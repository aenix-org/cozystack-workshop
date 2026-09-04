## 8. bastion में लॉगिन

**एक लॉगिन — और आप पहले से ही क्लस्टर में हैं**

📍 **कहाँ:** डैशबोर्ड ब्राउज़र में खोलें; बाकी सब कुछ bastion पर SSH के ज़रिए होता है।

**आपके क्रेडेंशियल्स** (लॉगिन और पासवर्ड तीनों जगह एक जैसे हैं):
```
dashboard: https://dashboard.workshop.aenix.io
bastion:   ssh workshopXX@<bastion-पता>
login:     workshopXX      ← आपका नंबर, मैं आपको व्यक्तिगत रूप से बताऊँगा
password:  ...             ← मैं आपको व्यक्तिगत रूप से बताऊँगा
```

bastion में लॉगिन करें — पासवर्ड वही है जो डैशबोर्ड का है, **SSH key की ज़रूरत नहीं**:

```bash
ssh workshopXX@<bastion-पता>
```

अंदर पहुँचते ही क्लस्टर तक पहुँच पहले से सेट है: kubeconfig `~/.kube/config` में रहता है, और `kubectl`
तुरंत आपके टेनेंट को देख लेता है। **इसके लिए कोई ब्राउज़र नहीं खुलता** — क्लस्टर में लॉगिन एक token के
ज़रिए होता है, Keycloak के बिना। चलिए जाँचते हैं:

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

पहली कमांड `tenant-workshopXX` दिखाएगी; दूसरी `No resources found` का जवाब देगी। यही
सही जवाब है: अभी कोई मशीन नहीं है, लेकिन क्लस्टर ने आपको पहचान लिया है।

⚠️ `kubectl get vm` और `kubectl get vmi` काम नहीं करेंगे — आपके अकाउंट के तहत `vminstance` टाइप ही
उपलब्ध है। यह जान-बूझकर ऐसा है।

⚠️ ब्राउज़र वाला डैशबोर्ड (माउस से किए जाने वाले स्टेप्स के लिए) उसी लॉगिन और पासवर्ड से चलता है। लेकिन
डैशबोर्ड से मिलने वाली kubeconfig (`Info → Secrets → kubeconfig-tenant-workshopXX`) को bastion पर
डाउनलोड करने की **ज़रूरत नहीं**: वहाँ वह ब्राउज़र-आधारित लॉगिन के लिए है, जबकि bastion पर पहले से एक
तैयार kubeconfig मौजूद है जो उसके बिना काम करती है।
