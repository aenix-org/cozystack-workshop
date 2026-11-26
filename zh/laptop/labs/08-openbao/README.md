# 实验 8 · 机密不在清单里

| | |
|---|---|
| **时长** | 50 分钟，其中一部分时间用于等待存储启动并对其解封 |
| **它证明了什么** | 密码可以彻底从 Git 中移除，并且无需改动任何一个文件就能更改 |
| **你需要准备** | 实验 0 中的集群和 `~/lab.kubeconfig`；访问你所在租户控制台的权限；形如 `workshopXX` 的租户编号 |

> ⚠️ **`workshopXX` 是占位符，不是名字。** 请替换成你自己的租户编号，否则
> 命令会发到别人的租户，你会收到访问被拒绝的错误——或者更糟，拿到别人的
> 数据。你的编号是和密码一起发给你的。

> ⚠️ **这是一个内容密集的实验：十一个步骤，加上一套陌生的访问模型。**
> 请把它安排成一整段连续的时间，中途不要休息。

## 为什么这很重要

「通行证」服务运转正常：员工为访客申请通行证，保安看到名单。
安全团队来做例行审计，随手带来了你仓库里的一行内容：

```yaml
- name: DB_PASSWORD
  value: "Propusk2019!"
```

通行证数据库的密码就放在一个清单里。清单放在 Git 里。这个 Git 有跨三个团队的
十二个人能看到，另有四个人已经离开公司，还有一份完整的仓库副本存在某个承包商的
笔记本电脑上——他去年做过一次集成。

审计员的问题听起来很平常：**「改掉这个密码，再给我看看过去一个月里谁读过它。」**
无从回答。改密码意味着找出它被硬编码的每一个地方；谁读过它则无从得知，因为从 Git
读取一个文件的动作没有任何地方记录。

在这个实验里，我们会把密码搬进 OpenBao，教会应用从那里获取密码，用一条命令更改
密码，再看看系统对此都知道些什么。

一路上我们会理清一个几乎所有人都会栽跟头的问题：**Kubernetes 里的 Secret 和真正的
机密存储有什么区别。**

本实验中的每个术语在第一次出现时都会讲清楚，下一节则是已经引入术语的词汇表。

## 词汇表

| 术语 | 是什么 | 类似于……但 |
|---|---|---|
| **Secret（Kubernetes）** | 一个集群对象，里面的数据以 base64 写成 | **虚拟机磁盘上的一个密码文件**，但它看着受保护，其实不然——下面我们会把这点拆开来看 |
| **base64** | 一种把任意字节写成可打印字符的方法 | **uuencode、MIME 附件**，但它不是加密。没有密钥，任何人都能把它逆转回去 |
| **机密存储** | 一个独立的服务：把机密加密保存，并按规则发放 | **没有直接的类比**，但它不是「装满密码的网络文件夹」——它是一个带有策略、有效期和日志的服务 |
| **OpenBao** | 这样一种存储。它是 HashiCorp Vault 的一个分支，以 MPL 许可证发布 | 命令和 API 都与 Vault 一致；只是工具名叫 `bao` |
| **Root 令牌** | 一个对一切拥有完全访问权限的账户 | **root**，但你只在初始设置时用它一次，之后就签发权限更窄的令牌 |

本实验其余的词汇——`sealed`、解封密钥、策略、令牌、KV v2、轮换、审计日志、
init 容器——都会随着进度逐一引入，出现在各自第一次用到的步骤里。现在不需要死记：
脱离了具体动作，它们反正也记不住。

<details>
<summary><b>如果你想一开始就看到完整列表</b></summary>

| 术语 | 是什么 | 类似于……但 |
|---|---|---|
| **密封（sealed）** | 服务在运行，但主密钥不在内存里：数据以加密形式存放，API 拒绝一切请求 | **「服务起来了，但卷没有挂载」**，但每次重启后你都得再手动解封一次 |
| **解封密钥** | 主密钥的一份份额，用它来给存储解封 | **保险箱的钥匙**，但份额有好几份，默认情况下你必须出示不止一份 |
| **策略（policy）** | 一份路径清单以及在这些路径上允许做什么 | **文件夹上的 ACL**，但这里的路径是 API 里的一个地址，而不是磁盘上的一个文件 |
| **令牌（token）** | 通往存储的临时通行证 | **一个会话**，但令牌有生命周期，会自行过期，也可以被吊销 |
| **KV v2** | 一个带版本历史的「键值」引擎 | **一个带修改历史的文件夹**，但它保留每一个版本以及每次写入的时间戳；旧值永不消失 |
| **轮换（rotation）** | 按计划把一条机密替换成新的 | **按规程更换密码**，但这里只是一条命令，应用会在下一次启动时把它取走 |
| **审计日志** | 一份「谁在什么时候请求了什么」的记录 | **文件共享的访问日志**，但每一个 API 请求都会写下一行，包括失败的请求和被拒的请求 |
| **零号机密** | 应用用来证明自己有权访问其余所有机密的那一个机密 | 它无法被彻底去掉。但可以让它短命、权限窄、只用一次 |
| **Init 容器** | 在主容器启动之前先运行并结束的容器 | **服务启动前运行的自启脚本**，但如果它失败了，主容器根本不会启动——而这正是你想要的 |

</details>

## 实验文件夹里有什么

所有文件你已经有了——它们是随仓库一起拿到的。不需要创建或重新敲入任何东西：
下文凡是写到 `kubectl apply -f 名称.yaml` 的地方，文件都取自这里。

```bash
cd labs/08-openbao
```

