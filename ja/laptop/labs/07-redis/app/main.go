// 「パス」サービス、キャッシュ付きバージョン。実行ファイルは1つ、ロールは2つ。
//
//	MODE=hr   — レガシーな従業員名簿のスタブ。ちょうど本物と同じように、
//	            ゆっくり応答する。HR_DELAY はデフォルトで 800ms。
//	MODE=api  — 「パス」サービス本体。名簿に問い合わせ、REDIS_ADDR が
//	            設定されていれば、まずキャッシュを見る。
//
// 両方の場合に1つのロールなのは、イメージが1つでなければならないから。ほぼ同じ
// イメージがレジストリに2つあると、バージョン更新を忘れる箇所が2つになる。
//
// 外部依存はなく、標準ライブラリだけ。ここの Redis クライアントは自前で、
// 五十行ほど — Redis プロトコルはテキストで、GET/SET なら1つの関数に収まる。
// 本番では既製のライブラリを使うが、ここではビルドがパッケージを取りに
// インターネットへ行かないことのほうが大事。
//
// Go を読める必要はない。以下でどこに何があるか示してある。まず小さなヘルパー、
// 次に自前の Redis クライアント、それから2つのロール —「遅い名簿」と「サービス
// 本体」。このラボの主眼は、ファイル終盤の setupAPI で起きる。
//
// 読むときにつまずかないための、言語の3つの約束事:
//
//	func 名前(引数) (返すもの) { ... } — 関数の宣言;
//	関数はしばしば複数の値を一度に返し、その最後がエラー:
//	err == nil は「うまくいった」、err != nil は「うまくいかなかった」と読む;
//	// で始まる行はコメントで、プログラムの動作には影響しない。
//
// このファイルは隣の Dockerfile が、ノートPC上でビルドする: docker build ... app/ — README 参照。
package main

// このファイルが使うライブラリの一覧。どれもすべて標準、Go の配布物に含まれる。
// サードパーティは一行もない。ビルドはインターネットへ行かず、誰かの他人のパッケージが
// 公開リポジトリから削除されても壊れない。
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

// ---------------------------------------------------------------- 環境

// env は環境変数を読み、それが空または未設定なら、フォールバック値を返す。
// そこからマニフェストで見られる性質が生まれる。アプリケーションの挙動は、
// イメージの再ビルドではなく、YAML の一行とポッドの再起動で変わる。
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — 数値についての同じもの。変数が数値でなかった場合、アプリケーションは
// 落ちない。ログに書いてフォールバック値を取る。マニフェストのタイプミスがサービスを
// 落としてはならない — ログで気づけるべきだ。
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("%s=%q は数値ではありません。%d を使います", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// Redis 自身が送ってきたエラー（「-」で始まる行）: 例えば
// NOAUTH や WRONGTYPE。これをネットワークエラーと区別するのは重要だ。再接続しても
// 誤ったパスワードは直らず、再試行は原因を覆い隠すだけ。
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — キャッシュへの持続的な TCP 接続1つと、ロック mu。2つの同時
// リクエストがこの接続に混ざって書き込まないようにするため。接続は開いたままに
// する。リクエストごとに新しく張るのは、リクエスト自体より高くつく。
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked は接続を開き、パスワードが設定されていれば、ただちに AUTH
// コマンドで名乗る。名前の Locked 接尾辞は「ロック mu を既に取得しているときだけ
// 呼べ」の意 — これはこれらの関数間の取り決めで、言語の性質ではない。
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

// do はコマンドを実行し、接続が切れたら一度だけ再接続する。
// 値、「値がある」フラグ、そしてエラーを返す。
// 試行はちょうど2回、十回ではない。Redis が拒否で応答するなら、再試行はユーザーへの
// 応答を遅らせ、原因をログ中に散らすだけ。
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

// commandLocked は Redis が理解する形でコマンドを送る。まず後続の
// チャンク数、次に各チャンクの長さと内容。3秒のデッドラインは、
// 固まったキャッシュが名簿への往復より長く応答を遅らせないため。
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

// readReplyLocked は応答を解析する。行の最初の文字が何が届いたかを告げ、
// 関数全体は5つのケースの処理だ。「$-1」は別途重要で、これは故障ではなく、
//「そのキーはない」、つまり普通のキャッシュミス。
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
	case '+', ':': // 単純な文字列または数値
		return line[1:], true, nil
	case '-': // サーバーからのエラー
		return "", false, &redisError{msg: line[1:]}
	case '$': // 既知の長さの文字列; -1 は「キーなし」の意
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // キャッシュミスはエラーではない
		}
		buf := make([]byte, n+2) // 末尾の \r\n のための +2
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: 予期しない応答 %q", line)
	}
}

// Get と SetTTL — サービスが使うコマンドの全て。キャッシュにこれ以上は
// 求めないので、ここのクライアントは1ページに収まる。
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL は値を入れ、ただちに生存期間を割り当てる。1つのコマンドで、
// SET と EXPIRE ではなく。2つのコマンドの間に接続が切れると、キーは
// キャッシュに永久に残ってしまう。
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- データ

// employee — サービスが外部に返し、キャッシュに入れるもの。右側の `json:"id"` タグは
// JSON でのフィールド名を定める。Go ではフィールドは大文字始まりのときだけ外から見え、JSON では
// 小文字が慣例で、これらのタグが両者を結びつける。
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// データは架空。学習用スタンドに本物の人事情報はないし、あってはならない。
var surnames = []string{
	"田中", "佐藤", "斎藤", "鈴木",
	"高橋", "加藤", "吉田", "松本",
}

var departments = []string{
	"警備部", "経理部", "開発部",
	"物流部", "人事部", "総務部",
}

