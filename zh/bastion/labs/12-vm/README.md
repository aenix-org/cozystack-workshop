# 实验 12 · 与容器为邻的一台虚拟机

| | |
|---|---|
| **时长** | 30 分钟，其中 5–10 分钟花在等待机器启动上 |
| **验证了什么** | 遗留系统不必容器化也能搬迁：迁移过来的虚拟机，用与容器化应用完全相同的 ingress 和域名对外发布 |
| **需要准备** | 租户控制台（dashboard）访问权限、租户的 `~/.kube/config`、`kubectl`、`virtctl` |

## 为什么重要

员工通讯录是「Propusk」中最古老的部分。一个 2011 年的应用，由一位早已不知去向的外包写成。它跑在 Windows Server 上，跑在一个从未更新过的 .NET 版本上，因为「它能用」。没有源码，没有文档——只有一份四页的恢复指南，其中一步写着「打电话给 Sergei」。

它内部是个小型 Web 应用：通过 HTTP 提供一个列出员工及其电话号码的页面。人们在浏览器里打开它；其他服务向它查询数据。

这个通讯录不会搬进容器。不是「暂时不」，而是永远不：一个没人能重新构建的应用，物理上就无法容器化。而这并不构成放弃搬迁的理由。对「那些搬不动的东西怎么办？」这个问题的答案是：原样搬过来，作为一台虚拟机。

但仅仅搬过来还不够：通讯录必须像以前一样从外部可见。在这个实验里，我们会在容器旁边立起一台虚拟机，并用**与容器化应用完全相同的方式**把它对外发布——通过平台的 ingress 和域名。对平台而言，虚拟机不过是又一个躲在域名背后的工作负载，它无需关心背后是一个容器还是一整套操作系统。

## 小词汇表

| 术语 | 是什么 | 像……但是 |
|---|---|---|
| **VMInstance** | 作为集群对象存在的虚拟机 | **一台虚拟机**，但它以文本描述，并用与应用相同的 `kubectl` 创建 |
| **VMDisk** | 独立于机器存在的磁盘 | **一个 vmdk**，但它是一个独立对象：比机器活得更久，可挂到另一台机器上 |
| **Instance type** | 平台清单里现成的机器规格：多少 vCPU、多少内存 | 更接近云上的实例类型，而非手动调校 vCPU/RAM |
| **Instance profile** | 一套面向客户机操作系统的设备与驱动 | **客户机操作系统类型（Guest OS type）**，但它影响客户机会看到哪些控制器 |
| **cloud-init** | 首次开机时运行的初始配置脚本 | **自定义规范（Customization Specification）**，但它是清单（manifest）内的纯 YAML，而不是界面里的向导 |
| **Service** | 集群内一组 Pod 的一个稳定地址 | **一个负载均衡池**，但成员名单由平台按标签自行保持最新 |
| **Ingress** | 一条规则：哪个域名路由到哪个 Service，连同 HTTPS | **一群机器前面的反向代理**（nginx、HAProxy），但它以对象形式描述，域名和证书都由平台签发 |
| **域名（domain）** | 一个固定的名字，服务通过它以 HTTP 从外部可见 | **企业负载均衡器背后的一个 DNS 名字**，但不用向 DNS 或证书部门提工单 |
| **KubeVirt** | Kubernetes 运行虚拟机所用的机制 | **一个虚拟机监控程序（hypervisor）**，但它不是第二层虚拟机监控程序：底层就是任何 Linux 都在用的那套 QEMU/KVM |

## 实验目录里有什么

所有文件你都已经有了——它们随仓库一起到手。无需创建或重新键入任何东西：下文凡是写着 `kubectl apply -f name.yaml` 的地方，文件都取自这里。

```bash
cd labs/12-vm
```

| 文件 | 是什么 | 何时会用到 |
|---|---|---|
| `staff-directory-vm.yaml` | 承载遗留员工通讯录的虚拟机 | 你**在租户中**应用它 |
| `check.sh` | 检查通讯录是否已发布并在其域名上应答 | 你在实验末尾运行它 |

