# 实验 7 · 慢速后端前面的缓存

| | |
|---|---|
| **时间** | 50 分钟，其中 10 分钟在等待 |
| **证明了什么** | 缓存带来的收益是测量出来的，而不是嘴上说说：过去 800 ms，现在是个位数 |
| **需要准备** | 实验 0 的集群、实验 6 的 Harbor 和镜像、`kubectl`、`docker`、控制台访问权限 |

> ⚠️ **`workshopXX` 是占位符，不是名字。** 请替换成你自己的租户编号，否则命令会发到别人的租户，你会收到拒绝访问的错误——或者更糟，拿到别人的数据。你的编号和密码是一起发给你的。

## 为什么这很重要

服务「通行证」在运行，信息安全部门满意，镜像仓库是自己的。然后保安来了。

> 在门岗上，访客名单要花十秒钟才打开。人们排着队，我们盯着屏幕干等。以前是好好的。

来看看到底发生了什么。名单里的每一行是一位访客，每位访客都有一名邀请他的员工，而员工的资料并不在你这里。它们躺在一套 2011 年上线的人事系统里，那系统响应一个请求要 **800 毫秒**。屏幕上十二行——差不多十秒。

人事系统你没法重写：它不是你的，是别人的，而且它的改造需求排到了明年。加速它也不行，原因一样。

但你可以别那么频繁地去问它。一名员工的姓氏和部门大概几年才变一次。**每次**打开名单都去向那套慢速系统询问，是种浪费：只要问一次并记住答案就够了。

记住答案的那个地方，叫作缓存。今天我们就来装一个——而且更重要的是，**测量前后的差别**。不是「变快了」，而是一个具体的数字。

## 小词典

| 术语 | 是什么 | 类似……但 |
|---|---|---|
| **缓存** | 对重复问题的现成答案的快速存储 | **存储阵列上的读缓存**，但这里由应用决定缓存什么，而不是设备 |
| **Redis** | 完全驻留在内存中的键值存储 | 没有直接的对应物；最接近的是 memcached，如果你接触过的话 |
| **键（key）** | 在缓存中用来查找值的字符串 | **文件名**，但由你自己来起，而且起得怎样决定了一切 |
| **TTL（存活时间）** | 一条记录在自行消失前能存活多久 | **快照的保留期限**，但删除无需任何人参与，也没有定时任务 |
| **未命中（cache miss）** | 缓存里没有答案，只能去慢速的源头取 | **存储阵列上的读缓存未命中**，但这里的未命中付出的代价不是毫秒，而是一趟别人系统的往返 |
| **命中（cache hit）** | 在缓存里找到了答案 | **读缓存命中**，但这里由应用来记命中，而且它也在响应的 `cached` 字段里可见 |
| **Sentinel** | 一个监视 Redis、并在故障时重新指派主角色的服务 | **HA 代理**，但它运行在 Redis 内部，无需为它单独建集群 |
| **托管服务（managed service）** | 由平台替你安装、更新和备份的服务 | 你拿不到运行它那台机器的 root 权限——而这正是重点 |
| **Fortio** | 一个带 Web 界面和延迟直方图的负载生成器 | vSphere 里没有对应物：它不是测量基础设施的工具，而是测量服务的工具 |
| **p50 / p99** | 中位数和「最差的那几个百分比」：99% 的请求延迟不高于此值 | 平均延迟会骗人，这两个数字不会 |

## 两个 kubeconfig：别搞混

这个实验里又是两个集群。

| Kubeconfig | 是什么 | 我们在里面做什么 |
|---|---|---|
| `~/.kube/workshop` | Cozystack 管理集群，你的租户 | 查看 Redis：地址、状态 |
| `~/lab.kubeconfig` | **你的** 实验 0 里的实验集群 `lab` | 部署应用并测量 |

两个都从控制台里取：租户的那个在 Secrets 标签页的 `kubeconfig-tenant-workshopXX` Secret 里，集群的那个在你实验集群 `lab` 的访问区块里。

⚠️ **每一组命令前面都写明了它发往哪里。** 如果出现奇怪的行为，第一件要做的事就是 `echo $KUBECONFIG`。

## 实验目录里有什么

所有文件都已经在你手上了——你连同仓库一起拿到了它们。不需要再创建或手敲任何东西：下面凡是写着 `kubectl apply -f name.yaml` 的地方，文件都来自这里。

```bash
# 本实验的所有命令都在实验目录里运行——请切换进去
cd labs/07-redis
```

| 文件 | 是什么 | 什么时候用得上 |
|---|---|---|
| `app/` | 服务「通行证」的源码，带缓存的版本 | 你在本地构建，`docker build` |
| `hr-legacy.yaml` | 遗留目录服务的桩：像真的一样慢慢回答 | 你在自己的实验集群 `lab` 上应用它 |
| `passes-api.yaml` | 不带缓存的「通行证」服务——先测量它有多糟 | 你应用到同一个地方 |
| `cache-patch-broken.yaml` | 一个**故意不完整**的补丁，用来开启缓存 | 你应用它来看到错误 |
| `cache-patch.yaml` | 可用的补丁。是补丁，不是完整清单：你能看到究竟改了什么 | 你在讲解之后应用它 |
| `fortio.yaml` | 用于前后测量的负载生成器 | 你应用到同一个地方 |
| `check.sh` | 检查第二次请求比第一次快一个数量级 | 你在实验末尾运行它 |