| 文件 | 是什么 | 什么时候用到 |
|---|---|---|
| `openbao.yaml` | 一份机密存储的订单——和控制台里的那个按钮是一回事 | 你把它应用**到租户里**，而不是 `lab` 集群里 |
| `secrets-demo-naive.yaml` | 服务现在的样子：密码就在文件里。这正是审计发现的东西 | 你把它应用在你自己的 `lab` 集群上 |
| `secrets-demo-secret.yaml` | 「幼稚的修法」：把密码搬进一个 Secret——以及为什么这还不够 | 你把它应用到同一个地方 |
| `secrets-demo.yaml` | 最终版本：密码哪里都没有——既不是明文，也不是 base64 | 你把它应用到同一个地方 |
| `check.sh` | 一个检查脚本，验证应用是从存储里拿到密码的 | 你在实验结束时运行它 |

## 第 1 步。亲眼看看这个问题

📍 **位置：** 在笔记本电脑上，在实验集群中。

我们在自己的地盘上复现审计的发现：在实验集群里起一个小小的 `secrets-demo`
服务，密码直接从它的描述里递给它。先把文件过一遍，再应用它。

<details>
<summary><b>细看：secrets-demo-naive.yaml 里面有什么</b></summary>

这是一个普通的 `Deployment`——对一个应用的描述：取用哪个镜像、保持运行多少个副本。
**镜像**是一份现成的文件系统快照，里面装着一个程序；vSphere 里最接近的类比是虚拟机
模板，只是没有操作系统。**容器**是镜像的一个运行中的实例。**Pod** 是 Kubernetes 里
最小的执行单元：一个或多个总是同生共死的容器。
Deployment 会确保运行中的 Pod 数量与订购的数量一致。

```yaml
      containers:
        - name: app
          image: busybox:1.36
```

我们不会去动你在「搭建自己的镜像仓库」那节实验里用 Go 写的真正的「通行证」应用：
它好好的，没理由为了一次练习去弄坏它。所以我们在它旁边另起一个小小的 `secrets-demo`
服务——我们关心的不是应用本身，而是密码抵达它的那条路径。正因如此，这里放的是一个
极小的容器，只做一件有意义的事——每十秒往日志里写一次它正在使用哪个密码。

```yaml
          env:
            - name: DB_PASSWORD
              value: "Propusk2019!"
```

这一行正是我们要谈的重点。环境变量是给应用传递配置最普通的方式：清单里的 `env` 会
变成容器内部的一个变量。这套机制很好；糟糕的是**值直接写在文件里**。

```yaml
                  "$(printf %s "$DB_PASSWORD" | sha256sum | cut -c1-12)"
```

应用打印的不是密码，而是它的**指纹**——sha256 的前十二个字符。指纹能显示密码变了，
但从它无法还原出密码本身。日志本就该这么写；我们会在本实验剩下的部分一直这么用。

`resources.requests` 是作为保证要预留多少资源（相当于 vSphere 里的资源预留（reservation）），
`resources.limits` 是不允许超过的上限（相当于 limit）。这些值故意设得极小：应用什么
都不做。

</details>

**应用它。**

```bash
# KUBECONFIG tells kubectl which cluster to talk to. Here it's the lab cluster
# from Lab 0; the tenant will be needed later, at the step where we order the store.
export KUBECONFIG=~/lab.kubeconfig
cd labs/08-openbao
# apply = "bring the cluster to what's described in the file". -f = take the description from the file.
# No object with this name exists yet, so it will be created.
kubectl apply -f secrets-demo-naive.yaml
```

**你应该看到** —— 一行以 `created` 一词结尾的输出。

看看我们得到了什么：

```bash
# logs = show what the application printed to its output. There's no separate log file.
#   deploy/secrets-demo  take the output from the Pod brought up by this description
#   --tail=2             only the last two lines, not everything since startup
kubectl logs deploy/secrets-demo --tail=2
```

**你应该看到** —— 大致如下：

```
08:14:31 connecting to passes-db.internal as passes_app, password fingerprint sha256:a609df223d57
```

应用运转正常。密码在一个文件里，文件在 Git 里。这正是审计所发现的情形。

## 第 2 步。幼稚的修法：把密码搬进 Secret

📍 **位置：** 在笔记本电脑上，在实验集群中。

任何一次网络搜索首先建议的都是：「Kubernetes 有个 Secret 专门干这个。」我们照建议
做——并先看看文件里有什么变化。

<details>
<summary><b>清单里变了什么</b></summary>

出现了一个独立的对象：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: passes-db
type: Opaque
data:
  password: UHJvcHVzazIwMTkh
```

`Secret` 是一个用于敏感数据的集群对象。`data` 字段里的值以 base64 写成，所以文件里
`Propusk2019!` 的位置如今站着 `UHJvcHVzazIwMTkh`。

而在 Deployment 里，值的位置出现了一个引用：

```yaml
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: passes-db
                  key: password
