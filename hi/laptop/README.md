# वर्कशॉप: VMware VM को Cozystack में माइग्रेट करना (अपने ही लैपटॉप से)

हम एक ऐसा एप्लिकेशन लेते हैं जो VMware में एक वर्चुअल मशीन पर सालों से चल रहा है, और उसे
Cozystack में ले जाते हैं। यह सब आप अपने हाथों से करते हैं।

> अगर प्रशिक्षक ने आपको एक साझा VM (bastion) दी है जिसमें टूल्स और पहुँच पहले से मौजूद हैं —
> तो आपको दूसरा सेट चाहिए, [`../bastion/`](../bastion/), जहाँ सब कुछ पहले से सेट है।

यह फ़ाइल रूट है: क्या किसके बाद आता है, कौन-सी कमांड टाइप करनी हैं, और अंत में आपके पास क्या होना
चाहिए। चीज़ें जिस तरह बनाई गई हैं वैसी क्यों हैं, इसकी व्याख्याएँ और मैनिफ़ेस्ट व स्क्रिप्ट के
लाइन-दर-लाइन विवरण [`chat/`](chat/) फ़ोल्डर में हैं — हर संदेश के लिए एक फ़ाइल। लिंक हर स्टेप के
अंत में हैं।

## रूट

एप्लिकेशन तीन मशीनों पर रहता है: खुद एप्लिकेशन, डेटाबेस, और मैसेज क़तार। हम सिर्फ़ पहली को ले जाते
हैं — डेटाबेस और क़तार पीछे रह जाते हैं, और उनकी जगह हम Cozystack कैटलॉग से बने-बनाए ले लेते हैं।

| चरण | हम क्या करते हैं | कहाँ |
|---|---|---|
| 1 | इमेज के लिए स्टोरेज सेट करना | लैपटॉप पर |
| 2 | डिस्क को VMware फ़ॉर्मैट से KVM फ़ॉर्मैट में फिर से पैक करना | एक अस्थायी मशीन में |
| 3 | मशीन को उसके नए घर में चालू करना | लैपटॉप पर |
| 4 | कैटलॉग से डेटाबेस और क़तार ऑर्डर करना | लैपटॉप पर |
| 5 | नेटवर्किंग ठीक करना और एप्लिकेशन को नए पतों पर स्विच करना | आपकी मशीन में |

उसके बाद आता है अंतिम जाँच: एप्लिकेशन में बनाया गया एक ऑर्डर पूरे रास्ते डेटाबेस और क़तार तक
पहुँचता है।

## प्रशिक्षक ने आपको क्या दिया

प्रशिक्षक आपको देता है:

* डैशबोर्ड https://dashboard.workshop.aenix.io
* यूज़रनेम `workshopXX`, पासवर्ड मौके पर दिया जाएगा
* kubeconfig — डैशबोर्ड में: `Info` → `Secrets` टैब → `kubeconfig-tenant-workshopXX` secret

नीचे हर जगह, `workshopXX` को अपने नंबर से बदलें।

## शुरू करने से पहले: चार यूटिलिटीज़

इन्हें वर्कशॉप से पहले, आपके लैपटॉप पर एक बार इंस्टॉल किया जाता है।

| यूटिलिटी | किसलिए | इंस्टॉल |
|---|---|---|
| `kubectl` | फ़ाइलें लागू करता है, दिखाता है कि क्लस्टर में क्या है | [chat/04](chat/04-install-kubectl.md) |
| `virtctl` | वर्चुअल मशीन कंसोल और पोर्ट फ़ॉरवर्डिंग | [chat/05](chat/05-install-virtctl.md) |
| `kubelogin` | ब्राउज़र से लॉगिन; इसके बिना क्लस्टर आपको अंदर नहीं आने देगा | [chat/06](chat/06-install-kubelogin.md) |
| `git` | इस रिपॉज़िटरी को खींचने के लिए | [chat/09](chat/09-install-git.md) |

⚠️ **इस वर्कशॉप के लिए krew की ज़रूरत नहीं** — क्यों, [chat/07](chat/07-about-krew.md) में।

