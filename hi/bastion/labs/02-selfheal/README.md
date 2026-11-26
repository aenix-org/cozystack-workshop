# लैब 2 · स्व-उपचार: एक कॉपी को मारें और देखें क्या होता है

| | |
|---|---|
| **समय** | 25 मिनट |
| **यह क्या साबित करता है** | एक कॉपी कुछ ही सेकंड में अपने आप वापस आ जाती है, लेकिन अकेले यह दोष-सहिष्णुता नहीं है |
| **क्या चाहिए होगा** | लैब 0 का क्लस्टर, लैब 1 का `rickroll`, `kubectl`, दो टर्मिनल विंडो |

## यह क्यों मायने रखता है

जल्द ही आपको «प्रवेश-पास» सेवा की ज़िम्मेदारी लेनी होगी: सुरक्षा-दस्ता सुबह सात बजे अतिथि-सूची
देखता है, और वहाँ «हम रीबूट कर रहे हैं, ज़रा रुकिए» नहीं चलता। ऐसा वादा करने से पहले यह पता कर
लेना बेहतर है — जहाँ कुछ भी दाँव पर नहीं है — कि क्लस्टर आखिर खुद क्या करता है और क्या आपको खुद करना पड़ेगा।

चलिए Kubernetes के सबसे ज़ोरदार वादे से निपटते हैं — स्व-उपचार। हम एप्लिकेशन की एक चालू कॉपी को
हटाएँगे और घड़ी से नापेंगे कि वह कितनी देर गायब रहती है। फिर हम कुछ और हटाएँगे —
और देखेंगे कि कॉपी वापस नहीं आती। इन्हीं दो स्थितियों का अंतर इस लैब का विषय है।

## संक्षिप्त शब्दावली

| पद | यह क्या है | जैसा… लेकिन |
|---|---|---|
| **वांछित अवस्था** | क्लस्टर में एक रिकॉर्ड जो कहता है «इसे ऐसा दिखना चाहिए» | **vCenter में क्लस्टर सेटिंग्स**, लेकिन क्लस्टर इसे एक बार लागू नहीं करता — यह लगातार वास्तविकता को इसके अनुरूप लाता रहता है |
| **कंट्रोलर** | क्लस्टर के कंट्रोल प्लेन में चलने वाली एक प्रक्रिया जो «जैसा आदेश दिया» की «जैसा है» से जाँच करती है | **vSphere HA**, लेकिन यह लगातार और सभी ऑब्जेक्ट पर चलती है, न कि किसी होस्ट के विफल होने पर जागती है |
| **ReplicaSet** | एक ऑब्जेक्ट जो सुनिश्चित करता है कि कॉपियाँ ठीक उतनी ही हों जितनी आदेशित की गई थीं | **«N इंस्टेंस बनाए रखो» नियम**, लेकिन यह टूटे हुए की मरम्मत नहीं करता — जो गायब हुआ उसकी जगह नया बना देता है |
| **ownerReferences** | ऑब्जेक्ट के भीतर एक निशान: «इसने मुझे बनाया» | यही वह चीज़ है जिससे किसी माता-पिता को हटाने पर उसके सारे बच्चे अपने-आप साथ चले जाते हैं |
| **टर्मिनेशन** | «हटाओ» और «प्रक्रिया मारी गई» के बीच का ठहराव | **Power Off के बजाय Guest Shutdown**, लेकिन डिफ़ॉल्ट रूप से 30 सेकंड, जिसके बाद उसे कठोरता से मार दिया जाता है |
| **EndpointSlice** | किसी Service के पीछे मौजूद जीवित पतों की सूची | **लोड बैलेंसर पर पूल की सदस्य-सूची**, लेकिन यह लेबल और तैयारी से अपने-आप बनती है — इसमें आप हाथ से नहीं लिखते |

## लैब फ़ोल्डर में क्या है

सारी फ़ाइलें पहले से आपके पास हैं — वे आपको रिपॉज़िटरी के साथ ही मिल गई थीं। कुछ भी नए सिरे से
बनाना या टाइप करना नहीं है: नीचे जहाँ भी `kubectl apply -f name.yaml` लिखा है, फ़ाइल यहीं से ली जाती है।

