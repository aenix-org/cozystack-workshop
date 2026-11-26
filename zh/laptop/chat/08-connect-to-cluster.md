## 8. 登录集群

**连接到你的租户**

📍 **位置：**在浏览器中打开控制台；命令在你自己的笔记本上执行。

**你的登录凭据：**
```
dashboard: https://dashboard.workshop.aenix.io
login:     workshopXX      ← your number, I'll tell you in person
password:  ...             ← I'll tell you in person
```

1. 通过上面的链接打开控制台。
2. 用你的登录名登录。
3. 在控制台中：**Info → Secrets 标签页 → `kubeconfig-tenant-workshopXX`**。点击 *Reveal*，
   复制其中的内容。
4. 保存到一个文件，并让变量指向它：

**macOS 和 Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # paste what you copied, then save
export KUBECONFIG=~/.kube/workshop
```

**Windows**（PowerShell）
```powershell
notepad $HOME\.kube\workshop   # paste, then save
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
# empty — means it's using the default file, not the one you were given

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — the file was saved incompletely; download the secret from the dashboard again

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# should start with apiVersion; little squares or emptiness mean the file is in UTF-16
```

第三点是 Windows 上最阴险的陷阱。记事本和 `>` 重定向会把文件保存成
**UTF-16**，而 `kubectl` 读不了这种文件。只能保存为 UTF-8：在记事本里把
文件类型选为「所有文件」，在命令行里用 `Out-File -Encoding utf8`，而不是 `>`。
