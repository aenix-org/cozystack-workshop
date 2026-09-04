// Der Dienst «Pass», die Version mit Cache. Eine ausführbare Datei, zwei Rollen.
//
//	MODE=hr   — ein Stub des Legacy-Mitarbeiterverzeichnisses. Antwortet langsam,
//	            genau so, wie es das echte tut: HR_DELAY ist standardmäßig 800 ms.
//	MODE=api  — der Dienst «Pass» selbst. Geht ins Verzeichnis, und wenn REDIS_ADDR
//	            gesetzt ist, schaut er zuerst in den Cache.
//
// Eine Rolle deckt beide Fälle ab, weil es ein einziges Image geben muss: zwei fast identische
// Images in der Registry sind zwei Stellen, an denen man vergessen kann, die Version zu erhöhen.
//
// Es gibt keine externen Abhängigkeiten, nur die Standardbibliothek. Der Redis-Client hier
// ist ein eigener, etwa fünfzig Zeilen — das Redis-Protokoll ist textbasiert und passt für GET/SET
// in eine einzige Funktion. In der Produktion nimmt man eine fertige Bibliothek; hier ist es
// wichtiger, dass der Build nicht ins Internet geht, um Pakete zu holen.
//
// Man muss Go nicht lesen können: unten ist markiert, wo was liegt. Zuerst die kleinen Helfer,
// dann der selbstgebaute Redis-Client, dann die zwei Rollen — das «langsame Verzeichnis» und der
// «Dienst selbst». Das Wichtigste, worum es im Lab geht, passiert in setupAPI, näher am Ende der Datei.
//
// Drei Konventionen der Sprache, damit man beim Lesen nicht stolpert:
//
//	func name(argumente) (was es zurückgibt) { ... } — eine Funktionsdeklaration;
//	eine Funktion gibt oft mehrere Werte auf einmal zurück, und der letzte davon ist ein Fehler:
//	err == nil liest sich als «hat geklappt», err != nil — «hat nicht geklappt»;
//	Zeilen, die mit // beginnen, sind Kommentare, sie beeinflussen die Arbeit des Programms nicht.
//
// Gebaut wird die Datei vom benachbarten Dockerfile, auf der VM: docker build ... app/ — siehe README.
package main

// Die Liste der Bibliotheken, die die Datei verwendet. Jede einzelne ist Standard, aus der Go-Distribution.
// Keine einzige fremde Zeile: der Build geht nicht ins Internet und geht nicht dadurch kaputt, dass
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
// ändert sich durch eine Zeile in YAML und einen Pod-Neustart, nicht durch einen Image-Rebuild.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — dasselbe für Zahlen. Wenn in der Variable keine Ziffer steht, stürzt die Anwendung nicht
// ab: sie schreibt ins Log und nimmt den Ersatzwert. Ein Tippfehler im Manifest darf den
// Dienst nicht umlegen — er soll im Log sichtbar sein.
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("значение %s=%q не число, беру %d", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// Ein Fehler, den Redis selbst gesendet hat (eine Zeile, die mit «-» beginnt): zum Beispiel
// NOAUTH oder WRONGTYPE. Ihn von einem Netzwerkfehler zu unterscheiden ist wichtig: ein Neuverbinden
// hilft bei einem falschen Passwort nicht, und Versuche verschleiern nur die Ursache.
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — eine dauerhafte TCP-Verbindung zum Cache plus eine Sperre mu, damit zwei
// gleichzeitige Anfragen nicht vermischt in diese Verbindung schreiben. Die Verbindung halten wir
// offen: für jede Anfrage eine neue aufzubauen ist teurer als die Anfrage selbst.
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked öffnet die Verbindung und stellt sich, wenn ein Passwort gesetzt ist, sofort mit dem
// Befehl AUTH vor. Das Suffix Locked im Namen bedeutet «nur dann aufrufen, wenn die Sperre mu
// bereits gehalten wird» — das ist eine Absprache zwischen diesen Funktionen, keine Eigenschaft der Sprache.
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

// do führt einen Befehl aus und verbindet sich einmal neu, wenn die Verbindung abgebrochen ist.
// Gibt den Wert, ein Kennzeichen «Wert ist vorhanden» und einen Fehler zurück.
// Genau zwei Versuche, nicht zehn: wenn Redis mit einer Ablehnung antwortet, verzögern Wiederholungen nur
// die Antwort an den Nutzer und verschmieren die Ursache über die Logs.
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
		r.closeLocked() // Netzwerk: abreißen und noch einmal versuchen
	}
	return "", false, lastErr
}

