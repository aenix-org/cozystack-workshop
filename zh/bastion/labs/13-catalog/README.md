# 实验 13 · 把你自己的应用放进 Cozystack 目录

| | |
|---|---|
| **时长** | 40 分钟 |
| **能证明什么** | 平台目录是开放的：你自己的应用就摆在里面，紧挨着 Redis 和虚拟机 |
| **需要什么** | bastion（跳板机）上的 `helm`、`kubectl`、租户访问权限。这里不需要实验集群 `lab` |

## 为什么这很重要

「访客通行证」已经跑起来了。一周后，子公司听说了这件事——他们有一样的前台，一样的问题。再过一周，第二家子公司也找上门来。

对前两家你是口头讲的：用哪些镜像、哪份配置、哪些参数、先起哪个。到第三次时已经很清楚，这样下去不行。讲解只装在一个人的脑子里，这样的脑袋只有一个，而公司会有五家。

你需要的是让「访客通行证」像 Redis 那样出现在他们面前：目录里的一个条目、一张带参数的表单、一个按钮。用不着你。

这就是本次工作坊的收尾。我们走完了从「给我部署一个 Pod」到「这是一个内置了我们服务的平台」的整条路。

## 先说要紧的：你的权限到哪里为止

这个实验**不会**把应用部署进目录。这并不是因为我们没来得及写那部分。

`ApplicationDefinition` 对象——就是把应用注册进目录的那个——是 **cluster-scoped** 的：整个集群只有一个，它没有 namespace，而且它一次就改变了所有租户的目录。租户创建不了这样的对象。你现在就可以自己验证：向集群询问自己的权限，无需创建任何东西。

```bash
# KUBECONFIG —— kubectl 从中读取集群地址和你的登录凭据的变量。
# 这里它指向租户访问，和其它每个实验里用的是同一个文件。
export KUBECONFIG=~/.kube/config
# auth can-i = “我可以做这个吗？”。集群回答 yes 或 no，什么都不改变：
#   create                   我们要检查的动作
#   applicationdefinitions   针对哪种类型的对象
kubectl auth can-i create applicationdefinitions
```

**你会看到：**

```
no
```

这里没有绕过的办法，也不打算有。所以这个实验被诚实地设计成这样：**你写 chart 和应用定义，在本地验证它们，然后交给平台管理员。** 现实中就是这样运作的：构建目录和运营它，是两个不同的角色。

用熟悉世界里的类比：OVF 模板的内容由你准备，但把它放进公用的 Content Library，是由拥有那个库权限的人来做。

## 小词典

| 术语 | 是什么 | 像……但是 |
|---|---|---|
| **Helm** | 带参数和版本的清单模板化工具 | 最接近带输入字段的 OVF 模板，但它是文本、放在 Git 里 |
| **Chart（chart）** | 一个 Helm 包：模板、默认值、schema | 一个 **OVF 模板**，但在同一处用不同参数被部署很多次 |
| **Release（release）** | chart 以自己名字进行的一次具体部署 | 一台**从模板部署出来的 VM**，但它记得自己的版本历史，能够回滚 |
| **values** | 部署 chart 时用的参数 | **OVF 部署向导的字段**，但是纯 YAML，和其它一切一起放在 Git 里 |
| **values.schema.json** | 对允许值的描述 | **向导里的字段校验**，但它在应用之前检查，而不是在过程中 |
| **ApplicationDefinition** | 平台目录里的一个条目：展示什么、部署什么 | **Content Library 里的一个条目**，但整个集群只有一个、对所有租户可见 |
| **Namespace** | 集群里存放某一个所有者对象的区段 | 一个**文件夹或资源池**，但权限的边界沿着它划：你的租户就是一个 namespace |
| **Cluster-scoped** | 没有 namespace、在整个集群共享的对象 | 一项 **vCenter 级别的设置**，但它的权限属于平台团队，不属于租户 |
| **CRD** | 往 Kubernetes 里添加一种新对象类型的方式 | 一经注册，你的类型就和内置类型无从区分 |

## 实验文件夹里有什么

每个文件都已经在那里——你连同仓库一起拿到了。不需要再创建或重新敲：下面凡是写了 `kubectl apply -f name.yaml` 的地方，文件都从这里取。

```bash
cd labs/13-catalog
```