📍 **ingress 由讲师创建，而非参与者，并且是提前创建的。** 每个租户里都已经有一个 `Service spravochnik-http`（它把 80 端口转发到 8080，并选中你机器的 Pod），以及一个 host 为 `spravochnik.workshopXX.workshop.aenix.io` 的 `Ingress spravochnik`。你不需要去搭建它们，也不需要自己保管它们的文件——你要做的只是立起一台名为 `spravochnik` 的虚拟机，发布会自行把它接住。

## 步骤 1. 立起虚拟机

📍 **在哪里：** 在浏览器里，在租户控制台（dashboard）中。

虚拟机是 Cozystack 的一项托管服务；它就住在你的租户里。它分两步创建，这一点值得马上弄明白。

### 先建磁盘

租户 → **创建应用** → `VM Disk`。

| 字段 | 值 | 为什么这样 |
|---|---|---|
| Name | `spravochnik` | 机器也将以此命名 |
| Source | `Image` → `ubuntu-22.04` | 取自平台现成的镜像集合 |
| Storage | `20Gi` | `ubuntu-22.04` 镜像解包后占 20Gi，不能设得更小 |
| Storage class | `replicated` | 数据在不同节点上有三份副本 |

**为什么磁盘是一个独立对象，而不是机器里的一个字段。** 因为磁盘比机器活得更久。你可以把整台机器删掉，用另一种类型、另一套网络、另一个名字重建它——再挂上同一块磁盘。在 vSphere 里，当你把一个 vmdk 从一台 VM 卸下再挂到另一台上时，做的正是同一件事；这里它在模型中被明确地表达了出来。

⚠️ **磁盘不能小于源镜像。** 平台的 `ubuntu-22.04` 解包后占 20Gi，平台会拒绝一个 10Gi 磁盘的请求：没有更小的卷可供克隆镜像。这里往小了设比往大了设代价更高：磁盘以后可以扩，但不能缩。

等磁盘填满：平台会下载并解包镜像，需要一两分钟。

### 再建机器

租户 → **创建应用** → `VM Instance`。

| 字段 | 值 | 为什么这样 |
|---|---|---|
| Name | `spravochnik` | |
| Instance type | `u1.medium` | 1 CPU、4 GB——和集群节点用的是同一份规格清单 |
| Instance profile | `ubuntu` | 面向客户机操作系统的一套设备 |
| Run strategy | `Always` | 保持运行；如果它自行关机，会被再次启动 |
| Disks | `spravochnik` | 你刚创建的那块磁盘 |
| Cloud init | 见下文 | 在 8080 端口上把通讯录立起来 |

在 cloud-init 字段里：

```yaml
#cloud-config
password: ubuntu
chpasswd: { expire: false }
ssh_pwauth: true
write_files:
  - path: /opt/directory/index.html
    content: |
      <!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Справочник</title></head><body><h1>Справочник сотрудников</h1><ul><li>Иванов И. — 101</li><li>Петров П. — 102</li></ul></body></html>
  - path: /etc/systemd/system/directory.service
    content: |
      [Unit]
      Description=Staff directory
      After=network.target
      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/directory
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd: [ "systemctl daemon-reload", "systemctl enable --now directory" ]
```

这段 cloud-init 把通讯录变成一台服务器：它放入一个列有员工的 HTML 页面，并设置一个通过 HTTP 在 8080 端口上提供该页面的服务。`python3` 在 Ubuntu 镜像里已经有了，所以无需安装任何东西，也不需要联网。8080 端口并非随手挑的：它正是讲师提前创建的 `Service spravochnik-http` 所盯着的端口。

⚠️ **明文密码——仅用于本实验。** 在真实机器上这里会是 `sshKeys`，而根本不会有密码。我们走这条捷径，是为了不把工作坊的时间花在交换密钥上。

**同一件事，用文本表达。** 磁盘和机器这两个对象都在同一个文件 `staff-directory-vm.yaml` 里，并用一条命令创建：先磁盘，后机器。在应用之前，打开文件，把里面的占位符 `tenant-workshopXX` 替换成你自己租户的名字——否则对象会跑到错误的地方去。

