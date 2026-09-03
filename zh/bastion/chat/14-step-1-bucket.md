## 14. 第 1 步：属于你自己的存储

**为镜像创建一个 Bucket**

📍 **位置：** 在 bastion（跳板机）上，位于 `~/workshop` 目录中。

磁盘镜像有好几个 GB。它得存放在某个地方，好让集群之后能通过链接把文件拉取下来。这正是对象存储的用途 —— 和 S3 是同一个思路。

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io -n tenant-workshopXX
```

等待 bucket 进入可用状态。

这份清单（manifest）会创建一个名为 **`my-images`** 的 bucket，并带有一个用户 —— `app`。在控制台中它会出现在 **Bucket** 板块下。

🖱 **通过控制台：** **Bucket → Deploy new**，名称填 `my-images`。但一定要**在创建之前就立刻把用户 `app` 加到 `users` 部分**。如果先创建一个空的 bucket，之后再通过 Edit 补上用户，bucket 会停留在半成品状态，镜像上传会失败。清单里已经处理好了这一点。

**现在把 bucket 的密钥取出来 —— 两步之后你会用到它们。**

bucket 是封闭的，要往里面放任何东西，都需要它自己的访问密钥。它们在控制台里：**Bucket → `my-images` → Secrets 标签页 → `bucket-my-images-app-credentials` 这个 secret**。展开它，你会看到四个值，每个都带有 *Reveal*（显示）和 *Copy*（复制）按钮。

**现在要做的事：把其中三个复制到一个记事本里** —— 随便哪儿都行，便签也好，发给自己的草稿消息也好：

• `bucketName`
• `accessKey`
• `secretKey`

⚠️ **`bucketName` 不是 `my-images`。** `my-images` 是你给这个订单起的名字；bucket 在 S3 里真正的名字是平台自己生成的，很长，形如 `bucket-a9209f83-4ac1-463e-8477-d8365bef787b`。进到脚本里的正是这个名字，来自 `bucketName` 字段。如果填了 `my-images`，上传就会发往一个不存在的 bucket，并以 `Insufficient permissions` 失败。在过去几次工作坊上就有人栽在这里。

第四个 `endpoint` 不用记 —— 它对所有人都一样，而且脚本里已经填好了。

**它们会用在哪里。** 在第 3 步，你会在转换机上打开 `convert.sh` 文件，其中有一个由三行组成、标着「PASTE YOUR VALUES（粘贴你的值）」的代码块：

```
BUCKET="ВСТАВЬТЕ_bucketName"
ACCESS_KEY="ВСТАВЬТЕ_accessKey"
SECRET_KEY="ВСТАВЬТЕ_secretKey"
```

你要粘贴进去的正是这三个值，每个都放进各自的引号里。它们在别的地方都用不到：脚本会自己把做好的镜像上传到你的 bucket，并自己生成指向它的链接。

⚠️ `secretKey` 就是访问你存储的密码。不要把它发到公共聊天里，哪怕是在求助的时候也不要。如果有什么对不上，私聊我。

⚠️ 如果你决定把 `endpoint` 换成自己的：在控制台里它是不带协议头显示的（`s3.workshop.aenix.io`），但写进脚本时开头**要带** `https://`。不写的话，上传会悄无声息地失败。
