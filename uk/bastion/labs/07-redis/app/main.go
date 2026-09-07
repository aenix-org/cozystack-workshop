// Сервіс «Перепустка», версія з кешем. Один виконуваний файл, дві ролі.
//
//	MODE=hr   — заглушка легасі-довідника співробітників. Відповідає повільно,
//	            рівно так, як відповідає справжній: HR_DELAY за замовчуванням 800 мс.
//	MODE=api  — сам сервіс «Перепустка». Ходить у довідник, а якщо задано REDIS_ADDR,
//	            спочатку дивиться в кеш.
//
// Одна роль на обидва випадки, тому що образ має бути один: два майже однакові
// образи в реєстрі — це два місця, де можна забути оновити версію.
//
// Зовнішніх залежностей немає, тільки стандартна бібліотека. Клієнт Redis тут
// свій, на п'ятдесят рядків, — протокол Redis текстовий і для GET/SET вміщується
// в одну функцію. У бою беруть готову бібліотеку; тут важливіше, щоб збірка
// не ходила в інтернет за пакетами.
//
// Читати на Go вміти не потрібно: нижче розмічено, де що лежить. Спочатку дрібні помічники,
// потім саморобний клієнт до Redis, потім дві ролі — «повільний довідник» і «сам
// сервіс». Головне, заради чого затіяна лаба, відбувається в setupAPI, ближче до кінця файлу.
//
// Три домовленості мови, щоб не спотикатися під час читання:
//
//	func ім'я(аргументи) (що поверне) { ... } — оголошення функції;
//	функція часто повертає кілька значень одразу, і останнє з них — помилка:
//	err == nil читається «обійшлося», err != nil — «не обійшлося»;
//	рядки, що починаються з //, — коментарі, на роботу програми вони не впливають.
//
// Збирається файл сусіднім Dockerfile, на віртуалці: docker build ... app/ — див. README.
package main

// Список бібліотек, якими користується файл. Усі до одної — стандартні, з поставки Go.
// Жодного стороннього рядка: збірка не ходить в інтернет і не зламається через те, що
// чийсь чужий пакет видалили з публічного репозиторію.
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

// ---------------------------------------------------------------- оточення

// env читає змінну оточення і, якщо та порожня або не задана, повертає запасне
// значення. Звідси властивість, яку ви бачите в маніфестах: поведінка застосунку
// змінюється рядком у YAML і перезапуском Pod, а не перезбіркою образу.
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — те саме для чисел. Якщо у змінній опинилася не цифра, застосунок не
// падає: пише в лог і бере запасне значення. Друкарська помилка в маніфесті не має класти
// сервіс — вона має бути помітна в лозі.
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("значення %s=%q не число, беру %d", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// Помилка, яку надіслав сам Redis (рядок, що починається з «-»): наприклад
// NOAUTH або WRONGTYPE. Відрізняти її від мережевої важливо: перепідключення
// від невірного пароля не рятує, а спроби тільки маскують причину.
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — одне постійне TCP-з'єднання до кешу плюс замок mu, щоб два
// одночасні запити не писали в це з'єднання впереміш. З'єднання тримаємо
// відкритим: встановлювати нове на кожен запит дорожче, ніж сам запит.
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked відкриває з'єднання і, якщо пароль заданий, тут же представляється
// командою AUTH. Суфікс Locked в імені означає «викликати тільки тоді, коли замок mu
// уже взято» — це домовленість між цими функціями, а не властивість мови.
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

// do виконує команду і один раз перепідключається, якщо обірвалося з'єднання.
// Повертає значення, ознаку «значення є» і помилку.
// Спроб рівно дві, не десять: якщо Redis відповідає відмовою, повтори тільки затримають
// відповідь користувачеві і розмажуть причину по логах.
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
			return "", false, err // відповів сам Redis — повтор не допоможе
		}
		r.closeLocked() // мережа: рвемо і пробуємо ще раз
	}
	return "", false, lastErr
}

