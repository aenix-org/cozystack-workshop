## 4. Встановлюємо kubectl

**kubectl — під вашу систему**

**macOS**
```bash
brew install kubectl
```
Без Homebrew:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
На комп'ютерах із процесором Intel замініть `arm64` на `amd64`.

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows** (PowerShell)
```powershell
winget install -e --id Kubernetes.kubectl
```
Після встановлення закрийте й відкрийте PowerShell заново, інакше команда не знайдеться.

⚠️ **Якщо Windows відповіла «Ім'я "winget" не розпізнано»** — отже, у вашій збірці немає
«Встановлювача застосунків», таке буває на Windows 10. Нічого страшного, ставимо напряму.
Копіюйте блок цілком:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
Потім обов'язково закрийте вікно PowerShell і відкрийте нове.

Ця сама тека `$HOME\bin` знадобиться далі — у неї ляжуть virtctl і kubelogin,
і в PATH вона вже додана.

**Перевірка — усюди однакова:**
```
kubectl version --client
```
