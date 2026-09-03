# 实验 14 · 可观测性：在图表里找到你自己制造的那次尖峰

| | |
|---|---|
| **时长** | 30 分钟 |
| **能证明什么** | 指标会自己持续、且可回溯地采集。你不需要另外购买一套监控系统 |
| **需要准备什么** | 实验 0 的集群、实验 1 的应用、已完成的实验 3（压测与 HPA）、租户控制台（dashboard）的访问权限 |

## 为什么这很重要

昨天 16:40，「Propusk」有十五分钟响应缓慢。投诉今天 11:00 才到——一向如此。管理层的问题是：这是怎么回事，还会不会再发生。

「现在复现一下看看」这条路走不通：昨天别人制造的负载你复现不了。唯一能回答的办法，是手里有**昨天的记录**，而且是在有人开口之前就已经采集好的。

在这个实验里，我们要在图表中找到实验 3 里我们自己制造的那次负载的痕迹：流量开始时 CPU 的尖峰，以及自动扩缩容加出副本时那道台阶。我们没有为此做任何特殊准备——记录早已经在那里了。

## 小词典

| 术语 | 是什么 | 类似……但 |
|---|---|---|
| **指标（metric）** | 定期采集的一个数字：用了多少 CPU、多少内存、多少请求 | **vCenter 图表里的计数器**，但存的是历史，而不是最后一个值 |
| **标签（label）** | 指标上的一对「名称=值」：pod、namespace、cluster | **计数器所挂靠的那个对象**，但标签有很多个，可以按其中任意一个切片和分组 |
| **时间序列（time series）** | 一条指标搭配一组固定的标签，随时间变化 | **vCenter 里的一张图**，但每一种标签组合都是独立的一条序列，成千上万条 |
| **抓取（scrape）** | 采集：agent 每 N 秒轮询一次数据源 | **vCenter 的计数器采集**，但是 agent 主动拉取数据，而不是应用推送 |
| **PromQL** | 查询指标的语言 | 没有直接对应物：在 vCenter 里你挑一个计数器，在这里你写一个表达式 |
| **VictoriaMetrics** | 存放已采集指标的存储 | **vCenter 的统计数据库**，但它懂 Prometheus 的查询语言，尽管它本身并不是 Prometheus |
| **Grafana** | 指标与日志的界面 | **Performance 选项卡**，但是一个独立产品；控制台（dashboard）要么手写、要么拿现成的 |
| **保留期（retention）** | 历史保存多久 | **vCenter 里的统计级别**，但由一个参数设定；默认是 3 天和 14 天，分放在两个独立的存储里 |
| **日志（logs）** | 应用写出的一行行文字 | **访客操作系统里的日志**，但集中收集，有自己的查询语言，不是 PromQL |
| **Pod** | 最小的执行单元：一个或几个容器，永远在同一个节点上 | **一台虚拟机**，但是一次性的：与其重启它，不如换个新名字重新创建 |
| **namespace** | 集群内部的隔断：不同 namespace 里相同的名字不会冲突 | **vCenter 清单里的一个文件夹**，但它还划分权限、配额和网络策略 |
| **租户（tenant）** | 你在平台上的那一块：Grafana 就在这里，集群的指标也流进这里 | **一个带自有权限的 Resource Pool**，但它还发放现成的服务，而不只是资源 |

### 指标和日志——为什么是两回事

它们老是被混为一谈，然后人们就跑去日志里找那些只存在于指标里的东西。

| | 指标 | 日志 |
|---|---|---|
| 是什么 | 按固定间隔采集的数字 | 事件发生那一刻的文字行 |
| 例子 | 「16:41:30 这个 Pod 用了 240 毫核」 | 「16:41:31 ERROR connection refused」 |
| 占多少空间 | 少，而且体量可预测 | 多，体量取决于应用有多话痨 |
| 保存多久 | 数周乃至数月 | 数天 |
| 回答什么问题 | 「用了多少、什么时候」 | 「到底发生了什么」 |
| 查询语言 | PromQL | LogsQL（在 Grafana 里这是一个单独的数据源） |

