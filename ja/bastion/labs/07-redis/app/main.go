// 「入館証」サービス、キャッシュ付きの版。実行ファイルは一つ、役割は二つ。
//
//	MODE=hr   — レガシーな社員名簿のスタブ。本物とまったく同じように、
//	            遅く応答する。HR_DELAY は既定で 800 ミリ秒。
//	MODE=api  — 「入館証」サービスそのもの。名簿へ問い合わせ、REDIS_ADDR が
//	            指定されていれば、まずキャッシュを見る。
//
// 一つの役割で両方の場合をまかなうのは、イメージが一つでなければならないから。レジストリ内に
// ほぼ同一のイメージが二つあれば、それはバージョンの更新を忘れうる箇所が二つあるということだ。
//
// 外部依存はなく、標準ライブラリだけを使う。ここでの Redis クライアントは
// 自前で、五十行ほど — Redis プロトコルはテキストで、GET/SET なら一つの関数に
// おさまる。実戦では出来合いのライブラリを使う。ここではむしろ、ビルドが
// パッケージを求めてインターネットに出ていかないことのほうが大事だ。
//
// Go を読める必要はない。以下、何がどこにあるかを区切って示す。まず小さな補助関数、
// 次に自作の Redis クライアント、そして二つの役割 — 「遅い名簿」と「サービス
// そのもの」。このラボの本題は、ファイル末尾寄りの setupAPI で起きる。
//
// 読むときにつまずかないための、言語の三つの約束事:
//
//	func 名前(引数) (返すもの) { ... } — 関数の宣言。
//	関数はしばしば複数の値を一度に返し、その最後がエラーだ。
//	err == nil は「うまくいった」、err != nil は「うまくいかなかった」と読む。
//	// で始まる行はコメントで、プログラムの動作には影響しない。
//
// このファイルは隣の Dockerfile によって、仮想マシン上でビルドされる: docker build ... app/ — README を参照。
package main

// このファイルが使うライブラリの一覧。どれもみな標準の、Go の配布物のものだ。
// サードパーティの行は一つもない。ビルドはインターネットに出ていかないし、
// 誰かのよそのパッケージが公開リポジトリから消されても壊れない。
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

// ---------------------------------------------------------------- 環境変数

// env は環境変数を読み、それが空か未設定なら予備の値を返す。ここから、
// マニフェストで目にする性質が生まれる: アプリケーションの振る舞いは、
// イメージの再ビルドではなく、YAML の一行とポッドの再起動で変わる。
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — 数値に対する同じもの。変数が数字でなかった場合、アプリケーションは
// 落ちない: ログに書き、予備の値を取る。マニフェストのタイプミスがサービスを
// 倒してはならない — ログで気づけるものであるべきだ。
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("値 %s=%q は数値ではありません。%d を使います", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// Redis 自身が送ってきたエラー(「-」で始まる行): 例えば
// NOAUTH や WRONGTYPE。これをネットワークのエラーと区別することが大事だ:
// 再接続しても誤ったパスワードは直らないし、再試行は原因を覆い隠すだけだ。
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — キャッシュへの永続的な TCP 接続が一つと、二つの同時リクエストが
// この接続に入り混じって書き込まないためのロック mu。接続は開いたまま保つ:
// リクエストごとに新しい接続を張るのは、リクエストそのものより高くつく。
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked は接続を開き、パスワードが指定されていれば、すぐさま AUTH コマンドで
// 名乗る。名前の Locked という接尾辞は「ロック mu を既に取っているときにのみ呼ぶこと」を
// 意味する — これはこれらの関数どうしの取り決めであって、言語の性質ではない。
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

// do はコマンドを実行し、接続が切れていたら一度だけ再接続する。
// 値、「値がある」という印、そしてエラーを返す。
// 試行はきっちり二回で、十回ではない: Redis が拒否で応答するなら、再試行は
// ユーザーへの応答を遅らせ、原因をログにまき散らすだけだ。
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
			return "", false, err // Redis 自身が応答した — 再試行は役に立たない
		}
		r.closeLocked() // ネットワーク: 切って、もう一度試す
	}
	return "", false, lastErr
}

