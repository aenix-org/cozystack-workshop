// «पास» सेवा, कैश वाला संस्करण। एक ही निष्पादन योग्य फ़ाइल, दो भूमिकाएँ।
//
//	MODE=hr   — कर्मचारियों की लेगेसी निर्देशिका का एक स्टब। धीरे जवाब देता है,
//	            ठीक वैसे ही जैसे असली देता है: HR_DELAY डिफ़ॉल्ट रूप से 800 ms।
//	MODE=api  — स्वयं «पास» सेवा। निर्देशिका के पास जाती है, और यदि REDIS_ADDR दिया गया हो,
//	            तो पहले कैश में देखती है।
//
// एक ही भूमिका दोनों मामलों को कवर करती है, क्योंकि इमेज एक ही होनी चाहिए: रजिस्ट्री में दो लगभग एक जैसी
// इमेज़ यानी दो जगहें जहाँ आप संस्करण अपडेट करना भूल सकते हैं।
//
// कोई बाहरी निर्भरता नहीं, केवल मानक लाइब्रेरी। Redis क्लाइंट यहाँ
// अपना ही है, करीब पचास पंक्तियों का, — Redis प्रोटोकॉल टेक्स्ट-आधारित है और GET/SET के लिए
// एक ही फ़ंक्शन में समा जाता है। असली उत्पादन में तैयार लाइब्रेरी ली जाती है; यहाँ अधिक ज़रूरी है कि
// बिल्ड पैकेजों के लिए इंटरनेट पर न जाए।
//
// Go पढ़ना आना ज़रूरी नहीं है: नीचे चिह्नित है कि क्या कहाँ है। पहले छोटे सहायक,
// फिर घर का बनाया हुआ Redis क्लाइंट, फिर दो भूमिकाएँ — «धीमी निर्देशिका» और «स्वयं
// सेवा»। जिस चीज़ के लिए यह लैब रची गई है वह setupAPI में, फ़ाइल के अंत के करीब, होती है।
//
// भाषा के तीन नियम, ताकि पढ़ते समय ठोकर न लगे:
//
//	func नाम(तर्क) (क्या लौटाएगा) { ... } — फ़ंक्शन की घोषणा;
//	फ़ंक्शन अक्सर एक साथ कई मान लौटाता है, और उनमें से अंतिम एक त्रुटि होता है:
//	err == nil का अर्थ है «ठीक रहा», err != nil — «ठीक नहीं रहा»;
//	// से शुरू होने वाली पंक्तियाँ टिप्पणियाँ हैं, वे प्रोग्राम के काम पर असर नहीं डालतीं।
//
// फ़ाइल पड़ोसी Dockerfile से, वर्चुअल मशीन पर बनती है: docker build ... app/ — README देखें।
package main

// फ़ाइल जिन लाइब्रेरियों का उपयोग करती है उनकी सूची। हर एक मानक है, Go वितरण से।
// एक भी तीसरे-पक्ष की पंक्ति नहीं: बिल्ड इंटरनेट पर नहीं जाता और इसलिए नहीं टूटेगा कि
// किसी और का पैकेज किसी सार्वजनिक रिपॉज़िटरी से हटा दिया गया।
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

