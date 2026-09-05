// 「通行证」服务，带缓存的版本。一个可执行文件，两种角色。
//
//	MODE=hr   — 遗留员工目录的桩程序。响应很慢，
//	            正如真实系统那样：HR_DELAY 默认为 800 毫秒。
//	MODE=api  — 「通行证」服务本身。会访问目录，如果设置了 REDIS_ADDR，
//	            则先查缓存。
//
// 两种情况共用一个角色，因为镜像必须是单一的：注册表里两个几乎一样的
// 镜像，就是两个可能忘记升级版本号的地方。
//
// 没有任何外部依赖，只用标准库。这里的 Redis 客户端是
// 自己写的，五十行——Redis 协议是文本的，对于 GET/SET 一个函数
// 就装得下。生产环境里会用现成的库；这里更重要的是让构建
// 不必上网去取包。
//
// 不需要会读 Go：下面标注了各部分的位置。先是小的辅助函数，
// 然后是自制的 Redis 客户端，再然后是两种角色——「慢目录」和「服务
// 本身」。这个实验室真正围绕的重点发生在 setupAPI 里，靠近文件末尾。
//
// 语言的三条约定，读起来就不会磕绊：
//
//	func 名字(参数) (返回什么) { ... } — 函数声明；
//	函数常常一次返回多个值，其中最后一个是错误：
//	err == nil 读作「没出问题」，err != nil — 「出问题了」；
//	以 // 开头的行是注释，不影响程序的运行。
//
// 文件由旁边的 Dockerfile 在笔记本上构建：docker build ... app/ — 见 README。
package main

// 本文件用到的库的清单。每一个都是标准库，来自 Go 的发行版。
// 没有一行第三方代码：构建不上网，也不会因为
// 别人的外部包从公共仓库里被删除而崩掉。
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

// ---------------------------------------------------------------- 环境

// env 读取环境变量，如果它为空或未设置，则返回后备
// 值。由此得到你在清单里看到的特性：应用的行为
// 用 YAML 里的一行加上一次 pod 重启就能改变，而不用重新构建镜像。
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt — 对数字做同样的事。如果变量里不是数字，应用不会
// 崩溃：它会写日志并采用后备值。清单里的笔误不该让
// 服务倒下——它应该在日志里显眼可见。
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("%s=%q 不是数字，采用 %d", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// Redis 自己发来的错误（以「-」开头的一行）：例如
// NOAUTH 或 WRONGTYPE。把它和网络错误区分开很重要：重新连接
// 救不了错误的密码，而重试只会掩盖原因。
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient — 一条到缓存的持久 TCP 连接，加上一把锁 mu，好让两个
// 并发请求不至于把内容混着写进这条连接。我们让连接保持
// 打开：每个请求都新建一条，比请求本身还贵。
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked 打开连接，如果设置了密码，就立刻用 AUTH 命令
// 自我介绍。名字里的 Locked 后缀意思是「只在锁 mu
// 已经持有时才调用」——这是这些函数之间的约定，而非语言的特性。
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

// do 执行一条命令，如果连接断了就重连一次。
// 返回值、一个「值存在」标志和一个错误。
// 尝试正好两次，而不是十次：如果 Redis 以拒绝作答，重试只会拖延
// 给用户的响应，并把原因摊散到各处日志里。
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
			return "", false, err // Redis 自己作了答——重试也没用
		}
		r.closeLocked() // 网络问题：断开再试一次
	}
	return "", false, lastErr
}

// commandLocked 以 Redis 能懂的形式发送命令：先是
// 后面有多少个块，再是每个块的长度和内容。三秒的截止期限是
// 为了让卡住的缓存别把响应拖得比访问目录本身还久。
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

