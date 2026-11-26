# 实验 4 · 滚动发布新版本与回滚

| | |
|---|---|
| **时长** | 30 分钟 |
| **验证什么** | 在实时流量下切换和回退版本，无需维护窗口 |
| **需要准备** | 实验 0 的集群、实验 1 的 `rickroll`、实验 3 的 Fortio、三个终端窗口、一个浏览器 |

## 为什么这很重要

「Pass」服务你只会发布一次，但会更新几十次。在常见的做法里，每次更新都意味着安排一个窗口、一个周六的夜晚、开始前先做一份快照，还得有个人守在那里盯着。当变更的代价这么高时，变更就会越攒越多：本该做十次小的滚动发布，最后变成做一次大的，而大的更容易出问题。

我们就在小白鼠身上把代价摸清楚——也就是拿练手的 `rickroll`，而不是「Pass」。我们会**在负载正盛时**切换应用的版本——不是趁着空闲时段，而是在每分钟数千个请求之中——然后盯着错误计数器。之后再回滚，同样是在负载之下。

## 小词汇表

| 术语 | 是什么 | 类似……但 |
|---|---|---|
| **RollingUpdate** | 逐个替换副本，而不是一次全换 | **手动一台台更新虚拟机**，但集群自己来做，并且在新副本起不来时停下 |
| **Revision** | 保存下来的应用描述快照 | **虚拟机快照**，但它只保留描述——里面没有任何数据 |
| **maxSurge** | 滚动发布期间，允许在请求数量之外多起多少个副本 | 没有直接对应；按 `replicas` 的百分比计算并向上取整 |
| **maxUnavailable** | 允许关闭多少个副本而不等待替换 | **一次性关掉几台虚拟机**，但向下取整，所以三个副本时结果为零 |
| **readinessProbe** | 一个「可以接收流量了」的检查 | **负载均衡池里的健康检查**，但它还会拖住滚动发布，而不只是把某个成员从均衡中摘掉 |
| **ReplicaSet** | 一组相同的副本，负责描述的某一个版本 | **由模板生成的一池相同虚拟机**，但每个版本各自有一套，上一套则在旁边留着，副本数为零 |
| **EndpointSlice** | 已准备好接收流量的副本地址清单 | **负载均衡池成员清单**，但由集群按标签维护，而不是管理员手工维护 |
| **JSON Patch** | 按对象内部的路径精确修改单个字段 | 没有直接对应；路径指向列表中元素的**序号**，而不是它的名字 |

## 实验文件夹里有什么

所有文件都已经在你手上——它们是和仓库一起拿到的。没有什么要创建或重新敲：下文凡是写着 `kubectl apply -f name.yaml` 的地方，文件都取自这里。

```bash
# From here on, all commands are run from this folder: paths in `kubectl apply -f` are counted from it.
cd labs/04-rollout
```

| 文件 | 是什么 | 什么时候用得上 |
|---|---|---|
| `rickroll-page-v2.yaml` | 页面的第二个版本——我们要在负载下发布的东西 | 你在自己的实验集群 `lab` 上应用它 |
| `check.sh` | 检查滚动发布过程没有丢失任何请求 | 你在实验末尾运行它 |
| — | 负载生成器从隔壁实验拿：`../03-scale/fortio.yaml` | |

## 步骤 1. 准备场地

📍 **在哪做：** 在笔记本电脑上。

滚动发布之前需要做两件事，两件都不是走过场。

**关掉自动扩缩容**，因为它也会管 `replicas` 字段。一边看着滚动发布，一边又有别的东西在同时改副本数量，这是保证你搞不清发生了什么的可靠办法。一个字段只由一个机制管。

**做三个副本**，好让替换能一个一个看清楚。这里的一个副本就是一个 Pod：集群里最小的运行单元，是应用容器连同它的运行环境，是最接近单台虚拟机的东西。只有一个副本时滚动发布也能无停机完成，但你只会看到「原来有一个 Pod，现在换成另一个」，而看不到集群替换它们的先后顺序。