// データは架空だが、同じ識別子には同じ:
// さもないと応答から、キャッシュなのか名簿への往復なのか区別できないだろう。
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

// writeJSON は応答を返す。コンテンツタイプ付きのヘッダー、応答コード、そして本体。
// SetEscapeHTML(false) が必要なのは、ロシア語の文字や引用符が \u シーケンスに
// 変わらないようにするため — さもないと応答を目で解読するはめになる。
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("応答を返せませんでした: %v", err)
	}
}

// employeeID はクエリ文字列から ?id= を取り出す。空の識別子は「0」にされ、
// キャッシュのキーが常に定まった形を持ち、末尾のない
//「employee:」というキーが作られないようにする。
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- メイン

// main — エントリーポイント。プログラムの動作はここから始まる。HTTP サーバーを立ち上げ、
// それに /healthz を、そして MODE を見て2つのロールのどちらかを掛ける。ロールは起動時に
// 一度選ばれ、ポッドの一生の間は変わらない。
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "不明")

	mux := http.NewServeMux()
	// /healthz は両方のロールに存在する。マニフェストに書かれた readiness プローブがここを叩く。
	// 常に応答し、何も検査しない — ここでのプローブの仕事は、プロセスが立ち上がってポートを
	// 待ち受けていると告げることで、システムの健全性を評価することではない。
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 2つのロールへの分岐。未知の値は「なんとなく」起動する理由にはならない。
	// ただちに、はっきりしたメッセージとともにクラッシュする。誤ったロールでの黙った起動は、
	// ログを睨む一時間の代償を払わせる。
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("不明な MODE=%q です。使用できる値は hr と api", mode)
	}

	// ReadHeaderTimeout は、クライアントがリクエストを始めて黙り込んだら接続を閉じる。これがないと、
	// そうした「クライアント」が数人いれば、何も要求せずにサーバー全体を占有するのに十分。
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("モード %s、ポート %s、ポッド %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — レガシー名簿のスタブ。その唯一の特徴は
// 遅いことで、これは偶然ではなく課題の本質。
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q を解析できませんでした。800ms を使います", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("名簿は %s で応答します", delay)

	// このロールの唯一のアドレス。time.Sleep が「レガシーシステム」の全て。まさにその
	// 数百ミリ秒のために、ラボにキャッシュが登場する。応答の source フィールドは、
	// データがキャッシュではなくここから来たことを示す。
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

// setupAPI —「パス」サービス本体。ここにキャッシュのロジックが宿り、ここに
//「なぜ応答が cache: off と言うのか」という問いの答えもある。
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// キャッシュは REDIS_ADDR が存在すること自体でオンになる — cache-patch.yaml が
	// 追加する変数だ。変数がなければ cache は空のまま、以下の
	// `if cache != nil` の検査はすべて発火せず、サービスは元通りに動く。
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("キャッシュ有効: %s、レコードの生存期間 %d 秒", addr, ttl)
	} else {
		log.Printf("キャッシュ無効: REDIS_ADDR が未設定のため、すべてのリクエストが名簿へ行きます")
	}

	// 拡大した接続プールを持つ別のクライアント。さもないと負荷時に、
	// 時間の半分が名簿への TCP 接続の確立に費やされ、
	// 測定は名簿の遅延ではなく、我々自身の雑さを示してしまう。
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// ルート「/」— サービスの名刺。バージョン、ポッド、ノード、レジストリ、キャッシュモード。cache フィールドから
	// ログを覗いたりマニフェストを解析したりせずに、off か redis かがすぐ分かる。
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

	// ラボの主要なアドレス。動作の順番: キャッシュに尋ね、ミスなら名簿へ行き、
	// 応答をキャッシュに入れる。このラボで測るものはすべて、この四十行で
	// 起きる。
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// キャッシュのキー —「employee:」に識別子を加えたもの。接頭辞が必要なのは、異なる種類の
		// レコードが衝突しないため。キャッシュはアプリケーション全体で1つ、その中の名前は平坦だ。
		key := "employee:" + id

		var emp employee
		fromCache := false

		// 第一段階: キャッシュに尋ねる。3つの結末 — エラー、ヒット、ミス — は
		// それぞれ別に処理され、その違いはここでは本質的だ。
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// キャッシュが使えない — それはユーザーにエラーを返す理由にはならない。
				// 名簿へ行く。遅いが、正しい。
				log.Printf("キャッシュが使えません (%v)。名簿へ行きます", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("キャッシュのキー %s にゴミが入っています。名簿へ行きます", key)
				}
			}
		}

		// 第二段階: ミス、または使えないキャッシュ — 名簿へ行く。遅いが、それが
		// 唯一の真実の源だ。応答をキャッシュに入れる。もし入れるのに失敗しても、
		// ユーザーがそれを知る必要はない — 彼らはもう応答を得ており、ただ
		// 次のリクエストがまた遅くなるだけ。
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("名簿が応答しませんでした: %v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "従業員名簿が利用できません",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("キャッシュへの書き込みに失敗しました: %v", err)
					}
				}
			}
		}

		// cached と took_ms のフィールド — これらすべてが始められた目的だ。そこから、リクエストが
		// キャッシュにヒットしたか否か、何ミリ秒かかったかが分かる。check.sh もそれらを読む、
		// ラボを合格と数えるか否かを決めるときに。
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

// cacheMode は内部状態を応答用の一語に翻訳する: off または redis。
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — HTTP 経由での名簿への往復。識別子はエスケープされる
// (url.QueryEscape): これがないと id 内の空白や「&」がリクエスト URL を壊してしまう。
// 応答の本体は必ず閉じられる (defer)、さもないと負荷時に接続が尽きる。
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("名簿の応答 %s", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