## 步骤 1. 构建 v2 版本并推送到自己的镜像仓库

📍 **位置：** 在你的笔记本上。

`app/` 目录里放着源码。它和上一个实验的版本有两点不同：多了一个「慢速目录」模式，以及对缓存的处理。

<details>
<summary><b>深入看看：app/ 里面有什么</b></summary>

**一个镜像，两种角色。** `MODE` 变量决定进程以什么身份启动：

| `MODE` | 这是什么 | 它做什么 |
|---|---|---|
| `hr` | 遗留目录服务的桩 | 睡眠 `HR_DELAY`（默认 800 ms）然后返回员工数据 |
| `api` | 「通行证」服务本身 | 去访问目录服务，如果设置了 `REDIS_ADDR`——就先访问缓存 |

用两个镜像而不是一个，就意味着有两个地方可能忘记更新版本。

**数据获取之旅是怎么运作的。** 整套缓存逻辑大约二十行：

```go
if cache != nil {
    raw, found, err := cache.Get(key)
    switch {
    case err != nil:
        log.Printf("缓存不可用 (%v)，转去目录服务", err)
    case found:
        if json.Unmarshal([]byte(raw), &emp) == nil {
            fromCache = true
        }
    }
}

if !fromCache {
    emp, err = fetchEmployee(hrClient, hrURL, id)
    ...
    cache.SetTTL(key, string(b), ttl)
}
```

注意第一个分支：**如果缓存不可用，应用不会崩溃。** 它会写日志然后去访问目录服务——慢，但正确。这不是装饰，而是任何缓存都必须具备的性质：缓存能加速，但不能成为能否正常工作的前提条件。如果服务随缓存一起倒下，那你造出来的就不是缓存，而是又一个故障点。

顺带一提，本实验稍后会从这个性质里长出一次可预料的失败。一个默默继续工作的应用，在生产环境里让人愉快，在调试时却很阴险。

**键。** `employee:42`——实体名、冒号、标识符。这里的冒号不是 Redis 语法，而是一种被广泛采用的习惯：它让你之后可以按 `employee:*` 这个模式来搜索，并且在两个应用共用一个 Redis 时不至于把自己的键和别人的键弄混。

**存活时间由写入的同一条命令设定：**

```go
r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
```

不是先 `SET` 再 `EXPIRE` 两条命令。两条命令之间连接可能会断开——于是那个键就永远留在缓存里了。这样的键之后会被人找上好几个月。

**这里的 Redis 客户端是我们自己写的，五十行。** Redis 协议是文本的，对于 `GET` 和 `SET` 来说它能塞进一个函数里。在真实项目里你会用现成的库——它会处理连接池、重试和 sentinel。这里之所以要自己写，正是为了让构建没有外部依赖：回想一下上一个实验是怎么开始的。

**一个单独的、连接池被扩大的 HTTP 客户端：**

```go
tr := http.DefaultTransport.(*http.Transport).Clone()
tr.MaxIdleConnsPerHost = 64
```

没有这一行，在负载下有一半时间会花在与目录服务建立 TCP 连接上，而测量显示的就不是目录服务的延迟，而是我们自己的马虎。测量的第一条规则：确保你测的正是你以为在测的东西。

</details>

构建它并推送到你自己的 Harbor。`build` 会根据 `Dockerfile` 构建镜像并把它留在你的笔记本上，`push` 会把它发送到镜像仓库。镜像名和上一个实验一样，但标签不同——`v2`：现在镜像仓库里会同时存放两个版本，旧的哪儿也不会去。

替换成你自己的地址：

```bash
cd labs/07-redis

# build =「根据 Dockerfile 构建镜像」。
#   --platform linux/amd64  为哪种处理器构建；集群节点是 x86
#   -t <主机>/<项目>/<名称>:<标签>  给结果起什么名字；名字开头的镜像仓库地址
#                           就是 push 之后会把它发往的地方
#   app/                    含有 Dockerfile 和源码、用来构建的目录
docker build --platform linux/amd64 -t harbor.workshop03.example.org/passes/passes-api:v2 app/

# push =「把镜像发送到镜像仓库」。地址取自镜像名的第一部分，
# 凭据取自你上一个实验里做过的 docker login。
docker push harbor.workshop03.example.org/passes/passes-api:v2
```

⚠️ **如果你用的是 Apple Silicon 的 Mac 或 ARM 上的虚拟机，`--platform linux/amd64` 是必需的。** 否则镜像会按 ARM 构建，推送时不报错，而在集群里给出 `CrashLoopBackOff`，日志里是 `exec format error`。

