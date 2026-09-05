// “通行证”服务，带缓存的版本。一个可执行文件，两种角色。
//
//	MODE=hr   — 遗留员工目录的桩。响应很慢，
//	            与真实系统的方式完全一致：HR_DELAY 默认 800 毫秒。
//	MODE=api  — “通行证”服务本身。会去查目录，如果设置了 REDIS_ADDR，
//	            则先查缓存。
//
// 一个角色兼顾两种情况，因为必须只有一个镜像：注册表里两个几乎相同的
// 镜像，就是两个可能忘记更新版本的地方。
//
// 没有任何外部依赖，只用标准库。这里的 Redis 客户端
// 是自己写的，大约五十行 —— Redis 协议是文本的，GET/SET 一个函数
// 就能容纳。生产环境里会用现成的库；这里更重要的是让构建
// 不去联网拉取包。
//
// 不需要会读 Go：下面标注了每样东西的位置。先是小的辅助函数，
// 然后是自制的 Redis 客户端，再是两种角色 ——“慢目录”和“服务
// 本身”。这个实验真正的重点发生在 setupAPI 里，靠近文件末尾。
//
// 语言的三条约定，以便阅读时不会磕绊：
//
//	func 名字(参数) (返回什么) { ... } —— 函数声明；
//	函数常常一次返回多个值，其中最后一个是错误：
//	err == nil 读作“顺利”，err != nil —— “没顺利”；
//	以 // 开头的行是注释，它们不影响程序的运行。
//
// 该文件由相邻的 Dockerfile 在虚拟机上构建：docker build ... app/ —— 见 README。
package main

// 本文件所使用的库的列表。每一个都是标准库，来自 Go 发行版。
// 没有任何一行第三方代码：构建不会联网，也不会因为
// 别人的某个包从公共仓库里被删掉而中断。
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

// ---------------------------------------------------------------- 环境变量

// env 读取一个环境变量，如果它为空或未设置，则返回后备
// 值。因此才有你在清单里看到的那个特性：应用的行为
// 通过 YAML 里的一行加上一次 pod 重启来改变，而不是通过重新构建镜像。
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envInt —— 对数字做同样的事。如果变量里不是数字，应用不会
// 崩溃：它写入日志并采用后备值。清单里的一个笔误不应把
// 服务搞垮 —— 它应当在日志里可见。
func envInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("值 %s=%q 不是数字，采用 %d", key, v, fallback)
	}
	return fallback
}

// ---------------------------------------------------------------- Redis

// 由 Redis 本身发来的错误（以“-”开头的行）：例如
// NOAUTH 或 WRONGTYPE。把它与网络错误区分开很重要：重连
// 无法解决密码错误，而重试只会掩盖原因。
type redisError struct{ msg string }

func (e *redisError) Error() string { return "redis: " + e.msg }

// redisClient —— 一条到缓存的持久 TCP 连接，外加一把锁 mu，好让两个
// 并发请求不会交错地往这条连接里写。我们让连接保持
// 打开：为每个请求建立新连接比请求本身还贵。
type redisClient struct {
	addr     string
	password string

	mu   sync.Mutex
	conn net.Conn
	rd   *bufio.Reader
}

// connectLocked 打开连接，如果设置了密码，则立即用 AUTH 命令
// 表明身份。名字里的 Locked 后缀意为“仅在锁 mu
// 已被持有时才调用”—— 这是这些函数之间的约定，而不是语言的特性。
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

// do 执行一条命令，如果连接断开则重连一次。
// 返回值、一个“值存在”的标志，以及一个错误。
// 恰好两次尝试，而不是十次：如果 Redis 以拒绝作答，重试只会拖延
// 给用户的响应，并把原因抹散到各处日志里。
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
			return "", false, err // 是 Redis 本身作答 —— 重试帮不上忙
		}
		r.closeLocked() // 网络问题：断开并再试一次
	}
	return "", false, lastErr
}

// commandLocked 以 Redis 能理解的形式发送命令：先是
// 后面跟着多少个片段，然后是每个片段的长度和内容。三秒的截止期限 ——
// 是为了让卡住的缓存不会把响应拖得比去查目录本身还久。
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

