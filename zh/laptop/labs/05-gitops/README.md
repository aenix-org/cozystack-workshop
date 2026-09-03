# 实验 5 · 用 Git 管理基础设施

| | |
|---|---|
| **时长** | 40 分钟 |
| **验证目标** | 集群会把自己拉到 Git 里所写的状态，并保持这个状态 |
| **你需要准备** | 实验 0 里的集群、`kubectl`、`git`、一个 GitHub 账号、`flux` CLI |

## 为什么这很重要

练习阶段结束了。从这里开始，是一个真实的任务。

业务方想要一个内部服务，叫 **「通行证」（Passes）**：员工通过手机应用申请访客通行证，安保在前台看到名单，管理层每月看一次报表。你在平台团队，把它交付出去就是你的工作。

这个服务背后会有好几个团队，而平台团队只有你们三个人。正是从这里开始，我们才能讲清楚为什么这个实验排在实操部分的第一位。

**三个管理员在一起会发生什么。** 有人通过控制台把应用起了起来。有人用 `kubectl edit` 改了配额，因为那是半夜，而且到处都在着火。有人周五改了副本数，到周一就忘了。一个月后，谁也回答不了两个问题：**这个设置为什么是这样** 和 **它本该是什么样**。而等一切崩掉时，才发现根本没有可以恢复的东西——状态只活在集群自己的脑子里，集群一没，它也就跟着没了。

治这个病的不是一纸制度，也不是「我们都说好不要手动去动」。治它的办法是让手动去动变得**毫无意义**：集群会把它改回原样。这正是我们今天要开启的东西。

## 小词汇表

| 术语 | 它是什么 | 类似……但是 |
|---|---|---|
| **仓库（Repository）** | 一组文件，连同它们完整的编辑历史：改了什么、谁改的、为什么改 | **共享盘上的一个模板文件夹**，但每个人都有自己的一份完整副本，而不是所有人共用一份 |
| **GitOps** | 一种方法：期望状态存放在 Git 里，由一个运行在集群里的代理把它搬过去 | **带蓝图（blueprint）的 vRealize Automation**，但不是一次性应用——而是持续不断的调谐（reconcile） |
| **Flux** | 就是那个代理。它运行在集群内部 | **一个定时代理/脚本**，但不是「应用完就撒手」：它每分钟检查一次，并修复任何偏差 |
| **Kustomization** | 集群里的一个对象：从仓库里究竟要应用什么 | **一个部署任务**，但别把它和 `kustomize` 工具搞混——名字一样，含义不同 |

这个实验里剩下的词——Git、Commit、Branch、Pull request、调谐（Reconciliation）、Drift、GitRepository、Prune——都会在用到它们的那一步、第一次需要时再引入。现在没必要去背它们：脱离了动作，它们记不住。

<details>
<summary><b>如果你想一次看到完整列表</b></summary>

| 术语 | 它是什么 | 类似……但是 |
|---|---|---|
| **Git** | 一个存放文本文件、带完整编辑历史的库 | **配置的存档 + 一份变更日志**，但它存的不是文件副本，而是把每一次变更单独存下来，连同其作者和原因 |
| **Commit** | 一次保存下来的变更：改了什么、谁改的、为什么 | **变更日志里的一条记录**，但它存的是被改动的文本本身，而不只是「发生过一次编辑」的记载 |
| **Branch（分支）** | 一条平行的变更线 | 没有直接的类比；你需要它来准备一个变更，而不必碰到正在工作的版本 |
| **Pull request** | 一个把分支合并进来的提议，在被应用之前会有人评审 | **审批一个申请**，但讨论的是具体的配置行，而不是申请的大意 |
| **调谐（Reconciliation）** | 这个循环：读取期望状态 → 与实际状态对比 → 修正它 | **把集群拉向目标状态的 DRS 逻辑**，但被调谐的不是机器的摆放位置——而是所有被描述过的东西 |
| **Drift（漂移）** | 事实与描述之间的偏差 | **在模板之外做的一次改动**，但这里的漂移不是「在合规报告里被记一笔」——它会被悄无声息地消除 |
| **GitRepository** | 集群里的一个对象：从哪里取状态 | **模板来源的那项设置**，但这个来源是按计划自己去拉取的，而不是在有人点「部署」那一刻才拉 |
| **Prune** | 「把从 Git 里消失的东西从集群里删掉」这个模式 | 没有直接的类比；没有它，从仓库里删掉一个文件不会删掉集群里的任何东西 |

</details>

## 实验文件夹里有什么

