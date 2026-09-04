## 8. क्लस्टर में लॉगिन

**अपने टेनेंट से कनेक्ट करना**

📍 **कहाँ:** डैशबोर्ड ब्राउज़र में खोलें; कमांड्स अपने लैपटॉप पर चलाएँ।

**आपके क्रेडेंशियल्स:**
```
dashboard: https://dashboard.workshop.aenix.io
login:     workshopXX      ← आपका नंबर, मैं आपको व्यक्तिगत रूप से बताऊँगा
password:  ...             ← मैं आपको व्यक्तिगत रूप से बताऊँगा
```

1. ऊपर दिए गए लिंक पर डैशबोर्ड खोलें।
2. अपने लॉगिन से लॉगिन करें।
3. डैशबोर्ड में: **Info → Secrets tab → `kubeconfig-tenant-workshopXX`**। *Reveal* पर क्लिक करें
   और सामग्री कॉपी करें।
4. इसे एक फ़ाइल में सेव करें और वेरिएबल को उस पर पॉइंट करें:

**macOS और Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # जो कॉपी किया उसे पेस्ट करें, फिर सेव करें
export KUBECONFIG=~/.kube/workshop
```

**Windows** (PowerShell)
```powershell
notepad $HOME\.kube\workshop   # पेस्ट करें, फिर सेव करें
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**चलिए जाँचते हैं:**
```
kubectl get vminstance -n tenant-workshopXX
```
एक ब्राउज़र खुलेगा — `workshopXX` के रूप में लॉगिन करें। इसके बाद कमांड को
`No resources found` का जवाब देना चाहिए। यही सही जवाब है: अभी कोई मशीन नहीं है, लेकिन क्लस्टर ने आपको पहचान लिया है।

⚠️ दो चीज़ें, जिन पर लोग सबसे ज़्यादा ठोकर खाते हैं:
• `KUBECONFIG` को ठीक उसी फ़ाइल पर पॉइंट करना चाहिए, जहाँ आपने कॉन्फ़िग पेस्ट किया था।
• `kubectl get vm` और `kubectl get vmi` काम नहीं करेंगे — आपके अकाउंट के तहत `vminstance` टाइप ही
  उपलब्ध है। यह जान-बूझकर ऐसा है।

⚠️ **`x509: certificate signed by unknown authority`** — दूसरी आम त्रुटि, लगभग
हमेशा Windows पर। इसका मतलब सर्टिफ़िकेट में कोई समस्या नहीं है; इसका मतलब है कि `kubectl` ने
**गलत एक्सेस फ़ाइल** उठा ली: क्लस्टर के आंतरिक सर्टिफ़िकेट अथॉरिटी पर भरोसा आपके
kubeconfig में, `certificate-authority-data` फ़ील्ड में रहता है, और डिफ़ॉल्ट फ़ाइल में वह नहीं होता।

चलिए इसे स्टेप दर स्टेप सुलझाते हैं, PowerShell में:
```powershell
$env:KUBECONFIG
# खाली — मतलब डिफ़ॉल्ट फ़ाइल इस्तेमाल हो रही है, वह नहीं जो आपको दी गई थी

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — फ़ाइल अधूरी सेव हुई थी; डैशबोर्ड से सीक्रेट फिर से डाउनलोड करें

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# apiVersion से शुरू होना चाहिए; छोटे-छोटे चौकोर या खालीपन का मतलब फ़ाइल UTF-16 में है
```

तीसरा बिंदु Windows का सबसे कपटी जाल है। Notepad और `>` रीडायरेक्शन फ़ाइल को
**UTF-16** में सेव करते हैं, जिसे `kubectl` नहीं पढ़ेगा। सिर्फ़ UTF-8 में सेव करें: Notepad में
"All Files" फ़ाइल टाइप चुनें, और कमांड लाइन से `>` के बजाय `Out-File -Encoding utf8` इस्तेमाल करें।
