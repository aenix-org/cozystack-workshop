## 4. 安装 kubectl

**kubectl —— 适配你的系统**

**macOS**
```bash
brew install kubectl
```
若没有 Homebrew：
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
在使用 Intel 处理器的电脑上，把 `arm64` 换成 `amd64`。

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows**（PowerShell）
```powershell
winget install -e --id Kubernetes.kubectl
```
安装完成后，请关闭 PowerShell 再重新打开，否则会找不到该命令。

⚠️ **如果 Windows 回复「无法识别名称 "winget"」** —— 这说明你的系统版本里没有
「应用安装程序」，这在 Windows 10 上时有发生。没关系，我们直接安装。
完整复制整个代码块：
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
然后请务必关闭 PowerShell 窗口，再打开一个新窗口。

这个 `$HOME\bin` 文件夹稍后还会派上用场——virtctl 和 kubelogin 都会装进去，
而且它已经被加进了你的 PATH。

**检查——各系统通用：**
```
kubectl version --client
```