एक जाँच कि सब कुछ जगह पर है। हर कमांड एक वर्शन या हेल्प टेक्स्ट प्रिंट करती है, `command not found`
नहीं:

```bash
kubectl version --client
virtctl version --client
kubectl oidc-login --help
```

## क्लस्टर से कनेक्ट करना

डैशबोर्ड से kubeconfig को डिस्क पर सेव करें और `KUBECONFIG` वैरिएबल को उस पर पॉइंट करें।

**macOS और Linux** — secret की सामग्री को `~/.kube/workshop` में डालें, फिर:

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Windows (PowerShell):**

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # kubeconfig पेस्ट करें; फ़ाइल टाइप — "All Files"
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

पहली रिक्वेस्ट पर एक ब्राउज़र खुलेगा — `workshopXX` के रूप में लॉग इन करें।

⚠️ **Windows: फ़ाइल सिर्फ़ UTF-8 में सेव करें।** Notepad और PowerShell में `>` रीडायरेक्ट
UTF-16 लिखते हैं, और `kubectl` ऐसी फ़ाइल नहीं पढ़ेगा — यह जवाब देगा
`x509: certificate signed by unknown authority`, भले ही सर्टिफ़िकेट में कुछ गलत न हो।

⚠️ त्रुटि `dial tcp [::1]:8080 ... refused` का मतलब है कि `kubectl` को kubeconfig नहीं मिला,
न कि क्लस्टर अगम्य है। दोनों का विवरण — [chat/08](chat/08-connect-to-cluster.md) में।

## सामग्री प्राप्त करना

```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/laptop
```

⚠️ `/laptop` सफ़िक्स अनिवार्य है: यह फ़ोल्डर लैपटॉप रास्ते की सामग्री रखता है, मैनिफ़ेस्ट और
स्क्रिप्ट के साथ; इसके बिना कमांड न `manifests` ढूँढ पाएँगी, न `scripts`।

हर फ़ाइल में एक `tenant-workshopXX` प्लेसहोल्डर है। अपने नंबर को एक साथ बदल दें
(उदाहरण में — `workshop03`):

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +

# macOS — वही sed, लेकिन इसे -i के बाद खाली कोट्स चाहिए
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

```powershell
# Windows
Get-ChildItem -Path manifests,scripts -File -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw) -replace 'tenant-workshopXX','tenant-workshop03' |
    Set-Content $_.FullName -NoNewline
}
```

हम जाँचते हैं कि एक भी प्लेसहोल्डर नहीं बचा:

```bash
grep -rn tenant-workshopXX manifests scripts || echo "all clean, you can continue"
```

एक जगह कमांड जानबूझकर अछूती छोड़ती है: `manifests/03-app-vm.yaml` में लाइन
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` — वह लिंक आपको दूसरे चरण के बाद मिलेगा।

विस्तार से: [chat/10](chat/10-clone-and-set-number.md) ·
फ़ाइल मैप [chat/11](chat/11-file-map.md)

---

## चरण 1. इमेज के लिए स्टोरेज

📍 लैपटॉप पर।

फिर से पैक की गई डिस्क को कहीं जाना है जहाँ से प्लेटफ़ॉर्म उसे नेटवर्क पर खींच सके। हम एक bucket
सेट करते हैं — S3 इंटरफ़ेस वाला ऑब्जेक्ट स्टोरेज।

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**आपको दिखना चाहिए:** `bucket.apps.cozystack.io/my-images created`, फिर `READY: True`।

⚠️ **टाइप का नाम पूरा लिखें, `bucket` नहीं।** यह शब्द क्लस्टर में तीन बार लिया गया है: कैटलॉग से
हमारा टाइप, Flux का टाइप, और ऑब्जेक्ट-स्टोरेज मानक का टाइप। तीनों में से किसे `kubectl` छोटे नाम
के बदले रखेगा, यह पहले से पता नहीं, और अगर वह गलत हुआ, तो आपको एक ऐसे रिसोर्स पर अनुमति अस्वीकृति
मिलेगी जो आपने कभी नहीं माँगा: `buckets.source.toolkit.fluxcd.io is forbidden`। यह एक्सेस की
समस्या नहीं है, और ठीक करने के लिए कुछ नहीं।

⚠️ **अगर `apply` `SchemaError … unknown model in reference` के साथ विफल हो** — यह क्लाइंट-साइड
वैलिडेशन है जो अटकती है, क्लस्टर नहीं; मैनिफ़ेस्ट सही है। इसका वर्कअराउंड:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`। यह फ़्लैग सिर्फ़ लोकल जाँच बंद
करता है; सर्वर अपनी तरफ़ से ऑब्जेक्ट को फिर भी वैलिडेट करेगा।

