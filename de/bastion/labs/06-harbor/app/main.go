// Lab 6 · Deine eigene private Image-Registry. Der Dienst «Ausweis», Lernversion.
//
// WAS DIESES PROGRAMM MACHT. Es startet einen Webserver und antwortet auf zwei Adressen.
// Die Adresse /healthz liefert ein kurzes «ok»: daran erkennt der Cluster, dass eine Kopie lebt
// und bereit ist, Verkehr anzunehmen. Die Adresse / liefert eine kleine Antwort im JSON-Format (Text
// der Form «Feld: Wert»), in der aufgeführt ist, welche Kopie und auf welchem Knoten die
// Anfrage bedient hat. Mehr nicht: keine Datenbank, keine Platte, kein Zustand. So ist es beabsichtigt — in diesem Lab
// ist nicht der Code interessant, sondern der Weg, auf dem er in den Cluster gelangt:
// Quelltext -> Image -> eigene Registry -> Cluster.
//
// Diese Go-Datei lesen zu können ist nicht nötig, es genügt zu verstehen, was hier passiert;
// die Kommentare unten sind darauf ausgelegt, dass du Go zum ersten Mal siehst.
//
// Externe Abhängigkeiten gibt es keine: es wird nur die Standardbibliothek verwendet, die
// zusammen mit dem Compiler kommt. Deshalb geht der Build nicht ins Internet, um
// Bibliotheken zu holen, und man kann das Image dort bauen, wo der Ausgang nach außen zu ist, — und genau
// damit beginnt das ganze Lab.
//
// Gebaut wird nicht direkt, sondern über das benachbarte Dockerfile, mit dem Befehl
// docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
//
// package main — so kennzeichnet man in Go ein Programm, das man ausführen kann (im Gegensatz
// zu einer Bibliothek). Der Einstiegspunkt beim Start ist die Funktion main ganz unten in der Datei.
package main

// Was wir aus der Standardbibliothek nehmen:
//   encoding/json — die Antwort im JSON-Format zusammenbauen
//   log           — Meldungen schreiben; im Container gehen sie in die Standardausgabe,
//                   von wo kubectl logs sie abholt. Logdateien gibt es drinnen nicht,
//                   und man muss auch keine anlegen — das ist normal für Container
//   net/http      — der Webserver selbst
//   os            — Umgebungsvariablen lesen
//   time          — Zeitstempel in der Antwort und das Server-Timeout
import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// Die Form der Antwort: die Menge der Felder, die die Anwendung über sich mitteilt. Fast alle davon —
// das ist, was die Anwendung vom Cluster erfährt: wir berechnen und raten sie nicht, der Cluster
// legt sie selbst in Umgebungsvariablen (siehe passes.yaml, Block env und Downward API).
//
// Der Text in Backticks rechts ist der Feldname im fertigen JSON. Ohne ihn würde das Feld
// als Namespace statt als namespace in die Antwort wandern; die Prüfung in check.sh sucht nach kleingeschriebenem «pod».
type identity struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Registry  string `json:"registry"`
	Time      string `json:"time"`
}

// Eine Umgebungsvariable lesen, und falls sie fehlt oder leer ist — einen Ersatz-
// wert zurückgeben. Nötig, damit das Programm auch außerhalb des Clusters gestartet werden kann, ohne eine einzige
// Einstellung: es stürzt nicht ab, sondern schreibt ehrlich «неизвестно» in die Antwort.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Einstiegspunkt: mit dieser Funktion beginnt die Arbeit des Programms.
func main() {
	// Auf welchem Port lauschen. Der Port lässt sich mit der Variable PORT überschreiben, ohne das
	// Image neu zu bauen, aber standardmäßig ist es 8080 — dieselbe Zahl wie in passes.yaml (containerPort)
	// und im Dockerfile (EXPOSE). Gehen sie auseinander — klopft der Service an eine verschlossene Tür.
	port := env("PORT", "8080")

	// Die Routing-Tabelle: welche Adresse von welchem Handler bedient wird.
	mux := http.NewServeMux()

	// Bereitschaftsprüfung. Der Cluster klopft hier an und lässt keinen Verkehr auf die Kopie,
	// bis er eine Antwort bekommt. Sie antwortet immer und schnell, ohne etwas zu prüfen:
	// die Anwendung hat nichts zu prüfen, sie hat weder Datenbank noch Platte.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// Die Hauptantwort. Wir bauen genau jene Felder zusammen und geben sie als ein JSON aus. Die Werte werden
	// bei jeder Anfrage gelesen, deshalb antwortet die zweite Kopie des Dienstes mit ihrem eigenen Pod-Namen —
	// an diesem Namen sieht man im Lab, dass es tatsächlich zwei Kopien gibt.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body := identity{
			Service:   "passes-api",
			Version:   env("APP_VERSION", "v1"),
			Pod:       env("POD_NAME", "неизвестно"),
			Node:      env("NODE_NAME", "неизвестно"),
			Namespace: env("POD_NAMESPACE", "неизвестно"),
			Registry:  env("IMAGE_REGISTRY", "не указан"),
			Time:      time.Now().UTC().Format(time.RFC3339),
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		// SetEscapeHTML(false), sonst würden Kyrillisch und Zeichen wie < in \uXXXX wandern
		// und die Antwort würde im Terminal unlesbar.
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("не удалось отдать ответ: %v", err)
		}
	})

	// Server-Einstellungen. ReadHeaderTimeout — wie lange auf die Anfrage-Header gewartet wird, bevor
	// die Verbindung abgebrochen wird. Die fünf Sekunden sind nicht der Geschwindigkeit wegen: ohne dieses Timeout
	// häufen sich offene und liegengelassene Verbindungen an, bis sie den Speicher des Containers auffressen,
	// und der Speicher ist durch das Limit aus dem Manifest begrenzt.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Das Erste, was du in kubectl logs siehst. Die Zeile ist nötig, um «die Anwendung
	// ist nicht gestartet» von «gestartet, aber antwortet nicht» zu unterscheiden — das sind verschiedene Diagnosen.
	log.Printf("passes-api %s слушает порт %s, под %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "неизвестно"))
	// Wir starten den Server und arbeiten, bis wir gestoppt werden. Ist der Port belegt oder der Server
	// abgestürzt — schreiben wir den Grund und beenden mit einem Fehler. Der Cluster sieht den beendeten Prozess
	// und bringt die Kopie erneut hoch; den Neustart innerhalb des Programms zu reparieren ist nicht nötig.
	log.Fatal(srv.ListenAndServe())
}
