// «출입증» 서비스, 캐시가 있는 버전. 하나의 실행 파일, 두 개의 역할.
//
//	MODE=hr   — 레거시 직원 디렉터리의 스텁. 느리게 응답하며,
//	            실제 시스템과 똑같이 동작한다: HR_DELAY는 기본값 800 ms.
//	MODE=api  — «출입증» 서비스 그 자체. 디렉터리로 가고, REDIS_ADDR가
//	            설정되어 있으면 먼저 캐시를 확인한다.
//
// 이미지는 반드시 하나여야 하므로 하나의 역할이 두 경우를 모두 담당한다: 레지스트리에 거의
// 동일한 이미지가 둘 있으면 버전 올리는 것을 잊을 수 있는 곳이 두 군데가 된다.
//
// 외부 의존성은 없고 표준 라이브러리만 사용한다. 여기의 Redis 클라이언트는
// 직접 만든 약 오십 줄짜리다 — Redis 프로토콜은 텍스트 기반이라 GET/SET 정도는
// 함수 하나에 들어간다. 실무에서는 기성 라이브러리를 쓰지만, 여기서는
// 빌드가 패키지를 받으러 인터넷에 나가지 않는 것이 더 중요하다.
//
// Go를 읽을 줄 몰라도 된다: 아래에 무엇이 어디에 있는지 표시해 두었다. 먼저 작은 헬퍼들,
// 그다음 직접 만든 Redis 클라이언트, 그다음 두 역할 — «느린 디렉터리»와 «서비스
// 그 자체». 이 랩의 핵심은 파일 끝에 가까운 setupAPI에서 일어난다.
//
// 읽다가 막히지 않도록, 이 언어의 세 가지 관례:
//
//	func 이름(인자) (반환값) { ... } — 함수 선언;
//	함수는 종종 여러 값을 한꺼번에 반환하며, 그중 마지막이 에러다:
//	err == nil은 «잘 됐다», err != nil은 «잘 안 됐다»로 읽는다;
//	//로 시작하는 줄은 주석이며, 프로그램 동작에는 영향을 주지 않는다.
//
// 이 파일은 옆의 Dockerfile로, VM에서 빌드된다: docker build ... app/ — README 참고.
package main

// 이 파일이 사용하는 라이브러리 목록. 하나도 빠짐없이 Go 배포판에 포함된 표준 라이브러리다.
// 서드파티 줄은 단 하나도 없다: 빌드는 인터넷에 나가지 않으며, 누군가의 패키지가
// 공개 저장소에서 삭제되었다고 해서 깨지지 않는다.
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

// ---------------------------------------------------------------- 환경

// env는 환경 변수를 읽고, 비어 있거나 설정되지 않았으면 대체(fallback) 값을
// 반환한다. 여기서 매니페스트에서 보는 성질이 나온다: 애플리케이션의 동작은
// 이미지 재빌드가 아니라 YAML 한 줄과 파드 재시작으로 바뀐다.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — 숫자에 대한 동일한 것. 변수가 숫자가 아니면 애플리케이션은
// 죽지 않는다: 로그에 기록하고 대체 값을 취한다. 매니페스트의 오타가 서비스를
// 쓰러뜨려서는 안 된다 — 로그에 드러나야 한다.
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("값 %s=%q은 숫자가 아니어서 %d를 사용합니다", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// Redis 자신이 보낸 에러 («-»로 시작하는 줄): 예를 들어
// NOAUTH나 WRONGTYPE. 이를 네트워크 에러와 구분하는 것이 중요하다: 잘못된
// 비밀번호는 재연결로 해결되지 않으며, 재시도는 원인을 가릴 뿐이다.
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — 캐시로의 지속적인 TCP 연결 하나에 락 mu가 더해진 것으로, 두 개의
// 동시 요청이 이 연결에 뒤섞여 쓰지 않도록 한다. 연결은 열어 둔다:
// 요청마다 새로 맺는 것이 요청 자체보다 비싸기 때문이다.
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked는 연결을 열고, 비밀번호가 설정되어 있으면 곧바로 AUTH 명령으로
// 자신을 소개한다. 이름의 Locked 접미사는 «락 mu가 이미 잡혀 있을 때만 호출하라»는
// 뜻이다 — 이는 언어의 성질이 아니라 이 함수들 사이의 약속이다.
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

// do는 명령을 실행하고, 연결이 끊겼으면 한 번 재연결한다.
// 값, «값이 있음» 플래그, 에러를 반환한다.
// 시도는 정확히 두 번, 열 번이 아니다: Redis가 거부로 응답하면 재시도는 사용자에게
// 가는 응답을 지연시키고 원인을 로그 곳곳에 흩뿌릴 뿐이다.
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
			return "", false, err // Redis 자신이 응답함 — 재시도는 도움이 안 됨
		}
		r.closeLocked() // 네트워크: 끊고 한 번 더 시도
	}
	return "", false, lastErr
}

