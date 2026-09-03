# 实验 6 · 你自己的私有镜像仓库

| | |
|---|---|
| **时间** | 45 分钟，其中 10 分钟在等待 |
| **验证了什么** | 镜像仓库十分钟就能建好，而且集群只能从它这里拉取镜像 |
| **需要准备** | 实验 0 建好的集群、笔记本电脑上的 `kubectl`、`docker`（或 `podman`）、控制台访问权限 |

## 为什么要做这一步

「Passes」服务一路走到了信息安全部门，然后回来一封邮件。

> 容器镜像是从互联网上的公共镜像仓库拉取的。这不可接受：镜像里的内容没有任何人审核过，
> 同一个名字下的内容可能发生变化，而且一旦外部资源不可用，生产服务就起不来。所有镜像
> 都必须存放在组织的内部镜像仓库里。

没什么可反驳的 —— 每一条都在理。一个打着 `latest` 标签的公共镜像，今天和明天可能是两回事。
镜像的作者可以把它删掉。外部镜像仓库可以在最不合适的时刻限制你的下载速度 —— 这不是假设，
所有大型公共镜像仓库都这么干。

所以你需要一个自己的镜像仓库。通常这本身就是一个项目：申请一台虚拟机、安装、证书、存储、
备份，耗掉某个人一个季度。而今天，它只是目录里的一个条目。

既然镜像仓库是你自己的、封闭的，就得给集群授予访问它的权限。所有人都在这里栽跟头，
我们也会栽 —— 故意的。

## 小词典

| 术语 | 是什么 | 像……但 |
|---|---|---|
| **镜像（image）** | 应用的快照，包含运行它所需的一切 | **虚拟机模板**，但不可变：你没法进到里面去修，只能重新构建一个 |
| **层（layer）** | 镜像的一部分。镜像由层构成，层可以复用 | 不同镜像里相同的层，在镜像仓库里只存一份 |
| **标签（tag）** | 镜像的版本标记：`passes-api:v1` | **模板的版本名**，但标签可以被重新指到另一个镜像上，这正是麻烦的主要来源 |
| **镜像仓库（registry）** | 通过 HTTP 提供服务的镜像存储 | **Content Library**，但它在每次启动时通过网络分发层，而不是整份复制模板 |
| **Harbor** | 带界面、项目、权限和漏洞扫描器的镜像仓库 | **Content Library + 权限 + 报告**，但它能检查镜像内容并给它们签名 |
| **Harbor 中的项目** | 镜像仓库内部一块有自己权限的区域 | **Content Library 里的一个文件夹**，但它可以是公开的或私有的，这决定了是否需要凭据 |
| **`imagePullSecret`** | 一个 Secret，保存着镜像仓库的登录名和密码，由节点读取 | **连接 Content Library 用的账号**，但需要它的是**节点**，不是你；你的 `docker login` 对集群没有任何帮助 |
| **Dockerfile** | 构建镜像的指令 | **准备模板的说明**，但它每次构建都从头到尾完整执行一遍 |
| **Downward API** | 通过环境变量把 Pod 关于自身的信息交给它的一种方式 | **VMware Tools 提供的来宾变量**，但这些值是集群在启动时注入的；应用并不主动请求它们 |

## 两个 kubeconfig：别搞混

从这里开始，本实验会涉及两个不同的集群，值得在敲第一条命令之前就把它们分清楚。

| Kubeconfig | 是什么 | 用它做什么 |
|---|---|---|
| `~/.kube/workshop` | Cozystack 管理集群，你的租户 | 查看托管服务：Harbor、数据库、队列 |
| `~/lab.kubeconfig` | 实验 0 建的**你自己的**实验集群 `lab` | 部署应用 |

两个都从控制台（dashboard）里获取。租户的那个放在 `kubeconfig-tenant-workshopXX` Secret 里
（Secrets 标签页），集群的那个在你实验集群 `lab` 的访问信息一节里。

⚠️ **本实验里「我这儿什么都不工作」最常见的原因，就是命令去了错误的集群。** 每个命令块
之前都写明了它是发给哪个集群的。如果你不确定：

