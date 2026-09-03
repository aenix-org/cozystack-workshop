## 11. 文件地图：什么放在哪里、在哪里运行

**读一遍就好——之后你就不用再猜了**

仓库里有两类文件，它们放在不同的地方。这是开始动手部分之前最需要弄明白的一点。

**清单（manifest）——`manifests/*.yaml`。从你的笔记本电脑上应用。**
它们描述要在集群里创建什么。命令始终是同一条：`kubectl apply -f <file>`。

• `01-bucket.yaml` — 存放镜像的存储 · 第 1 步
• `02-conversion-vm.yaml` — 转换机 · 第 2 步
• `03-app-vm.yaml` — 你的 app-VM · 第 4 步（这里要手动粘贴预签名链接）
• `04-managed.yaml` — 来自目录的 Postgres 和 Kafka · 第 5 步

**脚本——`scripts/*`。它们不在你的机器上运行，而是在虚拟机内部运行。**
在你的笔记本电脑上，它们你完全用不到。

• `convert.sh` — 在转换机内部 · 第 3 步
• `netfix-dhcp.sh` — 在你的 app-VM 内部 · 第 6 步
• `connect-managed.sh` — 在你的 app-VM 内部 · 第 7 步
• `orders-schema.sql` — 给数据库用的一张表，在 app-VM 内部执行 · 第 8 步（我们会把它作为
  查询敲进去；放这个文件是为了让你能确切看到创建的是什么）

**脚本是怎么进到机器里的——以及为什么方式不同。**

**转换机**有网络，所以它自己下载文件。仓库是公开的，不需要密钥：
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/convert.sh
```

**你的 app-VM 一开始根本没有网络**——这个坏掉的状态正是我们在第 6 步要修的。
那里既没有东西可下载，也没有工具去下载，文件也没法通过控制台传进去。所以
`netfix-dhcp.sh` 和 `connect-managed.sh` 你不是去下载，而是**手动敲进去**：每个
也就两三条命令，我会在聊天里把现成的给你。仓库里的这些文件本身是同样的内容，只是
写得更完整、带注释：日后你自己重复这套操作时，方便回头再看。

⚠️ **会让一切出问题的微妙之处。** 把 `tenant-workshopXX` 替换成你自己的编号，是你在
笔记本电脑上做的。而在转换机内部下载下来的文件是新鲜的、带着占位符的——那些值需要
重新手动填进去。