| 文件 | 是什么 | 什么时候用得上 |
|---|---|---|
| `chart/` | 你的应用，为目录打好包：模板、values、表单字段 schema | 你在本地阅读并验证它 |
| `applicationdefinition.yaml` | 目录条目的描述：它叫什么、在控制台里展示什么 | 你尝试 apply 它，以便看到权限被拒绝 |
| `guestpass-example.yaml` | 你的应用发布之后，下单它会是什么样子 | 你阅读它；只有在发布之后才能 apply |
| `icon.svg`、`icon.b64` | 条目的图标——源文件和它转成字符串的样子；已经嵌进定义里 | 如果你日后改图标就用得上 |
| `check.sh` | 检查 chart 能渲染、集群能接受它 | 你在实验末尾运行它 |

## 步骤 1. 看看我们在打包什么

`chart/` 文件夹里放着一个做好的「访客通行证」 chart。里面的应用故意做得很简单——一个带页面的 nginx——因为这个实验讲的不是应用，而是打包。

```
chart/
├── Chart.yaml            名称、版本、描述
├── values.yaml           参数和默认值
├── values.schema.json    把哪些值视为合法
└── templates/
    ├── configmap.yaml    页面和 nginx 配置
    ├── deployment.yaml    应用本身
    └── service.yaml      地址
```

<details>
<summary><b>细看一眼：chart 里面有什么</b></summary>

### `Chart.yaml` —— 身份证

```yaml
name: guest-pass
version: 0.1.0
appVersion: "1.0"
```

两个不同的版本号，它们老是被搞混。

`version` 是 **chart**（也就是打包）的版本。改了个模板、加了个参数、修了描述里的一个错别字——就把它加一。

`appVersion` 是里面**应用**的版本。它在「访客通行证」本身出新版本时才变，和打包版本没有任何关系。

实际意义在于：管理员从 `version` 能看出是不是部署机制本身在更新，从 `appVersion` 能看出是不是人们真正在用的东西在更新。

### `values.yaml` —— 参数

```yaml
## @param {int} replicas=2 - Number of application replicas.
replicas: 2

## @param {string} greeting=Order a pass for your guest - Text shown on the main page.
greeting: "Order a pass for your guest"

## @param {bool} external=false - Enable external access from outside the cluster.
external: false
```

`## @param` 注释不是装饰，也不是给人看的文档。Cozystack 的生成器（`cozyvalues-gen`）根据它们构建 `values.schema.json` 以及 chart README 里的参数表。单一事实来源：改了注释，重新生成 schema，控制台里的表单就随之改变。

格式是严格的：`## @param {类型} 名称=默认值 - 描述。`

参数故意很少。每多一个参数，就是表单里多一个字段、多一种把应用部署错的方式、多一个要你维护的分支。一个好的 chart 让你配置各次安装之间真正有差异的东西，仅此而已。

### `values.schema.json` —— 把什么视为合法

这个 schema 由 Helm 在任何东西发往集群**之前**检查。就地验证一下：往一个数值参数里塞一个字符串。

```bash
# template = “把 chart 里的清单组装出来并打印”，集群不受触碰：
#   gp                    chart 名义上部署所用的 release 名称
#   chart                 放 chart 的文件夹
#   --set replicas=abc    直接在命令行上覆盖单个参数
helm template gp chart --set replicas=abc
```

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
guest-pass:
- at '/replicas': got string, want integer
```

错误在 bastion 上半秒内就被抓住了。没有 schema 的话，它会一路开到集群，变成一个永远建不出来的 Deployment，还带着三屏长的消息。

这份 schema 会一字不差地进到 `ApplicationDefinition` 里——在那里它会长成控制台里的创建表单。

### `templates/configmap.yaml` —— 页面

```yaml
    <h1>{{ .Values.greeting }}</h1>
```

这正是模板化工具存在的全部理由：一个来自 `values` 的值在渲染时落进清单里。没有 Helm 的话，你就得为每家子公司保留一份清单副本，手工去改它们。

### `templates/deployment.yaml` —— 应用

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

人人都会忘掉的那行，之后要花一小时调试的那行。

Kubernetes **在 ConfigMap 变化时不会重启 Pod**。你改了文本，做一次更新，控制台显示「已更新」，可页面上还是旧的问候语。带着配置哈希的这个 annotation 会随配置一起改变，而 Pod 模板里 annotation 的改变本身就是 Pod 自身的改变，于是集群会重建它。

```yaml
            requests:
              cpu: {{ .Values.resources.cpu | quote }}