```bash
# echo 打印变量的值：kubectl 现在用的是哪个访问文件。
# 为空则表示 kubectl 会使用默认文件 ~/.kube/config，而不是你以为的那个。
echo $KUBECONFIG

# get nodes = 「显示集群的节点」。这里它是一张石蕊试纸：
# 从返回结果就能看出命令去了两个集群中的哪一个。
kubectl get nodes
```

实验集群 `lab` 里会有一个节点，名字类似 `kubernetes-lab-md0-...`。在管理集群里，这条命令多半
会返回拒绝 —— 租户没有查看节点的权限。

## 实验目录里有什么

所有文件都已经是你的了 —— 你随仓库一起拿到了它们。不需要再创建或手敲什么：下文凡是写着
`kubectl apply -f name.yaml` 的地方，文件都取自这里。

```bash
# 本实验的每条命令都在实验目录里执行 —— 先切换进去
cd labs/06-harbor
```

| 文件 | 是什么 | 什么时候用得上 |
|---|---|---|
| `app/` | 「Passes」服务的 Go 源码和一个 `Dockerfile` —— 你用它们构建镜像 | 你在本地构建，`docker build` |
| `passes-broken.yaml` | 一个**故意做得不完整**的文件：没有访问镜像仓库的凭据 | 你应用它，亲眼看到被拒绝 |
| `passes.yaml` | 同一个文件，但带了访问镜像仓库的凭据 | 弄明白之后你再应用它 |
| `check.sh` | 检查镜像是来自你的 Harbor，而不是来自互联网 | 在实验结束时运行 |

## 步骤 1. 创建 Harbor

📍 **在哪里：** 在浏览器里，在 Cozystack 控制台（dashboard）里。镜像仓库是租户的共享资源，
不属于你的实验集群 `lab`，所以它在创建集群本身的同一个地方创建。

租户 → **创建应用** → `Harbor`。

| 字段 | 值 | 为什么这样 |
|---|---|---|
| Name | `harbor` | 它会成为镜像仓库地址的一部分；具体是什么，创建后就能看到 |
| Host | 留空 | 那样地址会自动由名字和租户域名拼成 |
| Storage class | `replicated` | 数据会以三份副本分布在不同的节点上 |
| Trivy → enabled | **关掉** | 这个漏洞扫描器要下载一个好几 GB 的数据库；在教学测试环境里这意味着多等二十分钟 |
| Database → replicas | `1` | 今天我们不测试镜像仓库数据库的容错 |
| Database → size | `5Gi` | |
| Redis → replicas | `1` | |
| Redis → size | `1Gi` | |
| Core / Registry preset | 保持建议值 | |

⚠️ **这个表单里的 Redis 是 Harbor 自己的内部缓存，和下一个实验没有任何关系。** 在讲缓存的
那个实验里，你会为自己的应用另起一个 Redis。名字相同，角色不同。

点击创建然后等待。Harbor 五到十分钟起来：它不是单个应用，而是若干服务，外加一个数据库，
再加上一个用来存放镜像层本身的对象存储。

⚠️ **如果 Harbor 处于「未就绪」状态超过十五分钟** —— 看看发生了什么：
`kubectl -n tenant-workshopXX get pods | grep harbor`。多半是安装队列在起作用，它是全平台
共享的：你的应用排在别人的后面等着。

Harbor 把镜像层存放在兼容 S3 的存储里，用来放它们的 Bucket 会自动创建 —— 为此你不需要在
租户里启用自己的存储，用上级的就行。如果超过半小时 Pod 还是不出现，把这条命令的输出发到
工作坊聊天里。

## 步骤 2. 拿到凭据并登录镜像仓库

📍 **在哪里：** 在控制台（dashboard）里，然后在笔记本电脑上的终端里。

打开你创建的 `harbor` 应用，找到放 secret 的那个标签页。那里有一个装着镜像仓库凭据的
secret，它里面有三个你需要的键：

| 键 | 里面是什么 |
|---|---|
| `url` | 你的镜像仓库地址，形如 `https://harbor-....<测试环境域名>` |
| `admin-password` | 管理员的密码 |
| `redis-password` | Harbor 的内部密码，你用不到 |

登录名是 `admin`。