```bash
# KUBECONFIG 是 kubectl 从中读取集群地址和登录数据的变量。
# 这里需要的是租户（TENANT）访问文件：虚拟机住在管理集群上的租户里。
export KUBECONFIG=~/.kube/config
# apply = 「把集群带到文件里所写的状态」。没有对象——就创建它们，
# 对象已存在——就把它们带到所描述的状态。
#   -f   从文件读取描述
kubectl apply -f staff-directory-vm.yaml
```

**你应当看到：** 两行带 `created` 的输出——一行给磁盘，一行给机器。

<details>
<summary><b>细看一下：staff-directory-vm.yaml 里面有什么</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
```

和 bucket、数据库、队列所在的是同一个 API 组。这里虚拟机不是一个有着自己界面的独立子系统，而是像 Redis 一样的一个目录对象。这正是「在一个界面里、通过一套 API」这句话的实质内涵。

```yaml
spec:
  source:
    image:
      name: ubuntu-22.04
  storage: 20Gi
```

一个来自平台共享集合的镜像名，而不是一个 URL：这个集合在整个集群范围内共享，镜像只下载一次。`storage` 不能小于镜像本身——`ubuntu-22.04` 解包后占 20Gi。如果你需要自己的镜像，同一处还有带链接的 `source.http`，以及用于克隆现有磁盘的 `source.disk`。

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
```

机器规格取自一份现成的清单，而不是用 vCPU 和 RAM 字段拨出来。`u1.medium` 是 1 CPU 和 4 GB。当你为一个 Kubernetes 集群订购节点时，用的也是同一份清单，这并非巧合：集群节点同样是一个 VMInstance。

```yaml
  instanceProfile: ubuntu
```

客户机操作系统的 profile：把哪些控制器、驱动和设备交给机器，好让客户机认得它们。最接近的类比是 vSphere 里创建 VM 时的「客户机操作系统类型（Guest OS type）」，后果也一样：profile 选错了，你会得到一台能启动却看不见自己磁盘的机器。

```yaml
  runStrategy: Always
```

期望的电源状态。`Always`——保持运行：如果客户机从内部关机，机器会被再次启动。`Halted`——已关机。`Manual`——保持原样，没人干预。注意这个措辞，它和 Deployment 里的 `replicas` 是一样的：不是「把它开机」，而是「让它保持开机」。

```yaml
  disks:
    - name: spravochnik
```

按 VMDisk 对象名列出的磁盘清单。要加第二块数据盘，就在这里作为第二行加上去。

```yaml
  cloudInit: |
    #cloud-config
    write_files:
      - path: /opt/directory/index.html
      - path: /etc/systemd/system/directory.service
    runcmd: [ "systemctl daemon-reload", "systemctl enable --now directory" ]
```

cloud-init 是每一个云上 Linux 镜像都懂的标准首次开机初始配置机制。它只运行一次，在第一次开机时。这里它做三件事：放入通讯录的 HTML 页面，设置一个通过 HTTP 在 8080 端口上提供该页面的 systemd 服务，并启动这个服务。它是 vSphere 里自定义规范（Customization Specification）的对应物，只不过是清单（manifest）内的文本，而不是界面里的向导——这意味着它躺在 Git 里，并和其他一切一起接受评审。

正是因为这个代码块，通讯录才会从外部可见：讲师提前创建的 `Ingress` 把域名路由到 `Service spravochnik-http`，后者再路由到机器内部的 8080 端口。一旦 8080 上的服务起来，发布就会自行把它接住。

### 这份清单里没有、也不会有的东西

**一个 `replicas` 字段。** `VMInstance` 没有它。一台虚拟机是单个对象；如果你需要两台机器，就用不同的名字创建两个对象。

这与 `Deployment` 有着根本性的差别，而它并非缺陷。Deployment 里的副本是可互换的：任何一个都能服务任何请求，丢掉一个也无关紧要。虚拟机不可互换——每台都在自己的磁盘上有着自己的状态，「再造一台一模一样的」对虚拟机而言，与对容器而言，含义截然不同。