// commandLocked はコマンドを、Redis が理解する形で送る: まず
// この先いくつのかたまりが続くか、次にそれぞれの長さと中身。三秒のデッドラインは —
// 止まったキャッシュが、名簿そのものへの往復より長く応答を遅らせないためだ。
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

// readReplyLocked は応答を解析する。行の最初の文字が、何が来たのかをちょうど告げ、
// 関数全体が五つの場合分けになっている。「$-1」は別格に大事だ: これは故障ではなく、
// 「そのようなキーはない」、すなわちごく普通のキャッシュミスだ。
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: 空の応答")
	}
	switch line[0] {
	case '+', ':': // 単純な文字列、または数値
		return line[1:], true, nil
	case '-': // サーバーからのエラー
		return "", false, &redisError{msg: line[1:]}
	case '$': // 長さの分かった文字列。-1 は「そのようなキーはない」を意味する
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // キャッシュミスはエラーではない
		}
		buf := make([]byte, n+2) // 末尾の \r\n のぶん +2
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: 解釈できない応答 %q", line)
	}
}

// Get と SetTTL — サービスが使うコマンドの全て。キャッシュにこれ以上求めるものは
// ないので、クライアントもここでは一ページにおさまる。
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL は値を置き、すぐさま生存期間を割り当てる。SET プラス EXPIRE ではなく、
// 一つのコマンドで: 二つのコマンドのあいだに接続が切れることがあり、そうなると
// キーはキャッシュに永遠に残ってしまう。
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- データ

// employee — サービスが外部に返し、キャッシュに置くもの。右側の `json:"id"` というタグは
// JSON でのフィールド名を定める: Go ではフィールドは大文字始まりのときだけ外から見え、JSON では
// 小文字にするのが慣わしで、これらのタグが両者を結びつける。
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// データは架空のもの。学習用スタンドに本物の人事情報はないし、あってはならない。
var surnames = []string{
	"田中", "佐藤", "斎藤", "鈴木",
	"高橋", "加藤", "吉田", "松本",
}

var departments = []string{
	"警備部", "経理部", "開発部",
	"物流部", "人事部", "総務部",
}

// データは架空だが、同じ識別子に対しては同一だ:
// さもなければ、応答からそれがキャッシュなのか名簿への往復なのかを見分けられない。
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

// writeJSON は応答を返す: コンテンツタイプのヘッダー、応答コード、そして本体。
// SetEscapeHTML(false) は、ロシア語の文字や引用符が \u シーケンスに化けないために必要だ —
// さもなければ応答を目で解読するはめになる。
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("応答を返せませんでした: %v", err)
	}
}

// employeeID はクエリ文字列から ?id= を取り出す。空の識別子は「0」に変える。
// キャッシュのキーが常に定まった形を持ち、末尾のない「employee:」という
// キーが作られないようにするためだ。
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- 本題