⚠️ **不要去猜镜像仓库的地址，从 `url` 键里取。** 平台会在应用名字前加上服务类型作为前缀，
所以地址可能和你根据名字预期的不一样。同一个地址也能在应用的 ingress 列表里看到。

同一个密码也能用命令拿到。租户不被允许通读**所有**的 secret —— 你自己验证一下，
`kubectl auth can-i get secrets` 会回答 `no`。但对于你创建的每一个应用，平台都会设一条单独
的规则，恰好放行它自己的凭据：

```bash
# get secret = 「显示 Secret 对象」。这个 secret 的名字由应用类型前缀
# 和它的名字拼成：harbor- + harbor。
#   -n tenant-workshopXX  在哪个 namespace 里查找 —— 你的租户
#   -o jsonpath='...'     从对象里取出单个字段，而不是整个打印出来
#   base64 -d             解码：secret 里的值以 base64 存储
#   ; echo                补一个换行，否则密码会和提示符粘在一起
kubectl -n tenant-workshopXX get secret harbor-harbor-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

控制台（dashboard）的方便之处在于不用折腾 base64。命令的方便之处在于可以塞进脚本里。

在浏览器里打开这个地址并登录。你会看到 Harbor 界面，里面只有一个项目 `library`。

现在从终端做同样的事。`docker login` 会询问用户名和密码，并把凭据保存在你的笔记本电脑上，
放在文件 `~/.docker/config.json` 里。之后 `docker push` 和 `docker pull` 就不再多问，直接去
这个镜像仓库。

```bash
# login = 「记住这个镜像仓库的凭据」。
# 参数是 url 键里的镜像仓库地址；这里的 harbor-harbor.workshop03.example.org 是示例。
# 命令会询问用户名（admin）和密码；输入密码时不会显示。
docker login harbor-harbor.workshop03.example.org
```

从这里开始，文中的 `harbor-harbor.workshop03.example.org` 就是**你的**地址 —— 替换成你自己的。

**你应该看到：**

```
Login Succeeded
```

⚠️ **这次 `docker login` 教会了你的笔记本电脑登录镜像仓库 —— 而且仅仅是它。** 它对集群没做
任何事。记住这一点；在实验稍后你会用到它。

## 步骤 3. 建一个私有项目

📍 **在哪里：** 在浏览器里，在 Harbor 里。

**Projects** → **New Project**。

| 字段 | 值 | 为什么这样 |
|---|---|---|
| Project Name | `passes` | 每个服务一个项目 —— 这样分配权限更容易 |
| Access Level | **不要勾选 Public** | 安全部门要的是一个封闭的镜像仓库，而不是「你自己的、但对整个互联网开放」 |
| Storage quota | `-1`（无限制） | 在测试环境里，配额只会碍事 |

从一开始就在那里的 `library` 项目是公开的。从它那里拉取镜像根本不需要任何凭据。这正是我们
不用它的原因：它不会引出本实验就是围绕它搭建的那个访问错误。

## 步骤 4. 构建镜像

📍 **在哪里：** 在笔记本电脑上。

在本实验的目录里有 `app/` —— 「Passes」服务的源码和构建指令。开始构建之前，我们先看看里面
有什么。

<details>
<summary><b>细看：应用里面是什么</b></summary>

文件 `app/main.go`，大约七十行 Go 代码。它只做两件事。

**它对 `/healthz` 回答一个词 `ok`。** 这是就绪检查的地址：集群敲这里，在得到回答之前不会把
流量发给某个副本。

**它对 `/` 回答一小段 JSON**，在其中报告关于自己的信息：

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

应用怎么知道自己的名字、节点和 namespace？它**并不去查**。是集群在启动时把它们放进去的，
放进环境变量里：

```go
Pod:  env("POD_NAME", "неизвестно"),
Node: env("NODE_NAME", "неизвестно"),
```

而清单（manifest）里写明了要往里放什么：

```yaml
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
```

这叫做 downward API —— 「从上面递下来的信息」。在 vSphere 里最接近的类比是 VMware Tools 递进
机器里的来宾变量。区别在于，这里应用什么都不问、哪儿都不去：进程启动时，这些值就已经躺
在环境里了。既不需要连接集群 API 的客户端，也不需要对那个 API 的任何权限。

**应用里没有一个外部库，只有 Go 标准库。** 这不是故作姿态：带依赖的构建会去互联网取包，
而整个实验的开端就是安全部门禁止访问互联网。

文件 `app/Dockerfile` 是构建指令。它有两个阶段：

```dockerfile
FROM golang:1.23-alpine AS build
...
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