// commandLocked sendet den Befehl in der Form, in der Redis ihn versteht: zuerst,
// wie viele Stücke folgen, dann die Länge und der Inhalt jedes einzelnen. Eine Frist von drei Sekunden —
// damit ein hängender Cache die Antwort nicht länger verzögert als ein Gang ins Verzeichnis selbst.
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
// und die ganze Funktion ist die Behandlung von fünf Fällen. Besonders wichtig ist «$-1»: das ist kein Defekt,
// sondern «einen solchen Schlüssel gibt es nicht», also ein gewöhnlicher Cache-Fehlschlag.
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: пустой ответ")
	}
	switch line[0] {
	case '+', ':': // eine einfache Zeichenkette oder eine Zahl
		return line[1:], true, nil
	case '-': // ein Fehler vom Server
		return "", false, &redisError{msg: line[1:]}
	case '$': // eine Zeichenkette bekannter Länge; -1 bedeutet «kein solcher Schlüssel»
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // ein Cache-Fehlschlag ist kein Fehler
		}
		buf := make([]byte, n+2) // +2 für das abschließende \r\n
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: непонятный ответ %q", line)
	}
}

// Get und SetTTL — der gesamte Satz an Befehlen, die der Dienst verwendet. Mehr wird vom Cache nicht
// verlangt, weshalb der Client hier auf eine Seite passt.
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL legt den Wert ab und weist ihm sofort eine Lebensdauer zu. Mit einem Befehl, nicht
// SET plus EXPIRE: zwischen zwei Befehlen kann die Verbindung abbrechen, und der Schlüssel
// bleibt für immer im Cache.
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- Daten

// employee — das, was der Dienst nach außen gibt und in den Cache legt. Die Markierungen `json:"id"` rechts
// legen die Feldnamen im JSON fest: in Go sind Felder von außen nur mit Großbuchstaben sichtbar, und im JSON
// ist es üblich, Kleinbuchstaben zu nehmen, und diese Markierungen verbinden sie.
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// Die Daten sind erfunden. Echte Personaldaten gibt es im Übungsstand nicht und darf es nicht geben.
var surnames = []string{
	"Иванов И. И.", "Петрова А. С.", "Сидоров П. Н.", "Кузнецова М. В.",
	"Смирнов Д. А.", "Попова Е. К.", "Волков С. Ю.", "Морозова Н. Г.",
}

var departments = []string{
	"Служба безопасности", "Бухгалтерия", "Разработка",
	"Логистика", "Отдел кадров", "Административный отдел",
}

// Die Daten sind erfunden, aber gleich für denselben Bezeichner:
// sonst könnte man an der Antwort nicht erkennen, ob es der Cache ist oder ein Gang ins Verzeichnis.
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

// writeJSON gibt die Antwort zurück: einen Header mit dem Inhaltstyp, den Antwortcode und den Rumpf.
// SetEscapeHTML(false) wird benötigt, damit russische Buchstaben und Anführungszeichen nicht in
// \u-Sequenzen verwandelt werden — sonst müsste man die Antwort mit den Augen entziffern.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("не удалось отдать ответ: %v", err)
	}
}

// employeeID holt ?id= aus der Anfragezeichenkette. Einen leeren Bezeichner verwandeln wir in «0»,
// damit der Schlüssel im Cache immer eine bestimmte Form hat und kein Schlüssel
// «employee:» ohne Schwanz entsteht.
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- Hauptteil

// main — der Einstiegspunkt: hier beginnt die Arbeit des Programms. Bringt den HTTP-Server hoch, hängt
// /healthz an ihn und, je nach MODE, eine der zwei Rollen. Die Rolle wird einmal
// beim Start gewählt und ändert sich während des Lebens des Pods nicht.
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "неизвестно")

	mux := http.NewServeMux()
	// /healthz gibt es in beiden Rollen: hierher klopft die in den Manifesten beschriebene Bereitschaftsprobe.
	// Sie antwortet immer und prüft nichts — die Aufgabe der Probe ist hier zu erkennen,
	// dass der Prozess hochgekommen ist und den Port lauscht, nicht die Gesundheit des Systems zu bewerten.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// Die Verzweigung in zwei Rollen. Ein unbekannter Wert ist kein Grund, sich «irgendwie» zu starten:
	// wir fallen sofort und mit einer verständlichen Meldung. Ein stiller Start in der falschen Rolle würde
	// eine Stunde Starren auf Logs kosten.
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("неизвестный MODE=%q, допустимы hr и api", mode)
	}

	// ReadHeaderTimeout schließt die Verbindung, wenn ein Client eine Anfrage begonnen hat und verstummt ist. Ohne es
	// genügen ein paar solcher «Clients», um den ganzen Server zu besetzen, ohne etwas angefragt zu haben.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("режим %s, порт %s, под %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — ein Stub des Legacy-Verzeichnisses. Seine einzige Besonderheit ist,