```

这里 `quote` 是必须的。不加引号，YAML 会把值 `100m` 读成字符串，却把 `1` 读成数字，两次里有一次你会拿到类型错误。引号一下子消除了这整类问题。

### `templates/service.yaml` —— 地址

```yaml
  type: {{ if .Values.external }}LoadBalancer{{ else }}ClusterIP{{ end }}
```

一个布尔参数就决定了应用是否获得集群之外的地址。Cozystack 内置的应用正是这么做的——它们大多数都有一个恰是这个含义的 `external` 字段。在目录里遵循别人的约定是值得的：在你之前部署过三个托管服务的人，会在同一个地方、用同一个名字去找这个字段。

</details>

## 步骤 2. 在本地验证 chart

📍 **在哪：** 在 bastion 上（在它的终端里）。这一步不需要集群。

先是 linter。它把 chart 当作一组文件来读，抓出结构性错误：缩进不对、丢了一个必填字段、一个解析不了的模板。

```bash
cd labs/13-catalog
# lint = “检查这个包的格式错误和必填字段”
#   chart   chart 文件夹的路径；Helm 期望它里面有 Chart.yaml、values.yaml
#           以及 templates/ 文件夹
helm lint chart
```

**你应该看到：**

```
==> Linting chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

`[INFO]` 是一条提示，不是错误：这个 chart 没有 `icon` 字段。对于 Cozystack 目录来说反正也不需要它，图标是从 `ApplicationDefinition` 里取的，我们后面会讲到。

现在是渲染。模板就是一份清单，其中一部分值被形如 `{{ .Values.replicas }}` 的占位替换。渲染就是把模板变成成品清单：Helm 从 `values.yaml` 取值，代入文本，把结果打印出来。

```bash
# main —— release 名称，也就是这次具体部署 chart 的名字。它会进到所创建对象的
# 名字里，所以两次并排的安装不会在名字上冲突。
helm template main chart
```

输出的是普通清单，和你在头几个实验里手写的那些一样。Helm 没什么魔法：它把值代入文本。

验证一下参数是否真的到达了清单。我们用不同的值渲染两次，只在输出里保留本该变化的那一行。

```bash
# --set replicas=5 在一次运行期间覆盖 values.yaml 里的值。
# | grep 'replicas:' —— 从全部输出里只保留含这个词的行。
helm template main chart --set replicas=5 | grep 'replicas:'
# 对布尔参数同理：external 决定清单里最终是哪种 Service 类型
helm template main chart --set external=true | grep 'type:'
```

```
  replicas: 5
  type: LoadBalancer
          type: RuntimeDefault
```

第三行不是错误，也不是你打错了。`grep` 在整段文本里搜这个词，而 `type:` 还出现在安全要求里（`seccompProfile`）。这是一个有用的提醒：`grep` 不懂 YAML 结构——它找的是行，不是字段。

⚠️ **`helm template` 什么都不往集群发，也不在集群那侧做任何检查。** 它渲染文本。一份通过了 `helm template` 的清单，仍可能被集群拒绝——比如因为缺少某个 CRD。它是一个便宜的检查，不是完整的检查。

## 步骤 3. 拆解 ApplicationDefinition

chart 知道怎么部署应用。但目录还不知道它：为了让「访客通行证」在控制台里以列表形式出现、并成为 API 里的一种对象类型，还需要一个文件。

它就在旁边——`applicationdefinition.yaml`。

<details>
<summary><b>细看一眼：applicationdefinition.yaml 里面有什么</b></summary>

```yaml
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: guest-pass
```

注意这里**没有**什么：`namespace` 字段。这正是这个对象 cluster-scoped 的本性。整个集群只有一个，而它产生的那个目录条目会被所有租户一齐看到。

### `application` 块 —— 这在 API 里长什么样

```yaml
  application:
    kind: GuestPass
    plural: guestpasses
    singular: guestpass
```

这个文件被 apply 之后，集群里就出现了一种新的对象类型。不是「集成」，也不是「插件」——而是一个完整的类型，你用普通的 `kubectl` 就能操作它。管理员一旦 apply 了这个定义，下面这两条命令对任何租户都能用：

