# 实验 3 · 负载与自动扩缩容

| | |
|---|---|
| **时长** | 30 分钟 |
| **验证什么** | 副本数量可以由负载决定，而不是由一张服务台工单决定 |
| **需要准备** | 实验 0 的集群、实验 1 的 `rickroll`、三个终端窗口、一个浏览器 |

## 为什么这很重要

这次练习的全部意义所在——「门禁通行证」服务——运行起来并不均匀。早上八点，保安和半个办公室同时打开它；下午三点，没人碰它。按峰值来配置容量意味着一天有九个小时在白白烧钱，按平均值来配置则意味着门口排起长队。

我们来试试第三种选择：副本数量不由人来指定，而由负载本身来决定。我们会给应用真实的流量，看着它涨到六个副本，然后再缩回一个。

一路上我们还会理清人们在这里最容易绊倒的地方——「我们请求多少」和「我们允许多少」之间的区别。

## 小词典

| 术语 | 是什么 | 类似于……但 |
|---|---|---|
| **HPA** | 一个根据指标改变副本数量的对象 | **DRS 加上手动添加虚拟机**，但它改变的是实例的数量，而不是把它们分散到各个主机上 |
| **metrics-server** | 一个收集 Pod 当前消耗量的服务 | **vCenter 的统计数据收集**，但它只保留最近几分钟——完全没有历史数据 |
| **requests** | 我们作为保证量预留了多少资源 | **资源预留（reservation）**，但利用率百分比是从它算出来的，而且它也决定了一个 Pod 能放进哪里 |
| **limits** | 一个 Pod 无法超越的上限 | **Limit（上限）**，但触到上限时 CPU 会被限流，而内存会杀掉 Pod |
| **利用率** | 消耗量占 `requests` 的百分比 | **图表上的「CPU Usage %」**，但它可以是 600%，而这并不是错误 |
| **Fortio** | 一个带 Web 界面的负载生成器 | **HCIBench**，但它作为一个普通应用运行在集群内部 |

## 实验文件夹里有什么

你已经拥有了所有文件——它们是随仓库一起拿到的。没有什么要创建或重新敲的：下面凡是写着 `kubectl apply -f name.yaml` 的地方，文件都来自这里。

```bash
# Every command in this lab is run from this folder — otherwise the file names in them won't be found.
cd labs/03-scale
```

| 文件 | 是什么 | 什么时候用得上 |
|---|---|---|
| `hpa.yaml` | 自动扩缩容规则：根据 CPU 负载增加副本 | 你在自己的实验集群 `lab` 上应用它 |
| `fortio.yaml` | 一个带 Web 界面的负载生成器——就是用它来施加负载 | 你把它应用到同一个地方 |
| `check.sh` | 验证副本在负载下增加、之后又缩减 | 你在实验结束时运行它 |

## 步骤 1. 确认我们从单个副本开始

📍 **位置：** 在笔记本电脑上。

整个实验都建立在副本数量明显增长的基础上。所以我们必须从一个开始——否则增长就没有可以对照的参照。我们来看看现在有几个副本在运行。

```bash
# KUBECONFIG is the path to the file with the cluster's address and login details.
# Until the variable is set, kubectl looks for the cluster on the laptop itself and doesn't find it.
export KUBECONFIG=~/lab.kubeconfig

# The READY column reads as "ready / requested": 1/1 means one replica requested and running.
kubectl get deployment rickroll
```

它应该显示 `1/1`。如果更多，就把它降回一个，否则增长就不会那么明显：

```bash
# scale changes exactly one field in the application's record — the replica count.
# The cluster will retire the extra replicas on its own, within seconds.
kubectl scale deployment rickroll --replicas=1
```

## 步骤 2. 读一读应用请求了什么

在配置自动扩缩容之前，你需要弄清楚它会拿什么来计算百分比。

