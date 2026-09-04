// El servicio «Пропуск», versión con caché. Un único ejecutable, dos roles.
//
//	MODE=hr   — un stub del directorio legado de empleados. Responde despacio,
//	            exactamente como lo hace el real: HR_DELAY es 800 ms por defecto.
//	MODE=api  — el propio servicio «Пропуск». Consulta el directorio y, si REDIS_ADDR
//	            está definida, primero mira en la caché.
//
// Un solo rol para ambos casos, porque la imagen debe ser única: dos imágenes casi idénticas
// en el registro son dos lugares donde se puede olvidar subir la versión.
//
// No hay dependencias externas, solo la biblioteca estándar. El cliente de Redis aquí
// es propio, de cincuenta líneas: el protocolo de Redis es textual y para GET/SET cabe
// en una función. En producción se usa una biblioteca ya hecha; aquí importa más que
// la compilación no vaya a internet a por paquetes.
//
// No hace falta saber leer Go: abajo está marcado dónde está cada cosa. Primero los pequeños ayudantes,
// luego el cliente de Redis casero, luego los dos roles: el «directorio lento» y el «propio
// servicio». Lo principal, para lo que se ideó el laboratorio, ocurre en setupAPI, cerca del final del archivo.
//
// Tres convenciones del lenguaje, para no tropezar al leer:
//
//	func nombre(argumentos) (lo que devuelve) { ... } — una declaración de función;
//	una función a menudo devuelve varios valores a la vez, y el último de ellos es un error:
//	err == nil se lee «salió bien», err != nil — «no salió bien»;
//	las líneas que empiezan con //, son comentarios, no afectan al funcionamiento del programa.
//
// El archivo se compila con el Dockerfile vecino, en el portátil: docker build ... app/ — véase README.
package main

// La lista de bibliotecas que usa el archivo. Todas y cada una son estándar, de la distribución de Go.
// Ni una sola línea de terceros: la compilación no va a internet y no se romperá porque
// alguien haya eliminado el paquete ajeno de un repositorio público.
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

// ---------------------------------------------------------------- entorno

// env lee una variable de entorno y, si está vacía o sin definir, devuelve el valor
// de reserva. De ahí la propiedad que ves en los manifiestos: el comportamiento de la aplicación
// cambia con una línea en YAML y un reinicio del pod, no con una recompilación de la imagen.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — lo mismo para números. Si la variable resulta no ser un número, la aplicación no
// se cae: escribe en el log y toma el valor de reserva. Una errata en el manifiesto no debe tumbar
// el servicio: debe ser visible en el log.
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

// Un error enviado por el propio Redis (una línea que empieza con «-»): por ejemplo
// NOAUTH o WRONGTYPE. Distinguirlo de uno de red importa: reconectar
// no arreglará una contraseña incorrecta, y los reintentos solo enmascaran la causa.
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — una única conexión TCP persistente a la caché más un candado mu, para que dos
// peticiones concurrentes no escriban en esta conexión mezcladas. Mantenemos la conexión
// abierta: establecer una nueva en cada petición cuesta más que la propia petición.
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked abre la conexión y, si hay contraseña definida, se presenta de inmediato
// con el comando AUTH. El sufijo Locked en el nombre significa «llamar solo cuando el candado mu
// ya está tomado»: es un acuerdo entre estas funciones, no una propiedad del lenguaje.
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

// do ejecuta un comando y reconecta una vez si la conexión se cortó.
// Devuelve el valor, un indicador «valor presente» y un error.
// Los intentos son exactamente dos, no diez: si Redis responde con una negativa, los reintentos solo retrasan
// la respuesta al usuario y difuminan la causa por los logs.
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
			return "", false, err // el propio Redis respondió — un reintento no ayudará
		}
		r.closeLocked() // red: la cortamos y probamos otra vez
	}
	return "", false, lastErr
}

// commandLocked envía el comando en la forma que Redis entiende: primero
// cuántos trozos siguen, luego la longitud y el contenido de cada uno. El plazo de tres segundos es
// para que una caché colgada no retrase la respuesta más que un viaje al propio directorio.
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

// readReplyLocked analiza la respuesta. El primer carácter de la línea dice qué ha llegado exactamente,
// y toda la función es el manejo de cinco casos. El caso «$-1» es aparte importante: no es una avería,
// sino «no existe tal clave», es decir, un fallo de caché ordinario.
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
	case '+', ':': // una cadena simple o un número
		return line[1:], true, nil
	case '-': // un error del servidor
		return "", false, &redisError{msg: line[1:]}
	case '$': // una cadena de longitud conocida; -1 significa «no hay clave»
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // un fallo de caché no es un error
		}
		buf := make([]byte, n+2) // +2 para los \r\n finales
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: непонятный ответ %q", line)
	}
}

// Get y SetTTL — todo el conjunto de comandos que usa el servicio. Nada más se
// requiere de la caché, por eso el cliente aquí cabe en una página.
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL pone el valor y asigna de inmediato un tiempo de vida. Con un solo comando, no
// SET más EXPIRE: entre dos comandos la conexión puede cortarse, y la clave
// quedaría en la caché para siempre.
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- datos

// employee — lo que el servicio devuelve al exterior y pone en la caché. Las etiquetas `json:"id"` a la derecha
// fijan los nombres de los campos en JSON: en Go los campos son visibles desde fuera solo con mayúscula inicial, mientras que en JSON
// se acostumbra a usar minúscula, y estas etiquetas los vinculan.
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// Los datos son inventados. No hay datos de personal reales en el banco de pruebas de entrenamiento, ni debe haberlos.
var surnames = []string{
	"Иванов И. И.", "Петрова А. С.", "Сидоров П. Н.", "Кузнецова М. В.",
	"Смирнов Д. А.", "Попова Е. К.", "Волков С. Ю.", "Морозова Н. Г.",
}

