## 13. 深入解析：01-bucket.yaml 里面有什么

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: my-images
  namespace: tenant-workshopXX
spec:
  users:
    app: {}
```

`apiVersion: apps.cozystack.io/v1alpha1` —— 表示这个对象取自哪一组类型。
`apps.cozystack.io` 就是 Cozystack 的目录本身：其中列出的一切都是你可以订购的东西。这并不是「Kubernetes 自己就会做 bucket」——是平台把它们加进来的。

`kind: Bucket` —— 表示你到底在订购什么。这个文件并不描述*如何*把存储搭起来：它只说「我要一个 bucket」，其余一切由平台自己完成。整个目录都是这样工作的——你写下你需要什么，而不是一连串的操作步骤。

`metadata.name: my-images` —— 订单的名字。你会用它在控制台（dashboard）和命令里找到这个订单。这个名字是内部的；平台会在 S3 里生成它自己真正的 bucket 名，又长又唯一——稍后你会在 `bucketName` 参数里看到它。

`namespace: tenant-workshopXX` —— 你在平台上的那一块地盘。**唯一需要你手动修改的地方：**把 `XX` 换成你自己的编号。namespace（命名空间）是集群内部的一道隔断：不同 namespace 里同名的对象互不干扰、彼此看不见。最接近的类比是一个独立的 Resource Pool，带着自己的访问权限，只是更严格。

`users: app: {}` —— 创建一个名为 `app` 的 S3 用户。空的花括号表示「使用默认设置」：平台会自己为它想出一个访问密钥和一个私密密钥，并把它们放进一个单独的 Secret 对象里，你会在控制台（dashboard）里打开它。你不需要自己想任何密码，也不用把密码填到任何地方。

请注意文件里**没有**什么：大小、地址、端口、证书，以及这一切最终会落在哪些节点上。这些全都由平台自己决定。这正是「从目录里订购」和「手动搭建」之间的区别。
