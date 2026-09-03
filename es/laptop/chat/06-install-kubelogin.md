## 6. Instalar kubelogin

**kubelogin — iniciar sesión con tu cuenta**

Sin él, `kubectl` no puede abrir el navegador para el inicio de sesión y seguirá
respondiendo con un error de autorización. El archivo debe llamarse exactamente
`kubectl-oidc_login`: es el nombre con el que kubectl lo encuentra como complemento.

**macOS**
```bash
brew install int128/kubelogin/kubelogin
```
Sin Homebrew:
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
(la carpeta `$HOME\bin` ya fue creada y añadida al PATH en el paso anterior)

**Comprobemos:**
```
kubectl oidc-login --help
```
Si se imprimió la ayuda, el complemento está en su sitio y kubectl lo ve.