```bash
# All the lab's commands are run from this folder — otherwise the relative paths in them won't line up.
cd labs/02-selfheal
```

| फ़ाइल | यह क्या है | कब काम आती है |
|---|---|---|
| `check.sh` | जाँचता है कि क्लस्टर ने हटाई गई कॉपियों को खुद बहाल कर दिया | इसे लैब के अंत में चलाते हैं |
| — | लैब के अपने कोई मैनिफ़ेस्ट नहीं हैं: हम लैब 1 के एप्लिकेशन के साथ काम करते हैं, और फ़ाइल वहीं से ली जाती है — `../01-deploy/rickroll.yaml` | |

## स्टेप 1. देखते हैं हमारे पास क्या है

📍 **कहाँ:** bastion पर (bastion टर्मिनल में)।

`rickroll` एप्लिकेशन पहले से चल रहा है। कुछ भी तोड़ने से पहले, देखते हैं कि यह किन ऑब्जेक्ट से बना
है: एक ही कमांड से हम क्लस्टर से एक साथ तीन तरह की सत्ताओं के बारे में पूछते हैं।

```bash
# KUBECONFIG — the path to the file with the cluster's address and your login credentials.
# Until the variable is set, kubectl looks for a cluster on the bastion itself and doesn't find one.
export KUBECONFIG=~/lab.kubeconfig

# get = "show me what's there". Three kinds of object are listed at once, separated by commas.
#   -l app=rickroll   show only those labelled app=rickroll — that is, our
#                     application, not the entire contents of the cluster
kubectl get deployment,replicaset,pods -l app=rickroll
```

**आपको यह दिखना चाहिए** — तीनों ऑब्जेक्ट में से हर एक के लिए एक पंक्ति:

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/rickroll   1/1     1            1           14m

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/rickroll-6f4b9c8d57   1         1         1       14m