```bash
# KUBECONFIG — the file with the cluster's address and the credentials to log into it. While the
# variable is set, every kubectl command goes to the `lab` cluster, not the one it was issued from.
export KUBECONFIG=~/lab.kubeconfig

# hpa — the autoscaler set up in the scaling lab. We delete it
# so the number of copies changes only on our command.
#   --ignore-not-found  don't treat it as an error if it's no longer in the cluster
kubectl delete hpa rickroll --ignore-not-found

# scale = "keep this many copies". The number goes into the application's description,
# and the cluster then brings up the missing ones itself.
kubectl scale deployment rickroll --replicas=3

# rollout status = "wait until the requested becomes actual". The command keeps the window
# busy until all three copies are ready, and only then returns the prompt.
kubectl rollout status deployment/rickroll
```

确认 Fortio 负载生成器还在：

```bash
# get = "show what's there". The reply `Error from server (NotFound)` means it isn't there.
kubectl get deployment fortio
```

如果它不在，就从隔壁文件夹把它起起来：`kubectl apply -f ../03-scale/fortio.yaml`。

## 步骤 2. 把第二个版本放进集群

📍 **在哪做：** 在笔记本电脑上。

文件夹里放着 `rickroll-page-v2.yaml`——一个 ConfigMap 类型对象的描述。ConfigMap 把一个文本文件与应用分开地存在集群里，之后集群再把这个文件放进容器内部。这里它装的是 nginx 对外提供的那个页面。

<details>
<summary><b>细看：rickroll-page-v2.yaml 里面是什么</b></summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rickroll-page-v2
data:
  index.html: |
    ...
    <div class="tag">VERSION 2</div>
    <h1>We're No Strangers To Love</h1>
    ...
    <div class="pod">served by pod<b>__POD__</b></div>
```

里面就一个页面：不同的标题、不同的配色、一枚醒目的「版本 2」标记。差异是故意做得扎眼的——你会盯着浏览器看，而不是盯着 diff。

注意两点。

**`__POD__` 还在原处。** 替换成副本名字这件事，是由两个版本共用的 `rickroll-conf` ConfigMap 里的 nginx 设置来做的。我们改的是页面，而不是服务器的行为。

**对象的名字是 `rickroll-page-v2`，而不是 `rickroll-page`。** 这是整个实验的关键决定，值得把为什么讲清楚。

看上去顺手的其实是另一种做法：拿现成的 `rickroll-page-v1`，把它的内容重写一遍。一条命令，不产生任何新对象。别这么做，原因如下。

第一，你会丢掉旧的那份。回滚就没了：先前那个页面除了在你的文件里，别处再也不存在——而如果那次修改是通过 `kubectl edit` 做的，那连文件里都没有。

第二，更新会变得不可控。改 ConfigMap 时应用的描述并不改变，也就是说 Deployment——那个保存这份描述（用哪个镜像、多少个副本、从哪里取文件）并保证它被执行的对象——什么都不会察觉，也不会启动任何滚动发布。可集群还是会把运行中 Pod 里面的文件换掉——自作主张，在它自己挑的时刻，历时约一分钟，而且各副本之间顺序随意。你得到的会是一次历史里没有、无法用命令回滚、并且以参差不齐的节奏才到达各副本的变更。

所以就有了这条规则：**版本是不同的对象，而切换版本是对应用描述的一次变更。** Deployment 正是这样看待它的，它也正是这样进入修订历史、并因此能够被撤销。

</details>

应用它。集群里会出现第二个 ConfigMap；它不会碰到运行中的应用，因为暂时还没有任何东西引用它：

```bash
# apply = "bring the cluster to what's described in the file".
#   -f name.yaml   where to take the description from; the file is in this same folder
kubectl apply -f rickroll-page-v2.yaml
```

**你应当看到：** `configmap/rickroll-page-v2 created`。

现在打开应用，确认**什么都没有变**：

```bash
# port-forward = a temporary tunnel from the laptop into the cluster.
#   svc/rickroll  where it leads: into the Service, that is, with requests spread across the copies
#   8080:80       on the left the port on the laptop, on the right the service's port inside the cluster
# While the tunnel is open the window is busy; it closes on Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> ——还是那第一个版本。我们把新页面放进了集群，但应用并不知道它：它的卷仍然指向 `rickroll-page-v1`。关闭隧道（`Ctrl+C`），这还不是滚动发布。