```bash
# An object in the cluster has hundreds of fields; the table doesn't show them. jsonpath extracts
# exactly one spot from the response. Read the path top to bottom: spec.template is the template
# from which replicas are created, containers[0] is the first container in it, resources is its
# request and ceiling for CPU and memory. The tail {"\n"} is a newline, so the response
# doesn't run into the next command prompt.
kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

```json
{"limits":{"cpu":"300m","memory":"128Mi"},"requests":{"cpu":"20m","memory":"32Mi"}}
```

两对数字，而人们总是把它们弄混。我们拿 CPU 来讲清楚。

**`requests: cpu: 20m`**——「二十毫核」，也就是百分之二个核心。这是请求量：集群承诺随时为这个 Pod 保留的量。调度器用这个数字来决定 Pod 能不能放进某个节点：一个节点上所有 Pod 的请求量之和不能超过该节点的容量。最接近的类比是 vSphere 里的预留。

**`limits: cpu: 300m`**——上限。哪怕节点空闲，也不会给这个 Pod 超过十分之三个核心。类比是 vSphere 里的 limit。

它们之间有十五倍的差距，而这是有意为之的：当 CPU 空闲时，一个 Pod 可以拿很多，但保证给它的只有一点点。

⚠️ **CPU 和内存触到各自上限时的行为不一样，而这比看上去更要紧。** 触到 CPU 上限，应用只是开始变慢（限流）。触到内存上限，内核就会杀掉容器：你会看到 `OOMKilled` 状态，Pod 被重新创建。前者令人不快，后者是一次故障。在 vSphere 里内存同样不能超额，但那里客户机会拿到交换空间而降级，而不是死掉。

**而现在是这个实验的关键点。** HPA 计算负载不是从上限算，不是从节点容量算，也不是从应用内部看到多少个核心算。它**从 `requests` 算**。阈值 50% 配上 `requests: 20m`，意味着每个副本 10 毫核。

由此引出了那件最常让第一次配置自动扩缩容的人卡住的事：**如果一个容器没有指定 `requests.cpu`，就没有可计算的基准，HPA 根本不会工作。** 它不会报错——它会默默地一直显示 `<unknown>`。

## 步骤 3. 打开自动扩缩容

文件夹里有 `hpa.yaml`。我们把它过一遍，然后应用它。

<details>
<summary><b>细看一下：hpa.yaml 里面是什么</b></summary>

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rickroll
```

`autoscaling/v2` 不是摆设。在旧的 `v1` 里，你只能设定一个 CPU 目标，无法控制增长的速率。`metrics` 块以下的一切在 `v1` 里都用不了。如果你在网上看到一个用 `autoscaling/v1` 的例子——它没有过时到致命的地步，但它覆盖不了你需要的一半东西。

```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rickroll
```

我们盯着谁、又调整谁。HPA 不直接管理 Pod——它改动 Deployment 上的 `replicas` 字段，从那里开始，运转的就是和自愈实验里同样的链条：Deployment 把数字传给 ReplicaSet，ReplicaSet 创建缺少的副本。

由此得出一条实用规则：**只要 HPA 存在，用手改 `replicas` 就是徒劳。** 你设成三，十五秒后 HPA 就设成它自己的。两个机制争抢一个字段永远是一场争执，而这场争执 HPA 会赢。

```yaml
  minReplicas: 1
  maxReplicas: 6
```

一条走廊。下界防止「没有负载，那就全关了吧」——HPA 无法缩到零。上界保护预算和节点：没有它，一次突发的尖峰（或者应用里一个吃满 CPU 的 bug）会不停地繁殖副本，直到节点上没有地方为止。

六是为培训节点 `u1.medium` 选的。六个副本，每个请求 20m，就是 120m——节点轻松扛得住。

