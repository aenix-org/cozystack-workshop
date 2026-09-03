## 4. Instalar kubectl

**kubectl — para tu sistema**

**macOS**
```bash
brew install kubectl
```
Sin Homebrew:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
En equipos con procesador Intel, reemplaza `arm64` por `amd64`.

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows** (PowerShell)
```powershell
winget install -e --id Kubernetes.kubectl
```
Tras la instalación, cierra PowerShell y ábrelo de nuevo; de lo contrario el comando no se encontrará.

⚠️ **Si Windows responde «El término "winget" no se reconoce»** — significa que tu compilación no tiene
el «Instalador de aplicaciones»; esto ocurre en Windows 10. No pasa nada, lo instalamos directamente.
Copia el bloque completo:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
Luego asegúrate de cerrar la ventana de PowerShell y abrir una nueva.

Esta misma carpeta `$HOME\bin` te vendrá bien más adelante — ahí quedarán virtctl y kubelogin,
y ya está añadida a tu PATH.

**Comprobación — igual en todos lados:**
```
kubectl version --client
```
