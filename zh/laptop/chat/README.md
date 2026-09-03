# 工作坊聊天消息

一个文件对应一条消息。随实操进度逐条发出，不要一次性全发：否则参与者会跑到前面，卡在你还没解释为什么需要它的地方。

凡是出现 `workshopXX` 的地方，参与者都要填入自己的编号：`workshop03`、`workshop07`，以此类推。这个编号连同一个密码一起单独发给每个人。

每个文件都在 Telegram 的上限之内——4096 个字符。

| # | 消息 | 文件 |
|---|---|---|
| 1 | 我们到底在做什么 | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | 小词汇表：在你那边叫什么、在这里叫什么 | [`02-glossary.md`](02-glossary.md) |
| 3 | 开始之前：你会需要什么 | [`03-prerequisites.md`](03-prerequisites.md) |
| 4 | 安装 kubectl | [`04-install-kubectl.md`](04-install-kubectl.md) |
| 5 | 安装 virtctl | [`05-install-virtctl.md`](05-install-virtctl.md) |
| 6 | 安装 kubelogin | [`06-install-kubelogin.md`](06-install-kubelogin.md) |
| 7 | 关于 krew——以及我们为什么不用它 | [`07-about-krew.md`](07-about-krew.md) |
| 8 | 登录到集群 | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 9 | 安装 git | [`09-install-git.md`](09-install-git.md) |
| 10 | 获取材料并填入你的编号 | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | 文件地图：什么放在哪里、在哪里运行 | [`11-file-map.md`](11-file-map.md) |
| 12 | 阶段 1。把镜像从 vSphere 导出 | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | 细看：01-bucket.yaml 里有什么 | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | 步骤 1：你自己的存储 | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | 细看：02-conversion-vm.yaml 里有什么 | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | 步骤 2：转换机 | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | 细看：convert.sh 做了什么 | [`17-convert-script.md`](17-convert-script.md) |
| 18 | 步骤 3：转换镜像 | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | 阶段 2。在新家把机器启动起来 | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | 细看：03-app-vm.yaml 里有什么 | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | 步骤 4：你的虚拟机 | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | 阶段 3。扔掉这座动物园 | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | 细看：04-managed.yaml 里有什么 | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | 步骤 5：来自目录的数据库和队列 | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | 步骤 6：修复机器内部的网络 | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | 第一次检查：我们尝试启动，却撞上一个错误 | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | 步骤 7：把应用指向托管服务 | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | 步骤 8：为什么应用仍然崩溃 | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | 步骤 8：安装客户端并导入 schema | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | 步骤 9：验证整条链路 | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | 如果有什么运行不正常 | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | 工作坊之后 | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