```yaml
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

规则：把所有副本的**平均**负载保持在它们 `requests` 的 50%，也就是每个副本 10m。

「平均」这个词在这里是关键，全部算术都取决于它。HPA 是这样算的：

```
replicas needed = ceil( current replicas × current load ÷ target load )
```

一个副本在 645% 负载、目标 50% 的情况下，得出 `ceil(1 × 645 / 50) = 13`。十三大于六，所以 HPA 会顶到 `maxReplicas`。

为什么目标是 50 而不是 80：在 80% 时，增长只有在应用已经陷入困境之后才开始。一半留出了余量，用来等新副本起来的那段时间。对于真实的服务，这个数字要根据启动需要多少秒来调。

```yaml
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 2
          periodSeconds: 15
```

增长的速率。默认情况下，在扩容之前，Kubernetes 会看一个时间窗口内的指标历史，好让它不会为一个随机尖峰而抽动。在实验里那看起来就像「什么都没发生」，所以这个窗口被清零了：我们对第一次测量就做出反应。

`Pods: 2 / 15s`——每十五秒最多加两个副本。这就是为什么向上的路会呈阶梯状：1 → 3 → 5 → 6。

⚠️ **通过指定 `policies`，你是替换掉了标准策略，而不是在它们之上追加。** 标准的增长策略（每 15 秒翻倍）在这里不再生效。

```yaml
    scaleDown:
      stabilizationWindowSeconds: 60