## 步骤 3. 搞清集群将如何替换副本

📍 **在哪做：** 在笔记本电脑上。

在切换版本之前，先看看替换将遵循的规则。它们就在应用的描述本身里：

```bash
# -o jsonpath=... — instead of a table, print a single field of the object by giving the path to it.
#   {.spec.strategy}  the block of rules by which the cluster replaces copies
#   {"\n"}            a newline at the end, otherwise the output runs into the prompt
kubectl get deployment rickroll -o jsonpath='{.spec.strategy}{"\n"}'
```

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

这一段并不在 `rickroll.yaml` 里——是集群填上了默认值。

<details>
<summary><b>在我们这三个副本上，这些百分比意味着什么</b></summary>

两个数字都从 `replicas`、也就是从三来算。而且它们朝相反的方向取整。

**`maxSurge: 25%`** ——替换进行期间，允许在请求数量**之外**多起多少个副本。三的 25% 是 0.75，**向上**取整得 1。所以滚动发布期间集群里可以临时有四个副本。

**`maxUnavailable: 25%`** ——允许同时保持多少个副本**不可用**。三的 25% 同样是 0.75，但**向下**取整得 **0**。

零是一条硬约束。在就绪的替换副本出现之前，集群不许关闭任何一个正在工作的副本。不是「会尽量」，而是不许：这是约束，不是意愿。

于是每一步替换的动作顺序就是这样：

1. 起一个新副本（`maxSurge` 允许）；
2. 等它的 `readinessProbe` 回以成功；
3. 把它加进 EndpointSlice，也就是让流量打到它上面；
4. **到这时才**把一个旧副本从均衡中摘掉并关闭；
5. 重复，直到没有旧副本为止。

一切都系于第三、第四两点，而它们又系于 `readinessProbe`。把就绪检查从清单里去掉，集群就会在进程一启动的那一刻起把副本当成可用的。流量会打到一个还没读完自己配置的 nginx 上，你就会收到一批 500。这里的就绪检查不是监控，而是**滚动发布的刹车**，这才是它的主要职责。

一个有用的推论：如果新版本坏得连就绪检查都过不了，滚动发布就会**停下**。旧副本继续工作。我们在实验快结束时会看到这一点，只不过会用另一种方式把它弄坏。

</details>

## 步骤 4. 加上负载

在一片安静中做滚动发布没意思——vSphere 里也是这么干的。我们放流量进来，在它之下切换版本。

📍 **窗口 1** ——到 Fortio 的隧道：

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
# A tunnel to the load generator: port 8081 on the laptop → port 8080 of the fortio service.
# 8081 was chosen on the left so as not to collide with the tunnel to the application itself on 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **在浏览器里** —— <http://localhost:8081/fortio/>。填写：

| 字段 | 值 | 为什么这样 |
|---|---|---|
| URL | `http://rickroll/` | Service 的名字——所有副本都站在其后的那个稳定地址；流量会经过均衡，而不是打到某个具体的 Pod |
| QPS | `300` | 一个平稳的背景；现在没必要榨出最大值 |
| Duration | `180s` | 三分钟——我们在这个窗口内既来得及发布，也来得及回滚 |
| Connections | `20` | |

按 **Start**，然后**在实验结束前都别碰浏览器**。

如果表单没弄成，同样的负载也可以用命令给出：

