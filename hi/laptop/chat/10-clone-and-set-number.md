## 10. सामग्री लेना और अपना नंबर भरना

**मैनिफ़ेस्ट वाला रिपॉज़िटरी**

📍 **कहाँ:** अपने लैपटॉप पर, टर्मिनल में। हम इसे आपकी होम डायरेक्टरी में रखेंगे — इससे रास्ता सबके लिए एक जैसा रहता है, और मेरे लिए आपकी मदद करना आसान हो जाता है।

**टर्मिनल कहाँ खोलें:**
• macOS — Spotlight (`Cmd+Space`), "Terminal" टाइप करें
• Linux — ज़्यादातर एन्वायरनमेंट में `Ctrl+Alt+T`
• Windows — "Start" मेन्यू, "PowerShell" टाइप करें

**फ़ाइलों वाला फ़ोल्डर लीजिए** (तीन कमांड, एक-एक करके):
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
पहली कमांड आपको आपकी होम डायरेक्टरी में ले जाती है, दूसरी उसमें सामग्री वाला फ़ोल्डर डाउनलोड करती है, और तीसरी उसके अंदर जाती है। यहाँ से आगे हर कमांड **यहीं से** चलाई जाती है — उनमें दिए रास्ते इसी फ़ोल्डर के सापेक्ष लिखे गए हैं।

**देखिए क्या डाउनलोड हुआ:**
```bash
ls manifests scripts
```
आपको चार मैनिफ़ेस्ट और चार स्क्रिप्ट दिखने चाहिए — ठीक वही, जो फ़ाइल-मैप में थे।

**अगर आपने टर्मिनल बंद कर दिया या भटक गए** — वापस लौटने का रास्ता हमेशा एक ही है:
```bash
cd ~/cozystack-migration-workshop/workshop
```
Windows पर रास्ता वही है: `cd $HOME\cozystack-migration-workshop\workshop`।
यह जाँचने के लिए कि आप अभी कहाँ हैं: `pwd` (PowerShell में भी काम करता है)।

⚠️ `/workshop` सफ़िक्स ज़रूरी है। रिपॉज़िटरी में वर्कशॉप की सामग्री के बगल में एक `labs` फ़ोल्डर है जिसमें अलग स्वतंत्र लैब हैं — अगर आप एक स्तर ऊपर ही रुक गए, तो कमांड को न `manifests` मिलेगा, न `scripts`।

**संपादन के लिए फ़ाइलें किससे खोलें।** मैनिफ़ेस्ट सादे टेक्स्ट फ़ाइलें हैं, इसलिए कुछ भी चलेगा:
• टर्मिनल में — `nano manifests/03-app-vm.yaml` (सहेजें: `Ctrl+O`, `Enter`, बाहर निकलें: `Ctrl+X`)
• macOS पर माउस से — `open -a TextEdit manifests/03-app-vm.yaml`
• Windows पर माउस से — `notepad manifests\03-app-vm.yaml`
• अगर VS Code इंस्टॉल है — `code .` पूरे फ़ोल्डर को एक बार में खोल देता है, यह सबसे सुविधाजनक है

⚠️ `.yaml` फ़ाइलों को Word या Google Docs में न खोलें: वे कोट्स और डैश बदल देते हैं, जिसके बाद फ़ाइल लागू होनी बंद हो जाती है और त्रुटि अकारण-सी दिखती है।

हर फ़ाइल में `tenant-workshopXX` प्लेसहोल्डर है। अपना नंबर एक ही बार में हर जगह भर दीजिए, वरना मैनिफ़ेस्ट ग़लत जगह चला जाएगा। मान लीजिए आपका लॉगिन `workshop03` है:

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS** (यहाँ `sed` का सिंटैक्स अलग है — खाली कोट्स पर ध्यान दें)
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows** (PowerShell)
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**जाँचिए कि एक भी प्लेसहोल्डर बाकी न रहे:**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "clean, you can continue"
```

एक जगह ऐसी है जिसे कमांड नहीं छुएगी: `manifests/03-app-vm.yaml` में पंक्ति `url: "ВСТАВЬТЕ_PRESIGNED_URL"`। यह URL आपको बाद में मिलेगा, जब आप इमेज कन्वर्ट करेंगे। फ़िलहाल बस इतना जान लीजिए कि वह वहाँ आपका इंतज़ार कर रहा है।
