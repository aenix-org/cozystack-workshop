// "पास" सेवा, कैश वाला संस्करण। एक निष्पादन-योग्य फ़ाइल, दो भूमिकाएँ।
//
//	MODE=hr   — लीगेसी कर्मचारी निर्देशिका का एक स्टब। धीरे उत्तर देता है,
//	            ठीक वैसे ही जैसे असली देता है: HR_DELAY डिफ़ॉल्ट रूप से 800ms।
//	MODE=api  — खुद "पास" सेवा। निर्देशिका से पूछती है, और यदि REDIS_ADDR
//	            सेट है, तो पहले कैश में देखती है।
//
// दोनों मामलों के लिए एक ही भूमिका, क्योंकि इमेज एक ही होनी चाहिए: रजिस्ट्री में दो लगभग एक जैसी
// इमेज दो ऐसी जगहें हैं जहाँ आप संस्करण बढ़ाना भूल सकते हैं।
//
// कोई बाहरी निर्भरता नहीं, केवल मानक लाइब्रेरी। यहाँ Redis क्लाइंट अपना है,
// पचास पंक्तियों का — Redis प्रोटोकॉल टेक्स्ट-आधारित है और GET/SET के लिए यह
// एक फ़ंक्शन में समा जाता है। उत्पादन में तैयार लाइब्रेरी ली जाती है; यहाँ यह अधिक मायने रखता है कि
// बिल्ड पैकेजों के लिए इंटरनेट पर न जाए।
//
// Go पढ़ना आना ज़रूरी नहीं है: नीचे दर्शाया गया है कि क्या कहाँ है। पहले छोटे सहायक,
// फिर घर का बना Redis क्लाइंट, फिर दो भूमिकाएँ — "धीमी निर्देशिका" और "खुद
// सेवा"। जिसके लिए लैब बनाई गई है, वह मुख्य बात setupAPI में होती है, फ़ाइल के अंत के पास।
//
// भाषा के तीन नियम, ताकि पढ़ते समय आप न अटकें:
//
//	func नाम(तर्क) (क्या लौटाता है) { ... } — एक फ़ंक्शन घोषणा;
//	एक फ़ंक्शन अक्सर एक साथ कई मान लौटाता है, और उनमें से अंतिम एक त्रुटि होती है:
//	err == nil का अर्थ है "ठीक रहा", err != nil — "ठीक नहीं रहा";
//	// से शुरू होने वाली पंक्तियाँ टिप्पणियाँ हैं, वे प्रोग्राम के काम करने पर असर नहीं डालतीं।
//
// फ़ाइल को पड़ोसी Dockerfile द्वारा, लैपटॉप पर बनाया जाता है: docker build ... app/ — README देखें।
package main

// फ़ाइल जिन लाइब्रेरियों का उपयोग करती है उनकी सूची। हर एक मानक है, Go वितरण से।
// कोई तृतीय-पक्ष पंक्ति नहीं: बिल्ड इंटरनेट पर नहीं जाता और इसलिए नहीं टूटेगा क्योंकि
// किसी और का बाहरी पैकेज सार्वजनिक रिपॉज़िटरी से हटा दिया गया।
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

// ---------------------------------------------------------------- परिवेश

// env एक परिवेश चर पढ़ता है और, यदि वह खाली या अनसेट है, तो प्रतिस्थापन मान लौटाता है।
// यहीं से वह गुण आता है जो आप मैनिफ़ेस्ट में देखते हैं: अनुप्रयोग का व्यवहार
// YAML में एक पंक्ति और पॉड पुनरारंभ से बदलता है, इमेज के पुनर्निर्माण से नहीं।
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — संख्याओं के लिए वही बात। यदि चर में संख्या नहीं निकली, तो अनुप्रयोग
// गिरता नहीं: लॉग में लिखता है और प्रतिस्थापन मान लेता है। मैनिफ़ेस्ट में एक टाइपो को
// सेवा नहीं गिरानी चाहिए — वह लॉग में दिखाई देनी चाहिए।
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