```

`valueFrom` 取代 `value`，意思是：「值不要从这里取，而是从那边那个对象里取。」容器
启动时，Kubernetes 会把 `passes-db` secret 里 `password` 键的内容代入 `DB_PASSWORD`
变量。

这种做法本身是对的——引用一个 secret，而不是把值写进去。问题在于引用的另一端放着
什么。

</details>

**应用它。**

```bash
# The same apply. The file holds two objects — a Secret and the changed Deployment; the cluster will
# compare what's described against what it already has and bring the two into line.
kubectl apply -f secrets-demo-secret.yaml
```

确认应用依然工作：

```bash
# rollout status waits until the new version of the application has fully replaced the old one, and only
# then returns control. Without it you might read the logs of the old Pod.
kubectl rollout status deploy/secrets-demo
kubectl logs deploy/secrets-demo --tail=2
```

指纹是一样的——`sha256:a609df223d57`。应用通过另一条路径拿到了同一个密码。

**问题解决了？** 密码不再写在 Deployment 里了。文件里放着一串看不懂的字符。我们来
检查一下。

## 一次可以预料的失败 · 「Secret」不等于「已加密」

试着让自己相信现在一切都好。问一问集群，secret 里面装着什么：

```bash
# get … -o yaml = "show the object in full, exactly as the cluster stores it".
# Look at the data field — that's the secret's contents.
kubectl get secret passes-db -o yaml
```

你会看到同一串 `UHJvcHVzazIwMTkh`。它看着看不懂，因此显得安全。

现在来一条命令：

```bash
#   -o jsonpath='{.data.password}'  pull exactly one field out of the object, without the wrapper
#   | base64 -d                     pass it along and decode it: d = decode
#   ; echo                          print a trailing newline, otherwise the result runs into
#                                   the next terminal prompt
kubectl get secret passes-db -o jsonpath='{.data.password}' | base64 -d; echo
```

> **继续往下读之前，先停下来想一想。**
>
> 你刚才到底做了什么来拿到这个密码？你需要哪把钥匙？还有谁能运行这条命令？

<details>
<summary><b>答案，以及一个比这个错误更宽泛的教训</b></summary>

输出是 `Propusk2019!`。明文。

**base64 不是加密，而是编码。** 它被发明出来是为了在为文本而建的通道上搬运任意字节：
邮件附件、JSON 里的数据、配置文件里的二进制。它里面没有密钥，因为它里面也没有任何
保护。任何人都能把它逆转回去——任何人、任何浏览器、任何解码网站。

Kubernetes 在 Secret 里使用 base64 正是出于这个原因：你没法把任意字节（比如一份证书
或一把密钥）放进 YAML，但可以把它们放进 base64。对象名里的「Secret」一词意思是
「敏感的东西放这里」，而不是「东西在这里受保护」。

这在实践中意味着：

| 说法 | 是真的吗？ |
|---|---|
| Secret 在集群里是加密的 | 不。在集群的数据存储里，它以近乎明文的形式存放，除非管理员另外开启了静态加密 |
| Secret 可以提交到 Git | 不。那和把密码放进去是一回事 |
| 可以看到谁读过某个 Secret | 不。对该对象的一次普通读取没有任何地方记录 |
| 没有权限就读不了 Secret | 真的，而且这是唯一真正的保护。集群里的权限确实限制了访问 |
| Secret 会按计划自己更改 | 不。是你来改，手动地，一次性在每一个地方改 |

**一个比这个错误更宽泛的教训。** 也是最要紧的一点。哪怕上面这些全都解决了，审计员的
问题依旧在：**给我看看过去一个月里谁读过这个密码。** Kubernetes 对它根本无法回答——
不是因为它做得差，而是因为这不是它的职责。保管机密是一项独立的工作，为它准备的是
一个独立的服务。

顺便说一句，你在 Cozystack 租户里的角色**并不**允许你通过 `kubectl` 读取 secret——
试一下就会被拒绝。但实验 0 的实验集群完全是你的，在那里你是管理员。上面那条命令能
成功，恰恰就是因为这一点。

</details>

## 第 3 步。订购 OpenBao

📍 **位置：** 在浏览器里，在 Cozystack 控制台中，在你自己的租户里。

租户 → **创建应用** → `OpenBAO`。

| 字段 | 值 | 为什么 |
|---|---|---|
| Name | `secrets` | 短，而且稍后你得把它敲进地址里 |
| Replicas | **1** | 一个教学测试环境。到两个及以上，chart 会启用 Raft 复制，而那已经是另一种存储模式了 |
| Size | `2Gi` | 机密只占几千字节；这点空间是留给内部数据的 |
| Storage class | `replicated` | 数据会以三份副本放在不同的节点上 |
| Resources preset | `t1.small` | 1 个 CPU，512 MB |
| UI | 启用 | 集群内部的 Web 界面 |
| External | 禁用 | 我们不把它对外暴露 |

⚠️ **在一份副本和多份副本之间切换不是勾一下复选框的事。** 一份副本把数据存在文件里，
多份则存在 Raft 里。更改模式需要迁移数据，所以在生产环境里，这个决定是在安装之前
做出的，而不是之后。

### 同样的东西，用文本表示——并逐个字段过一遍

实验文件夹里有 `openbao.yaml`：

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: OpenBAO
metadata:
  name: secrets
  namespace: tenant-workshopXX
spec:
  replicas: 1
  size: 2Gi
  storageClass: replicated
  resourcesPreset: t1.small
  ui: true
  external: false
```

`apiVersion: apps.cozystack.io/v1alpha1` 就是 Cozystack 目录本身，只不过是从看起来
像 API 的那一侧去看它。当你按下按钮，控制台会组装出正是这样一个对象并把它发往集群。
按钮是文本之上的一层封装，而不是它的替代品。

`kind: OpenBAO` 是它在目录里的位置。注意大小写：是 `OpenBAO`，不是 `OpenBao`。集群
对大小写很挑剔。

`namespace: tenant-workshopXX` —— **托管服务住在管理集群上你自己的租户里，而不是
实验 0 的实验集群里。** 这是两个不同的集群，在本实验剩下的部分记住这一点很重要：
应用会在一个集群里，存储在另一个集群里。

`replicas`、`size`、`storageClass`、`resourcesPreset` —— 和你用鼠标填的是同样的东西。

`ui: true` —— 起一个 Web 界面。`external: false` —— 不给这个服务分配外部地址；反正从
集群内部它照样能访问到。

这个文件**不是应用到实验集群**，而是应用到租户：

```bash
# --kubeconfig names the access file explicitly and overrides the KUBECONFIG variable.
# So the order goes to the tenant on the management cluster, not to the lab cluster.
kubectl --kubeconfig ~/.kube/workshop apply -f openbao.yaml
```

租户的 kubeconfig 从控制台里取得：**Info → Secrets 标签页 →
`kubeconfig-tenant-workshopXX`**。把它保存到 `~/.kube/workshop`。

在本文剩下的部分我们几乎用不到这个文件：服务用鼠标订购，而与 OpenBao 本身打交道走
的是它自己的 API。

等到应用进入就绪状态。这需要一两分钟。

## 第 4 步。搭一个工作用的 Pod 并检查连通性

📍 **位置：** 在笔记本电脑上，在实验集群中。

