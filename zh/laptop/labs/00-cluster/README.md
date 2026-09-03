# 实验 0 · 你自己的 Kubernetes 集群

| | |
|---|---|
| **时长** | 15 分钟，其中 10 分钟在等待 |
| **它证明了什么** | 一个集群只是目录里的一个条目，而不是一个耗时一个季度的项目 |
| **你需要什么** | 访问租户控制台的权限；笔记本上的 `kubectl`、`kubelogin` 和 `git` |

## 为什么这很重要

接下来你会部署应用、把它们弄坏、修好，再对它们做扩缩容。要做这一切，你需要一块自己完全拥有、犯错也毫无代价的地方。

在 vSphere 里，这样一块地方是别人分配给你的。而在这里，你自己动手，十分钟就拿到手，用完之后同样轻松地自己删掉。

## 小词汇表

从这里往后，每个实验里都会出现这七个词。第三列指出这个术语所类似的 vSphere 里的东西——并且立刻指出它与之不同的地方：这里的类比帮助你理解，但没有哪一个是完全吻合的，而知道类比究竟在哪里失效，比类比本身更重要。

| 术语 | 它是什么 | 类似……但是 |
|---|---|---|
| **Kubernetes 集群** | 若干台机器加上一个管理程序，由它把应用分摊到这些机器上。你把应用交给它，并不告诉它在哪台机器上运行——它自己决定 | **一个 ESXi 集群**，但 DRS 既做放置，之后还会持续地重新平衡虚拟机，在各主机之间来回搬迁。这里的单位是容器，它的放置位置只在启动时选一次，外加节点故障时再选一次；集群不会自己去重新洗牌已经在运行的东西 |
| **Control plane** | 集群的管理层：它接收你的命令，保存期望状态，并把工作分派给各个节点 | **vCenter**，但它不是一台带 Web 界面的独立服务器——它是一小撮进程；在 Cozystack 里它们运行在平台之中，而不在你的节点上 |
| **节点（node）** | 你的应用最终运行在其上的机器 | **一台 ESXi 主机**，但这里它是一台 VM，而不是硬件，而且几分钟就能创建出来 |
| **Node group** | 对一组相同节点的描述：有多少个、多大规格 | **一个主机集群**，但这个组能根据负载自己增加和减少节点 |
| **Kubeconfig** | 一个文件，里面装着集群的地址和你对它的访问凭据。没有它，`kubectl` 就不知道去哪里连接 | **vCenter 地址加上一个账号**，但这是你磁盘上的一个纯文本文件，而不是客户端里的一项设置 |
| **租户** | 你在平台里的那一份：你自己的配额、你自己的权限、你自己的对象 | **一个资源池加上对某个文件夹的权限**，但它同时也是一条可见性边界——邻居无法窥探你的租户 |
| **Namespace** | 集群内部用来放置对象的一个区块 | **vCenter 清单里的一个文件夹**，但隔离更严格：不同 namespace 里的对象无法用短名字互相找到对方 |

容器值得单独说一句，因为这是与你熟悉的那个世界最主要的分岔。容器是一个正在运行的应用，连同它工作所需的一切，打包进单个镜像文件里。它与虚拟机的区别在于，它内部没有自己的操作系统：容器使用它所运行的那台机器的内核。规模上的差别正是由此而来——一台 VM 启动要一分钟、体积达数 GB，而一个容器一秒钟就启动、体积只有几十 MB。正因如此，集群才毫不在乎地成批重启它们，而这正是你在后面几个实验里要做的事。

## 如果你用的是 Windows——先读这一段

实验里的命令是为 Linux 和 macOS 的命令行写的。在普通的 PowerShell 里，其中一部分不会工作：PowerShell 有着不同的语法和不同的命令集。

解决办法是 **WSL**——Windows 内部的一个 Linux 子系统。用以管理员身份运行的 PowerShell 里的一条命令就能装上它：

```powershell
# 把 Linux 子系统装进 Windows：内核、服务，以及默认的
# Ubuntu 发行版。安装完成后 Windows 会要求你重启。
wsl --install
```

重启之后你就会有一个 Ubuntu 控制台——从这里开始你就在里面工作，和其他人一样。在 WSL 内部你需要一个自己的 `kubectl`——就是你用来连接集群的那个命令：

