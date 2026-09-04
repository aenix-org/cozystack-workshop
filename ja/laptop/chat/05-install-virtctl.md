## 5. virtctl のインストール

**virtctl — 仮想マシンの操作**

⚠️ **注意: 最新版ではなく、クラスターに合ったバージョンを入れてください。** クライアントがサーバーより新しいと、コマンドの構文が変わってしまいます。これまでのワークショップでの質問の半分は、まさにこれが原因でした。私たちのクラスターは **v1.8.4** で動いています。以下のすべてのブロックで指定しているのがそのバージョンです。latest に切り替えないでください。

**macOS**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
macOS が「開発元を検証できません」と表示する場合:
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

**Windows**（PowerShell、一般ユーザーで実行）
```powershell
$ver = "v1.8.4"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
このあとは **PowerShell のウィンドウを閉じて、新しく開き直してください**。そうしないと更新された PATH が読み込まれません。

**確認（どの環境でも同じ）:**
```
virtctl version
```
番号付きの `Client Version:` の行が表示されるはずです。この時点でサーバーに接続できないという文句が出るのは正常です。まだ接続していないだけです。

**コマンドでのマシン名について。** クライアント v1.8.4 では、マシンは接頭辞なしの素の名前で指定します: `vm-instance-app-1`。もし新しめのクライアントが入ってしまっていて、`target must contain type and name separated by '/'` と返す場合は、**`vmi/`** の接頭辞を付けてください: `vmi/vm-instance-app-1`。

⚠️ 接頭辞は `vmi/` であって `vm/` ではありません。`vm/` にすると権限エラー（`cannot get resource "virtualmachines/portforward"`）になります。参加者に付与されているのは、実行中のマシンインスタンスに対する権限であって、その定義に対する権限ではありません。