它们是成对工作的：**指标帮你找到时刻，日志帮你找到原因。**图上显示 16:41 有个尖峰——你就去看那一分钟的日志。反过来行不通：翻日志去找「什么时候开始出问题的」，可以找到天荒地老。

### 为什么指标是持续采集，而不是按需采集

这是监控区别于诊断的关键所在，值得直白地说清楚。

按需采集在**物理上**就不可能：等问题被提出来时，事件早已经过去了。如果昨晚没人记录，任何系统都没法给你看昨晚的负载。

所以 agent 不加区分地把一切都轮询一遍，每 30 秒一次，然后放进存储。是的，这些数字里 99% 永远不会有人去看。这 99% 的代价，是几个 GB 的磁盘。而缺失的那 1% 的代价，是「我们不知道当时发生了什么，而且再也无从知道」。

⚠️ **要提前知道的另一面。**持续采集意味着持续开销：agent 占用 CPU 和内存，存储不断增长。在大集群上，指标会成为消耗中一个显眼的条目，你不得不给它们做减法：缩短保留期、丢掉不需要的标签、关掉很少用到的指标的采集。这是常规的运维工作，头一个月不会冒出来，但迟早会冒出来。

## 实验文件夹里有什么

所有文件你都已经有了——它们是随仓库一起拿到的。不需要再创建或重新敲任何东西：下面凡是写着 `kubectl apply -f name.yaml` 的地方，文件都取自这里。

```bash
# 切换到本实验的文件夹：下面所有相对路径都从这里算起
cd labs/14-observability
```

| 文件 | 是什么 | 什么时候用得上 |
|---|---|---|
| `check.sh` | 检查指标是否在采集、图表是否有响应 | 在实验结尾运行 |
| — | 本实验没有自己的清单（manifest）：负载和自动扩缩容取自实验 3 —— `../03-scale/` | |

## 步骤 1. 先确认指标究竟有没有在采集

📍 **在哪里做：**在笔记本电脑上。

实验集群 `lab` 不会自己把指标对外暴露，而是通过 `Monitoring agents` 这个附加组件（add-on）。检查它是否已启用：

```bash
# KUBECONFIG —— kubectl 读取它来得知集群的地址以及以谁的身份登录。
# 文件 ~/lab.kubeconfig 是你创建实验集群 `lab` 时保存下来的。
# 每开一个新的终端窗口都得重新设置一次。
export KUBECONFIG=~/lab.kubeconfig

# get pods = 「让我看看有哪些 pod」。
#   -n cozy-monitoring   不在整个集群里找，而是在这个 namespace 里找：附加组件
#                        正是把它的采集器放到了这里。
kubectl get pods -n cozy-monitoring
```

**如果你在列表里看到 `vmagent` 和 `fluent-bit`**——一切就绪，继续往下走。

⚠️ **要看名字，而不是看列表是不是空的。**`cozy-monitoring` 这个 namespace 始终存在：平台还会把 `metrics-server` 放进去，而它会安装到任何一个拥有自己 etcd 的集群上，跟这个附加组件无关。换句话说，看到一行 `metrics-server` 就断定指标采集已开启，是个典型错误，而且它只会在 Grafana 里暴露出来——那时你会发现里面空空如也。

**如果列表里有 `metrics-server`，却既没有 `vmagent` 也没有 `fluent-bit`：**

```
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-7d4b8c9f5-x2klm    1/1     Running   0          3d
```

这就意味着附加组件是关着的，你手里没有过去的记录。顺带一提，这正是对上一节的精确注解：采集没法回溯地开启。

在控制台（dashboard）里开启它：`Kubernetes` → `lab` → 编辑 → 在 Addons 这一节里勾上 `Monitoring agents`。附加组件几分钟就会起来，但**指标只会从这一刻起才开始积累**——实验 3 的那次尖峰你已经找不回来了。

那就只好把尖峰重新制造一遍。请注意，实验 3 的清理删掉了自动扩缩容，实验 4 的清理删掉了负载生成器，所以两个都得恢复回来：