```

而向下则相反，是带延迟的。HPA 会看最近一分钟内请求数量的最大值，只有当整段区间负载都很低时，才减少副本数量。否则，每逢尖峰之间的一次停顿，副本就会开始消失又重现。

这里的标准值是 **300 秒**，五分钟。我们把它砍到一分钟，好让你在实验期间来得及看到回落。生产环境里五分钟更合理。

</details>

应用它：

```bash
# apply = "bring the cluster to what's described in the file." The HPA object will appear at once,
# but it won't start computing right away — that's what we'll trip over in the next step.
kubectl apply -f hpa.yaml
```

## 步骤 4. 通不过的那次检查

我们来看看得到了什么：

```bash
# hpa is shorthand for horizontalpodautoscaler; kubectl understands both spellings.
# The TARGETS column reads as "current load / target," REPLICAS is how many
# replicas are requested right now.
kubectl get hpa rickroll
```

**你会看到：**

```
NAME       REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: <unknown>/50%   1         6         1          10s
```

在 `TARGETS` 这一列里，负载的位置上是 `<unknown>`。自动扩缩容不知道应用消耗了多少 CPU，因此它也就没有可以据以做决定的依据。

⚠️ **又或者你会马上看到一个百分比**——比如 `cpu: 5%/50%`。这不代表你那里有什么不同：你集群里的指标收集器已经运行了一段时间，来得及轮询过 Pod 了。`<unknown>` 出现在一个刚刚拉起来的集群上。如果你一上来就看到数字——还是把下面的分析读一遍，因为 `<unknown>` 的成因你总有一天会碰上，提前弄懂它，好过在它挡你路的那一刻才弄懂。

> **在往下读之前，停下来想一想。**
>
> 清单应用时没有出错，对象创建好了，容器有 `requests`——我们刚刚看过。所以问题不在于描述里少了什么。
>
> 提示：自动扩缩容到底是从哪儿得知当前负载的？总得有人把那个数字报给它——而那个人轮询 Pod 不是连续不断的，而是每隔几十秒一次。

<details>
<summary><b>答案，以及一个比这个错误更宽泛的教训</b></summary>

时间还不够。等一分半到两分钟，再看一次：

```bash
# The same command as above. We're looking at the same TARGETS column.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 0%/50%     1         6         1          2m
```

**这不是坏了，这里没什么好修的。** Pod 的负载是由一个单独的服务 `metrics-server` 收集的。它大约每十五秒轮询一次节点，并在一个短窗口内对结果取平均。在它拿到连续两次测量之前，它没有东西可交，于是 HPA 老老实实地写下「我不知道」。

你可以直接检查指标是不是在流动：

```bash
# top = "how many resources these Pods are eating right now." The numbers come from
# the same metrics-server that feeds autoscaling: if top answers, then the
# data source is alive and it's only a matter of time.
kubectl top pods -l app=rickroll
```

```
NAME                        CPU(cores)   MEMORY(bytes)
rickroll-6f4b9c8d57-p9wqt   1m           4Mi
```

如果过了五分钟仍然是 `<unknown>`，而 `kubectl top` 回应 `error: Metrics API not available`——那它就真的是坏了，成因二选一：`metrics-server` 没有装在集群里，或者容器没有设 `requests.cpu`（这种情况下 `kubectl top` 能工作，但 HPA 仍然算不了——没有可以取百分比的基准）。

`metrics-server` 会随集群一起自行装好——你不需要单独启用它。它住在 `cozy-monitoring` 这个 namespace 里，可以这样检查：

```bash
# -n = which namespace to look in. A namespace is a section of the cluster;
# by default kubectl looks in default and doesn't see the system Pods there.
# deploy is shorthand for deployment.
kubectl -n cozy-monitoring get deploy metrics-server
```

别把它和实验 0 里的 **Monitoring agents** 复选框搞混：那个负责把指标收进存储、负责画图（可观测性那个实验），而 `metrics-server` 负责 `kubectl top` 和自动扩缩容所需的当前数字。不同的机制，各自独立地存在。

确切的成因由这条告诉你：

```bash
# describe = the object's full card: all fields, events, and conditions,
# unlike get, which prints a few table columns.
kubectl describe hpa rickroll
```

在最下面的 `Conditions` 里，会有一行 `ScalingActive`，带着一段人能读懂的解释。

**一个比这个错误更宽泛的教训。** 在 Kubernetes 里，「已应用」和「在工作」是在时间上分开的。`apply` 命令只是把你的意图记录进集群。从那里开始，控制器接手，而每个控制器都有自己的节奏：HPA 每十五秒重算一次，指标滞后一分钟，垃圾回收器每隔几分钟才来一趟。从 vCenter 带来的那个习惯——「对话框关了，那就是做完了」——在这里会坑你。你该盯的不是命令的返回码，而是对象的 `status`。

</details>

## 步骤 5. 拉起负载生成器

从笔记本电脑通过 `port-forward` 去压这个应用是没有意义的：瓶颈会变成你家里的网络和隧道本身，而不是应用。生成器必须待在集群内部，紧挨着目标。

文件夹里有 `fortio.yaml`。

<details>
<summary><b>细看一下：fortio.yaml 里面是什么</b></summary>

```yaml
kind: Deployment
metadata:
  name: fortio
```

Fortio 是集群里一个普通的应用，用和其他一切东西一样的 Deployment 来部署。这里没有什么特殊的「测试基础设施」，而这件事本身就很说明问题。

```yaml
        - name: fortio
          image: fortio/fortio:latest
          args: ["server"]
```

Fortio 镜像能以两种模式运行。`fortio load ...` 是从命令行发起的一次性运行。`fortio server` 是一个持续运行、带 Web 界面的服务，你在那里用一个按钮启动负载，结果就地以图表呈现。我们选第二种：在工作坊上，在浏览器里看延迟直方图，比在终端里读一列数字更清楚。

⚠️ **清单里的 `latest` 标签是你在生产里不该做的事。** 今天它是一个镜像，一个月后是另一个，你就没法重现你自己的测试了。对一个培训用的生成器来说这尚可容忍，对别的任何东西则不然。

```yaml
          ports:
            - containerPort: 8080
              name: http
```

Fortio 的 Web 界面监听 8080，位于路径 `/fortio/`。名字 `http` 在下面的 Service 里会用到。

```yaml
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: "1"
              memory: 256Mi