// commandLocked відправляє команду в тому вигляді, в якому її розуміє Redis: спочатку
// скільки далі йде шматків, потім довжина і вміст кожного. Дедлайн у три секунди —
// щоб завислий кеш не затримав відповідь довше, ніж похід у сам довідник.
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

// readReplyLocked розбирає відповідь. Перший символ рядка каже, що саме прийшло,
// і вся функція — це розбір п'яти випадків. Окремо важливий «$-1»: це не поломка,
// а «такого ключа немає», тобто звичайний промах кешу.
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: порожня відповідь")
	}
	switch line[0] {
	case '+', ':': // простий рядок або число
		return line[1:], true, nil
	case '-': // помилка від сервера
		return "", false, &redisError{msg: line[1:]}
	case '$': // рядок відомої довжини; -1 означає «ключа немає»
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // промах кешу — це не помилка
		}
		buf := make([]byte, n+2) // +2 на завершальні \r\n
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: незрозуміла відповідь %q", line)
	}
}

// Get і SetTTL — весь набір команд, якими користується сервіс. Більше від кешу нічого
// не потрібно, тому і клієнт тут вміщується на сторінку.
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL кладе значення і одразу призначає термін життя. Однією командою, а не
// SET плюс EXPIRE: між двома командами з'єднання може обірватися, і ключ
// залишиться в кеші назавжди.
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- дані

// employee — те, що сервіс віддає назовні і кладе в кеш. Позначки `json:"id"` праворуч
// задають імена полів у JSON: у Go поля видно ззовні тільки з великої літери, а в JSON
// прийнято з маленької, і ці позначки їх зв'язують.
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// Дані вигадані. Справжніх кадрових відомостей у тестовому середовищі немає і бути не повинно.
var surnames = []string{
	"Коваленко І. І.", "Ткаченко А. С.", "Сидоренко П. М.", "Бондаренко М. В.",
	"Мельник Д. А.", "Попович О. К.", "Вовченко С. Ю.", "Мороз Н. Г.",
}

var departments = []string{
	"Служба безпеки", "Бухгалтерія", "Розробка",
	"Логістика", "Відділ кадрів", "Адміністративний відділ",
}

// Дані вигадані, але однакові для одного й того самого ідентифікатора:
// інакше по відповіді не можна було б зрозуміти, кеш це чи похід у довідник.
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

// writeJSON віддає відповідь: заголовок з типом вмісту, код відповіді і тіло.
// SetEscapeHTML(false) потрібен, щоб російські літери і лапки не перетворювалися
// в \u-послідовності, — інакше відповідь доведеться розшифровувати очима.
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("не вдалося віддати відповідь: %v", err)
	}
}

// employeeID дістає ?id= з рядка запиту. Порожній ідентифікатор перетворюємо на «0»,
// щоб у ключа в кеші завжди була визначена форма і не заводилося ключа
// «employee:» без хвоста.
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- головне

