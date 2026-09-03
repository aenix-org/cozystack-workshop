## 11. 文件地图：什么放在哪里、在哪里运行

**读一遍就好——之后你就不用再猜了**

请记住三个「事情发生」的地方：**bastion（跳板机）**（你通过 SSH 登入的那台机器）、
**转换机**，以及**你的 app-VM**——后两者都在集群内部创建。仓库里有两类文件，
它们在不同的地方运行。

**清单（manifest）——`manifests/*.yaml`。从 bastion 上应用。**
它们描述要在集群里创建什么。命令始终是同一条：`kubectl apply -f <file>`。

• `01-bucket.yaml` — 存放镜像的存储 · 第 1 步
• `02-conversion-vm.yaml` — 转换机 · 第 2 步
• `03-app-vm.yaml` — 你的 app-VM · 第 4 步（这里要手动粘贴预签名链接）
• `04-managed.yaml` — 来自目录的 Postgres 和 Kafka · 第 5 步

**脚本——`scripts/*`。它们不在 bastion 上运行，而是在集群内的机器里运行。**
在 bastion 本身你不运行它们——你只用 `kubectl` 应用清单。

• `convert.sh` — 在转换机内部 · 第 3 步
• `netfix-dhcp.sh` — 在你的 app-VM 内部 · 第 6 步
• `connect-managed.sh` — 在你的 app-VM 内部 · 第 7 步
• `orders-schema.sql` — 给数据库用的一张表，在 app-VM 内部执行 · 第 8 步（我们会把它作为
  查询敲进去；放这个文件是为了让你能确切看到创建的是什么）

**脚本是怎么进到机器里的——以及为什么方式不同。**

**转换机**有网络，所以它自己下载文件。仓库是公开的，不需要密钥：
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/convert.sh
```

**你的 app-VM 一开始根本没有网络**——这个坏掉的状态正是我们在第 6 步要修的。
那里既没有东西可下载，也没有工具去下载，文件也没法通过控制台传进去。所以
`netfix-dhcp.sh` 和 `connect-managed.sh` 你不是去下载，而是**手动敲进去**：每个
也就两三条命令，我会在聊天里把现成的给你。仓库里的这些文件本身是同样的内容，只是
写得更完整、带注释：日后你自己重复这套操作时，方便回头再看。

⚠️ **清单里的租户编号已经填好了**——在准备这台跳板机时，`tenant-workshopXX`
占位符已经替换成了你的编号。你不需要手动输入任何东西。你唯一要自己填的，是
`convert.sh` 里的 `bucketName`、`accessKey` 和 `secretKey`（它是新鲜下载到转换机里的，
带着 `ВСТАВЬТЕ_...` 占位符），以及第四步 `manifests/03-app-vm.yaml` 里的预签名链接。
