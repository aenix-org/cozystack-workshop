## 6. Ставимо kubelogin

**kubelogin — вхід за обліковим записом**

Без нього `kubectl` не зможе відкрити браузер для входу і відповідатиме помилкою
авторизації. Файл обовʼязково має називатися саме `kubectl-oidc_login` — під цим імʼям
kubectl знаходить його як плагін.

**macOS**
```bash
brew install int128/kubelogin/kubelogin
```
Без Homebrew:
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

**Windows** (PowerShell)
```powershell
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_windows_amd64.zip" -OutFile "$HOME\kubelogin.zip"
Expand-Archive -Force "$HOME\kubelogin.zip" "$HOME\kubelogin-tmp"
Move-Item -Force "$HOME\kubelogin-tmp\kubelogin.exe" "$HOME\bin\kubectl-oidc_login.exe"
Remove-Item -Recurse -Force "$HOME\kubelogin.zip","$HOME\kubelogin-tmp"
```
(папку `$HOME\bin` уже створено й додано до PATH на попередньому кроці)

**Перевіряємо:**
```
kubectl oidc-login --help
```
Якщо вивелася довідка — плагін на місці, і kubectl його бачить.