```bash
# get = “给我看看有什么”。guestpasses 就是下面 plural 字段里的那个名字：
#   -n tenant-workshopXX   在哪个 namespace 里看；把 XX 换成你自己的编号
kubectl get guestpasses -n tenant-workshopXX
# describe = “给我看看某一个对象的一切”：参数、状态、最近的事件。
# 这里的 main 是某个具体下单的应用的名字，不是类型的名字。
kubectl describe guestpass main -n tenant-workshopXX
```

`plural` 是代入命令和 API URL 的那个。`singular` 是你在 `kubectl describe` 里写的那个。两者都用小写、不带空格——这是 Kubernetes 的要求，不是风格问题。

```yaml
    openAPISchema: |-
      {"title":"Chart Values","type":"object","properties":{...}}
```

和 chart 里作为 `values.schema.json` 文件存在的是同一份 schema，只是写成了一行 JSON。它在两个地方起作用：API 拒绝非法的值，而控制台根据它画出创建表单——字段类型、默认值、提示。

⚠️ **这里的 schema 和 chart 里的 schema 必须一致。** 它们之间没有任何自动联系：这是两个文件，让它们保持同步是你的活儿。让它们漂开，控制台里的表单就显示一套字段，而 chart 期望的是另一套。`check.sh` 会替你交叉核对它们，但养成做这个检查的习惯是值得的。

### `release` 块 —— 部署什么

```yaml
  release:
    prefix: guest-pass-
```

release 名称由前缀和对象名拼成：一个名为 `main` 的 `GuestPass` 会部署成名为 `guest-pass-main` 的 release。这个字段是必填的。它的用处是让不同应用的 release 在同一个 namespace 里不撞名：叫 `main` 的东西有很多，而 `guest-pass-main` 只属于你。

```yaml
    labels:
      sharding.fluxcd.io/key: tenants
```

一个 Cozystack 的服务性标签：租户们的 release 靠它在 Flux 的处理器之间分配。没有它，就没人来服务这个 release，它会一直挂着等。这里不是发挥主观能动性的地方——原样照抄。

```yaml
    chartRef:
      kind: HelmChart
      name: cozystack-guest-pass
      namespace: cozy-public
```

从哪里取 chart。`kind` 的合法值有三个：`OCIRepository`、`HelmChart`、`ExternalArtifact`。

外部目录通常沿着 `GitRepository` → `HelmChart` 这条链到达：管理员把你的仓库作为源添加到 `cozy-public` namespace 里，Flux 从中拉出 chart，而 `ApplicationDefinition` 引用那个 chart。`cozystack/external-apps-example` 里展示的正是这条路径，从它入手是明智的。

⚠️ **`chartRef` 里的名字不是你一个人说了算的。** 它们必须和管理员注册源的方式一致。在你把文件发出去之前先商定好——否则定义会 apply 成功，可就没东西能部署了，而这个错误只会在第一个点「创建」的人那里才浮现出来。

### `dashboard` 块 —— 这在界面里长什么样

```yaml
  dashboard:
    category: PaaS
    singular: Guest Pass
    plural: Guest Passes
    description: Internal guest pass service for employees and reception
    tags: [internal, web]
```

`category` 是目录的分区。Cozystack 用了五个：`PaaS`、`IaaS`、`NaaS`、`Administration`、`Networking`。选一个现成的。搞一个自己的分区，意味着一个只有一个条目的分区，没人会在那儿找到你的应用。

这里的 `singular` 和 `plural` 是**给人看的**名字，带空格和大写字母。别和 `application` 块里的那些搞混：那些是给 API 的，这些是给眼睛的。

```yaml
    icon: PHN2ZyB3aWR0aD0iMTQ0IiBoZWlnaHQ9IjE0NCIgdmlld0JveD0iMCAwIDE0NCAxNDQi...
```

图标是一个用 base64 编码的 SVG。是编码，不是路径也不是链接：控制台不会跑去哪里下载它，图片就存在对象本身里。

源文件就在旁边，在 `icon.svg` 里，做好的字符串在 `icon.b64` 里。如果你改了源文件，字符串就得重新生成。编码器默认会把输出拆成多行，而 `icon` 字段需要一整条连续的字符串——所以换行符要在单独一步里去掉。

```bash
# base64 = 把一个二进制文件转成由字母、数字和 + / = 符号组成的字符串
#   -i icon.svg   要编码什么（macOS 和 BSD 的选项写法）
# tr -d '\n' = 把输出里的每一个换行符都丢掉，粘成一整条
base64 -i icon.svg | tr -d '\n'
```

