# 工作坊：将 VMware 虚拟机迁移到 Cozystack（从你自己的笔记本）

我们把一个在 VMware 虚拟机上运行了多年的应用，搬到 Cozystack。整个过程都由你亲手完成。

> 如果讲师给了你一台已经配好工具和访问权限的共享 VM（bastion）——那你需要的是另一套材料，[`../bastion/`](../bastion/)，那里一切都已经配好了。

这个文件就是路线图：先做什么、后做什么、要敲哪些命令、最终应该得到什么。至于为什么这样设计、以及对清单（manifest）和脚本逐行的讲解，都放在 [`chat/`](chat/) 文件夹里——每条消息一个文件。链接都放在每个步骤的末尾。

## 路线

这个应用跑在三台机器上：应用本身、数据库和消息队列。我们只搬第一台——数据库和队列留在原地，取而代之的是从 Cozystack 目录里现成的那些。

| 阶段 | 我们做什么 | 在哪里 |
|---|---|---|
| 1 | 为镜像准备存储 | 在笔记本上 |
| 2 | 把磁盘从 VMware 格式重新打包成 KVM 格式 | 在一台临时机器里 |
| 3 | 让机器在新家里启动起来 | 在笔记本上 |
| 4 | 从目录里订购数据库和队列 | 在笔记本上 |
| 5 | 修好网络，把应用切换到新地址 | 在你的机器里 |

之后是最终检查：在应用里创建的一个订单，一路走到数据库和队列。

## 讲师发给你的东西

讲师会给你：

* 控制台（dashboard） https://dashboard.workshop.aenix.io
* 用户名 `workshopXX`，密码当场发给你
* kubeconfig——在控制台里：`Info` → `Secrets` 标签页 → `kubeconfig-tenant-workshopXX` 这个 secret

下面所有地方，都把 `workshopXX` 换成你自己的编号。

## 开始之前：四个工具

它们在工作坊之前，在你的笔记本上一次性装好。

| 工具 | 做什么用 | 安装 |
|---|---|---|
| `kubectl` | 应用文件、显示集群里有什么 | [chat/04](chat/04-install-kubectl.md) |
| `virtctl` | 虚拟机控制台和端口转发 | [chat/05](chat/05-install-virtctl.md) |
| `kubelogin` | 通过浏览器登录；没有它集群不会放你进去 | [chat/06](chat/06-install-kubelogin.md) |
| `git` | 用来拉取这个仓库 | [chat/09](chat/09-install-git.md) |

⚠️ **这个工作坊不需要 krew**——原因见 [chat/07](chat/07-about-krew.md)。

确认一下一切都就位。每条命令都会打印出一个版本号或一段帮助文本，而不是 `command not found`：

```bash
kubectl version --client
virtctl version --client
kubectl oidc-login --help
```

## 连接到集群

把控制台里的 kubeconfig 存到磁盘上，再让 `KUBECONFIG` 变量指向它。

**macOS 和 Linux**——把 secret 的内容放进 `~/.kube/workshop`，然后：

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Windows（PowerShell）：**

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # 粘贴 kubeconfig；文件类型选「所有文件」
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

第一次请求时会弹出一个浏览器——用 `workshopXX` 登录。

⚠️ **Windows：文件只能存成 UTF-8。** Notepad 和 PowerShell 里的 `>` 重定向写出来的是 UTF-16，`kubectl` 读不了这样的文件——它会回 `x509: certificate signed by unknown authority`，尽管证书本身一点问题都没有。

⚠️ 报错 `dial tcp [::1]:8080 ... refused` 意思是 `kubectl` 没找到 kubeconfig，而不是集群不可达。两者的讲解——见 [chat/08](chat/08-connect-to-cluster.md)。

## 取得材料

```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/laptop
```

⚠️ 末尾的 `/laptop` 是必须的：这个文件夹装着走笔记本路线的材料，连同清单和脚本；没有它，命令既找不到 `manifests` 也找不到 `scripts`。

每个文件里都有一个 `tenant-workshopXX` 占位符。一次性把你自己的编号替换进去（示例里是 `workshop03`）：

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +

# macOS —— 同样的 sed，但 -i 之后需要一对空引号
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

```powershell
# Windows
Get-ChildItem -Path manifests,scripts -File -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw) -replace 'tenant-workshopXX','tenant-workshop03' |
    Set-Content $_.FullName -NoNewline
}
```

我们确认一下没有一个占位符被漏下：

```bash
grep -rn tenant-workshopXX manifests scripts || echo "all clean, you can continue"
```

有一处是命令故意不去碰的：在 `manifests/03-app-vm.yaml` 里那行 `url: "ВСТАВЬТЕ_PRESIGNED_URL"`——这个链接你会在第二阶段之后拿到。

详见：[chat/10](chat/10-clone-and-set-number.md) ·
文件地图 [chat/11](chat/11-file-map.md)

---

## 阶段 1. 为镜像准备存储

📍 在笔记本上。

重新打包后的磁盘需要放到一个平台能通过网络拉取的地方。我们建一个 bucket——带 S3 接口的对象存储。

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**你应该看到：** `bucket.apps.cozystack.io/my-images created`，然后是 `READY: True`。