// main — точка входу: з неї починається робота програми. Піднімає HTTP-сервер, вішає
// на нього /healthz і, дивлячись на MODE, одну з двох ролей. Роль вибирається один раз
// на старті і протягом життя Pod не змінюється.
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "невідомо")

	mux := http.NewServeMux()
	// /healthz є в обох ролях: сюди стукається проба готовності, описана в маніфестах.
	// Він відповідає завжди і нічого не перевіряє — задача проби тут у тому, щоб зрозуміти,
	// що процес піднявся і слухає порт, а не в тому, щоб оцінити здоров'я системи.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// Розвилка на дві ролі. Невідоме значення — не привід запуститися «як-небудь»:
	// падаємо одразу і з виразним повідомленням. Мовчазний запуск не в тій ролі коштував би
	// години розглядання логів.
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("невідомий MODE=%q, дозволені hr і api", mode)
	}

	// ReadHeaderTimeout закриває з'єднання, якщо клієнт почав запит і замовк. Без нього
	// вистачить кількох таких «клієнтів», щоб зайняти сервер цілком, нічого не запитавши.
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("режим %s, порт %s, Pod %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — заглушка легасі-довідника. Єдина її особливість у тому,
// що вона повільна, і це не випадковість, а суть задачі.
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q не розібрався, беру 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("довідник відповідає за %s", delay)

	// Єдина адреса цієї ролі. time.Sleep і є вся «легасі-система»: ті самі
	// сотні мілісекунд, заради яких у лабі з'являється кеш. Поле source у відповіді
	// показує, що дані прийшли звідси, а не з кешу.
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

// setupAPI — сам сервіс «Перепустка». Тут живе логіка кешу, і тут же лежить відповідь
// на питання «чому у відповіді написано cache: off».
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// Кеш вмикається самим фактом наявності REDIS_ADDR — тієї змінної, яку додає
	// cache-patch.yaml. Змінної немає — cache залишається порожнім, усі перевірки
	// `if cache != nil` нижче не спрацьовують, і сервіс працює як працював.
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("кеш увімкнено: %s, термін життя запису %d с", addr, ttl)
	} else {
		log.Printf("кеш вимкнено: REDIS_ADDR не задано, кожен запит піде в довідник")
	}

	// Окремий клієнт зі збільшеним пулом з'єднань: інакше під навантаженням
	// половина часу піде на встановлення TCP-з'єднань до довідника,
	// і замір покаже не затримку довідника, а нашу власну неакуратність.
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// Корінь «/» — візитка сервісу: версія, Pod, вузол, реєстр і режим кешу. По полю cache
	// одразу видно off або redis, не заглядаючи в логи і не розбираючи маніфест.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "невідомо"),
			"namespace": env("POD_NAMESPACE", "невідомо"),
			"registry":  env("IMAGE_REGISTRY", "не вказано"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// Головна адреса лаби. Порядок дій: спитати кеш, при промаху сходити в довідник,
	// покласти відповідь у кеш. Усе, що ви вимірюєте в цій лабі, відбувається на цих сорока
	// рядках.
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// Ключ у кеші — «employee:» плюс ідентифікатор. Приставка потрібна, щоб різні види
		// записів не зіткнулися: кеш один на весь застосунок, а імена в ньому плоскі.
		key := "employee:" + id

		var emp employee
		fromCache := false

		// Крок перший: спитати кеш. Три результати — помилка, попадання, промах — розбираються
		// по-різному, і різниця між ними тут принципова.
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// Кеш недоступний — це не привід віддавати помилку користувачеві.
				// Ідемо в довідник: повільно, але правильно.
				log.Printf("кеш недоступний (%v), йду в довідник", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("у кеші за ключем %s лежить сміття, йду в довідник", key)
				}
			}
		}

		// Крок другий: промах або недоступний кеш — ідемо в довідник. Повільно, але це
		// єдине джерело правди. Відповідь кладемо в кеш; якщо покласти не вийшло,
		// користувачеві про це знати ні до чого — він свою відповідь уже отримав, просто
		// наступний запит знову буде повільним.
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("довідник не відповів: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "довідник співробітників недоступний",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("не вдалося покласти в кеш: %v", err)
					}
				}
			}
		}

		// Поля cached і took_ms — те, заради чого все затівалося: по них видно, чи потрапив запит
		// у кеш чи ні і у скільки мілісекунд це обійшлося. Їх же читає check.sh,
		// коли вирішує, зараховувати лабу чи ні.
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

// cacheMode переводить внутрішній стан в одне слово для відповіді: off або redis.
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — похід у довідник по HTTP. Ідентифікатор екранується
// (url.QueryEscape): без цього пробіл або «&» всередині id розвалили б адресу запиту.
// Тіло відповіді обов'язково закривається (defer), інакше під навантаженням скінчаться з'єднання.
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("довідник відповів %s", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
