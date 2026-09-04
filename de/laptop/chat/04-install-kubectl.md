## 4. kubectl installieren

**kubectl — für Ihr System**

**macOS**
```bash
brew install kubectl
```
Ohne Homebrew:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
Auf Computern mit Intel-Prozessor ersetzen Sie `arm64` durch `amd64`.

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows** (PowerShell)
```powershell
winget install -e --id Kubernetes.kubectl
```
Schließen Sie PowerShell nach der Installation und öffnen Sie es erneut, sonst wird der Befehl nicht gefunden.

⚠️ **Wenn Windows mit „Der Ausdruck ‚winget‘ wurde nicht als Name erkannt“ antwortet** — dann fehlt in Ihrem Build
der „App Installer“; das kommt unter Windows 10 vor. Kein Problem, wir installieren direkt.
Kopieren Sie den ganzen Block:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
Schließen Sie danach unbedingt das PowerShell-Fenster und öffnen Sie ein neues.

Genau dieser Ordner `$HOME\bin` wird später nützlich — virtctl und kubelogin landen darin,
und in PATH ist er bereits aufgenommen.

**Prüfung — überall gleich:**
```
kubectl version --client
```
