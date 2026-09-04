## 6. kubelogin のインストール

**kubelogin — アカウントでのログイン**

これがないと `kubectl` はログイン用のブラウザを開けず、認可エラーを返し続けます。
ファイル名は必ず `kubectl-oidc_login` にしてください。kubectl はこの名前でプラグインとして
見つけます。

**macOS**
```bash
brew install int128/kubelogin/kubelogin
```
Homebrew がない場合:
```bash
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o kubelogin.zip "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_darwin_${ARCH}.zip"
unzip -o kubelogin.zip kubelogin
chmod +x kubelogin
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
rm kubelogin.zip
```

**Linux**
```bash
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o kubelogin.zip "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_${ARCH}.zip"
unzip -o kubelogin.zip kubelogin
chmod +x kubelogin
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
rm kubelogin.zip
```

**Windows**（PowerShell）
```powershell
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_windows_amd64.zip" -OutFile "$HOME\kubelogin.zip"
Expand-Archive -Force "$HOME\kubelogin.zip" "$HOME\kubelogin-tmp"
Move-Item -Force "$HOME\kubelogin-tmp\kubelogin.exe" "$HOME\bin\kubectl-oidc_login.exe"
Remove-Item -Recurse -Force "$HOME\kubelogin.zip","$HOME\kubelogin-tmp"
```
（`$HOME\bin` フォルダは前のステップで作成し、PATH に追加済みです）

**確認しましょう:**
```
kubectl oidc-login --help
```
ヘルプが表示されれば、プラグインは正しく置かれていて kubectl から見えています。