```bash
# exec = run a command inside an already-running Pod. The load is generated not by your laptop,
# but by Fortio itself from inside the cluster, so no tunnel is needed for this.
#   deploy/fortio  in any copy of the fortio application
#   --             everything to the right is a command for the container, not for kubectl
#   -qps 300       three hundred requests per second
#   -c 20          twenty simultaneous connections
#   -t 180s        hold the load for three minutes
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **窗口 2** ——盯着副本：

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — show only Pods with this label; others won't get into the output.
# -w = "watch and append": the window stays busy and prints a new line every time
# the state of some copy changes. Exit — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## 步骤 5. 切换版本

📍 **窗口 3** ——一个空闲窗口。第一个握着到 Fortio 的隧道，第二个忙着盯 Pod，所以我们在第三个里执行 patch。在它里面得再设一次访问：

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
```

现在我们要在应用的描述里改动恰好一个字段：名为 `page` 的卷——那个被放进容器内部的文件夹——必须从 ConfigMap `rickroll-page-v2` 取它的内容。没有「更新应用」这条命令，将来也不会有：只有一条关于应该是什么样子的新记录。集群会自己发现它与实际状态之间的差异，并开始替换副本。

```bash
# patch = change a field in an object pinpoint-style, without rewriting the whole object.
#   --type=json  the edit format: "operation + path + value"
#   op: replace  replace what sits at this path
#   path         the address of the field inside the object; volumes/0 — the first volume in the list (see below)
#   value        the new ConfigMap name from which the volume will take the page
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v2"}]'
```

**你应当看到：**

```
deployment.apps/rickroll patched
```

⚠️ **这个 patch 很脆弱，这一点必须直说。** 路径 `/spec/template/spec/volumes/0/...` 是**按卷在列表里的序号**来寻址的。在 `rickroll.yaml` 里 `page` 卷排第一、`conf` 排第二——那里甚至有一条关于这一点的注释。但只要有人把它们对调（而 YAML 对此毫无禁止），完全相同的这条命令就会一声不响地把 nginx 配置的名字覆盖掉，应用就会以一种莫名其妙的方式坏掉。

<details>
<summary><b>那为什么我们还是这么做，以及正确做法是什么</b></summary>

我们采用 JSON Patch，是因为它把机制以最纯粹的形式展示出来：一条命令、一个字段、一个看得见的后果。对一个实验来说这很有价值。

**更安全**——用普通的合并 patch 做同样的事。Kubernetes 里的列表可以按某个键来合并，而 `volumes` 的这个键是 `name`：

