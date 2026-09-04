// 实验 6 · 你自己的私有镜像仓库。「通行证（Пропуск）」服务，教学版本。
//
// 这个程序做什么。它启动一个 Web 服务器，并在两个地址上作出响应。
// /healthz 地址返回一个简短的「ok」：集群通过它来判断某个副本是否存活，
// 以及是否准备好接收流量。/ 地址返回一个 JSON 格式的小型响应（形如
// 「字段: 值」的文本），其中列出了是哪个副本、在哪个节点上处理了
// 请求。仅此而已：没有数据库，没有磁盘，没有状态。这是有意为之——在这个实验里
// 有意思的不是代码，而是它进入集群所走的那条路径：
// 源码 -> 镜像 -> 你自己的仓库 -> 集群。
//
// 你不需要会读这个 Go 文件，只要理解这里发生了什么就够了；
// 下面的注释是按照你第一次见到 Go 来编写的。
//
// 没有外部依赖：只用到了标准库，它随编译器一起
// 附带而来。因此构建时不会到互联网去拉取库，你可以在
// 对外访问被封闭的环境里构建镜像——而整个实验
// 正是从这一点开始的。
//
// 它不是直接构建的，而是通过相邻的 Dockerfile 构建，用命令
// docker build --platform linux/amd64 -t HARBOR-HOST/passes/passes-api:v1 app/
//
// package main —— 在 Go 里就是这样标记一个可以运行的程序（相对于
// 库而言）。运行时的入口是文件最底部的 main 函数。
package main

// 我们从标准库里取用的东西：
//   encoding/json —— 把响应组装成 JSON 格式
//   log           —— 写入消息；在容器里它们会进入标准输出，
//                   kubectl logs 从那里把它们取走。容器内部没有日志文件，
//                   也不需要创建——这对容器来说是正常的
//   net/http      —— Web 服务器本身
//   os            —— 读取环境变量
//   time          —— 响应中的时间戳以及服务器超时
import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// 响应的形态：应用报告关于自身的一组字段。它们几乎全部——
// 都是应用从集群那里得知的：我们既不计算也不猜测它们，是集群
// 自己把它们放进环境变量的（见 passes.yaml，env 块和 downward API）。
//
// 右侧反引号里的文本是最终 JSON 中的字段名。没有它，字段就会以
// Namespace 而非 namespace 的形式进入响应；check.sh 里的检查查找的是小写的「pod」。
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
// 值。它的作用是让程序也能在集群之外运行，无需任何一项
// 配置：它不会崩溃，而会老实地在响应里写上「неизвестно」。
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// 入口点：程序的工作从这个函数开始。
func main() {
	// 监听哪个端口。端口可以用 PORT 变量来覆盖，无需重新构建
	// 镜像，但默认是 8080——与 passes.yaml（containerPort）
	// 和 Dockerfile（EXPOSE）里的数字相同。一旦不一致——Service 就会敲一扇关着的门。
	port := env("PORT", "8080")

	// 路由表：哪个地址由哪个处理器来服务。
	mux := http.NewServeMux()

	// 就绪检查。集群敲这里，在得到响应之前
	// 不会把流量放到副本上。它总是快速作答，什么都不检查：
	// 应用没有什么可检查的，它既没有数据库也没有磁盘。
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	// 主响应。我们把那些字段组装起来，作为一个 JSON 交出去。这些值是在
	// 每次请求时读取的，所以服务的第二个副本会用它自己的 pod 名称作答——
	// 在实验里，通过这个名称就能看到确实有两个副本。
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
		// SetEscapeHTML(false)，否则西里尔字母和像 < 这样的符号会变成 \uXXXX
		// 响应就会在终端里变得无法阅读。
		enc.SetEscapeHTML(false)
		if err := enc.Encode(body); err != nil {
			log.Printf("не удалось отдать ответ: %v", err)
		}
	})

	// 服务器设置。ReadHeaderTimeout —— 在切断连接之前，等待请求头
	// 多久。这五秒不是为了速度：没有这个超时，
	// 打开后被丢弃的连接会不断堆积，直到吃光容器的内存，
	// 而内存受到清单里那条限额的约束。
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// 你在 kubectl logs 里看到的第一样东西。这一行是为了区分「应用
	// 没有启动」和「启动了，但不响应」——这是两种不同的诊断。
	log.Printf("passes-api %s слушает порт %s, под %s",
		env("APP_VERSION", "v1"), port, env("POD_NAME", "неизвестно"))
	// 我们启动服务器并一直工作，直到被停止。如果端口被占用或服务器
	// 崩溃了——我们写下原因并以错误退出。集群会看到已结束的进程
	// 并重新拉起副本；无需在程序内部去修复重启这件事。
	log.Fatal(srv.ListenAndServe())
}