这里我们需要停一下，弄清楚布局。

**OpenBao 住在管理集群上你自己的租户里。** 你在租户里的角色允许你订购和删除服务，
但不允许你在那里运行自己的 Pod，也不允许通过端口转发连接到服务。这不是缺陷，而是
一条边界：租户是放托管服务的地方，不是工作台。

**你的工作台是实验 0 的实验集群。** 在那里你是管理员。我们会从那里访问 OpenBao——
通过每个服务都有的内部地址：

```
openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
```

我们把这个名字拆成几部分：

| 部分 | 表示什么 |
|---|---|
| `openbao-` | 目录加在名字前面的前缀。你把应用命名为 `secrets`，对象就得到了形如 `openbao-secrets…` 的名字 |
| `secrets` | 你在控制台里给的名字 |
| `tenant-workshopXX` | 你的租户。替换成你自己的编号 |
| `svc.cozy.local` | 管理集群的内部名称区 |
| `8200` | OpenBao 的 API 端口 |

我们来起一个工作用的 Pod。里面会有 `bao` 工具——我们就用它来命令存储，而且你不必在
笔记本电脑上安装它。替换成你自己的租户编号：

```bash
# run creates a single Pod from the given image — a disposable little machine inside the cluster.
#   --image          where to take the contents from: the official OpenBao image with the bao utility
#   --restart=Never  don't bring it up again once the command inside finishes
#   --env            the Pod's environment variable: any command inside it will see it
#   --command --     everything after the two dashes is the command the Pod will run
# sleep 86400 = "do nothing for a day": we need the Pod only as a workspace.
kubectl run bao-workbench \
  --image=openbao/openbao:2.5.1 \
  --restart=Never \
  --env=BAO_ADDR=http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200 \
  --command -- sleep 86400
# wait holds the terminal until the condition is met.
#   --for=condition=Ready  the Pod has started and is ready to accept commands
#   --timeout=120s         give up after two minutes and return an error
kubectl wait --for=condition=Ready pod/bao-workbench --timeout=120s
```

`BAO_ADDR` 是 `bao` 工具从中读取存储地址的变量。在创建 Pod 时设置一次，它就省得我们
在每条命令里都写 `-address=…`。

这个 Pod 是一次性的工作台，没什么可惜的：实验结束时我们会用一条命令删掉它。

检查一下从实验集群能不能看到租户：

```bash
# exec = run a command inside an already-running Pod; the command itself comes after --.
# bao status asks the store about its state: whether it's sealed, whether it's initialized.
# Here it doubles as a connectivity check: a reply arrived at all — so the tenant is visible.
kubectl exec bao-workbench -- bao status
```

**你应该看到** —— 一张状态表。这里 `Initialized false` 和 `Sealed true` 这两个值是
正确的：存储在运行，但还没有配置好，且处于关闭状态：

```
Key                Value
---                -----
Seal Type          shamir
Initialized        false
Sealed             true
Total Shares       0
Threshold          0
Version            2.5.0
Storage Type       file
```

⚠️ **这条命令会返回一个非零退出码——2，而这不是错误。** 对 `bao status` 来说，退出码
表示的是存储的状态，而不是命令是否成功：0 —— 已解封，2 —— 已密封。如果你的 shell 把
非零退出码高亮出来，或者你看到 `command terminated with exit code 2` 这行提示——不要
慌，一切都在按应有的方式进行。

⚠️ **如果命令以 `connection refused`、`no such host` 或 `i/o timeout` 失败——**
再往下走没有意义；先解决连通性。常见原因，按可能性从高到低：你没有把 `workshopXX`
换成自己的编号；控制台里的应用还没就绪；名字里有拼写错误。名字是按
`openbao-<应用名>` 这条规则拼出来的：你把应用命名为 `secrets`，所以地址里是
`openbao-secrets`，而不是 `secrets`。

## 一次可以预料的失败 · 存储拒绝服务

连通性有了，那就可以存密码了。试试看：

```bash
# bao kv put = place a record in the store.
#   secret/passes/db  the path where it will live
#   password=…        the record's contents: a "field name = value" pair
kubectl exec bao-workbench -- bao kv put secret/passes/db password=Propusk2026
```

**你会看到** —— 得到的不是写入确认，而是一个拒绝：

```
Error making API request.
Code: 503. Errors:
* Vault is sealed
```

> **继续往下读之前，先停下来想一想。**
>
> 服务在运行，端口有响应，可存储却拒绝工作。一个运行中的服务为什么会故意不去服务
> 请求？而这为什么很可能是对的？

<details>
<summary><b>答案，以及一个比这个错误更宽泛的教训</b></summary>

更仔细地看看上一步 `bao status` 的输出：

```
Sealed             true
Initialized        false
```

**处于密封状态的存储是刚安装好的 OpenBao 的正常状态。** 磁盘上的数据用主密钥加密，
而主密钥不在进程的内存里。在它被放进去之前，服务既读不了也写不了任何东西，并且它
老老实实地拒绝一切。

在本实验剩下的部分，「解封」只表示一件事：向存储出示主密钥的份额，让它把密钥放进
自己的内存。这个词和往纸上打印毫无关系。

为什么这么设计。如果主密钥就放在加密数据旁边，加密就毫无意义了：偷走磁盘的人两样
都能拿到。所以密钥**只住在内存里**，并且在有人或外部系统出示它时才进入内存。

由此可以得出一个值得立刻接受的结论：**每次 Pod 重启之后，OpenBao 又会回到密封
状态。** 节点重启了、版本升级了、集群把 Pod 迁走了——存储便又停止应答，直到被解封
为止。在生产环境里，这通过外部模块（云 KMS、硬件 HSM）的自动解封来处理，而那本身
就是一个项目。在实验里我们会手动解封，亲眼看看这套机制运转。

