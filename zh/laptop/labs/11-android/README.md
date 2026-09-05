# 实验 11 · 在集群里构建移动应用

| | |
|---|---|
| **时长** | 40 分钟，其中最多 15 分钟用来等待第一次构建 |
| **它证明了什么** | 构建服务器不是一台服务器——它是一个任务，在构建期间占用一个节点，构建完就把节点释放掉 |
| **你需要什么** | 实验 0 里的集群、`kubectl`、`~/lab.kubeconfig`、以及对租户控制台的访问权限 |

## 为什么这很重要

移动团队正在给 Propusk 写一个客户端——就是员工用来给访客申请通行证的那个界面。目前他们把它构建在某个开发者的笔记本电脑上。等这个人休假了，就没人能发版。

他们没有自己的构建服务器，将来也不会有：他们申请一台专门跑 Android SDK 的机器，被拒了两次——「负载不均衡，机器会闲着」。坦白说，这话没错。构建每天只跑二十分钟，但它需要的机器却得有四核和十六 GB。

在这里我们要做的恰恰是别人要我们做的事：把那四个核**借用二十分钟**，构建出 APK，然后再还回去。而构建好的文件，我们要放到一个任何人都能取的地方——包括拿着手机的测试人员——放进一个 bucket 里。

这是所有实验里第一次出现一个工作负载会**结束**。在此之前我们部署的一切，都是设计成永远运行下去的。

## 小词典

| 术语 | 它是什么 | 像……但是 |
|---|---|---|
| **Job** | 一个任务：运行某个东西，等它成功完成 | **客户机操作系统里的计划任务**，但 job 会自己创建一台机器来跑，跑完自己收拾干净 |
| **Deployment** | 一个永远运行的应用的描述 | **一个 vApp**，但它永远不会「成功完成」——消失掉的副本会被重新创建 |
| **对象存储** | 没有文件、也没有目录的存储——只有一个键和它的内容 | **一个 datastore**，但它不挂载。你按整个对象存取，通过 HTTP | 
| **Bucket** | 对象存储里一块有名字的区域 | **datastore 上的一个文件夹**，但它不嵌套：bucket 就是最顶层，里面那些「文件夹」其实是对象名字的一部分 |
| **S3** | 一种通过 HTTP 访问对象存储的协议 | 没有直接对应物；比起 NFS，它更接近一个 REST API |
| **访问密钥** | 用一对「access key / secret key」代替登录名和密码 | **一个服务账号**，但密钥是按 bucket 发放的，不是按人 |
| **Secret** | 集群里用来放密码和密钥的对象 | **凭据库里的一条记录**，但在集群内部它是 base64，不是加密。它只是把东西藏起来不让人看见，而不是藏起来不让管理员看见 |
| **emptyDir** | 一块临时磁盘，它存活的时间与 Pod 完全一致 | **一块临时的 vmdk**，但它会跟着 Pod 一起消失，没有任何办法恢复 |

### Job 对比 Deployment——一张表说清

这是本实验最关键的区别，值得在我们应用任何东西之前先钉牢。

下面两行里都出现了 **Pod** 这个词。Pod 是集群里最小的执行单位：在某个具体节点上拉起的一个容器（或几个容器）。最接近的类比是一台专门跑单个任务的虚拟机，只不过它是在几秒内创建出来的，而且活不过它所在的节点。Job 和 Deployment 自己都不运行任何东西：它们创建 Pod，并决定当一个 Pod 消失时该怎么办。

| | Deployment | Job |
|---|---|---|
| 「一切正常」意味着什么 | 副本此刻正在运行 | 进程以代码 0 退出了 |
| 一个 Pod 成功结束了 | 集群把这当成故障，创建一个新的 | 集群认为工作已经完成 |
| 它存活多久 | 直到你删除它 | 直到它跑到完成 |
| 它执行多少次 | 从不——它不「执行」，它一直运行 | 一次（或按指定的次数） |
| 结束之后留下什么 | 一个运行中的应用 | 工作的结果和日志 |

于是就有了一个人人都会栽跟头的实际后果：**如果你把构建当成 Deployment 来跑，集群会一遍又一遍地跑它**。构建成功完成了——所以副本没了——所以必须创建一个新的。一个无限循环，而且这不怪集群：它就是被这么告知的。

## 实验目录里有什么

所有文件都已经是你的了——你拿仓库的时候就一起拿到了。没有什么要创建或重新敲的：下面凡是写着 `kubectl apply -f name.yaml` 的地方，文件都来自这里。

