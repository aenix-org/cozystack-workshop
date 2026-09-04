// 实验 6 · 你自己的私有镜像仓库。「通行证」服务，教学版本。
//
// 这个程序做什么。它启动一个 Web 服务器，并在两个路径上作出响应。
// /healthz 路径返回一个简短的「ok」：集群据此得知某个副本存活
// 且已准备好接收流量。/ 路径返回一个 JSON 格式的小型响应（形如
//「字段: 值」的文本），列出是哪个副本、在哪个节点上处理了这个
// 请求。仅此而已：没有数据库，没有磁盘，没有状态。这是有意为之——在这个实验里
// 重要的不是代码，而是它进入集群所走的路径：
// 源码 -> 镜像 -> 你的仓库 -> 集群。
//
// 你不需要会读这个 Go 文件，只要理解这里发生了什么就够了；
// 下面的注释是按照你第一次见到 Go 的假设来写的。
//
// 没有外部依赖：只用到标准库，它随编译器一起
// 附带而来。因此构建过程不会为了库而访问互联网，
// 你可以在出网被封闭的地方构建镜像——而这
// 恰恰就是整个实验的起点所在。
//
// 它不是直接构建的，而是通过相邻的 Dockerfile，用命令
// docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
//
// package main —— Go 用这种方式标记一个可以运行的程序（与库
// 相对）。运行时的入口点是文件最底部的 main 函数。
package main

// 我们从标准库中取用的东西：
//   encoding/json —— 以 JSON 格式组装响应
//   log           —— 写日志消息；在容器里它们进入标准输出，
//                   kubectl logs 从那里取走它们。容器内部没有日志文件，
//                   也不需要创建——这对容器来说是正常的
//   net/http      —— Web 服务器本身
//   os            —— 读取环境变量
//   time          —— 响应里的时间戳以及服务器超时
import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// 响应的形态：应用向外报告的关于自身的一组字段。它们几乎都是
// 应用从集群那里获知的：我们不计算也不猜测它们，而是集群
// 自己把它们放进环境变量（见 passes.yaml，env 块和 downward API）。
//
// 右侧反引号中的文本是最终 JSON 里的字段名。没有它，字段就会以
// Namespace 而不是 namespace 的形式进入响应；check.sh 里的检查查找的是小写的「pod」。
type identity struct {
	Service   string `json:"service"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Node      string `json:"node"`
	Namespace string `json:"namespace"`
	Registry  string `json:"registry"`
	Time      string `json:"time"`
}

// 读取一个环境变量，如果它缺失或为空——就返回一个备用
// 值。之所以需要它，是为了让程序也能在集群之外运行，不需要任何一项
// 配置：它不会崩溃，而会老实地在响应里写上「未知」。
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// 入口点：程序的工作从这个函数开始。
func main() {
	// 监听哪个端口。端口可以用 PORT 变量覆盖而无需重新构建
	// 镜像，但默认是 8080 —— 与 passes.yaml（containerPort）
	// 以及 Dockerfile（EXPOSE）里是同一个数字。一旦不一致——Service 就会敲一扇关着的门。
	port := env("PORT", "8080")

	// 路由表：哪个路径由哪个处理器来处理。
	mux := http.NewServeMux()

	// 就绪检查。集群往这里敲门，在得到响应之前
	// 不会把流量发到该副本上。它总是快速作答，什么都不检查：
	// 应用没有什么可检查的，它既没有数据库也没有磁盘。
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 主响应。我们组装那些字段，并把它们作为一个 JSON 返回。这些值是在
	// 每次请求时读取的，因此服务的第二个副本会用它自己的 pod 名字来作答——
	// 在实验里正是通过这个名字看出确实有两个副本。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body := identity{
			Service:   "passes-api",
			Version:   env("APP_VERSION", "v1"),
			Pod:       env("POD_NAME", "неизвестно"),
			Node:      env("NODE_NAME", "неизвестно"),
			Namespace: env("POD_NAMESPACE", "неизвестно"),
			Registry:  env("IMAGE_REGISTRY", "не указан"),
			Time:      time.Now().UTC().Format(time.RFC3339),
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		// SetEscapeHTML(false)，否则西里尔字母以及像 < 这样的字符会变成 \uXXXX
		// 使得响应在终端里变得不可读。
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("не удалось отдать ответ: %v", err)
		}
	})

	// 服务器设置。ReadHeaderTimeout —— 在断开连接之前
	// 等待请求头多久。这五秒不是为了速度：没有这个超时，
	// 打开后被丢弃的连接会不断堆积，直到吃光容器的内存，
	// 而内存受清单里的 limit 限制。
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// 你在 kubectl logs 里看到的第一样东西。这一行是为了把「应用
	// 没有启动」和「启动了，但不作答」区分开——这是不同的诊断。
	log.Printf("passes-api %s слушает порт %s, под %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "неизвестно"))
	// 我们启动服务器并一直运行，直到被停止。如果端口被占用或服务器
	// 崩溃——我们写下原因并以错误退出。集群会看到结束了的进程
	// 并重新拉起一个副本；不需要在程序内部去修复重启。
	log.Fatal(srv.ListenAndServe())
}