## 步骤 2. 部署目录服务和服务

📍 **位置：** 在你的笔记本上，实验集群 `lab`。

两个清单里，镜像仓库地址的位置上放的是占位符 `HARBOR-HOST`：`sed` 会替换它，就地修改文件。然后 `apply` 把文件里描述的内容交给集群，`rollout status` 等待副本起来。

```bash
# KUBECONFIG 告诉 kubectl 用哪个访问文件。我们切换到
# 你的实验集群 `lab`；它一直有效，直到你关闭终端窗口。
export KUBECONFIG=~/lab.kubeconfig

# sed -i =「就地修改文件」。
#   's|old|new|g'  替换每一处出现；这里用 | 作分隔符而不是 /，
#                  因为地址里含有斜杠
#   macOS 版的 sed 要求 -i 后面必须跟一个参数；空引号
#   表示「不做备份」。在 Linux 上则不能有这个参数。
#   行尾有两个文件：sed 一次可接受多个文件并在一趟里改完。

# Linux
sed -i    's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml

# apply =「把集群带到文件里所描述的状态」。-f 标志对每个文件重复一次。
kubectl apply -f hr-legacy.yaml -f passes-api.yaml

# rollout status 等待副本就绪后自行退出；等不到就返回错误
kubectl rollout status deployment/hr-legacy
kubectl rollout status deployment/passes-api
```

⚠️ 两个清单都引用了 `harbor` Secret——就是上一个实验里那个 `imagePullSecret`。如果你没做过，Pod 会进入 `ImagePullBackOff`。创建这个 Secret：

```bash
# create secret docker-registry =「创建一个含镜像仓库凭据的 Secret」；
# 这样的 Secret 能被 kubelet 自己在把镜像拉到节点上时读取。
#   harbor             这个 Secret 在集群里的名字——两个清单都引用它
#   --docker-server    这些凭据是给哪个镜像仓库的
#   --docker-username  谁来登录；--docker-password —— Harbor 管理员密码
kubectl create secret docker-registry harbor \
  --docker-server=harbor.workshop03.example.org \
  --docker-username=admin --docker-password='你的密码'
```

我们来检查这条链路是否工作。服务只能从集群内部看到，所以我们也从那里发请求：起一个带 `curl` 的一次性 Pod，它去请求 `passes-api` 服务，打印答案，然后消失。

```bash
# run probe =「启动一个名为 probe 的 Pod」。
#   --rm              一旦它跑完就删除该 Pod
#   -i                把它的输出显示给我们
#   --restart=Never   不要重启:这是一次性命令，不是常驻服务
#   --image=...       用哪个镜像;版本被固定住，免得来了新的东西
#   --quiet           不打印辅助信息，只打印答案
#   --                这两个短横线之后的一切，都是 Pod 内部的命令
# 形如 <service>.<namespace>.svc.cluster.local 的地址是服务的内部名字;
# Pod 靠它互相找到对方，而无需知道地址。
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**你应该看到：**

```json
{"cache":"off","cached":false,"dept":"物流部","id":"42","name":"高艳",
 "pod":"passes-api-6f8b9c7d5-x2ktm","took_ms":803,"ttl_s":60}
```

关键字段：`cache: off`——没有缓存，`took_ms: 803`——它们来了，你的八百毫秒。这正是我们要缩小的那个数字。

## 步骤 3. 测量现在有多糟

📍 **位置：** 在你的笔记本上，实验集群 `lab`。

一个请求算不上测量。你需要接近真实情况的负载，以及延迟的分布。

部署生成器。它像普通应用一样起来，住在集群里、紧挨着服务——这样测量就不依赖你的网络，也不依赖隧道：

```bash
# 文件里有两个对象:生成器本身和给它的一个服务
kubectl apply -f fortio.yaml
kubectl rollout status deployment/fortio
```

现在启动负载。`kubectl exec` 命令在一个已经运行的 Pod 内部执行某些东西——这里是在生成器内部启动生成器本身，进入轰击模式：

```bash
# exec deploy/fortio = 在这个应用的 Pod 内部执行一条命令
#   --            分界线:左边是 kubectl，右边是进入 Pod 的命令
#   fortio load   轰击模式:发送请求并测量响应时间
#   -qps 20       每秒二十个请求——我们设定节奏，而不是「使出全力猛压」
#   -t 20s        测量持续多久
#   -c 16         十六个并行连接。这个数字不是随便取的:
#                 目录服务用 800 ms 回答，所以一个连接每秒只能勉强
#                 处理一个多一点的请求。要维持设定的每秒 20 个，
#                 连接数不能少于十六——否则 Fortio 会撞上延迟墙，
#                 交不出所要求的节奏。
#   最后一个参数是我们要轰击的地址
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**你应该看到**——在输出末尾，一个直方图和几行百分位数：

```
# target 50% 0.801
# target 90% 0.806
# target 99% 0.812
Code 200 : 400 (100.0 %)
```