NAME                             READY   STATUS    AGE
pod/rickroll-6f4b9c8d57-xk2mp    1/1     Running   14m
```

⚠️ **`replicaset` की एक से ज़्यादा पंक्तियाँ हो सकती हैं।** नई वर्शन की हर रोलआउट पिछले सेट को
इतिहास में छोड़ जाती है — कॉलम में शून्य के साथ। जीवित वही है जहाँ इकाइयाँ खड़ी हैं; बाकी इसलिए
बने रहते हैं ताकि कहीं वापस लौटा जा सके।

ऑब्जेक्ट तीन हैं, हालाँकि लैब 1 के मैनिफ़ेस्ट में आपने एक ही Deployment वर्णित किया था। बाकी दो
क्लस्टर ने खुद बनाए, और यह कोई सजावटी बारीकी नहीं है — आगे जो कुछ भी है वह इसी शृंखला पर निर्भर करता है।

<details>
<summary><b>शृंखला को खोलते हैं: किसने किसको बनाया, और क्यों</b></summary>

नामों को देखिए। किसी Pod का नाम ReplicaSet का नाम प्लस पाँच यादृच्छिक अक्षर होता है, और
ReplicaSet का नाम Deployment का नाम प्लस एक हैश। शृंखला इसी तरह बनी है।

**Deployment** आपके इरादे को पूरा रखता है: कौन-सी इमेज, कितनी कॉपियाँ, कैसे अपडेट करना है। यह
सीधे Pods पर नज़र नहीं रखता — यह ReplicaSet पर नज़र रखता है।

**ReplicaSet** एक ही विचार रखता है: «`app=rickroll` लेबल वाले Pods ठीक इतने ही होने चाहिए»। बस
इतना ही। इसे इमेज या वर्शन के बारे में कुछ नहीं पता।

**Pod** एक चालू कॉपी है।

आप यह पुष्टि इस तरह कर सकते हैं कि यह अटकल नहीं है:

```bash
# The default kubectl table doesn't show the ownerReferences field — you have to ask for it explicitly.
#   -o jsonpath=...   "pull these fields out of the server's response and print them like this"
# Inside the expression: range .items[*] — walk through every Pod found, .metadata.name —
# the Pod's name, ownerReferences[0].kind and .name — the kind and name of whatever created it.
kubectl get pods -l app=rickroll -o jsonpath='{range .items[*]}{.metadata.name}{"  <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}'
```

आउटपुट:

```
rickroll-6f4b9c8d57-xk2mp  <- ReplicaSet/rickroll-6f4b9c8d57
```

`ownerReferences` फ़ील्ड «इस ऑब्जेक्ट ने मुझे बनाया» वाला रिकॉर्ड है। ReplicaSet के पास भी वही
रिकॉर्ड है, बस वहाँ वह Deployment की ओर इशारा करता है।

एक ऑब्जेक्ट के बजाय तीन तल क्यों: तल अलग-अलग चीज़ों के लिए ज़िम्मेदार हैं। जब लैब 4 में हम नई
वर्शन रोलआउट करेंगे, तो Deployment नई वर्शन के लिए एक **दूसरा** ReplicaSet बनाएगा और कॉपियों को
पुराने सेट से नए में एक-एक करके ले जाना शुरू करेगा। इस बीच पुराना ReplicaSet कहीं नहीं जाएगा —
यही वह चीज़ है जो आपको एक ही कमांड से वापस लौटने देती है।

याद रखने लायक एक पार्श्व तथ्य: माता-पिता को हटाना उसके बच्चों को साथ ले जाता है। ReplicaSet को
हाथ से हटाइए — Deployment एक सेकंड के भीतर नया बना देगा। Deployment को हटाइए — सब कुछ गायब हो
जाता है। दूसरी स्थिति को हम लैब के अंत में परखेंगे।

</details>

## स्टेप 2. एक कॉपी को मारें और समय नापें

अब हम एक Pod को हटाएँगे। न बंद करना, न रीबूट करना — उसे पूरी तरह हटाना, मानो किसी ने किसी
वर्चुअल मशीन पर Delete from Disk क्लिक कर दिया हो।

**अभी क्या होने वाला है:** नीचे दी कमांड मौजूदा कॉपी का नाम याद रखेगी, उसे हटाएगी, और फिर सेकंड
में एक बार क्लस्टर से पूछेगी कि क्या किसी **दूसरे** नाम वाली कॉपी Running अवस्था में प्रकट हुई है।
जैसे ही एक प्रकट होती है, यह छाप देती है कि इसमें कितना समय लगा।

```bash
# items[0].metadata.name — the name of the first Pod in the list. We save it in the POD variable:
# without that we won't be able to tell the old copy from the new one later.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')
echo "killing: $POD"

# date +%s — the current time in seconds. This is our stopwatch: we note it before the delete,
# and subtract it from a fresh reading right at the end.
START=$(date +%s)

# delete pod — delete the copy for good.
#   --wait=false   don't wait for the Pod to fully disappear, return control immediately:
#                  we need to start counting seconds from this moment, not afterwards
kubectl delete pod "$POD" --wait=false

# Once a second we re-read the Pod list and look for a line where all of these hold at once:
#   $1!=old        the name doesn't match the old one — so this is a different copy
#   $2=="1/1"      one container out of one is ready
#   $3=="Running"  the pod is running
#   --no-headers   don't print the table header, so awk sees only data
#   2>/dev/null    hide error messages during the seconds when there are no Pods at all
while true; do
  NEW=$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null \
        | awk -v old="$POD" '$1!=old && $2=="1/1" && $3=="Running" {print $1; exit}')
  [ -n "$NEW" ] && break
  sleep 1