**आगे आपको keys चाहिए होंगी:** डैशबोर्ड → `Bucket` → `my-images` → `Secrets` टैब →
`bucket-my-images-app-credentials` secret। वहाँ से आप `bucketName`, `accessKey` और `secretKey`
लेते हैं — उन्हें अगले चरण में स्क्रिप्ट में डालेंगे।

मैनिफ़ेस्ट विवरण: [chat/13](chat/13-bucket-manifest.md) ·
पूरा स्टेप: [chat/14](chat/14-step-1-bucket.md)

---

## चरण 2. डिस्क को फिर से पैक करना

📍 पहले लैपटॉप पर, फिर अस्थायी मशीन के अंदर।

VMware से आई डिस्क VMDK फ़ॉर्मैट में लिखी है, जबकि KVM QCOW2 पढ़ता है। `virt-v2v` फिर से पैक करने
का काम संभालता है; एक बार के काम के लिए इसे लैपटॉप पर इंस्टॉल करने का कोई मतलब नहीं, इसलिए हम
टूल्स पहले से मौजूद एक अस्थायी मशीन चालू करते हैं।

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**आपको दिखना चाहिए:** `created` वाली दो लाइनें, फिर `Running`।

⚠️ `Running` का मतलब "चालू", "तैयार" नहीं: अंदर, `cloudInit` कुछ और मिनट काम करता रहता है —
पैकेज इंस्टॉल करता और `mc` डाउनलोड करता। बहुत जल्दी लॉग इन करेंगे तो `virt-v2v` नहीं मिलेगा।