⚠️ **类型名要写全，别写 `bucket`。** 这个词在集群里被占用了三次：我们目录里的类型、Flux 的类型，以及对象存储标准里的类型。`kubectl` 会用短名替换成哪一个，事先并不确定；如果是别的那个，你就会在一个自己根本没请求过的资源上被拒绝权限：`buckets.source.toolkit.fluxcd.io is forbidden`。这不是访问权限的问题，不用去修它。

⚠️ **如果 `apply` 报 `SchemaError … unknown model in reference` 而失败**——绊倒的是你这一侧的校验，不是集群；清单是对的。绕开它的办法：`kubectl apply -f manifests/01-bucket.yaml --validate=false`。这个标志只关掉本地校验，服务器那边仍然会校验对象。

**接下来你会用到这些密钥：** 控制台 → `Bucket` → `my-images` → `Secrets` 标签页 → `bucket-my-images-app-credentials` 这个 secret。从那里取出 `bucketName`、`accessKey` 和 `secretKey`——下一阶段你会把它们填进脚本。

清单讲解：[chat/13](chat/13-bucket-manifest.md) ·
整个步骤：[chat/14](chat/14-step-1-bucket.md)

---

## 阶段 2. 重新打包磁盘

📍 先在笔记本上，然后进入临时机器内部。

来自 VMware 的磁盘是以 VMDK 格式写的，而 KVM 读的是 QCOW2。重新打包由 `virt-v2v` 完成；为了一次性的活儿在笔记本上装它没意义，所以我们启动一台已经装好工具的临时机器。

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

进去后：`nano convert.sh`，把 `scripts/convert.sh` 的内容粘进去，再把你自己的 `bucketName`、`accessKey` 和 `secretKey` 填到 `ВСТАВЬТЕ_...` 的位置，然后运行 `bash convert.sh`。

**你应该看到：** 在输出的末尾，`Share:` 这个词后面——一个指向镜像的签名链接。下一阶段你会用到它。

清单讲解：[chat/15](chat/15-conversion-vm-manifest.md) ·
脚本讲解：[chat/17](chat/17-convert-script.md) ·
两个步骤完整版：[chat/16](chat/16-step-2-conversion-vm.md)，
[chat/18](chat/18-step-3-convert-image.md)

---

## 阶段 3. 机器在新家里

📍 在笔记本上。

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

⚠️ **机器内部不会有网络。** 这不是测试环境坏了——本该如此。我们在第五阶段修它。

清单讲解：[chat/20](chat/20-app-vm-manifest.md) ·
整个步骤：[chat/21](chat/21-step-4-your-vm.md)

---

## 阶段 4. 从目录里取数据库和队列

📍 在笔记本上。

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

**你应该看到：** `200`。如果是 `503`——说明数据库或队列里有东西没连上。

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

我们把表结构取下来并导入：

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql

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

### 步骤 3. 端口转发，并从外部检查

📍 在笔记本上。

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

别关掉这个窗口——只要命令还在运行，隧道就一直在。在另一个窗口里：

```bash
curl -s http://localhost:8080/actuator/health

curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s http://localhost:8080/api/orders
```

**你应该看到：** 列表里的那个订单。整段旅程走完了。

详见：[chat/30](chat/30-step-9-verify-chain.md)

---

## 速查表

> **`vmi/` 前缀不是每条命令都需要，这不是笔误。** 这两条命令的目标语法不一样。`virtctl console` 只接受名字，带上前缀它会回 `forbidden`，因为它把 `vmi` 这个词当成了机器的名字。而 `virtctl port-forward` 要求用 `type/name` 这种形式，不带前缀它会回 `target must contain type and name separated by '/'`。

```bash
# 登录 app-VM（root / cozydemo）
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# 登录 conversion-VM（ubuntu / ubuntu）
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# 把应用的端口转发到笔记本
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

退出控制台——`Ctrl+]`。如果连上之后屏幕是空的，按一下 Enter。同样的事情用鼠标也能做：控制台里机器页面上的 **VNC** 按钮。

## 容易卡住的地方

* conversion-VM 只用 `ubuntu-20.04`。在 24.04 上内核会 panic；在 22.04 上 `virt-v2v` 解析不了老的 CentOS 7 RPM 数据库。
* 用于目录镜像的 VMDisk 必须比镜像本身大，否则克隆过不去，磁盘会卡在 `Terminating`。对 `ubuntu-20.04` 来说，25Gi 就够了。
* 在一台全新的 app-VM 上，先 `netfix`，再 `connect`——否则应用看不到那些托管服务。
* 别用 Word 或 Google Docs 打开 `.yaml` 文件：它们会把引号和破折号换掉，文件就应用不了了，而报错看上去莫名其妙。

其余的坑——[chat/31](chat/31-troubleshooting.md)。

## 给搭建测试环境的人

配额、创建租户的顺序、平台版本——都在 [REQUIREMENTS.md](../REQUIREMENTS.md) 里。

## 所有消息按顺序

32 条消息的列表——[chat/README.md](chat/README.md)。