```bash
export KUBECONFIG=~/lab.kubeconfig          # 与上面同一个访问文件

# apply = 「把集群变成文件里所描述的样子」。这两个文件都在相邻实验的文件夹里，
# 所以路径以 `../` 开头 —— 不用再重新敲一遍。
kubectl apply -f ../03-scale/hpa.yaml       # rickroll 的自动扩缩容规则
kubectl apply -f ../03-scale/fortio.yaml    # 负载生成器

# rollout status = 「占住终端，等滚动发布完成了再告诉我」。
# deployment/fortio —— 对象类型和它的名字。当生成器起来后，命令会返回提示符，
# 并带上一行 `successfully rolled out`。
kubectl rollout status deployment/fortio
```

一直等到 `kubectl get hpa rickroll` 里 `<unknown>` 变成一个百分比为止；`hpa` 是 `HorizontalPodAutoscaler` 的缩写，也就是那个自动扩缩容对象。这要花上几分钟。然后转发生成器的端口，施加与实验 3 相同的负载，否则自动扩缩容的那道台阶不会出现：

```bash
# port-forward = 从笔记本电脑挖一条隧道通进集群。命令运行期间，
# 对 localhost:8081 的请求会落到负载生成器上。
#   svc/fortio    目标：名为 fortio 的 service（不是 pod）
#   8081:8080     左边是你笔记本电脑上的端口，右边是 service 内部的端口
# 别关这个窗口：隧道存活的时间正好等于命令运行的时间。
kubectl port-forward svc/fortio 8081:8080
```

在 <http://localhost:8081/fortio/> 上：**URL** `http://rickroll/`，**QPS** `1200`，**Duration** `90s`，**Connections** `80`。跑完之后过几分钟再回到这里——数据就有了。

⚠️ 为了不陷入这种境地，在创建集群时就顺手把 `Monitoring agents` 开上——在实验 0 里它是参数表中单独的一行。

<details>
<summary><b>那里究竟跑着什么，采集到的东西又去了哪里</b></summary>

在你集群的 `cozy-monitoring` namespace 里，跑着这些：

| 谁 | 干什么 |
|---|---|
| `vmagent` | 每 30 秒轮询一次指标数据源，把采集到的东西发往租户 |
| `kube-state-metrics` | 把集群对象的状态变成指标：有多少副本、各个 Pod 处于什么状态 |
| `node-exporter` | 节点本身的指标：CPU、内存、磁盘、网络 |
| `fluent-bit` | 收集容器日志并发往租户 |
| `metrics-server` | **不属于监控**：随集群一起安装，为 `kubectl top` 和自动扩缩容提供当前的数值。它什么都不存储，也不参与指标采集 |

请注意：**这里没有存储**。采集到的一切都会立刻通过网络发往租户，进到 Grafana 旁边那个共享的指标存储里。这是有意为之：实验集群 `lab` 是个一次性的东西——你会删掉它，但关于它当时表现如何的记录，必须比这次删除活得更久。

要看采集器把数据发往哪个地址：

```bash
# get vmagent = 「让我看看采集器这个对象」。我们不要常规的表格，而是只要它描述里的
# 一个字段 —— -o jsonpath 这个语法对任何集群对象都管用：
#   .items[0]                  找到的第一个（这里也是唯一一个）采集器
#   .spec.remoteWrite[0].url   它把指标交出去的那个地址
#   {"\n"}                     一个换行符，否则输出会和提示符黏在一起
kubectl get vmagent -n cozy-monitoring \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}{"\n"}'
```

```
http://vminsert-shortterm.tenant-workshopXX.svc.cozy.local:8480/insert/0/prometheus
```

这个地址指向你的租户。这跟实验 12 里那台虚拟机与应用对话时用的是同一套机制：普通地址之间的普通网络。

</details>

## 步骤 2. 打开租户的 Grafana

📍 **在哪里做：**在浏览器里。

地址是你租户主机的 `grafana` 子域名：

```
https://grafana.<你的租户主机>
```

确切地址记在控制台（dashboard）里：你的租户 → `Monitoring` 应用 → `Ingress` 选项卡。Ingress 是把一个 service 以某个域名对外发布的规则；最接近的对应物是负载均衡器上的一条记录，只不过它是在同一个集群里描述的。地址完整地写在那里，连主机名一起。