```bash
cd labs/11-android
```

| 文件 | 它是什么 | 你什么时候会用到 |
|---|---|---|
| `bucket.yaml` | 存放构建好的 APK 的存储 | 你**在租户里**应用它 |
| `propusk-src.yaml` | Propusk 移动应用的源代码 | 你在自己的 `lab` 集群上应用它 |
| `android-build.yaml` | 构建本身。脚本被单独放进了一个 ConfigMap，而不是内联到 job 里 | 你也在那里应用它 |
| `check.sh` | 检查构建是否成功、APK 是否落进了存储 | 你在实验的最后运行它 |

## 步骤 1. 创建 bucket

📍 **位置：** 在浏览器里，在租户控制台里。

**租户**是你在平台上的那一份切片：就是你在控制台里看到、并且由你掌管的那些东西。你在实验 0 里就是在它里面订购了 `lab` 集群的，bucket 你也在那里订购。

bucket 是一个**托管服务**——一个现成的目录项：你说明你需要什么，平台就把它拉起来、更新它、修好它。它**不在 `lab` 集群里**，而是在它旁边，在租户里。事情本该如此：构建产物应当比构建它的那个集群活得更久。

访问租户的文件（kubeconfig）从控制台里获取：**Info → Secrets 标签页 → `kubeconfig-tenant-workshopXX`**，保存到 `~/.kube/workshop`。这跟其余所有实验里都是同一个路径。

租户 → **创建应用** → `Bucket`。

| 字段 | 值 | 为什么 |
|---|---|---|
| Name | `builds` | 短，而且一看就知道里面是什么 |
| Users | 添加用户 `ci` | 构建会用这些密钥来写入 |
| Locking | 关闭 | 防止对象被删除的保护；对构建来说是多余的 |
| Storage pool | 留空 | 默认存储池就够用 |

**同一个 bucket 用文本表示**，如果你更喜欢这样的话。注意：这里的 `namespace`（集群内部的一道隔断；你的租户就是一个单独的 namespace）是租户的，而且你需要的是访问租户的文件，不是 `lab` 集群的那个。

```bash
# KUBECONFIG——kubectl 用哪个访问文件。这里用租户的：bucket
# 是在管理集群上订购的，不是在 lab 集群里
export KUBECONFIG=~/.kube/workshop

# apply =「把集群变成文件里描述的样子」。这条命令本身并不创建
# 存储——它把订单交给平台。
#   -f bucket.yaml   要应用哪个文件。在这之前，先把文件里的
#                    tenant-workshopXX 替换成你自己的 namespace，否则订单会跑到别处去
kubectl apply -f bucket.yaml
```

**你应该看到** —— `bucket.apps.cozystack.io/builds created`。

<details>
<summary><b>细看：bucket.yaml 里面有什么</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
```

`apps.cozystack.io` 是平台的托管服务所在的 API 组。虚拟机、数据库和队列都会带同样的前缀。这不是「Kubernetes 之上的一个附加组件」——它们就是普通的 Kubernetes 对象，由平台来描述。

```yaml
spec:
  users:
    ci: {}
```

一张用户映射表。每个键都是一个单独的 S3 用户，平台会为每一个用户发放**它自己的**一对访问密钥。一个空对象 `{}` 表示完全访问权限。

为什么一个 bucket 上要有好几个用户：构建需要写入权限，而移动团队和测试人员只需要只读。不同的密钥，不同的权限，可以分别撤销：

```yaml
  users:
    ci: {}
    mobile:
      readonly: true
```

我们为了节省实验时间只用一个，但值得知道有这回事。

</details>

bucket 需要几秒钟来完成置备。等到它在控制台里显示为就绪。

## 步骤 2. 取回密钥

📍 **位置：** 在控制台里，在 bucket 的卡片上，**Secrets** 标签页。

找到那个名为 `bucket-builds-ci-credentials` 的 secret。它里面有四个值：

| 字段 | 它是什么 |
|---|---|
| `endpoint` | 存储的地址，**不带** `https://`——前缀得你自己加上 |
| `bucketName` | 真正的 bucket 名字：很长，带一个标识符，不是 `builds` |
| `accessKey` | 「登录名」 |
| `secretKey` | 「密码」 |

⚠️ **`bucketName` 不等于你输入的那个名字。** `builds` 这个名字是 Cozystack 对象的名字。存储里真正的 bucket 名字是平台自己发放的，它看起来像 `bucket-a9209f83-...`。你必须替换成的正是这个，否则你会得到一个对不存在的 bucket 的访问被拒绝，然后花十分钟去找一个根本不存在的拼写错误。