```

注意：给生成器分配的比给目标的还多。请求量 100m 对上 `rickroll` 的 20m，上限是一整个核心对上 300m。

这不是慷慨，而是一次正确测试的必要条件。如果生成器 CPU 不够用，它会顶到自己的上限，那你测量的就是 Fortio，而不是应用。这个错误的症状很好认：延迟在上升，而目标的负载却原地不动。

```yaml
kind: Service
metadata:
  name: fortio
spec:
  ports:
    - port: 8080
      targetPort: http
```

给 Web 界面的一个稳定地址。从集群内部，它现在可以用 `http://fortio:8080/` 访问到，从外部则通过 `port-forward`——我们接下来就要这么做。

</details>

应用并等待：

```bash
# There are two objects at once in the file: the Deployment with the generator and a Service — a
# stable address for its web interface.
kubectl apply -f fortio.yaml

# rollout status holds the terminal and prints progress until the replica is ready.
# We wait here on purpose: until the generator is up, there's nothing to drive load with.
kubectl rollout status deployment/fortio
```

## 步骤 6. 在浏览器里打开 Fortio

📍 **窗口 1**——通往 Fortio 的隧道。选端口 `8081` 是为了不和 `8080` 冲突，以防你还开着实验 1 里通往 `rickroll` 的隧道：

```bash
export KUBECONFIG=~/lab.kubeconfig

# port-forward runs a tunnel from your laptop into the cluster.
#   svc/fortio    what we connect to: the Service named fortio
#   8081:8080     reads as "port on your side : port in the cluster" — a request
#                 to localhost:8081 goes to port 8080 of this Service
kubectl port-forward svc/fortio 8081:8080
```

这条命令不会结束——它把隧道保持打开。趁它运行时，打开 <http://localhost:8081/fortio/>。

⚠️ **路径末尾的斜杠是必须的。** 在没有它的 `http://localhost:8081/fortio` 地址上，Fortio 回应 404，看起来就像是它没启动。

## 步骤 7. 准备好第二个窗口来观察增长

实验的重点不在于 Fortio 报告里的数字，而在于副本身上发生了什么。你需要在施加负载的同时看到这件事，而不是在之后。

📍 **窗口 2**——一直开着，直到实验结束。

我们会用 `-w`（watch）标志来观察。它的意思不是「刷新屏幕」，而是「每有一次变化就打印一行新的」。输出出来的是一份事件日志，而不是一张表格。这是它和 `watch kubectl get pods` 的一个重要区别，后者你只看到「此刻」的快照，很容易错过中间状态。

```bash
export KUBECONFIG=~/lab.kubeconfig

# We watch rickroll's replicas: each new line is a state change of one of them.
# The command doesn't finish; to exit, Ctrl+C — this has no effect on the replicas themselves.
kubectl get pods -l app=rickroll -w
```

如果你有第三个窗口，也把这条放进去——这样你就能看到决策过程本身：

```bash
# The same watching, but of the autoscaling decisions: TARGETS shows how the load
# changes, REPLICAS shows how many replicas it requested in response.
kubectl get hpa rickroll -w
```

## 步骤 8. 施加负载

📍 **位置：** 在浏览器里，在 Fortio 的标签页上。

填写表单：

| 字段 | 值 | 为什么这样 |
|---|---|---|
| URL | `http://rickroll/` | Service 的名字；Fortio 在集群里，直接就能看到它 |
| QPS | `1200` | 每秒一千二百个请求 |
| Duration | `90s` | 一分半：既够增长，也够看清楚 |
| Connections | `80` | 八十个并行连接 |

按 **Start**。

⚠️ **如果你这个版本的 Fortio 里字段名字不一样**（比如连接数被标为 `Threads`），就按含义来对：URL、请求速率、时长、并行度。同样的负载也可以用一条命令施加，绕开浏览器：