// dass es langsam ist, und das ist kein Zufall, sondern der Kern der Aufgabe.
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q не разобрался, беру 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("справочник отвечает за %s", delay)

	// Die einzige Adresse dieser Rolle. time.Sleep ist das gesamte «Legacy-System»: eben jene
	// Hunderte von Millisekunden, um derentwillen im Lab der Cache auftaucht. Das Feld source in der Antwort
	// zeigt, dass die Daten von hier kamen und nicht aus dem Cache.
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

// setupAPI — der Dienst «Pass» selbst. Hier lebt die Cache-Logik, und hier liegt auch die Antwort
// auf die Frage «warum steht in der Antwort cache: off».
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// Der Cache wird durch die bloße Tatsache eingeschaltet, dass REDIS_ADDR vorhanden ist — jene Variable, die
	// cache-patch.yaml hinzufügt. Keine Variable — cache bleibt leer, alle Prüfungen
	// `if cache != nil` unten greifen nicht, und der Dienst arbeitet wie zuvor.
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("кеш включён: %s, срок жизни записи %d с", addr, ttl)
	} else {
		log.Printf("кеш выключен: REDIS_ADDR не задан, каждый запрос пойдёт в справочник")
	}

	// Ein separater Client mit vergrößertem Verbindungspool: sonst würde unter Last
	// die halbe Zeit in den Aufbau von TCP-Verbindungen zum Verzeichnis gehen,
	// und die Messung würde nicht die Latenz des Verzeichnisses zeigen, sondern unsere eigene Nachlässigkeit.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// Die Wurzel «/» — die Visitenkarte des Dienstes: Version, Pod, Knoten, Registry und Cache-Modus. Am Feld cache
	// sieht man sofort off oder redis, ohne in Logs zu schauen und ohne das Manifest zu zerlegen.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "неизвестно"),
			"namespace": env("POD_NAMESPACE", "неизвестно"),
			"registry":  env("IMAGE_REGISTRY", "не указан"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// Die Hauptadresse des Labs. Die Reihenfolge der Schritte: den Cache fragen, bei einem Fehlschlag ins Verzeichnis gehen,
	// die Antwort in den Cache legen. Alles, was man in diesem Lab misst, passiert auf diesen vierzig
	// Zeilen.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// Der Schlüssel im Cache ist «employee:» plus der Bezeichner. Das Präfix wird gebraucht, damit verschiedene Arten
		// von Einträgen nicht kollidieren: der Cache ist einer für die ganze Anwendung, und die Namen darin sind flach.
		key := "employee:" + id

		var emp employee
		fromCache := false

		// Schritt eins: den Cache fragen. Drei Ausgänge — ein Fehler, ein Treffer, ein Fehlschlag — werden
		// unterschiedlich behandelt, und der Unterschied zwischen ihnen ist hier grundlegend.
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// Der Cache ist nicht verfügbar — das ist kein Grund, dem Nutzer einen Fehler zurückzugeben.
				// Wir gehen ins Verzeichnis: langsam, aber richtig.
				log.Printf("кеш недоступен (%v), иду в справочник", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("в кеше по ключу %s лежит мусор, иду в справочник", key)
				}
			}
		}

		// Schritt zwei: ein Fehlschlag oder ein nicht verfügbarer Cache — wir gehen ins Verzeichnis. Langsam, aber es ist
		// die einzige Quelle der Wahrheit. Die Antwort legen wir in den Cache; wenn das Ablegen nicht geklappt hat,
		// braucht der Nutzer davon nichts zu wissen — er hat seine Antwort schon bekommen, nur wird
		// die nächste Anfrage wieder langsam sein.
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("справочник не ответил: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "справочник сотрудников недоступен",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("не удалось положить в кеш: %v", err)
					}
				}
			}
		}

		// Die Felder cached und took_ms sind das, worum es die ganze Zeit ging: an ihnen sieht man, ob die Anfrage
		// in den Cache getroffen hat oder nicht und wie viele Millisekunden das gekostet hat. Sie liest auch check.sh,
		// wenn es entscheidet, das Lab anzurechnen oder nicht.
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

// cacheMode übersetzt den internen Zustand in ein einziges Wort für die Antwort: off oder redis.
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — ein Gang ins Verzeichnis über HTTP. Der Bezeichner wird maskiert
// (url.QueryEscape): ohne das würde ein Leerzeichen oder «&» innerhalb der id die Anfrageadresse zerlegen.
// Der Rumpf der Antwort wird unbedingt geschlossen (defer), sonst gehen unter Last die Verbindungen aus.
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("справочник ответил %s", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
