// The "Pass" service, cached version. One executable, two roles.
//
//	MODE=hr   — a stub for the legacy employee directory. Answers slowly,
//	            exactly like the real one does: HR_DELAY is 800ms by default.
//	MODE=api  — the "Pass" service itself. Queries the directory, and if REDIS_ADDR
//	            is set, first looks in the cache.
//
// One role for both cases, because the image must be single: two nearly identical
// images in the registry are two places where you can forget to bump the version.
//
// There are no external dependencies, only the standard library. The Redis client here
// is our own, fifty lines long — the Redis protocol is textual and for GET/SET it fits
// into one function. In production you take a ready-made library; here it matters more that
// the build does not go to the internet for packages.
//
// You don't need to know how to read Go: below it is laid out where everything is. First the small helpers,
// then the homemade Redis client, then the two roles — the "slow directory" and the "service
// itself". The main thing the lab is built around happens in setupAPI, closer to the end of the file.
//
// Three conventions of the language, so you don't stumble while reading:
//
//	func name(arguments) (what it returns) { ... } — a function declaration;
//	a function often returns several values at once, and the last of them is an error:
//	err == nil reads as "went fine", err != nil — "did not go fine";
//	lines starting with // are comments, they don't affect how the program works.
//
// The file is built by the neighboring Dockerfile, on the laptop: docker build ... app/ — see README.
package main

// The list of libraries the file uses. Every single one is standard, from the Go distribution.
// Not one third-party line: the build does not go to the internet and won't break because
// someone's foreign package was removed from a public repository.
import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------- environment

// env reads an environment variable and, if it is empty or unset, returns the fallback
// value. Hence the property you see in the manifests: the application's behavior
// changes with a line in YAML and a pod restart, not with a rebuild of the image.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — the same for numbers. If the variable turns out not to be a number, the application does not
// crash: it writes to the log and takes the fallback value. A typo in the manifest must not bring down
// the service — it must be visible in the log.
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("%s=%q is not a number, using %d", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// An error sent by Redis itself (a line starting with "-"): for example
// NOAUTH or WRONGTYPE. Telling it apart from a network error matters: reconnecting
// won't fix a wrong password, and retries only mask the cause.
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — one persistent TCP connection to the cache plus a lock mu, so that two
// concurrent requests don't write into this connection intermixed. We keep the connection
// open: establishing a new one for every request costs more than the request itself.
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked opens the connection and, if a password is set, immediately introduces itself
// with the AUTH command. The Locked suffix in the name means "call only when the lock mu
// is already held" — this is an agreement between these functions, not a property of the language.
func (r *redisClient) connectLocked() error {
	c, err := net.DialTimeout("tcp", r.addr, 3*time.Second)
	if err != nil {
		return err
	}
	r.conn = c
	r.rd = bufio.NewReader(c)
	if r.password != "" {
		if _, _, err := r.commandLocked("AUTH", r.password); err != nil {
			r.closeLocked()
			return err
		}
	}
	return nil
}

func (r *redisClient) closeLocked() {
	if r.conn != nil {
		_ = r.conn.Close()
	}
	r.conn = nil
	r.rd = nil
}

// do runs a command and reconnects once if the connection dropped.
// Returns the value, a "value present" flag, and an error.
// There are exactly two attempts, not ten: if Redis answers with a refusal, retries only delay
// the response to the user and smear the cause across the logs.
func (r *redisClient) do(args ...string) (string, bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		if r.conn == nil {
			if err := r.connectLocked(); err != nil {
				return "", false, err
			}
		}
		val, found, err := r.commandLocked(args...)
		if err == nil {
			return val, found, nil
		}
		lastErr = err
		var re *redisError
		if errors.As(err, &re) {
			return "", false, err // Redis itself answered — a retry won't help
		}
		r.closeLocked() // network: drop it and try again
	}
	return "", false, lastErr
}

// commandLocked sends the command in the form Redis understands: first
// how many chunks follow, then the length and content of each. The three-second deadline is
// so a hung cache does not delay the response longer than a trip to the directory itself.
func (r *redisClient) commandLocked(args ...string) (string, bool, error) {
	var b strings.Builder
	fmt.Fprintf(&b, "*%d\r\n", len(args))
	for _, a := range args {
		fmt.Fprintf(&b, "$%d\r\n%s\r\n", len(a), a)
	}
	if err := r.conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return "", false, err
	}
	if _, err := io.WriteString(r.conn, b.String()); err != nil {
		return "", false, err
	}
	return r.readReplyLocked()
}

// readReplyLocked parses the reply. The first character of the line tells what exactly arrived,
// and the whole function is the handling of five cases. The "$-1" case is separately important: it is not a breakage,
// but "there is no such key", that is, an ordinary cache miss.
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: empty reply")
	}
	switch line[0] {
	case '+', ':': // a simple string or a number
		return line[1:], true, nil
	case '-': // an error from the server
		return "", false, &redisError{msg: line[1:]}
	case '$': // a string of known length; -1 means "no key"
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // a cache miss is not an error
		}
		buf := make([]byte, n+2) // +2 for the trailing \r\n
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: unexpected reply %q", line)
	}
}

// Get and SetTTL — the whole set of commands the service uses. Nothing else is
// required from the cache, which is why the client here fits on a page.
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL puts the value and immediately assigns a time to live. With one command, not
// SET plus EXPIRE: between two commands the connection may drop, and the key
// would stay in the cache forever.
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- data

// employee — what the service returns to the outside and puts in the cache. The `json:"id"` tags on the right
// set the field names in JSON: in Go fields are visible from outside only with a capital letter, while in JSON
// it is customary to use lowercase, and these tags link them together.
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// The data is made up. There are no real HR records in a training stand, and there must not be.
var surnames = []string{
	"Whitfield J.", "Prescott A.", "Sidney P.", "Marsh M.",
	"Grant D.", "Poole E.", "Wolfe S.", "Frost N.",
}