第二个地方是本实验中 `check.sh` 的输出：那一行「Grafana for your metrics」。脚本会从同一个 ingress 里把地址抽出来，所以不用手敲。

⚠️ **如果你的租户里没有 `Monitoring` 应用**——那你也就没有自己的 Grafana，指标会流进父租户的监控里。可靠的做法是从目录（catalog）里部署一个 `Monitoring`（`Administration` 分区）：地址就会出现在你自己那个应用的 `Ingress` 选项卡上，下面所有查询都能用了。`check.sh` 同样会找到别人的监控，并说出它跑在哪个 namespace 里，但只有当你有那个 namespace 的访问权限时才打得开。

**用什么登录。**登录名是 `admin`。密码在 `grafana-admin-password` 这个 Secret 里：控制台（dashboard）→ `Monitoring` 应用 → `Secrets` 选项卡 → `password` 这个键 → `Reveal`。

以租户身份，`kubectl` 不会给你访问这个 Secret 的权限（core 的 Secret 对你不可见），所以走控制台（dashboard）。

如果你用的是父租户的监控，这个 Secret 就在你够不着的地方——那要么按上面说的部署你自己的 `Monitoring` 应用，要么向管理测试环境的人要访问权限。

进去之后，打开 **Explore**——这是做一次性查询的地方，不保存控制台（dashboard）。在数据源下拉框里，选 **`vm-shortterm`**（它也是默认值）。

⚠️ **把查询框切到 `Code` 模式。**Grafana 打开 Explore 时用的是构造器（`Builder`）——一个带下拉框的表单，没地方敲查询文本。`Builder | Code` 切换开关在输入框上方、靠右。下面所有查询都是在 `Code` 里敲的。

<details>
<summary><b>列表里那些数据源都是什么</b></summary>

| 数据源 | 里面是什么 | 保留 |
|---|---|---|
| `vm-shortterm` | 高分辨率的指标 | 3 天 |
| `vm-longterm` | 同样的指标，但做了稀释 | 14 天 |
| `vlogs-generic` | 容器日志 | 1 天 |

两个指标存储而不是一个，是在分辨率和体量之间的一种折中。排查故障你会用 `shortterm`，那里每 30 秒都看得见。回答「它两周前表现如何」这个问题则用 `longterm`，那里分辨率更粗，但深度更大。

这跟 vCenter 统计级别里的逻辑一模一样：20 秒间隔的数据存一天，而每小时的数据存一年。

⚠️ **`vlogs-generic` 是日志，那里的查询语言是另一套。**PromQL 在里面不管用，这不是故障：日志有自己的语法。别浪费时间去切换数据源、再把同一个查询粘进去。

</details>

⚠️ **租户的 Grafana 里没有现成的 Pod 控制台（dashboard）。**列表里会有关于数据库、ingress 和队列的控制台（dashboard）——都是归属于托管服务（managed services）的那些东西。「Pod 和节点」这个层级的控制台（dashboard）不在租户这套里。所以从这里往后，我们都在 Explore 里干活、手写查询。这不如 vCenter 里现成的 Performance 选项卡方便，没必要装作不是这样。

## 步骤 3. 找到你自己的 Pod

📍 **在哪里做：**在 Grafana、Explore、`vm-shortterm` 数据源里。

我们从最粗的问题开始：集群里到底能看见哪些 Pod。查询很短，但里面有三个不熟悉的部分——敲之前先把分解看一遍。

<details>
<summary><b>把查询逐部分拆开</b></summary>

```promql
container_cpu_usage_seconds_total
```

指标的名字。它是一个计数器：容器自启动以来消耗了多少秒的 CPU 时间。它只会往上走——直到容器重启，之后从零重新开始。

它本身没什么用：「这个 Pod 消耗了 4718 秒 CPU」什么也说明不了。这条指标要在配上 `rate()` 之后才变得有用，那个我们下一步再讲。

```promql
{cluster="kubernetes-lab", namespace="default"}
```

按标签过滤。这里两个标签都很重要。

`cluster`——你的集群在平台眼里的名字。它**并不等于** `lab`：应用叫 `lab`，但部署它的那个 release 叫 `kubernetes-lab`，进到标签里的是 release 的名字。这是所有人都会踩的第一个坑。想确认你的叫什么：把值清空，看看 Grafana 的自动补全会给出什么。

