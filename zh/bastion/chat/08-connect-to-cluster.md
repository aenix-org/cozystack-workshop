## 8. 登录 bastion（跳板机）

**一次登录，你就已经进入集群**

📍 **位置：**在浏览器中打开控制台，其余一切都通过 SSH 在 bastion 上完成。

**你的登录凭据**（登录名和密码在这三处都相同）：
```
dashboard: https://dashboard.workshop.aenix.io
bastion:   ssh workshopXX@<bastion-address>
login:     workshopXX      ← 你的编号，我会当面告诉你
password:  ...             ← 我会当面告诉你
```

登录 bastion —— 密码与控制台的相同，**不需要 SSH 密钥**：

```bash
ssh workshopXX@<bastion-address>
```

进入之后，对集群的访问已经配置好了：kubeconfig 位于 `~/.kube/config`，`kubectl`
立刻就能看到你的租户。**这个过程不会打开浏览器** —— 登录集群走的是令牌（token），不经过
Keycloak。我们来验证一下：

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

第一条命令会显示 `tenant-workshopXX`，第二条会回答 `No resources found`。这就是
正确的结果：目前还没有机器，但集群已经认得你了。

⚠️ `kubectl get vm` 和 `kubectl get vmi` 不会生效 —— 在你的账户下可用的是 `vminstance`
类型。这是有意为之的。

⚠️ 浏览器中的控制台（用于点击操作的直观步骤）使用相同的登录名和密码。但控制台里的
kubeconfig（`Info → Secrets → kubeconfig-tenant-workshopXX`）**不需要**下载到 bastion 上：
在那里它是为浏览器登录准备的，而 bastion 上已经有一个现成的、不依赖它也能用的 kubeconfig。
