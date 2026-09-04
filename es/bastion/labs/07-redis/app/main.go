// El servicio «Pase», la versión con caché. Un solo ejecutable, dos roles.
//
//	MODE=hr   — un stub del directorio legacy de empleados. Responde despacio,
//	            exactamente igual que el real: HR_DELAY es 800 ms por defecto.
//	MODE=api  — el propio servicio «Pase». Va al directorio y, si REDIS_ADDR
//	            está definido, primero mira en la caché.
//
// Un solo rol cubre ambos casos, porque debe haber una única imagen: dos imágenes casi
// idénticas en el registro son dos lugares donde puedes olvidarte de subir la versión.
//
// No hay dependencias externas, solo la biblioteca estándar. El cliente de Redis aquí
// es propio, de unas cincuenta líneas: el protocolo de Redis es textual y para GET/SET cabe
// en una sola función. En producción se usa una biblioteca ya hecha; aquí importa
// más que la compilación no vaya a internet a por paquetes.
//
// No hace falta saber leer Go: abajo está marcado dónde vive cada cosa. Primero los pequeños ayudantes,
// luego el cliente casero de Redis, luego los dos roles: el «directorio lento» y el «propio
// servicio». Lo principal, para lo que se ideó el laboratorio, ocurre en setupAPI, cerca del final del archivo.
//
// Tres convenciones del lenguaje, para no tropezar al leer:
//
//	func nombre(argumentos) (lo que devuelve) { ... } — una declaración de función;
//	una función a menudo devuelve varios valores a la vez, y el último de ellos es un error:
//	err == nil se lee como «salió bien», err != nil — «no salió bien»;
//	las líneas que empiezan por //, son comentarios, no afectan al funcionamiento del programa.
//
// El archivo se compila con el Dockerfile vecino, en la VM: docker build ... app/ — ver README.
package main

// La lista de bibliotecas que usa el archivo. Todas y cada una son estándar, de la distribución de Go.
// Ni una sola línea de terceros: la compilación no va a internet y no se romperá porque
// alguien haya eliminado el paquete de otra persona de un repositorio público.
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

// env lee una variable de entorno y, si está vacía o no definida, devuelve el valor
// de reserva. De ahí la propiedad que ves en los manifiestos: el comportamiento de la aplicación
// cambia con una línea en YAML y un reinicio del pod, no con una reconstrucción de la imagen.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — lo mismo para números. Si en la variable resulta no haber un dígito, la aplicación no
// se cae: escribe en el log y toma el valor de reserva. Una errata en el manifiesto no debe tumbar
// el servicio — debe ser visible en el log.
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

// Un error que envió el propio Redis (una línea que empieza por «-»): por ejemplo
// NOAUTH o WRONGTYPE. Es importante distinguirlo de uno de red: reconectar
// no soluciona una contraseña incorrecta, y los reintentos solo enmascaran la causa.
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — una única conexión TCP persistente a la caché más un candado mu, para que dos
// peticiones simultáneas no escriban en esta conexión de forma entremezclada. Mantenemos la conexión
// abierta: establecer una nueva en cada petición es más caro que la propia petición.
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked abre la conexión y, si hay una contraseña definida, se presenta de inmediato
// con el comando AUTH. El sufijo Locked en el nombre significa «llamar solo cuando el candado mu
// ya está tomado» — es un acuerdo entre estas funciones, no una propiedad del lenguaje.
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

// do ejecuta un comando y se reconecta una vez si la conexión se cortó.
// Devuelve el valor, un indicador «hay valor» y un error.
// Exactamente dos intentos, no diez: si Redis responde con un rechazo, los reintentos solo retrasan
// la respuesta al usuario y desdibujan la causa por los logs.
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
			return "", false, err // respondió el propio Redis — un reintento no ayudará
		}
		r.closeLocked() // red: la cortamos y probamos una vez más
	}
	return "", false, lastErr
}

// commandLocked envía el comando en la forma en que Redis lo entiende: primero
// cuántos trozos siguen, luego la longitud y el contenido de cada uno. Un plazo de tres segundos —
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

// readReplyLocked analiza la respuesta. El primer carácter de la línea dice qué es exactamente lo que llegó,
// y toda la función es el análisis de cinco casos. Aparte, es importante el «$-1»: no es una avería,
// sino «no hay tal clave», es decir, un fallo de caché normal.
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
		buf := make([]byte, n+2) // +2 por el \r\n final
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: непонятный ответ %q", line)
	}
}

// Get y SetTTL — el conjunto completo de comandos que usa el servicio. Nada más se
// requiere de la caché, por eso el cliente aquí cabe en una página.
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL guarda el valor y de inmediato le asigna un tiempo de vida. Con un solo comando, no
// SET más EXPIRE: entre dos comandos la conexión puede cortarse, y la clave
// se quedará en la caché para siempre.
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- datos

// employee — lo que el servicio devuelve al exterior y guarda en la caché. Las marcas `json:"id"` de la derecha
// definen los nombres de los campos en JSON: en Go los campos son visibles desde fuera solo con mayúscula, y en JSON
// se acostumbra a usar minúscula, y estas marcas los vinculan.
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// Los datos son inventados. No hay datos de personal reales en el banco de pruebas y no debe haberlos.
var surnames = []string{
	"Иванов И. И.", "Петрова А. С.", "Сидоров П. Н.", "Кузнецова М. В.",
	"Смирнов Д. А.", "Попова Е. К.", "Волков С. Ю.", "Морозова Н. Г.",
}

