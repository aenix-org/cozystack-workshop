## 5. virtctl इंस्टॉल करना

**virtctl — VM का प्रबंधन**

⚠️ **सावधान: सबसे नया संस्करण नहीं, बल्कि वही इंस्टॉल करें जो क्लस्टर में है।** सर्वर से नया क्लाइंट कमांड सिंटैक्स बदल देता है, और पिछले वर्कशॉप में आधे सवाल ठीक इसी वजह से आए थे। हमारा क्लस्टर **v1.8.4** पर चलता है — यही संस्करण नीचे के हर ब्लॉक में पिन किया गया है। इसे latest पर मत बदलिए।

**macOS**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
अगर macOS शिकायत करे कि वह "डेवलपर को सत्यापित नहीं कर सका":
```bash
sudo xattr -d com.apple.quarantine /usr/local/bin/virtctl
```

**Linux**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-linux-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```

**Windows** (PowerShell, सामान्य उपयोगकर्ता के रूप में चलाएँ)
```powershell
$ver = "v1.8.4"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
इसके बाद **PowerShell विंडो बंद करके एक नई खोलें** — वरना अपडेट किया गया PATH लागू नहीं होगा।

**सत्यापन (हर जगह एक जैसा):**
```
virtctl version
```
`Client Version:` वाली एक पंक्ति एक नंबर के साथ दिखनी चाहिए। इस स्टेप पर सर्वर तक न पहुँच पाने की शिकायत सामान्य है — हम अभी उससे जुड़े ही नहीं हैं।

**कमांड में मशीन के नाम के बारे में।** क्लाइंट v1.8.4 के साथ मशीन उसके गोल-मटोल नाम से दी जाती है, बिना किसी उपसर्ग के: `vm-instance-app-1`। अगर आपके यहाँ किसी तरह नया क्लाइंट इंस्टॉल हो गया और वह `target must contain type and name separated by '/'` जवाब देता है — तो **`vmi/`** उपसर्ग जोड़ें: `vmi/vm-instance-app-1`।

⚠️ उपसर्ग ठीक `vmi/` है, `vm/` नहीं। `vm/` के साथ आपको अधिकारों की त्रुटि मिलेगी (`cannot get resource "virtualmachines/portforward"`): प्रतिभागी को चल रहे मशीन इंस्टेंस पर अधिकार दिए गए हैं, उनकी परिभाषाओं पर नहीं।