// env एक परिवेश चर पढ़ता है और, यदि वह खाली या अनसेट हो, तो फ़ॉलबैक मान लौटाता है।
// यहीं से वह गुण आता है जो आप मैनिफ़ेस्ट में देखते हैं: एप्लिकेशन का व्यवहार
// YAML में एक पंक्ति और पॉड के पुनरारंभ से बदलता है, इमेज को दोबारा बनाने से नहीं।
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — संख्याओं के लिए वही चीज़। यदि चर संख्या न निकले, तो एप्लिकेशन क्रैश नहीं
// होता: लॉग में लिखता है और फ़ॉलबैक मान लेता है। मैनिफ़ेस्ट में एक टाइपो को सेवा
// नहीं गिरानी चाहिए — वह लॉग में दिखनी चाहिए।
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("मान %s=%q संख्या नहीं है, %d ले रहा हूँ", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// स्वयं Redis द्वारा भेजी गई त्रुटि («-» से शुरू होने वाली पंक्ति): उदाहरण के लिए
// NOAUTH या WRONGTYPE। इसे नेटवर्क वाली त्रुटि से अलग पहचानना ज़रूरी है: पुनः जुड़ने से
// गलत पासवर्ड ठीक नहीं होता, और पुनः प्रयास केवल कारण को छिपाते हैं।
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — कैश तक एक स्थायी TCP कनेक्शन और साथ में एक ताला mu, ताकि दो
// एक साथ आने वाले अनुरोध इस कनेक्शन में गड्डमड्ड न लिखें। कनेक्शन को खुला रखते हैं:
// हर अनुरोध पर नया बनाना खुद अनुरोध से महँगा है।
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked कनेक्शन खोलता है और, यदि पासवर्ड दिया हो, तो तुरंत AUTH कमांड से
// अपना परिचय देता है। नाम में Locked प्रत्यय का अर्थ है «केवल तभी बुलाएँ जब ताला mu
// पहले से पकड़ा हुआ हो» — यह इन फ़ंक्शनों के बीच एक सहमति है, भाषा का गुण नहीं।
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

// do एक कमांड चलाता है और यदि कनेक्शन टूट गया हो तो एक बार पुनः जुड़ता है।
// मान, «मान मौजूद है» संकेतक और त्रुटि लौटाता है।
// ठीक दो प्रयास, दस नहीं: यदि Redis अस्वीकृति के साथ जवाब दे, तो पुनः प्रयास केवल उपयोगकर्ता को
// उत्तर देने में देरी करेंगे और कारण को लॉग भर में फैला देंगे।
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
			return "", false, err // स्वयं Redis ने जवाब दिया — पुनः प्रयास मदद नहीं करेगा
		}
		r.closeLocked() // नेटवर्क: तोड़ते हैं और एक बार और कोशिश करते हैं
	}
	return "", false, lastErr
}

// commandLocked कमांड को उसी रूप में भेजता है जिस रूप में Redis उसे समझता है: पहले
// आगे कितने टुकड़े हैं, फिर हर एक की लंबाई और सामग्री। तीन सेकंड की समय-सीमा —
// ताकि अटका हुआ कैश उत्तर को स्वयं निर्देशिका जाने से अधिक देर तक न रोके।
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

// readReplyLocked उत्तर को पार्स करता है। पंक्ति का पहला अक्षर बताता है कि आया क्या है,
// और पूरा फ़ंक्शन पाँच मामलों का विश्लेषण है। «$-1» मामला अलग से ज़रूरी है: यह खराबी नहीं,
// बल्कि «ऐसी कोई कुंजी नहीं है», यानी एक सामान्य कैश मिस है।
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: खाली उत्तर")
	}
	switch line[0] {
	case '+', ':': // एक सरल स्ट्रिंग या एक संख्या
		return line[1:], true, nil
	case '-': // सर्वर से एक त्रुटि
		return "", false, &redisError{msg: line[1:]}
	case '$': // ज्ञात लंबाई की स्ट्रिंग; -1 का अर्थ है «ऐसी कोई कुंजी नहीं»
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // कैश मिस त्रुटि नहीं है
		}
		buf := make([]byte, n+2) // +2 अंत में आने वाले \r\n के लिए
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: समझ में न आने वाला उत्तर %q", line)
	}
}

// Get और SetTTL — कमांडों का पूरा समूह जिसका उपयोग सेवा करती है। कैश से इससे अधिक कुछ
// नहीं चाहिए, यही कारण है कि क्लाइंट यहाँ एक पन्ने में समा जाता है।
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL मान को रखता है और तुरंत एक जीवनकाल निर्धारित करता है। एक ही कमांड से, न कि
// SET और EXPIRE से: दो कमांडों के बीच कनेक्शन टूट सकता है, और कुंजी
// कैश में हमेशा के लिए रह जाएगी।
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- डेटा

// employee — वह जो सेवा बाहर लौटाती है और कैश में रखती है। दाईं ओर की `json:"id"` टैग
// JSON में फ़ील्ड के नाम तय करती हैं: Go में फ़ील्ड बाहर से केवल बड़े अक्षर से दिखते हैं, और JSON में
// छोटे अक्षर का चलन है, और ये टैग उन्हें आपस में जोड़ती हैं।
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// डेटा काल्पनिक है। प्रशिक्षण स्टैंड में असली कर्मचारी जानकारी नहीं है और न होनी चाहिए।
var surnames = []string{
	"शर्मा आर.", "वर्मा अ.", "सिन्हा प्र.", "गुप्ता वि.",
	"अग्रवाल दी.", "पटेल ई.", "रेड्डी सा.", "भट्ट नी.",
}