实际后果是：**你在删除 Pod 那个实验里见过的自愈，对虚拟机并不存在。** 删掉一个 Pod，集群几秒内就会创建一个新的。删掉一个 VMInstance，机器就没了，唯一能让它回来的办法是手动来做——挂上那块幸存的磁盘。在这一点上，你和当年在 vSphere 里所处的位置完全相同，这值得事先知道，而不是在过程中才发现。

</details>

第一次开机需要 3–5 分钟：cloud-init 把文件系统扩展到整块磁盘上，并把通讯录服务立起来。我们不会袖手等它——在下一步，我们正好来看看机器还在启动时，发布那头究竟在发生什么。

## 步骤 2. 机器启动时，先去敲一敲域名

📍 **在哪里：** 在 bastion 上（在 bastion 终端里），另开一个窗口。或者干脆在你自己笔记本的浏览器里。

讲师已经提前发布了通讯录：你的租户里已经有一个 host 为 `spravochnik.workshopXX.workshop.aenix.io` 的 `Ingress spravochnik`，以及一个路由到机器内部 8080 端口的 `Service spravochnik-http`。发布已经就绪，只等通讯录一开始应答就接住它。我们现在就来检查，不用等机器加载完。

```bash
# curl —— 「去这个地址，把响应显示出来」。把 XX 替换成你自己的租户编号。
#   --max-time 5   5 秒后放弃，而不是长时间等待
curl --max-time 5 http://spravochnik.workshopXX.workshop.aenix.io
```

**你会看到：**

```
<html><head><title>503 Service Temporarily Unavailable</title></head>
<body><center><h1>503 Service Temporarily Unavailable</h1></center></body></html>
```

> **先停下来想一想，再往下读。**
>
> ingress 是讲师创建的，域名已配置好，机器是你立起来的。
> 为什么域名应答的是 `503`，而不是通讯录页面？

<details>
<summary><b>答案，以及一个比这个错误本身更宽泛的教训</b></summary>

因为机器内部的通讯录还没在监听。

`503` 并不意味着「ingress 坏了」。ingress 在位，并且知道该把流量路由到哪儿：到 `Service spravochnik-http`，后者选中你机器的 Pod，并把请求转发到 8080 端口。但当 cloud-init 还在扩展文件系统、还在设置服务时，机器内部 8080 上还没人应答——这个 service 连一个就绪的后端都没有。而 ingress 报告的正是这一点：路由存在，但暂时没人能在它上面应答。

这里的响应码本身就是诊断：

| 你看到什么 | 它意味着什么 |
|---|---|
| `503` | ingress 在位，但它背后没有就绪的后端 |
| `404` | ingress 存在，但规则路由到了错误的 service |
| 无响应、超时 | 根本就没有创建过带这个 host 的 ingress |

**这个教训比这个错误本身更宽泛。** 来自 ingress 的 `503` 讲的是后端就绪性，而不是 ingress 本身。如果域名背后的应用崩溃，或者它的 Pod 还没通过就绪检查，你也会得到同样的 `503`。对外发布和工作负载就绪是两件不同的事：域名是提前设好的，会有一段时间空着，恰恰在背后出现一个准备好应答的东西时才被填满。对虚拟机来说，那是「8080 上的服务起来的时候」；对容器来说，那是「Pod 通过就绪检查的时候」。机制是同一个，而这正是「虚拟机以与容器化应用相同的方式发布」这句话的含义。

</details>

## 步骤 3. 进入机器

📍 **在哪里：** 在控制台（dashboard）里，在 `spravochnik` 机器的卡片上。

卡片里有一个控制台——它就是 vSphere 里「Open Console」的那块屏幕。打开它。登录名 `ubuntu`，密码 `ubuntu`。

⚠️ **如果控制台显示黑屏和一个闪烁的光标——请等待。** cloud-init 还没跑完，登录提示会自行出现。不要重启机器：在 cloud-init 中途重启，会让它停在配置了一半的状态。

**从终端进行同样的登录。** `virtctl` 是一条专门用于操作虚拟机的命令：控制台、端口转发、开机和关机。它以单个文件安装；具体怎么装写在 `workshop/README.md` 里。

