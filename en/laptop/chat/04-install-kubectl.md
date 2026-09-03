## 4. Installing kubectl

**kubectl — for your system**

**macOS**
```bash
brew install kubectl
```
Without Homebrew:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
On computers with an Intel processor, replace `arm64` with `amd64`.

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows** (PowerShell)
```powershell
winget install -e --id Kubernetes.kubectl
```
After installing, close PowerShell and open it again, otherwise the command won't be found.

⚠️ **If Windows replies "The term 'winget' is not recognized"** — it means your build doesn't have
the "App Installer"; this happens on Windows 10. No problem, we'll install directly.
Copy the whole block:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
Then be sure to close the PowerShell window and open a new one.

This same `$HOME\bin` folder will come in handy later — virtctl and kubelogin will land in it,
and it's already been added to your PATH.

**Check — the same everywhere:**
```
kubectl version --client
```
