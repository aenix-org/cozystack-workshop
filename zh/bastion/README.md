# 工作坊：将 VMware 虚拟机迁移到 Cozystack（通过 bastion）

我们把一个在 VMware 虚拟机上运行了多年的应用，搬到 Cozystack。整个过程都由你亲手完成。

**这是走共享 VM（bastion）的路线。** 你不需要在自己的笔记本上安装任何东西：`kubectl`、`virtctl` 和 `git` 都已经装在 bastion 上，你在那里访问集群的权限也已经配好。你通过 SSH 登录进去，直接在上面干活，最后在浏览器里用域名打开做好的应用。

> 如果你想从自己的笔记本上工作（自己安装工具、通过 `port-forward` 访问应用）——那你需要另一套材料，[`../laptop/`](../laptop/)。

这个文件就是路线图：先做什么、后做什么、要敲哪些命令、最终应该得到什么。至于为什么这样设计、以及对清单（manifest）和脚本逐行的讲解，都放在 [`chat/`](chat/) 文件夹里——每条消息一个文件。链接都放在每个步骤的末尾。

## 路线

这个应用跑在三台机器上：应用本身、数据库和消息队列。我们只搬第一台——数据库和队列留在原地，取而代之的是从 Cozystack 目录里现成的那些。

| 阶段 | 我们做什么 | 在哪里 |
|---|---|---|
| 1 | 为镜像准备存储 | 在 bastion 上 |
| 2 | 把磁盘从 VMware 格式重新打包成 KVM 格式 | 在一台临时机器里 |
| 3 | 让机器在新家里启动起来 | 在 bastion 上 |
| 4 | 从目录里订购数据库和队列 | 在 bastion 上 |
| 5 | 修好网络，把应用切换到新地址 | 在你的机器里 |

之后是最终检查：在应用里创建的一个订单，一路走到数据库和队列。

## 讲师发给你的东西

一个用户名和一个密码——在这三个地方都一样：

* **dashboard** https://dashboard.workshop.aenix.io ——通过浏览器登录，namespace 为 `tenant-workshopXX`
* **bastion** ——通过 SSH 登录：`ssh workshopXX@<bastion-address>`
* 在 bastion 内部，访问集群的权限已经配好，kubeconfig 就放在 `~/.kube/config`

下面所有地方，都把 `workshopXX` 换成你自己的编号（讲师发给你的）。

## 登录 bastion

```bash
ssh workshopXX@<bastion-address>
```

密码和 dashboard 的一样。不需要 SSH 密钥：用密码登录。我们来确认一下集群的访问是否就绪（这里不会弹出浏览器——bastion 配置的是直接用 token 访问，不经过 Keycloak）：

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**你应该看到：** 上下文名称 `tenant-workshopXX`，以及一份（目前还是空的）机器列表。

## 材料已经在 bastion 上

没什么可克隆的——材料文件夹就在你的主目录里，清单和脚本里你的租户编号**也已经填好了**：在准备 bastion 时，`tenant-workshopXX` 占位符已被替换成你的 `tenant-workshopNN`。不用去查找替换——直接原样应用这些文件即可。

```bash
cd ~/workshop
ls manifests scripts
grep -rl tenant-workshop manifests | head -1 | xargs grep -m1 namespace   # 你会看到自己的编号
```

有一处是故意留作占位符的：在 `manifests/03-app-vm.yaml` 里那行 `url: "ВСТАВЬТЕ_PRESIGNED_URL"`——这个链接你会在第二阶段之后拿到，然后自己填进去。

详见：[chat/10](chat/10-clone-and-set-number.md) ·
文件地图 [chat/11](chat/11-file-map.md)

---

## 阶段 1. 为镜像准备存储

📍 在 bastion 上。

重新打包后的磁盘需要放到一个平台能通过网络拉取的地方。我们建一个 bucket——带 S3 接口的对象存储。

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**你应该看到：** `bucket.apps.cozystack.io/my-images created`，然后是 `READY: True`。

⚠️ **类型名要写全，别写 `bucket`。** 这个词在集群里被占用了三次：我们目录里的类型、Flux 的类型，以及对象存储标准里的类型。`kubectl` 会用短名替换成哪一个，事先并不确定；如果是别的那个，你就会在一个自己根本没请求过的资源上被拒绝权限：`buckets.source.toolkit.fluxcd.io is forbidden`。这不是访问权限的问题，不用去修它。

⚠️ **如果 `apply` 报 `SchemaError … unknown model in reference` 而失败**——绊倒的是你这一侧的校验，不是集群；清单是对的。绕开它的办法：`kubectl apply -f manifests/01-bucket.yaml --validate=false`。这个标志只关掉本地校验，服务器那边仍然会校验对象。