done
echo "new copy $NEW ready in $(( $(date +%s) - START ))s"
```

**आपको यह दिखना चाहिए:**

```
killing: rickroll-6f4b9c8d57-xk2mp
pod "rickroll-6f4b9c8d57-xk2mp" deleted
new copy rickroll-6f4b9c8d57-p9wqt ready in 4s
```

चार सेकंड। परीक्षण मंच पर बिखराव दो से पंद्रह तक होता है, इस पर निर्भर करते हुए कि नोड कितना
व्यस्त है। इमेज पहले से नोड पर है, डाउनलोड करने को कुछ नहीं, इसलिए सब कुछ प्रक्रिया शुरू करने और
तैयारी-जाँच पर आकर टिकता है।

**नाम पर ध्यान दें।** पुछल्ला बदल गया: `xk2mp` अब `p9wqt` हो गया। यह वही Pod दोबारा शुरू हुआ नहीं
है — यह एक अलग Pod है। पुराना अब कहीं नहीं है; आप उसकी मरम्मत नहीं कर सकते, उसे रीसायकल बिन से
बहाल नहीं कर सकते, या यह नहीं देख सकते कि उसकी डिस्क पर क्या था।

किसी ने कुछ भी «बहाल» नहीं किया। सेकंड में कई बार ReplicaSet «आदेशित: 1» की «मौजूद: 0» से जाँच
करता है और, बेमेल होने पर, जो गायब है उसे बना देता है। कॉपी लुप्त हुई — बेमेल प्रकट हुआ —
एक कॉपी बनी। यही तंत्र तब भी चलता अगर Pod को किसी अधिक महत्वपूर्ण वर्कलोड के लिए नोड से बेदखल कर
दिया जाता, अगर नोड खुद गिर जाता, या अगर Pod के भीतर का एप्लिकेशन मेमोरी खत्म होने से मर जाता।

## स्टेप 3. जाँचें कि क्या इसमें दोष-सहिष्णुता थी

कॉपी चार सेकंड में वापस आ गई। क्या इसका मतलब है कि सेवा बाधित नहीं हुई?

चलिए जाँचते हैं। हमें **दो टर्मिनल विंडो** चाहिए होंगी।

📍 **विंडो 1** — क्लस्टर के भीतर हम एक नन्हा Pod शुरू करते हैं जो सेकंड में एक बार Service के ज़रिए
हमारे एप्लिकेशन को टहोका देता है और सफलता पर एक बिंदु, त्रुटि पर एक `X` बनाता है:

```bash
export KUBECONFIG=~/lab.kubeconfig

# run = create a single Pod straight from the command line, without a manifest.
#   --rm             delete the Pod as soon as you interrupt the command
#   -it              the Pod's output comes to your screen, Ctrl+C stops it
#   --restart=Never  there's a single copy and no need to recreate it: this is a tool, not a service
#   --image          busybox — an image a few megabytes in size that has wget
# Everything after -- runs inside the Pod. The address http://rickroll is the name of the Service;
# inside the cluster it turns into the application's address on its own.
#   -q               don't print download statistics
#   -T 2             wait no longer than two seconds for a reply, otherwise we count it as a failure
#   -O /dev/null     throw the response body away, all we care about is the fact of a reply
kubectl run pinger --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'while true; do wget -q -T 2 -O /dev/null http://rickroll/healthz \
         && echo "$(date +%T) ." || echo "$(date +%T) X"; sleep 1; done'
```

हर पंक्ति के साथ एक टाइमस्टैम्प होता है: इस तरह आप केवल विफलता ही नहीं, बल्कि यह भी देखेंगे कि वह
**कितने सेकंड** चली — और यही वह संख्या है जिसके पीछे यह पूरी लैब है।

⚠️ **आपको एक दूसरा टर्मिनल चाहिए, न कि पृष्ठभूमि में चलाना।** इस अभ्यास का मकसद यह है कि विफलता को
**ठीक उसी क्षण** देखें जब आप दूसरी विंडो में कॉपी हटाते हैं: क्रॉस वाली पंक्ति आपकी आँखों के सामने
प्रकट होनी चाहिए। इसे बाद में `kubectl logs` में पढ़ा जा सकता है, लेकिन तब मुख्य बात खो जाती है —
आपके कार्य और उसके परिणाम के बीच की कड़ी।

क्लस्टर के भीतर से क्यों, न कि bastion से: `port-forward` किसी एक विशिष्ट Pod से चिपक जाता है और
उसी के साथ मर जाता है, इसलिए वह किसी भी हाल में विफलता दिखाएगा — वहाँ भी जहाँ कोई नहीं है। जबकि
किसी पड़ोसी Pod से `wget` Service के ज़रिए जाता है, यानी ठीक उसी तरह जैसे कोई असली क्लाइंट जाता।

रुकिए जब तक बिंदु दौड़ने न लगें।

📍 **विंडो 2** — कॉपी को मारें:

```bash
export KUBECONFIG=~/lab.kubeconfig