FROM alpine:3.21
COPY --from=build /out/passes-api /usr/local/bin/passes-api
```

第一个阶段是构建阶段。它需要整个 Go 编译器，大约 350 MB。第二个阶段才是真正发往集群的
东西：从第一个阶段只搬过来**编译好的那个二进制文件**，其余全部丢弃。

结果是一个大约十兆字节的镜像，而不是三百五十兆。这不只是大小的问题：里面没有编译器、
没有源码、没有包管理器。就算有人真的进了容器，也没有可以下手的东西。

把这和虚拟机模板的做法比一比。模板把整个操作系统都装在自己里面，如果编译器曾经进去过，
也一并带着。事后再把它缩小几乎是不可能的。

最后几行：

```dockerfile
RUN adduser -D -u 10001 app
USER 10001
```

应用不以 root 身份运行。在配置得当的集群里，Pod 不被允许以 root 运行，这不是我们挑剔，
而是你在任何现代集群里都会遇到的要求。

</details>

`docker build` 命令构建镜像：它读取 `Dockerfile`，执行其中描述的步骤，并把结果放进你笔记本
电脑上的镜像存储里。结果存放时用的名字由 `-t` 标志指定，由三部分组成：

| 部分 | 表示什么 |
|---|---|
| `harbor-harbor.workshop03.example.org` | 镜像仓库地址 —— 之后去哪里取镜像 |
| `passes/passes-api` | 镜像仓库内部的项目和名字 |
| `v1` | 版本标签 |

镜像仓库地址是镜像名字的一部分。这正是为什么迁移到自己的镜像仓库会改动每一份清单
（manifest）：镜像的名字变成了另一个。

开始构建。把地址替换成你自己的：

```bash
cd labs/06-harbor

# build = 「按 Dockerfile 构建镜像」。
#   --platform linux/amd64  为哪种处理器构建；集群节点是 x86，
#                           而笔记本电脑可能是 ARM —— 那样不加这个标志就会构建出不对的东西
#   -t <地址>/<项目>/<名称>:<标签>  给结果起什么名字。名字开头的镜像仓库地址
#                           就是之后 docker push 要发往的地方
#   app/                    最后一个参数 —— 装着 Dockerfile 和源码的目录；
#                           它的全部内容都会交给构建器
docker build --platform linux/amd64 -t harbor-harbor.workshop03.example.org/passes/passes-api:v1 app/
```

⚠️ **`--platform linux/amd64` 不是装饰。** 如果你用的是 Apple Silicon（M1–M4）的 Mac，或者
ARM 笔记本电脑，不加这个标志你就会构建出一个 ARM 镜像。它构建时不报错，推送时不报错，
可是在集群里 —— 那里的节点是普通的 x86 —— Pod 会陷入 `CrashLoopBackOff`，日志里会写
`exec format error`。这要花很长时间才能诊断出来，因为周围没有任何东西提示问题出在处理器
架构上。

**你应该看到** —— 关于各构建步骤的行，以及最后：

```
Successfully tagged harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

## 步骤 5. 把镜像发送到你的镜像仓库

📍 **在哪里：** 在笔记本电脑上。

构建好的镜像目前只存在于你的磁盘上。`docker push` 把它一层一层地发到镜像仓库；已经在
镜像仓库里的层不会再次发送。