**接下来你会用到这些密钥：** dashboard → `Bucket` → `my-images` → `Secrets` 标签页 → `bucket-my-images-app-credentials` 这个 secret。从那里取出 `bucketName`、`accessKey` 和 `secretKey`——下一阶段你会把它们填进脚本。

清单讲解：[chat/13](chat/13-bucket-manifest.md) ·
整个步骤：[chat/14](chat/14-step-1-bucket.md)

---

## 阶段 2. 重新打包磁盘

📍 先在 bastion 上，然后进入临时机器内部。

来自 VMware 的磁盘是以 VMDK 格式写的，而 KVM 读的是 QCOW2。重新打包由 `virt-v2v` 完成；为了一次性的活儿在 bastion 上装它没意义，所以我们启动一台已经装好工具的临时机器。

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**你应该看到：** 两行带 `created`，然后是 `Running`。

⚠️ `Running` 意思是「已开机」，不是「已就绪」：机器内部 `cloudInit` 还会再干上几分钟——装软件包、下载 `mc`。登录得太早，你会找不到 `virt-v2v`。

登录进去（用户名 `ubuntu`，密码 `ubuntu`）：

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

进去后：`nano convert.sh`，把 `scripts/convert.sh` 的内容粘进去，再把你自己的 `bucketName`、`accessKey` 和 `secretKey` 填到 `ВСТАВЬТЕ_...` 的位置。

⚠️ **在 `screen` 里跑转换**——它大约要五分钟，如果你到 bastion 的 SSH 会话断了，普通方式跑的话会在半路被切断。`screen` 能把进程保住，哪怕连接掉了也在：

```bash
screen -S convert          # 开一个独立会话
sudo bash convert.sh       # 在这个会话里跑它
#  连接断了？重新 ssh 到 bastion，然后：  screen -r convert
```

**你应该看到：** 在输出的末尾，`Share:` 这个词后面——一个指向镜像的签名链接。下一阶段你会用到它。

清单讲解：[chat/15](chat/15-conversion-vm-manifest.md) ·
脚本讲解：[chat/17](chat/17-convert-script.md) ·
两个步骤完整版：[chat/16](chat/16-step-2-conversion-vm.md)，
[chat/18](chat/18-step-3-convert-image.md)

---

## 阶段 3. 机器在新家里

📍 在 bastion 上。

⚠️ 先关掉转换机——它已经干完了活，还占着你 8Gi 的配额。如果不把它清掉，新机器会卡在 `Pending`：

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

把你拿到的链接填进 `manifests/03-app-vm.yaml`，替换掉 `url: "ВСТАВЬТЕ_PRESIGNED_URL"`，然后：

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**你应该看到：** 两行带 `created`，然后是 `Running`。这里等待时间更长——平台正在从你的链接下载镜像。

登录进去（用户名 `root`，密码 `cozydemo`）：

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **机器内部不会有网络。** 这不是实验环境坏了——本该如此。我们在第五阶段修它。

清单讲解：[chat/20](chat/20-app-vm-manifest.md) ·
整个步骤：[chat/21](chat/21-step-4-your-vm.md)

---

## 阶段 4. 从目录里取数据库和队列

📍 在 bastion 上。

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**你应该看到：** `postgres.apps.cozystack.io/db created` 和 `kafka.apps.cozystack.io/kafka created`。Kafka 起来的时间明显比 Postgres 长。

清单讲解：[chat/23](chat/23-managed-manifest.md) ·
整个步骤：[chat/24](chat/24-step-5-database-and-queue.md)

---

## 阶段 5. 接通应用

📍 在你的虚拟机内部。

三个动作严格按顺序来：没有网络，脚本就够不到数据库；没有数据库，它就不会接受表结构。

| 步骤 | 我们修什么 | 用什么 |
|---|---|---|
| 5.1 | 机器不在网络里 | `scripts/netfix-dhcp.sh` |
| 5.2 | 应用在找旧地址 | `scripts/connect-managed.sh` |
| 5.3 | 新数据库里没有表 | `scripts/orders-schema.sql` |

**5.1.** 脚本把 `BOOTPROTO=static` 改成 `dhcp`，并去掉 VMware 网络里的那个地址。你要手动敲——机器还没有网络，下载不了文件。之后机器需要**重启**：CentOS 7 在启动时才应用网络设置。

**5.2.** 脚本把 `/etc/orders/application.properties` 里写死的地址 `192.168.10.30` 和 `192.168.10.40` 替换成服务名，并重启应用。

**5.3.** 我们安装 `psql` 客户端并导入表结构——命令在下面，在最终检查里。

