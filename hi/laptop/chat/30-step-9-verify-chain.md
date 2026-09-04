## 30. स्टेप 9: पूरी श्रृंखला की जाँच करें

**सच्चाई का क्षण**

⚠️ **सबसे पहले — वर्चुअल मशीन के भीतर — firewalld को बंद कर दें।** माइग्रेट किया गया CentOS
अपने पिछले जीवन के नियम साथ ले आया और बाहर की ओर सिर्फ़ SSH ही उजागर करता है। एप्लिकेशन का
पोर्ट बंद है, और आपके लैपटॉप से किया गया port-forward `no route to host` से टकराएगा — और यह
ऐसा दिखेगा जैसे "एप्लिकेशन काम नहीं कर रहा।"

```bash
systemctl stop firewalld
systemctl disable firewalld
```

वहीं, मशीन के भीतर से ही जाँच लें कि एप्लिकेशन जीवित है:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — आप port-forward कर सकते हैं। `503` — नेटवर्क वाले स्टेप पर वापस जाएँ।

📍 **आगे — अपने लैपटॉप पर।** एप्लिकेशन का पोर्ट अपने पास फ़ॉरवर्ड करते हैं:
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
इस कमांड वाली विंडो को बंद न करें: टनल तब तक जीवित रहता है जब तक यह चलती रहती है।

⚠️ **यहाँ `vmi/` अनिवार्य है, जबकि `virtctl console` में उल्टा — यह बाधा बनता है।** यह कोई
टाइपो या हमारी सनक नहीं है: दोनों कमांड्स का target सिंटैक्स अलग है। `port-forward` को
`type/name` चाहिए और प्रीफ़िक्स के बिना यह `target must contain type and name separated by '/'`
जवाब देता है। `console` सिर्फ़ नाम की अपेक्षा करता है और प्रीफ़िक्स के साथ `forbidden` जवाब देता
है, क्योंकि यह `vmi` शब्द को मशीन का नाम मान लेता है।

अगर virtctl क्लाइंट और क्लस्टर के बीच वर्ज़न के अंतर की शिकायत करता है — तो यह एक चेतावनी है,
त्रुटि नहीं, और यह बाधा नहीं बनती।

अगर port-forward फिर भी नहीं उठता, तो वही टनल मशीन के Pod के ज़रिए बनाया जा सकता है:
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <आउटपुट-से-पॉड-का-नाम> 8080:8080
```

टर्मिनल की दूसरी विंडो में:
```bash
# स्वास्थ्य
curl -s http://localhost:8080/actuator/health

# एक ऑर्डर बनाते हैं
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# देखते हैं कि वह रिकॉर्ड हो गया
curl -s http://localhost:8080/api/orders
```

अगर ऑर्डर बन गया — तो आपने पूरा रास्ता तय कर लिया। एप्लिकेशन VMware से आया, क्लस्टर में चलता
है, एक प्रबंधित डेटाबेस में लिखता है और एक प्रबंधित क़तार में इवेंट भेजता है।

आधे घंटे पहले यह सिस्टम ESXi पर रह रहा था।
