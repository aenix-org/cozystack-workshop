# 实验 9 · 百万行数据上的分析

| | |
|---|---|
| **时长** | 45 分钟 |
| **它证明了什么** | 一份基于百万条记录的报表在毫秒级完成计算，而搭建它只需十分钟 |
| **你需要准备** | 实验 0 中的集群和 `~/lab.kubeconfig`；访问你租户控制台的权限；形如 `workshopXX` 的租户编号；能读懂 SQL |

> ⚠️ **这是一节内容密集、需要阅读 SQL 的实验。不要把它安排在实验 8 之后紧接着上。**

## 为什么这很重要

「通行证」服务已经运行了半年。管理层带着一个听起来无害的问题找上门来：

> 我们每个月有多少访客，是在增长还是下降，入口在哪些时段会排队？我们想每月看一次，最好每天都能看。

存放通行证本身的那个数据库里没有这些数据——它保存的是当前的申请，而不是数年的历史。历史记录在进出日志里：服务运行以来每一次刷闸机的记录。这已经是一百万行了，而且还会继续增长。

接下来就是熟悉的套路。有人对生产数据库写了一条 `GROUP BY` 查询，它跑了两分钟，也让通行证服务在这两分钟里瘫痪。有人建议导出到 Excel——结果撞上了行数上限。有人搭了一套每晚导出到单独数据库的流程，半年后没人记得为什么报表里的数字和现实对不上。

正确的答案是**一个专门用于分析、内部结构不同的独立数据库**。不是「同一种数据库，只是放在另一台服务器上」，而是内部构造就不一样。在这节实验里，我们会启动一个 ClickHouse，往里灌入一百万条进出记录，看看报表要花多久才能算出来。

顺带我们会搞清楚，**为什么列式数据库在分析上很快，在点对点操作上却很慢**——因为后半句和前半句同样重要，而正是因为不了解后半句，人们才会把 ClickHouse 用在它根本不需要出现的地方。

本实验中的每个术语都会在首次出现时解释，下一节是已经介绍过的术语的小词典。

## 术语小词典

| 术语 | 是什么 | 类似……但 |
|---|---|---|
| **OLAP** | 「查询不多，但每条都要读几百万行」的负载 | **一份季度 vRealize 报表**，但拆分维度是在提问的那一刻才想出来的，而不是预先规划好的 |
| **列式数据库** | 把每个字段作为独立的数据流存储 | **没有直接的类比**，但它只读取你请求的字段。不过，修改单个值的代价很高 |
| **ClickHouse** | 一种列式数据库；这里是来自目录的一项托管服务 | 不是 PostgreSQL 的替代品，而是对它的补充 |
| **MergeTree** | ClickHouse 中表的主要存储方式 | 数据以 part 的形式存放，这些 part 会定期合并成更大的 |
| **排序键（`ORDER BY`）** | part 内部数据的排列顺序 | **磁盘上文件的顺序**，但它是唯一真正的「索引」。每张表只有一个，而且要预先选定 |
| **HTTP 接口** | 用一个普通的 HTTP 请求与 ClickHouse 对话的方式 | 查询以文本形式放在 POST 的请求体里发出，答案以表格形式返回 |

本实验其余的术语——OLTP、行式数据库、part、mutation（变更）、shard（分片）、replica（副本）、Keeper——会在用到它们的那一步随进度引入。现在不必去背：脱离了实际操作，它们记不住。

<details>
<summary><b>如果你想一次看到完整列表</b></summary>

| 术语 | 是什么 | 类似……但 |
|---|---|---|
| **OLTP** | 「许多小操作」的负载：创建一条申请、修改一个状态 | **vCenter 操作它自己的数据库**，但每个操作只触及寥寥几行——只是操作的数量很多 |
| **行式数据库** | 把记录整条存储，一行接一行 | **datastore 上的文件：每个都整块存放**，但正因为如此，改一行很容易，而快速对一列求和却很难 |
| **Part** | 一次插入在磁盘上产生的一块数据 | 你不会手动去动它们，但它们的数量和大小解释了系统的行为 |
| **Mutation（变更）** | 对行的一次延迟的修改或删除 | 它不是原地完成的：它会在后台重写整个 part |
| **Shard（分片）** | 数据的一部分，放在一组单独的服务器上 | 关乎容量，而非可靠性 |
| **Replica（副本）** | 数据的一份完整拷贝 | **datastore 的副本**，但关乎可靠性，而非容量 |
| **Keeper** | 各个副本之间相互协调所借助的服务 | **一块仲裁盘（quorum disk）**，但只有在副本多于一份时才需要 |

</details>

## 实验目录里有什么

你已经有了所有文件——它们随仓库一起给到你了。不需要创建或重新输入任何东西：下文凡是写着 `kubectl apply -f 名称.yaml` 的地方，文件都来自这里。

```bash
cd labs/09-clickhouse
```

| 文件 | 是什么 | 何时用到 |
|---|---|---|
| `clickhouse.yaml` | 分析数据库的订单——和控制台里的按钮效果相同 | 你要在**租户里**应用它，而不是在实验集群 `lab` 里 |
| `01-schema.sql` | 进出事件的表 | 在数据库里执行 |
| `02-generate.sql` | 生成一百万行，好让有东西可算 | 接着执行 |
| `03-report.sql` | 报表本身——「有多少访客、高峰在什么时候」 | 最后执行 |
| `check.sh` | 检验报表确实能算出来，而且用时合理 | 在实验结束时运行 |

## 步骤 1. 订购 ClickHouse

📍 **在哪里：** 在浏览器里，在 Cozystack 控制台中，在你的租户里。

租户 → **创建应用** → `ClickHouse`。

