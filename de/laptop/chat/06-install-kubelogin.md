## 6. kubelogin installieren

**kubelogin — Anmeldung mit Ihrem Konto**

Ohne es kann `kubectl` keinen Browser für die Anmeldung öffnen und antwortet
weiterhin mit einem Autorisierungsfehler. Die Datei muss exakt `kubectl-oidc_login`
heißen — unter diesem Namen findet kubectl sie als Plugin.

**macOS**
```bash
brew install int128/kubelogin/kubelogin
```
Ohne Homebrew:
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
(der Ordner `$HOME\bin` wurde im vorherigen Schritt bereits erstellt und zum PATH hinzugefügt)

**Prüfen wir es:**
```
kubectl oidc-login --help
```
Wenn der Hilfetext ausgegeben wurde, ist das Plugin an Ort und Stelle und kubectl sieht es.