// readReplyLocked 解析响应。行的第一个字符说明到底来了什么，
// 整个函数就是对五种情况的处理。“$-1”这一种尤其重要：它不是故障，
// 而是“没有这样的键”，也就是一次普通的缓存未命中。
func (r *redisClient) readReplyLocked() (string, bool, error) {
	line, err := r.rd.ReadString('\n')
	if err != nil {
		return "", false, err
	}
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return "", false, errors.New("redis: 空响应")
	}
	switch line[0] {
	case '+', ':': // 一个简单字符串或一个数字
		return line[1:], true, nil
	case '-': // 来自服务器的错误
		return "", false, &redisError{msg: line[1:]}
	case '$': // 已知长度的字符串；-1 表示“没有这样的键”
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
		return "", false, fmt.Errorf("redis: 无法识别的响应 %q", line)
	}
}

// Get 和 SetTTL —— 服务所用命令的全部集合。缓存不再需要
// 别的东西，所以这里的客户端一页就装得下。
func (r *redisClient) Get(key string) (string, bool, error) { return r.do("GET", key) }

// SetTTL 存入值并立即赋予一个生存期。用一条命令，而不是
// SET 加 EXPIRE：在两条命令之间连接可能断开，那样键
// 就会永远留在缓存里。
func (r *redisClient) SetTTL(key, val string, ttlSeconds int) error {
	_, _, err := r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
	return err
}

// ---------------------------------------------------------------- 数据

// employee —— 服务对外返回并放入缓存的东西。右边的 `json:"id"` 标签
// 设定 JSON 里的字段名：在 Go 里字段只有首字母大写才从外部可见，而在 JSON 里
// 习惯用小写，这些标签把两者关联起来。
type employee struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Dept string `json:"dept"`
}

// 数据是虚构的。教学台架里没有、也不应有真实的人事资料。
var surnames = []string{
	"王军", "林安", "郑平", "陈梅",
	"赵东", "高艳", "徐帅", "冯宁",
}

var departments = []string{
	"保卫处", "财务部", "研发部",
	"物流部", "人事处", "行政处",
}

// 数据是虚构的，但对同一个标识符是一致的：
// 否则就无法从响应判断这是缓存还是去查了目录。
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

// writeJSON 返回响应：带内容类型的头、响应码和响应体。
// 需要 SetEscapeHTML(false)，好让俄文字母和引号不变成
// \u 序列 —— 否则响应就得靠肉眼去解码。
func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		log.Printf("返回响应失败: %v", err)
	}
}

// employeeID 从查询字符串里取出 ?id=。空的标识符被转成“0”，
// 好让缓存里的键始终有确定的形状，也不会生成一个
// 没有尾巴的键“employee:”。
func employeeID(r *http.Request) string {
	id := r.URL.Query().Get("id")
	if id == "" {
		return "0"
	}
	return id
}

// ---------------------------------------------------------------- 主程序

// main —— 入口点：程序的工作从这里开始。它启动 HTTP 服务器，挂上
// /healthz，并根据 MODE 挂上两种角色之一。角色在启动时选定一次，
// 在 pod 的生命周期内不会改变。
func main() {
	mode := env("MODE", "api")
	port := env("PORT", "8080")
	pod := env("POD_NAME", "未知")

	mux := http.NewServeMux()
	// /healthz 在两种角色里都有：清单里描述的就绪探针就是敲这里。
	// 它总是应答，且什么都不检查 —— 探针在这里的任务是判断
	// 进程已经起来并在监听端口，而不是评估系统的健康状况。
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 分岔到两种角色。未知的取值不足以成为“随便”启动的理由：
	// 我们立即失败，并给出清楚的消息。以错误角色悄悄启动，代价会是
	// 一个小时对着日志发呆。
	switch mode {
	case "hr":
		setupHR(mux, pod)
	case "api":
		setupAPI(mux, pod)
	default:
		log.Fatalf("未知的 MODE=%q，允许的取值为 hr 和 api", mode)
	}

	// ReadHeaderTimeout 会在客户端开始了请求却沉默时关闭连接。没有它，
	// 几个这样的“客户端”就足以占满整个服务器，而它们什么都没请求。
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("模式 %s，端口 %s，pod %s", mode, port, pod)
	log.Fatal(srv.ListenAndServe())
}