**把这些数字记下来。** 十分钟后你会需要它们来做比较，而人的记忆是这样的：「嗯，大概八百吧」会变成「嗯，大概半秒吧」。

### 用鼠标做同样的事

用鼠标——这里不是 Cozystack 控制台：它面向管理集群，展示租户的目录条目，但不会窥探你的实验集群 `lab` 内部。生成器本身有自己的 Web 界面，而你得通过隧道才能够到它。

```bash
# port-forward svc/fortio = 从你的笔记本到集群里生成器服务的一条隧道
#   8081:8080 — 左边的数字是你笔记本上的端口，右边是集群里服务的端口
# 用 8081 是因为 8080 在你机器上可能被别的东西占用了。
# 别关这个窗口:隧道随命令运行而存活。要停止它——Ctrl+C。
kubectl port-forward svc/fortio 8081:8080
```

打开 <http://localhost:8081/fortio>。填写：

| 字段 | 值 |
|---|---|
| URL | `http://passes-api.default.svc.cluster.local/employee?id=42` |
| QPS | `20` |
| Duration | `20s` |
| Connections | `16` |

点击 **Start**。底部会画出一个延迟直方图。它比数字更直观：你能看到所有请求都聚成 800 ms 附近的一条窄带——也就是说它慢不是「偶尔」，而是总是慢、且慢得一样多。


<details>
<summary><b>为什么用 p50 和 p99，而不是平均延迟</b></summary>

平均延迟是运维里最具欺骗性的指标。

设想一下：九十个请求各 10 ms，十个请求各 2000 ms。平均是 209 ms，从报表看一切都挺体面。可实际上每十个用户里就有一个等了两秒然后走了。

**p50（中位数）**——一半请求比这个数字快，一半更慢。它回答的是「一个普通用户要等多久」。

**p99**——99% 的请求比这个数字快。它回答的是「最糟能糟到什么程度」。正是 p99 决定了门岗的保安会不会抱怨：人们抱怨的不是平均值，而是那一次不得不等待的经历。

在我们的测量里 p50 和 p99 几乎重合——801 和 812 ms。这是个信号，说明这种慢不是随机的，而是系统性的：恰恰总是慢。这种情况用缓存能治。要是 p50 是 10 ms 而 p99 是 2000 ms，原因就是另一回事了，缓存帮不上忙。

</details>

## 步骤 4. 创建 Redis

📍 **位置：** 在浏览器里，在 Cozystack 控制台中。Redis 是租户的共享资源，和 Harbor 一样。

租户 → **创建应用** → `Redis`。

| 字段 | 值 | 为什么这样 |
|---|---|---|
| Name | `cache` | 它会进入服务名，短一点更方便 |
| Replicas | `2` | 一份主副本和一份从副本：我们会看到这带来了什么 |
| Size | `1Gi` | 员工目录塞进内存还绰绰有余 |
| Storage class | `replicated` | |
| Resources preset | 保留建议的那个 | |
| Version | `v8` | |
| Auth enabled | **开启**（默认） | 平台自己生成密码 |
| External | **关闭** | 没有理由把这个缓存暴露到外面 |

预计要等三到五分钟它才会就绪。

⚠️ **这个 Redis 和你在 Harbor 创建表单里可能见过的那个 Redis 毫无关系。** 那里的是镜像仓库自己的内部缓存。这一个是你自己的，给你的应用用的。

<details>
<summary><b>托管 Redis 和装在虚拟机上的 Redis 有什么不同</b></summary>

在虚拟机上装 Redis 是半小时的活儿：`apt install redis`，调一下 `bind` 和 `requirepass`，设为开机启动。正因为如此，托管服务才显得多余。区别不在安装，而在于之后发生的事。

**复制。** 你设了 `replicas: 2`——就得到了分布在不同节点上的两份数据副本，外加三个看守它们的 sentinel。如果带主副本的节点挂了，sentinel 会举行选举，把第二份副本立为主。应用会以几秒的停顿挺过这一关。手工拼出同样的东西要一天的工夫，然后还要再花一天去验证它真的会故障切换，而不只是看起来配好了。

**更新。** Redis 里出漏洞并不罕见。在虚拟机上，更新意味着 `apt upgrade`、重启，外加祈祷配置能挺过大版本变更。这里镜像更新随平台更新一起到来，而且副本重启的顺序被安排好，好让服务不至于消失。

**可观测性。** 指标已经在采集了：每份副本旁边都运行着一个 exporter，图表无需你出一分力就已经在那儿了。在虚拟机上，这又是一个要装的包、又一份配置，以及又一件被忘掉的事。

**你放弃了什么。** 老实说：装着 Redis 那台机器的 root 权限。你没法 SSH 进去，没法手工改配置，没法在它旁边丢一个自己的脚本。任何没有以应用参数形式呈现出来的东西，你都够不着——而呈现出来的远非全部。如果你需要一个非标准的 `maxmemory-policy` 或者一个 Redis 模块，托管服务不会给你，你只能在虚拟机上装自己的。这是实实在在的限制，不是小事。

