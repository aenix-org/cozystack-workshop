// Der Dienst „Ausweis", Version mit Cache. Eine ausführbare Datei, zwei Rollen.
//
//	MODE=hr   — ein Platzhalter für das Legacy-Mitarbeiterverzeichnis. Antwortet langsam,
//	            genau so, wie das echte antwortet: HR_DELAY ist standardmäßig 800 ms.
//	MODE=api  — der Dienst „Ausweis" selbst. Fragt das Verzeichnis ab, und wenn REDIS_ADDR
//	            gesetzt ist, schaut er zuerst in den Cache.
//
// Eine Rolle für beide Fälle, weil es nur ein Image geben soll: zwei fast identische
// Images in der Registry sind zwei Stellen, an denen man vergessen kann, die Version zu erhöhen.
//
// Es gibt keine externen Abhängigkeiten, nur die Standardbibliothek. Der Redis-Client hier
// ist unser eigener, fünfzig Zeilen lang — das Redis-Protokoll ist textbasiert und passt für GET/SET
// in eine Funktion. In der Produktion nimmt man eine fertige Bibliothek; hier ist wichtiger, dass
// der Build nicht ins Internet nach Paketen geht.
//
// Man muss Go nicht lesen können: unten ist ausgewiesen, wo was liegt. Zuerst die kleinen Helfer,
// dann der selbstgebaute Redis-Client, dann die zwei Rollen — das „langsame Verzeichnis" und der „Dienst
// selbst". Das Wichtigste, worum es in der Übung geht, passiert in setupAPI, näher am Ende der Datei.
//
// Drei Konventionen der Sprache, damit man beim Lesen nicht stolpert:
//
//	func name(Argumente) (was zurückgegeben wird) { ... } — eine Funktionsdeklaration;
//	eine Funktion gibt oft mehrere Werte auf einmal zurück, und der letzte davon ist ein Fehler:
//	err == nil liest sich als „hat geklappt", err != nil — „hat nicht geklappt";
//	Zeilen, die mit // beginnen, sind Kommentare, sie beeinflussen die Arbeitsweise des Programms nicht.
//
// Die Datei wird vom benachbarten Dockerfile gebaut, auf dem Laptop: docker build ... app/ — siehe README.
package main

// Die Liste der Bibliotheken, die die Datei verwendet. Jede einzelne ist Standard, aus der Go-Distribution.
// Keine einzige Drittanbieter-Zeile: der Build geht nicht ins Internet und bricht nicht deshalb ab, weil
// jemandes fremdes Paket aus einem öffentlichen Repository entfernt wurde.
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

// ---------------------------------------------------------------- Umgebung

// env liest eine Umgebungsvariable und gibt, wenn sie leer oder nicht gesetzt ist, den Ersatzwert
// zurück. Daher die Eigenschaft, die man in den Manifesten sieht: das Verhalten der Anwendung
// ändert sich mit einer Zeile in YAML und einem Pod-Neustart, nicht mit einem Neubau des Images.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — dasselbe für Zahlen. Wenn die Variable sich als keine Zahl herausstellt, stürzt die Anwendung nicht
// ab: sie schreibt ins Log und nimmt den Ersatzwert. Ein Tippfehler im Manifest darf den
// Dienst nicht lahmlegen — er muss im Log sichtbar sein.
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("%s=%q ist keine Zahl, verwende %d", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// Ein Fehler, den Redis selbst gesendet hat (eine Zeile, die mit „-" beginnt): zum Beispiel
// NOAUTH oder WRONGTYPE. Ihn von einem Netzwerkfehler zu unterscheiden ist wichtig: ein Neuverbinden
// behebt kein falsches Passwort, und Wiederholungen verschleiern nur die Ursache.
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — eine dauerhafte TCP-Verbindung zum Cache plus ein Lock mu, damit zwei
// gleichzeitige Anfragen nicht vermischt in diese Verbindung schreiben. Wir halten die Verbindung
// offen: für jede Anfrage eine neue aufzubauen kostet mehr als die Anfrage selbst.
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked öffnet die Verbindung und stellt sich, wenn ein Passwort gesetzt ist, sofort mit dem
// AUTH-Befehl vor. Das Suffix Locked im Namen bedeutet „nur dann aufrufen, wenn das Lock mu
// bereits gehalten wird" — das ist eine Vereinbarung zwischen diesen Funktionen, keine Eigenschaft der Sprache.
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

// do führt einen Befehl aus und verbindet einmal neu, wenn die Verbindung abgebrochen ist.
// Gibt den Wert, ein „Wert vorhanden"-Flag und einen Fehler zurück.
// Es gibt genau zwei Versuche, nicht zehn: wenn Redis mit einer Ablehnung antwortet, verzögern Wiederholungen nur
// die Antwort an den Benutzer und verschmieren die Ursache über die Logs.
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
			return "", false, err // Redis selbst hat geantwortet — eine Wiederholung hilft nicht
		}
		r.closeLocked() // Netzwerk: abbrechen und noch einmal versuchen
	}
	return "", false, lastErr
}

