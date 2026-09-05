// Lab 6 · Tu propio registro privado de imágenes. El servicio «Pase», versión de aprendizaje.
//
// QUÉ HACE ESTE PROGRAMA. Levanta un servidor web y responde en dos direcciones.
// La dirección /healthz devuelve un breve «ok»: por ella el clúster entiende que una réplica está viva
// y lista para recibir tráfico. La dirección / devuelve una respuesta pequeña en formato JSON (texto
// del tipo «campo: valor»), donde se enumera qué réplica y en qué nodo atendió la
// petición. Nada más: ni base de datos, ni disco, ni estado. Así está pensado — en esta lab
// lo interesante no es el código, sino el camino por el que llega al clúster:
// fuente -> imagen -> tu registro -> clúster.
//
// No hace falta saber leer este archivo en Go, basta con entender qué ocurre aquí;
// los comentarios de abajo están puestos contando con que ves Go por primera vez.
//
// No hay dependencias externas: se usa solo la biblioteca estándar, que
// llega junto con el compilador. Por eso la compilación no va a internet a por
// bibliotecas, y se puede construir la imagen allí donde la salida al exterior está cerrada, — y precisamente
// con esto empieza toda la lab.
//
// No se compila directamente, sino a través del Dockerfile vecino, con el comando
// docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
//
// package main — así en Go se marca un programa que se puede ejecutar (a diferencia
// de una biblioteca). El punto de entrada al ejecutarse es la función main al final del archivo.
package main

// Qué tomamos de la biblioteca estándar:
//   encoding/json — armar la respuesta en formato JSON
//   log           — escribir mensajes; en el contenedor van a la salida estándar,
//                   de donde los recoge kubectl logs. No hay archivos de logs dentro,
//                   y no hace falta crearlos — es lo normal para los contenedores
//   net/http      — el propio servidor web
//   os            — leer las variables de entorno
//   time          — la marca de tiempo en la respuesta y el timeout del servidor
import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// La forma de la respuesta: el conjunto de campos que la aplicación comunica sobre sí misma. Casi todos ellos —
// es lo que la aplicación conoce del clúster: no los calculamos ni los adivinamos, el clúster
// mismo los pone en las variables de entorno (ver passes.yaml, el bloque env y la downward API).
//
// El texto entre comillas invertidas a la derecha es el nombre del campo en el JSON final. Sin él el campo iría
// a la respuesta como Namespace, y no como namespace; la comprobación en check.sh busca el «pod» en minúscula.
type identity struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Registry  string `json:"registry"`
	Time      string `json:"time"`
}

// Leer una variable de entorno, y si no existe o está vacía — devolver un valor
// de reserva. Hace falta para que el programa se pueda ejecutar también fuera del clúster, sin una sola
// configuración: no se caerá, sino que escribirá honestamente «desconocido» en la respuesta.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Punto de entrada: con esta función empieza el trabajo del programa.
func main() {
	// En qué puerto escuchar. El puerto se puede sobrescribir con la variable PORT, sin recompilar
	// la imagen, pero por defecto es 8080 — el mismo número que en passes.yaml (containerPort)
	// y en el Dockerfile (EXPOSE). Si divergen — el Service llamará a una puerta cerrada.
	port := env("PORT", "8080")

	// La tabla de rutas: qué dirección atiende qué manejador.
	mux := http.NewServeMux()

	// Comprobación de disponibilidad. El clúster llama aquí y no envía tráfico a la réplica
	// hasta que recibe una respuesta. Responde siempre y rápido, sin comprobar nada:
	// la aplicación no tiene nada que comprobar, no tiene ni base de datos ni disco.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// La respuesta principal. Armamos esos mismos campos y los devolvemos en un único JSON. Los valores se leen
	// en cada petición, por eso la segunda réplica del servicio responderá con su propio nombre de pod —
	// por ese nombre en la lab se ve que las réplicas son realmente dos.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body := identity{
			Service:   "passes-api",
			Version:   env("APP_VERSION", "v1"),
			Pod:       env("POD_NAME", "desconocido"),
			Node:      env("NODE_NAME", "desconocido"),
			Namespace: env("POD_NAMESPACE", "desconocido"),
			Registry:  env("IMAGE_REGISTRY", "sin especificar"),
			Time:      time.Now().UTC().Format(time.RFC3339),
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		// SetEscapeHTML(false), de lo contrario el cirílico y caracteres como < se irían a \uXXXX
		// y la respuesta se volvería ilegible en la terminal.
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("no se pudo entregar la respuesta: %v", err)
		}
	})

	// Configuración del servidor. ReadHeaderTimeout — cuánto esperar las cabeceras de la petición, antes
	// de cortar la conexión. Los cinco segundos no son por velocidad: sin este timeout
	// las conexiones abiertas y abandonadas se acumulan hasta comerse la memoria del contenedor,
	// y la memoria está limitada por el límite del manifiesto.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Lo primero que verás en kubectl logs. La línea hace falta para distinguir «la aplicación
	// no arrancó» de «arrancó, pero no responde» — son diagnósticos distintos.
	log.Printf("passes-api %s escucha el puerto %s, pod %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "desconocido"))
	// Arrancamos el servidor y trabajamos hasta que nos detengan. Si el puerto está ocupado o el servidor
	// se cayó — escribimos la causa y salimos con error. El clúster verá el proceso terminado
	// y levantará una réplica de nuevo; no hace falta arreglar el reinicio dentro del programa.
	log.Fatal(srv.ListenAndServe())
}