</details>

## 步骤 5. 找到 Redis 地址并检查连通性

📍 **位置：** 在你的笔记本上，**管理**集群。

Redis 住在管理集群上你的租户里，而应用在你的实验集群 `lab` 里。这是两个不同的集群，第一件要做的事就是确认第二个能够到第一个。

我们来看看出现了哪些服务：

```bash
# --kubeconfig 直接在命令里指定访问文件——只此一次，不动 KUBECONFIG。
# 这样连续两条命令可以发往不同集群而不至于搞混。
#   -n tenant-workshopXX  你租户的 namespace
#   get svc               「列出服务」——背后有 Pod 支撑的固定地址
#   | grep redis          只保留输出里带 redis 这个词的行
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX get svc | grep redis
```

**你应该看到**——几个带有说明性前缀的服务：

| 名称 | 它背后是什么 |
|---|---|
| `rfrm-redis-cache` | 主副本（master）——在这里写入和读取 |
| `rfrs-redis-cache` | 从副本（replicas）——只读 |
| `rfs-redis-cache` | sentinel——负责监视和切换角色的服务 |

⚠️ **名字里多出来的 `redis-` 是从哪来的。** 平台会给应用名加上一个带服务类型的前缀：类型为 Redis 的 `cache` 应用，内部叫作 `redis-cache`。所以是 `rfrm-redis-cache`，而不是 `rfrm-cache`。别去猜名字——看上面那条命令的输出，那才是事实的来源。

我们需要的是 `rfrm-redis-cache`：缓存既写又读，而写只能写到主副本。

从你的集群里看到它的完整名字是这样拼出来的：

```
rfrm-redis-cache.tenant-workshopXX.svc.cozy.local
```

取密码。📍 **位置：** 在控制台里，`cache` 应用，secrets 标签页。你需要 `redis-cache-auth` Secret 的 `password` 键。

现在——做连通性检查。📍 **位置：** 在你的笔记本上，实验集群 **`lab`**。

在你的集群里起一个带 Redis 客户端的一次性 Pod，让它对 Redis 说一句 `ping`。如果有回音，就说明从实验集群 `lab` 能看到租户里的缓存——而这正是我们此刻唯一在检查的事。

⚠️ **我们通过 `REDISCLI_AUTH` 变量传密码，而不是用 `-a` 标志。** 凡是落到命令参数里的东西，都会在节点的进程列表里可见，还会留在 Pod 的描述里——而任何有权访问你 namespace 的人都能读到它。`redis-cli` 自己就会对此发出警告，而去消掉警告、却不去除掉原因，是个坏习惯。

```bash
export KUBECONFIG=~/lab.kubeconfig

# run redis-probe = 一个带 redis-cli 客户端的一次性 Pod:
#   --rm --restart=Never  干完活就自我删除，不需要重启
#   -i --quiet            把输出显示给我们，且不打印辅助信息
#   --env=REDISCLI_AUTH   密码以环境变量而非参数的形式进入 Pod
#   --                    这些短横线右边是进入 Pod 的命令
#   redis-cli -h <名字>   连到哪个服务器；名字就是那个完整的
#   ping                  简短的「你活着吗」；它的回答是 PONG
kubectl run redis-probe --rm -i --restart=Never --image=redis:7-alpine --quiet \
  --env=REDISCLI_AUTH='你的密码' -- \
  redis-cli -h rfrm-redis-cache.tenant-workshopXX.svc.cozy.local ping
```

**你应该看到：**

```
PONG
```

⚠️ **如果你得到的不是 `PONG` 而是一个名字解析错误**——那说明从你的集群里看不到管理集群的内部名字。用 IP 来访问就能解决：

```bash
# -o jsonpath='{.spec.clusterIP}' —— 打印对象的一个字段：平台
# 分配给这个服务的内部地址。{"\n"} 加一个换行。
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX get svc rfrm-redis-cache \
  -o jsonpath='{.spec.clusterIP}{"\n"}'
```

从这里往后，处处都用你拿到的地址替换名字。效果一样；唯一的缺点是，如果 Redis 被重建，地址会变，而名字不会。要是连按地址也不回应——请在工作坊聊天群里说一声，这是测试环境的配置问题，不是你的错。

## 步骤 6. 开启缓存

📍 **位置：** 在你的笔记本上，实验集群 `lab`。

我们改动应用不是用一整份清单，而是用一个补丁——这样你能精确看到改了什么。先把你 Redis 的地址替换进补丁，再把补丁交给集群：`kubectl patch` 是把改动追加到一个已存在的对象上，而不是把它整个替换掉。