```bash
# Without --type=json this is a merge patch: you describe a piece of the object in the same form
# it has in the manifest, and the cluster merges it with what's already there. The volumes list merges
# by the `name` key, so here the `page` volume is addressed, not "the volume at such-and-such index".
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

这里寻址是按卷的名字来的，列表里的顺序无关紧要，也就没什么可弄混的。

**正确做法**——根本不用 patch。patch 和 `kubectl edit` 一样，改的是集群里的对象，却不改你的文件。一周后有人从仓库应用了 `rickroll.yaml`，应用就一声不响地退回到第一个版本。没人会明白这是为什么。

在正常工作里，版本是这样切换的：你在文件里改一行，把变更送去评审，合并之后由自动化来应用。这样一来，集群的状态和仓库的内容就总是一致的。我们在实验 5 里正是要做这件事。

</details>

看着替换进行：

```bash
# rollout status prints the progress of the replacement line by line and finishes when all copies are updated.
# If the rollout doesn't converge, the command returns a non-zero exit code — convenient for
# stopping it in scripts.
kubectl rollout status deployment/rickroll
```

```
Waiting for deployment "rickroll" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "rickroll" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "rickroll" successfully rolled out
```

📍 **在窗口 2 里**你这时可以看到副本被逐个替换：先冒出一个新的并到达 `1/1 Running`，然后旧的里才有一个进入 `Terminating`。

留意名字的尾巴：新副本连中间那一段也变了——那是另一个 ReplicaSet。Deployment 没有去改造旧的那个，而是在旁边建了第二个，把副本从一个往另一个里倒。旧的哪儿也没去，它有零个副本，正在一旁候着：

```bash
# rs — shorthand for ReplicaSet, a set of copies of one version of the description.
# DESIRED — how many copies are requested in this set, READY — how many of them are ready to answer.
kubectl get rs -l app=rickroll
```

```
NAME                  DESIRED   CURRENT   READY   AGE
rickroll-6f4b9c8d57   0         0         0       48m
rickroll-7c5d4f9b21   3         3         3       40s
```

## 步骤 6. 数错误

📍 **在哪做：** 在笔记本电脑上，在窗口 3 里——它在上一条命令之后空出来了。

打开一条到应用的隧道：

```bash
# The same tunnel as at the start of the lab: port 8080 on the laptop → port 80 of the rickroll service.
kubectl port-forward svc/rickroll 8080:80
```

📍 **在浏览器里** <http://localhost:8080> ——带「版本 2」标记的绿色页面。刷新几次：底部的副本名字会变，因为 Service 把请求分摊到三个副本上。

关闭隧道（`Ctrl+C`）。

📍 **现在是重点——Fortio 那个标签页。** 等运行结束，找到带响应码的那几行：

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**零错误。** 应用在持续流量下把版本整个换掉了，五万四千个请求里没有一个受到损伤。

我们为此付出的代价，是清单里的一个块——就是实验 1 里的那个 `readinessProbe`。没有它，集群就会在还没确认新副本已准备好应答之前，就把旧副本从均衡中摘掉，那这一行看起来就会不一样。

⚠️ **几万个请求里出现几十个错误、而不是零**，这不是测试环境坏了。把副本从均衡中移除和停掉它内部的进程是并行发生的，在快速流量下会有一小撮连接来得及落进那道缝里。这个可以靠关闭前的一段暂停（`preStop`）以及应用自身对连接的优雅收尾来治好。我们在实验里故意不做这件事：知道这道缝存在，比假设它会自己合上更有用。

## 步骤 7. 回滚

在 Fortio 里再启动一次负载（同样的参数），趁它运行的时候看看变更历史：

```bash
# history = the list of saved revisions of the description. Each line is a state you can
# return to with a single command. CHANGE-CAUSE — an optional note on why it was changed.
kubectl rollout history deployment/rickroll
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

两个修订。每一个都是变更那一刻应用描述的已保存快照。第一个带着 `rickroll-page-v1`，第二个带着 `v2`。它们能留下来，正是因为旧的 ReplicaSet 没被删掉：集群默认保留最近的十个。

回滚：

```bash
# undo with no extra parameters = return to the previous revision. This isn't "rewinding
# time", it's an ordinary rollout of the old description: copies are replaced one at a time, by the same
# maxSurge and maxUnavailable rules.
kubectl rollout undo deployment/rickroll
# We wait until the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

📍 **在窗口 2 里**——同样的过程反着来：三个新副本逐个起来，三个当前的离场。`kubectl get rs -l app=rickroll` 会显示副本回到了第一个 ReplicaSet——就是那个原本挂着零的。

📍 **在浏览器里**应用又是第一个版本了。

📍 **在 Fortio 里**——又是 `Code 200 ... (100.0 %)`。

**把这和 vSphere 里的回滚比一比。** 那里回滚意味着从快照恢复：机器关机、文件被放回、机器启动。数分钟的不可用，外加丢掉快照拍下之后发生的一切。这里回滚意味着把描述退回到上一个修订，它和一次普通的滚动发布毫无区别：同样是副本逐个来、同样的零停机。

⚠️ **`CHANGE-CAUSE` 是空的，这很不方便。** 历史保留了*什么*变了，却没保留*为什么*。一个月后修订 2 什么也不会告诉你。原因可以用 `kubernetes.io/change-cause` 注解来填上，但这个问题真正的答案不是注解，而是 Git——那里每一次变更都有作者、日期和提交信息。

## 步骤 8. 一次过不去的检查

机制清楚了。现在来看看滚动发布出岔子时会发生什么——而这比谁都希望的要常见。

设想一个平常的早晨：一位同事在准备页面的第三个版本，赶时间，把名字打错了。可清单本身是有效的——集群没有义务知道那个对象并不存在。我们来精确复现这一幕：

```bash
# The same patch as when switching to the second version, but with a mistake in the ConfigMap name:
# there is no object `rickroll-page-v3` in the cluster. The reference's existence isn't checked on acceptance,
# so the command will finish successfully.
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v3"}]'