var departments = []string{
	"सुरक्षा विभाग", "लेखा", "इंजीनियरिंग",
	"लॉजिस्टिक्स", "मानव संसाधन विभाग", "प्रशासन विभाग",
}

// डेटा काल्पनिक है, लेकिन एक ही पहचानकर्ता के लिए एक जैसा:
// अन्यथा उत्तर से यह नहीं समझा जा सकता कि यह कैश है या निर्देशिका जाने का परिणाम।
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

// writeJSON उत्तर लौटाता है: सामग्री-प्रकार वाला हेडर, उत्तर कोड और शरीर।
// SetEscapeHTML(false) इसलिए ज़रूरी है ताकि रूसी अक्षर और उद्धरण चिह्न
// \u-अनुक्रमों में न बदलें, — अन्यथा उत्तर को आँखों से डिकोड करना पड़ेगा।
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("उत्तर देने में विफल: %v", err)
	}
}

// employeeID अनुरोध स्ट्रिंग से ?id= निकालता है। खाली पहचानकर्ता को «0» में बदल देते हैं,
// ताकि कैश की कुंजी का रूप हमेशा निश्चित रहे और बिना पूंछ वाली कोई कुंजी
// «employee:» न बन जाए।
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- मुख्य

// main — प्रवेश-बिंदु: यहीं से प्रोग्राम का काम शुरू होता है। HTTP सर्वर उठाता है, उस पर
// /healthz टाँगता है और, MODE को देखकर, दो में से एक भूमिका। भूमिका एक बार
// स्टार्ट पर चुनी जाती है और पॉड के जीवनकाल में नहीं बदलती।
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "अज्ञात")

	mux := http.NewServeMux()
	// /healthz दोनों भूमिकाओं में मौजूद है: यहीं मैनिफ़ेस्ट में वर्णित तैयारी-जाँच दस्तक देती है।
	// यह हमेशा जवाब देता है और कुछ नहीं जाँचता — जाँच का काम यहाँ यह समझना है
	// कि प्रक्रिया उठ गई है और पोर्ट पर सुन रही है, न कि सिस्टम के स्वास्थ्य का आकलन करना।
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// दो भूमिकाओं में विभाजन। अज्ञात मान «किसी तरह» शुरू होने का बहाना नहीं:
	// तुरंत और स्पष्ट संदेश के साथ गिर जाते हैं। गलत भूमिका में चुपचाप शुरू होना
	// लॉग घूरने के एक घंटे में पड़ता।
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("अज्ञात MODE=%q, मान्य मान hr और api हैं", mode)
	}

	// ReadHeaderTimeout कनेक्शन बंद कर देता है यदि क्लाइंट ने अनुरोध शुरू किया और चुप हो गया। इसके बिना
	// ऐसे कुछ «क्लाइंट» पूरे सर्वर को बिना कुछ माँगे व्यस्त रखने के लिए काफी हैं।
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("मोड %s, पोर्ट %s, पॉड %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — लेगेसी निर्देशिका का एक स्टब। इसकी एकमात्र विशेषता यह है
// कि यह धीमी है, और यह संयोग नहीं बल्कि कार्य का सार है।
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q पार्स नहीं हुआ, 800ms ले रहा हूँ", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("निर्देशिका %s में जवाब देती है", delay)

	// इस भूमिका का एकमात्र पता। time.Sleep ही पूरी «लेगेसी प्रणाली» है: वही
	// सैकड़ों मिलीसेकंड, जिनके लिए लैब में कैश प्रकट होता है। उत्तर में source फ़ील्ड
	// दिखाती है कि डेटा यहाँ से आया, कैश से नहीं।
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

// setupAPI — स्वयं «पास» सेवा। यहीं कैश का तर्क रहता है, और यहीं इस
// प्रश्न का उत्तर है कि «उत्तर में cache: off क्यों लिखा है»।
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// कैश केवल REDIS_ADDR के मौजूद होने भर से चालू होता है — वही चर जिसे
	// cache-patch.yaml जोड़ता है। चर नहीं है — cache खाली रहता है, नीचे की सारी
	// `if cache != nil` जाँचें नहीं चलतीं, और सेवा जैसे चलती थी वैसे ही चलती है।
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("कैश चालू: %s, प्रविष्टि का जीवनकाल %d सेकंड", addr, ttl)
	} else {
		log.Printf("कैश बंद: REDIS_ADDR निर्दिष्ट नहीं, हर अनुरोध निर्देशिका जाएगा")
	}

	// बढ़े हुए कनेक्शन पूल वाला एक अलग क्लाइंट: अन्यथा भार के तहत
	// आधा समय निर्देशिका तक TCP कनेक्शन स्थापित करने में लग जाएगा,
	// और माप निर्देशिका की देरी नहीं बल्कि हमारी अपनी लापरवाही दिखाएगा।
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// मूल «/» — सेवा का विज़िटिंग कार्ड: संस्करण, पॉड, नोड, रजिस्ट्री और कैश मोड। cache फ़ील्ड से
	// तुरंत दिख जाता है off या redis, बिना लॉग में झाँके और बिना मैनिफ़ेस्ट पार्स किए।
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "अज्ञात"),
			"namespace": env("POD_NAMESPACE", "अज्ञात"),
			"registry":  env("IMAGE_REGISTRY", "निर्दिष्ट नहीं"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// लैब का मुख्य पता। क्रियाओं का क्रम: कैश से पूछो, मिस पर निर्देशिका जाओ,
	// उत्तर को कैश में रखो। इस लैब में आप जो कुछ मापते हैं वह इन चालीस
	// पंक्तियों में होता है।
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// कैश की कुंजी — «employee:» और साथ में पहचानकर्ता। उपसर्ग इसलिए ज़रूरी है ताकि अलग-अलग तरह की
		// प्रविष्टियाँ न टकराएँ: कैश पूरे एप्लिकेशन के लिए एक ही है, और उसमें नाम सपाट हैं।
		key := "employee:" + id

		var emp employee
		fromCache := false

		// पहला चरण: कैश से पूछो। तीन परिणाम — त्रुटि, हिट, मिस — अलग-अलग तरीके से
		// संभाले जाते हैं, और यहाँ उनके बीच का अंतर मौलिक है।
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// कैश अनुपलब्ध है — यह उपयोगकर्ता को त्रुटि लौटाने का बहाना नहीं।
				// निर्देशिका जाते हैं: धीमा, पर सही।
				log.Printf("कैश अनुपलब्ध (%v), निर्देशिका जा रहा हूँ", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("कुंजी %s पर कैश में कचरा है, निर्देशिका जा रहा हूँ", key)
				}
			}
		}

		// दूसरा चरण: मिस या अनुपलब्ध कैश — निर्देशिका जाते हैं। धीमा, पर यही
		// सत्य का एकमात्र स्रोत है। उत्तर को कैश में रखते हैं; यदि रखना न बना,
		// तो उपयोगकर्ता को इसके बारे में जानने की ज़रूरत नहीं — उसे अपना उत्तर मिल ही चुका है, बस
		// अगला अनुरोध फिर से धीमा होगा।
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("निर्देशिका ने जवाब नहीं दिया: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "कर्मचारी निर्देशिका अनुपलब्ध है",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("कैश में डालने में विफल: %v", err)
					}
				}
			}
		}

		// cached और took_ms फ़ील्ड ही वह हैं जिनके लिए यह सब रचा गया था: उनसे दिखता है कि अनुरोध
		// कैश में लगा या नहीं और कितने मिलीसेकंड में पड़ा। इन्हें ही check.sh पढ़ता है,
		// जब वह तय करता है कि लैब गिनी जाए या नहीं।
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

// cacheMode आंतरिक स्थिति को उत्तर के लिए एक शब्द में बदल देता है: off या redis।
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — HTTP के ज़रिए निर्देशिका तक जाना। पहचानकर्ता को एस्केप किया जाता है
// (url.QueryEscape): इसके बिना id के भीतर एक स्पेस या «&» अनुरोध का पता बिखेर देता।
// उत्तर का शरीर हमेशा बंद किया जाता है (defer), अन्यथा भार के तहत कनेक्शन खत्म हो जाएँगे।
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("निर्देशिका ने %s जवाब दिया", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