```bash
# 和之前一样的地址替换，只是占位符不同——REDIS-ADDR

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml

# patch deployment passes-api =「用文件里的内容把这个对象修补一下」
#   --patch-file  从哪里取改动
# 改动环境变量意味着新的 Pod:旧的会被替换。
kubectl patch deployment passes-api --patch-file cache-patch-broken.yaml

# 等到新副本就绪——否则我们量到的还是旧的
kubectl rollout status deployment/passes-api
```

再测一次——用开启缓存之前测量时的同一条命令。轰击的条件必须精确到最后一个标志都一致，否则就没什么可比的了：

```bash
# 同样是每秒二十个请求，同样是二十秒，同样是十六个连接
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

> **在往下读之前，先停下来想一想。**
>
> 数字没变：还是那八百毫秒。可是没有一个 Pod 崩溃，响应里没有错误，每个请求都返回了 `200`。Redis 已经创建，地址是对的——你刚刚还从它那里收到了 `PONG`。
>
> 该往哪儿看？

<details>
<summary><b>答案，以及比这个错误更深远的一课</b></summary>

先看看应用自己回答了什么：响应里有几个字段能显示缓存是否开启、答案是否来自它。

```bash
# 和之前一样的一次性 curl Pod:我们从集群内部请求这个服务
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

```json
{"cache":"redis","cached":false,"took_ms":802, ...}
```

`cache: redis`——缓存开着。`cached: false`——可答案却不是从它那里来的。而且**总是** false，不管你重复多少次。

现在看日志。应用把它做不到的事写在那里——而那是目前唯一能看到真相的地方：

```bash
# logs =「显示应用写到它输出里的东西」。
#   -l app=passes-api  一次性覆盖所有带这个标签的副本，而不是某个指名的副本
#   --tail=20          每个副本的最后二十行，而不是整个日志
kubectl logs -l app=passes-api --tail=20
```

```
缓存不可用 (redis: NOAUTH Authentication required.)，转去目录服务
缓存不可用 (redis: NOAUTH Authentication required.)，转去目录服务
```

答案就在这里。我们指定了 Redis 地址，却没指定密码。Redis 要求认证——是你自己在创建时打开了 `Auth enabled`，而这是正确的设置。应用老老实实地尝试了，被拒绝了，把这事写进日志，然后去了目录服务。

**为什么这看起来不像故障。** 因为根本没有故障。应用被设计成能在缓存不可用时照常存活：缓存能加速，但不能成为能否正常工作的前提条件。在生产环境里这救了你——Redis 倒下不会把服务拖下水。而在调试时，同样这个性质却把问题藏了起来：一切都是绿的，没有错误，就是不见得更快。

**比这个错误更深远的一课。** 一个不妨碍工作的故障，是最昂贵的那种故障。它不拉响警报，能在生产环境里活上好几个月。由此得出一条实用规则：**每一个加速器都必须有一个可观测的、表明它正在工作的标志。** 对我们来说那就是响应里的 `cached` 字段。要是没有它，你此刻就只能靠猜了。

在真实系统里，这个位置上会有一个「缓存命中率」指标，以及一个在它跌到零时触发的告警。

</details>

## 步骤 7. 放进密码，再测一次

📍 **位置：** 在你的笔记本上，实验集群 `lab`。

Redis 密码住在管理集群里，而应用在你的集群里需要它。我们把它搬过来——经由一个 shell 变量，好让密码不落进命令历史：

```bash
# read 把键盘上输入的内容放进 REDIS_PASS 变量:
#   -s  不在屏幕上显示所输入的内容
#   -r  不把反斜杠当作特殊字符
# 这一行之后屏幕上不会出现任何东西:从控制台粘贴密码然后回车。
read -rs REDIS_PASS

# create secret generic = 一个普通的 Secret，一组键值对。
#   redis-password              这个 Secret 在集群里的名字
#   --from-literal=password=... 在它里面建一个 password 键，值就是这个；
#                               补丁引用的正是「Secret 名字 + 键」这一对
kubectl create secret generic redis-password --from-literal=password="$REDIS_PASS"

# unset 抹掉这个变量，好让密码不会传到这个窗口里后面的命令
unset REDIS_PASS
```

应用完整的补丁。它有同样的 Redis 地址，外加一个对刚创建的 Secret 的引用，以及缓存条目的存活时间；讲解就在命令后面的折叠块里。

```bash
# 同样的地址替换，这次是在可用的补丁文件里

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml

# 用文件内容修补现有的 Deployment，并等待新副本
kubectl patch deployment passes-api --patch-file cache-patch.yaml
kubectl rollout status deployment/passes-api
```

<details>
<summary><b>深入看看：cache-patch.yaml 里面有什么</b></summary>

```yaml
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: REDIS_ADDR
              value: "rfrm-redis-cache.tenant-workshopXX.svc.cozy.local:6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-password
                  key: password
            - name: CACHE_TTL
              value: "60"
```

**为什么用补丁，而不是完整清单。** 补丁是「改这个」，不是「状态应该是这样」。在文件里你精确看到改了什么，而不是两百行里得用眼睛去找那三行新的。