同样这四个值也可以通过命令行拿到——平台会给你对每个你创建过的应用的凭据授予访问权限。下面这条命令取出四个值里的一个，`accessKey`；其余的取法一样，只需换一下字段名。

```bash
# 我们用跟上一步相同的租户访问权限：secret 就在租户里。
# get secret =「显示那个装着密码和密钥的对象」。secret 里面的值是
# base64 编码的——这不是加密，只是把二进制数据写成文本的一种方式。
#   -n tenant-workshopXX   在哪个 namespace 里找
#   -o jsonpath='...'      不返回整个对象，只返回它里面的一个字段：
#                          .data.accessKey —— data 区段里面的 accessKey 字段
#   base64 -d              把它解码回可读的形式（d = decode）
#   ; echo                 加一个换行：没有它的话，这个值会跟
#                          下一个终端提示符黏在一起
kubectl -n tenant-workshopXX get secret bucket-builds-ci-credentials \
  -o jsonpath='{.data.accessKey}' | base64 -d; echo
```

不过，成批地读取所有 secret 对租户来说是不允许的：`kubectl auth can-i get secrets` 会回答 `no`。权限是精确地按具体名字授予的——同样也授予了你实验 0 里那个集群的 kubeconfig。

## 步骤 3. 把密钥放进你自己的集群

构建会在 `lab` 集群里跑，而密钥在租户里。两个集群是不同的；没有任何东西会自动跨过去。我们手动把它们搬过去。

📍 **位置：** 在笔记本电脑上。

我们要在 `lab` 集群里用上一步的那四个值攒出我们自己的一个 secret。别改字段名：构建脚本会去找名字正好是这些的变量。

```bash
# 从这里到实验结束，我们都用 lab 集群，不用租户
export KUBECONFIG=~/lab.kubeconfig

# create secret generic =「用我接下来列出的这些值创建一个 secret」。
# generic 意思是「一组任意的名字-值对」，而不是某个现成的类型，
# 比如给镜像仓库密码或 TLS 证书用的那种。
#   bucket-creds        secret 的名字。Job 会按这个名字引用它
#   --from-literal=name='value'   一对。把 ВСТАВЬТЕ_... 替换成
#                       控制台里 bucket 卡片上的那些值
kubectl create secret generic bucket-creds \
  --from-literal=endpoint='ВСТАВЬТЕ_endpoint' \
  --from-literal=bucketName='ВСТАВЬТЕ_bucketName' \
  --from-literal=accessKey='ВСТАВЬТЕ_accessKey' \
  --from-literal=secretKey='ВСТАВЬТЕ_secretKey'
```

**你应该看到：**

```
secret/bucket-creds created
```

⚠️ **用单引号。** secret 密钥里经常含有 `$`、`!` 和 `&`。在双引号里，shell 会按它自己的方式解释它们，于是你拿到的会是一个跟你复制的不一样的密钥。

**为什么这条命令是手敲的，而不是作为一个文件躺在仓库里。** 这些实验里其余的一切都是可以进 Git 的文本。secret 不行。集群里的 `Secret` 对象把它的值存成 base64，而 base64 不是加密，只是一种写法：任何拿到这个文件的人都能读到密钥。一个装着 secret 的文件进了 Git，就意味着密钥永远进了 Git，连整个历史都算。这正是那种会把 OpenBao 引入 Propusk 场景的审计发现。

## 步骤 4. 看看我们要构建的是什么

目录里有一个 `propusk-src.yaml`——应用的源代码，以 ConfigMap 的形式存在。**ConfigMap** 是集群里的一个对象，里面装着文本文件：随后集群会把它们作为磁盘上普通的文件放进容器里。最接近的类比是一个共享的配置文件夹，只不过它存在集群自身里，而且是跟着任务的描述一起送到的。

源代码放在那里也是出于同样的原因：构建需要文件，而为了六个文本文件去搭一块网络磁盘毫无意义。

这个应用只做一件事：它显示一行字«申请访客通行证»。这就够了，因为这个实验讲的不是 Android，而是它在哪里被构建出来。

**APK** 就是最后产出的东西。它是一个归档文件，里面装着编译好的应用、图片、文本，以及该启动哪个界面的描述；手机安装的正是它。就它扮演的角色而言，它跟 Windows 上的 `.msi` 是一回事：一个交给用户的单一文件。

<details>
<summary><b>细看：源代码里面有什么</b></summary>

