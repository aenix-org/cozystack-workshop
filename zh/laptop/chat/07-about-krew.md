## 7. 关于 krew —— 以及我们为什么不用它

**简短回答：今天别装它**

krew 是 kubectl 的插件管理器，用它也能装上同样的 virtctl 和 kubelogin。但在以往的工作坊上，恰恰是它耗掉了最多时间，尤其在 Windows 上。如果你已经完成了第 3 步和第 4 步 —— **你已经有了全部所需，跳过这篇即可**。

只有当你已经装了 krew，或者非常想用它时，才继续往下读。

⚠️ **Windows 上的三个坑，都是实战中遇到过的：**
• **PATH 在当前窗口没有刷新。** 最常见的一个。就在同一个会话里修复它：
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe 没有装完** —— 被 SmartScreen 或杀毒软件干掉了。检查：
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **管理员 PowerShell 窗口和普通窗口是两个不同的世界。** 它们有不同的 `$HOME`，
  也有不同的用户 PATH。以管理员身份安装，却以普通用户身份运行 ——
  插件就永远找不到。要在同一个普通窗口里安装并运行。

**macOS 和 Linux** —— 整段复制，它会自行识别系统：
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
然后把 krew 加入 PATH —— 这一行需要追加到你的 profile 里，否则下次启动终端时就会被遗忘：
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # zsh 用，macOS 默认
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # bash 用，通常是 Linux
source ~/.zshrc    # 或 source ~/.bashrc
```

**Windows**（PowerShell）
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
再次关闭并重新打开 PowerShell。

**安装插件：**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ 一个重要区别：通过 krew 安装时命令的名字不一样 ——
是 `kubectl virt console …` 而不是 `virtctl console …`。后面的说明里我写的是
`virtctl` —— 如果你是通过 krew 装的，就在心里把它换成 `kubectl virt`。
为了避免混淆，你可以设一个简短的别名：
```bash
alias virtctl="kubectl virt"
```