所有文件都已经是你的了——你连同仓库一起把它们拿走了。没有什么需要新建或重新敲一遍的：下文凡是写 `kubectl apply -f name.yaml` 的地方，文件都出自这里。

```bash
# 从这里开始，所有命令都在这个文件夹里运行：`kubectl apply -f` 里的路径都是相对于它的。
cd labs/05-gitops
```

| 文件 | 它是什么 | 什么时候派上用场 |
|---|---|---|
| `app/` | 最终应该进入集群的东西：namespace 和「通行证」服务本身 | 你把它放进你自己的 Git 仓库 |
| `flux/` | 给 Flux 的两份描述：从哪里取仓库、以及从中应用什么 | 你把它应用到你自己的实验集群 `lab` |
| `check.sh` | 一项检查：集群是否自己从 Git 里拉取了变更 | 你在实验结束时运行它 |

## 步骤 1. 设置仓库

📍 **位置：** 在浏览器里，在 GitHub 上。

新建一个仓库：

| 字段 | 值 | 为什么 |
|---|---|---|
| Name | `passes-gitops` | 让人一眼看出这是服务的状态，而不是它的源代码 |
| Visibility | **Public** | 这样 Flux 无需密钥就能访问它，你也不用在权限上花时间 |
| Add a README file | 勾上 | 否则仓库会是空的，没有分支，Flux 也就找不到任何可读的东西 |

⚠️ **这里用公开仓库，是对培训测试环境的一处有意简化。** 在生产环境里仓库是私有的，Flux 通过 deploy key 访问它。那又是二十分钟摆弄 SSH 密钥的功夫，而今天我们说的是另一件事。至于里面会放什么——没有一个密码的清单——你自己会看到：密码不进 Git，它们有单独的一个实验。

📍 **位置：** 在你的笔记本电脑上。

把仓库拉到你的机器上：

```bash
# clone = 把仓库连同它全部的编辑历史一起完整下载下来。你得到的
# 不是对某个共享文件夹的访问权，而是磁盘上你自己的一份完整副本：你可以离线使用它。
# 把 `YOUR-LOGIN` 换成你自己的 GitHub 登录名，否则这条命令会指向别人的仓库。
git clone https://github.com/YOUR-LOGIN/passes-gitops.git
# clone 会创建一个以仓库命名的文件夹。从这里开始我们在它里面工作。
cd passes-gitops
```

## 步骤 2. 把「通行证」服务放进仓库

📍 **位置：** 在你的笔记本电脑上。

这个实验的文件夹里有两个文件：`app/namespace.yaml` 和 `app/passes.yaml`。把它们复制到你的仓库里，放进 `apps` 文件夹：

```bash
# apps —— Flux 将从中拉取描述的文件夹。名字是我们选的，它和
# Flux 配置里所指定的完全一样，所以没有理由无缘无故去改它。
#   -p  如果文件夹已经存在，不要当作错误处理
mkdir -p apps
# 把两个文件复制到你自己的仓库里。把 `/path/to/` 换成你克隆
# labs 仓库的那个地方；`*.yaml` 会一次把两个文件都取走。
cp /path/to/labs/05-gitops/app/*.yaml apps/
```

在把它们发出去之前，我们先过一遍你要放进去的是什么。

<details>
<summary><b>细看一下：namespace.yaml 和 passes.yaml 里面有什么</b></summary>

### `namespace.yaml` —— 属于你自己的一个 namespace

```yaml
kind: Namespace
metadata:
  name: passes
```

namespace 是单个集群内部的一个逻辑分区。在 vSphere 里最接近的类比是 vCenter 树里的一个文件夹或一个资源池：同样的资源，但有独立的作用域、独立的权限、独立的配额。

为什么要把它和应用一起放进 Git，而不是手动创建：当这个服务最终离开仓库时，Flux 也会把 namespace 一并移除。不会留下一个空的分区，让人在半年后想不起来它当初为什么被创建。

### `passes.yaml` —— 服务本身

四个对象，用一行 `---` 分隔。

**第一个 —— 一个带 nginx 配置的 `ConfigMap`。** `ConfigMap` 把一个文本文件与应用分开放进集群，然后这个文件被挂载到容器内部。目的是在不重建镜像的情况下修改配置。

里面是一份普通的 nginx 配置。有一行值得留意：

```
sub_filter '__POD__' '$hostname';
```

它告诉 nginx：在它提供的页面里，把文本 `__POD__` 替换成它所运行的那台机器的名字。在一个 Pod 内部，机器名就是 Pod 自己的名字。页面就是这样报出是哪个副本提供了服务的。稍后，你会凭这个名字看到现在有了两个副本。