# No pod name is given, a label instead: delete every copy with the label app=rickroll.
# Right now there's only one, so the one the pinger is polling is exactly the one that goes.
kubectl delete pod -l app=rickroll
```

📍 **विंडो 1 को देखें।** आपको कुछ ऐसा दिखेगा:

```
.........XXXXX.........
```

कुछ सेकंड तक सेवा एक त्रुटि के साथ जवाब देती रही — हमें पाँच मिले, व्यस्त नोड पर पंद्रह भी हो सकते
हैं। कॉपी जल्दी वापस आ गई, लेकिन जब तक वह गायब थी, जवाब देने वाला कोई नहीं था।

**हमने जो देखा उसे ईमानदारी से यों कहा जा सकता है।** स्व-उपचार दोष-सहिष्णुता नहीं है। स्व-उपचार
सिस्टम को बिना किसी इंसान के सामान्य स्थिति में लौटाता है। दोष-सहिष्णुता का मतलब है कि क्लाइंट ने
कुछ भी नहीं देखा। एक कॉपी आपको पहला देती है, दूसरा नहीं।

pinger को मत रोकिए, यह अभी तुरंत काम आएगा।

## स्टेप 4. वही करें, पर तीन कॉपियों के साथ

📍 **विंडो 2.** हम एक के बजाय तीन कॉपियाँ आदेशित करते हैं और तब तक रुकते हैं जब तक तीनों तैयार न हो जाएँ।

```bash
# scale changes exactly one field in the application's record — the number of copies.
kubectl scale deployment rickroll --replicas=3

# rollout status holds the terminal and prints progress until all the copies you asked for
# are ready. The command finishes on its own — no need to poll get pods by hand.
kubectl rollout status deployment/rickroll
```

हमने वांछित अवस्था में ठीक एक संख्या बदली। आगे सब कुछ वही ReplicaSet करता है: वह «आदेशित 3,
मौजूद 1» देखता है और दो गायब कॉपियाँ बना देता है। इसमें पहले जितने ही सेकंड लगते हैं।

पक्का करें कि अब तीन कॉपियाँ हैं और वे सब Service के पीछे पहुँच गईं:

```bash
# EndpointSlice — that very list of live addresses the Service keeps for you.
#   -l kubernetes.io/service-name=rickroll   take the list belonging to the Service rickroll
#   -o jsonpath=...                          from each entry print only the address itself,
#                                            one per line
kubectl get endpointslices -l kubernetes.io/service-name=rickroll \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

तीन पते। इन्हें वहाँ किसी ने दर्ज नहीं किया — Service ने सूची खुद जुटाई, `app=rickroll` लेबल और
हर कॉपी की तैयारी से। यही वह अंतर है लोड-बैलेंसर पूल से, जिसकी बात लैब 1 में हुई थी: वहाँ आप पते
दर्ज करते हैं, यहाँ आप एक शर्त वर्णित करते हैं।

अब हम तीन में से एक कॉपी को मारते हैं:

```bash
# We take the name of the first of the three copies — which one exactly doesn't matter.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')

# And delete it. No --wait=false here: the command returns once the Pod is already gone.
kubectl delete pod "$POD"
```

📍 **विंडो 1 को देखें:**

```
...........................
```

एक भी `X` नहीं। कॉपी मारी गई, वह दोबारा बनी, क्लाइंट ने नहीं देखा।

एक-कॉपी परीक्षण और तीन-कॉपी परीक्षण के बीच अंतर मैनिफ़ेस्ट में एक ही संख्या है। **यहाँ
दोष-सहिष्णुता कोई ऐसी सुविधा नहीं जिसे आप चालू करते हैं — यह इस बात का परिणाम है कि कॉपियाँ एक से
ज़्यादा हैं।** ठीक इसीलिए Kubernetes में «HA चालू करो» वाला कोई चेकबॉक्स नहीं है: चालू करने को कुछ
है ही नहीं, बस `replicas` है।

विंडो 1 में `Ctrl+C` दबाकर pinger को रोकें। अगर Pod लटका रह जाए, तो उसे हटा दें:
`kubectl delete pod pinger`।