| 字段 | 取值 | 为什么这样 |
|---|---|---|
| Name | `analytics` | 简短——后面要把它输入到地址里 |
| Replicas | **1** | 一个教学测试环境。这些是**服务器**的副本，不是数据的副本——见下方警告 |
| Shards | **1** | 一百万行很少。当数据在一台服务器上放不下时才分片 |
| Size | `5Gi` | 一百万行占几兆字节；其余是余量 |
| Log storage size | `2Gi` | 用于服务器自身文本日志的存储卷，`/var/log/clickhouse-server` |
| Log TTL | `15` | 超过十五天的查询日志会被丢弃 |
| Storage class | `replicated` | 数据会以三份副本落在不同节点上 |
| Resources preset | `u1.small` | 1 个处理器，4 GB。分组是在内存里计算的 |
| Users | 用户 `analyst`，自己设一个密码 | 我们将以这个用户身份工作 |
| ClickHouse Keeper → enabled | **关闭** | Keeper 用于在各副本之间协调。只有一份副本——没什么可协调的 |

> ⚠️ **服务器的副本不等于数据的副本。** `Replicas` 字段会拉起好几台 ClickHouse
> 服务器，但表本身并不会被复制：我们下一步要创建的普通 `MergeTree`，
> 只存在于创建它的那台服务器上。给这样一张表设置两个副本，插入会进到一台
> 服务器，而查询有时落到它上面，有时落到空的邻居上。
>
> 要让数据真正被复制，就把表创建为 `ReplicatedMergeTree`，而协调需要开启
> Keeper。这是另一个话题，在教学测试环境里没有意义——但在你把生产环境的这个
> 数字设成二之前，必须知道这个区别。

⚠️ **设一个像样的密码并记下来。** 后面在命令里和检验脚本里都会用到它。之后你可以在控制台里查到它：应用 `analytics` →
**Secrets** 标签页 → `clickhouse-analytics-credentials`。

⚠️ **Keeper 默认开启，而这是正确的默认值。** 一旦副本多于一份，它们就需要一个地方来就「谁写了什么」达成一致。我们只有一份副本，而三份 Keeper
副本会白白浪费测试环境的资源。如果你在表单里看不到这个复选框，就展开附加参数那一节。

### 细看：clickhouse.yaml 里面是什么

实验目录里有 `clickhouse.yaml`：

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: ClickHouse
metadata:
  name: analytics
  namespace: tenant-workshopXX
spec:
  replicas: 1
  shards: 1
  size: 5Gi
  logStorageSize: 2Gi
  logTTL: 15
  storageClass: replicated
  resourcesPreset: u1.small
  users:
    analyst:
      password: 你的密码
  backup:
    enabled: false
  clickhouseKeeper:
    enabled: false
```

`apiVersion: apps.cozystack.io/v1alpha1`——从「看起来像 API」的那一面看到的 Cozystack 目录。当你点击按钮时，控制台组装出的正是这样一个对象。

`namespace: tenant-workshopXX`——**托管服务位于管理集群上你的租户里，而不是实验 0 中的实验集群里。** 这是两个不同的集群，接下来整节实验都得记住这一点。

`shards` 和 `replicas` 是两个常被混淆的不同概念。**Shard 关乎容量：** 数据被分散到几组服务器上，每组保存自己的那一部分。**Replica 关乎可靠性：** 每一份都完整保存全部数据。一百万行只有几兆字节——没什么可分片的。

`users`——用户的映射表。ClickHouse 会用给定的密码创建 `analyst`，并把它放进 Secret `clickhouse-analytics-credentials`，这个 Secret 在控制台里可见。

⚠️ 在这个 Secret 里，除了你的用户，还会出现另一个——`backup`。chart 会自己创建它，供备份机制使用。你不需要去动它。

`backup.enabled: false`——实验里不需要备份。在生产环境里，这是你第一个要开启的东西。

`clickhouseKeeper.enabled: false`——见上文，关于只有一份副本的说明。

这个文件应用的对象**不是实验集群**，而是租户：

```bash
# --kubeconfig 明确指定访问文件，并覆盖 KUBECONFIG 变量。
# 于是订单发往管理集群上的租户，而不是实验集群。
kubectl --kubeconfig ~/.kube/config apply -f clickhouse.yaml
```

对租户的管理访问在这台 bastion（跳板机）上已经配置好了——就是文件 `~/.kube/config`（基于 token，不会打开浏览器）。没有什么要去获取或保存的。

等它就绪。这需要两到四分钟：服务器启动、存储卷创建、用户建立。

## 步骤 2. 搭建一个工作用的 Pod

📍 **在哪里：** 在 bastion（跳板机）上，在实验集群里。

这里我们需要停下来，理解一下布局。

**Pod** 是 Kubernetes 里最小的执行单元：一个或多个总是同生共死的容器。vSphere 里最接近的类比是一台虚拟机，只是没有自己的操作系统、也没有自己的磁盘。从这里开始，这个词会不断出现。

**ClickHouse 位于管理集群上你的租户里。** 你在租户里的角色允许你订购和删除服务，但不允许在那里运行自己的 Pod，也不允许转发端口。这不是故障，而是一条边界。

**你的工作区是实验 0 中的实验集群。** 我们将从那里，通过 ClickHouse 的内部地址去访问它：

```
chendpoint-clickhouse-analytics.tenant-workshopXX.svc.cozy.local:8123
```

把这个名字拆成几部分：

| 部分 | 含义 |
|---|---|
| `chendpoint-` | ClickHouse operator 给自己的服务加的前缀 |
| `clickhouse-` | Cozystack 目录给应用名加的前缀 |
| `analytics` | 你在控制台里设置的名字 |
| `tenant-workshopXX` | 你的租户。替换成你自己的编号 |
| `svc.cozy.local` | 管理集群的内部名称域 |
| `8123` | HTTP 接口端口。还有 9000——用于原生协议 |

拉起工作用的 Pod。替换成你的租户编号和你的密码：

```bash
# 从这里开始一切都在实验集群里发生，所以把 kubectl 切换到它。
export KUBECONFIG=~/lab.kubeconfig
# run 用给定的镜像创建一个 Pod——集群内一台一次性的小机器。
# 镜像里带了 curl，这就够了：不需要单独的 ClickHouse 客户端。
#   --restart=Never  当里面的命令结束时不要再次拉起它
#   --env=CH_URL     存储的 HTTP 接口地址；结尾的斜杠是必需的
#   --env=CH_AUTH    用于普通 HTTP 认证的「用户:密码」对
#   --command --     两个短横线之后的一切，都是 Pod 要执行的命令
# sleep 86400 =「一整天什么都不做」：这个 Pod 只是作为工作场地。
kubectl run ch-workbench \
  --image=curlimages/curl:8.11.1 \
  --restart=Never \
  --env=CH_URL="http://chendpoint-clickhouse-analytics.tenant-workshopXX.svc.cozy.local:8123/" \
  --env=CH_AUTH="analyst:你的密码" \
  --command -- sleep 86400