需要这个标签，是因为一个存储里放着你**所有**集群和托管服务的指标。没有这个过滤，你拿到的会是整个租户里所有东西掺在一起的结果。

`namespace`——实验集群 `lab` **内部**的 namespace。第一个实验里的应用部署在了 `default`，所以这里就是 `default`。别把它跟租户的 namespace（`tenant-workshopXX`）搞混——那是不同集群里的两码事。租户的 namespace 存在 `tenant` 这个标签里。

```promql
count by (pod) ( ... )
```

按 `pod` 标签分组，数一数每一组里落进了多少条序列。我们感兴趣的不是数字本身，而是最终得到的那份 `pod` 值的列表。

</details>

```promql
# count by (pod) —— 把匹配到的序列按 pod 标签拆开，数一数每组里有多少条序列。
# 数字本身不重要：我们要的是由此得到的那份 pod 名字列表。
count by (pod) (
  # 指标名字 —— 容器 CPU 时间的计数器
  container_cpu_usage_seconds_total{
    cluster="kubernetes-lab",   # 你的集群：这里是 release 的名字，而不是应用名 lab
    namespace="default"         # 实验集群 lab 内部部署了 rickroll 的那个 namespace
  }
)
```

**你应该看到什么：**把视图从 Graph 切到 **Table**——这样列表读起来更顺。表里会有 `rickroll-...`、`fortio-...`，如果你做过实验 11，还会有 `propusk-build-...`。

## 步骤 4. 找到 CPU 尖峰

上一步那个计数器，原样是读不了的。我们把它变成一个能拿来跟 Pod 的 request 对照、也能跟 `kubectl top` 的显示对照的量——变成消耗的核数。`rate()` 在这个过程里做了什么，查询里那两个额外条件又是从哪来的，都在下面的分解里；敲之前先展开它。

<details>
<summary><b>把查询逐部分拆开</b></summary>

```promql
rate( ... [2m])
```

`rate` 拿一个计数器，算出**它每秒的增长速率**，在一个两分钟的窗口内做平均。对 CPU 时间这条指标来说，这给出一个非常好用的量：「每秒消耗了多少秒 CPU」，也就是消耗了多少个核。`0.24` 表示一个核的 24%，换算成毫核就是 `240m`。

`[2m]` 这个窗口是一种折中。窗口更小（`[30s]`）——图会很跳，数据稀疏时还会断开。更大（`[5m]`）——尖峰会被抹平，不高的峰可能彻底消失。从 `[2m]` 开始，再往下调。

⚠️ **窗口至少要是采集间隔的两倍。**采集每 30 秒一次，所以不能设成低于 `[1m]` 的值——那样窗口里只会落进一个点，而单靠一个点算不出速率，图就会变空。这是「我这儿什么都画不出来」最常见的原因。

```promql
pod=~"rickroll-.*"
```

`=~`——按正则表达式比较，而不是精确匹配。精确匹配在这里不行：Pod 名字带着一段随机的尾巴，每次重新创建都会变。

```promql
container!=""
```

丢掉没有容器名的那些序列。这样的序列是存在的：它们是整个 Pod 的汇总，如果不丢掉，每个 Pod 都会被数两遍，图会精确地显示成真相的两倍。又一个经典陷阱。

```promql
sum by (pod) ( ... )
```

把剩下的一切按 Pod 加起来。一个 Pod 可以有好几个容器；我们关心的是整个 Pod。

</details>

```promql
# rate(...[2m]) —— 计数器每秒的增长速率，在 2 分钟的窗口内做平均。
# 对 CPU 时间来说，它读作「消耗了多少个核」：
# 0.24 —— 一个核的百分之二十四，也就是 240m。
sum by (pod) (     # 把 pod 的各个容器加起来：每个 pod 一条线，而不是每个容器一条
  rate(container_cpu_usage_seconds_total{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*",  # =~ 按正则表达式比较：pod 名字的尾巴是随机的
    container!=""        # 丢掉整个 pod 的汇总序列，否则一切都会翻倍
  }[2m])
)
```