// commandLocked는 Redis가 이해하는 형식으로 명령을 보낸다: 먼저
// 뒤에 몇 개의 조각이 오는지, 그다음 각 조각의 길이와 내용. 3초의 데드라인은 —
// 멈춘 캐시가 디렉터리로 가는 것보다 더 오래 응답을 지연시키지 않도록 하기 위함이다.
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

// readReplyLocked는 응답을 파싱한다. 줄의 첫 문자가 정확히 무엇이 왔는지 알려주며,
// 함수 전체가 다섯 가지 경우의 처리다. «$-1» 경우가 특히 중요하다: 이는 고장이 아니라
// «그런 키가 없다», 즉 평범한 캐시 미스다.
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: 빈 응답")
	}
	switch line[0] {
	case '+', ':': // 단순 문자열 또는 숫자
		return line[1:], true, nil
	case '-': // 서버에서 온 에러
		return "", false, &redisError{msg: line[1:]}
	case '$': // 길이가 알려진 문자열; -1은 «그런 키가 없다»는 뜻
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // 캐시 미스는 에러가 아니다
		}
		buf := make([]byte, n+2) // 끝의 \r\n를 위한 +2
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: 알 수 없는 응답 %q", line)
	}
}

// Get과 SetTTL — 서비스가 사용하는 명령의 전부. 캐시에 더 요구되는 것이
// 없으므로 여기 클라이언트가 한 페이지에 들어간다.
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL은 값을 저장하고 곧바로 수명을 지정한다. SET 더하기 EXPIRE가 아니라
// 명령 하나로: 두 명령 사이에 연결이 끊길 수 있고, 그러면 키가
// 캐시에 영원히 남는다.
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- 데이터

// employee — 서비스가 외부로 반환하고 캐시에 넣는 것. 오른쪽의 `json:"id"` 태그는
// JSON에서의 필드 이름을 정한다: Go에서 필드는 대문자로 시작할 때만 외부에서 보이고, JSON에서는
// 소문자를 쓰는 것이 관례라서, 이 태그들이 둘을 이어 준다.
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// 데이터는 지어낸 것이다. 학습용 스탠드에 실제 인사 기록은 없으며, 있어서도 안 된다.
var surnames = []string{
	"김민○", "이수○", "임준○", "박서○",
	"최동○", "한은○", "오상○", "서나○",
}

var departments = []string{
	"보안팀", "회계팀", "개발팀",
	"물류팀", "인사팀", "행정팀",
}

// 데이터는 지어낸 것이지만 같은 식별자에 대해서는 동일하다:
// 그렇지 않으면 응답만 보고 그것이 캐시에서 왔는지 디렉터리로 갔다 왔는지 알 수 없다.
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

// writeJSON은 응답을 반환한다: 콘텐츠 타입 헤더, 응답 코드, 본문.
// SetEscapeHTML(false)는 러시아어 글자와 따옴표가 \u 시퀀스로 바뀌지 않도록
// 하기 위해 필요하다 — 그렇지 않으면 응답을 눈으로 해독해야 한다.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("응답을 반환하지 못했습니다: %v", err)
	}
}

// employeeID는 쿼리 문자열에서 ?id=를 꺼낸다. 빈 식별자는 «0»으로 바꾸어,
// 캐시 키가 항상 확정된 형태를 갖고 꼬리 없는 «employee:» 키가
// 만들어지지 않도록 한다.
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- 메인

// main — 진입점: 여기서 프로그램의 동작이 시작된다. HTTP 서버를 띄우고, 거기에
// /healthz를, 그리고 MODE를 보고 두 역할 중 하나를 붙인다. 역할은 시작 시 한 번
// 선택되며 파드가 사는 동안 바뀌지 않는다.
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "알 수 없음")

	mux := http.NewServeMux()
	// /healthz는 두 역할 모두에 있다: 매니페스트에 기술된 준비성 프로브가 여기로 두드린다.
	// 이것은 항상 응답하고 아무것도 확인하지 않는다 — 여기서 프로브의 역할은 프로세스가
	// 떴고 포트를 듣고 있는지 알리는 것이지 시스템의 건강을 평가하는 것이 아니다.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 두 역할로 갈라지는 분기. 알 수 없는 값은 «어떻게든» 시작할 이유가 되지 않는다:
	// 즉시, 그리고 분명한 메시지와 함께 멈춘다. 잘못된 역할로 조용히 시작하면
	// 로그를 한 시간 들여다보는 대가를 치르게 된다.
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("알 수 없는 MODE=%q, 허용되는 값은 hr과 api입니다", mode)
	}

	// ReadHeaderTimeout은 클라이언트가 요청을 시작하고 침묵하면 연결을 닫는다. 이것이 없으면
	// 그런 «클라이언트» 몇이면 아무것도 요청하지 않고도 서버 전체를 점유하기에 충분하다.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("모드 %s, 포트 %s, 파드 %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — 레거시 디렉터리의 스텁. 유일한 특징은 느리다는 것이며,