```bash
# exec runs a command inside an already-running Pod, not on your laptop.
#   deploy/fortio   in a Pod of this application; which Pod exactly — kubectl picks itself
#   --              everything after this separator is the command for the Pod
#   -qps 1200       twelve hundred requests per second
#   -c 80           eighty parallel connections
#   -t 90s          hold the load for a minute and a half
# The last argument is the target: the Service name of our application.
kubectl exec deploy/fortio -- fortio load -qps 1200 -c 80 -t 90s http://rickroll/
```

## 步骤 9. 观察发生了什么

📍 **窗口 2**，在开始后大约二十秒：

```
NAME                        READY   STATUS              AGE
rickroll-6f4b9c8d57-p9wqt   1/1     Running             22m
rickroll-6f4b9c8d57-mn4kd   0/1     Pending             0s
rickroll-6f4b9c8d57-mn4kd   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-t8zxc   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-mn4kd   1/1     Running             3s
rickroll-6f4b9c8d57-t8zxc   1/1     Running             3s
```

然后又两个，接着再一个。一分钟内就有了六个副本。

📍 **看看 HPA**——它看到了什么、又决定了什么：

```bash
# TARGETS is the current average load against the target, REPLICAS is how many replicas are requested.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 645%/50%   1         6         6          8m
```

**645%。** 在试跑这个实验的那个测试环境上，恰好是这个数；你那里会是另一个数量级，但肯定是几百个百分点。

这个数字看起来荒唐，直到你想起它是从什么算出来的。不是从节点容量，而是从副本的**请求量**，而我们的请求量是 20m——百分之二个核心。一个副本占用的比它申请的多出好几倍，而这是允许的：`requests` 是有保证的最小值，不是上限。上限是 `limits`，离它还远着呢。

与此同时，节点远谈不上空闲：`u1.medium` 是一个核心，而在这一分钟里，应用的副本和负载生成器本身都跑在它上面。这么高的百分比来自的不是容量的充裕，而是一个很小的分母。

**超过一百的百分比在这里是常态，不是警报。** 这是最能击碎从 vCenter 带来的直觉的一点：在那里，「CPU Usage 645%」意味着一场灾难，因为百分比是从分配给你的量算出来的。在这里，它是从申请的最小值算出来的，而在请求量和上限之间，我们有十五倍的差距。

自己验证一下 HPA 的算术：

```bash
# The consumption of each replica separately. CPU(cores) is printed in millicpu:
# 100m is a hundredth of a core, 1000m is a whole core.
kubectl top pods -l app=rickroll
```

各副本的平均值，正是 HPA 拿来和阈值比较的那个数字：20m 请求量的 50%，也就是 10m。所有副本之和会顶到节点的那个核心——增长就在那里停下，哪怕你再把负载调高。

📍 **与此同时，在浏览器里的 Fortio 标签页上**，一张延迟直方图正在被画出来。把这次运行看到底：末尾会出现一行像 `Code 200 : 108000 (100.0 %)` 这样的内容。零错误——应用扛住了。记住这一行在哪里：在实验 4 里，它会是主要的证据。

## 步骤 10. 观察副本如何降回去

负载结束了。什么都别做，看着窗口 2。

头一分半到两分钟里什么都不会发生。这段停顿由三个延迟组成：指标滞后大约一分钟，`stabilizationWindowSeconds: 60` 要求负载在整个最后一分钟里都很低，而 HPA 自己每十五秒重算一次。

然后一堆行会一下子涌出来：

```
rickroll-6f4b9c8d57-t8zxc   1/1     Terminating   4m
rickroll-6f4b9c8d57-mn4kd   1/1     Terminating   4m
...
```

五个副本离开，剩下一个——`minReplicas`。

**注意这种不对称。** 我们向上是以每次两个副本的阶梯上去的；向下则是一步就下来了。这是有意设计的：往「副本太多」的方向出错只花钱，而往「副本太少」的方向出错则意味着把服务搞垮。所以它们增长得激进，收缩得谨慎。

