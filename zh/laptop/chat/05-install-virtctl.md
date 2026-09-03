## 5. 安装 virtctl

**virtctl — 管理虚拟机**

⚠️ **注意：要安装与集群匹配的版本，而不是最新版本。** 客户端比服务端新会改变命令语法，过去几次工作坊里有一半的问题正是由此而来。我们的集群运行的是 **v1.8.4** — 下面每个代码块里锁定的都是这个版本。不要把它改成 latest。

**macOS**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
如果 macOS 提示「无法验证开发者」：
```bash
sudo xattr -d com.apple.quarantine /usr/local/bin/virtctl
```

**Linux**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-linux-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```

**Windows**（PowerShell，以普通用户身份运行）
```powershell
$ver = "v1.8.4"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
之后，**关闭 PowerShell 窗口再打开一个新的** — 否则更新后的 PATH 不会生效。

**验证（各平台相同）：**
```
virtctl version
```
应该会出现一行带版本号的 `Client Version:`。这一步如果提示无法连接到服务端，是正常的 — 我们还没有连上它。

**关于命令中的机器名。** 使用 v1.8.4 客户端时，机器用它的裸名指定，不带前缀：`vm-instance-app-1`。如果你最终装的是更新一些的客户端，而它回复 `target must contain type and name separated by '/'` — 那就加上 **`vmi/`** 前缀：`vmi/vm-instance-app-1`。

⚠️ 前缀是 `vmi/`，不是 `vm/`。用 `vm/` 会得到一个权限错误（`cannot get resource "virtualmachines/portforward"`）：参与者被授予的是对运行中机器实例的权限，而不是对它们定义的权限。
