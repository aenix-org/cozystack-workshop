## 8. 登录集群

**连接到你的租户**

📍 **位置：**在浏览器中打开控制台；命令在你自己的笔记本上执行。

**你的登录凭据：**
```
dashboard: https://dashboard.workshop.aenix.io
login:     workshopXX      ← 你的编号，我会当面告诉你
password:  ...             ← 我会当面告诉你
```

1. 通过上面的链接打开控制台。
2. 用你的登录名登录。
3. 在控制台中：**Info → Secrets 标签页 → `kubeconfig-tenant-workshopXX`**。点击 *Reveal*，
   复制其中的内容。
4. 保存到一个文件，并让变量指向它：

**macOS 和 Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # 粘贴刚才复制的内容，然后保存
export KUBECONFIG=~/.kube/workshop
```

**Windows**（PowerShell）
```powershell
notepad $HOME\.kube\workshop   # 粘贴，然后保存
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**我们来验证一下：**
```
kubectl get vminstance -n tenant-workshopXX
```
会打开一个浏览器 —— 以 `workshopXX` 身份登录。之后这条命令应当回答
`No resources found`。这就是正确的结果：目前还没有机器，但集群已经认得你了。

⚠️ 最容易让人栽跟头的两点：
• `KUBECONFIG` 必须精确指向你粘贴了配置的那个文件。
• `kubectl get vm` 和 `kubectl get vmi` 不会生效 —— 在你的账户下可用的是 `vminstance`
  类型。这是有意为之的。

⚠️ **`x509: certificate signed by unknown authority`** —— 第二个常见错误，几乎
总是出现在 Windows 上。它并不意味着证书有问题，而是意味着 `kubectl` 取到了
**错误的访问文件**：对集群内部证书颁发机构的信任存放在你的
kubeconfig 里的 `certificate-authority-data` 字段中，而默认文件里没有它。

我们在 PowerShell 里一步步排查：
```powershell
$env:KUBECONFIG
# 为空 —— 说明用的是默认文件，而不是发给你的那个

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False —— 文件保存得不完整；请从控制台重新下载这个 secret

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# 应当以 apiVersion 开头；出现小方块或空白，说明文件是 UTF-16 编码
```

第三点是 Windows 上最阴险的陷阱。记事本和 `>` 重定向会把文件保存成
**UTF-16**，而 `kubectl` 读不了这种文件。只能保存为 UTF-8：在记事本里把
文件类型选为「所有文件」，在命令行里用 `Out-File -Encoding utf8`，而不是 `>`。
