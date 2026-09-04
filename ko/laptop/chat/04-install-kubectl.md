## 4. kubectl 설치하기

**kubectl — 여러분의 시스템에 맞게**

**macOS**
```bash
brew install kubectl
```
Homebrew가 없다면:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
Intel 프로세서가 탑재된 컴퓨터에서는 `arm64`를 `amd64`로 바꾸십시오.

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows** (PowerShell)
```powershell
winget install -e --id Kubernetes.kubectl
```
설치 후에는 PowerShell을 닫았다가 다시 여십시오. 그러지 않으면 명령을 찾지 못합니다.

⚠️ **Windows가 "'winget' 용어가 인식되지 않습니다"라고 응답하면** — 여러분의 빌드에
"앱 설치 관리자"가 없다는 뜻이며, Windows 10에서 흔히 있는 일입니다. 문제없습니다, 직접 설치하겠습니다.
블록 전체를 복사하십시오:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
그런 다음 반드시 PowerShell 창을 닫고 새 창을 여십시오.

이 `$HOME\bin` 폴더는 나중에도 쓸모가 있습니다 — virtctl과 kubelogin이 여기에 놓이며,
PATH에는 이미 추가되어 있습니다.

**확인 — 어디서나 동일합니다:**
```
kubectl version --client
```