```bash
# push = 「把镜像发到镜像仓库」。发往哪里，docker 从镜像名里取：
# 名字的第一部分是镜像仓库地址，就发往那里，用 docker login 得到的凭据。
docker push harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

**你应该看到** —— 各层被发送出去，最后是带着一长串哈希的一行，即 `digest`。

在浏览器里看看 Harbor：**Projects** → `passes` → 那里出现了一个仓库 `passes/passes-api`，
里面有标签 `v1`。你能看到大小、日期，以及那个相同的 `digest`。

那个 `digest` 就是镜像的确切内容。标签 `v1` 明天可以被重新指到另一个镜像上，谁都不会察觉；
而 `digest` 无法伪造。于是就有了每个人迟早都会学到的规则：**发往生产按 digest，而不是按标签。**

## 步骤 6. 部署到集群

📍 **在哪里：** 在笔记本电脑上，实验集群 `lab`。

```bash
# KUBECONFIG 告诉 kubectl 用哪个访问文件。我们切换到你的实验集群 `lab`：
# 从这里开始所有 kubectl 命令都发往它。
# 它一直生效，直到关闭终端窗口。
export KUBECONFIG=~/lab.kubeconfig
```

实验目录里有 `passes-broken.yaml`。它里面用一个占位符 `HARBOR-HOST` 代替了镜像仓库地址 ——
需要把它替换成你的地址。`sed` 来做这件事：它就地修改文件，不询问也不显示任何东西。选取
适合你系统的那一行：

```bash
# sed -i = 「就地修改文件」
#   's|什么|换成什么|g'  替换所有出现处；分隔符用 | 而不是 /，因为
#                     地址里有斜杠，用 / 就得转义
#   macOS 的 sed 在 -i 后面必须跟一个参数；空引号
#   表示「不做备份」。Linux 上则不能有这个参数。

# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
```

应用它：

```bash
# apply = 「把集群变成文件里描述的样子」
kubectl apply -f passes-broken.yaml

# get pods = 「显示 Pod」。
#   -l app=passes-api  只显示带这个标签的，而不是全部
#   -w                 不退出，随着变化出现就打印出来；
#                      停止观察 —— Ctrl+C
kubectl get pods -l app=passes-api -w
```

**你会看到** —— 而且这不是你所期待的：

```
NAME                          READY   STATUS             RESTARTS   AGE
passes-api-6c9d4f7b8-2xk4n    0/1     ErrImagePull       0          8s
passes-api-6c9d4f7b8-2xk4n    0/1     ImagePullBackOff   0          22s
```

用 `Ctrl+C` 停止观察，看看集群怎么说：

```bash
# describe = 「详细讲讲这个对象」。输出的最末尾是事件日志：
# 集群对这个 Pod 做了什么尝试、结果如何。
# tail -12 保留最后十二行 —— 事件正好在那里。
kubectl describe pod -l app=passes-api | tail -12
```

```
  Warning  Failed   kubelet  Failed to pull image
    "harbor-harbor.workshop03.example.org/passes/passes-api:v1":
    failed to resolve reference: unexpected status from HEAD request: 401 Unauthorized