把时间范围设成你做实验 3 的那段时间——比如最近 3 小时。

**你应该看到什么：**一条紧贴零的平线，然后在负载持续期间陡然升起，再回落下来。如果副本变成了好几个，就会有好几条线，而且它们不是同时出现，而是随着 Pod 被逐个创建而出现。

## 步骤 5. 找到自动扩缩容的台阶

尖峰找到了。现在来看看集群是怎么回应它的：每一个时刻它跑着几份应用副本，又想跑几份。这是两个不同的数字，两者之间的差距是这一步里最有意思的东西。它们从哪来，都在下面的分解里。

<details>
<summary><b>这些指标从哪来，desired 又和 current 有什么区别</b></summary>

这些指标不是来自应用，而是来自 `kube-state-metrics`——它通过 API 读取集群对象，把它们的字段变成数字。`horizontalpodautoscaler` 这个标签是 HPA 对象的名字（`HorizontalPodAutoscaler`，就是实验 3 里那条自动扩缩容规则），`deployment` 标签是 Deployment 的名字，也就是「保持这么多份应用副本」这份描述的名字，其余每一种对象类型都以此类推。

`desired`——自动扩缩容根据负载算下来，此刻**想要**几份副本。`current`——**实际**跑着几份。两者之间总有落差：Pod 不是瞬间创建出来的。

如果 `desired` 长时间高于 `current`，就说明副本创建不出来。原因几乎总是同一个：节点上没有足够的空间，新 Pod 卡在 `Pending`。正是你在实验 11 里撞上的那种情况。

放在旁边一起看很有用：

```promql
# rickroll 一共创建了多少份副本
kube_deployment_status_replicas{cluster="kubernetes-lab", deployment="rickroll"}
# 其中有多少份通过了就绪检查、已经在接流量
kube_deployment_status_replicas_available{cluster="kubernetes-lab", deployment="rickroll"}
```

在发布新版本的滚动发布过程中，两者之间的分叉，正是新副本通过就绪检查时的那段停顿。

</details>

```promql
# ..._status_current_replicas —— rickroll 此刻跑着多少份副本。
# 这个数字不来自应用，而来自 HPA 对象，由 kube-state-metrics 读取。
kube_horizontalpodautoscaler_status_current_replicas{
  cluster="kubernetes-lab",             # 只要你的实验集群 lab
  horizontalpodautoscaler="rickroll"    # 实验 3 里那个自动扩缩容对象的名字
}
```

再在旁边作为第二个查询：

```promql
# ..._status_desired_replicas —— 自动扩缩容根据负载，此刻想要几份副本。
# current 落后于 desired，正是创建 pod 所花的时间。
kube_horizontalpodautoscaler_status_desired_replicas{
  cluster="kubernetes-lab",
  horizontalpodautoscaler="rickroll"
}
```

**你应该看到什么：**一条阶梯状的线。先是 1，然后 3，然后 5 或 6，然后——在负载消退后约一分钟的延迟之后——再降回来。

把它叠到上一步的 CPU 消耗图上：在 Explore 里，第二个查询用 `+ Add query` 按钮添加。可以看到，台阶**跟在**尖峰后面，落后几十秒：先是 CPU 上去了，然后自动扩缩容才注意到并作出反应。这正是「为什么用户到底还是察觉到了变慢」这个问题的答案。

## 步骤 6. 换用自动扩缩容的眼睛来看同一件事

自动扩缩容看的不是绝对的消耗，而是**相对于 `requests` 的比例**。`requests` 是一个 Pod 对资源的申请：调度器在节点上为它预留多少 CPU 和内存，不管这个 Pod 实际用不用得上这些资源。最接近的对应物是 vSphere 里的资源预留（reservation）。

我们来看看决策所依据的那个量。这个查询由用除号隔开的两部分组成：上面是实际消耗，下面是申请。

```promql
# 上半部分 —— pod 实际的 CPU 消耗。跟上面那个查询一样。
sum by (pod) (
  rate(container_cpu_usage_seconds_total{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*", container!=""
  }[2m])
)
/
# 下半部分 —— pod 申请了多少。相除的结果就是相对于申请的比例：1 表示
# 「消耗的正好等于申请的」，0.5 —— 申请的一半。
sum by (pod) (
  kube_pod_container_resource_requests{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*",
    resource="cpu"     # 这条指标也有内存的序列 —— 我们只保留 CPU
  }
)
```