**为什么这不会抹掉其他变量。** Kubernetes 里的列表能按键合并。对 `env` 来说键是 `name` 字段：补丁里的三条会加到已有的那些上面，而 `REDIS_ADDR` 那条会替换掉从坏补丁里遗留下来的同名条目。容器列表也一样按名字合并——这就是为什么 `- name: api` 是必需的；没有它 Kubernetes 就搞不清你在改哪个容器。

**为什么密码要经由 `secretKeyRef`，而不是写成明文。** 值是在 Pod 启动的那一刻从 `redis-password` Secret 里取来的。清单本身里没有密码——这很重要，因为清单会进 Git，而在那里它会永远留存。Secret 不会进 Git。

老实说：集群里的 Secret 依然是明文躺着的，只是换了个地方。任何能读这个 namespace 里 Secret 的人都会看到密码。真正的解决办法是外部的密钥存储，那是另一个实验的事了。

**`CACHE_TTL: 60`。** 六十秒是个折中。下面——读下一个折叠块。

</details>

在加负载之前，我们先一个一个地检查。对一个还没被问过的标识符连发两个相同的请求：第一个注定慢，第二个——快。

```bash
# 还是那个一次性 curl Pod，但这次在它内部启动一个 sh shell:
#   sh -c '...'  执行以单个字符串传入的多条命令
#   ; echo       在两个答案之间插一个换行，免得它们粘在一起
# 用 id=777 是因为这个员工还没被问过:他肯定不在缓存里。
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  sh -c 'curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"; echo;
         curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"'
```

**你应该看到**——两个答案，而且它们不一样：

```json
{"cached":false,"took_ms":804, ...}
{"cached":true,"took_ms":1, ...}
```

第一个请求是未命中：缓存是空的，只能去目录服务，804 ms。第二个是命中：答案已经在那儿了，1 ms。

现在做一次负载下的测量，同一条命令、同样的标志，第三次：

```bash
# 轰击条件里我们什么都不改:变的只有服务内部的东西
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**你应该看到：**

```
# target 50% 0.0012
# target 90% 0.0021
# target 99% 0.0043
Code 200 : 400 (100.0 %)
```

## 步骤 8. 结算收益

📍 **位置：** 在一张草稿纸上。

把三个数字汇到一张表里。你的会有出入——测试环境、网络、节点上的邻居：

| | p50 | p99 | 这对保安意味着什么 |
|---|---|---|---|
| 没有缓存 | 801 ms | 812 ms | 12 行的列表要 ~9.6 秒才打开 |
| 缓存开着、没有密码 | 802 ms | 815 ms | 什么都没变 |
| 缓存工作了 | 1.2 ms | 4.3 ms | 同样的列表——~0.05 秒 |

差距是**几百倍**，而且这不是修辞，而是两个测量出来的数字相除的商。

注意我们**没有**做什么。我们没有重写人事系统。我们没有加节点。我们没有改动「通行证」服务逻辑里的哪怕一行——我们只是教会了它不要把同一件事问两遍。这个改动装进了三个环境变量里。

<details>
<summary><b>缓存什么时候帮不上忙，以及如何提前看出来</b></summary>

缓存不是万能的加速。它只在一个条件下有用：**同一个问题被问很多次。** 拿三个情形考考自己。

**每个请求都是唯一的。** 如果访客列表每次都请求一个新员工的信息，那就根本不会有命中，反而给每个请求都加上了一趟 Redis。会变得更慢。你可以这样确认——针对不同标识符跑两组短序列，看每一组的头几个请求：

```bash
# 针对不同员工连着两次轰击，每次十秒。
# 每组开头，缓存对这个键都是空的——于是第一个请求会去目录服务。
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=1"
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=2"
```

每组的开头几个请求都是未命中。在一大堆很少重复的键上，缓存退化成了纯粹的开销。

**数据变得比 TTL 还勤。** 如果员工信息每十秒就变一次，而 TTL 设的是 60，保安就会看到长达一分钟的陈旧数据。缓存总是用新鲜度换速度，而决定能舍弃多少新鲜度不是一个技术决定，而是一个要问客户的问题。

**不是总慢，而是偶尔慢。** 还记得第一次测量里 p50 和 p99 的差别吗？如果 p50 小而 p99 巨大，那慢的不是数据源，而是某种飘忽不定的东西：垃圾回收、节点上的邻居、数据库里的锁。缓存会把这遮盖住，却治不好它，而某一天你会去解开完全一样的那个结，只不过晚了一年，而且上面还盖着一层缓存。

</details>

<details>
<summary><b>TTL 是怎么选的</b></summary>

TTL 是缓存唯一真正的参数，而它不是根据技术理由来选的。

问题是这样的：**你愿意展示陈旧数据多久？**

对员工目录来说：姓氏几年才改一次，部门一年一次。门岗上显示昨天的部门谁也不会在意。TTL 完全可以是一小时，甚至一天。

我们设了六十秒，是为了让这个实验可观测：等一分钟，重复请求——你会再次看到 `cached: false`，因为那条记录过期了、去了目录服务。要是 TTL 是一天，你就只能凭信任接受这一点了。

极端情形：

| TTL | 你会得到什么 |
|---|---|
| 太小 | 命中很少，缓存几乎不起作用，源头上的负载依旧 |
| 太大 | 快，但用户看到昨天的数据，转而抱怨别的 |
| 干脆不设 | 键越堆越多，内存耗尽，Redis 开始随便淘汰 |

最后一行最阴险。没有 TTL 的缓存，久而久之会变成一个没人备份的数据库。

</details>

## 验证

📍 **位置：** 在你的笔记本上，就在你用 `kubectl` 工作过的那个终端窗口里。

脚本会同时访问两个集群，并从环境变量里取它们。前两个是必需的，第三个是租户 kubeconfig 的路径。

```bash
cd labs/07-redis