**第二个 —— 一个带页面的 `ConfigMap`。** 目前它只是个占位内容：真正的应用会在下一个实验里出现，而今天重要的不是服务显示什么，而是它在集群里**从哪来**。

**第三个 —— 一个 `Deployment`。** 应用的描述：用哪个镜像、多少个副本、怎样检查就绪。

```yaml
spec:
  replicas: 1
```

要保持运行多少个副本。注意这个措辞：不是「启动一个」，而是「保持一个」。这就是我们将通过 Git 去改动、并观察会发生什么的那个数字。

```yaml
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
```

就绪检查：集群敲一敲这个地址，在收到响应之前不会把流量发给某个副本。Flux 也需要它——我们会让它等到就绪，而不是一应用完就报告成功。

**第四个 —— 一个 `Service`。** 一个立在所有副本前面的固定名字。`Service` 和 Pod 之间的联系不是一份地址清单，而是条件 `selector: app: passes`，也就是「所有带这个标签的 Pod」。一个带标签的新副本出现了——它就被自动纳入负载均衡。

这四个对象里没有一个包含密码、密钥或令牌。这不是偶然：一切进了 Git 的东西就永远在里面了——历史可以被重写，但每一个来得及克隆它的人都留着旧的副本。密码在这里没有位置；它们有单独的机制和单独的实验。

</details>

把它发到 GitHub。Git 记住的不是不加区别的一切，而是被明确展示给它的东西——正因如此才有三条命令，各做各的事：

```bash
# add = 标记那些将进入下一条历史记录的文件。
git add apps
# commit = 把标记好的东西作为一条记录保存下来：内容、作者、时间和原因。
#   -m "..."  就是那个原因。它会永远留在历史里，人们会读它。
# 这次 commit 目前只活在你的笔记本电脑上——它还没进 GitHub。
git commit -m "add passes service v1"
# push = 把攒下来的 commit 发到 GitHub。在这条命令之前，那边什么都没变。
git push
```

**你应该看到** ——在浏览器里，在仓库页面上，`apps` 文件夹里有两个文件。与此同时集群里还什么都没变：Git 对集群一无所知。

## 步骤 3. 把 Flux 装进你的集群

📍 **位置：** 在你的笔记本电脑上。

Flux 是你集群里的几个服务。一个伸进 Git 把内容下载下来，另一个把下载下来的东西应用到集群，并盯着偏差。

集群是你的，你是它完整的管理员。你自己来装它；不用去问平台团队。

先装 `flux` 命令行工具。它住在你的笔记本电脑上，不在集群里：你会用它来安装那些服务，然后再用它去询问它们的状态。

macOS：

```bash
# Homebrew 从 Flux 项目的仓库取来 formula，放下一个可执行文件。
brew install fluxcd/tap/flux
```

Linux：

```bash
# Flux 站点上的脚本会检测你的架构，把文件放进 /usr/local/bin。
#   -s          curl 静默工作，不显示下载进度
#   | sudo bash 下载下来的文本立即以管理员权限执行——之所以需要管理员权限，
#               是因为要写入一个系统文件夹
curl -s https://fluxcd.io/install.sh | sudo bash
```

Windows（PowerShell，如果装了 Chocolatey）：

```powershell
# choco —— Windows 的一个第三方包管理器；它装的是同一个单独的 flux.exe 文件。
choco install flux
```

现在我们把服务本身装进集群：

```bash
# 设置访问文件：下面的命令会在集群里创建对象，而在哪个集群里创建很关键。
export KUBECONFIG=~/lab.kubeconfig
# flux install 会在集群里建立一个 `flux-system` namespace，并把服务部署进去。
#   --components=...  具体要装哪些：
#     source-controller     伸进 Git，保持仓库一份新鲜的副本
#     kustomize-controller  把下载下来的东西应用到集群，并盯着偏差
flux install --components=source-controller,kustomize-controller
```

⚠️ **按下回车之前，先确认 `KUBECONFIG` 指向哪里。** 我们要把 Flux 装进你自己的实验集群 `lab`，而不是那个把它交给你的集群。如果不确定——`kubectl get nodes` 应该显示一个节点，名字类似 `kubernetes-lab-md0-...`。

**你应该看到** ——一份正在被创建的东西的列表，末尾是一行关于安装成功的信息：

```
✔ install finished
```

