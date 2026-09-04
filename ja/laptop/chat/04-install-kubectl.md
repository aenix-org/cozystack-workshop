## 4. kubectl のインストール

**kubectl — お使いのシステム向け**

**macOS**
```bash
brew install kubectl
```
Homebrew を使わない場合:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
Intel プロセッサ搭載のコンピュータでは、`arm64` を `amd64` に置き換えてください。

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows** (PowerShell)
```powershell
winget install -e --id Kubernetes.kubectl
```
インストール後は PowerShell を一度閉じて開き直してください。そうしないとコマンドが見つかりません。

⚠️ **Windows が「用語 'winget' が認識されません」と返した場合** — お使いのビルドに
「アプリ インストーラー」が入っていないということです。Windows 10 でよく起こります。問題ありません、直接インストールします。
ブロック全体をコピーしてください:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
その後、必ず PowerShell のウィンドウを閉じて、新しいウィンドウを開いてください。

この `$HOME\bin` フォルダは後でも役に立ちます — ここに virtctl と kubelogin が置かれ、
PATH にもすでに追加されています。

**確認 — どこでも同じです:**
```
kubectl version --client
```