// setupHR —— 遗留目录的桩。它唯一的特别之处在于
// 它很慢，而这不是偶然，正是这项任务的实质。
func setupHR(mux *http.ServeMux, pod string) {
	delay, err := time.ParseDuration(env("HR_DELAY", "800ms"))
	if err != nil {
		log.Printf("HR_DELAY=%q 无法解析，采用 800ms", os.Getenv("HR_DELAY"))
		delay = 800 * time.Millisecond
	}
	log.Printf("目录响应耗时 %s", delay)

	// 这个角色唯一的地址。time.Sleep 就是整个“遗留系统”：正是那几百
	// 毫秒，为了它实验里才出现了缓存。响应里的 source 字段
	// 表明数据来自这里，而不是来自缓存。
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

// setupAPI —— “通行证”服务本身。缓存逻辑就住在这里，对
// “为什么响应里写着 cache: off”这个问题的答案也在这里。
func setupAPI(mux *http.ServeMux, pod string) {
	hrURL := env("HR_URL", "http://hr-legacy")
	ttl := envInt("CACHE_TTL", 60)
	version := env("APP_VERSION", "v2")

	// 缓存靠 REDIS_ADDR 的存在这一事实本身来开启 —— 就是
	// cache-patch.yaml 所添加的那个变量。没有该变量 —— cache 保持为空，下面所有
	// `if cache != nil` 的检查都不触发，服务照旧工作。
	var cache *redisClient
	if addr := os.Getenv("REDIS_ADDR"); addr != "" {
		cache = &redisClient{addr: addr, password: os.Getenv("REDIS_PASSWORD")}
		log.Printf("缓存已启用: %s，记录生存期 %d 秒", addr, ttl)
	} else {
		log.Printf("缓存已禁用: 未设置 REDIS_ADDR，每个请求都会去查目录")
	}

	// 一个单独的、连接池更大的客户端：否则在负载下
	// 一半时间会耗在建立到目录的 TCP 连接上，
	// 而测量出来的就不是目录的延迟，而是我们自己的马虎。
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConnsPerHost = 64
	hrClient := &http.Client{Timeout: 10 * time.Second, Transport: tr}

	// 根路径“/” —— 服务的名片：版本、pod、节点、注册表和缓存模式。从 cache 字段
	// 立刻就能看到 off 还是 redis，无需翻日志，也无需解析清单。
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

	// 实验的主地址。动作的顺序：问缓存，未命中就去查目录，
	// 把答案放进缓存。你在这个实验里测量的一切，都发生在这四十
	// 行里。
	mux.HandleFunc("/employee", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		id := employeeID(r)
		// 缓存里的键是“employee:”加上标识符。需要这个前缀，好让不同种类
		// 的记录不相撞：整个应用共用一个缓存，而其中的名字是扁平的。
		key := "employee:" + id

		var emp employee
		fromCache := false

		// 第一步：问缓存。三种结果 —— 错误、命中、未命中 —— 各自
		// 处理不同，而它们之间的区别在这里至关重要。
		if cache != nil {
			raw, found, err := cache.Get(key)
			switch {
			case err != nil:
				// 缓存不可用 —— 这不足以成为给用户返回错误的理由。
				// 我们去查目录：慢，但正确。
				log.Printf("缓存不可用 (%v)，改为去查目录", err)
			case found:
				if json.Unmarshal([]byte(raw), &emp) == nil {
					fromCache = true
				} else {
					log.Printf("缓存中键 %s 下存放的是垃圾数据，改为去查目录", key)
				}
			}
		}

		// 第二步：未命中或缓存不可用 —— 我们去查目录。慢，但它是
		// 唯一的事实来源。我们把答案放进缓存；如果放不进去，
		// 用户不必知道 —— 他已经拿到了自己的答案，只不过
		// 下一个请求又会很慢。
		if !fromCache {
			fetched, err := fetchEmployee(hrClient, hrURL, id)
			if err != nil {
				log.Printf("目录未响应: %v", err)
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
						log.Printf("写入缓存失败: %v", err)
					}
				}
			}
		}

		// cached 和 took_ms 字段就是这一切的目的所在：从它们能看出请求是否命中了
		// 缓存，以及花了多少毫秒。check.sh 在决定
		// 实验是否通过时，读的也是它们。
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

// fetchEmployee —— 通过 HTTP 去查目录。标识符会被转义
// （url.QueryEscape）：没有它，id 里的空格或“&”会把请求地址弄散架。
// 响应体必定会被关闭（defer），否则在负载下连接会耗尽。
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