```

> **在继续读下去之前，停下来想一想。**
>
> 你刚刚用 `docker login` 成功登录了镜像仓库，也成功把镜像发了过去。镜像仓库认识你。
> 为什么集群却被拒绝了？

<details>
<summary><b>答案，以及一个比这个错误更宽泛的教训</b></summary>

**下载镜像的不是你。** 是 `kubelet` 下载的 —— 集群节点上的一个服务。那是另一台机器、
另一个进程、另一个用户。

你的 `docker login` 把凭据写进了**你笔记本电脑上**的文件 `~/.docker/config.json`。集群节点对
这个文件一无所知，也不可能知道：它和你的笔记本电脑之间根本没有任何共同点，除了你会往那里
发命令这一点之外。

回到实验稍早处 `docker login` 之后的那条警告。它说的正是这件事，只是当时后果还看不出来。

**正确的做法。** 凭据需要放进集群本身 —— 放进一个特殊种类的 Secret 对象里 —— 然后应用的
清单（manifest）里要写明下载时用哪个 secret。这样的 secret 叫做 `imagePullSecret`。

**为什么集群需要单独的凭据，而不是你的。** 三个原因，三个都很实际。

第一：你可能不在。某个节点会在凌晨三点重启，然后又去下载镜像。如果它用的是你的账号，
一切就都取决于你还在这家公司干、你的密码还没过期。

第二：权限不同。你需要向镜像仓库**写入**的权限，以便把构建发过去。集群只需要**读取**。
给集群从镜像仓库删除镜像的权限是个糟糕的主意，而用你的账号，你恰恰就给了它这个权限。

第三：留下的痕迹不同。当镜像仓库日志显示镜像是由 `robot$passes-puller` 而不是 `admin` 下载
的时候，事故调查才成为可能。

**为什么不直接配置节点。** 你可以把凭据直接放在节点上，放进容器运行时的配置里 —— 那样就
不需要 `imagePullSecret` 了。有人有时确实这么做。但集群里的节点是一次性的：升级时被重建，
负载增长时被添加，故障时被杀掉。手工在节点上做的设置，只能活到该节点第一次被替换。而集群
里的 secret 能挺过任何替换。

**一个比这个错误更宽泛的教训。** `ImagePullBackOff` 几乎总是三种情况之一：镜像名字里有拼写
错误、没有凭据，或者镜像存在但不是对应正确处理器架构的。别看 Pod 的状态，去看
`kubectl describe pod` —— 真正的原因写在那里。

</details>

## 步骤 7. 授予集群访问镜像仓库的权限

📍 **在哪里：** 在笔记本电脑上，实验集群 `lab`。

我们创建一个带镜像仓库凭据的 secret。`create secret` 命令有一个专门的变体，能做出一种
`kubelet` 在下载镜像时可以自行读取的 secret：

```bash
# create secret docker-registry = 「创建一个带镜像仓库凭据的 secret」
#   harbor             这个 secret 在集群内的名字；应用清单会引用它
#   --docker-server    这些凭据是给哪个镜像仓库的 —— 和镜像名里一样的地址
#   --docker-username  谁在登录
#   --docker-password  密码；如果里面有 $、! 或空格，就需要用单引号
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password='YOUR-PASSWORD'
```

⚠️ **命令行上的密码会留在 shell 历史里。** 在测试环境里这无所谓，在正式工作环境里就有所谓。
一种不留历史的办法：

```bash
# read 把从键盘输入的内容放进 HARBOR_PASS 变量：
#   -s  不在屏幕上显示输入的内容
#   -r  不把反斜杠当作特殊字符
# 这一行之后屏幕上不会出现任何东西：粘贴密码并按回车。
read -rs HARBOR_PASS

# 从这里开始密码从变量里替换进来，所以进入 shell 历史的只有变量名。
# 双引号是必须的：没有它们，空格会把值拆断。
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password="$HARBOR_PASS"

# unset 清除变量，这样密码不会传到本窗口后续的命令里
unset HARBOR_PASS
```

<details>
<summary><b>这个 secret 里面是什么，以及它为什么有单独的类型</b></summary>

我们来问问集群，做出来的是什么种类的 secret：

```bash
#   -o jsonpath='{.type}'  打印对象的单个字段 —— secret 的类型
#   {"\n"}                 补一个换行，否则输出会和提示符粘在一起
kubectl get secret harbor -o jsonpath='{.type}{"\n"}'
```

```
kubernetes.io/dockerconfigjson
```

这个 secret 有一个**类型**，而且它不是装饰性的。普通的 secret 就是一组键值对，拿它们做什么
由应用决定。类型为 `kubernetes.io/dockerconfigjson` 的 secret 则由 `kubelet` 自己理解：它知道
里面是一个与 `~/.docker/config.json` 相同格式的文件，并且能在下载镜像时使用它。

查看内容（那里的密码是 base64 —— 这**不是加密**，而是把二进制数据写成文本的一种方式，
谁都能解码）：

```bash
# .data.\.dockerconfigjson —— secret 里的键。这个键名本身以点开头，
# 所以要转义：否则 jsonpath 会把它当成路径分隔符。
# base64 -d 把值解码回文本 —— 你会看到和你笔记本电脑上
# ~/.docker/config.json 文件里一样的格式。
kubectl get secret harbor -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

由此得出一件重要的事：**Kubernetes 里的 Secret 默认不加密**，它只是被访问权限隔开而已。
谁能读取 namespace 里的 secret，谁就能看到密码。要体面地处理这件事，是另一个关于密钥存储
的实验。

**实战中怎么做。** 不用 `admin` 账号。Harbor 有机器人账号：**Projects** → `passes` →
**Robot Accounts** → 创建一个只有 `pull` 权限的机器人。机器人的凭据放进 `imagePullSecret`，
这样集群里的 secret 一旦泄露，只意味着有人能下载你的镜像 —— 讨厌，但不致命。而 `admin`
泄露则意味着有人能把它们替换掉。