详见：[chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## 最终检查：三步依次进行

### 步骤 1. 关掉 firewalld

📍 在你的机器内部。这些规则是旧网络遗留下来的，正在切断对应用的请求。

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**你应该看到：** `200`。如果是 `503`——说明数据库或队列里有东西没连上。这里的 `localhost` 就是你正坐着的这台机器：应用是从内部被检查的。

### 步骤 2. 数据库表结构

📍 在你的机器内部。CentOS 7 自带的 psql 是 9.2 版，它不会 SCRAM，会回 `SCRAM authentication requires libpq version 10 or above`。我们装个新的：

```bash
# 1. PGDG 仓库——PostgreSQL 软件包的来源
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd：CentOS 7 的仓库里没有，我们从 EPEL 归档里取
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. 客户端本身——只从还活着的 pgdg15 仓库取
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ 第二条和第三条命令不是多余的。没有 `libzstd`，安装会卡在 `Requires: libzstd >= 1.4.0`。没有 `--disablerepo`/`--enablerepo`——会卡在 `HTTPS Error 410 - Gone`：这个仓库包会一次性启用所有 PostgreSQL 版本，包括已停止支持的 12 和 13，而 `yum` 在安装前会遍历每一个启用的仓库，一碰到第一个死掉的就失败。

```bash
psql --version
```

如果 `command not found`——客户端落在了 `PATH` 之外：看一下 `ls /usr/pgsql-*/bin/psql`，然后 `export PATH="$PATH:/usr/pgsql-15/bin"`。

我们把表结构取下来并导入（这台 app-VM 是能上网的，文件会下载下来）：

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**你应该看到：** 在最后一条命令里——`orders` 表。

数据库地址不是 IP，而是名字：`postgres-db-rw`（`db` 服务，读写），`tenant-workshopXX`（你的 namespace），`svc.cozy.local`（集群内部名称的后缀）。密码在 `manifests/04-managed.yaml` 里设定，哪儿都不用去找。

详见：[chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### 步骤 3. 从外部检查——用域名

📍 在你自己笔记本的浏览器里，或者在 bastion 上用 `curl`。

这里就显出这条路线的主要不同点：**不需要端口转发。** 讲师已经预先在你的租户里创建了 `Ingress`，只要机器内部的应用监听着 `8080`，商店就发布在 `https://app.workshopXX.workshop.aenix.io`（`XX` 是你的编号）。直接从那里检查：

```bash
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

**你应该看到：** 列表里的那个订单。整段旅程走完了。

⚠️ 只要 app-VM 还没起来或还在启动，域名就会回 `503`——这很正常：`Ingress` 在等后端。等机器启动之后（内部监听着 `8080`），就会变成 `200`。

详见：[chat/30](chat/30-step-9-verify-chain.md)

---

## 速查表

> **`vmi/` 前缀不是每条命令都需要，这不是笔误。** 在租户权限下，`virtctl console` 只接受**裸的**名字（`vm-instance-app-1`）；带上 `vmi/` 它会回 `forbidden`，因为它把 `vmi` 这个词当成了机器的名字。而 `virtctl ssh` 和 `virtctl port-forward` 恰恰相反，要求用 `vmi/<name>` 这种形式。

```bash
# 登录 app-VM（root / cozydemo）
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# 登录 conversion-VM（ubuntu / ubuntu）
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# 通过 SSH 进入 app-VM 的 shell（等机器的网络起来之后）
virtctl ssh ubuntu@vmi/vm-instance-app-1 --namespace=tenant-workshopXX
```

检查应用用域名 `https://app.workshopXX.workshop.aenix.io`；这条路线不需要 `port-forward`。退出控制台——`Ctrl+]`。如果连上之后屏幕是空的，按一下 Enter。同样的事情用鼠标也能做：dashboard 里机器页面上的 **VNC** 按钮。

## 容易卡住的地方

* conversion-VM 只用 `ubuntu-20.04`。在 24.04 上内核会 panic；在 22.04 上 `virt-v2v` 解析不了老的 CentOS 7 RPM 数据库。
* 用于目录镜像的 VMDisk 必须比镜像本身大，否则克隆过不去，磁盘会卡在 `Terminating`。对 `ubuntu-20.04` 来说，25Gi 就够了。
* 在一台全新的 app-VM 上，先 `netfix`，再 `connect`——否则应用看不到那些托管服务。
* 长时间的转换要在 `screen` 里跑——否则 SSH 一断就会把它切在半路。

其余的坑——[chat/31](chat/31-troubleshooting.md)。

## 给搭建实验环境的人

配额、创建租户的顺序、平台版本——都在 [REQUIREMENTS.md](../REQUIREMENTS.md) 里。

## 所有消息按顺序

27 条消息的列表——[chat/README.md](chat/README.md)。