// एक त्रुटि जो खुद Redis ने भेजी ("-" से शुरू होने वाली पंक्ति): उदाहरण के लिए
// NOAUTH या WRONGTYPE. इसे नेटवर्क त्रुटि से अलग करना मायने रखता है: पुनः जुड़ने से
// गलत पासवर्ड ठीक नहीं होगा, और पुनः प्रयास केवल कारण को छिपाते हैं।
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — कैश तक एक स्थायी TCP कनेक्शन और एक ताला mu, ताकि दो
// समवर्ती अनुरोध इस कनेक्शन में मिलाकर न लिखें। कनेक्शन खुला रखते हैं:
// हर अनुरोध के लिए नया स्थापित करना खुद अनुरोध से अधिक महँगा पड़ता है।
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked कनेक्शन खोलता है और, यदि पासवर्ड सेट है, तो तुरंत AUTH कमांड से
// अपना परिचय देता है। नाम में Locked प्रत्यय का अर्थ है "केवल तभी कॉल करें जब ताला mu
// पहले से लिया जा चुका हो" — यह इन फ़ंक्शनों के बीच एक समझौता है, भाषा का गुण नहीं।
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

// do एक कमांड चलाता है और, यदि कनेक्शन टूट गया, तो एक बार पुनः जुड़ता है।
// मान, "मान मौजूद है" संकेत और एक त्रुटि लौटाता है।
// प्रयास ठीक दो हैं, दस नहीं: यदि Redis इनकार से उत्तर देता है, तो पुनः प्रयास केवल
// उपयोगकर्ता को उत्तर में देरी करेंगे और कारण को लॉग में फैला देंगे।
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
			return "", false, err // खुद Redis ने उत्तर दिया — पुनः प्रयास से मदद नहीं मिलेगी
		}
		r.closeLocked() // नेटवर्क: इसे तोड़ें और फिर से कोशिश करें
	}
	return "", false, lastErr
}

// commandLocked कमांड को उस रूप में भेजता है जैसे Redis उसे समझता है: पहले
// आगे कितने टुकड़े आते हैं, फिर हर एक की लंबाई और सामग्री। तीन सेकंड की समय-सीमा इसलिए है —
// ताकि अटका हुआ कैश उत्तर को खुद निर्देशिका तक जाने से अधिक देर न करे।
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

// readReplyLocked उत्तर को विश्लेषित करता है। पंक्ति का पहला वर्ण बताता है कि ठीक क्या आया,
// और पूरा फ़ंक्शन पाँच मामलों का विश्लेषण है। "$-1" अलग से महत्वपूर्ण है: यह खराबी नहीं,
// बल्कि "ऐसा कोई कुंजी नहीं है", यानी एक साधारण कैश मिस है।
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
	case '+', ':': // एक साधारण स्ट्रिंग या एक संख्या
		return line[1:], true, nil
	case '-': // सर्वर से एक त्रुटि
		return "", false, &redisError{msg: line[1:]}
	case '$': // ज्ञात लंबाई की एक स्ट्रिंग; -1 का अर्थ है "कोई कुंजी नहीं"
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // कैश मिस कोई त्रुटि नहीं है
		}
		buf := make([]byte, n+2) // +2 अंत के \r\n के लिए
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: непонятный ответ %q", line)
	}
}

// Get और SetTTL — कमांडों का पूरा समूह जिनका सेवा उपयोग करती है। कैश से और कुछ
// आवश्यक नहीं, इसीलिए यहाँ क्लाइंट एक पृष्ठ में समा जाता है।
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL मान रखता है और तुरंत जीवन-काल निर्धारित करता है। एक ही कमांड से, न कि
// SET और EXPIRE: दो कमांडों के बीच कनेक्शन टूट सकता है, और कुंजी
// कैश में हमेशा के लिए रह जाएगी।
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- डेटा