**一个比这个错误更宽泛的教训。** **托管服务替你卸下了安装、升级、复制和备份，但它没有
替你卸下运维上的决策。** Cozystack 两分钟就给你把 OpenBao 进程起了起来。解封密钥存在
哪里、谁有权解封、凌晨三点某个节点重启了该怎么办——这些依然是你的问题，而平台没有
悄悄替你回答它们，是件好事。

</details>

## 第 5 步。初始化并解封

📍 **位置：** 在笔记本电脑上，在实验集群中。

**接下来会发生什么：** OpenBao 会生成一个主密钥，把它切成份额，连同一个 root 令牌
一起交给我们。这不会再有第二次——密钥只显示这一次。

```bash
# operator init runs once in the life of the store: it creates the master key and prints
# its shares together with a root token. No one will show these values again.
#   -key-shares=1     how many shares to cut the master key into
#   -key-threshold=1  how many shares must be presented to reassemble it
kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1
```

**你应该看到：**

```
Unseal Key 1: 8kJq…=
Initial Root Token: s.7Yx…
```

⚠️ **现在就把这两个值复制到笔记本电脑上的一个文件里** —— 比如放进 `~/openbao-lab.txt`，
而不是只放到剪贴板。没有人会再次显示它们。丢了解封密钥，你就丢了存储里的每一条
机密——这在设计上就无法恢复。

这两样你都会不止一次用到，具体是什么时候：

- **解封密钥** —— 每一次存储的 Pod 重启时。重启后它又会回到密封状态，每条命令都开始
  回 `Code: 503 ... * Vault is sealed`。
  解决办法是用同一条命令、从你上次停下的同一个地方再解封一次；
- **root 令牌** —— 在实验结束时，给检查脚本用。这两个时刻之间几乎会隔着整个实验，
  到那时你多半已经把终端关掉了。

<details>
<summary><b>`-key-shares` 和 `-key-threshold` 是什么意思，以及为什么生产环境不这样</b></summary>

主密钥不是整个交出去的。它被切成 `key-shares` 份份额，而要把它重新拼回来，你必须
出示其中 `key-threshold` 份。这套方案叫作 Shamir 秘密共享。

其意义在于**没有任何单独一个人能够完成解封**。经典的生产配置是五份份额、门槛为三：
份额交给分处不同部门的五名持有人，重启之后要把存储起起来，你需要凑齐任意三份。
一名离职的管理员不会把访问权限一并带走，一名不老实的管理员也无法凭一己之力拿到它。

我们设一份份额、门槛为一，因为在实验里你是单枪匹马，而我们要的是机制，不是流程。
**在生产环境里绝不能这么做**，这不是走过场：单独一份份额意味着单独一个能让一切泄露
出去的点。

</details>

给它解封。替换成你自己的解封密钥：

```bash
# unseal hands the store one share of the master key. Once the shares reach the threshold,
# the key ends up in the process's memory and the store starts serving requests.
kubectl exec bao-workbench -- bao operator unseal <your-unseal-key>
# We repeat status to see the changed state.
kubectl exec bao-workbench -- bao status
```

**你应该看到** —— `Sealed  false` 和 `Initialized  true`。

现在我们用 root 令牌登录。它会被记在工作 Pod 内部，接下来的命令就不会再要令牌了：

```bash
# login exchanges the entered token for an entry in a file inside the Pod — from then on the utility
# takes the token from there itself, and you won't have to type it into every command.
# -it gives the Pod a terminal: without it the utility has nowhere to print its prompt and nowhere to take input.
kubectl exec -it bao-workbench -- bao login
```

工具会索要令牌，并且**在你输入时不会把它显示出来**——这是有意为之的。把 `init`
输出里的 Initial Root Token 粘贴进去。

⚠️ **如果 `bao login` 抱怨它没法写入令牌文件**，那就在每条命令里都把令牌作为环境
变量传进去：`kubectl exec bao-workbench -- env BAO_TOKEN='你的令牌' bao status`。
这法子管用，但令牌会落进你的命令历史里——在实验里可以忍，在生产环境里不行。

## 第 6 步。启用引擎并存入密码

📍 **位置：** 在笔记本电脑上，在实验集群中。

一个全新的 OpenBao 是空的：里面没有任何一个地方可以放东西。机密引擎需要显式启用。

```bash
# secrets enable turns on an engine — a part of the store that knows one kind of work.
#   -path=secret  which path to hang it on: from here on everything is written as secret/…
#   kv-v2         which engine exactly: "key-value" with version history
kubectl exec bao-workbench -- bao secrets enable -path=secret kv-v2
```

<details>
<summary><b>什么是机密引擎，以及为什么不止一个</b></summary>

OpenBao 不是单一的存储，而是一组引擎，每个引擎都懂得自己的活儿，并挂载在自己的
路径上：

| 引擎 | 做什么 |
|---|---|
| `kv-v2` | 把你放进去的东西存起来，带版本历史。普通的「键值」 |
| 数据库引擎 | **自己**在 PostgreSQL 或 MongoDB 里创建一个存活两小时的临时用户，再自己把它删掉 |
| PKI | 按需签发证书，而不是一年一次向安全部门提申请 |
| transit | 按需加密数据而不存储数据：密钥永远不离开存储 |

`-path=secret` —— 把它挂载在哪个路径上。从此对这个引擎的所有访问都走 `secret/…`。

我们选 `kv-v2` —— 最简单的情形：我们有一个现成的密码需要存起来。数据库引擎有意思得
多：它们把「常驻密码」这一现象整个取消掉，为每一次运行给应用签发一个临时账户。那是
下一个层次，得慢慢长进去；从这里起步是合理的。

</details>

存入密码：

```bash
# kv put writes a whole new version: the listed fields become its contents.
# There can be any number of fields; here there are two — the password and the database username.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026 username=passes_app
```

**你应该看到** —— 一张小表，里面有 `version  1` 和一个创建时间。

检查一下它能读回来：