// readReplyLocked 解析应答。行的第一个字符告诉你到底来了什么，
// 整个函数就是对五种情况的处理。「$-1」这个情况单独重要：它不是故障，
// 而是「没有这个键」，也就是普通的缓存未命中。
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: 空应答")
	}
	switch line[0] {
	case '+', ':': // 简单字符串或数字
		return line[1:], true, nil
	case '-': // 来自服务器的错误
		return "", false, &redisError{msg: line[1:]}
	case '$': // 已知长度的字符串；-1 表示「没有该键」
		n, err := strconv.Atoi(line[1:])
		if err != nil {
			return "", false, err
		}
		if n < 0 {
			return "", false, nil // 缓存未命中不是错误
		}
		buf := make([]byte, n+2) // +2 是给末尾的 \r\n
		if _, err := io.ReadFull(r.rd, buf); err != nil {
			return "", false, err
		}
		return string(buf[:n]), true, nil
	default:
		return "", false, fmt.Errorf("redis: 无法识别的应答 %q", line)
	}
}

// Get 和 SetTTL — 服务所用命令的全部。缓存那边再没有别的
// 需求了，所以这里的客户端能装在一页纸上。
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL 放入值并立刻指定存活时间。用一条命令，而不是
// SET 加 EXPIRE：两条命令之间连接可能断掉，那样键
// 就会永远留在缓存里。
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- 数据

// employee — 服务对外返回并放进缓存的东西。右边的 `json:"id"` 标签
// 设定 JSON 里的字段名：在 Go 里字段只有首字母大写才对外可见，而在 JSON 里
// 习惯用小写，这些标签把两者关联起来。
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// 数据是编造的。教学环境里没有、也不该有真实的人事记录。
var surnames = []string{
	"王军", "林安", "郑平", "陈梅",
	"赵东", "高艳", "徐帅", "冯宁",
}

var departments = []string{
	"保卫处", "财务部", "研发部",
	"物流部", "人事处", "行政处",
}

// 数据是编造的，但对同一个标识符是相同的：
// 否则就无法从响应里判断这是缓存还是访问了目录。
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

// writeJSON 发出响应：带内容类型的头、响应码和响应体。
// SetEscapeHTML(false) 是为了让俄文字母和引号不被变成
// \u 序列——否则就得用肉眼去解码响应了。
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("无法返回响应: %v", err)
	}
}

// employeeID 从查询串里取出 ?id=。空标识符转成「0」，
// 好让缓存里的键始终有确定的形状，也不会出现没有尾巴的
// 「employee:」键。
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- 主程序

