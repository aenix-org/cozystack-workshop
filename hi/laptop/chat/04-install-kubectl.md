## 4. kubectl इंस्टॉल करना

**kubectl — आपके सिस्टम के लिए**

**macOS**
```bash
brew install kubectl
```
Homebrew के बिना:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
Intel प्रोसेसर वाले कंप्यूटरों पर `arm64` को `amd64` से बदलें।

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows** (PowerShell)
```powershell
winget install -e --id Kubernetes.kubectl
```
इंस्टॉल करने के बाद PowerShell बंद करके फिर से खोलें, वरना कमांड नहीं मिलेगी।

⚠️ **अगर Windows जवाब दे "The term 'winget' is not recognized"** — इसका मतलब है कि आपके बिल्ड में
"App Installer" नहीं है; ऐसा Windows 10 पर होता है। कोई बात नहीं, हम सीधे इंस्टॉल कर देंगे।
पूरा ब्लॉक कॉपी करें:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
फिर PowerShell विंडो को ज़रूर बंद करके नई विंडो खोलें।

यही `$HOME\bin` फ़ोल्डर आगे काम आएगा — इसी में virtctl और kubelogin आकर बैठेंगे,
और यह PATH में पहले से जुड़ा हुआ है।

**जाँच — हर जगह एक जैसी:**
```
kubectl version --client
```