var departments = []string{
	"Служба безопасности", "Бухгалтерия", "Разработка",
	"Логистика", "Отдел кадров", "Административный отдел",
}

// Los datos son inventados, pero iguales para el mismo identificador:
// de lo contrario no se podría distinguir por la respuesta si es la caché o un viaje al directorio.
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

// writeJSON envía la respuesta: la cabecera con el tipo de contenido, el código de respuesta y el cuerpo.
// SetEscapeHTML(false) es necesario para que las letras rusas y las comillas no se conviertan
// en secuencias \u, de lo contrario habría que descifrar la respuesta a ojo.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("не удалось отдать ответ: %v", err)
	}
}

// employeeID saca ?id= de la cadena de consulta. Un identificador vacío se convierte en «0»,
// para que la clave en la caché siempre tenga una forma definida y no se cree ninguna clave
// «employee:» sin cola.
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- principal

// main — el punto de entrada: aquí empieza el trabajo del programa. Levanta un servidor HTTP, cuelga
// /healthz en él y, mirando MODE, uno de los dos roles. El rol se elige una vez
// al arranque y no cambia durante la vida del pod.
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "неизвестно")

	mux := http.NewServeMux()
	// /healthz existe en ambos roles: la sonda de readiness descrita en los manifiestos llama aquí.
	// Siempre responde y no comprueba nada: el trabajo de la sonda aquí es indicar
	// que el proceso arrancó y está escuchando en el puerto, no evaluar la salud del sistema.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// La bifurcación en dos roles. Un valor desconocido no es motivo para arrancar «de cualquier manera»:
	// nos caemos de inmediato y con un mensaje claro. Un arranque silencioso en el rol equivocado costaría
	// una hora mirando logs.
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("неизвестный MODE=%q, допустимы hr и api", mode)
	}

	// ReadHeaderTimeout cierra la conexión si un cliente empezó una petición y se quedó callado. Sin él
	// bastan unos pocos «clientes» así para ocupar todo el servidor sin pedir nada.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("режим %s, порт %s, под %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — un stub del directorio legado. Su única particularidad es que
// es lento, y esto no es un accidente sino la esencia de la tarea.
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q не разобрался, беру 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("справочник отвечает за %s", delay)

	// La única dirección de este rol. time.Sleep es todo el «sistema legado»: esos mismos
	// cientos de milisegundos por los que aparece la caché en el laboratorio. El campo source en la respuesta
	// muestra que los datos vinieron de aquí, no de la caché.
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

// setupAPI — el propio servicio «Пропуск». Aquí vive la lógica de la caché, y aquí también está la respuesta
// a la pregunta «por qué la respuesta dice cache: off».
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// La caché se activa por la sola presencia de REDIS_ADDR — la variable que
	// añade cache-patch.yaml. No hay variable — cache queda vacío, todas las comprobaciones
	// `if cache != nil` de abajo no se disparan, y el servicio funciona como funcionaba.
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("кеш включён: %s, срок жизни записи %d с", addr, ttl)
	} else {
		log.Printf("кеш выключен: REDIS_ADDR не задан, каждый запрос пойдёт в справочник")
	}

	// Un cliente aparte con un pool de conexiones ampliado: de lo contrario, bajo carga
	// la mitad del tiempo se iría en establecer conexiones TCP al directorio,
	// y la medición mostraría no la latencia del directorio sino nuestro propio descuido.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// La raíz «/» — la tarjeta de visita del servicio: versión, pod, nodo, registro y modo de caché. Por el campo cache
	// se ve de inmediato off o redis, sin mirar en los logs ni analizar el manifiesto.
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

	// La dirección principal del laboratorio. El orden de acciones: preguntar a la caché, en un fallo ir al directorio,
	// poner la respuesta en la caché. Todo lo que mides en este laboratorio ocurre en estas cuarenta
	// líneas.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// La clave en la caché — «employee:» más el identificador. El prefijo es necesario para que distintos tipos
		// de registros no colisionen: la caché es una para toda la aplicación, y los nombres en ella son planos.
		key := "employee:" + id

		var emp employee
		fromCache := false

		// Paso uno: preguntar a la caché. Tres desenlaces — un error, un acierto, un fallo — se manejan
		// de forma distinta, y la diferencia entre ellos es fundamental aquí.
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// La caché no está disponible — eso no es motivo para devolver un error al usuario.
				// Vamos al directorio: lento, pero correcto.
				log.Printf("кеш недоступен (%v), иду в справочник", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("в кеше по ключу %s лежит мусор, иду в справочник", key)
				}
			}
		}

		// Paso dos: un fallo o una caché no disponible — vamos al directorio. Lento, pero es
		// la única fuente de verdad. Ponemos la respuesta en la caché; si ponerla falló,
		// el usuario no necesita saberlo — ya obtuvo su respuesta, solo que
		// la próxima petición volverá a ser lenta.
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

		// Los campos cached y took_ms — para lo que se inició todo esto: por ellos se ve si la petición acertó
		// en la caché o no y cuántos milisegundos costó. check.sh también los lee
		// cuando decide si contar el laboratorio como aprobado o no.
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

// cacheMode traduce el estado interno a una sola palabra para la respuesta: off o redis.
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — un viaje al directorio por HTTP. El identificador se escapa
// (url.QueryEscape): sin esto un espacio o «&» dentro de id rompería la URL de la petición.
// El cuerpo de la respuesta siempre se cierra (defer), de lo contrario bajo carga se agotarían las conexiones.
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
