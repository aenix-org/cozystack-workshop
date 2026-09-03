## 16. 第二步：转换机

**启动我们用来做转换的虚拟机**

📍 **位置：** 在 bastion 上。

**什么是「转换」，以及为什么绕不开它。** 虚拟机的磁盘就是一个文件。VMware 用它自己的格式 `VMDK` 来保存它。Cozystack 中运行虚拟机的 KVM 看不懂这个格式——它需要 `QCOW2`。内容是一样的，还是你那台带着全套东西的 CentOS，只是封装方式不同。转换就是把文件从一种格式重新封装成另一种，数据本身并不改变。

除此之外，你还得修整里面的东西。一套在 vSphere 里长大的系统，期望看到的是 VMware 的虚拟硬件：它自己的网卡、它自己的磁盘控制器、`vmxnet3` 和 `pvscsi` 驱动。到了新家，硬件不一样了——是 `virtio`。如果不提前把正确的驱动塞进启动镜像里，机器一开机就会既找不到磁盘也找不到网络。这件事同样由转换来处理。

**为什么要单独一台机器，而不是虚拟机本身。** 这个工具叫 `virt-v2v`，它会拖来一大堆依赖，还要吃掉几十个 GB。把它装在大家共用的 bastion 上是个糟糕的主意：它很小，而且你们所有人只有这一台。更省事的做法是在集群里、就在存储旁边启动一台用完即弃的机器，在里面把活干完，然后关掉。

顺带一提，这正是真实迁移项目里做转换所采用的方式：转换器住在数据旁边，而不是通过 VPN 跑在某个人的工作机上。

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

我们等待 `Running` 状态（按 Ctrl+C 退出监视）。我们**通过控制台**进到里面：

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

**转换机的访问凭据：**
```
login:    ubuntu
password: ubuntu
```

退出控制台——`Ctrl+]`。如果屏幕是空的，按 Enter。

⚠️ **不要用 `virtctl ssh` 进去。** 在之前几次工作坊里，它对谁都没用：它会回一句 `exit status 255` 然后断开连接。控制台走的是集群 API，任何时候都能用。同样的操作也可以用鼠标完成——控制台（dashboard）里机器页面上的 **VNC** 按钮。

**这条命令到底创建了什么。** 文件里描述了两个对象，所以控制台（dashboard）里会出现两条记录，而不是一条：

• **VM Disk**，名为 `convert-tools`——一块 25Gi 的磁盘，从目录镜像 `ubuntu-20.04` 克隆而来
• **VM Instance**，名为 `convert`——机器本身，它会挂载那块磁盘

虚拟机离不开磁盘——所以磁盘总是作为单独的对象先被创建。记住这一点；在第四步你会看到一模一样的这一对。

⚠️ 顺便马上说一下命名，否则你会搞混。控制台（dashboard）里的对象叫 `convert`，而它启动起来的机器在集群内部叫 **`vm-instance-convert`**——带前缀。所以在控制台（dashboard）里你找 `convert`，而在 `virtctl` 命令里你写 `vm-instance-convert`。

🖱 **通过控制台（dashboard）：** 你手动依次创建同样这两个对象。
**1)** **VM Disk → Deploy new**：名称 `convert-tools`，source = **image**，镜像 `ubuntu-20.04`，大小 `25Gi`，storage class 为 `replicated`。
**2)** **VM Instance → Deploy new**：名称 `convert`，instance type 为 `u1.large`，profile 为 `ubuntu`，然后在磁盘列表里选中 `convert-tools`——就是你上一步创建的那块。你可以直接在那里用 **VNC** 按钮进到里面，这样 ssh 和 virtctl 都不需要，一切都在浏览器里。

⚠️ 磁盘不要小于 25Gi：如果它比镜像还小，克隆就过不去，之后磁盘会卡在 Terminating 状态里碍事。

⚠️ 清单（manifest）里特意指定了 **ubuntu-20.04** 镜像，不要改动它。在 24.04 上机器起不来，而在 22.04 上转换会绊在 CentOS 7 内部那套旧的软件包数据库上。我们已经替你验证过了，省得你去验证。