// 그것은 우연이 아니라 과제의 본질이다.
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q를 해석하지 못해 800ms를 사용합니다", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("디렉터리가 %s 만에 응답합니다", delay)

	// 이 역할의 유일한 주소. time.Sleep가 «레거시 시스템»의 전부다: 캐시가 랩에
	// 등장하는 이유가 되는 바로 그 수백 밀리초. 응답의 source 필드는
	// 데이터가 캐시가 아니라 여기서 왔음을 보여준다.
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

// setupAPI — «출입증» 서비스 그 자체. 여기에 캐시 로직이 살고, «응답에 왜
// cache: off라고 쓰여 있나»라는 질문의 답도 여기에 있다.
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// 캐시는 REDIS_ADDR가 존재한다는 사실만으로 켜진다 — cache-patch.yaml이 추가하는
	// 바로 그 변수. 변수가 없으면 — cache는 비어 있고, 아래의 모든
	// `if cache != nil` 검사가 발동하지 않으며, 서비스는 하던 대로 동작한다.
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("캐시 활성화됨: %s, 레코드 수명 %d초", addr, ttl)
	} else {
		log.Printf("캐시 비활성화됨: REDIS_ADDR가 설정되지 않아 모든 요청이 디렉터리로 갑니다")
	}

	// 확장된 연결 풀을 가진 별도의 클라이언트: 그렇지 않으면 부하 상황에서
	// 절반의 시간이 디렉터리로의 TCP 연결을 맺는 데 쓰이고,
	// 측정값은 디렉터리의 지연이 아니라 우리 자신의 부주의를 보여주게 된다.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// 루트 «/» — 서비스의 명함: 버전, 파드, 노드, 레지스트리, 캐시 모드. cache 필드에서
	// 로그를 들여다보거나 매니페스트를 뜯어보지 않고도 off인지 redis인지 바로 보인다.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "알 수 없음"),
			"namespace": env("POD_NAMESPACE", "알 수 없음"),
			"registry":  env("IMAGE_REGISTRY", "미지정"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// 랩의 주요 주소. 동작 순서: 캐시에 묻고, 미스면 디렉터리로 가고,
	// 응답을 캐시에 넣는다. 이 랩에서 측정하는 모든 것이 이 마흔
	// 줄에서 일어난다.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// 캐시 키는 «employee:» 더하기 식별자다. 접두사는 서로 다른 종류의 레코드가
		// 충돌하지 않도록 하기 위해 필요하다: 캐시는 애플리케이션 전체에 하나이고, 그 안의 이름은 평면적이다.
		key := "employee:" + id

		var emp employee
		fromCache := false

		// 첫 번째 단계: 캐시에 묻는다. 세 가지 결과 — 에러, 히트, 미스 — 는
		// 서로 다르게 처리되며, 그 차이는 여기서 근본적이다.
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// 캐시를 사용할 수 없음 — 이는 사용자에게 에러를 반환할 이유가 아니다.
				// 디렉터리로 간다: 느리지만 올바르다.
				log.Printf("캐시를 사용할 수 없음 (%v), 디렉터리로 갑니다", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("키 %s의 캐시에 쓰레기가 들어 있어 디렉터리로 갑니다", key)
				}
			}
		}

		// 두 번째 단계: 미스이거나 캐시를 쓸 수 없으면 — 디렉터리로 간다. 느리지만 그것이
		// 유일한 진실의 원천이다. 응답을 캐시에 넣는다; 넣는 것이 잘 안 됐어도
		// 사용자는 그것을 알 필요가 없다 — 그는 이미 자신의 응답을 받았고, 단지
		// 다음 요청이 다시 느려질 뿐이다.
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("디렉터리가 응답하지 않았습니다: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "직원 디렉터리를 사용할 수 없습니다",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("캐시에 넣지 못했습니다: %v", err)
					}
				}
			}
		}

		// cached와 took_ms 필드가 이 모든 것을 시작한 이유다: 이것으로 요청이 캐시에
		// 맞았는지 아닌지, 그리고 몇 밀리초가 들었는지 보인다. 이것들은 check.sh가
		// 랩을 통과시킬지 말지 결정할 때도 읽는다.
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

// cacheMode는 내부 상태를 응답용 한 단어로 옮긴다: off 또는 redis.
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — HTTP로 디렉터리에 가는 여정. 식별자는 이스케이프된다
// (url.QueryEscape): 그러지 않으면 id 안의 공백이나 «&»가 요청 주소를 망가뜨린다.
// 응답 본문은 항상 닫는다(defer), 그러지 않으면 부하 상황에서 연결이 바닥난다.
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("디렉터리가 %s로 응답했습니다", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