# --timeout=90s — don't wait forever: not having gotten ready copies, the command gives up after a
# minute and a half and returns an error. The rollout itself won't go anywhere and will stay hanging.
kubectl rollout status deployment/rickroll --timeout=90s
```

**你会看到：**

```
Waiting for deployment "rickroll" rollout to finish: 0 of 3 updated replicas are available...
error: timed out waiting for the condition
```

看看副本的构成：三个先前的在工作，新的那个卡在启动上。

```bash
# The READY column counts the ready containers inside the Pod: 1/1 — ready, 0/1 — not.
# STATUS says exactly where the startup stalled.
kubectl get pods -l app=rickroll
```

```
NAME                        READY   STATUS              RESTARTS   AGE
rickroll-6f4b9c8d57-4kk2p   1/1     Running             0          6m
rickroll-6f4b9c8d57-9dnvt   1/1     Running             0          6m
rickroll-6f4b9c8d57-lm7bq   1/1     Running             0          6m
rickroll-8b6a1e5c39-wr4tz   0/1     ContainerCreating   0          90s
```

> **在往下读之前，停下来想一想。**
>
> 这里有两个问题，而第二个比第一个更重要。第一：新副本为什么起不来？第二：服务此刻怎么样了——它挂了吗？

<details>
<summary><b>答案，以及一个比这个错误更宽泛的教训</b></summary>

**副本为什么没起来。** 我们从来没创建过名为 `rickroll-page-v3` 的 ConfigMap——它不在集群里。直接问集群：

```bash
# events — the cluster's log of occurrences, the nearest analogue of the Tasks & Events tab in vCenter.
#   --field-selector reason=FailedMount  keep only the records about a failed volume mount
#   --sort-by=.lastTimestamp             sort by time, the freshest end up at the bottom
#   | tail -3                            show the last three lines, discard the rest
kubectl get events --field-selector reason=FailedMount --sort-by=.lastTimestamp | tail -3
```

```
Warning  FailedMount  kubelet  MountVolume.SetUp failed for volume "page":
         configmap "rickroll-page-v3" not found
```

注意：`kubectl patch` 命令成功完成并打印了 `patched`。集群接受了一份引用通向虚无的描述，一个字也没说。清单被接收时并没有对 ConfigMap 是否存在的检查——那种检查只可能在 Pod 启动的那一刻做，而这正是发生的事情。

**现在来看第二个问题，也是这一步专为它而设的问题。** 就在卡住的滚动发布正中打开应用：

```bash
# The same tunnel. Traffic will go only to the copies that passed the readiness check,
# that is, to the three old ones: the stuck one didn't make it into balancing.
kubectl port-forward svc/rickroll 8080:80
```

它照常工作。第一个版本，三个副本，没有错误。如果你此刻在 Fortio 里跑着负载——报告里依然是百分之百的 200。

**一次彻底坏掉的滚动发布并没有把服务弄垮。** 这是 `maxUnavailable: 0` 的直接后果，我们在实验开头就算过它：在拿到就绪的替换之前，集群不许关闭任何一个正在工作的副本。它没拿到替换——所以它也没关闭任何东西。滚动发布恰好停在它开始出问题的地方，并停在了这个状态。

**这个教训比这个错误更宽泛。**

> Kubernetes 里失败的滚动发布默认会**卡住**，而不是崩塌。

这把人们熟悉的更新逻辑整个翻了过来。在「停机、更新、启动」的做法里，中途的任何错误都意味着停机，正因如此更新才要在夜里、有人守着电话去做。在「起新的、确认、切过去」的做法里，一个错误意味着切换没有发生——而旧的东西照旧运转，和原来一样。

于是给值班者的一个实用结论：**卡住的滚动发布不是事故。** 它不会在半夜把你叫醒。它可以早上再处理——或者用一条命令回滚，之后再处理。

我们现在正要做这件事。

</details>

脱身：

```bash
# We return the previous revision — the one where the ConfigMap name is written correctly.
kubectl rollout undo deployment/rickroll
# We wait until the stuck copy disappears and the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