// main — 入口点：程序的运行从这里开始。它启动一个 HTTP 服务器，给它
// 挂上 /healthz，并根据 MODE 挂上两种角色之一。角色在启动时选定一次，
// 在 pod 的一生中不再改变。
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "未知")

	mux := http.NewServeMux()
	// /healthz 在两种角色里都有：清单里描述的就绪探针会来敲这里。
	// 它总是应答，什么也不检查——探针在这里的任务是判断
	// 进程是否起来并在监听端口，而不是评估系统的健康。
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 分岔到两种角色。未知的值不是「随便」启动的理由：
	// 我们立刻崩溃，并给出明确的信息。以错误角色悄无声息地启动，代价是
	// 一个小时盯着日志。
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("未知的 MODE=%q，允许的值为 hr 和 api", mode)
	}

	// ReadHeaderTimeout 会在客户端开始请求后又沉默时关闭连接。没有它，
	// 几个这样的「客户端」就足以占满整个服务器，而什么也没请求。
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("模式 %s，端口 %s，pod %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR — 遗留目录的桩程序。它唯一的特点在于
// 它很慢，这不是偶然，而是任务的实质。
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("无法解析 HR_DELAY=%q，采用 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("目录响应耗时 %s", delay)

	// 这个角色唯一的地址。time.Sleep 就是整个「遗留系统」：那几百
	// 毫秒，正是为它实验室里才出现了缓存。响应里的 source 字段
	// 表明数据来自这里，而不是缓存。
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

// setupAPI — 「通行证」服务本身。缓存逻辑住在这里，「为什么响应里
// 写着 cache: off」这个问题的答案也在这里。
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// 缓存靠 REDIS_ADDR 这个变量存在与否来开启——就是
	// cache-patch.yaml 添加的那个。没有这个变量——cache 就保持为空，下面所有
	// `if cache != nil` 的检查都不触发，服务照旧工作。
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("缓存已开启：%s，记录存活时间 %d 秒", addr, ttl)
	} else {
		log.Printf("缓存已关闭：未设置 REDIS_ADDR，每个请求都会访问目录")
	}

	// 一个单独的、连接池加大的客户端：否则在负载下
	// 一半的时间会花在建立到目录的 TCP 连接上，
	// 测量出来的就不是目录的延迟，而是我们自己的马虎。
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// 根路径「/」——服务的名片：版本、pod、节点、注册表和缓存模式。从 cache 字段
	// 一眼就能看出 off 还是 redis，不用翻日志也不用解析清单。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{
			"service":   "passes-api",
			"version":   version,
			"pod":       pod,
			"node":      env("NODE_NAME", "未知"),
			"namespace": env("POD_NAMESPACE", "未知"),
			"registry":  env("IMAGE_REGISTRY", "未设置"),
			"cache":     cacheMode(cache),
			"cache_ttl": ttl,
			"hr_url":    hrURL,
			"time":      time.Now().UTC().Format(time.RFC3339),
		})
	})

	// 实验室的主地址。动作顺序：问缓存，未命中就去目录，
	// 把响应放进缓存。你在这个实验室里测量的一切，都发生在这四十
	// 行里。
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// 缓存里的键——「employee:」加上标识符。前缀是为了让不同种类
		// 的记录不相撞：缓存全应用共用一个，而里面的名字是扁平的。
		key := "employee:" + id

		var emp employee
		fromCache := false

		// 第一步：问缓存。三种结果——错误、命中、未命中——各自
		// 处理不同，它们之间的区别在这里是根本性的。
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// 缓存不可用——这不是给用户返回错误的理由。
				// 我们去目录：慢，但正确。
				log.Printf("缓存不可用（%v），改去访问目录", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("缓存中键 %s 下是垃圾数据，改去访问目录", key)
				}
			}
		}

		// 第二步：未命中或缓存不可用——我们去目录。慢，但它是
		// 唯一的真相来源。把响应放进缓存；如果放失败了，
		// 用户没必要知道——他已经拿到了自己的响应，只不过
		// 下一个请求又会很慢。
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("目录未响应：%v", err)
				writeJSON(w, http.StatusBadGateway, map[string]any{
					"error": "员工目录不可用",
					"pod":   pod,
				})
				return
			}
			emp = fetched
			if cache != nil {
				if b, err := json.Marshal(emp); err == nil {
					if err := cache.SetTTL(key, string(b), ttl); err != nil {
						log.Printf("无法写入缓存：%v", err)
					}
				}
			}
		}

		// cached 和 took_ms 字段——这一切的初衷所在：从它们能看出请求是否命中
		// 了缓存，以及花了多少毫秒。check.sh 在判定这个实验室
		// 算不算通过时，读的也是它们。
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

// cacheMode 把内部状态翻译成响应里的一个词：off 或 redis。
func cacheMode(c *redisClient) string {
	if c == nil {
		return "off"
	}
	return "redis"
}

// fetchEmployee — 通过 HTTP 访问目录。标识符会被转义
//（url.QueryEscape）：否则 id 里的空格或「&」会把请求地址拆散。
// 响应体一定要关闭（defer），否则在负载下连接会耗尽。
func fetchEmployee(c *http.Client, base, id string) (employee, error) {
	u := strings.TrimRight(base, "/") + "/employee?id=" + url.QueryEscape(id)
	resp, err := c.Get(u)
	if err != nil {
		return employee{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return employee{}, fmt.Errorf("目录返回 %s", resp.Status)
	}
	var emp employee
	if err := json.NewDecoder(resp.Body).Decode(&emp); err != nil {
		return employee{}, err
	}
	return emp, nil
}