var departments = []string{
	"Служба безопасности", "Бухгалтерия", "Разработка",
	"Логистика", "Отдел кадров", "Административный отдел",
}

// Los datos son inventados, pero idénticos para el mismo identificador:
// de lo contrario, por la respuesta no se podría saber si es la caché o un viaje al directorio.
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

// writeJSON devuelve la respuesta: una cabecera con el tipo de contenido, el código de respuesta y el cuerpo.
// SetEscapeHTML(false) es necesario para que las letras rusas y las comillas no se conviertan
// en secuencias \u — de lo contrario habría que descifrar la respuesta a ojo.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("не удалось отдать ответ: %v", err)
	}
}

// employeeID extrae ?id= de la cadena de consulta. Un identificador vacío lo convertimos en «0»,
// para que la clave en la caché siempre tenga una forma definida y no se cree una clave
// «employee:» sin cola.
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- principal

// main — el punto de entrada: aquí comienza el trabajo del programa. Levanta el servidor HTTP, monta
// en él /healthz y, mirando MODE, uno de los dos roles. El rol se elige una vez
// al arrancar y no cambia durante la vida del pod.
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "неизвестно")

	mux := http.NewServeMux()
	// /healthz existe en ambos roles: aquí llama la sonda de readiness descrita en los manifiestos.
	// Responde siempre y no comprueba nada — la tarea de la sonda aquí es entender
	// que el proceso se ha levantado y escucha el puerto, no evaluar la salud del sistema.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// La bifurcación en dos roles. Un valor desconocido no es motivo para arrancar «de cualquier manera»:
	// nos caemos de inmediato y con un mensaje claro. Un arranque silencioso en el rol equivocado costaría
	// una hora de mirar logs.
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("неизвестный MODE=%q, допустимы hr и api", mode)
	}

	// ReadHeaderTimeout cierra la conexión si un cliente empezó una petición y se calló. Sin él
	// bastan unos pocos de esos «clientes» para ocupar el servidor entero sin pedir nada.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("режим %s, порт %s, под %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — un stub del directorio legacy. Su única particularidad es que
// es lento, y eso no es una casualidad sino la esencia de la tarea.
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q не разобрался, беру 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("справочник отвечает за %s", delay)

	// La única dirección de este rol. time.Sleep es todo el «sistema legacy»: esos mismos
	// cientos de milisegundos para los que aparece la caché en el laboratorio. El campo source en la respuesta
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

// setupAPI — el propio servicio «Pase». Aquí vive la lógica de la caché, y aquí también está la respuesta
// a la pregunta «por qué en la respuesta pone cache: off».
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// La caché se activa por el mero hecho de que REDIS_ADDR esté presente — la variable que añade
	// cache-patch.yaml. Si no hay variable — cache queda vacío, todas las comprobaciones
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
	// y la medición mostraría no la latencia del directorio, sino nuestro propio descuido.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// La raíz «/» — la tarjeta de presentación del servicio: versión, pod, nodo, registro y modo de caché. Por el campo cache
	// se ve de inmediato off o redis, sin mirar los logs ni analizar el manifiesto.
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

	// La dirección principal del laboratorio. El orden de acciones: preguntar a la caché, en caso de fallo ir al directorio,
	// poner la respuesta en la caché. Todo lo que mides en este laboratorio ocurre en estas cuarenta
	// líneas.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// La clave en la caché — «employee:» más el identificador. El prefijo hace falta para que distintos tipos
		// de registros no colisionen: la caché es una sola para toda la aplicación, y los nombres en ella son planos.
		key := "employee:" + id

		var emp employee
		fromCache := false

		// Paso uno: preguntar a la caché. Tres desenlaces — un error, un acierto, un fallo — se manejan
		// de forma diferente, y la diferencia entre ellos aquí es fundamental.
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// La caché no está disponible — eso no es motivo para devolver un error al usuario.
				// Vamos al directorio: despacio, pero correcto.
				log.Printf("кеш недоступен (%v), иду в справочник", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("в кеше по ключу %s лежит мусор, иду в справочник", key)
				}
			}
		}

		// Paso dos: un fallo o una caché no disponible — vamos al directorio. Despacio, pero es
		// la única fuente de verdad. Ponemos la respuesta en la caché; si ponerla no salió,
		// el usuario no tiene por qué saberlo — ya recibió su respuesta, solo que
		// la siguiente petición volverá a ser lenta.
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

		// Los campos cached y took_ms — para lo que se ideó todo: por ellos se ve si la petición acertó
		// en la caché o no y cuántos milisegundos costó. También los lee check.sh,
		// cuando decide si dar por superado el laboratorio o no.
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
// (url.QueryEscape): sin esto un espacio o «&» dentro del id desbaratarían la dirección de la petición.
// El cuerpo de la respuesta se cierra obligatoriamente (defer), de lo contrario bajo carga se agotarán las conexiones.
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