我们只装四个服务里的两个。完整的 Flux 套件还能部署 Helm charts、往即时通讯软件发通知——今天这些不需要，而且我们只有一个节点，上面的内存也不多。

确认一下服务起来了：

```bash
# -n flux-system —— Flux 安家的那个 namespace。没有这个标志，kubectl 会去
# default namespace 里找，什么都显示不出来。
kubectl get pods -n flux-system
```

**你应该看到** ——两行，处于 `Running` 状态。

<details>
<summary><b>如果安装 <code>flux</code> CLI 没成功</b></summary>

完全一样的东西，用一份普通的清单（manifest）就能装上，不需要那个工具：

```bash
# 同一套服务，但作为一份现成的描述：-f 接受的不仅是磁盘上的路径，
# 也可以是一个链接。kubectl 会下载这个文件并应用它的内容。
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
```

区别在于：这样一来起的是全部四个服务，而不是两个。这会体现在内存上，但实验照样能走通。后文中 `flux ...` 命令仅用于查看状态——它们可以换成 `kubectl get gitrepository` 和 `kubectl get kustomization`，二者显示的是同样的东西，只是没那么整洁。

</details>

## 步骤 4. 让 Flux 指向仓库

📍 **位置：** 在你的笔记本电脑上。

Flux 装好了，但它还不知道该去哪。我们会用两个对象来告诉它。

打开这个实验文件夹里的 `flux/gitrepository.yaml`，把 `REPLACE-ME` 占位符换成 **你自己** 仓库的地址：

```yaml
  url: https://github.com/REPLACE-ME/passes-gitops
```

<details>
<summary><b>细看一下：gitrepository.yaml 和 kustomization.yaml 里面有什么</b></summary>

### `GitRepository` —— 从哪里取

```yaml
kind: GitRepository
spec:
  interval: 1m
  url: https://github.com/REPLACE-ME/passes-gitops
  ref:
    branch: main
```

这个对象唯一的工作就是保持仓库一份新鲜的副本。它不往集群里应用任何东西，只下载。

`interval: 1m` —— 多久去取一次更新。为了实验方便选了一分钟，好让你不用等。在生产环境里通常设成一到五分钟之间，而对 push 的即时反应不是靠缩短间隔，而是用 webhook 来做：GitHub 自己在有变化时敲一敲集群。

`ref: branch: main` —— 把哪个分支当作真相之源。一切合并进 `main` 的东西都会走到集群里。一切在其他分支里的东西都不会。评审正是从这里来的：一个变更先住在它自己的分支里，可以在那里被审视，只有合并进 `main` 才会让它生效。

### `Kustomization` —— 要应用什么

```yaml
kind: Kustomization
spec:
  interval: 1m
  path: ./apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: passes
  wait: true
```

`path: ./apps` —— 仓库里面的那个文件夹。它里面的一切都会走到集群里。挨着它的文件——比如根目录里的 `README.md`——不会被碰。

这里的 `interval: 1m` 和 `GitRepository` 里的含义不一样。那里是「多久下载一次」。这里是 **多久把集群的实际状态与被描述的状态调谐一次**。即使 Git 里什么都没变，Flux 每分钟也会检查集群是否与描述相符，并把它拉回一致。这正是我们在实验再往后一点会踩到的坑。

`prune: true` —— 把从 Git 里消失的对象从集群里删掉。没有这个，Git 就不再是一份完整的描述：你从仓库里删掉一个文件，但对象仍在集群里跑着，半年后谁也弄不懂它是哪来的。有了 `prune`，描述与现实在两个方向上都相符。

`wait: true` —— 不要一应用完就报告成功，而是等到被应用的东西变得就绪。这个区别正如「提交了申请」和「申请办完了」之间的区别。

</details>

把两个都应用上：

```bash
# -f 指向一个文件夹，而不是一个文件：它里面所有的清单都会被应用——
# GitRepository 和 Kustomization 都在内。两者都创建在 flux-system namespace 里。
kubectl apply -f flux/
```

我们来看看结果如何：

```bash
# 我们向 Flux 询问调谐的状态。
#   --watch  让窗口保持占用，并在情况变化时刷新这一行
# READY: True 意味着仓库的内容到达了集群并被应用了。
# REVISION —— 分支，以及当前所应用 commit 的短标识。
flux get kustomizations --watch
```

**你应该看到** ——几十秒后，出现 `Ready: True` 状态，以及所应用 commit 的哈希：

```
NAME     REVISION            SUSPENDED  READY  MESSAGE
passes   main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d
```