六个文件，分散在 ConfigMap 的各个键里。

### `settings.gradle.kts` —— Gradle 到哪里去找依赖

```kotlin
pluginManagement {
  repositories { google(); mavenCentral(); gradlePluginPortal() }
}
```

三个公开仓库，Android 构建插件、Kotlin 插件以及它们拉进来的一切都会从这里下载。正是这份清单解释了为什么第一次构建那么慢：从一个空容器开始，一切都得下载下来。

⚠️ 当安全部门禁止上互联网取依赖时，你第一个要改的就是这个地方。到那时你的代理仓库会写进这里，就像 Harbor 成了 Docker Hub 的替代品一样。

### `build.gradle.kts` —— 工具版本

```kotlin
plugins {
  id("com.android.application") version "8.5.2" apply false
  id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
```

`apply false` 意思是「声明版本，但不要在根项目里启用它」——`app` 模块会启用它们。版本是刻意钉死的：一个拉「最新」的构建，一个月之后构建出来的结果会跟今天不一样，而要弄清楚为什么的人就是你。

### `app-build.gradle.kts` —— 模块本身

```kotlin
android {
  namespace = "io.aenix.propusk"
  compileSdk = 34
  defaultConfig { minSdk = 24; targetSdk = 34 }
}
```

`compileSdk 34` 是我们编译时所针对的 Android SDK 的版本。它也决定了在 SDK 安装那一步到底得下载什么，而那大约是一个半 GB。

`minSdk 24` 是这个应用能运行的最老的 Android。这里是 Android 7。

```kotlin
  kotlinOptions { jvmTarget = "17" }
```

Kotlin 编译成 JVM 字节码，因此对 Java 版本有要求。我们用的镜像自带 JDK 17，这两个数字必须匹配。

### `MainActivity.kt` —— 应用

```kotlin
class MainActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    ...
    view.text = getString(R.string.greeting)
```

一个 activity，一个 `TextView`，文本取自资源。它用的是光秃秃的 `android.app.Activity`，而不是兼容库：这个应用有零个外部依赖，这在每次构建时都省下了几分钟的下载。

`R.string.greeting` 是对 `strings.xml` 里某个字符串的引用。`R` 类是在构建时生成的；它不在源代码里。如果你看到错误「unresolved reference: R」，那说明是资源生成那一步失败了，不是你的代码有问题。

### `AndroidManifest.xml` 和 `strings.xml`

清单文件声明了从图标启动的是哪个 activity。`strings.xml` 把文本跟代码分开存放——这样就能翻译它们而不用打扰程序员。

</details>

我们把源代码放进集群。目前还什么都没运行：这些只是构建在下一步会需要的文件。

```bash
# 创建一个里面装着六个文件的 ConfigMap。要检查它是否就位：
# kubectl get configmap propusk-src
kubectl apply -f propusk-src.yaml
```

**你应该看到** —— `configmap/propusk-src created`。

## 步骤 5. 拆解这个 Job

在你运行它之前，先读一读你到底要运行的是什么。这个构建会占用整个节点，值得搞清楚是为了什么。

<details>
<summary><b>细看：android-build.yaml 里面有什么</b></summary>

文件里有两个对象：一个装着构建脚本的 ConfigMap，以及 Job 本身。

### 构建脚本

它放在一个 ConfigMap 里，原因跟 nginx 页面当初跟 Deployment 分开存放的原因一样：四十行 shell 塞在一个 `command` 字段里根本没法读。

五个步骤，五个全都是你在构建服务器上会手敲的普通命令。容器启动时是空的：它有镜像自带的 Java 和 Gradle，但没有 Android SDK、没有密钥、没有源代码——SDK 和密钥由构建命令拉进来，而源代码由挂载进容器的 ConfigMap 一起带来。

| 步骤 | 它做什么 | 要花多长时间 |
|---|---|---|
| 1 | 下载 Android command-line tools——用来安装 SDK 本身的那套工具 | 1–2 分钟 |
| 2 | 接受许可协议并安装 SDK、平台 34、build-tools | 5–15 分钟 |
| 3 | `gradle :app:assembleDebug` —— 把源代码编译成 APK | 3–8 分钟 |
| 4 | 安装 `mc`，一个连接 S3 存储的命令行客户端 | 几秒 |
| 5 | 把 APK 用两个名字放进 bucket | 几秒 |

有三行值得细看。

