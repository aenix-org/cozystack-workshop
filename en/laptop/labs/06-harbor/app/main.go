// Lab 6 · Your own private image registry. The "Pass" service, training version.
//
// WHAT THIS PROGRAM DOES. It starts a web server and answers on two addresses.
// The /healthz address returns a short "ok": from it the cluster understands that the
// replica is alive and ready to accept traffic. The / address returns a small response in
// JSON format (text of the form "field: value"), where it lists which replica and on which
// node served the request. Nothing more: no database, no disk, no state. That is by design — in
// this lab the interesting part is not the code, but the path by which it gets into the cluster:
// source -> image -> your own registry -> cluster.
//
// You do not need to be able to read this Go file, it is enough to understand what happens here;
// the comments below are written on the assumption that you are seeing Go for the first time.
//
// There are no external dependencies: only the standard library is used, which
// comes together with the compiler. Therefore the build does not go to the internet for
// libraries, and you can build the image where outbound access is closed off, — and that
// is exactly where the whole lab begins.
//
// It is built not directly, but through the neighboring Dockerfile, with the command
// docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
//
// package main — this is how in Go you mark a program that can be run (as opposed
// to a library). The entry point when running is the main function at the very bottom of the file.
package main

// What we take from the standard library:
//   encoding/json — assemble the response in JSON format
//   log           — write messages; in a container they go to standard output,
//                   from where kubectl logs picks them up. There are no log files inside,
//                   and there is no need to create them — this is normal for containers
//   net/http      — the web server itself
//   os            — read environment variables
//   time          — timestamp in the response and server timeout
import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// The shape of the response: a set of fields that the application reports about itself. Almost all of them —
// are what the application learns from the cluster: we do not compute or guess them, the cluster
// itself puts them into environment variables (see passes.yaml, the env block and downward API).
//
// The text in backticks on the right is the field name in the final JSON. Without it the field would go
// into the response as Namespace, not as namespace; the check in check.sh looks for the lowercase "pod".
type identity struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Registry  string `json:"registry"`
	Time      string `json:"time"`
}

// Read an environment variable, and if it is missing or empty — return a fallback
// value. It is needed so that the program can be run outside the cluster too, without a single
// setting: it will not crash, but honestly write "неизвестно" in the response.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Entry point: the program's work begins with this function.
func main() {
	// Which port to listen on. The port can be overridden with the PORT variable, without rebuilding
	// the image, but by default it is 8080 — the same number as in passes.yaml (containerPort)
	// and in the Dockerfile (EXPOSE). If they diverge — the Service will knock on a closed door.
	port := env("PORT", "8080")

	// The routing table: which address which handler serves.
	mux := http.NewServeMux()

	// Readiness check. The cluster knocks here and does not let traffic onto the replica,
	// until it gets a response. It answers always and fast, checking nothing:
	// the application has nothing to check, it has neither a database nor a disk.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// The main response. We assemble those very fields and hand them out as a single JSON. The values are read
	// on every request, so the second replica of the service will answer with its own pod name —
	// by that name in the lab you can see that there really are two replicas.
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
		// SetEscapeHTML(false), otherwise Cyrillic and symbols like < would go into \uXXXX
		// and the response would become unreadable in the terminal.
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("не удалось отдать ответ: %v", err)
		}
	})

	// Server settings. ReadHeaderTimeout — how long to wait for the request headers, before
	// cutting off the connection. The five seconds are there not for speed: without this timeout
	// opened and abandoned connections pile up until they eat up the container's memory,
	// and the memory is limited by the limit from the manifest.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// The first thing you will see in kubectl logs. The line is needed to distinguish "the application
	// did not start" from "started, but does not respond" — these are different diagnoses.
	log.Printf("passes-api %s слушает порт %s, под %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "неизвестно"))
	// We start the server and work until we are stopped. If the port is taken or the server
	// crashed — we write the reason and exit with an error. The cluster will see the finished process
	// and bring up the replica anew; there is no need to fix the restart inside the program.
	log.Fatal(srv.ListenAndServe())
}