# wait 会占住终端直到 Pod 启动，但最多不超过两分钟。
kubectl wait --for=condition=Ready pod/ch-workbench --timeout=120s
```

**为什么把地址和密码做成 Pod 的变量，而不是直接写在命令里。** 你在 `kubectl exec` 里输入的一切，都会进入你 shell 的历史记录，以及节点上的进程列表。Pod 的变量只设置一次，此后密码再也不会出现在命令里。

⚠️ **这并没有彻底解决问题，坦白说清楚更诚实。** 通过 `--env` 传入的值会留在 Pod 的描述里：任何有权在你的 namespace 中读取 Pod 的人都能看到它，它存在集群的数据库里，还会进入审计日志。对教学测试环境来说这可以接受，对生产环境则不行：那里密码要放进一个单独的集群对象（`Secret`——一种专门用于敏感值的对象），再通过引用挂接上去，而对象本身则由密钥存储填充。那正是讲 Secret 的那节实验的内容。

现在我们来定义一个简短的命令，免得每次都敲 `curl`。先拆解一下它由什么组成。

<details>
<summary><b>逐段拆解这条命令</b></summary>

`kubectl exec -i ch-workbench`——在工作用的 Pod 里执行某个命令。`-i` 标志会把标准输入转发进去：没有它，查询到不了 ClickHouse。

`sh -c '…'` 用单引号括起来——字符串原样传进去，`$CH_AUTH` 是**在 Pod 内部**、从 Pod 的变量展开的。你的 bastion（跳板机）看不到这些值，也不会把它们写进命令历史。

`curl -sS`——安静地运行，但要报告错误。`-s` 去掉进度指示，`-S` 把 `-s` 本会吞掉的错误信息找回来。

`-u "$CH_AUTH"`——用户名和密码。ClickHouse 接受普通的 HTTP 认证。

`--data-binary @-`——「把请求体原样从标准输入取来」。SQL 正是这样进入 ClickHouse 的：**查询就是一个普通 POST 请求的请求体**，而不是什么特殊协议。由此有个推论：要访问 ClickHouse，你不需要驱动。`curl` 就够了，这在排查问题时常常帮上忙。

`?default_format=PrettyCompact`——以什么形式返回答案。`PrettyCompact` 是给人看的表格。格式有三十多种；下面我们会用到 `JSON`。

</details>

```bash
# 我们定义 ch——一条长命令的简称。从这里起，「ch」的意思是：把标准输入传来的
# SQL 发给 ClickHouse，并以表格形式显示答案。
# 这个名字在你关闭这个终端窗口前一直有效；在新窗口里要重新定义它。
ch() {
  kubectl exec -i ch-workbench -- sh -c \
    'curl -sS -u "$CH_AUTH" --data-binary @- "$CH_URL?default_format=PrettyCompact"'
}
```

检查一下连接：

```bash
# echo 打印一个字符串，| 把它传给 ch 的输入。SELECT version() 是可能的最廉价
# 查询：服务器不从磁盘读取任何东西，只报出自己的版本。
echo 'SELECT version()' | ch
```

**你应当看到**——一个小框里显示 ClickHouse 的版本号。

⚠️ **如果命令毫无反应，或以 `Could not resolve host` / `Connection refused` 失败**——再往下走没有意义。常见原因按可能性从高到低：你没有把 `workshopXX` 替换成自己的编号；控制台里的应用还没就绪；服务名里有拼写错误。如果答案是 `Authentication failed`，说明连接是通的，只是密码不对：用正确的 `CH_AUTH` 重新创建 Pod。

Windows PowerShell 用户，你们的版本：

```powershell
# $input——通过左侧管道进入函数的内容。
# 行尾的反引号把命令续接到下一行。
function ch {
  $input | kubectl exec -i ch-workbench -- sh -c `
    'curl -sS -u "$CH_AUTH" --data-binary @- "$CH_URL?default_format=PrettyCompact"'
}
"SELECT version()" | ch
```

## 步骤 3. 创建进出日志表

📍 **在哪里：** 在 bastion（跳板机）上，在实验集群里。

我们为进出日志建一张表：每次刷闸机一行。文件 `01-schema.sql` 在实验目录里，应用之前值得先读一读——其中有两行决定了后面哪些查询会快、哪些不会。

<details>
<summary><b>逐行走读表结构</b></summary>

```sql
-- IF NOT EXISTS——如果表已存在就不要报错。这个文件可以应用两次。
CREATE TABLE IF NOT EXISTS passes
(
    pass_id      UInt64,                 -- 通行证编号
    created_at   DateTime,               -- 此人通过闸机的时间
    guest_name   String,                 -- 访客姓名：各不相同
    host_dept    LowCardinality(String), -- 接待方所在部门：取值不多
    entrance     LowCardinality(String), -- 入口：一共三个
    pass_type    LowCardinality(String), -- 一次性、按周、车辆
    duration_min UInt16                  -- 访客在里面停留了多少分钟
)
ENGINE = MergeTree               -- 如何存储：磁盘上的 part，后台合并
ORDER BY (created_at, entrance)  -- 按什么顺序存放数据；它也是索引
```

`UInt64`、`UInt16`——8 字节和 2 字节的无符号整数。在 ClickHouse 里，类型的大小是有意选择的：十亿行乘以多出来的四个字节就是四个吉字节。对于以分钟计的时长，两个字节绰绰有余。

`LowCardinality(String)`——取值种类很少的字符串。我们有三个入口名称、五个部门。ClickHouse 把这类字段存成字典：磁盘上是数字，而不是重复了一百万次的词。节省巨大，我们会用数字看到它。

⚠️ **规则是这样的：** 不同取值在几千个以内——用 `LowCardinality`；超过这个数——用普通的 `String`。把几乎总是唯一的访客姓名包进 `LowCardinality`，只会让情况变糟：字典会变得比数据本身还大。

`ENGINE = MergeTree`——主要的存储方式。每次插入都在磁盘上放一个新的 **part**，这些 part 在后台合并成更大的。顺便由此得出一条重要的实用规则：应当**成批、一次插入很多行**，而不是一次一行。一百万次单行插入会创建一百万个 part，把服务器压垮。

```sql
ORDER BY (created_at, entrance)
```

这是文件里最重要的一行，而且要在开始写入数据之前就选定它。

`ORDER BY` 设定了**数据在磁盘上物理存放的顺序**。它同时充当唯一真正的索引：ClickHouse 每隔几千行留下标记，并借此判断文件的哪些部分可以完全跳过不读。

查询「三月有多少次进出」会变成「读文件的这一段」。查询「找到编号 424242 的那次进出」则什么也变不成：`pass_id` 不在排序键里，所以只能把整列都读一遍。我们会在单独的一步里看到这一点，它不是实现的缺陷，而是设计的直接结果。

**一个来自熟悉世界的类比。** 排序键就像决定把纸质通行证按什么顺序归档：按日期，还是按姓氏。按日期归档，三月的卷宗一下子就抽出来，而要找某个具体的 Ivanov 就得一张张翻。而且没人会事后把一百万张纸重新归档。

</details>

**应用它。**

```bash
# < 读取文件并把它喂给 ch 的输入，也就是把文件内容作为单条查询发给
# ClickHouse。CREATE TABLE 返回空答案——这就是成功。
ch < 01-schema.sql
```

## 步骤 4. 生成一百万条记录

📍 **在哪里：** 在 bastion（跳板机）上，在实验集群里。

我们没有进出数据，却需要一百万条。我们会直接在 ClickHouse 内部生成它——不用导出、脚本或中间文件。先看看生成器由什么组成。

<details>
<summary><b>逐行走读生成器</b></summary>

```sql
INSERT INTO passes
SELECT …
FROM numbers(1000000)
```

`numbers(1000000)`——一个内置的生成器表：一百万行，只有一列 `number`，从 0 到 999999。它不从磁盘读取任何东西，现实中并不存在，是即时计算出来的。这是一个标准技巧：ClickHouse 里的任何测试数据都是这样造出来的。

```sql
    number AS pass_id,
```

通行证编号。唯一的，因为 `number` 是唯一的。

```sql
    addDays(
        toDateTime('2026-01-01 00:00:00'),
        toUInt16(sqrt(cityHash64(number, 'day') % 57600))
    )
```

`cityHash64(number, 'day')`——一个快速的哈希函数。它从行号造出一个伪随机数，而相同的输入总是得到相同的结果。第二个参数 `'day'` 是「盐」：换一个盐，同一个数字会得到不同的结果。我们就是这样，从单个 `number` 造出任意多个相互独立的随机值。

`% 57600` 给出 0 到 57599 之间的数，对它取 `sqrt` 得到 0 到 239，也就是八个月之内的某一天。这里的平方根不是为了好看：它**把数据向时段的末尾聚集**。访客随时间越来越多——就像现实中一样，而这正是管理层想在报表里看到的。

```sql
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
```

到达的小时。我们不用均匀的「8 到 18」，而是从一个数组里取值，数组里各个小时以不同频率重复：十出现三次，十五三次，八只出现一次。这产生了**两个明显的高峰**——午饭前和午饭后。这正是管理层让我们找的东西，而当测试数据里就含有我们即将去找的东西时，是件好事。

⚠️ ClickHouse 里数组下标从一开始，而不是从零。所以有 `1 + …`。

```sql
    ['北门', '北门', '北门',
     '南门', '南门', '西门'][1 + cityHash64(number, 'entrance') % 6] AS entrance
```

同样的技巧用于制造不均匀的分布：北入口获得一半的人流，南入口三分之一，西入口是剩下的。均匀的数据在报表里显得不真实，也什么都说明不了。

```sql
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
```

访问时长从 30 到 329 分钟。需要 `toUInt16`，是因为列的类型是显式声明的，而算术运算的结果更宽。

**这花了多长时间。** 一百万行在几秒内生成并写入，完全在服务器内部完成。数据没有走网络，没有经过你的 bastion（跳板机），也没有落在中间文件里。把它和造测试数据的惯常做法——一次插入一行的脚本——比一比。

</details>

**应用它。**

```bash
# 文件里只有一条 INSERT … SELECT：ClickHouse 会自己造出一百万行并写入，
# 全程不离开服务器。
ch < 02-generate.sql
```

**你应当看到**——一个空答案，几秒后提示符回来。`INSERT` 返回空答案就是成功。

检查一下结果：

```bash
# 不带条件的 count() 回答「表里一共有多少行」这个问题。
echo 'SELECT count() FROM passes' | ch
```

**你应当看到**——`1000000`。

## 步骤 5. 管理层要的那份报表

📍 **在哪里：** 在 bastion（跳板机）上，在实验集群里。

正是管理层要的那份报表：每个月有多少访客、一次访问平均持续多久、人们最常在哪个小时到达、哪个入口更繁忙。文件 `03-report.sql` 是单条查询；运行前我们先拆解它。

<details>
<summary><b>逐行走读报表</b></summary>

```sql
-- 数据中出现的每个月，对应一行报表。
SELECT
    toStartOfMonth(created_at)          AS month,        -- 归到哪个月
    count()                             AS guests,       -- 这个月里有多少次进出
    round(avg(duration_min))            AS avg_minutes,  -- 平均访问时长
    topK(1)(toHour(created_at))[1]      AS peak_hour,    -- 最频繁的到达小时
    topK(1)(entrance)[1]                AS busiest_entrance  -- 最频繁的入口
FROM passes
GROUP BY month   -- 把同一个月的所有行折叠成一行答案
ORDER BY month   -- 按升序输出月份
```

`toStartOfMonth` 把精确时间变成当月的第一天。按周期分组的经典技巧：不用「按年和月分组」，而是用一个既能分组又能排序的单一值。

`count()`——落入分组的行数。这正是「每月多少访客」。

`topK(1)(x)[1]`——分组中 `x` 出现最频繁的值。`topK(1)` 返回一个只有一个元素的数组，`[1]` 把它取出来。高峰小时和最繁忙的入口，就是这样一起进到同一行报表里的。

值得单独指出这条查询里没有什么：子查询、临时表或 join。一切都在对数据的单次扫描中算完。

</details>

**应用它。**

```bash
# 对整张表做一次分组。答案有多少行，取决于数据中出现了多少个月份。
ch < 03-report.sql
```

**你应当看到**——八行，每月一行，访客数逐渐增长。

现在是重点——**它算了多久**。查询末尾的 `JSON` 格式会给答案加上一个统计块：

```bash
# <<'SQL' … SQL——一种把多行文本传给命令输入、又不用文件的方式。
# SQL 两侧的引号意思是「内容原样别动」：否则 shell 会试图
# 把查询里的字符当成它自己的来解释。
ch <<'SQL'
-- 同一份报表，精简到两列：月份和访客数。
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM passes
GROUP BY month
ORDER BY month
FORMAT JSON  -- 答案不以表格返回，而以 JSON 返回：里面含有一个统计块
SQL
```

把输出滚动到最后：

```json
    "statistics": {
        "elapsed": 0.0089,
        "rows_read": 1000000,
        "bytes_read": 4000000
    }
```

**一百万行，约九毫秒。** 你的数字会是你自己的，但数量级一样——个位数或几十毫秒。

<details>
<summary><b>这份报表在普通数据库上会怎么做</b></summary>

设想那个熟悉的场景：进出日志放在 PostgreSQL 或 MS SQL 里，就紧挨着通行证服务本身。

**查询会怎样。** 行式数据库把一条记录整条存储：编号、时间、访客姓名、部门、入口、类型、时长——全都挨在一行里，一个接一个。要按月计算 `count()`，它必须遍历每一行，也就意味着**从磁盘读出所有字段**，包括报表里根本用不到的访客姓名。在一百万行上这是几十秒；在一千万行上是几分钟。

你可以用 `created_at` 上的索引、覆盖索引、物化视图或预聚合表来绕开这个问题。每种方案都管用，而每一种都意味着：得有人**预先知道会要哪份报表**。换一个拆分维度，就又回到原点。

**服务会怎样。** 一条重查询会和生产负载争抢磁盘和内存。报表在计算的时候，入口处的门卫看到的是转圈的指示。「报表只在夜里跑」这条规矩就是这么来的，而由它又衍生出——只读副本、每晚导出、对不上的数字，以及「为什么报表显示的是昨天的数据」这个问题。

**人们实际会怎么做。** 他们在旁边立起第二个数据库，为分析而建，把数据灌进去。这正是我们刚才做的，只不过这第二个数据库是从目录里十分钟起来的，而不是用一个季度、靠一个上线项目搞起来的。

| | 行式（PostgreSQL） | 列式（ClickHouse） |
|---|---|---|
| 按编号查一张通行证 | 微秒级，走索引 | 读取整列 |
| 修改一张通行证的状态 | 微秒级 | 在后台重写 part |
| 按月统计访客 | 秒级或分钟级 | 毫秒级 |
| 添加一行 | 家常便饭 | 成批更好；一次一行则很糟 |
| 事务 | 完备的 | 没有通常意义上的事务 |

两列里没有哪一列「更好」。它们是用于不同工作的工具，而正确的答案几乎总是两者都要，各就其位。

</details>

## 步骤 6. 为什么它快：看看列

📍 **在哪里：** 在 bastion（跳板机）上，在实验集群里。

「列式」这个词听起来很抽象，直到你看见数字。

```bash
ch <<'SQL'
-- 我们直接问 ClickHouse，表的每一列占多少空间。
SELECT
    name,                                                    -- 列名
    formatReadableSize(data_compressed_bytes)   AS on_disk,  -- 磁盘上占多少
    formatReadableSize(data_uncompressed_bytes) AS raw,      -- 不压缩的话会是多少
    round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio  -- 压缩了多少倍
FROM system.columns   -- 一张系统表：ClickHouse 在其中描述自己
WHERE database = currentDatabase() AND table = 'passes'   -- 只看我们这张表
ORDER BY data_compressed_bytes DESC   -- 最重的列排在最上面
SQL
```

**你应当看到**——大致这样一幅图景：

```
name          on_disk    raw       ratio
guest_name    5.20 MiB   13.4 MiB  2.6
pass_id       3.81 MiB   7.63 MiB  2.0
created_at    1.20 MiB   3.81 MiB  3.2
duration_min  1.10 MiB   1.91 MiB  1.7
entrance      35.1 KiB   1.00 MiB  29.2
pass_type     41.0 KiB   1.05 MiB  26.1
host_dept     52.3 KiB   1.10 MiB  21.4
```

你的数字会是你自己的，但比例是一样的。

<details>
<summary><b>这里能看出什么，以及它为何解释了速度</b></summary>

**第一：每个字段分开存放。** 这就是「列式」的含义。在行式数据库里，磁盘上是「第 1 行整条、第 2 行整条、第 3 行整条」。这里则是「`created_at` 全部连成一片、`entrance` 全部连成一片、`guest_name` 全部连成一片」。

由此得到当初做这一切所追求的结果：**查询只读取它提到的字段。** 按月报表需要 `created_at` 和一个行计数器。它会读一兆多一点，而不会去碰占了五倍空间的访客姓名。

行式数据库对同一条查询会把所有东西都读进来。不是因为它写得差，而是因为字段是混在一起存的：要拿到第 500001 行里的时间，你必须读取那个把时间和其余一切放在一起的块。

**第二：看看 `entrance` 的 `ratio`。** 二十九倍。从三个选项中取出的一百万个值，被压缩得几乎不剩什么。

`LowCardinality` 就是这样工作的：磁盘上有一个三个字符串的字典和一百万个小数字，除此之外还有通用压缩，而对压缩来说，连续相同的数字是一份大礼。对于每个值都不同的 `guest_name`，压缩只有两倍半。

**第三，而且这打破直觉：压缩让事情更快，而不是更慢。** 看上去解压是额外的活儿。实际上瓶颈是磁盘，而不是处理器：读 35 千字节再
解压，比读一兆还要快。这就是为什么列式数据库积极地压缩，并且赢两次——赢在空间，也赢在时间。

</details>

我们来确认查询确实读得很少。对单个小列做一次计数：

```bash
ch <<'SQL'
-- 我们统计超过一百分钟的访问。这条查询在七列里只点了一列——所以
-- 它应当只读表的一小部分。我们用 bytes_read 来验证。
SELECT count() FROM passes WHERE duration_min > 100 FORMAT JSON
SQL
```

看输出末尾的 `bytes_read`，把它和表的数据量比一比：

```bash
ch <<'SQL'
-- 我们把所有列的未压缩体积加起来。这正是「一共有多少数据」——
-- 也就是上一段输出里的 bytes_read 应当拿来对比的那个数值。
SELECT formatReadableSize(sum(data_uncompressed_bytes)) AS total
FROM system.columns
WHERE database = currentDatabase() AND table = 'passes'
SQL
```

⚠️ **必须和未压缩的体积比，而不是和磁盘上的大小比。** 查询统计里的 `bytes_read` 是数据库解压并读取的量——一个未压缩的数值。用它除以 `bytes_on_disk`，得到的是相对于压缩后数据的一个比值，而在压缩良好的表上，这样的「比值」轻易就会超过百分之一百。数值必须可比，否则这个数字虽然好看，却毫无意义。

这条查询扫过了一百万行，却只读了数据的百分之几：它读了 `duration_min`，没有碰 `guest_name`。

## 步骤 7. 找出高峰

📍 **在哪里：** 在 bastion（跳板机）上，在实验集群里。

管理层问题的后半部分是关于入口排队的。我们会统计一天中每个小时有多少次进出，并直接在终端里画成柱状。这条查询有两部分——运行前我们先拆解它。

<details>
<summary><b>拆解这条查询</b></summary>

内层查询是一次普通的分组：一天中每个小时有多少次进出。输出十一行。

外层给它们加上一幅图。`bar(value, from, to, width)` 画出一条伪图形的柱子——这是 ClickHouse 的一个内置函数，做出来正是为了让你在终端里看结果，而不必打开 Excel。

`max(guests) OVER ()`——一个窗口函数：在**整个结果**上取最大值，而不是在某个分组上。`OVER` 后面的空括号表示「窗口就是全部行」。需要它，是为了让最长的柱子恰好是五十个字符，其余的按比例。

为什么不能不带 `OVER ()` 直接写 `max(guests)`：那样它会是一个聚合函数，会把十一行折叠成一行。窗口函数算的是同一个东西，却把行留在原处。

</details>

```bash
ch <<'SQL'
SELECT
    hour,                                     -- 一天中的小时
    guests,                                   -- 这个小时有多少次进出
    bar(guests, 0, max(guests) OVER (), 50) AS chart  -- 一条伪图形的柱子
FROM
(
    -- 内层查询：按小时的普通分组
    SELECT toHour(created_at) AS hour, count() AS guests
    FROM passes
    GROUP BY hour
)
ORDER BY hour   -- 小时按升序，好让这幅图从上往下读
SQL
```

**你应当看到**——两个驼峰：上午十点左右和下午三点左右。

给管理层的答案已经就绪：高峰在 10 点和 15 点，正是在这两个小时，往入口再加一个人才有意义。

顺便看看查询日志——ClickHouse 把每一条查询都记在那里：

```bash
ch <<'SQL'
-- 每一条执行过的查询，ClickHouse 都记录在系统表 system.query_log 里。
SELECT
    event_time,                                       -- 查询何时完成
    query_duration_ms,                                -- 用了多少毫秒
    formatReadableQuantity(read_rows) AS rows_read,   -- 读了多少行
    formatReadableSize(read_bytes)    AS bytes_read,  -- 为此拉起了多少字节
    -- 查询文本：把其中的换行折叠掉，取前 50 个字符，
    -- 否则输出在屏幕上放不下
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 50) AS query
FROM system.query_log
WHERE type = 'QueryFinish'  -- 只看已完成的：开始时另有一条记录
  AND user = 'analyst'      -- 只看你的，不含服务器自己的内部查询
ORDER BY event_time DESC    -- 最近的排在上面
LIMIT 10                    -- 十条就够了
SQL
```

你全部查询的历史，带着时长和读取的量。这是一张普通的表，它存在数据卷里，而不是日志卷里：订单表单里的 `Log storage size` 说的是服务器的文本日志，而不是这份日志。这份日志的保留期由 `Log TTL` 设定。在生产环境里，正是这张表回答「为什么昨晚七点一切都很卡」这个问题。

⚠️ 日志每隔几秒才刷一次盘，所以最新的那条查询可能还不在里面。重复执行命令。

## 一次可预见的失败 · 按编号查一张通行证

报表都好了。保安带着一个日常请求过来：**找出编号 424242 的那次进出。**

查询自己就冒出来了：

```bash
ch <<'SQL'
-- 我们按通行证编号找单独一行。SELECT * 表示「返回所有列」。
SELECT * FROM passes WHERE pass_id = 424242 FORMAT JSON
SQL
```

这一行会找到。但别看它，看输出末尾的统计——看 `rows_read`。

> **在往下读之前，停下来想一想。**
>
> 数据库读了多少行才返回一行？换成带 `pass_id` 索引的 PostgreSQL 会读多少？差距为什么恰恰这么大？

<details>
<summary><b>答案，以及一个比这个错误更深远的教训</b></summary>

`rows_read` 会是大约 **1 000 000**。为了返回单独一行，ClickHouse 读了整个 `pass_id` 列。

原因就是我们在本实验稍早处梳理过的那个：**ClickHouse 里唯一真正的索引是排序键**，而我们的是 `(created_at, entrance)`。数据不是按 `pass_id` 排序的，没有依据可以跳过 part，剩下的只有全表扫描。

带 `pass_id` 索引的 PostgreSQL 会读几页树节点和一行数据。相差五个数量级——而且不利于 ClickHouse。

现在做同一件事，但做对。保安通常知道的不只是编号，还有**它发生的时间**：

```sql
-- 同样的查找，但加了时间范围。created_at 上的条件落在
-- 排序键里，ClickHouse 会丢弃那一天之外的一切。
SELECT * FROM passes
WHERE created_at >= '2026-03-01' AND created_at < '2026-03-02'
  AND pass_id = 424242
FORMAT JSON
```

现在看 `rows_read`——是几千，而不是一百万。`created_at` 上的条件落进了排序键，ClickHouse 丢弃了除所需那一段之外的每个 part。如果这张通行证是在另一天，可能找不到——重要的不是找没找到，而是读了多少行。

**一个比这个错误更深远的教训。** ClickHouse 不是「快数据库」。它是为一种工作而建的数据库：在少数几列上读许多行，然后算点什么。在这种工作上，它以数量级的优势甩开行式数据库。在相反的工作上——找一行、改一个字段、回滚一个事务——它又以同样多的数量级落在它们后面。

由此得出一条值得带走的实用规则：

| 任务 | 放哪里 |
|---|---|
| 申请一张通行证、修改它、取消它 | 服务旁边的普通数据库 |
| 按编号查某张具体的通行证 | 同一处 |
| 年度报表、漏斗、高峰、趋势 | ClickHouse |
| 事件日志、指标、日志 | ClickHouse |

两个数据库在同一个租户里，都来自目录，都在几分钟内启动。不再需要挑「一个包打天下」——而这，也许，正是相比那个「每新增一个数据库就意味着一台新 VM 和一张新工单」的世界的最大变化。

</details>

## 步骤 8. 坦白说说这里别扭的地方

📍 **在哪里：** 在 bastion（跳板机）上，在实验集群里。

一位访客改了姓；有一条记录需要更正。在普通数据库里这是一条 `UPDATE`，微秒级。

先留意一下语法：不是 `UPDATE passes SET …`，而是 `ALTER TABLE … UPDATE`。这不是作者的任性，而是一个诚实的警告：**你运行的不是一次行更新，而是一次对表的改动。**

```bash
ch <<'SQL'
-- 我们在一行里改一位访客的姓名。命令会立即交回控制权，但工作
-- 并没有到此结束：ClickHouse 会把它排进队列，在后台执行。
ALTER TABLE passes UPDATE guest_name = '王军' WHERE pass_id = 424242
SQL
```

看看正在发生什么：

```bash
ch <<'SQL'
-- 表的延迟改动队列——ClickHouse 的又一张系统表。
SELECT
    command,       -- 具体被要求做什么
    is_done,       -- 工作完成则为 1
    parts_to_do,   -- 还剩多少个 part 要重写
    create_time    -- 任务何时被排进队列
FROM system.mutations
WHERE table = 'passes'
ORDER BY create_time DESC
SQL
```

<details>
<summary><b>什么是 mutation，以及它为何昂贵</b></summary>

命令立即交回了控制权，而工作被排进了队列。这样延迟的工作叫做 **mutation（变更）**，可以在 `system.mutations` 里看到：`is_done` 显示它是否完成，`parts_to_do`——还剩多少个 part 要重写。

为什么要重写。数据以列的形式存放在压缩的 part 里。你无法改动压缩块内部的单个值——这个块必须被解压、修改、压缩，再重新写入。实际上 ClickHouse 会重写**整个 part**，连同它所有的列。

在我们这一百万行上，这是零点几秒，`is_done` 多半已经是 `1`。在一张十亿行的表上，同样的操作就是数小时的磁盘工作，以及重写期间加倍的空间占用。

由此得出在 ClickHouse 世界里被视为理所当然的一些规则：

- **不要修改数据。** 只往里追加。进出日志本来也不该变：一次进出要么发生了，要么没发生
- 如果某条记录确实需要更正，就写入这一行的一个新版本，读取时取最新的那个。为此有一种专门的表（`ReplacingMergeTree`）
- 删除旧数据不是用查询，而是用保留期（`TTL`）：「丢弃超过三年的行」。这样删的是整个 part，而不是单独的行
- 批量修改被汇集成一次少见的操作，而不是一百次小操作

**还有一样这里完全没有的东西：通常意义上的事务。** 把钱从一个账户转到另一个账户、要么两个操作都生效要么都不生效，在 ClickHouse 里做不到。这不是实现上的缺口——而是为了读取速度而有意的放弃。正因如此，ClickHouse 不被放在通行证服务之下，而是放在它旁边。

</details>

## 验证

📍 **在哪里：** 在 bastion（跳板机）上，在你刚才用 `kubectl` 工作的同一个终端窗口里。

```bash
cd labs/09-clickhouse
# 脚本会读取这三个环境变量，所以必须在运行它之前、
# 并且在同一个终端窗口里设置好它们。
export KUBECONFIG=~/lab.kubeconfig       # 检查哪个集群
export COZY_TENANT=workshop03            # 你的租户编号
export CH_PASSWORD='你的analyst密码'  # 订购 ClickHouse 时你设的那个
./check.sh
```

⚠️ **在 Windows 上，脚本从 WSL 里运行**，而不是从 PowerShell——如何安装它在实验 0 的开头有说明。没有 WSL 也能完成本实验，只是不会有产物报告。

脚本检查的不是服务被创建这个事实，而是实打实的工作：表存在，行数不少于一百万，数据里有明显的高峰，按月报表在毫秒级算完，而对单列的查询只读表的一小部分。

密码不会进入报告。

## 清理

```bash
# 工作用的 Pod 什么都不保存：所有工作都在 ClickHouse 内部发生，Pod 只是
# 把查询传递过去。删掉它，不必可惜。
kubectl delete pod ch-workbench
```

ClickHouse 本身在控制台里删除：应用 `analytics` → 删除。

为什么这很便宜。在传统基础设施里，一个分析数据库是一台 VM（更可能是三台）、磁盘、安装、配置、监控，以及一个为这一切负责的人。你没法把它还回去：空间已经分配，许可证已经买了，还有那句「万一以后要用呢」。而这里，你把一个服务借用一小时，十秒钟就还了回去，它占用的空间也随之释放。

⚠️ **删除它的同时也会删掉表。** 一百万行几秒就能重新生成，所以在实验里这算不上损失。如果你往里放了真实的东西——先开启备份，它在订单表单里是单独的一节。

## 现在我们能做什么

- 不用言语，而用压缩和读取字节的数字，来解释行式数据库和列式数据库的区别
- 从目录里启动 ClickHouse，并理解为什么表单里有 shard、replica 和 Keeper
- 有意识地选择排序键，并预测哪些查询会快
- 在数据库内部生成逼真的测试数据，不用脚本或导出
- 用一条查询、而不是导出到 Excel，来回答「高峰在什么时候」这个问题
- 明白 ClickHouse 在哪里落下风，不把它放在需要普通数据库的地方

## 换成 vSphere 会是

为分析数据库准备一台单独的机器——而几乎立刻就发现一台不够：你还需要第二台放副本，还要空间放每日导出。「每月多少访客」这份报表，变成了一个带有自己的硬件、自己的监控和自己的负责人的基础设施项目。

而这里——目录里的一项和十分钟，包括生成一百万行。

**坦白说说 vSphere 更方便的地方。** 一台带数据库的 VM 是一台你能走过去的机器。用 SSH 登进去，看 top，改配置，在旁边放一个脚本，在危险操作前打一个快照、不行就回滚。托管服务**有意**不给你这些：在租户里，你既不被允许 `exec` 进 Pod，也进不了日志。你通过订单表单管理服务，而不是通过它底下的那台机器。

只要一切正常，这就是一种优势——把东西弄坏的途径更少了。当某样东西表现得奇怪时，这个限制就被强烈地感受到：管理员惯用的那套动作用不了，剩下的只有去找运维这个平台的人。查询日志和指标能覆盖这份痛苦的一部分，但不是全部，而假装它们能覆盖全部，是不诚实的。

还有一件人们后来才想起的事。托管服务意味着别人的默认值。ClickHouse 的版本、part 合并的参数、内存设置，都是替你选好的。通常合理，有时并不契合你的负载，而你没法像在自己机器上那样自由地更改它们。