用 `Ctrl+C` 停止观察，看看集群里冒出来了什么：

```bash
# all —— 一次列出主要对象类型的简写：Pod、Deployment、Service 等等。
# 你并没有手动创建 `passes` namespace：它是随应用一起从仓库里到来的。
kubectl get all -n passes
```

**你没有手动应用任何东西。** 你把文本放进了 GitHub，集群自己把它拉了进来。这和 `kubectl apply -f` 的区别不是方便与否——而是现在有了一个单一的地方，写着东西该是什么样。

## 步骤 5. 第一次通过 `git push` 做变更

📍 **位置：** 在你的笔记本电脑上，在仓库文件夹里。

一个副本对「通行证」服务来说不够：安保全天候盯着名单，而更新应用不该让前台停摆。我们把它设成两个。

以前，你会去跑 `kubectl scale`。现在——在文件里改一改。

打开 `apps/passes.yaml` 并改成：

```yaml
spec:
  replicas: 2
```

把它发出去：

```bash
# 和第一次发送一样的三步：标记文件、带上原因保存、发送。
git add apps/passes.yaml
git commit -m "passes: two replicas so the gate does not go dark during rollout"
git push
```

现在观察集群并等待：

```bash
# -w = 「观察并持续追加」：窗口保持占用，每当副本的状态变化时就出现新的一行。
# 用 Ctrl+C 退出。
kubectl get pods -n passes -w
```

**你应该看到** ——一分钟内出现第二个副本。它不是你创建的。

不想等一分钟——你可以让 Flux 立刻调谐：

```bash
# reconcile = 「立刻调谐，不等下一分钟。」
#   kustomization passes  要调谐哪个对象
#   --with-source         先去 Git 取新鲜的 commit，然后才应用；
#                         没有这个标志，调谐会基于早先下载的那份副本进行
flux reconcile kustomization passes --with-source
```

留意一下 commit 信息。`two replicas so the gate does not go dark during rollout`——那就是原因。半年后，当有人问「这里为什么是两个而不是一个」，五秒钟就能找到答案：

```bash
# log = commit 的历史，最新的在最上面。
#   --oneline         每个 commit 一行：一个短标识和原因文本
#   apps/passes.yaml  只显示碰过这个具体文件的 commit
git log --oneline apps/passes.yaml
```

无论是控制台还是 `kubectl`，都不会留下这样的痕迹。

## 步骤 6. 我们来检查一切都在掌控之中

📍 **位置：** 在你的笔记本电脑上。

夜里，一起事故，服务的副本不够用了。你做你一贯做的事：

```bash
# 直接在集群里改副本数，绕过 Git——就像你到今天为止一直做的那样。
#   -n passes  应用住在这个 namespace 里；没有这个标志命令找不到它
kubectl scale deployment passes -n passes --replicas=5
```

```
deployment.apps/passes scaled
```

成功了。我们来检查：

```bash
# READY 这一列读作「就绪/所要求」：有多少副本响应，以及本该有多少。
kubectl get deployment passes -n passes
```

五个副本。等一分钟再看：

```bash
# 同一条命令。唯一的区别是两次运行之间过了一分钟。
kubectl get deployment passes -n passes
```

