## 7. krew के बारे में — और हम इसका इस्तेमाल क्यों नहीं करते

**छोटा जवाब: आज इसे मत लगाइए**

krew, kubectl के लिए एक प्लगिन मैनेजर है, और इससे आप वही virtctl और kubelogin लगा सकते हैं।
लेकिन पिछले वर्कशॉप्स में सबसे ज़्यादा समय ठीक इसी ने खाया, खासकर Windows पर।
अगर आपने स्टेप 3 और 4 कर लिए हैं — **आपके पास सब कुछ पहले से है, इस पोस्ट को छोड़ दीजिए**।

आगे तभी पढ़िए, अगर krew आपके यहाँ पहले से लगा है या बहुत मन है।

⚠️ **Windows के तीन झमेले, तीनों असल में देखे गए हैं:**
• **मौजूदा विंडो में PATH अपडेट नहीं हुआ।** सबसे आम। उसी सेशन में ठीक हो जाता है:
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe पूरा इंस्टॉल नहीं हुआ** — SmartScreen या एंटीवायरस ने उसे मार दिया। जाँचिए:
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **एडमिन वाली PowerShell विंडो और साधारण विंडो — ये अलग-अलग दुनिया हैं।** इनके `$HOME` अलग हैं
  और यूज़र PATH भी अलग। एडमिनिस्ट्रेटर के तौर पर लगाया, चलाते हैं साधारण यूज़र से —
  तो प्लगिन कभी नहीं मिलेगा। एक ही साधारण विंडो में लगाइए और चलाइए।

**macOS और Linux** — पूरा ब्लॉक कॉपी कीजिए, यह सिस्टम खुद पहचान लेता है:
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
फिर krew को अपने PATH में जोड़िए — यह लाइन आपको अपनी प्रोफ़ाइल में जोड़नी होगी, वरना
टर्मिनल के अगली बार शुरू होने पर यह भूल जाएगी:
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # zsh के लिए, macOS में डिफ़ॉल्ट यही है
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # bash के लिए, आमतौर पर Linux
source ~/.zshrc    # या source ~/.bashrc
```

**Windows** (PowerShell)
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
PowerShell को फिर से बंद करके खोलिए।

**प्लगिन लगाते हैं:**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ एक अहम फ़र्क: krew के ज़रिए लगाने पर कमांड का नाम अलग होता है —
`virtctl console …` की जगह `kubectl virt console …`। आगे निर्देशों में मैं
`virtctl` लिखता हूँ — अगर आपने krew से लगाया है, तो मन में `kubectl virt` रख लीजिए।
गड़बड़ी से बचने के लिए आप एक छोटा उपनाम बना सकते हैं:
```bash
alias virtctl="kubectl virt"
```