```bash
# kv get reads the record and prints its fields as a table. We're still reading with the root token — that is,
# we're checking that the record landed, not that the application will have enough permissions.
kubectl exec bao-workbench -- bao kv get secret/passes/db
```

## 第 7 步。给应用授予访问权限——恰好一行

📍 **位置：** 在笔记本电脑上，在实验集群中。

你绝不能把 root 令牌给应用：拿着它可以为所欲为，包括读取别人的机密和删除存储。应用
需要的只是对一个路径的读取权限。

我们来写一条策略：

```bash
# policy write saves a named list of permissions in the store.
#   passes-read  the policy's name; it's later granted to a token by this name
#   -            take the policy text from standard input rather than from a file
#   -i           in kubectl exec: forward that input into the Pod
# <<'HCL' … HCL is a way to pass multi-line text straight into the command, without a file.
kubectl exec -i bao-workbench -- bao policy write passes-read - <<'HCL'
path "secret/data/passes/db" {
  capabilities = ["read"]
}
path "secret/metadata/passes/db" {
  capabilities = ["read"]
}
HCL
```

<details>
<summary><b>读懂这条策略</b></summary>

一条策略就是一份路径清单以及在这些路径上允许做什么。凡是没有明确允许的，都被拒绝；
不需要另外写一条「拒绝」。

```hcl
path "secret/data/passes/db" {
  capabilities = ["read"]
}
```

`secret/data/passes/db` 是 **API 里**的路径，而不是文件系统里的。在 `kv-v2` 引擎里它
是这样构成的：`secret` —— 引擎挂载的位置，`data` —— 引擎自己的内部前缀，`passes/db`
—— 你在 `kv put` 命令里指定的部分。

⚠️ **这个 `data` 前缀是所有令人费解的拒绝里一半的根源。** 在命令行上你写的是
`secret/passes/db`，但在策略里——是 `secret/data/passes/db`。`bao kv` 工具替你插入了
`data`；策略不会。

`capabilities = ["read"]` —— 只能读。不能写，不能删，不能列出相邻的路径。

第二个块，`secret/metadata/passes/db`，是对版本信息的访问：什么时候写的、有多少个
版本、哪个是当前版本。同样只读。

`bao policy write passes-read -` —— 末尾的短横线表示「从标准输入读取内容」。这正是
命令要用 `kubectl exec -i` 运行的原因：`-i` 标志把输入转发进 Pod。

</details>

用这条策略签发一个令牌：

```bash
# token create issues a new token and binds a set of permissions to it.
#   -policy=passes-read  which permissions: the policy written above
#   -ttl=24h             lifetime; after a day the token stops working on its own
#   -field=token         print only the token value, without the table around it —
#                        that way it's easy to copy and pass along
kubectl exec bao-workbench -- \
  bao token create -policy=passes-read -ttl=24h -field=token
```

**你应该看到** —— 一行，里面是令牌。

复制这个令牌——马上就会用到它。

这里的生命周期不是走过场。令牌溜进了日志、进了备份、随笔记本电脑一起泄露了——到后天
它就没用了。清单里的密码没有这种性质。

## 第 8 步。把令牌放进集群，并从清单里移除密码

📍 **位置：** 在笔记本电脑上，在实验集群中。

应用需要某样东西来向 OpenBao 证明「它就是它自称的那个」。这样东西就是令牌。

```bash
# create secret generic creates a Secret object directly in the cluster, bypassing a file on disk.
#   passes-bao-token      the object's name; the application's description will reference the secret by it
#   --from-literal=name=…  set the value as a string from the command line
#                          (there's also --from-file, when the value is in a file)
kubectl create secret generic passes-bao-token \
  --from-literal=token='paste-the-token-from-the-previous-step'
```

**注意：是命令，不是文件。** 令牌直接在集群里创建，永远进不了 Git——根本没有文件让
它去进。

<details>
<summary><b>零号机密：老实说说我们没能战胜的东西</b></summary>

一个合理的反驳：我们移除了数据库密码，却往集群里放了一个令牌。我们不是只是把一个
问题换成了另一个吗？

没有，令牌和密码的区别就在这里：

| | 清单里的密码 | 集群里的令牌 |
|---|---|---|
| 是否躺在 Git 里 | 是，永远地，贯穿整个提交历史 | 否，它是用命令创建的 |
| 生命周期 | 永久 | 一天，之后自行作废 |
| 它授予什么 | 对通行证数据库的完全访问 | 读取存储里的一行 |
| 吊销 | 在它被写到的每个地方都改一遍密码 | 一条命令，即刻生效 |
| 能否看到谁用过它 | 否 | 是，在审计日志里 |

但这并没有把问题完全解决，假装它解决了是不老实的。**总会有一个机密，应用用它来证明
自己有权访问其余的机密。** 它甚至有个名字——零号机密。想去掉它是不可能的：你总得用
某样东西来表明自己的身份。

成熟的系统会怎么处理它：

- **Kubernetes 认证。** OpenBao 拿 Pod 的服务令牌去 Kubernetes 本身那里核验，然后
  签发自己的令牌作为交换。这样一来，「零号机密」就变成了由集群授予的 Pod 身份，
  而不是某个人放在那里的一串字符
- **一次性令牌（response wrapping）。** 运维人员签发一个只能用一次的令牌。如果应用
  收到「已被使用」的拒绝，说明令牌被截获了——而且这一点会立刻显现出来

这两种做法都存在也都管用，但在这个实验里它们会把我们带得太远。记住有这么一条路，
而目标不是「零机密」，而是「用一个短命、权限窄、可吊销的机密，代替一打永久的机密」。

</details>

现在我们应用这份干净的清单。先替换成你自己的租户编号：

```bash
# sed edits text by the pattern s/what-to-replace/with-what/g; g = in every place on the line,
# not just the first. -i means "edit the file itself" rather than print the result
# to the screen. In place of workshop03 from the example, substitute your own number.

# macOS: the empty quotes after -i are mandatory — otherwise sed will take the next word
# as a backup-file extension and replace nothing
sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
# Linux
sed -i 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
```