// commandLocked sendet den Befehl in der Form, die Redis versteht: zuerst
// wie viele Stücke folgen, dann Länge und Inhalt jedes einzelnen. Die Frist von drei Sekunden ist
// dafür, dass ein hängender Cache die Antwort nicht länger verzögert als ein Gang zum Verzeichnis selbst.
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

// readReplyLocked zerlegt die Antwort. Das erste Zeichen der Zeile sagt, was genau angekommen ist,
// und die ganze Funktion ist die Behandlung von fünf Fällen. Besonders wichtig ist „$-1": das ist kein Defekt,
// sondern „so einen Schlüssel gibt es nicht", also ein gewöhnlicher Cache-Fehltreffer.
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: leere Antwort")
	}
	switch line[0] {
	case '+', ':': // eine einfache Zeichenkette oder eine Zahl
		return line[1:], true, nil
	case '-': // ein Fehler vom Server
		return "", false, &redisError{msg: line[1:]}
	case '$': // eine Zeichenkette bekannter Länge; -1 bedeutet „kein Schlüssel"
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // ein Cache-Fehltreffer ist kein Fehler
		}
		buf := make([]byte, n+2) // +2 für das abschließende \r\n
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: unerwartete Antwort %q", line)
	}
}

// Get und SetTTL — der ganze Satz an Befehlen, den der Dienst verwendet. Mehr wird vom
// Cache nicht verlangt, weshalb der Client hier auf eine Seite passt.
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL legt den Wert ab und weist sofort eine Lebensdauer zu. Mit einem Befehl, nicht
// SET plus EXPIRE: zwischen zwei Befehlen kann die Verbindung abbrechen, und der Schlüssel
// bliebe für immer im Cache.
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- Daten

// employee — das, was der Dienst nach außen zurückgibt und in den Cache legt. Die `json:"id"`-Tags rechts
// legen die Feldnamen in JSON fest: in Go sind Felder von außen nur mit Großbuchstaben sichtbar, während in JSON
// üblicherweise Kleinbuchstaben verwendet werden, und diese Tags verbinden sie miteinander.
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// Die Daten sind erfunden. Es gibt keine echten Personaldaten in einem Schulungsstand, und es darf keine geben.
var surnames = []string{
	"Weber J.", "Bergmann A.", "Sander P.", "Krüger M.",
	"Schulz D.", "Pohl E.", "Wolf S.", "Winter N.",
}

var departments = []string{
	"Sicherheitsdienst", "Buchhaltung", "Entwicklung",
	"Logistik", "Personalabteilung", "Verwaltung",
}

// Die Daten sind erfunden, aber gleich für denselben Bezeichner:
// sonst könnte man an der Antwort nicht erkennen, ob es der Cache ist oder ein Gang zum Verzeichnis.
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

// writeJSON sendet die Antwort: den Header mit dem Inhaltstyp, den Antwortcode und den Body.
// SetEscapeHTML(false) wird gebraucht, damit russische Buchstaben und Anführungszeichen sich nicht
// in \u-Sequenzen verwandeln — sonst müsste man die Antwort mit dem Auge entschlüsseln.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("Antwort konnte nicht gesendet werden: %v", err)
	}
}

// employeeID zieht ?id= aus dem Query-String. Ein leerer Bezeichner wird in „0" verwandelt,
// damit der Schlüssel im Cache immer eine bestimmte Form hat und kein Schlüssel
// „employee:" ohne Schwanz angelegt wird.
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- main

// main — der Einstiegspunkt: hier beginnt die Arbeit des Programms. Er bringt einen HTTP-Server hoch, hängt
// /healthz an ihn und, mit Blick auf MODE, eine der zwei Rollen. Die Rolle wird einmal
// beim Start gewählt und ändert sich während des Lebens des Pods nicht.
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "unbekannt")

	mux := http.NewServeMux()
	// /healthz existiert in beiden Rollen: hierher klopft die Readiness-Probe, die in den Manifesten beschrieben ist.
	// Sie antwortet immer und prüft nichts — die Aufgabe der Probe ist hier zu erkennen,
	// dass der Prozess hochgekommen ist und den Port abhört, nicht die Gesundheit des Systems zu bewerten.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// Die Verzweigung in zwei Rollen. Ein unbekannter Wert ist kein Grund, „irgendwie" zu starten:
	// wir stürzen sofort und mit einer klaren Nachricht ab. Ein stiller Start in der falschen Rolle würde
	// eine Stunde Starren auf Logs kosten.
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("unbekannter MODE=%q, zulässig sind hr und api", mode)
	}

	// ReadHeaderTimeout schließt die Verbindung, wenn ein Client eine Anfrage begonnen hat und verstummt ist. Ohne ihn
	// reichen ein paar solcher „Clients", um den ganzen Server zu belegen, ohne etwas anzufragen.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("Modus %s, Port %s, Pod %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — ein Platzhalter für das Legacy-Verzeichnis. Seine einzige Besonderheit ist,