我们用 `admin` 是为了不把实验拖长。你要知道这是一种简化。

</details>

现在应用正确的清单（manifest）。先做和之前一样的地址替换，只是换个文件；然后移除坏掉的
应用，装上能工作的：

```bash
# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml

# delete -f = 从集群里删除文件中描述的那些对象
kubectl delete -f passes-broken.yaml
kubectl apply -f passes.yaml

# rollout status 会等到新副本就绪后自行结束。
# 如果等不到，它会返回错误，所以这样一行放在脚本里很方便。
kubectl rollout status deployment/passes-api
```

**你应该看到：**

```
deployment "passes-api" successfully rolled out
```

能工作的清单和坏掉的清单之间的区别，恰好是两行：

```yaml
      imagePullSecrets:
        - name: harbor
```

## 步骤 8. 看看结果如何

📍 **在哪里：** 在笔记本电脑上，实验集群 `lab`。

应用没有对外暴露，但你需要看看它。`port-forward` 从笔记本电脑往集群里挖一条隧道：命令运行
期间，发往 `localhost:8080` 的请求会去到 `passes-api` service。最接近的类比是在 NAT 网关上做
一个临时的端口转发，只不过完全不用动网络。

```bash
# port-forward svc/passes-api = 通往 service 的隧道，而不是通往某个具体的 Pod
#   8080:80 —— 左边的数字是笔记本电脑上的端口，右边是集群里 service 的端口
# 别关窗口：命令运行多久，隧道就存活多久。
kubectl port-forward svc/passes-api 8080:80
```

在另一个终端窗口里：

```bash
# curl —— 「去这个地址并显示返回」。
#   -s     不显示进度指示器
#   ; echo 补一个换行：返回是单独一行，没有它
#          就会和 shell 提示符粘在一起
curl -s http://localhost:8080/; echo
```

**你应该看到** —— 一段 JSON，应用在其中报告是哪个副本作出了应答、它运行在哪个节点上、
从哪个镜像仓库来的：

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

应答里的 `pod` 字段是作出应答的那个副本的名字。把它和副本列表对一对：

```bash
# 新终端窗口对 KUBECONFIG 变量一无所知 —— 这里也要设一遍，
# 否则 kubectl 会去错误的集群
export KUBECONFIG=~/lab.kubeconfig

# 同样按标签筛选：列表里应该包含你在返回里看到的那个名字
kubectl get pods -l app=passes-api
```

把请求重复几次 —— 名字会一直是**同一个**，这不是故障。`port-forward` 在启动的那一刻挑一个
副本，并把隧道一直保持到那一个，直到 `Ctrl+C`；这条路径上根本没有负载均衡。负载均衡在
`Service` 上有，但你只能从集群内部看到它 —— 从外部你是在和一个具体的 Pod 对话。

你可以这样真正地检验负载均衡 —— 从一个活在集群内部的临时 Pod 发出八个请求：

```bash
# run 起一个一次性的 Pod，--rm 用完后清理掉它。
# -- 之后的一切都在 Pod 内部运行：八次通过内部名字访问 service，
# 并打印出应答副本名字所在的那一行。
kubectl run probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
  -- sh -c 'for i in $(seq 1 8); do curl -s http://passes-api/ | grep -o "passes-api-[a-z0-9-]*"; done'
```

**你应该看到：** 两个不同的名字混在一起 —— 这就是 `Service` 把请求分摊到各个副本上。

关闭隧道 —— 在第一个窗口里按 `Ctrl+C`。

闭合这个循环：在浏览器里进入 Harbor，进入 `passes` 项目。在 `passes/passes-api` 仓库上，
下载计数器（**Pulls**）已经变成非零。你的集群确实正是来了这里。

## 验证

📍 **在哪里：** 在笔记本电脑上，在你刚才使用 `kubectl` 的同一个终端窗口里。

脚本会同时访问两个集群，并从环境变量里取得它们。前两个是必需的，第三个是租户 kubeconfig
的路径。