```bash
# yes —— 一条无休止地打印「y」的命令：这样一批「接受
# 许可协议吗？[y/n]」的问题就无需人参与地被应答了。
#   >/dev/null 2>&1   把正常输出和错误输出都丢掉：这里不需要
#   || true           「即使命令返回了错误，也当它没事」
yes | sdkmanager --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null 2>&1 || true
```

这里的 `|| true` 不是偷工减料，而是必需的：当 `sdkmanager` 关闭它的输入时，`yes` 会收到一个 SIGPIPE，于是它返回一个非零码。在 `set -o pipefail` 下，这会无缘无故地让构建失败。如果许可协议真的没被接受，紧接着的下一条命令就会拒绝安装 SDK，所以我们并没有把错误藏起来。

```bash
# alias set =「把存储地址和密钥记在一个短名字 builds 底下」，这样
# 后面每一条复制命令里就不用把它们重复一遍了。
#   "https://${endpoint}"   地址：https:// 前缀我们自己加，secret 里没有它
#   ${accessKey} ${secretKey}   S3 说法里的登录名和密码，它们来自 secret
#   >/dev/null              把输出压掉
mc alias set builds "https://${endpoint}" "${accessKey}" "${secretKey}" >/dev/null
```

输出是刻意压掉的，脚本里没有 `set -x` 也是同样的原因：Job 的日志任何有集群访问权限的人都看得到，而密钥绝不能落到那里。

```bash
# echo 往任务的日志里打印一行。它不做任何实际工作——它是一个标记，
# 表明前一条复制命令跑到了尽头
echo "APK-UPLOADED ${bucketName}/propusk/propusk-${STAMP}.apk"
```

一行标记。`check.sh` 靠它来区分「Job 跑过了」和「APK 真的到了 bucket 里」——这是两个不同的论断，而后者更有力。

### Job

```yaml
kind: Job
spec:
  backoffLimit: 1
```

如果构建失败了，把 Pod 重新创建多少次。填零会更诚实，但下载那一个半 GB 的 SDK 时网络偶尔会断，而重试一次比去排查「为什么我的失败了」要便宜。

```yaml
  activeDeadlineSeconds: 7200
```

整个任务的一个上限，两小时。没有它的话，一个卡住的构建会把节点占到晚上，而你会从一个东西部署不上去的邻居那里听说这事。

倒计时从 Job 创建开始算，而不是从容器启动开始：花在 `Pending` 上的时间，以及实验稍后那一步节点重建的时间，消耗的是同一个额度。一小时不够用——那样构建会在一个人已经等完之后立刻带着 `DeadlineExceeded` 死掉。

```yaml
      restartPolicy: Never
```

对 Job 来说这个字段是必填的，而且只有两个有效值。`Never` 的意思是：不要在同一个 Pod 内部重启失败的进程，而是把决定权交给 Job——它会创建一个新的。这样每次尝试都有自己的日志，你能看出是第几次失败的。

在 Deployment 里熟悉的那个值 `Always` 在这里不可用：「总是重启」和「等它完成」是相互矛盾的。

```yaml
          envFrom:
            - secretRef:
                name: bucket-creds
```

secret 的四个密钥全都变成名字相同的环境变量。另一种做法是把每个变量单独列出来；对于四个同类的密钥来说，那是多余的噪音。

⚠️ 一个值得知道的副作用：`envFrom` 会把 secret 的**所有**密钥都拽进环境里，包括之后才加进去的那些。对于一个你自己创建、只给一个任务用的 secret 来说，这是可以接受的。对于一个横跨整个 namespace 的共享 secret 来说，就不行了。

```yaml
          resources:
            requests: {cpu: "1", memory: 4Gi}
            limits:   {cpu: "2", memory: 6Gi}
```

这就是 Android 构建那个诚实的价码。`requests` 是要预留的量：一个核和四 GB。再少就没意义了——Kotlin 编译器会把它们吃光还要更多。`limits` 是上限：两个核和六 GB。

拿它跟第一个实验里的那个应用比一比：`20m` 的 CPU 和 `32Mi` 的内存。CPU 差五十倍，内存差一百三十倍。这就回答了「到底为什么要指定 `requests`」这个问题：没有它们，调度器会把这个构建当成跟 nginx 一样轻飘飘，于是把它放到一个它根本装不下的节点上。

```yaml
        - name: work
          emptyDir:
            sizeLimit: 12Gi
```

节点上的一块临时磁盘。SDK、Gradle 缓存和构建结果都会落到这里——总共六到八 GB。它存活的时间与 Pod 完全一致：Job 结束了，磁盘也就没了。