लॉग इन करें (यूज़रनेम `ubuntu`, पासवर्ड `ubuntu`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

अंदर: `nano convert.sh`, `scripts/convert.sh` का टेक्स्ट पेस्ट करें, `ВСТАВЬТЕ_...` की जगह अपने
`bucketName`, `accessKey` और `secretKey` डालें, और `bash convert.sh` चलाएँ।

**आपको दिखना चाहिए:** आउटपुट के अंत में, `Share:` शब्द के बाद — इमेज का एक साइन किया हुआ लिंक।
अगले चरण में आपको इसकी ज़रूरत होगी।

मैनिफ़ेस्ट विवरण: [chat/15](chat/15-conversion-vm-manifest.md) ·
स्क्रिप्ट विवरण: [chat/17](chat/17-convert-script.md) ·
दोनों स्टेप पूरे: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## चरण 3. मशीन उसके नए घर में

📍 लैपटॉप पर।

⚠️ पहले कन्वर्टर मशीन को बंद करें — उसने अपना काम कर लिया है और आपके कोटा का 8Gi रोके हुए है।
अगर आप उसे नहीं हटाएँगे, तो नई मशीन `Pending` में अटकी रहेगी:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

आपको जो लिंक मिला उसे `manifests/03-app-vm.yaml` में
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` की जगह डालें, फिर:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**आपको दिखना चाहिए:** `created` वाली दो लाइनें, फिर `Running`। यहाँ इंतज़ार लंबा है —
प्लेटफ़ॉर्म आपके लिंक से इमेज डाउनलोड कर रहा है।

लॉग इन करें (यूज़रनेम `root`, पासवर्ड `cozydemo`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **अंदर कोई नेटवर्क नहीं होगा।** यह कोई खराब परीक्षण मंच नहीं है — ऐसा ही होना चाहिए। हम इसे
पाँचवें चरण में ठीक करते हैं।

मैनिफ़ेस्ट विवरण: [chat/20](chat/20-app-vm-manifest.md) ·
पूरा स्टेप: [chat/21](chat/21-step-4-your-vm.md)

---

## चरण 4. कैटलॉग से डेटाबेस और क़तार

📍 लैपटॉप पर।

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**आपको दिखना चाहिए:** `postgres.apps.cozystack.io/db created` और
`kafka.apps.cozystack.io/kafka created`। Kafka को चालू होने में Postgres से काफ़ी ज़्यादा समय
लगता है।

मैनिफ़ेस्ट विवरण: [chat/23](chat/23-managed-manifest.md) ·
पूरा स्टेप: [chat/24](chat/24-step-5-database-and-queue.md)

---

## चरण 5. एप्लिकेशन को जोड़ना

📍 आपकी वर्चुअल मशीन के अंदर।

सख़्त क्रम में तीन क्रियाएँ: नेटवर्किंग के बिना स्क्रिप्ट डेटाबेस तक नहीं पहुँच सकती, और डेटाबेस
के बिना वह स्कीमा स्वीकार नहीं करेगी।

| स्टेप | हम क्या ठीक करते हैं | किससे |
|---|---|---|
| 5.1 | मशीन में कोई नेटवर्क नहीं | `scripts/netfix-dhcp.sh` |
| 5.2 | एप्लिकेशन पुराने पते ढूँढता है | `scripts/connect-managed.sh` |
| 5.3 | नए डेटाबेस में कोई टेबल नहीं | `scripts/orders-schema.sql` |

**5.1.** स्क्रिप्ट `BOOTPROTO=static` को `dhcp` में बदलती है और VMware नेटवर्क का पता हटा देती
है। आप इसे हाथ से टाइप करते हैं — मशीन में अभी भी नेटवर्क नहीं है, इसलिए आप फ़ाइल डाउनलोड नहीं कर
सकते। उसके बाद मशीन को **रीबूट** चाहिए: CentOS 7 नेटवर्क सेटिंग्स बूट पर लागू करता है।

**5.2.** स्क्रिप्ट `/etc/orders/application.properties` में हार्ड-वायर्ड पते `192.168.10.30`
और `192.168.10.40` को service नामों से बदल देती है और एप्लिकेशन को फिर से शुरू करती है।

**5.3.** हम `psql` क्लाइंट इंस्टॉल करते हैं और स्कीमा लागू करते हैं — कमांड नीचे हैं, अंतिम जाँच
में।

विस्तार से: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## अंतिम जाँच: क्रम में तीन स्टेप

### स्टेप 1. firewalld बंद करना

📍 आपकी मशीन के अंदर। नियम पुराने नेटवर्क से बचे हुए हैं और एप्लिकेशन तक जाने वाली रिक्वेस्ट काट रहे हैं।

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**आपको दिखना चाहिए:** `200`। अगर `503` — डेटाबेस या क़तार से कुछ कनेक्ट नहीं हुआ।

### स्टेप 2. डेटाबेस स्कीमा

📍 आपकी मशीन के अंदर। CentOS 7 का स्टॉक psql वर्शन 9.2 है; यह SCRAM नहीं कर सकता और जवाब देता है
`SCRAM authentication requires libpq version 10 or above`। हम एक नया इंस्टॉल करते हैं:

```bash
# 1. PGDG रिपॉज़िटरी — PostgreSQL पैकेजों का स्रोत
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: CentOS 7 रिपॉज़िटरी में नहीं, इसलिए हम इसे EPEL आर्काइव से लेते हैं
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. खुद क्लाइंट — सिर्फ़ जीवित pgdg15 रिपॉज़िटरी से
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ दूसरी और तीसरी कमांड फ़ालतू नहीं हैं। `libzstd` के बिना इंस्टॉल `Requires: libzstd >= 1.4.0`
पर विफल होता है। `--disablerepo`/`--enablerepo` के बिना — `HTTPS Error 410 - Gone` पर:
रिपॉज़िटरी पैकेज हर PostgreSQL वर्शन को एक साथ सक्षम कर देता है, जीवन-समाप्त 12 और 13 सहित, और
इंस्टॉल करने से पहले, `yum` हर सक्षम रिपॉज़िटरी में घूमता है और पहली मृत पर विफल हो जाता है।

```bash
psql --version
```

अगर `command not found` — क्लाइंट `PATH` के बाहर उतरा: `ls /usr/pgsql-*/bin/psql` देखें, फिर
`export PATH="$PATH:/usr/pgsql-15/bin"`।

हम स्कीमा लाते हैं और उसे लागू करते हैं:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**आपको दिखना चाहिए:** आख़िरी कमांड में — `orders` टेबल।

डेटाबेस का पता कोई IP नहीं बल्कि एक नाम है: `postgres-db-rw` (`db` service, read-write),
`tenant-workshopXX` (आपका namespace), `svc.cozy.local` (क्लस्टर के आंतरिक नामों का सफ़िक्स)।
पासवर्ड `manifests/04-managed.yaml` में सेट है, इसलिए आपको इसे कहीं ढूँढने की ज़रूरत नहीं।

विस्तार से: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### स्टेप 3. पोर्ट फ़ॉरवर्डिंग और बाहर से जाँच

📍 लैपटॉप पर।

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

विंडो बंद न करें — टनल तब तक ज़िंदा रहता है जब तक कमांड चलती है। दूसरी विंडो में:

```bash
curl -s http://localhost:8080/actuator/health

curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s http://localhost:8080/api/orders
```

**आपको दिखना चाहिए:** सूची में ऑर्डर। पूरा सफ़र पूरा हुआ।

विस्तार से: [chat/30](chat/30-step-9-verify-chain.md)

---

## चीट शीट

> **हर कमांड को `vmi/` प्रीफ़िक्स की ज़रूरत नहीं, और यह कोई टाइपो नहीं है।** दोनों कमांड की टारगेट
> सिंटैक्स अलग है। `virtctl console` सिर्फ़ नाम की अपेक्षा करता है और प्रीफ़िक्स के साथ `forbidden`
> जवाब देता है, क्योंकि यह `vmi` शब्द को मशीन का नाम समझ लेता है। `virtctl port-forward` को
> `type/name` चाहिए और प्रीफ़िक्स के बिना
> `target must contain type and name separated by '/'` जवाब देता है।

```bash
# app-VM में लॉग इन करें (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# conversion-VM में लॉग इन करें (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# एप्लिकेशन का पोर्ट लैपटॉप पर फ़ॉरवर्ड करें
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

कंसोल से निकलने के लिए — `Ctrl+]`। अगर कनेक्ट करने के बाद स्क्रीन खाली है, तो Enter दबाएँ। वही
चीज़ माउस से भी उपलब्ध है: डैशबोर्ड में मशीन के पेज पर **VNC** बटन।

## कहाँ फँसना आसान है

* conversion-VM के लिए, सिर्फ़ `ubuntu-20.04` इस्तेमाल करें। 24.04 पर कर्नेल पैनिक होता है; 22.04
  पर `virt-v2v` पुराने CentOS 7 RPM डेटाबेस को पार्स नहीं कर पाता।
* कैटलॉग इमेज के लिए VMDisk खुद इमेज से बड़ी होनी चाहिए, वरना क्लोन पूरा नहीं होगा और डिस्क
  `Terminating` में अटक जाएगी। `ubuntu-20.04` के लिए, 25Gi काफ़ी है।
* नई app-VM पर, पहले `netfix`, फिर `connect` — वरना एप्लिकेशन प्रबंधित सेवाएँ को नहीं देखेगा।
* `.yaml` फ़ाइलें Word या Google Docs में न खोलें: वे कोट्स और डैश बदल देते हैं, फ़ाइल लागू होना
  बंद कर देती है, और त्रुटि अकथनीय लगती है।

बाकी की मुश्किलें — [chat/31](chat/31-troubleshooting.md)।

## जो परीक्षण मंच सेट कर रहे हैं उनके लिए

कोटा, tenant बनाने का क्रम, और प्लेटफ़ॉर्म वर्शन — [REQUIREMENTS.md](../REQUIREMENTS.md) में।

## सभी संदेश क्रम में

32 संदेशों की सूची — [chat/README.md](chat/README.md)।
</content>
</invoke>