```bash
# snap 是 Ubuntu 的包管理器。--classic 以不隔离的方式安装该包：
# 在隔离模式下 kubectl 看不到你主目录里的访问文件。
sudo snap install kubectl --classic
```

Windows 的磁盘从 WSL 里可以在 `/mnt/c/...` 路径下看到，所以用普通浏览器下载的文件在里面也能用——无需把它们复制到任何地方。这一点稍后会派上用场，就是你拿到集群访问文件的时候：如果你把它保存在 Windows 上，从 WSL 看它会位于类似 `/mnt/c/Users/Ivan/Downloads/filename` 这样的路径。

⚠️ **如果 WSL 被安全策略禁用了**——在企业的笔记本上这很常见——实验依然能做：凡是在控制台里完成的一切都与操作系统无关。你唯一没法做的，只有运行检查脚本和少数几个完全由命令组成的步骤。这些地方会单独标出。

## 实验文件夹里有什么

所有文件都已经是你的了——你把它们连同仓库一起取来了。没什么要创建或重新敲的：下面凡是写 `kubectl apply -f name.yaml` 的地方，文件都取自这里。

```bash
# 路径从仓库根目录算起——它你在下一步取来
cd labs/00-cluster
```

| 文件 | 它是什么 | 你什么时候会用到 |
|---|---|---|
| `cluster.yaml` | 实验集群的描述：版本、节点、监控 | 你在第一步在管理集群上应用它 |
| `check.sh` | 检查集群是否已起来、你是否连上了它 | 你在实验末尾运行它 |

## 步骤 0. 取来材料

📍 **在哪里：** 在笔记本上。

仓库里放着清单（manifest）——描述要在集群里创建什么的文件——和检查脚本。从这个实验起你就需要它们：

```bash
# clone = 把整个仓库下载下来，连同它的变更历史。
# 旁边会出现一个 cozystack-migration-workshop 文件夹，我们进到里面去。
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop
```

从这里往后，实验里每个路径都从这个文件夹算起。

## 拿到平台的访问权限

📍 **在哪里：** 在浏览器里，然后在笔记本上。

你从平台订购的一切，都存在于**管理集群**上——和你的租户在同一个地方。要用命令连接它，你需要一个访问文件。在控制台里取来它：`Info` 应用 → `Secrets` 标签页 → `kubeconfig-tenant-workshopXX` 这个 Secret → `Reveal`。复制其内容，把它保存在笔记本上，名字叫 `~/.kube/workshop`。

这个路径在每个实验里都会用到——如果你把文件保存到别的地方，从这里往后每次都得替换成你自己的路径。

```bash
# 检查文件可读、且集群有响应。
# --kubeconfig 告诉 kubectl 在这条命令里用哪个访问文件。
kubectl --kubeconfig ~/.kube/workshop get kubernetes.apps.cozystack.io -n tenant-workshopXX
```

**你应该看到什么：** 要么是一个空列表，要么是 `No resources found` 这一行——你还没创建过任何集群。要紧的是另一件事：是集群本身回应了，而不是一条错误信息。

⚠️ **首次连接时会打开一个浏览器。** 访问不是靠证书授予的，而是通过 Keycloak——一台登录服务器，就像内部服务里的「用企业账号登录」。`kubectl` 会调用 `kubelogin`，后者打开一个浏览器窗口，你以 `workshopXX` 的身份登录，从此之后命令就静默运行，直到你的通行证过期。如果你看到的不是浏览器，而是一条关于缺少插件的错误——那是 `kubelogin` 没装，或者它的文件没命名为 `kubectl-oidc_login`。怎么安装，写在工作坊的开头。

⚠️ **你的租户编号就是你登录控制台所用的登录名：** `workshop03`、`workshop07` 等等。你的租户的 namespace 由 `tenant-` 这个词加上这个编号构成：`tenant-workshop03`。下面凡是写 `workshopXX` 的地方，都替换成你自己的。

## 步骤 1. 创建集群

📍 **在哪里：** 在浏览器里，在 Cozystack 控制台里。

租户 → **Create application** → `Kubernetes`。

填写：