// employee — वह जो सेवा बाहर लौटाती है और कैश में रखती है। दाईं ओर की `json:"id"` टैग
// JSON में फ़ील्ड के नाम निर्धारित करती हैं: Go में फ़ील्ड बाहर से केवल बड़े अक्षर से दिखते हैं, जबकि JSON में
// छोटे अक्षर का रिवाज़ है, और ये टैग उन्हें आपस में जोड़ती हैं।
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// डेटा काल्पनिक है। प्रशिक्षण स्टैंड में कोई वास्तविक कार्मिक जानकारी नहीं है और न होनी चाहिए।
var surnames = []string{
	"Иванов И. И.", "Петрова А. С.", "Сидоров П. Н.", "Кузнецова М. В.",
	"Смирнов Д. А.", "Попова Е. К.", "Волков С. Ю.", "Морозова Н. Г.",
}

var departments = []string{
	"Служба безопасности", "Бухгалтерия", "Разработка",
	"Логистика", "Отдел кадров", "Административный отдел",
}

// डेटा काल्पनिक है, लेकिन एक ही पहचानकर्ता के लिए एक जैसा:
// अन्यथा उत्तर से यह समझना असंभव होता कि यह कैश है या निर्देशिका तक की यात्रा।
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

// writeJSON उत्तर देता है: सामग्री-प्रकार वाला हेडर, उत्तर कोड और मुख्य भाग।
// SetEscapeHTML(false) इसलिए ज़रूरी है ताकि रूसी अक्षर और उद्धरण चिह्न
// \u-अनुक्रमों में न बदलें — अन्यथा उत्तर को आँखों से समझना पड़ता।
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("не удалось отдать ответ: %v", err)
	}
}

// employeeID अनुरोध स्ट्रिंग से ?id= निकालता है। खाली पहचानकर्ता को "0" में बदल देते हैं,
// ताकि कैश में कुंजी का हमेशा एक निश्चित रूप हो और बिना पूँछ वाली कुंजी
// "employee:" न बने।
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- मुख्य