**你应该看到什么：**一条几乎全程都走得很低、只在负载期间升起来的线。这张图上的 1 表示「Pod 消耗的正好等于它申请的」。

实验 3 的 `hpa.yaml` 里有 `averageUtilization: 50`，而 `rickroll.yaml` 里有 `requests.cpu: 20m`。也就是说，触发阈值是每个 Pod 10 毫核，在图上就是 `0.5` 这条刻度线。找到线越过它的那一刻，跟上一步的台阶对照一下：两者之间就会是那同样的几十秒。

⚠️ PromQL 里两个表达式相除，是按**所有**标签匹配来工作的。这里能对上，是因为两部分都按 `by (pod)` 分了组，分组之后不再剩下别的标签。如果两边的标签集合不一样，结果就会是空的——没有报错，没有警告，一张空图。这是这门语言最阴险的特性。

## 步骤 7. 三个日常常用的查询

这几个值得存下来——它们覆盖了日常大部分的问题。

**集群里谁消耗 CPU 最多，前 10 名：**

```promql
# topk(10, ...) —— 只保留值最大的那十条序列。
# 按 (namespace, pod) 分组会把 namespace 加进答案里：能看出这是谁的 pod。
# [5m] 窗口比前几步的宽：我们要的不是尖峰的形状，而是平均水平。
topk(10,
  sum by (namespace, pod) (
    rate(container_cpu_usage_seconds_total{cluster="kubernetes-lab", container!=""}[5m])
  )
)
```

**按 Pod 看内存（不是计数器，所以不用 `rate`）：**

```promql
# container_memory_working_set_bytes —— 不是计数器，而是一个瞬时值：此刻占用了这么多字节。
# rate() 在这里会算出没有意义的东西 —— 「每秒多少字节」。
sum by (pod) (
  container_memory_working_set_bytes{
    cluster="kubernetes-lab", namespace="default", container!=""
  }
)
```

⚠️ 必须是 `working_set`，而不是 `container_memory_usage_bytes`。后者把文件缓存也算进去，而内核在有压力时会把这部分让出来，所以它经常用一些跟应用真实需求毫不相干的数字把人吓一跳。因内存而杀掉一个 Pod 的决定，同样是依据 `working_set` 作出的。

**预留了多少资源，相对于实际用了多少：**

```promql
# sum 不带 by —— 把一切加成一个数：整个集群的所有 pod 一共预留了多少 CPU。
# 这是申请，而不是消耗：预留了却在空转的那部分也会算进总和里。
sum(kube_pod_container_resource_requests{cluster="kubernetes-lab", resource="cpu"})
```

把这个数字跟第一个查询里的总和对照一下。「预留」和「使用」之间的差，就是你付了钱却什么都没换回来的那部分。跟 vSphere 里聊预留是同一场对话，只不过这里能在图上看见它。

如果你做过实验 11，顺便看看 Android 构建——它非常显眼：

```promql
# 同样的 rate，但过滤到构建的那些 pod。sum 不带 by (pod) —— 整个构建一条线，
# 不管它起了多少个 pod。
sum(rate(container_cpu_usage_seconds_total{
  cluster="kubernetes-lab", pod=~"propusk-build-.*", container!=""
}[2m]))
```

二十分钟里在一个半到两个核上保持一道平坦的高原，然后跌到零。这就是一个 Job 在图上的样子——一次性的任务，把活干到底然后结束。跟被长期保持运行的应用不同，它的线是有终点的。

## 步骤 8. 到日志里看看

把数据源切到 **`vlogs-generic`**。这里的查询语言是另一套：在 PromQL 里你描述的是数值序列，在 LogsQL 里你是按字段的值来挑选文字行。

下面这个查询读起来是这样：「显示那些 `kubernetes_namespace_name` 字段等于 `default`、并且 `kubernetes_pod_name` 字段以 `rickroll` 开头的行」。末尾的星号就是 Pod 名字里那段随机的尾巴，也正是它逼得你在 PromQL 里得写 `=~`。