**你会看到：**

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
passes   2/2     2            2           8m
```

又是两个副本。你的命令被执行了，然后又被撤销了。

> **在往下读之前，停下来想一想。**
>
> 是谁撤销的？为什么它悄无声息地发生，对你的命令没有回以一个错误？
> 而最重要的是：这是一处需要修复的故障，还是它本就该这样工作？

<details>
<summary><b>答案，以及一堂意义远超这个错误本身的课</b></summary>

是 Flux 撤销的，而这正是它被装上来所要做的事。

每分钟一次，`Kustomization` 拿 Git 里的东西和集群里的东西作对比。Git 说 `replicas: 2`。集群里结果是 `5`。一处偏差——这意味着集群错了，因为它不是真相之源。

**为什么 `kubectl scale` 没有返回错误。** 它不可能返回：它老老实实地做了被要求做的事。Kubernetes 接受了变更，副本确实起来了。一分钟后，调谐来了，恢复了被描述的状态。谁也没跟谁争——不同的机制各自按各自的规则运作。

**为什么这是一项特性，而不是一个 bug。** 回到这个实验一开头的那个痛点：你们三个人，有人手动改了什么，而谁也不知道什么在哪被设成了什么。现在这不会发生了。一个在 Git 之外做的变更，会活到下一次调谐为止——也就是说，它不会活。由此得出三件事：

1. **集群不可能被悄悄配错。** 不是「这样做不受待见」，而是物理上不可能。
2. **Git 永远描述现实。** 不是「本该描述」——它就是在描述，因为偏差会自己消除。
3. **恢复集群变成一件枯燥的例行公事。** 装上 Flux，把仓库给它，等着。曾经在里面的一切都会回来，因为它全都被写下来了。

**这一课的意义远不止于这个错误本身。** 你刚刚看到了「应用完就撒手」和「持续不断地调谐」之间的区别。一次普通的 `kubectl apply` 是一发子弹：状态改了，然后就自顾自地活着，谁都能推它一把。调谐不是一发子弹，而是一股拉力：描述持续不断地把现实往自己身边拽。

顺便说一句，正是这同一套机制也会修复那些不是你犯的错误。如果某个节点故障删掉了一个 Pod，或者有人不小心抹掉了 `Service`——那也会回来。

**它什么时候碍事。** 它在事故当中碍事，当你确实需要立刻改动某样东西、没有时间去商量的时候。为了这类情况，Flux 可以暂停：

```bash
# suspend = 为这个对象暂停调谐。Flux 停止把集群拉向描述，
# 手动的改动开始能活下来。这期间 Git 的内容不变。
flux suspend kustomization passes
```

在这之后，调谐不再运行，手动你可以做任何事。要反过来：

```bash
# resume = 把调谐重新打开。紧接着的下一次调谐会消除一切手动做过的东西。
flux resume kustomization passes
```

⚠️ 暂停是一笔递延的债：在 `Kustomization` 被暂停期间，Git 又一次不再描述现实，你又回到了当初的起点。有一条规则：一暂停——就给自己设个提醒，记得把它重新打开。

</details>

## 步骤 7. 通过 `git revert` 回滚

📍 **位置：** 在你的笔记本电脑上。

现在是一个真实的情形。你推出一个变更，结果它是个坏的。

做一次改动：假设某人没多想，把内存挤到一个跑不起来的值。在 `apps/passes.yaml` 里，改内存限制：

```yaml
          resources:
            requests:
              cpu: 20m
              memory: 4Mi
            limits:
              cpu: 300m
              memory: 4Mi