// main — प्रवेश बिंदु: प्रोग्राम का काम यहीं से शुरू होता है। यह एक HTTP सर्वर खड़ा करता है, उस पर
// /healthz टाँगता है और, MODE को देखकर, दो में से एक भूमिका। भूमिका आरंभ पर एक बार
// चुनी जाती है और पॉड के जीवन के दौरान नहीं बदलती।
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "неизвестно")

	mux := http.NewServeMux()
	// /healthz दोनों भूमिकाओं में मौजूद है: यहाँ मैनिफ़ेस्ट में वर्णित तत्परता जाँच दस्तक देती है।
	// यह हमेशा उत्तर देता है और कुछ जाँचता नहीं — यहाँ जाँच का काम यह समझना है
	// कि प्रक्रिया खड़ी हुई और पोर्ट सुन रही है, न कि सिस्टम के स्वास्थ्य का आकलन करना।
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// दो भूमिकाओं में विभाजन। अज्ञात मान "किसी तरह" शुरू होने का कारण नहीं:
	// हम तुरंत और एक स्पष्ट संदेश के साथ गिरते हैं। गलत भूमिका में मौन आरंभ पर
	// लॉग को घूरते हुए एक घंटा लग जाता।
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("неизвестный MODE=%q, допустимы hr и api", mode)
	}

	// ReadHeaderTimeout कनेक्शन बंद कर देता है यदि क्लाइंट ने अनुरोध शुरू किया और चुप हो गया। इसके बिना
	// ऐसे कुछ "क्लाइंट" ही काफ़ी हैं पूरे सर्वर को बिना कुछ माँगे व्यस्त कर देने के लिए।
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("режим %s, порт %s, под %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — लीगेसी निर्देशिका का एक स्टब। इसकी एकमात्र विशेषता यह है कि
// यह धीमी है, और यह कोई संयोग नहीं बल्कि कार्य का सार है।
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q не разобрался, беру 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("справочник отвечает за %s", delay)

	// इस भूमिका का एकमात्र पता। time.Sleep ही पूरी "लीगेसी सिस्टम" है: वही
	// सैकड़ों मिलीसेकंड, जिनके लिए लैब में कैश प्रकट होता है। उत्तर में source फ़ील्ड
	// दिखाता है कि डेटा यहाँ से आया, कैश से नहीं।
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

// setupAPI — खुद "पास" सेवा। यहाँ कैश तर्क रहता है, और यहीं इस प्रश्न का उत्तर है
// कि "उत्तर में cache: off क्यों लिखा है"।
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// कैश REDIS_ADDR की मौजूदगी मात्र से चालू होता है — वही चर जिसे
	// cache-patch.yaml जोड़ता है। चर नहीं है — cache खाली रहता है, नीचे की सारी जाँचें
	// `if cache != nil` सक्रिय नहीं होतीं, और सेवा वैसे ही काम करती है जैसे करती थी।
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("кеш включён: %s, срок жизни записи %d с", addr, ttl)
	} else {
		log.Printf("кеш выключен: REDIS_ADDR не задан, каждый запрос пойдёт в справочник")
	}

	// बढ़े हुए कनेक्शन पूल वाला एक अलग क्लाइंट: अन्यथा भार के अंतर्गत
	// आधा समय निर्देशिका तक TCP कनेक्शन स्थापित करने में चला जाता,
	// और माप निर्देशिका की देरी नहीं बल्कि हमारी अपनी लापरवाही दिखाता।
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// मूल "/" — सेवा का विज़िटिंग कार्ड: संस्करण, पॉड, नोड, रजिस्ट्री और कैश मोड। cache फ़ील्ड से
	// तुरंत off या redis दिख जाता है, लॉग में झाँके बिना और मैनिफ़ेस्ट विश्लेषित किए बिना।
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

	// लैब का मुख्य पता। क्रियाओं का क्रम: कैश से पूछें, मिस पर निर्देशिका तक जाएँ,
	// उत्तर कैश में रखें। इस लैब में जो कुछ भी आप मापते हैं, वह इन चालीस
	// पंक्तियों पर होता है।
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// कैश में कुंजी — "employee:" और पहचानकर्ता। उपसर्ग इसलिए ज़रूरी है ताकि विभिन्न प्रकार की
		// प्रविष्टियाँ न टकराएँ: कैश पूरे अनुप्रयोग के लिए एक है, और उसमें नाम सपाट हैं।
		key := "employee:" + id

		var emp employee
		fromCache := false

		// पहला चरण: कैश से पूछें। तीन परिणाम — त्रुटि, हिट, मिस — अलग-अलग तरीके से
		// संभाले जाते हैं, और यहाँ उनके बीच का अंतर मूलभूत है।
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// कैश अनुपलब्ध है — यह उपयोगकर्ता को त्रुटि देने का कारण नहीं।
				// निर्देशिका तक जाते हैं: धीरे, पर सही।
				log.Printf("кеш недоступен (%v), иду в справочник", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("в кеше по ключу %s лежит мусор, иду в справочник", key)
				}
			}
		}

		// दूसरा चरण: मिस या अनुपलब्ध कैश — निर्देशिका तक जाते हैं। धीरे, पर यही
		// सत्य का एकमात्र स्रोत है। उत्तर कैश में रखते हैं; यदि रखना विफल हुआ,
		// तो उपयोगकर्ता को इसके बारे में जानने की ज़रूरत नहीं — उसे अपना उत्तर मिल ही चुका है, बस
		// अगला अनुरोध फिर से धीमा होगा।
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

		// cached और took_ms फ़ील्ड — वह जिसके लिए यह सब शुरू किया गया था: इनसे दिखता है कि अनुरोध
		// कैश में लगा या नहीं और यह कितने मिलीसेकंड में पड़ा। इन्हीं को check.sh पढ़ता है,
		// जब यह तय करता है कि लैब को पास गिनना है या नहीं।
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

// cacheMode आंतरिक स्थिति को उत्तर के लिए एक शब्द में बदलता है: off या redis।
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — HTTP के ज़रिए निर्देशिका तक की यात्रा। पहचानकर्ता को एस्केप किया जाता है
// (url.QueryEscape): इसके बिना id के अंदर एक स्पेस या "&" अनुरोध URL को तोड़ देता।
// उत्तर का मुख्य भाग अनिवार्य रूप से बंद किया जाता है (defer), अन्यथा भार के अंतर्गत कनेक्शन ख़त्म हो जाएँगे।
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