卡住的副本消失，描述回到能工作的那份。

## 校验

📍 **在哪做：** 在笔记本电脑上，就在你刚才操作 `kubectl` 的那个终端窗口里。

```bash
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **在 Windows 上脚本要从 WSL 运行**，而不是从 PowerShell——怎么装它写在实验 0 的开头。没有 WSL 也能完成本实验，只是不会有作为产物的报告。

脚本看的是事情的实质，而不是你敲过的命令：应用的历史里有好几个修订（说明版本确实被改过又退回过）、集群里躺着第二个版本的 ConfigMap、应用在通过 HTTP 应答，而且它给出的页面和描述所指向的那个 ConfigMap 相符。它另外还检查 `readinessProbe`——没有它，那个零停机是复现不出来的。

## 收尾

`rickroll` 应用后面还会用到——我们不删它。把它退回一个副本：

```bash
# Two extra copies will free up the node's memory — there won't be any load in the labs ahead.
kubectl scale deployment rickroll --replicas=1
```

负载生成器不再需要了：

```bash
# delete -f = delete exactly the objects listed in the file, and nothing besides them.
# The path leads to the neighboring folder, because the file is where the scaling lab is.
kubectl delete -f ../03-scale/fortio.yaml
```

`rickroll-page-v2` 这个 ConfigMap 可以原样留着：它占几 KB，既不吃 CPU 也不吃内存。Kubernetes 里的描述存在 control plane 的数据库里，在没人引用它时不花任何成本——这不同于虚拟机快照，快照要占存储上的空间，而且活得越久，把机器拖得越慢。

## 我们现在会做什么

- 在实时流量下切换应用版本，并靠计数器确认没有出错
- 讲清零停机是从哪里来的：`maxUnavailable`、`readinessProbe`，以及「先就绪、再切换」的顺序
- 读修订历史，用一条命令回滚
- 理解为什么版本要做成独立的对象，而不是去改现有的那个
- 知道坏掉的滚动发布会卡住、而不是把服务弄垮，以及为什么这不是事故

## 而在 vSphere 里这会是

一个事先商定好的维护窗口。开始前一份快照——占用数分钟和存储空间。就地更新。要是没成——从快照恢复，又是数分钟的不可用。这一切都在夜里，因为白天不能做。

这里——白天一条命令，在流量之下，再加一条命令，如果你不喜欢结果的话。

**vSphere 更方便的地方，说句公道话。** 有三点。

第一，也是最重要的：**快照拿走的是整个状态，而 `rollout undo` 拿走的只是描述。** 如果在新版本工作期间，你的应用往数据库里写了点什么、或改了表结构，回滚会退回代码，却退不回数据。你会得到新数据之上的旧版本——有时这比什么都不动更糟。虚拟机快照能救你于此，`rollout undo` 不能。正因如此，数据库表结构迁移才要写成双向兼容的，而这是一种 Kubernetes 会向你索取、vSphere 却不曾索取的纪律。

第二，vSphere 里的回滚会把绝对的一切都退回来：手工装上的软件包、通过电话交代着改的一处配置。这里只有清单里描述过的东西才会被回滚。任何人绕开去做的一切都不会被回滚，因为集群根本不知道它。

第三，快照不要求应用能同时以两个版本运行。而 `RollingUpdate` 要求：滚动发布期间，旧副本和新副本在同一个地址后面一起服务请求。如果它们彼此不兼容——在会话格式上、在数据结构上、在协议上——那就不会有零停机，只会有一团糟。对那些还没为此做好准备的应用，有 `Recreate` 策略：全部关掉，再全部起来。它会带来停机，但可预测，有时选它反而更诚实。