```logsql
kubernetes_namespace_name:default AND kubernetes_pod_name:rickroll*
```

对上时间：取你在 CPU 消耗图上找到的那次尖峰所在的那一分钟，看看它这一分钟的日志。在那一分钟里，nginx 会有一波请求记录的尖峰。

**这正是我们把指标和日志分开的意义所在。**靠图，你一秒钟就在三个小时里找到了那个时刻。靠那一分钟的日志，你知道了到底在发生什么。反过来行不通：靠翻日志去找「什么时候开始变糟的」，可以找上非常久。

## 检查

📍 **在哪里做：**在笔记本电脑上，就是你刚才操作 `kubectl` 的那个终端窗口里。

```bash
export KUBECONFIG=~/lab.kubeconfig          # 访问实验集群 `lab`

# 下面这两个变量让脚本还能访问租户。有了它们，脚本会额外检查指标是否真的到了那里，
# 并打印出你 Grafana 的地址。没有它们，检查也能通过，但报告会短一些。
export COZY_TENANT=workshopXX               # 用你的编号替换 XX
export COZY_KUBECONFIG=~/.kube/workshop     # 访问租户的文件

./check.sh                                  # ./ = 「从当前文件夹里运行这个文件」
```

⚠️ **在 Windows 上，脚本要从 WSL 里运行**，而不是从 PowerShell——怎么装它，写在实验 0 的开头。不用 WSL 也能完成这个实验，只是不会有报告这个产物。

脚本检查的不是「你看了图」——那没法检查——而是能检查、也应该检查的东西：指标采集确实在工作、发送确实配置到了你的租户、日志采集在工作，以及集群里确实有一段来自实验 3 的负载痕迹，能在这些图里被找到。

## 清理

没什么要清理的。`Monitoring agents` 附加组件消耗不多，而且一直到工作坊结束都用得上——让它保持开着。

指标会自己抹掉：默认 `shortterm` 存 3 天，`longterm` 存 14 天，日志存一天。这是那种难得的情况——清理已经替你做好了，而且忘不掉。

## 我们现在会做什么了

- 解释为什么指标要持续采集，以及它们和日志有什么区别
- 检查集群里的采集是否已开启、又究竟发往哪里
- 写出能找到你自己的 Pod 及其消耗的查询，并且不在 `container!=""` 上栽跟头
- 在图表里找到负载尖峰，以及自动扩缩容对它的反应
- 把 `desired` 和 `current` 的分叉读成空间不足的信号

## 换成 vSphere 会是怎样

vCenter 显示主机和虚拟机的计数器——只要问的是关于虚拟机的问题，这就够了。可一旦问题变成「这个服务出了什么事」，就得上 vRealize Operations：一个单独的产品、一份单独的许可证、一次单独的安装、几台单独的虚拟机来跑它，还得有一个单独的、会配置它的人。

在这里，指标和日志采集是个在应用里勾一下就开启的附加组件，而带存储的 Grafana 作为目录（catalog）里的一项就起来了。没有许可证，没有实施项目。

**说句公道话，vSphere 更省事的地方。**论装完就能用的东西，vCenter 赢得毫无悬念，而我们在这个实验里就看到了：

| | vSphere | Cozystack |
|---|---|---|
| 装完立刻就有图 | 每个对象上的 Performance 选项卡 | 需要开启附加组件、再打开 Grafana |
| 现成的视图 | 任何 VM 和主机都有 | 在租户里 —— 只有托管服务才有 |
| 找到你要的那个计数器 | 用鼠标从列表里挑 | 用 PromQL 写一个查询 |
| 入门门槛 | 一个小时 | 好几天，PromQL 得学 |
| 上手之后的深度 | 受限于计数器的那一套 | 受限于采集了哪些指标和标签 |

PromQL 是一门语言，它确实得学。头两周，你会一边抄别人的查询，一边搞不懂图为什么是空的。作为回报，你得到了 vCenter 根本没有的东西：能问出任意一个问题的能力——「显示这个应用的 Pod 相对于它们预留量的消耗，按节点分组，取上周二」——并且能得到答案，而不是「没有这样的计数器」。