<details>
<summary><b>细看：secrets-demo.yaml 里面有什么</b></summary>

先从最要紧的开始：**在这个文件里找出密码。** 它不在里面——不是明文，不是 base64，
也不是指向某个它会存身其中的对象的引用。

```yaml
      volumes:
        - name: secrets
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
```

`emptyDir` 是一个临时文件夹，它和 Pod 活得一样久，也随它一起消失。`medium: Memory`
意味着它不是磁盘上的文件，而是内存里的一块区域。密码不会到达节点的磁盘，也不会进入
卷快照或备份。

```yaml
      initContainers:
        - name: fetch-secret
          image: openbao/openbao:2.5.1
```

init 容器是一个在主容器**之前**运行、并且必须成功结束的容器。如果它失败了，主容器
根本不会启动。对于获取机密来说，这正是你想要的行为：应用不应该带着一个空密码启动，
然后在第一次请求数据库时才失败。

```yaml
              bao kv get -field=password secret/passes/db \
                | tr -d '\n' > /secrets/db_password
              chmod 0400 /secrets/db_password
```

我们取一个字段并把它写进一个文件。`tr -d '\n'` 会去掉换行符，万一冒出一个的话：末尾
多一个字符的密码在数据库那里不管用，而排查这种问题很不愉快。`chmod 0400` —— 只有
属主能读它。

```yaml
          env:
            - name: BAO_ADDR
              value: http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: passes-bao-token
                  key: token
```

存储的地址和令牌。令牌是通过对你用命令创建的那个对象的引用而来的。文件里只有对象的
名字，而名字不是机密。

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        fsGroup: 1000
```

一切都以非 root 身份运行。需要 `fsGroup`，是为了让两个容器——写文件的那个和读文件的
那个——都能访问这个文件夹。没有它，init 容器写出的文件主容器打不开，你会花上半个小时
纳闷自己错在哪儿。

```yaml
          volumeMounts:
            - name: secrets
              mountPath: /secrets
              readOnly: true