| 字段 | 值 | 为什么这样 |
|---|---|---|
| Name | `lab` | 短——你得在命令里敲它 |
| Version | 保留给出的那个 | 它是最新的稳定版 |
| Control plane replicas | **1** | 默认是两个；对一个实验用的测试环境而言一个就够了 |
| Node group: name | `md0` | 这个名字会进到节点名里——稍后你会在 `kubectl get nodes` 的输出里看到它 |
| Node group: min replicas | **1** | 我们从一个节点开始 |
| Node group: max replicas | **3** | 这个组自己可以增长到的上限；默认是 10，而扩缩容那个实验就建立在这个上限之上 |
| Node group: instance type | `u1.medium` | 1 个处理器，4 GB |
| Node group: disk | `20Gi` | |
| Storage class | `replicated` | 数据会以三份副本落在不同的节点上 |
| Addons → **Monitoring agents** | **启用** | 否则指标不会积累，到画图那个实验里就没什么可看的了 |

点击创建。

⚠️ **马上启用 `Monitoring agents`。** 指标采集没法事后再打开：如果你一周后才勾上这个框，在那之前发生的一切就永远丢失了。画图那个实验依赖的是从今天开始积累的数据。

⚠️ **如果你旁边有人在做同样的事——错开几分钟。** 几个同时进行的创建会给内部安装机制加负担，两个集群起来都会慢上三倍。实验各按各的节奏走，不用赶。

### 从命令行做同样的事——以及它背后的那个文件

这不是控制台挂了时的备用方案。控制台里那个按钮拼出的正是同样这个文件，并把它发送到集群——也就是说，这里文本是主体，而鼠标是它之上的一层。我们要引向的正是与文本打交道：躺在文件里的一份描述，可以被评审、放进 Git、回滚，而按一下按钮则不能。

这个文件躺在本实验的文件夹里：**`labs/00-cluster/cluster.yaml`**。没什么要打开或重新敲的——如果你在实验开头取来了仓库，它就已经是你的了。下面是它的完整内容，好让我们逐个字段过一遍。

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Kubernetes
metadata:
  name: lab
  namespace: tenant-workshopXX
spec:
  version: v1.35
  storageClass: replicated
  controlPlane:
    replicas: 1
  addons:
    monitoringAgents:
      enabled: true
  nodeGroups:
    md0:
      minReplicas: 1
      maxReplicas: 3
      instanceType: u1.medium
      diskSize: 20Gi
      storageClass: replicated
```

⚠️ 下面的命令在**管理集群上**运行——用连同租户一起发给你的那份访问权限。`lab` 集群本身的访问文件还不存在：它只在集群起来之后才出现。

```bash
# 进入实验文件夹——从这里往后所有文件都从这里取
cd labs/00-cluster
# 应用之前，把文件里的 XX 换成你自己的租户编号。
# apply =「把集群带到文件里所描述的样子」。这条命令并不自己把集群
# 起起来——它把订单交给平台，由平台决定创建什么、以什么顺序创建。
#   -f   从文件取描述
kubectl apply -f cluster.yaml
# get =「显示有什么」。kubernetes.apps.cozystack.io 是对象类型的全名，
# 正是文件里描述的那个（kind: Kubernetes），lab 是你那份订单的名字。
#   -n   在哪个 namespace 里查找；不带这个标志 kubectl 会在默认 namespace 里看
#   -w   持续观察并打印变化。要退出——Ctrl+C，安装不会因此中断
# 一直等到 READY 列里出现 True。
kubectl -n tenant-workshopXX get kubernetes.apps.cozystack.io lab -w
```

## 步骤 2. 等待，并看看它是由什么组装起来的

📍 **在哪里：** 在浏览器里，在控制台里。

状态通常会在五到十分钟内转为 `Ready`。

⚠️ **如果过了二十多分钟状态还没变——原因可能不在你的集群上。** 平台上所有应用的安装都由一条共享队列驱动，如果队列里排着某人的一个耗时操作，你的集群就在等轮到自己。要看它是否已被拿去处理：

```bash
# 看订单本身，以及平台关于它写了什么。
# 输出末尾的 status.conditions 一段就是它的报告：有没有被拿去处理、
# 什么在阻塞、它在等什么。
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX \
  get kubernetes.apps.cozystack.io lab -o yaml