**由此可以直接推出为什么每次构建都慢。** 我们每一次都从头下载 SDK 和依赖。在一台真正的构建服务器上，`emptyDir` 的位置会是一块持久卷，而它会比任务活得更久：第一次构建慢一些，第二次就明显快了。我们在实验里刻意不这么做，以免引入一个多余的实体，但在现实里这是你第一个会加上去的东西。

```yaml
            items:
              - key: app-build.gradle.kts
                path: app/build.gradle.kts
```

一个 ConfigMap 键不能包含斜杠，但挂载路径可以。一张六个键的扁平映射表就是这样展开成 Gradle 所期望的那棵目录树的。

</details>

## 步骤 6. 运行它——然后撞墙

📍 **位置：** 在笔记本电脑上，在 `lab` 集群里。

我们应用这个 job，然后立刻看看它创建出来的那个 Pod。

```bash
# 从文件里创建两个对象：一个装着脚本的 ConfigMap，以及 Job 本身。
# 从这一刻起，集群就有义务给这个构建找一个节点并把它启动起来
kubectl apply -f android-build.yaml

# get pods =「显示 Pod」。任务的 Pod 没有自己的名字——Job 自己给它
# 编一个，在它自己的名字后面接上一段随机尾巴。所以我们不按名字找，而按标签找：
#   -l job-name=propusk-build   挑出 job-name 标签等于该 job 名字的那些 Pod。
#                               这个标签是 Job 自己贴到它的 Pod 上的
kubectl get pods -l job-name=propusk-build
```

**你多半会看到：**

```
NAME                   READY   STATUS    RESTARTS   AGE
propusk-build-x7k2p    0/1     Pending   0          40s
```

`Pending` 不是「正在启动」。它意味着「没启动，也不会启动」。集群会把原因写进 Pod 的事件里——那是它的一份日志：谁试图对它做了什么。

```bash
# describe =「把关于这个对象所知道的一切都显示出来」：配置、状态、事件。
# 输出很长，所以我们只留下它的末尾部分：
#   sed -n '/Events:/,$p'   从出现「Events:」的那一行开始，
#                           一直打印到输出的末尾（$ —— 末尾）
kubectl describe pod -l job-name=propusk-build | sed -n '/Events:/,$p'
```

**你应该看到** —— 那一行写着 Pod 没被安置的原因：

```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory.
```

> **在往下读之前，先停下来想一想。**
>
> 到底是什么对不上？回想一下你在实验 0 里订购的是哪种节点，以及这个 Job 请求了多少内存。

<details>
<summary><b>答案，以及一个比这个错误更深远的教训</b></summary>

在实验 0 里我们取了 `u1.medium` 节点——一个核和四 GB。这个 Job 请求 `requests: memory 4Gi` 和 `cpu 1`。节点有的正好是这么多，但其中一部分已经被占用了：kubelet 给自己预留了内存，另外节点上还跑着负责网络和监控的系统 Pod，再加上第一个实验里的那个应用。

请注意，**两样都不够**——CPU 也是。`u1.medium` 节点给一个核，构建要一整个，而这个核的一部分已经被系统 Pod 占了。所以消息里有两个原因，不是一个：对调度器来说，其中任何一个都足以拒绝。

调度器把节点上所有 Pod 的 `requests` 加起来，跟节点实际愿意给出的量做比较。凑不出足够的空闲空间，于是这个 Pod 就永远留在等待里。

**一个比这个错误更深远的教训。** Kubernetes 调度器算的不是实际消耗，而是**声明的量**。一个所有 Pod 都在打盹、CPU 使用率只有百分之三的节点，在调度器看来可以是完全占满的——只要 `requests` 之和已经等于容量。反过来也一样：一个在负载下喘不过气的节点，会一直接受新的 Pod，直到 `requests` 之和顶到天花板。

这也解释了那个乍一看很奇怪的组合 `Insufficient cpu, Insufficient memory` 会出现在一个看似空的集群上——你还会不止一次碰到它。

在 vSphere 里，这两样你都熟悉：DRS 在安置时计入的那个资源预留（reservation），以及它单独去看的实际负载。而在这里，安置**只**按预留来算，没有另外那一半。

</details>

## 步骤 7. 把节点做大

📍 **位置：** 在控制台里，在 `lab` 应用里。

打开 `Kubernetes` → `lab` → 编辑。在节点组里，改动：

| 字段 | 之前 | 之后 | 为什么 |
|---|---|---|---|
| Instance type | `u1.medium`（1 核，4 GB） | `u1.large`（2 核，8 GB） | 构建能装下的最小规格 |
| Disk | `20Gi` | `40Gi` | SDK、Gradle 缓存和镜像层塞不进二十 |