在 Linux 上同一条命令的选项不同：`base64 -w0 icon.svg`，其中 `-w0` 意思是“完全不要给输出换行”。GNU 和 BSD 的选项写法在这里对不上。

144×144 的画布尺寸和平台内置的图标一致。不需要更大：在目录里它画得很小。

```yaml
    keysOrder: [["apiVersion"], ["kind"], ["metadata"], ..., ["spec", "replicas"], ...]
```

对象 YAML 表示里字段的顺序。是美观问题，但没有它，字段就排得乱七八糟——很少用的 `resources` 排在前，主要的 `replicas` 排在后——表单读起来比它本可以的样子要差。

</details>

## 步骤 4. 试着 apply —— 然后被拒绝

📍 **在哪：** 在 bastion 上，用租户访问。

文件做好了、语法也没问题——我们就当权限够用，试着去 apply 它。拒绝会来自集群，而不是来自 `kubectl`，而拒绝的文字会准确说出到底缺了什么。

```bash
# 租户访问 —— 就是你整个工作坊里一直用的那个
export KUBECONFIG=~/.kube/config
# apply = “让集群与文件里写的内容一致”；-f —— 从文件读取
kubectl apply -f applicationdefinition.yaml
```

**你会看到：**

```
Error from server (Forbidden): error when creating "applicationdefinition.yaml":
applicationdefinitions.cozystack.io is forbidden: User "workshopXX" cannot create
resource "applicationdefinitions" in API group "cozystack.io" at the cluster scope
```

拒绝在意料之中：实验一开始就讲过。这里有内容的是最后四个词——**at the cluster scope**。

<details>
<summary><b>答案，以及一个比这个错误更宽泛的教训</b></summary>

你在租户里的权限是一个 namespace 内部的权限。你是自己那块地的完全主人：你起集群、起数据库、起 VM，删掉它们、弄坏它们、修好它们。你的对象没有一个对邻居可见、也不会妨碍邻居。

`ApplicationDefinition` 是另一种构造。它**一次就改变所有租户的**目录。一个 schema 里有错的应用，由你 apply 后，会被其它部门的人看到并尝试部署。一个和已有应用同名的应用，会把那个已有的弄坏。

正因如此，边界正划在这里，而它无关不信任。vSphere 里也是一样：你在自己的池里自己创建自己的 VM，而公用 Content Library 的内容以及对它的权限——不归你。

**实际该怎么做。** 把两个文件和一项约定交给平台管理员：

| 交出什么 | 为什么 |
|---|---|
| `applicationdefinition.yaml` | 对象本身，他会去 apply 它 |
| 一个指向放着 chart 的仓库的链接 | 管理员据此在 `cozy-public` 里构建源 |
| `chartRef` 里商定好的名字 | 好让定义能找到 chart |

发送之前要检查两个文件都没问题——因为这里的反馈回路很长：管理员 apply 它，看到错误的却是第三个人。

</details>

拒绝也可能来自文件本身的错误。我们把两者分开：先问权限，再让 `kubectl` 把整个文件解析一遍，却不把它发到任何地方。

```bash
# auth can-i = “我可以做这个吗？”。回答是 yes 或 no，集群不受改动。
kubectl auth can-i create applicationdefinitions
# --dry-run=client = “解析文件、展示会得出什么，但不要去集群”。
# client 意味着整个检查都在 bastion 上进行，集群甚至不会听说这件事。
kubectl apply -f applicationdefinition.yaml --dry-run=client
```

**你应该看到。** 第一条命令——`no`。第二条——`applicationdefinition.cozystack.io/guest-pass created (dry run)`：文件被解析了，语法没问题，问题真的在权限上。

⚠️ **`--dry-run=client` 只检查语法。** 它根本什么都不问集群。`--dry-run=server` 会问，但那需要的恰是缺失的那份权限。

## 步骤 5. 子公司们会看到什么

管理员 apply 定义之后，目录就多了一个条目。从那一刻起，任何租户部署「访客通行证」都和他们当初部署 Redis 一样：**创建应用** → `Guest Pass` → 一张由你那四个参数生成的表单 → 一个按钮。

或者用文本——这个文件夹里的 `guestpass-example.yaml`：

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: GuestPass
metadata:
  name: main
  namespace: tenant-workshopXX
spec:
  replicas: 2
  greeting: "Order a pass for your guest"
  external: false