// main — エントリーポイント: ここからプログラムの仕事が始まる。HTTP サーバーを立ち上げ、
// そこに /healthz を、そして MODE を見て二つの役割のうちの一つを載せる。役割は起動時に
// 一度選ばれ、ポッドの一生のあいだ変わらない。
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "不明")

	mux := http.NewServeMux()
	// /healthz は両方の役割にある: マニフェストに書かれた readiness プローブがここを叩く。
	// これは常に応答し、何も検査しない — ここでのプローブの役目は、システムの健全性を
	// 評価することではなく、プロセスが立ち上がってポートを聴いていると分かることだ。
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 二つの役割への分岐。未知の値は「なんとなく」起動する理由にはならない:
	// すぐに、はっきりしたメッセージとともに落ちる。違う役割での無言の起動は、
	// ログを眺める一時間の代償を払うことになっただろう。
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("不明な MODE=%q、許される値は hr と api です", mode)
	}

	// ReadHeaderTimeout は、クライアントがリクエストを始めて黙り込んだら接続を閉じる。これがないと、
	// そうした「クライアント」が数人いれば、何も要求せずにサーバー全体を占領するのに足りる。
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("モード %s、ポート %s、ポッド %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — レガシー名簿のスタブ。その唯一の特徴は遅いことであり、
// それは偶然ではなく、課題の本質だ。
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q を解釈できませんでした。800ms を使います", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("名簿は %s で応答します", delay)

	// この役割の唯一のアドレス。time.Sleep こそが「レガシーシステム」の全てだ: ラボに
	// キャッシュが登場するのは、まさにこの数百ミリ秒のためだ。応答の source フィールドは、
	// データがここから来たのであって、キャッシュからではないことを示す。
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

// setupAPI — 「入館証」サービスそのもの。ここにキャッシュのロジックが宿り、ここに
// 「なぜ応答に cache: off と書かれるのか」という問いへの答えもある。
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// キャッシュは REDIS_ADDR が存在するという、まさにその事実によって有効になる — その変数は
	// cache-patch.yaml が追加する。変数がなければ cache は空のまま、以下の
	// `if cache != nil` の検査はどれも発火せず、サービスはこれまでどおり動く。
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("キャッシュ有効: %s、レコードの生存期間 %d 秒", addr, ttl)
	} else {
		log.Printf("キャッシュ無効: REDIS_ADDR が未設定のため、すべてのリクエストが名簿へ行きます")
	}

	// 接続プールを大きくした別のクライアント: さもなければ負荷のもとで、
	// 時間の半分が名簿への TCP 接続の確立に費やされ、
	// 計測は名簿の遅延ではなく、我々自身の不注意を示すことになる。
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// ルート「/」— サービスの名刺: バージョン、ポッド、ノード、レジストリ、そしてキャッシュのモード。cache フィールドで
	// ログを覗いたりマニフェストを読み解いたりせずとも、off か redis かがすぐ分かる。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "不明"),
			"namespace": env("POD_NAMESPACE", "不明"),
			"registry":  env("IMAGE_REGISTRY", "未設定"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// ラボの主役のアドレス。動作の順序: キャッシュに尋ね、ミスなら名簿へ行き、
	// 応答をキャッシュに置く。このラボで計測するものはすべて、この四十行の上で起きる。
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// キャッシュのキーは「employee:」プラス識別子。接頭辞が必要なのは、種類の異なる
		// レコードが衝突しないためだ: キャッシュはアプリケーション全体で一つ、その中の名前は平坦だ。
		key := "employee:" + id

		var emp employee
		fromCache := false

		// 第一段階: キャッシュに尋ねる。三つの結末 — エラー、ヒット、ミス — はそれぞれ
		// 違うように扱われ、その違いはここでは本質的だ。
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// キャッシュが利用できない — これはユーザーにエラーを返す理由にはならない。
				// 名簿へ行く: 遅いが、正しい。
				log.Printf("キャッシュが利用できません (%v)。名簿へ行きます", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("キャッシュのキー %s にゴミが入っています。名簿へ行きます", key)
				}
			}
		}

		// 第二段階: ミス、または利用できないキャッシュ — 名簿へ行く。遅いが、これが
		// 唯一の真実の源だ。応答をキャッシュに置く。もし置けなかったとしても、
		// ユーザーがそれを知る必要はない — 応答はもう受け取っており、ただ
		// 次のリクエストがまた遅くなるだけだ。
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("名簿が応答しませんでした: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "社員名簿が利用できません",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("キャッシュに書き込めませんでした: %v", err)
					}
				}
			}
		}

		// cached と took_ms のフィールドこそ、すべての目当てだった: これらによって、リクエストが
		// キャッシュに当たったか否か、そしてそれが何ミリ秒かかったかが分かる。同じものを check.sh が読み、
		// ラボを合格とするか否かを決める。
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

// cacheMode は内部状態を、応答用の一語に翻訳する: off か redis。
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — HTTP による名簿への往復。識別子はエスケープされる
// (url.QueryEscape): これがないと、id 中の空白や「&」がリクエストのアドレスを崩してしまう。
// 応答の本体は必ず閉じられる(defer)。さもなければ負荷のもとで接続が尽きる。
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("名簿が %s を返しました", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