如果你租户的配额允许，就取 `u1.xlarge`（4 核，16 GB）。构建会明显更快，而多出来的资源你在实验一结束就还回去。如果配额不允许，表单在保存时会拒绝，那就只剩下 `u1.large` 了。

⚠️ **更换节点类型会重建节点的虚拟机。** 旧节点离场，新节点起来，Pod 迁移过去。这要花几分钟，而节点本地磁盘上存的一切都会消失。对我们的实验来说这没什么痛的——数据放在托管服务里，不在节点上——但在生产集群上，这是一次你会去规划的操作。

等新节点。`lab` 集群没有图形化控制台，所以我们用命令来盯着：

```bash
# get nodes =「显示集群的节点」——就是那些跑着 Pod 的虚拟机。
#   -w   watch，「别退出；每次有变化就追加一行」。旧节点
#        会从列表里掉出去，新节点会出现并到达 STATUS=Ready。
#        要退出这个监视——Ctrl+C，它对集群没有任何影响
kubectl get nodes -w
```

一旦节点变成 `Ready`，那个卡住的构建 Pod 就会自己动起来——调度器一直在复查 `Pending` 的 Pod，不用去请求它。我们检查一下它是否动了：

```bash
# 跟改节点之前同样的查询。现在 STATUS 那一列应该显示
# ContainerCreating，再过一两分钟变成 Running
kubectl get pods -l job-name=propusk-build
```

## 步骤 8. 等待构建

📍 **位置：** 在笔记本电脑上，在 `lab` 集群里。

我们要在构建的日志里盯着它——也就是脚本在容器内部打印到屏幕上的那些内容。

```bash
# logs =「显示任务打印了什么」。
#   -f                  follow：别退出，而是随着新行出现追加上去。
#                       退出——Ctrl+C，构建照样继续
#   job/propusk-build   你可以指向 Job 本身，而不是 Pod：kubectl 会自己找到它的 Pod
kubectl logs -f job/propusk-build
```

**你应该看到** —— 脚本的五个步骤依次出现。时间上的参照点：

| 日志标记 | 大约在什么时候 |
|---|---|
| `== 1/5 正在安装 Android 命令行工具 ==` | 立刻 |
| `== 2/5 正在接受许可协议并下载 SDK（最耗时的一步） ==` | +1–2 分钟，而且卡得最久 |
| `== 3/5 正在构建 APK ==` | 从开始起 +5–15 分钟 |
| `BUILD SUCCESSFUL in ...` | 从开始起 +10–25 分钟 |
| `APK-UPLOADED bucket-.../propusk/propusk-...apk` | 紧接在它之后 |

⚠️ **在 `2/5` 标记处沉默二十分钟是正常的，不是卡死。** `sdkmanager` 在非交互模式下不显示下载进度：它一声不吭，然后打印一个 `done`。你可以在另一个终端窗口里确认进程还活着——看看这个 Pod 是不是在吃 CPU 和内存：

```bash
# top =「它此刻消耗多少」。不是 requests 那个声明，而是就在这一秒的
# 实际用量。非零的 CPU 意味着内部正在干活
kubectl top pod -l job-name=propusk-build
```

当 Pod 以代码 0 退出时（返回码为零是被广泛接受的「运行时没出错」），这个 Job 就被认为完成了：

```bash
# 我们看的不是 Pod，而是 job 本身：它有一些 Pod 没有的列
kubectl get job propusk-build
```

```
NAME             STATUS     COMPLETIONS   DURATION   AGE
propusk-build    Complete   1/1           18m32s     19m
```

`DURATION` 那一列正是对移动团队「构建要花多久」这个问题的回答。把同一个 Job 删掉再重建，跑第二遍，它会花上一样久：我们没有缓存，而且我们知道为什么。

## 步骤 9. 取回 APK

📍 **位置：** 在租户控制台里，在 bucket 的卡片上。

bucket 有一个网页界面——从 bucket 的卡片打开它，用同样的 `accessKey` 和 `secretKey` 登录。进去之后你会看到：

```
propusk/propusk-20260821-141207.apk
propusk/propusk-latest.apk
```

一个文件两个名字是常见做法：带日期的名字显示了构建历史，而靠 `latest`，测试人员总能拿到最新的那个，不用去问今天是几号。