# 在哪个集群里检查应用——你的 `lab`
export KUBECONFIG=~/lab.kubeconfig
# 你的租户编号:脚本用它拼出 namespace 名字 tenant-workshop03
export COZY_TENANT=workshop03
# 管理集群的访问在哪里——脚本会去那里查看 Redis 本身。
# 可以不设:那样脚本会去找 ~/.kube/workshop，找不到就跳过
# 对管理集群的检查，并会告诉你这一点。
export COZY_KUBECONFIG=~/.kube/workshop

./check.sh
```

⚠️ **在 Windows 上脚本从 WSL 里运行**，而不是从 PowerShell——怎么安装它写在实验 0 的开头。没有 WSL 你照样能做完这个实验，只是不会有产物报告。

脚本不轻信任何清单的一面之词。它自己针对一个随机标识符连发两个请求并观察：第一个应该是未命中、花上数百毫秒，第二个是命中、花个位数毫秒。它把这个差值以数字形式记进报告。顺带，它还会检查那个慢速目录服务确实慢：没有这一点，比较就毫无意义。

## 清理

后面的实验里一切都会用到——现在什么都不删。

当你做完所有实验之后：

```bash
# delete -f = 从集群里删除文件中所描述的那些对象
kubectl delete -f passes-api.yaml -f hr-legacy.yaml -f fortio.yaml
# 这个 Secret 是用命令创建的，不是用文件——我们按名字删除它
kubectl delete secret redis-password
```

Redis 本身通过控制台删除，就像一个普通应用一样。

删除缓存是一个廉价且几乎安全的操作，而这是缓存的一个独有性质：**缓存里不存放任何在别处不存在的数据。** 它里面的一切都能通过去源头取一趟而恢复。丢掉 Redis 意味着丢掉几分钟的速度——趁它重新填满的这段时间——但不会丢掉信息。数据库可不是这样，在关于数据库的那个实验里你会回到这一点。

## 我们现在会做什么了

- 配置一个托管 Redis，并解释你没有配置过的那个复制带来了什么
- 测量一次改动前后的延迟，而不是空谈它
- 读懂 p50 和 p99，理解为什么平均延迟会骗人
- 根据客户能容忍多少陈旧来选择 TTL
- 找出那个不妨碍工作的故障——最昂贵的那种故障

## 而在 vSphere 里这会是

这个任务在 vSphere 里没有对应物，这一点值得直说。缓存不是一个基础设施对象，而是应用架构的一部分。虚拟机监控程序没法缓存人事系统的回答，也不应该有这个本事。

在虚拟机的世界里你会这么做：申请一台给 Redis 用的虚拟机，安装，配置 `requirepass`，配置自动启动，然后——如果腾得出手的话——再来第二台给副本用的虚拟机、sentinel、验证故障切换。好几天的工作，其中缓存本身占半小时，剩下的都是脚手架。任何管理员都熟悉的一个习惯正是由此而来：「咱们先不要副本了，以后再加。」以后，他们不加。

区别不在于这里 Redis 装得更快。区别在于副本、故障切换、指标和更新都是默认就到位的，而「先不要副本」根本不会作为一个选项冒出来。

**老实说，vSphere 更方便的地方。** 三件事。

**完全的控制。** 在你自己的虚拟机上，你可以装任何版本的 Redis、任何模块、任何 `maxmemory-policy`，还能在旁边放上你自己的监控脚本。这里你只能接触到那些以应用参数形式呈现出来的东西——而呈现出来的远非全部。

**诊断。** 当虚拟机上的 Redis 行为古怪时，你 SSH 进去看 `redis-cli INFO`、`SLOWLOG`、系统计数器。这里没有 SSH，要拿到同样的信息只能通过 `kubectl exec` 和指标——更慢，分辨率也更低。

**邻居的可预测性。** 一台跑 Redis 的虚拟机意味着有保证的核心和内存，你在 vCenter 里能看到。托管服务住在共享节点上、紧挨着别人的工作负载；限额会保护它，但「为什么今天慢了两毫秒」你要弄清楚，会比在一台专用机器上花更长时间。
