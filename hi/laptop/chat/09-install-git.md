## 9. git इंस्टॉल करना

**आखिरी टूल — इसी से हम सामग्री उठा लेंगे**

📍 **कहाँ:** आपके लैपटॉप पर।

पहले जाँच लें, शायद वह पहले से मौजूद हो: macOS पर और अधिकांश Linux बिल्ड में git
पहले से इंस्टॉल आता है।
```
git --version
```
अगर उसने वर्ज़न दिखा दिया — तो इस संदेश को छोड़ दें।

**macOS.** सबसे आसान तरीका है सिस्टम के डायलॉग को काम करने देना: `git --version` टाइप करें, और अगर
git इंस्टॉल नहीं है, तो macOS खुद डेवलपर टूल्स इंस्टॉल करने का प्रस्ताव देगा। उसे स्वीकार कर लें।
या सीधे:
```bash
xcode-select --install
```
Homebrew के साथ:
```bash
brew install git
```

**Linux** — डिस्ट्रीब्यूशन परिवार पर निर्भर करता है:
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian, Ubuntu
sudo dnf install -y git                               # Fedora, RHEL, CentOS Stream
```

**Windows** (PowerShell):
```powershell
winget install -e --id Git.Git
```
फिर PowerShell को बंद करके दोबारा खोलें, वरना कमांड नहीं मिलेगा।

⚠️ **अगर `winget` न मिले** — git एक सामान्य इंस्टॉलर से इंस्टॉल होता है: खोलें
https://git-scm.com/download/win, फ़ाइल डाउनलोड करें, उसे चलाएँ और हर स्टेप पर "Next" दबाएँ,
कुछ भी बदलने की ज़रूरत नहीं। इंस्टॉलेशन के बाद — एक नई PowerShell विंडो।
या git के बिना ही काम चलाएँ — नीचे दिए Download ZIP वाले विकल्प से।

**चलिए जाँचते हैं:**
```
git --version
```

🖱 **अगर आप git इंस्टॉल नहीं करना चाहते** — इसकी ज़रूरत ठीक एक बार पड़ती है, फ़ाइलों वाला
फ़ोल्डर डाउनलोड करने के लिए। आप ब्राउज़र से भी काम चला सकते हैं: खोलें
https://github.com/aenix-org/cozystack-migration-workshop, हरे रंग का
**Code → Download ZIP** बटन दबाएँ और आर्काइव को अनपैक करें। उसके बाद सब कुछ वैसा ही है,
बस `cd cozystack-migration-workshop` के बजाय अनपैक किए गए फ़ोल्डर में जाएँ।
