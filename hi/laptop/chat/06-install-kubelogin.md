## 6. kubelogin इंस्टॉल करना

**kubelogin — अपने अकाउंट से लॉगिन**

इसके बिना `kubectl` लॉगिन के लिए ब्राउज़र नहीं खोल पाएगा और लगातार प्राधिकरण
त्रुटि के साथ जवाब देता रहेगा। फ़ाइल का नाम ठीक `kubectl-oidc_login` ही होना
चाहिए — इसी नाम से kubectl उसे एक प्लगइन के रूप में ढूँढता है।

**macOS**
```bash
brew install int128/kubelogin/kubelogin
```
Homebrew के बिना:
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
(`$HOME\bin` फ़ोल्डर पिछले स्टेप में ही बना दिया गया था और PATH में जोड़ दिया गया था)

**चलिए जाँचते हैं:**
```
kubectl oidc-login --help
```
अगर मदद-टेक्स्ट (help) छप गया — तो प्लगइन अपनी जगह पर है और kubectl उसे देख रहा है।