它语法上有一个怪癖值得提前讲清楚，否则你的第一条命令就会被拒。`virtctl` 的目标不是用裸名字给出，而是带一个类型前缀：`vmi/<name>`。`vmi` 是 virtual machine instance，即机器的**正在运行的实例**；你创建的那个 `VMInstance` 对象和正在运行的实例，在 API 里是两个不同的对象。在租户访问权限下，权限授予在 `virtualmachineinstances` 这个 **subresource** 上（`console` 和 `portforward`），而不是在整个 `virtualmachines` 对象上——裸名字会打到 vm 对象上，返回 `forbidden`。平台用前缀 `vm-instance-` 加上你机器的名字来构成实例名：`spravochnik` 就是实例 `vm-instance-spravochnik`。

```bash
# 租户访问：机器住在租户里
export KUBECONFIG=~/.kube/config
# console = 连接到机器的串行控制台。它就是 vSphere 里
# 「Open Console」给你的那块屏幕，只不过是文本形式的：
#   --namespace  在集群的哪个分区里查找；对你的租户来说它叫
#                tenant- 加上你的登录名，把 XX 替换成你自己的编号
#   vmi/...      目标：机器正在运行的实例，而不是 VMInstance 描述
virtctl console --namespace=tenant-workshopXX vmi/vm-instance-spravochnik
```

如果连接后屏幕是空的——按下 Enter，登录提示就会出现。退出控制台——`Ctrl+]`。你租户里所有正在运行的实例的名字，可用 `kubectl --kubeconfig ~/.kube/config get vminstance -n tenant-workshopXX` 查看。

从内部看，它就是一台普通的 Ubuntu。确认通讯录已经起来：

```bash
uname -a                       # 内核和架构：和裸金属服务器上是同一行输出
systemctl status directory     # 通讯录服务：应当是 active (running)
curl -s localhost:8080 | head  # 同一个页面，但从机器自身内部请求
```

如果 `systemctl status directory` 显示 `active (running)`，而对 `localhost:8080` 的 `curl` 返回了带员工列表的 HTML——那么服务器就绪了，外面的发布马上就会把 `503` 换成页面。内部没有一丝 Kubernetes 的痕迹，也不该有：客户机并不知道自己在一个集群里——正如 vSphere 里的虚拟机无需知道 vCenter 的存在。

## 步骤 4. 域名应答了——通讯录已发布

📍 **在哪里：** 在 bastion 上（在 bastion 终端里）。或者在你自己笔记本的浏览器里。

还是那个返回 `503` 的请求，但现在 8080 上的服务已经起来了。代入你自己的编号。

```bash
curl http://spravochnik.workshopXX.workshop.aenix.io
```

**你应当看到**——通讯录页面的 HTML：

```html
<h1>Справочник сотрудников</h1><ul><li>Иванов И. — 101</li><li>Петров П. — 102</li></ul>
```

在浏览器里打开这个地址，你会看到同样的列表。通讯录以一个对人友好的域名从外部可见，带着来自平台的 HTTPS，没有向网络部门或证书部门提过一张工单。

**我们来拆解一下刚刚发生了什么。**

一台对 Kubernetes 一无所知的 Ubuntu 虚拟机，正在一个普通端口上监听普通的 HTTP。从外部，它通过域名 `spravochnik.workshopXX.workshop.aenix.io` 被访问到，请求经由发布容器化应用的那同一个 ingress 到达它。客户机内部没有代理程序，没有网关，没有「集成」。对发布而言，域名背后是什么并无差别——是一个 nginx 的 Pod，还是一整台虚拟机：它看到一个 `Service`，`Service` 背后有一个就绪的后端，这就够了。

这正是「遗留系统不必容器化」的含义。2011 年的通讯录会照它一贯的样子继续工作——而从外部看，它就跟任何一个新的「Propusk」服务一模一样：一个名字、一个域名、HTTPS。

## 验证

📍 **在哪里：** 在 bastion 上（在 bastion 终端里），就在你用 `kubectl` 干活的那个窗口。