```

这个文件夹以只读方式交给主容器。应用既不能弄坏密码，也不能把它替换掉。

</details>

**应用它。** Deployment 会滚动到一个新版本：init 容器会去存储那里，把密码放进 Pod 的
内存，然后应用本身才会启动。

```bash
kubectl apply -f secrets-demo.yaml
# We wait until the new version has fully replaced the old one. If the init container can't fetch
# the password, the wait won't finish — and that's exactly the behavior we want.
kubectl rollout status deploy/secrets-demo
```

## 第 9 步。验证应用是从存储里拿到密码的

📍 **位置：** 在笔记本电脑上，在实验集群中。

先看看 init 容器说了什么：

```bash
# -c selects a container inside the Pod. There are two here, and without -c kubectl can't guess which
# one you mean. fetch-secret is the one that ran before the application started.
kubectl logs deploy/secrets-demo -c fetch-secret
```

**你应该看到：**

```
password fetched from OpenBao, not present in the manifest
```

现在看服务本身：

```bash
# The main container: it reads the file the init container placed.
kubectl logs deploy/secrets-demo -c app --tail=2
```

指纹**变了**——之前是 `sha256:a609df223d57`，现在不一样了。应用正在使用一个新密码，
而这个密码不在仓库的任何文件里。

我们把那个幼稚的 secret 删掉；它不再需要了，只会碍事：

```bash
# delete removes the object from the cluster. The application no longer references it,
# so the deletion won't break anything.
kubectl delete secret passes-db
```

## 第 10 步。轮换：不动一个文件就更改密码

📍 **位置：** 在笔记本电脑上，在实验集群中。

回到审计员的第一个要求：「改掉密码。」以前，这意味着找出它被写到的每一个地方，逐一
改好，提交，发布，然后祈祷没有遗漏。

现在：

```bash
# The same kv put. The previous version of the record isn't erased — a second one appears alongside it.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026-autumn username=passes_app
# rollout restart recreates the application's Pods without changing a single line in its description.
# This is what it was all for: the new password is picked up on the next start.
kubectl rollout restart deploy/secrets-demo
kubectl rollout status deploy/secrets-demo
# The fingerprint in the log will show that the password changed, without showing the password itself.
kubectl logs deploy/secrets-demo -c app --tail=2
```

**你应该看到** —— 指纹又变了。两条命令，零个改动的文件，零次提交。

⚠️ **应用是在重启时取走新值的，而不是即刻。** 我们在启动时用一个 init 容器获取机密——
一种简单、可靠的做法，但更新需要重启。如果某个服务需要即时取走机密，你就加一个
sidecar 容器，让它按定时器重新读取值并更新文件。那更复杂，也不是你该起步的地方。

我们来看看历史：

```bash
# kv metadata get shows not the values but information about the record's versions: how many there are,
# when each was created, and which is current now.
kubectl exec bao-workbench -- bao kv metadata get secret/passes/db
```

**你应该看到** —— 两个版本连同它们的创建时间。旧值没有消失：万一发现新密码不适合
数据库，还有地方可以回退。

你也可以把之前的值完整读出来：

```bash
# -version=1 reads the first version written instead of the current one.
kubectl exec bao-workbench -- bao kv get -version=1 secret/passes/db
```

这就是**轮换**：按计划把一条机密替换成新的，而不是在泄露发生之后。像「服务账户的
密码每季度更换一次」这样的规程，从做不到变成了排期表里的一行。

## 第 11 步。审计日志：谁请求了什么

📍 **位置：** 在笔记本电脑上，在实验集群中。

审计员的第二个要求——「给我看看谁读过密码。」我们把日志打开：

```bash
# audit enable turns on an audit device.
#   file              the device type: write records as text
#   file_path=stdout  instead of a file on disk — to the Pod's standard output, from where
#                     the platform collects the logs
kubectl exec bao-workbench -- bao audit enable file file_path=stdout
# audit list lists the enabled devices — a check that the command above went through.
kubectl exec bao-workbench -- bao audit list
```

**你应该看到** —— 一张表，里面有一个类型为 `file` 的已开启设备。

<details>
<summary><b>审计日志里会写进什么，以及它和普通日志有何不同</b></summary>

从这一刻起，OpenBao 会**为每一个 API 请求**写下一条记录：谁请求的（哪个令牌、哪条
策略）、具体请求了什么、什么时候、从哪个地址，以及回复了什么。每个请求有两条记录——
请求本身和对它的响应。

与你熟悉的应用日志相比有三处不同：

**被拒的请求也会写下来。** 试图读取别人的路径会留下痕迹，和一次成功的读取完全一样。
安全团队感兴趣的正是这些被拒的请求：成功的读取是正常工作，而一连串的被拒则是侦察。

**机密的值不会进入日志。** 路径、名字和令牌都被哈希处理；机密本身不会被写下来。日志
可以交到外面去，而不必连同它的内容一起交出去。

**如果日志无处可写，OpenBao 就停止工作。** 这是一个有意为之的决定：一个在无法记录
请求的情况下还继续服务请求的存储，比一个宕掉的存储更糟。由此得到一个实用推论——不要
把你唯一的审计设备指向一个可能被写满的磁盘上的文件。

⚠️ **在实验里你不会被允许读取这份日志，这一点必须讲明白。** 我们把它导向了 OpenBao
Pod 的标准输出，而你的角色读不了租户里 Pod 的日志——租户把服务的管理交给你，却不把
访问它们内部的权限交给你。在真实的部署里，平台的日志收集器会把这份日志取走，放到
安全团队查看它的地方，而不是让你通过 `kubectl` 去看。

你自己仍然能看到的，是上一步的版本历史（`bao kv metadata get`）：谁**写**的、什么
时候写的，精确到秒。这不是完整的审计，但它能回答「密码最后一次更改是什么时候」这个
问题。

</details>

## 检查

📍 **位置：** 在笔记本电脑上，在你先前用 `kubectl` 干活的那同一个终端窗口里。

```bash
cd labs/08-openbao
# The script reads these three environment variables, so you must set them before running it
# and in the same terminal window.
export KUBECONFIG=~/lab.kubeconfig     # which cluster to check
export COZY_TENANT=workshop03          # your tenant number
export BAO_TOKEN='your-root-token'     # the one bao operator init printed
./check.sh
```

⚠️ **在 Windows 上脚本要从 WSL 里运行**，而不是从 PowerShell——怎么装它，写在实验 0
的开头。没有 WSL 也能完成这个实验，只是不会有报告产物。

脚本检查的不是清单有没有被应用这个事实，而是工作的实质：存储已解封、用令牌能把机密
读回来、版本不止一个（说明发生过一次轮换）、审计已开启，而且应用的清单里没有一个
明文密码。

旁边会出现一个报告文件。**没有一条机密会进入报告** —— 只有版本、名字和指纹。

## 清理

```bash
# delete -f = "remove from the cluster everything described in this file".
kubectl delete -f secrets-demo.yaml
# What was created by a command rather than a file is deleted by name.
kubectl delete secret passes-bao-token
kubectl delete pod bao-workbench
```

OpenBao 本身在控制台里删除：`secrets` 应用 → 删除。

为什么这很便宜。在经典的部署方式里，一个机密存储是一个项目：一台服务器、集群化、
证书、一套解封流程、与监控的集成。而在这里，你两分钟就得到了它，十秒钟就把它交还
回去，它占用的空间也释放了。

⚠️ **删除它会连同里面的每一条机密一起删掉。** 已删除存储的解封密钥和 root 令牌会变成
一堆没用的字符串。如果你往里面放过什么真实的东西——先把它取回来。

## 我们现在能做什么

- 向同事解释为什么 Kubernetes 里的 Secret 不是「加密的」，并用一条命令来佐证
- 订购 OpenBao，把它初始化并解封，同时明白正在发生什么
- 把一条机密放进存储，并用一个短命的令牌授予应用恰好对一个路径的访问权限
- 不动仓库里的任何一个文件就更改密码，并查看版本历史
- 清楚地回答「谁读过这个密码」这个问题——并且明白答案是从哪里来的

## 而这在 vSphere 里会是

没有直接的类比，这是老实的回答。在经典的基础设施里，服务账户的密码同时住在三个
地方：一台虚拟机上的配置文件里、部门的密码管理器里，以及当初设置它的那个人脑子里。
轮换意味着把这三处都跑一遍，所以人们不做轮换。「谁读过它」这个问题没有答案，因为
没有人记录一个文件的读取。

有 vSphere Credential Store，有 Windows Credential Manager，有企业级密码管理器——
它们解决的都是「方便人来保管密码」这个问题。而「应用自己按策略、在有限时间内、并留有
记录地拿到密码」这个问题，它们并不解决。

**老实说，vSphere 在哪些方面更方便。** 在上面这些方面都不——但方便是有代价的，代价
就在下面。

虚拟机上文件里的密码**永远可用**：主机重启了，机器起来了，服务读了文件就开始工作。
没有人需要在凌晨三点被叫醒。OpenBao 重启之后是密封的，在解封之前应用不会启动。这给
你的基础设施增添了一个新的故障点和一套新的流程——带着值班人员、带着密钥持有人、带着
一份成文的规程。通过外部 KMS 的自动解封消除了这个问题，却又添上了对那个外部 KMS 的
依赖。

第二点。磁盘上的一个文件，任何管理员一眼就能看懂。路径、策略、令牌、TTL、路径中间
的那个 `data` 前缀——这是一套独立的模型，团队将不得不去学它，而头几个月里它都会是
各种令人费解的拒绝的来源。

收益依然胜过这一切，但它不是免费的，你在规划迁移时应当把这份代价记在心里。