请注意，那个 `propusk`「文件夹」其实并不存在。对象存储里没有目录：`propusk/propusk-latest.apk` 完完整整就是对象的名字，里面那个斜杠是界面为了我们方便才画成一棵树的。

**这跟你习惯的文件共享有什么不同**：

| | 文件共享（NFS、SMB） | 对象存储（S3） |
|---|---|---|
| 怎么连接 | 作为磁盘挂载 | 不挂载，通过 HTTP 请求 |
| 部分写入 | 你可以往文件中间写 | 不允许，对象是整个放进去的 |
| 目录 | 真实存在 | 没有，斜杠是名字的一部分 |
| 锁 | 有 | 没有 |
| 谁能够到 | 在同一个网络里的人 | 任何有密钥和 HTTPS 的人 |
| 能装多少 | 卷装得下多少就多少 | 实际上没有上限 |

于是就有了选择的准则：**数据库或一个共享的文档文件夹——用文件共享；产物和备份——用对象存储**。想把数据库放到 S3 上，跟通过互联网用 SMB 分发 APK 一样让人难受。

## 检查

📍 **位置：** 在笔记本电脑上，在你之前用 `kubectl` 干活的那个终端窗口里。

```bash
# 这个脚本用跟你一样的访问文件去连 lab 集群。bucket 的凭据
# 它从 bucket-creds secret 里取——你不用另外输入任何东西
export KUBECONFIG=~/lab.kubeconfig
./check.sh
```

⚠️ **在 Windows 上这个脚本从 WSL 里运行**，不是从 PowerShell——怎么安装它在实验 0 的开头有说明。没有 WSL 你也能做完这个实验，但就不会有产物报告了。

这个脚本检查的不是你应用了清单，而是构建跑到了尽头：Job 成功结束，日志里有 `BUILD SUCCESSFUL`，APK 到了 bucket 里，而且 secret 里的那个存储真的能从集群内部响应。

## 清理

Job 结束之后什么都不消耗：Pod 终止了，它的那些核和 GB 早在 `Complete` 那一刻就回到了节点的空闲容量里——别人马上就能拿去用。剩下的只有集群里的一条记录和日志——几个 KB。

不需要马上删掉它，日志还会有用。等你做完了：

```bash
# delete -f =「把这个文件里描述的东西从集群里移除」。Job 连同
# 它的日志会一起消失，所以这条命令在时间上排最后，不是最前
kubectl delete -f android-build.yaml
kubectl delete -f propusk-src.yaml
# 我们单独删掉这个 secret：它没有对应的文件，你是用命令创建它的
kubectl delete secret bucket-creds
```

⚠️ **如果你不再需要这个节点，就把它还回 `u1.medium`** —— 否则它会一直占着四个核直到工作坊结束。bucket 和它里面的内容留着：它很小，而且如果你想重新构建的话会派上用场。

正是清理的这种低廉，构成了反对专用构建服务器的论据。我们在构建期间取了一个大一些的节点，事后一次字段编辑就把原来那个还了回去。

## 我们现在会做什么了

- 把 Job 跟 Deployment 区分开，并理解为什么构建绝不能当成后者来跑
- 在集群里跑一个繁重的一次性任务，而不用为它搭一台机器
- 把产物放进对象存储，并解释清楚它为什么不是文件共享
- 把 `Pending` 读成「按 `requests` 没装下」，而不是「正在加载」
- 用核数、GB 和分钟说出一次 Android 构建真实的价码

## 而在 vSphere 里这本来会是

一张申请一台 VM 当构建代理的单子。一份说明，解释一台每天只工作二十分钟的机器为什么需要十六 GB。一次驳回。一个季度之后的第二次尝试。然后是一台 98% 的时间都在闲着的机器，一年下来上面装了三代 SDK，因为删掉它们太吓人。

而在这里，资源在任务期间被取用，然后自己回收掉。

**说句公道话，vSphere 在哪里更方便。** 一台永久存在的构建机器有一个无可争辩的优势：上面已经什么都下载好了。我们的构建时间主要就是下载 SDK 和依赖，而一个永久代理是不会有这段时间的。这个问题可以用一块给缓存用的持久卷来治，但卷得搭起来、得盯着它的大小、还得清理它——也就是说，部分地又把我们本想逃离的那份活给揽了回来。区别在于，一块卷只值几个小钱，而且不需要申请单，而一台机器当初是需要的。

再有一点：一台你能 SSH 进去看看构建为什么表现古怪的活机器，是很方便的。对着一个 Job 的 Pod，你只能看日志，而在它结束之后就更少了。在集群里调试构建，一开始会更慢一些。
