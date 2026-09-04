## 21. स्टेप 4: आपकी वर्चुअल मशीन

**अपनी खुद की इमेज से मशीन खड़ी करना**

📍 **कहाँ:** bastion पर।

⚠️ **पहले कन्वर्टर मशीन को बंद करें** — इसका काम पूरा हो चुका है और यह आपके कोटे का 8Gi घेरे बैठी है।
अगर इसे नहीं हटाया, तो नई मशीन `Pending` में अटकी रहेगी, और ऐसा लगेगा
कि परीक्षण मंच खराब हो गया है। पिछले वर्कशॉप्स में यहाँ लगभग सभी अटक गए थे:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

इमेज इस दौरान bucket में बनी रहती है — इसी से हम मशीन खड़ी करेंगे।

अब `manifests/03-app-vm.yaml` खोलें, presigned लिंक को `url` फ़ील्ड में पेस्ट करें
और लागू करें:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

पहले क्लस्टर लिंक से इमेज डाउनलोड करता है और उसे रेप्लिका के बीच बाँट देता है — इसमें एक-दो मिनट लगते हैं।
फिर मशीन शुरू हो जाती है।

चलिए अंदर जाते हैं:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

**आपकी मशीन में एक्सेस:**
```
login:    root
password: cozydemo
```

कंसोल से बाहर निकलने के लिए — `Ctrl+]`।

**यहाँ वही ऑब्जेक्ट्स की जोड़ी है जो कन्वर्टर मशीन के साथ थी**, बस डिस्क
कैटलॉग से नहीं ली जाती, बल्कि आपके लिंक से डाउनलोड होती है:

• **VM Disk** `app-1` — 10Gi, source = http, वही presigned-URL
• **VM Instance** `app-1` — प्रोफ़ाइल `centos.7`, instance type `u1.medium`

नाम एक जैसे हैं, और यह ठीक है: डिस्क और मशीन अलग-अलग ऑब्जेक्ट टाइप हैं। `virtctl`
कमांड्स में मशीन को, पिछली बार की तरह, उसके प्रीफ़िक्स के साथ संबोधित किया जाता है: **`vm-instance-app-1`**।

🖱 **डैशबोर्ड के ज़रिए:** **1)** **VM Disk → Deploy new**: नाम `app-1`, source = **http**,
URL फ़ील्ड में — presigned लिंक, आकार `10Gi`, storage class `replicated`।
**2)** **VM Instance → Deploy new**: नाम `app-1`, instance type `u1.medium`,
profile `centos.7`, डिस्क — `app-1`। कंसोल — मशीन के पेज पर **VNC** बटन।

ध्यान दें कि आपने अभी क्या किया: आपने एक वर्चुअल मशीन को टेक्स्ट में वर्णित किया
और उसे एक ही कमांड से लागू कर दिया। इस फ़ाइल को आप किसी रिपॉज़िटरी में रख सकते हैं और
एक भी क्लिक किए बिना ऐसी ही सौ मशीनें खड़ी कर सकते हैं।