// dass es langsam ist, und das ist kein Zufall, sondern das Wesen der Aufgabe.
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q konnte nicht verarbeitet werden, verwende 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("Verzeichnis antwortet in %s", delay)

	// Die einzige Adresse dieser Rolle. time.Sleep ist das ganze „Legacy-System": genau jene
	// Hunderte von Millisekunden, um derentwillen in der Übung der Cache erscheint. Das Feld source in der Antwort
	// zeigt, dass die Daten von hier kamen, nicht aus dem Cache.
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

// setupAPI — der Dienst „Ausweis" selbst. Hier lebt die Cache-Logik, und hier liegt auch die Antwort
// auf die Frage „warum steht in der Antwort cache: off".
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// Der Cache wird durch das bloße Vorhandensein von REDIS_ADDR eingeschaltet — der Variable, die
	// cache-patch.yaml hinzufügt. Keine Variable — cache bleibt leer, alle Prüfungen
	// `if cache != nil` unten greifen nicht, und der Dienst arbeitet, wie er gearbeitet hat.
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("Cache aktiviert: %s, Lebensdauer des Eintrags %d s", addr, ttl)
	} else {
		log.Printf("Cache deaktiviert: REDIS_ADDR ist nicht gesetzt, jede Anfrage geht ins Verzeichnis")
	}

	// Ein separater Client mit vergrößertem Verbindungspool: sonst würde unter Last
	// die halbe Zeit für den Aufbau von TCP-Verbindungen zum Verzeichnis draufgehen,
	// und die Messung würde nicht die Latenz des Verzeichnisses zeigen, sondern unsere eigene Nachlässigkeit.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// Die Wurzel „/" — die Visitenkarte des Dienstes: Version, Pod, Node, Registry und Cache-Modus. Am Feld cache
	// sieht man sofort off oder redis, ohne in die Logs zu schauen oder das Manifest zu zerlegen.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "unbekannt"),
			"namespace": env("POD_NAMESPACE", "unbekannt"),
			"registry":  env("IMAGE_REGISTRY", "nicht angegeben"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// Die Hauptadresse der Übung. Die Reihenfolge der Aktionen: den Cache fragen, bei einem Fehltreffer zum Verzeichnis gehen,
	// die Antwort in den Cache legen. Alles, was man in dieser Übung misst, passiert auf diesen vierzig
	// Zeilen.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// Der Schlüssel im Cache — „employee:" plus der Bezeichner. Das Präfix wird gebraucht, damit verschiedene Arten
		// von Einträgen nicht kollidieren: der Cache ist einer für die ganze Anwendung, und die Namen darin sind flach.
		key := "employee:" + id

		var emp employee
		fromCache := false

		// Schritt eins: den Cache fragen. Drei Ausgänge — ein Fehler, ein Treffer, ein Fehltreffer — werden
		// unterschiedlich behandelt, und der Unterschied zwischen ihnen ist hier grundlegend.
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// Der Cache ist nicht verfügbar — das ist kein Grund, dem Benutzer einen Fehler zurückzugeben.
				// Wir gehen zum Verzeichnis: langsam, aber korrekt.
				log.Printf("Cache nicht verfügbar (%v), gehe ins Verzeichnis", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("Cache enthält Müll für Schlüssel %s, gehe ins Verzeichnis", key)
				}
			}
		}

		// Schritt zwei: ein Fehltreffer oder ein nicht verfügbarer Cache — wir gehen zum Verzeichnis. Langsam, aber es ist
		// die einzige Quelle der Wahrheit. Wir legen die Antwort in den Cache; wenn das Ablegen fehlgeschlagen ist,
		// braucht der Benutzer davon nichts zu wissen — er hat seine Antwort schon bekommen, es ist nur so, dass
		// die nächste Anfrage wieder langsam sein wird.
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("Verzeichnis hat nicht geantwortet: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "Mitarbeiterverzeichnis ist nicht verfügbar",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("Ablegen in den Cache fehlgeschlagen: %v", err)
					}
				}
			}
		}

		// Die Felder cached und took_ms — das, wofür das alles begonnen wurde: an ihnen sieht man, ob die Anfrage
		// den Cache getroffen hat oder nicht und wie viele Millisekunden es gekostet hat. check.sh liest sie ebenfalls,
		// wenn es entscheidet, ob die Übung als bestanden gilt oder nicht.
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

// cacheMode übersetzt den internen Zustand in ein Wort für die Antwort: off oder redis.
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — ein Gang zum Verzeichnis über HTTP. Der Bezeichner wird escaped
// (url.QueryEscape): ohne dies würden ein Leerzeichen oder „&" innerhalb von id die Anfrage-URL auseinanderreißen.
// Der Antwort-Body wird immer geschlossen (defer), sonst würden unter Last die Verbindungen ausgehen.
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("Verzeichnis hat geantwortet %s", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