脚本检查的不是对象是否存在，而是实质上是否工作：域名返回 `200` 且是通讯录页面，机器本身在运行，发布它的 `Ingress` 在位。按域名的检查即使没有租户访问权限也能工作——它只需要 `curl`；租户访问权限会额外加上机器状态的检查。

```bash
# 租户访问：脚本从这里取用虚拟机本身和 Ingress
export KUBECONFIG=~/.kube/config
# 不带 tenant- 前缀的你的登录名：脚本用它同时拼出分区名 tenant-workshopXX
# 和域名 spravochnik.workshopXX.workshop.aenix.io
export COZY_TENANT=workshopXX
# 名字前面的 ./ 意为「当前目录里的文件」，也就是 labs/12-vm 里的
./check.sh
```

⚠️ **在 Windows 上脚本从 WSL 运行**，而不是从 PowerShell——怎么安装它写在实验 0 的开头。没有 WSL 你依然能完成这个实验，只是不会有产出报告这件产物。

`COZY_TENANT` 是必需的——没有它脚本会立刻停下：域名是从它拼出来的。如果没有设置租户访问，机器状态的检查会被跳过并给出一条警告，而主检查——域名上的应答——照样运行。

## 清理

如果你打算做监控那个实验，就把虚拟机留着：它的消耗在图表里也看得到，是个不错的示例。如果不打算——就通过控制台（dashboard）把机器和磁盘删掉。

⚠️ **按正确的顺序删除：先机器，后磁盘。** 挂在一台运行中机器上的磁盘删不掉，你会得到一个卡在删除状态里的对象。

发布通讯录的 `Ingress` 和 `Service` 是讲师创建的——别碰它们，这个测试环境上的下一位参与者会用到它们。

这里清理的代价说实话比其他实验都高：带数据的磁盘就是带数据的磁盘，它不会瞬间消失。但另一方面，创建它既不需要一张磁盘空间的工单，也不需要任何审批。

## 我们现在会做什么了

- 在租户里立起一台虚拟机——既能用鼠标，也能用文本
- 解释为什么磁盘和机器是两个对象，以及这带来了什么好处
- 通过 ingress 和域名把工作负载对外发布——与容器相同的方式
- 把来自 ingress 的 `503` 读作「域名背后暂时没人应答」，而不是一处故障
- 用一个活生生的例子表明，迁移遗留系统并不需要重写它

## 这事在 vSphere 里会是怎样

vSphere 里的虚拟机是主场，在那里造它是老一套的熟练活。差别不在机器本身，而在于把它以一个对人友好的名字暴露到外部。

要在 vSphere 里把这台机器用一个域名发布出去，你会需要一个作为独立产品的反向代理或负载均衡器、一张向网络部门申请外部地址的工单、一张向 DNS 申请名字的工单，以及一张向安全部门申请证书的工单。三四条命令，三四套系统，外加那个笼统的问题——「这一整套到底由谁来运维」。这里，发布就是一个讲师提前搭好的 `Ingress` 对象，加上一个在机器开始应答那一秒就被填满的域名。

**说句公道话，vSphere 更方便的地方。** 在管理虚拟机本身这件事上，vCenter 目前仍然更丰富，装作不是这样是没意义的：

| 什么 | vSphere | Cozystack |
|---|---|---|
| 模板与克隆 | 成熟，带客户机自定义 | 有磁盘克隆，没有自定义向导 |
| 快照 | 熟悉，带树形结构 | 有，但围绕它的生态更年轻 |
| 在线迁移 | vMotion，多年打磨 | 有，但用得更少、实战检验也更少 |
| 对某个 VM 文件夹的权限 | 细粒度 | 权限在租户级别，没有文件夹 |
| 控制台与客户机工具 | VMware Tools，带完整遥测 | qemu-guest-agent，数据更少 |

如果你**只**需要虚拟机——公道的答案是：为搬而搬没有意义。收益出现在你除了虚拟机之外还需要别的东西的地方：集群、数据库、队列、镜像仓库、对象存储、用域名发布。那时，你拥有的不是五套各带一套权限模型的产品，而是一份目录，2011 年的通讯录就站在里面，与其余的一切为邻。