```

如果那里也看不出什么名堂——看看租户的事件。这是平台对你的对象都做了些什么的日志：

```bash
# events = 事件日志。我们按时间排序，好让最新的在最下面。
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX \
  get events --sort-by=.lastTimestamp | tail -20
```

这里最常见的发现是 `exceeded quota: tenant-quota` 这一行。它意味着集群不够分配给你租户的那一份资源，而且它自己不会从这个状态里出来：你得腾出空间，或者扩大配额。

安装进行的同时，在控制台里看看你的租户里究竟出现了什么。

**Control plane** 作为几个普通应用部署了出来。没有哪台单独的机器充当「这个集群的 vCenter」：管理层就是一些进程，它们和其余一切并排运行。

**一个节点**——而这个才是一台虚拟机。一台再普通不过的，和你正在迁移的那些一模一样：有自己的磁盘、自己的内存、自己的地址，而且它住在你的租户里。

由此引出一件要紧的事：**Kubernetes 在这里不取代虚拟化，而是活在它之上。** 你不必在「我们跑 VM」和「我们跑容器」之间做选择——两者都能工作，在同一套硬件上、在同一个界面里。

## 步骤 3. 拿到新集群的访问权限

📍 **在哪里：** 在笔记本上；文件本身用命令取，或从控制台取。

**我们要取什么。** `lab` 集群的 kubeconfig——一个文本文件，里面记着它 API server 的地址和你对它的访问数据。没有这样一个文件，`kubectl` 就不知道去哪里连接、以谁的身份出示自己。这个文件你自己在笔记本上创建，名字叫 `~/lab.kubeconfig`；路径里的 `~` 就是你的主目录：macOS 上是 `/Users/name`，Linux 和 WSL 上是 `/home/name`。

⚠️ **这是第二个访问文件，不是第一个的替代品。** 连同租户一起发给你的那个（在实验里它躺在 `~/.kube/workshop` 路径下）通往管理集群——你在那里订购应用、也刚在那里创建了 `lab`。新的这个文件通往 `lab` 集群内部本身。这是两个地址不同的不同集群，而从这里往后两个都需要：给平台的订单走第一个文件，在你自己集群内部的工作走第二个。

**它躺在哪里。** 平台把它放进了你租户里的 Secret `kubernetes-lab-admin-kubeconfig`。Secret 是一种集群对象，里面存放密码、密钥和访问文件。Secret 里你需要的那个键是 `admin.conf`。

⚠️ **这个 Secret 里有四个键，而你要的正是 `admin.conf`。** 挨着它的是 `admin.svc`——同一个东西，但带的是只在集群内部可见的内部地址；从笔记本用它连不上。`super-admin.*` 这一对授予绕过既定限制的权限，是为事故之后的处理准备的，而不是日常使用。

**主要办法——用命令。** Cozystack 在你的集群上设置了一条单独的访问规则，只允许读这一个 Secret，别的什么都不许。命令在**管理集群上**运行，用连同租户一起发给你的那份访问权限，结果放进笔记本上的一个文件里：

```bash
# get secret = 显示 Secret；-o go-template ——不整个打印它，
# 而是从中抽出一个字段并以文本形式输出：
#   index .data "admin.conf"   从 Secret 里取 admin.conf 这个键
#   base64decode               Secret 的内容是以 base64 编码存放的，
#                              这个函数返回原始文本
#   > ~/lab.kubeconfig         把输出写进文件而不是打到屏幕上
kubectl -n tenant-workshopXX get secret kubernetes-lab-admin-kubeconfig \
  -o go-template='{{ printf "%s\n" (index .data "admin.conf" | base64decode) }}' > ~/lab.kubeconfig
