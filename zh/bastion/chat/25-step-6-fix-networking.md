## 25. 第 6 步：修复机器内部的网络

**先搞定网络，其余的都往后放**

📍 **位置：** 在你的虚拟机内部，在控制台里（不是在 bastion（跳板机）上）。

📄 这是仓库中 `scripts/netfix-dhcp.sh` 的内容。**你不需要、也没法把它下载到机器里** —— 机器现在还没有网络，而这缺失的网络正是我们要修的故障。命令用手敲，一共两条。文件放在仓库里，是为了让你以后能再翻出来看。

应用现在处于宕机状态，这不是测试环境的故障。过去仍残留在镜像内部：一个来自 VMware 网络的静态地址，以及一个在这里并不存在的网关。机器死抱着它们不放，既看不到集群 DNS，也看不到自己的邻居。

从控制台进入机器 —— 在 bastion 上：
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```
🖱 **或者用鼠标：** 在控制台（dashboard）里打开你的机器，点击 **VNC** —— 这是同一个控制台，只是在浏览器里。两条路径都经过集群 API，即便现在机器内部的网络已经坏了，它们也照样能用。

接下来 —— 在机器内部（这是 CentOS，网络在这里配置，而不是在 netplan 里）：
```bash
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' /etc/sysconfig/network-scripts/ifcfg-eth0
```
亲眼看看改成了什么样：
```bash
cat /etc/sysconfig/network-scripts/ifcfg-eth0
```
应该保留 `BOOTPROTO=dhcp` 这一行，而不应该有任何带地址或网关的行。如果你用 `nano` 手动修改，结果是一样的，只是更慢。

现在需要重启机器：
```bash
reboot
```
🖱 **或者用鼠标：** 在控制台里机器的页面上，点 **Restart** 按钮。

重启之后，检查地址是否已经变成了集群地址：
```bash
ip -4 addr show eth0
```
它应该是类似 `10.244.x.x` 这样的地址。这说明机器已经接入集群网络，并且能看到集群的 DNS。

⚠️ 顺序很重要：只要地址还是旧的，服务名就解析不了，去改应用的配置也没有意义。