## स्टेप 5. एक परीक्षण जो पास नहीं होगा

तंत्र स्पष्ट है: एक कॉपी हटाओ, वह वापस आ जाती है। चलिए इसे एक बार और परखते हैं, पर इस बार कॉपी नहीं
बल्कि खुद एप्लिकेशन को हटाते हैं:

```bash
# We delete not a copy but the application's record itself. There will be no confirmation,
# the object won't go to any recycle bin — there'll be nowhere to restore it from but the file.
kubectl delete deployment rickroll
```

हम कुछ सेकंड रुकते हैं और देखते हैं कि क्या कॉपियाँ वापस आईं:

```bash
# We look for pods by the application's label. An empty response here is an answer too.
kubectl get pods -l app=rickroll
```

**आपको यह दिखेगा:**

```
No resources found in default namespace.
```

कॉपियाँ वापस नहीं आईं। न पाँच सेकंड बाद, न एक मिनट बाद।

> **आगे पढ़ने से पहले रुकें और सोचें।**
>
> पहले, जब आपने कॉपी को मारा था, वह दोबारा क्यों प्रकट हुई, पर अब नहीं? हमने तो कुछ भी बंद नहीं किया।

<details>
<summary><b>उत्तर, और इस त्रुटि से कहीं व्यापक एक सबक</b></summary>

पहले आप एक **कॉपी** हटा रहे थे — यानी एक तथ्य। «तीन कॉपियाँ होनी चाहिए» वाला रिकॉर्ड अपनी जगह बना
रहा, वास्तविकता उससे अलग हुई, और कंट्रोलर ने इस विचलन को मिटा दिया।

इस बार आपने **खुद रिकॉर्ड** हटा दिया। अब अलग होने के लिए कुछ बचा ही नहीं: वांछित अवस्था है «यह
एप्लिकेशन मौजूद नहीं है», वास्तविक अवस्था है «यह एप्लिकेशन मौजूद नहीं है»। वे मेल खाते हैं, और
कंट्रोलर के पास करने को कुछ नहीं। साथ ही, `ownerReferences` शृंखला का अनुसरण करते हुए, ReplicaSet
और तीनों Pods Deployment के साथ ही चले गए।

**इस त्रुटि से कहीं व्यापक एक सबक।** पूरी लैब से साथ ले जाने लायक नियम:

> Kubernetes आपको किसी **तथ्य** के खोने से बचाता है, पर **इरादे** के खोने से बचाने के लिए कुछ नहीं करता।

सारा स्व-उपचार ठीक तब तक काम करता है जब तक यह रिकॉर्ड सलामत है कि चीज़ें कैसी होनी चाहिए। अगर
रिकॉर्ड बदल दिया या हटा दिया जाए, तो क्लस्टर लगन से और बहुत तेज़ी से वास्तविकता को नई वांछित अवस्था
के अनुरूप ला देगा, चाहे वह कैसी भी हो। वह «क्या आप पक्का हैं?» नहीं पूछेगा और कोई रीसायकल बिन नहीं छोड़ेगा।

दो व्यावहारिक परिणाम हैं, और दोनों ठीक एक बार अप्रिय होते हैं।

**पहला: यहाँ हटाना vSphere की तुलना में ज़्यादा चुपचाप होता है।** किसी Deployment को गिराना एक ही
पंक्ति है — कोई पुष्टि नहीं, लाल आइकन वाला कोई «Delete from Disk?» नहीं। आप इसे क्लस्टर से बहाल
नहीं कर सकते: हटाया गया ऑब्जेक्ट कहीं संग्रहित नहीं होता।

**दूसरा: एकमात्र असली सुरक्षा है इरादे को क्लस्टर के बाहर रखना।** अगर मैनिफ़ेस्ट Git में रहता है और
उसे क्लस्टर में स्वचालन लाता है, तो आकस्मिक हटाव का इलाज यह है कि स्वचालन एक मिनट बाद ऑब्जेक्ट को
रिपॉज़िटरी से वापस ले आता है। यही GitOps है, और हम इसे लैब 5 में चालू करेंगे। फ़िलहाल, आपका
`rickroll.yaml` इरादे की एकमात्र कॉपी है। अच्छा है कि यह एक फ़ाइल में है: आप इसकी समीक्षा कर सकते
हैं, इसे Git में डाल सकते हैं, और इसे दोबारा लागू कर सकते हैं।