```

**用鼠标做同样的事。** 同一个 Secret 在控制台里 `lab` 应用的页面上、在它的 secret 列表里可以看到——按名字 `kubernetes-lab-admin-kubeconfig` 找。复制 `admin.conf` 键的值，打开任意文本编辑器，把复制的内容粘进去，把文件以 `lab.kubeconfig` 的名字保存在你的主目录里。

## 步骤 4. 连接

📍 **在哪里：** 在笔记本上。

**接下来会发生什么：** 我们告诉 `kubectl` 用哪个访问文件，并向集群索要它的节点列表。

macOS 和 Linux：

```bash
# KUBECONFIG 是 kubectl 从中得知要取哪个访问文件的变量。
# export 让它对这个终端窗口里往后运行的所有命令可见。
export KUBECONFIG=~/lab.kubeconfig
# nodes 是集群的节点，正是你的应用将要在其上运行的那些虚拟机。
# 这个回应顺带证明了访问文件是可用的。
kubectl get nodes
```

Windows PowerShell——仅当你没能装上 WSL 时：

```powershell
# 在 PowerShell 里环境变量通过 $env: 设置，一直存活到窗口关闭
$env:KUBECONFIG="$HOME\lab.kubeconfig"
kubectl get nodes
```

**你应该看到什么**——一行，是你的节点，状态为 `Ready`：

```
NAME                        STATUS   ROLES    AGE   VERSION
kubernetes-lab-md0-xxxxx    Ready    <none>   3m    v1.35.6
```

⚠️ **`TLS handshake timeout` 和 `context deadline exceeded` 是集群一侧的拒绝，而不是命令里的错误。** 你集群的管理部分只以单份副本运行，当平台处于负载之下时，它会有几十秒停止响应。命令失败，你过半分钟再重复一遍——它就通过了。如果这发生在某个 `apply` 的中途，就重复它：这条命令是把集群带到文件里所描述的状态，而不是添加新东西，所以什么都不会被创建两次。

⚠️ **`KUBECONFIG` 变量必须在每个新终端窗口里都设置。** 忘了它，`kubectl` 就会跑去某个别的集群，或者说没有可连接的东西。这是所有实验里「我这儿全坏了」最常见的原因。如果有什么表现古怪——第一件要检查的事就是 `echo $KUBECONFIG`。

## 检查

📍 **在哪里：** 在笔记本上，就在你刚才用 `kubectl` 工作的那个终端窗口里。

```bash
# 脚本从实验文件夹里运行：它在自己旁边找文件
cd labs/00-cluster
# 名字前的 ./ 意思是「就从这里运行这个文件」；不加它，shell
# 就会在系统文件夹里找 check.sh 这个命令，然后找不到
./check.sh
```

⚠️ **在 Windows 上脚本从 WSL 里运行**，而不是从 PowerShell——怎么装它，写在本实验的开头。没有 WSL 也能完成实验，但就不会有报告产物。

脚本会确认集群有响应、节点都在岗，而且它们上面有地方留给将来的应用。它旁边会出现一个报告文件——你可以把它附到任何地方，作为实验做完了的证明。

## 清理

集群在实验 1–5 以及往后还会用到。现在别删它。

等你把所有实验都做完了——通过控制台删掉 `lab` 应用。

删除本身要花几分钟：平台关掉节点 VM、移除管理组件、释放磁盘。如果那一刻安装队列正被某人的耗时操作占着，等待可能更久——那就用同样那个 `reconcile.fluxcd.io/requestedAt` 注解的小技巧，本实验前面描述过的那个。

要紧的是另一件事：**释放出来的东西会完整地、自己回到配额里。** 用不着去求谁，也用不着解释你当初为什么拿它。

## 我们现在能做什么

- 给自己起一个 Kubernetes 集群，不用去找任何人
- 明白 control plane 是一些进程，而节点是一台虚拟机
- 拿到访问权限并从笔记本连接
- 当 `kubectl` 表现古怪时，知道该去哪里找原因

## 而在 vSphere 里这会是

vSphere 里的 Kubernetes 是一个单独的产品、一份单独的许可证，以及一个有厂商参与的落地项目。这里则是目录里的一行和十分钟。

**说句公道话，vSphere 在哪里更方便。** 如果你需要的只是虚拟机、别的一概不要，vCenter 给你更多现成的管理工具：模板、克隆、来宾操作系统定制、精确到单个文件夹一级的权限。Cozystack 会做 VM，但这里围绕它们的生态更年轻。收益出现在你同时需要 VM 和其余一切的地方——数据库、队列、集群、镜像仓库——在一个地方、通过一个 API。