```bash
cd labs/06-harbor

# 在哪个集群里检查应用 —— 你的 `lab`
export KUBECONFIG=~/lab.kubeconfig
# 你的租户编号：脚本据此拼出 namespace 名字 tenant-workshop03
export COZY_TENANT=workshop03
# 管理集群的访问文件在哪里 —— 脚本会去那里查看 Harbor 本身。
# 也可以不设：那样脚本会去找 ~/.kube/workshop，找不到就跳过
# 管理集群上的检查，并作出说明。
export COZY_KUBECONFIG=~/.kube/workshop

./check.sh
```

⚠️ **在 Windows 上脚本从 WSL 里运行**，不是从 PowerShell —— 怎么安装它写在实验 0 的开头。
没有 WSL 也能做实验，但不会有产物报告。

脚本检查的不是 Harbor 被创建这一事实，而是实质上的运作：镜像仓库通过它的 API 作出应答，
集群里的应用是从躺在你自己镜像仓库里的镜像启动的，带凭据的 secret 存在并指向同一个地址，
而 service 本身返回一段 JSON，里面是一个确实存在的 Pod 的名字。

## 清理

下一个实验会用到这个应用和 Harbor —— 现在先别删。

当你做完所有实验之后：

```bash
# 删除文件里描述的对象：Deployment 和 Service 都删
kubectl delete -f passes.yaml
# 这个 secret 是用命令创建的，不是用文件 —— 按名字删除
kubectl delete secret harbor
```

Harbor 本身通过控制台（dashboard）删除，跟任何普通应用一样。随它一起，层存储也会消失 ——
这是十几秒的事，而不是一张报废虚拟机的申请单。

值得弄清楚你到底在删的是什么。镜像仓库不仅是镜像躺着的地方，也是对「过去一年我们究竟往
生产发布了什么」这个问题的唯一答案。在正式工作环境里像这里一样轻易地把它删掉，是你不会
想干的事。

## 现在我们会做什么

- 给自己搭一个镜像仓库，并说清楚它和 Content Library 有何不同
- 用两阶段构建来构建镜像，并理解为什么结果会小三十倍
- 把笔记本电脑上的 `docker login` 和集群需要的访问权限区分开
- 读懂 `ImagePullBackOff`，并在 `describe pod` 里找到真正的原因
- 通过 downward API 把 Pod 关于自身的信息交给它，而不授予它对集群 API 的权限

## 在 vSphere 里这会是

镜像仓库最接近的类比是 Content Library。相似之处是有的：两者都存放镜像并把它们分发给机器，
两者也都能做权限和站点间的同步。

除此之外它们就分道扬镳了，而且区别不在细枝末节上。

**Content Library 整份复制模板。** 镜像仓库分发层，并且相同的层只存一份。如果你有二十个服务
都基于同一个 Alpine 基础镜像，这个基础镜像在镜像仓库里只有一份，当第二十一个服务启动时，
节点只会下载它自己那一层 —— 区区几兆字节。

**模板靠名字，镜像靠寻址。** 镜像有一个 digest —— 其内容的哈希。凭它你可以验证你运行的正是
你构建的那份代码，而非别的。模板没有这种东西：你只能指望没人把它换掉。

**镜像仓库是一个 HTTP 服务。** 由此引出了整件事的意义所在：流水线里的构建用一条命令把镜像
放上去，集群用另一条命令把它取下来，没有人手工挂载存储或在站点之间复制文件。

**老实说，vSphere 更方便的地方。** 三件事。

Content Library 不要求你对凭据懂任何东西。连上它 —— 就能用。而在这里你得单独向集群解释如何
访问镜像仓库，而且你在这上面栽了跟头，就像所有人一样。

vCenter 里的权限是统一的。一个账号管一切：机器、库、网络。而在这里，控制台（dashboard）里
的权限、集群里的权限和 Harbor 里的权限是三套不同的东西，必须保持彼此一致。这就是镜像仓库
作为一个独立产品、而非平台一部分所付出的代价。

模板可以被修改。你从模板部署一台机器，进一步调优，再截取一个新模板 —— 而确切的操作步骤
没有记录在任何地方这一点，并不妨碍什么。镜像不是这样构建的：如果构建无法从 `Dockerfile`
复现，你就有麻烦了。这种纪律是有用的，但习惯它很难，而假装并非如此是愚蠢的。