```

把它发出去。一个明知是坏的变更，走的是和好变更一样的路：此刻在你的 `push` 和集群之间没有任何检查——而这正是这一步的要点。

```bash
# 同样的 add、commit、push。commit 里的原因老实地写下来——五分钟后
# 当这个变更不得不撤销时，它会派上用场。
git add apps/passes.yaml
git commit -m "passes: trim memory limit"
git push
```

我们等待并观察：

```bash
# 观察副本，直到调谐带来新的描述。
kubectl get pods -n passes -w
```

**你应该看到** ——新副本起不来。`OOMKilled` 状态意味着进程因超出内存限制而被杀掉；`CrashLoopBackOff` 意味着集群已经接连重启这个副本好几次，如今在下一次尝试之前等得越来越久。Nginx 塞不进四兆字节，一启动就死。

```bash
# 同一份列表，但作为单张快照，不持续观察。
kubectl get pods -n passes
```

```
NAME                      READY   STATUS             RESTARTS   AGE
passes-6c9d4f7b8-2xk4n    1/1     Running            0          12m
passes-7f8a1b2c3-qq7lp    0/1     CrashLoopBackOff   3          90s
```

旧副本还在跑——服务是活的，但更新卡住了。该回滚了。

**以前你会怎么回滚：**

```bash
# undo 会把 Deployment 退回到上一个 revision——退到那次编辑之前的设置。
kubectl rollout undo deployment/passes -n passes
```

这条命令会起作用。副本会回到上一个镜像和上一份设置，二十秒后一切都会好起来——直到 Flux 与 Git 调谐的那一刻。而 Git 里仍然写着 `memory: 4Mi`。一分钟之内，那个坏掉的状态又回来了。

**别做 `rollout undo`。到真相所在的地方去回滚** ——在 Git 里：

```bash
# revert = 新增一个 commit，撤销指定 commit 的改动。
#   HEAD       「当前分支的最后一个 commit」——正是带着那个坏限制的那个
#   --no-edit  不为 commit 信息打开编辑器；Git 自己写好标题
git revert --no-edit HEAD
# 在这个 revert 的 commit 被发到 GitHub 之前，Flux 对它一无所知。
git push
```

**你应该看到** ——一个新的 commit，标题是 `Revert "passes: trim memory limit"`，而一分钟内集群里又有了两个能工作的副本。

```bash
# 副本又起来了：能工作的内存限制回来了。
kubectl get pods -n passes
# 而在这里你能看到现在应用的是哪个 commit——它应该和那个 revert 的对上。
flux get kustomizations
```

<details>
<summary><b><code>git revert</code> 和「把它改回原样」有什么不同</b></summary>

`git revert` 不会抹掉那个坏的 commit。它新增一个 **新的** commit，撤销坏 commit 的改动。一切都留在历史里：什么曾经坏过、什么时候被发现、以及回滚了什么。

```bash
# -4 —— 显示最近的四个 commit；最上面那个是最新的。
git log --oneline -4
```

```
9f3c1ab Revert "passes: trim memory limit"
5d2b8e0 passes: trim memory limit
c71a4f9 passes: two replicas so the gate does not go dark during rollout
0e5f2d3 add passes service v1
```

把这个和没有 Git 时的样子比一比。一个月后，「等等，我们是不是已经踩过这个耙子了？」这个问题没有答案：`kubectl rollout undo` 不留痕迹，而 `Deployment` 的 revision 历史只保留最近十条，并且随对象一起消亡。

在这里你有四行，从中能看出：是的我们踩过，这是什么时候，这是谁，这是他们具体做了什么，这是它在回滚前活了多久。

**还有第二条命令 —— `git reset`，它是真会抹掉历史的。** 在共享仓库里它用不上：你在自己机器上抹掉的一个 commit，仍在两位同事的机器上，他们下一次 `push` 会把它带回来。在共享分支里撤销，永远是 `revert`。

</details>

## 步骤 8. 通过 pull request 评审

📍 **位置：** 在浏览器里，在 GitHub 上。

我们要治的痛点的最后一部分：一个变更立刻就走到了集群里，而没人看过它。上一步里那个坏的内存限制，评审时十秒钟就会被打回——但当时根本没有评审。

为这个变更起一个分支：

```bash
# checkout -b = 起一个新分支并立刻切过去。分支是一条独立的变更线：
# 在它里面做的 commit 到不了 `main`，因而也到不了集群。
#   passes/version-line  分支名；名字里允许有斜杠，用于分组
git checkout -b passes/version-line
```

在 `apps/passes.yaml` 里，改页面上的那一行——比如把文本里的版本从 `v1` 改成 `v1.1`。把分支发出去：

```bash
git add apps/passes.yaml
git commit -m "passes: bump the version shown on the page"
# origin —— Git 记住的、你当初克隆仓库所用地址的名字。
#   -u origin passes/version-line  在 GitHub 里创建一个同名分支并记住
#                                  与它的关联，这样以后一条光秃秃的 `git push` 就够了
git push -u origin passes/version-line
```

作为回应，GitHub 打印出一个创建 pull request 的链接。打开它。

**看一下 「Files changed」 标签页。** 这就是基础设施评审的样子：不是「Pete 说他把限制修好了」，而是具体的行——改前和改后，高亮出来。你的同事看到的正是将走到集群里的东西，并可以就某一具体的行留下评论。

集群这期间没有变，也不会变：`GitRepository` 看的是 `main` 分支，而变更住在另一个分支里。

点击 **Merge pull request** ——变更落进 `main`，下一次调谐把它带到集群。一分钟后，我们开一个隧道，看看服务提供的是什么：

```bash
# port-forward = 从你的笔记本电脑通往集群的一条临时隧道。
#   -n passes     服务所在的 namespace
#   svc/passes    我们通向哪里：通向 Service，而不是某个具体的副本
#   8080:80       左边是你笔记本电脑上的端口，右边是集群内部服务的端口
kubectl port-forward -n passes svc/passes 8080:80
```

📍 **在浏览器里** <http://localhost:8080> ——页面写着 `v1.1`。用 `Ctrl+C` 关闭隧道。

现在一个变更的完整路线是这样的：**分支 → pull request → 评审 → 合并 → 集群**。没有哪一步有人手动进过集群。

<details>
<summary><b>这里面哪些是生产环境里会做而我们没做的</b></summary>

一个真正在用的仓库会在此之上加上三件事：

**分支保护。** 在 GitHub 设置里，`main` 分支对直接 push 是关闭的，唯一的入口是一个带批准的 pull request。否则纪律就靠自觉，而自觉在凌晨三点会崩。

**合并前的检查。** 自动化在清单走到集群之前检查它们的语法和是否合规，不让坏的被合并进去。

**多个环境。** 通常仓库里放的不是一个文件夹，而是 `apps/staging` 和 `apps/production`，各自在各自的集群里有各自的 `Kustomization`。一个变更先走到 staging，稳定下来，再到 production。

我们没这么做，是因为每一件都是单独的一个钟头，而机理并不因它们而改变：真相之源仍然是 Git，Flux 仍然把集群往它身边拉。

</details>

## 验证

📍 **位置：** 在你的笔记本电脑上，在你操作 `kubectl` 的那同一个终端窗口里。

```bash
# 回到实验文件夹：脚本住在那里，而你之前在你自己仓库的文件夹里工作。
cd labs/05-gitops
export KUBECONFIG=~/lab.kubeconfig
# 脚本不改动集群里的任何东西：它只读取状态并打印一份报告。
./check.sh
```

⚠️ **在 Windows 上，脚本从 WSL 里运行**，而不是从 PowerShell——怎么装它写在实验 0 的开头。没有 WSL 你照样能完成实验，只是不会有报告产物。

脚本检查的不是 Flux 装上了这个事实，而是这套机制在运作：Flux 的服务是活的，来源指向你的仓库并成功地从中读取，集群里的对象确实属于 Flux（而不是被手动应用进去的），服务通过 HTTP 响应，并且调谐没有被暂停。

如果你想让脚本也看看你仓库的历史——告诉它克隆在哪里：

```bash
# LAB_REPO —— 脚本据以得知你仓库的克隆在哪里的变量。
# 如果你把它克隆到了主目录以外的地方，填上你自己的路径。
export LAB_REPO=~/passes-gitops
./check.sh
```

那样它会额外核实：集群里所应用的 commit 与你分支里最新的那个相符，以及回滚是通过 `revert` 做的。

## 清理

我们什么都不删：仓库和 Flux 稍后还会用到——接下来的服务会以同样的方式到达集群。

当你把所有实验都做完时，可以像这样一次性把一切都移除：

```bash
# delete kustomization = 从集群里移除这个调谐对象。
#   --silent  不要再问一遍确认
flux delete kustomization passes --silent
```

因为有 `prune: true`，`Kustomization` 带来的一切都会随它一起离开：应用、设置，还有 `passes` namespace 本身。不用手动列出任何东西，也没人会漏掉一个残留——因为 Flux 自己留着一份它创建了什么的清单。

顺便说一句，这是 GitOps 一项不会一眼看出来的独立好处。彻底删掉一个服务，就是对那个文件夹的一次 `git rm` 加一次 `push`。

## 我们现在能做什么

- 把集群的状态保存在 Git 里，并理解这和 `kubectl apply` 有何不同
- 把 Flux 装进我们的集群并让它指向一个仓库
- 解释调谐是什么，以及为什么一个在 Git 之外做的变更活不下来
- 通过 `git revert` 回滚，而不是通过 `kubectl rollout undo`
- 让一次基础设施变更走完 pull request 和评审

## 换成 vSphere 这会是

最接近的类比是 vRealize Automation 里的一份蓝图（blueprint）：期望的配置被单独描述出来，并从描述部署出去。但从那里开始，路就分岔了。蓝图部署完就撒手；如果之后有人进到 vCenter 里改了一台机器的内存，蓝图不会知道。合规工具会在报告里显示这处偏差——然后就没了，由人去解决它。

在这里，偏差自己解决，每分钟一次，没有报告，也不用人。

第二处不同关乎历史。vCenter 里有一份任务日志：谁在什么时候做了什么。它回答「发生了什么」这个问题，但不回答「为什么」和「它本该是什么样」。Git 两者都有：变更的文本、作者、commit 信息里的原因，以及 pull request 里的讨论。

**老实说，哪些地方 vSphere 更方便。** 三件事。

**入门门槛。** 要在 vCenter 里改一台虚拟机的内存，你需要会用 vCenter。要在这里改它，你需要会用 Git：分支、commit、合并、冲突。对一个不懂 Git 的人来说，这不是「更方便」——这是一门新职业，头两周他们会比过去干得更慢。

**反应速度。** 在紧急情况里，你想立刻改状态，而不是通过一个分支、一次评审、和一分钟的调谐。暂停机制是有的，但你得记着去用它，还得记着把它关掉。

**故障的清晰度。** 在 vCenter 里某样东西部署不出来时，会给你显示一个带错误的任务。在这里部署不出来时，你得看 `GitRepository` 的状态，然后看 `Kustomization`，然后看事件，然后看两个服务的日志。诊断被摊在了各个层里，老实说这在你习惯之前很不方便。