```

注意这个组：`apps.cozystack.io`——和 `Bucket` 与 `VMInstance` 是同一个。你的应用**和内置的那些站在了同一排**，而不是被挤到一边。它在租户的应用列表里同样地被看到，它的资源同样地被计入，权限同样地生效。

⚠️ 在管理员注册定义之前，你无法 apply 这个文件：`kubectl` 会回答 `no matches for kind "GuestPass"`——集群里还没有这种对象类型。

## 步骤 6. 怎么不用手把这一切都写出来

你在这个实验里拆解的一切都是骨架：`Chart.yaml`、`values.yaml`、schema、模板、带正确名字和标签的 `ApplicationDefinition`。文件的一半是各处都一样的必填字段，而在它们上面写错比写对还容易。

为此有一个现成的工具。

| 什么 | 在哪 | 为什么 |
|---|---|---|
| `cozystack/ccp` 仓库 | github.com/cozystack/ccp | 一套给 Claude Code 用的插件和 skill |
| `cozystack` 插件 | 从那里 | 教会 Claude Code 认识 Cozystack 包的结构 |
| `external-app-create` skill | 在插件里 | 生成整个外部应用的骨架 |
| 示例仓库 | github.com/cozystack/external-apps-example | 一个带 chart 构建和发布的可用示例 |

这个 skill 会询问应用名称、kind、category 和参数——然后铺出一整棵做好的文件树：带 schema 的 chart、带正确前缀和标签的 `ApplicationDefinition`、用于构建的 Makefile。

亲手拆解这一切并不因此失去意义。生成出来的骨架还是得读、得改，而去改你不理解的东西，是已知最糟的工作方式。

## 检查

📍 **在哪：** 在 bastion 上，在你之前用 `kubectl` 干活的同一个终端窗口里。

这个脚本在**本地**运行，不触碰集群：它检查 chart 能过 linter、能渲染、参数真的到达清单、`ApplicationDefinition` 能被解析并含有所有必填字段、图标能解码成 SVG——而且，最要紧的是，定义里的 schema 和 chart 里的 schema 一致。

```bash
# 名字前面的 ./ 意思是“当前文件夹里的文件”，也就是来自 labs/13-catalog
./check.sh
```

⚠️ **在 Windows 上这个脚本从 WSL 里运行**，不是从 PowerShell——怎么装它，写在实验 0 的开头。没有 WSL 也能完成这个实验，但不会有产物报告。

如果设置了 `KUBECONFIG`，脚本还会顺便向集群询问权限，并确认你无权 apply 这个定义。脚本把没有权限当作预期结果，而不是错误。

## 清理

没什么要清理的：你在集群里什么都没创建。这是整个工作坊里唯一一个不留痕迹的实验，而这正是它的特点——平台团队的工作大体上就是这个样子：文本、评审、别人的手来做 apply。

把 `chart/` 和 `applicationdefinition.yaml` 这些文件带走。这是一份可用的起点稿，一个真正属于你目录的应用可以从它长出来。

## 我们现在会做什么了

- 把应用打包成带参数 schema 的 Helm chart，并在本地验证它
- 写一个 `ApplicationDefinition`，并说清它每一个块的用途
- 理解为什么目录是共享的、为什么租户对它没有权限
- 把交接给管理员的东西准备好，让他一次就能 apply 成功
- 知道用什么来生成骨架、该参照哪个示例

## 而在 vSphere 里这会是

Content Library 和一个带输入字段的 OVF 模板。这套机制比看上去更相像：一个团队准备模板，另一个把它放进公用库，其他人来部署。

区别在于最终得到的东西。OVF 模板是一台带磁盘的机器：你部署它，从此它就自己活着，而你要在每一份副本上手工更新它。`ApplicationDefinition` 是一份背后有 chart 支撑的描述：更新 chart、把版本加一，所有安装就通过同一个机制更新。

**说句实话，哪里 vSphere 更方便。** Content Library 是一个现成的界面：放进文件、分好权限，就完了。这里你需要建一个仓库、配置 chart 的构建和发布、和管理员商定源的名字——而这一切都得在目录里出现任何东西之前完成。入门门槛更高，第一个应用会花掉一天，而不是一小时。

它在第二个和第三个应用上就回本了，尤其是在第一次更新上。更新一个已经散布到五家子公司的应用——从 chart 更新，对比在五份已经彼此漂开的 OVF 副本上更新同一个应用——那是不同的工作量。是不同的数量级。