## 验证

📍 **位置：** 在笔记本电脑上，在你此前用 `kubectl` 干活的同一个终端窗口里。

这个脚本检查的不是清单被应用了这个事实，而是这套机制是不是真的活着：HPA 存在并且指向正确的 Deployment，容器有一个用来算百分比的 `requests.cpu`，`metrics-server` 确实在交出数字（`TARGETS` 不是 `<unknown>`），以及 HPA 的状态里仍然带着一个标记，表明扩缩容已经触发过了。

⚠️ **在清理之前运行检查**——一旦 HPA 被删除，就没有东西可检查了。

⚠️ **在 Windows 上，脚本从 WSL 里运行**，而不是从 PowerShell——怎么装它，写在实验 0 的开头。没有 WSL 也能完成本实验，但不会有报告产物。

```bash
# ./ means "a file from the current folder," not a command from the system PATH.
# The script changes nothing in the cluster: it only reads and prints a report.
./check.sh
```

## 清理

**删除 HPA。** 在实验 4 里，我们会在负载下滚动发布一个新版本，而一个此时同时在改变副本数量的多余机制只会把画面搅乱：

```bash
# delete -f = "remove from the cluster what's described in this file." The application stays:
# only the HPA is described in the file. After deletion the replica count freezes at the current value.
kubectl delete -f hpa.yaml
```

**保留 Fortio**——在实验 4 里它会作为负载来源被用到。如果你不打算做实验 4，就把它也移除：

```bash
# Removes both objects from the file — the generator's Deployment and its Service.
kubectl delete -f fortio.yaml
```

不要碰 `rickroll` 应用。

你释放的一切，在容器结束的那一刻就回到了节点的共享池里。这里没有「已分配但没交还」这回事——一份请求活得恰好和 Pod 一样久。

## 我们现在能做到什么

- 解释 `requests` 和 `limits` 的区别，并预测触到每一个时会发生什么
- 理解为什么 HPA 从 `requests` 算百分比，以及为什么没有它 HPA 就不工作
- 读懂 HPA 的公式，并提前说出它会请求多少个副本
- 把「清单已应用」和「机制开始工作」区分开来，并知道该去哪里看状态
- 从集群内部，而不是从笔记本电脑，给应用施加真实的负载

## 而在 vSphere 里，这会是

在 vSphere 里你向上扩：给一台运行中的机器热添加 CPU 和内存。这由一个人按计划或按告警来做，仅此而已——vCenter 不会繁殖应用实例；要那样，你需要一个负载均衡器、一个机器模板，以及某人的手工活。DRS 解决的是另一个问题：它在主机之间搬动现有的机器，但不改变它们的数量。

在这里，副本的数量是负载的一个结果，用二十行文字描述出来。

**说句公道话，哪里是 vSphere 更方便。** 三件事，而且都很重要。

第一，热添加对任何应用都有效，包括一个写于 2009 年、严格以单个实例存在的应用。HPA 要求应用能够同时以若干副本运行：没有共享状态，不写本地文件，会话不绑定到某个实例。如果它做不到，自动扩缩容对你就是不可用的，而 Kubernetes 不会解决这个问题——它会把它暴露出来。真正的迁移边界恰恰划在这里，而不在清单里。

第二，指标。vCenter 把统计数据保存好几个月，「上周二发生了什么」这个问题用一张图就能回答。`metrics-server` 只保留最近几分钟，别的什么都没有——它的设计恰恰就是为了喂给 HPA。要历史数据，你就得去装 Prometheus，而那是一份单独的活儿（实验 14）。

第三，账单的可预测性。一台四核的机器要花多少钱，是事先就知道的。自动扩缩容意味着，在糟糕的一天里，你会得到比平常一天多六倍的消耗。`maxReplicas` 不是一个精细的性能调节旋钮，它是你在钱上的保险丝，应当据此对待它。