वैसे, बीच की कड़ी को अलग से परखना ठीक रहता है और वह अलग तरह से व्यवहार करती है। एप्लिकेशन बहाल करें
(अगला स्टेप), फिर Deployment के बजाय ReplicaSet हटाकर देखें:

```bash
# rs — short for replicaset; kubectl understands both spellings.
# We delete the middle link, leaving the Deployment in place.
kubectl delete rs -l app=rickroll

# And immediately look at what's left: compare the set's name with what it was before the delete.
kubectl get rs -l app=rickroll
```

सेट एक सेकंड के भीतर फिर प्रकट होता है — और **उसी नाम के साथ**। नाम में हैश Pod टेम्पलेट से गणना
होता है, और टेम्पलेट को हमने छुआ नहीं: वही नाम इसका मतलब है कि क्लस्टर ने ठीक वही चीज़ बहाल की, न
कि कुछ नया बनाया। «यह एप्लिकेशन होना चाहिए» वाला रिकॉर्ड सलामत रहा — इसके लिए Deployment ज़िम्मेदार
है, और वह सेट के हटाए जाने के बाद भी बचा रहा।

</details>

## स्टेप 6. एप्लिकेशन को वापस लाएँ

इरादा आपके पास है, वह एक फ़ाइल में है। इसे बहाल करना एक ही कमांड है:

```bash
# apply = "bring the cluster to what's described in the file". The object doesn't exist — it will be created.
#   -f ../01-deploy/rickroll.yaml   the file lives in the lab 1 folder, hence the path via ../
kubectl apply -f ../01-deploy/rickroll.yaml

# We wait for the copy to come up and become ready to take requests.
kubectl rollout status deployment/rickroll
```

ध्यान दें कि यहाँ क्या **नहीं** था: कोई बैकअप नहीं, कोई स्नैपशॉट नहीं, vCenter से कोई निर्यात नहीं।
आपने एप्लिकेशन को दस किलोबाइट की एक टेक्स्ट फ़ाइल से बहाल किया, और जो मिला वह हूबहू वही था जो पहले
था। किसी वर्चुअल मशीन के साथ यह करतब नहीं चलता: उसका विवरण और उसकी सामग्री अविभाज्य हैं।

## सत्यापन

📍 **कहाँ:** bastion पर, उसी टर्मिनल विंडो में जहाँ आप `kubectl` के साथ काम कर रहे थे।

स्क्रिप्ट यह नहीं जाँचती कि आपने कमांड चलाईं, बल्कि यह कि क्लस्टर में क्या बचा है: एप्लिकेशन फिर से
Service के ज़रिए अनुरोध परोस रहा है, वह पृष्ठ में अपनी कॉपी का नाम डालता है, और वह नाम किसी सचमुच
चल रहे Pod का है। अलग से यह कॉपियों के दोबारा बनने के निशान ढूँढती है — Pods की उम्र से और क्लस्टर
की घटनाओं से।

⚠️ **Windows पर स्क्रिप्ट WSL से चलती है**, PowerShell से नहीं — इसे कैसे इंस्टॉल करें यह लैब 0 की
शुरुआत में लिखा है। WSL के बिना भी लैब पूरी की जा सकती है, पर कोई आर्टफ़ैक्ट-रिपोर्ट नहीं बनेगी।

```bash
# ./ means "a file from the current folder", not a command from the system PATH.
# The script changes nothing in the cluster: it only reads and prints a report.
./check.sh
```

## सफ़ाई

`rickroll` एप्लिकेशन लैब 3 और 4 में चाहिए — हम इसे नहीं हटाते।

यहाँ सफ़ाई के लिए कुछ नहीं है, और यह अपने-आप में ध्यान देने लायक है। आपने एप्लिकेशन को फ़ाइल से बहाल
किया, और फ़ाइल एक कॉपी आदेशित करती है — बाकी दो को क्लस्टर ने खुद बंद कर दिया, पिछले ही स्टेप पर,
बिना पूछे और बिना आपकी कमांड का इंतज़ार किए। पुष्टि के लिए:

```bash
# The READY column should read 1/1.
kubectl get deployment rickroll
```

नोड के संसाधन उसी क्षण मुक्त हो गए जब कंटेनर समाप्त हुए। यहाँ न कोई «डीफ़्रैग्मेंटेशन» है, न
समय-सारणी के अनुसार जगह की वापसी: एक कंटेनर समाप्त हुआ — उसकी मेमोरी और CPU समय तुरंत उसके पड़ोसियों
को उपलब्ध हो जाते हैं।

## अब हम क्या कर सकते हैं

- Deployment → ReplicaSet → Pod शृंखला समझाना और समझना कि इसमें तीन तल क्यों हैं
- स्व-उपचार (कॉपी वापस आई) को दोष-सहिष्णुता (क्लाइंट ने नहीं देखा) से अलग पहचानना
- कॉपियों की संख्या एक ही संख्या से बदलना और देखना कि Service उन्हें खुद कैसे उठा लेता है
- समझना कि क्लस्टर किसी तथ्य की रक्षा करता है पर इरादे की नहीं, और इरादे की जगह कहाँ है

## और vSphere में यह ऐसा होता

vSphere HA किसी होस्ट की विफलता के बाद एक VM को पुनः शुरू करता है: पहले क्लस्टर को पक्का करना होता
है कि होस्ट सचमुच खो चुका है (यह दसियों सेकंड है), फिर मशीन शून्य से बूट होती है — कर्नेल, सेवाएँ,
एप्लिकेशन। मिनटों में। खोई हुई heartbeat पर आधारित VM Monitoring भी उसी तरह और उसी समय-पैमाने पर
काम करती है।

यहाँ यह सेकंड में है, और केवल किसी होस्ट की विफलता पर नहीं: वही तंत्र तब चलता है जब कोई कॉपी बेदखल
की जाती है, जब OOM उसे मार देता है, जब आप उसे खुद हटाते हैं।

**कहाँ vSphere ज़्यादा सुविधाजनक है, ईमानदारी से।** तीन बातें।

पहला, vSphere HA **ठीक वही मशीन** वापस लाता है, उस सब के साथ जो उसकी डिस्क पर था। एक Pod खाली वापस
आता है: जो कुछ भी किसी स्थायी वॉल्यूम पर नहीं था वह हमेशा के लिए खो जाता है। किसी स्थिति-रहित
(stateless) एप्लिकेशन के लिए यह एक फ़ायदा है; किसी legacy सेवा के लिए जो सालों तक अपने ही `/var` में
कुछ लिखती रही, यह बहुत बुरे आश्चर्यों का स्रोत है।

दूसरा, vSphere में Fault Tolerance है: दो मशीनें lock-step में और किसी होस्ट की विफलता पर शून्य
डाउनटाइम, बिना एप्लिकेशन में कोई फेरबदल किए। Kubernetes में इसका सीधा समकक्ष नहीं है, और हो भी नहीं
सकता — यहाँ शून्य डाउनटाइम इस बात से हासिल होता है कि कई कॉपियाँ हों, यानी एप्लिकेशन को कई कॉपियों
में चलने में सक्षम होना चाहिए। अगर वह नहीं कर सकता, तो Kubernetes आपके लिए यह समस्या हल नहीं करेगा —
वह इसे उजागर कर देगा।

तीसरा, पोस्ट-मॉर्टम। vCenter में किसी मशीन के पुनः शुरू होने का कारण क्लस्टर की घटनाओं में एक ही
प्रविष्टि के रूप में दिखता है, और वह वहीं बना रहता है। Kubernetes में घटनाएँ करीब एक घंटे तक जीती हैं
और फिर गायब हो जाती हैं, और आपको तस्वीर को कई घटकों के लॉग से दोबारा जोड़ना पड़ेगा। जब तक आपने लॉग और
घटनाओं का संग्रह स्थापित नहीं किया (लैब 14), «यह रात को क्यों पुनः शुरू हुआ» एक ऐसा सवाल है जिसका कोई
जवाब नहीं।