var departments = []string{
	"Security", "Accounting", "Engineering",
	"Logistics", "HR", "Administration",
}

// The data is made up, but the same for the same identifier:
// otherwise you couldn't tell from the response whether it's the cache or a trip to the directory.
func personFor(id string) employee {
	h := 7
	for _, c := range id {
		h = h*31 + int(c)
	}
	if h < 0 {
		h = -h
	}
	return employee{
		ID:   id,
		Name: surnames[h%len(surnames)],
		Dept: departments[(h/13)%len(departments)],
	}
}

// writeJSON sends the response: the header with the content type, the response code, and the body.
// SetEscapeHTML(false) is needed so that Russian letters and quotes don't turn
// into \u-sequences — otherwise you'd have to decode the response by eye.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("failed to write response: %v", err)
	}
}

// employeeID pulls ?id= out of the query string. An empty identifier is turned into "0",
// so that the key in the cache always has a definite shape and no key
// "employee:" without a tail is created.
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- main

// main — the entry point: the program's work begins here. It brings up an HTTP server, hangs
// /healthz on it and, looking at MODE, one of the two roles. The role is chosen once
// at startup and does not change during the pod's life.
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "unknown")

	mux := http.NewServeMux()
	// /healthz exists in both roles: the readiness probe described in the manifests knocks here.
	// It always answers and checks nothing — the probe's job here is to tell
	// that the process came up and is listening on the port, not to assess the health of the system.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// The fork into two roles. An unknown value is no reason to start up "somehow":
	// we crash immediately and with a clear message. A silent startup in the wrong role would cost
	// an hour of staring at logs.
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("unknown MODE=%q, allowed values are hr and api", mode)
	}

	// ReadHeaderTimeout closes the connection if a client started a request and went quiet. Without it
	// a few such "clients" are enough to occupy the whole server without requesting anything.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("mode %s, port %s, pod %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — a stub for the legacy directory. Its only distinctive feature is that
// it is slow, and this is not an accident but the essence of the task.
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("could not parse HR_DELAY=%q, using 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("directory responds in %s", delay)

	// The only address of this role. time.Sleep is the whole "legacy system": those very
	// hundreds of milliseconds for whose sake the cache appears in the lab. The source field in the response
	// shows that the data came from here, not from the cache.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		id := employeeID(r)
		time.Sleep(delay)
		emp := personFor(id)
		writeJSON(w, http.StatusOK, map[string]any{
			"id":     emp.ID,
			"name":   emp.Name,
			"dept":   emp.Dept,
			"source": "hr-legacy",
			"pod":    pod,
		})
	})
}

// setupAPI — the "Pass" service itself. Here lives the cache logic, and here too lies the answer
// to the question "why does the response say cache: off".
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// The cache is turned on by the very presence of REDIS_ADDR — the variable that
	// cache-patch.yaml adds. No variable — cache stays empty, all the checks
	// `if cache != nil` below don't fire, and the service works as it worked.
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("cache enabled: %s, entry TTL %d s", addr, ttl)
	} else {
		log.Printf("cache disabled: REDIS_ADDR is not set, every request will go to the directory")
	}

	// A separate client with an enlarged connection pool: otherwise under load
	// half the time would go to establishing TCP connections to the directory,
	// and the measurement would show not the directory's latency but our own sloppiness.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// The root "/" — the service's business card: version, pod, node, registry and cache mode. From the cache field
	// you can immediately see off or redis, without looking into the logs or parsing the manifest.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "unknown"),
			"namespace": env("POD_NAMESPACE", "unknown"),
			"registry":  env("IMAGE_REGISTRY", "not set"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// The main address of the lab. The order of actions: ask the cache, on a miss go to the directory,
	// put the response in the cache. Everything you measure in this lab happens in these forty
	// lines.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// The key in the cache — "employee:" plus the identifier. The prefix is needed so that different kinds
		// of records don't collide: the cache is one for the whole application, and the names in it are flat.
		key := "employee:" + id

		var emp employee
		fromCache := false

		// Step one: ask the cache. Three outcomes — an error, a hit, a miss — are handled
		// differently, and the difference between them is fundamental here.
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// The cache is unavailable — that is no reason to return an error to the user.
				// We go to the directory: slow, but correct.
				log.Printf("cache unavailable (%v), going to the directory", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("cache holds garbage for key %s, going to the directory", key)
				}
			}
		}

		// Step two: a miss or an unavailable cache — we go to the directory. Slow, but it is
		// the only source of truth. We put the response in the cache; if putting it failed,
		// the user need not know about it — they have already got their response, it's just that
		// the next request will again be slow.
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("directory did not respond: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "employee directory is unavailable",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("failed to write to cache: %v", err)
					}
				}
			}
		}

		// The cached and took_ms fields — what all of this was started for: from them you can see whether the request hit
		// the cache or not and how many milliseconds it cost. check.sh also reads them
		// when it decides whether to count the lab as passed or not.
		writeJSON(w, http.StatusOK, map[string]any{
			"id":      emp.ID,
			"name":    emp.Name,
			"dept":    emp.Dept,
			"cached":  fromCache,
			"cache":   cacheMode(cache),
			"ttl_s":   ttl,
			"took_ms": time.Since(start).Milliseconds(),
			"pod":     pod,
		})
	})
}

// cacheMode translates the internal state into one word for the response: off or redis.
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — a trip to the directory over HTTP. The identifier is escaped
// (url.QueryEscape): without this a space or "&" inside id would break the request URL apart.
// The response body is always closed (defer), otherwise under load connections would run out.
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("directory responded %s", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
