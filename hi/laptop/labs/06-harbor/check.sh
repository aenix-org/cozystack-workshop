#!/usr/bin/env bash
# लैब 6 की जाँच: एप्लिकेशन क्लस्टर में अपने खुद के निजी रजिस्ट्री से डिप्लॉय होता है।
#
# हम "Harbor बन गया" यह नहीं जाँचते, बल्कि पूरी शृंखला जाँचते हैं: रजिस्ट्री अपने API पर जवाब देती है,
# मैनिफ़ेस्ट में मौजूद इमेज ठीक उसी में रहती है, क्लस्टर के पास उसी पते के लिए क्रेडेंशियल हैं,
# और इस इमेज वाला पॉड सचमुच चलता है और जवाब देता है।
#
# दो क्लस्टर, और यही मुख्य कारण है कि यह स्क्रिप्ट अपने पड़ोसियों से ज़्यादा जटिल दिखती है:
# KUBECONFIG आपका lab क्लस्टर है, जहाँ एप्लिकेशन चलता है; COZY_KUBECONFIG है
# Cozystack प्रबंधन क्लस्टर, जहाँ आपके टेनेंट में managed Harbor सेवा रहती है।
# दोनों को एक ही कमांड से क्वेरी नहीं किया जा सकता, इसलिए नीचे kubectl को कॉल करने के दो अलग तरीके हैं।
#
# आपके द्वारा, lab फ़ोल्डर से चलाया जाता है; यह कुछ नहीं बदलता, केवल देखता है और रिपोर्ट छापता है:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/workshop
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="लैब 6 · आपकी अपनी निजी इमेज रजिस्ट्री"
# सभी लैब की साझा संरचना: ok / fail / warn / evidence / finish और एनवायरनमेंट जाँच।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# क्लस्टर एक्सेस फ़ाइल के बिना और टेनेंट नंबर के बिना जाँचने के लिए कुछ नहीं है — तुरंत बाहर निकलें।
need_kubeconfig
need_tenant

APP="passes-api"
# प्रबंधन क्लस्टर पर टेनेंट नेमस्पेस: नाम उपसर्ग tenant- और आपके नंबर से बनता है,
# यानी tenant-workshopXX. नंबर एनवायरनमेंट से लिया जाता है,
# इसे स्क्रिप्ट के टेक्स्ट में हाथ से डालने की ज़रूरत नहीं।
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# kubectl को कॉल करने के दो तरीके: kget आपके lab क्लस्टर में जाता है, cozy — प्रबंधन क्लस्टर में।
# त्रुटियाँ जानबूझकर दबाई गई हैं: यहाँ किसी ऑब्जेक्ट का न होना विफलता नहीं बल्कि अपेक्षित
# परिणामों में से एक है, और इसे नीचे स्पष्ट सलाह के साथ एक अलग शाखा में संभाला जाता है।
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- प्रबंधन क्लस्टर पर managed Harbor सेवा ---------------------------
# वैकल्पिक भाग: टेनेंट kubeconfig के बिना भी लैब जाँचने योग्य है,
# लेकिन प्लेटफ़ॉर्म की ओर से सेवा हमें दिखाई नहीं देगी।
#
# हम "कमांड ने काम नहीं किया" वाले मामले को अलग से पकड़ते हैं: टेनेंट में भूमिका एप्लिकेशन
# देखने की अनुमति नहीं दे सकती। यह प्रतिभागी की गलती नहीं और जाँच विफल करने का कारण नहीं, इसलिए
# यहाँ warn — "नहीं देखा", न कि fail — "गलत किया"। हम जानबूझकर कमांड त्रुटि को
# खाली जवाब से अलग करते हैं: खाली सूची का मतलब है Harbor कभी बना ही नहीं।
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "टेनेंट kubeconfig ${COZY_KUBECONFIG} नहीं मिला — Harbor की स्थिति जाँची नहीं गई" \
       "पथ सेट करें: export COZY_KUBECONFIG=~/.kube/workshop"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "टेनेंट ${TENANT_NS} में Harbor एप्लिकेशन नहीं देख सके" \
         "टेनेंट में भूमिका शायद यह कमांड न दे — यह लैब की त्रुटि नहीं; बाकी सब नीचे जाँचा जाता है"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "टेनेंट ${TENANT_NS} में कोई Harbor एप्लिकेशन नहीं है" \
         "इसे डैशबोर्ड में बनाएँ: Create application -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "managed Harbor सेवा «${HARBOR_NAME}» तैयार है"
    else
      warn "Harbor «${HARBOR_NAME}» मौजूद है, लेकिन तैयारी की सूचना नहीं देता" \
           "इसकी स्थिति डैशबोर्ड में देखें; Harbor को ऊपर आने में 5-10 मिनट लगते हैं, और टेनेंट में ऑब्जेक्ट स्टोरेज के बिना यह बिल्कुल ऊपर नहीं आएगा"
    fi
    evidence "टेनेंट में Harbor एप्लिकेशन" "$HARBOR_LIST"
    # हम क्रेडेंशियल सीक्रेट पढ़ने की कोशिश नहीं करते: टेनेंट इस सीक्रेट को पढ़ सकता है,
    # लेकिन हमें रिपोर्ट में पासवर्ड की वैसे भी ज़रूरत नहीं।
  fi
fi

# --- एप्लिकेशन इमेज कहाँ से खींचता है ------------------------------------------
# लैब का मकसद यह है कि इमेज आपकी रजिस्ट्री से आई, इंटरनेट से नहीं। यह
# मैनिफ़ेस्ट में इमेज नाम से जाँचा जाता है: स्लैश तक नाम का पहला भाग रजिस्ट्री
# पता है। अगर उसमें न बिंदु है न कोलन, तो वहाँ पता है ही नहीं, और
# क्लस्टर चुपचाप इमेज के लिए Docker Hub जाएगा — ठीक वहीं जहाँ सुरक्षा ने मना किया।
# HARBOR-HOST प्लेसहोल्डर और ज्ञात सार्वजनिक रजिस्ट्रियों को हम अलग शाखाओं में पकड़ते हैं:
# औपचारिक रूप से पता मौजूद है, पर लैब की आवश्यकता पूरी नहीं, और हर मामले में सलाह अलग है।
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "lab क्लस्टर में ${APP} एप्लिकेशन नहीं है" \
       "passes.yaml लागू करें, उसमें अपना Harbor पता डालकर"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # रजिस्ट्री पते जैसा दिखता है
    *) REGISTRY="" ;;          # पता नहीं — यानी इमेज Docker Hub से खींची जाती है
  esac

  if [ -z "$REGISTRY" ]; then
    fail "इमेज ${IMAGE} सार्वजनिक रजिस्ट्री से खींची जाती है, आपकी से नहीं" \
         "इमेज नाम की शुरुआत आपके Harbor के पते से होनी चाहिए"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "मैनिफ़ेस्ट में अभी भी प्लेसहोल्डर पता HARBOR-HOST है" \
         "अपना Harbor पता डालें: sed -i 's|HARBOR-HOST|harbor.yourdomain|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "इमेज सार्वजनिक रजिस्ट्री ${REGISTRY} से खींची जाती है" \
         "सुरक्षा ने निजी रजिस्ट्री माँगी थी — इमेज बनाकर अपने Harbor में पुश करें"
  else
    ok "एप्लिकेशन आपकी रजिस्ट्री से शुरू होता है: ${REGISTRY}"
    evidence "एप्लिकेशन इमेज" "$IMAGE"
  fi
fi

# --- रजिस्ट्री सचमुच काम करती है ------------------------------------------
# मैनिफ़ेस्ट में पता सही लिखा हो सकता है, पर उस पर रजिस्ट्री न हो: Harbor
# तुरंत ऊपर नहीं आता, और डोमेन में टाइपो बिल्कुल वैसा ही दिखता है। इसलिए हम
# इसके API पर दस्तक देते हैं और "pong" जवाब का इंतज़ार करते हैं — यह पुष्टि करता है कि वहाँ Harbor है,
# न कि किसी और की साइट और न लोड बैलेंसर का स्टब।
if [ -z "$REGISTRY" ]; then
  : # ऊपर पहले ही रिपोर्ट कर दिया
elif ! command -v curl >/dev/null 2>&1; then
  warn "curl उपयोगिता नहीं है — रजिस्ट्री उपलब्धता जाँची नहीं गई" \
       "ब्राउज़र में https://${REGISTRY} खोलें, वहाँ Harbor इंटरफ़ेस होना चाहिए"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","अज्ञात"))' 2>/dev/null)"
    ok "रजिस्ट्री API पर जवाब देती है: https://${REGISTRY} (Harbor ${VER:-संस्करण अज्ञात})"
    evidence "रजिस्ट्री" "https://${REGISTRY}
API ping: ${PING}
Harbor संस्करण: ${VER:-अज्ञात}"
  else
    fail "रजिस्ट्री https://${REGISTRY} /api/v2.0/ping पर जवाब नहीं देती" \
         "पता और डैशबोर्ड में Harbor एप्लिकेशन की स्थिति जाँचें"
  fi
fi

# --- क्लस्टर के पास एक्सेस क्रेडेंशियल हैं -------------------------------------
# यह काफ़ी नहीं कि सीक्रेट मैनिफ़ेस्ट में संदर्भित है — मायने यह रखता है कि उसमें ठीक उसी
# रजिस्ट्री के क्रेडेंशियल हों जिससे इमेज खींची जाती है। सबसे आम लैब गलती सही दिखती है:
# सीक्रेट बना, मैनिफ़ेस्ट में नामित, पर उसके अंदर का पता गलत है
# (अतिरिक्त https://, एक पोर्ट, अलग होस्टनेम), और kubelet उसे लागू नहीं करेगा।
# इसलिए हम सीक्रेट की सामग्री खोलते हैं और नामों की नहीं, पतों की तुलना करते हैं।
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # कोई एप्लिकेशन नहीं, ऊपर रिपोर्ट किया
elif [ -z "$PULL_SECRETS" ]; then
  fail "मैनिफ़ेस्ट ${APP} में कोई imagePullSecret निर्दिष्ट नहीं है" \
       "निजी रजिस्ट्री से इमेज क्रेडेंशियल के बिना डाउनलोड नहीं होगी: imagePullSecrets जोड़ें, passes.yaml देखें"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # हम कॉन्फ़िग को python से पार्स करते हैं: base64 -d macOS और Linux पर अलग व्यवहार करता है,
    # और पासवर्ड रिपोर्ट में नहीं छापना चाहिए — हम केवल पतों की सूची लेते हैं।
    SERVERS="$(kget secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' \
      | python3 -c 'import sys,json,base64
raw = sys.stdin.read().strip()
try:
    cfg = json.loads(base64.b64decode(raw))
    print(" ".join(cfg.get("auths", {}).keys()))
except Exception:
    pass' 2>/dev/null)"
    if [ -n "$REGISTRY" ] && printf '%s' "$SERVERS" | grep -q "$REGISTRY"; then
      SECRET_OK="$s"
      break
    fi
  done

  if [ -n "$SECRET_OK" ]; then
    ok "क्लस्टर के पास सीक्रेट ${SECRET_OK} में ${REGISTRY} के क्रेडेंशियल हैं (पासवर्ड: <छिपा हुआ>)"
  else
    fail "निर्दिष्ट सीक्रेट्स (${PULL_SECRETS}) में से किसी में ${REGISTRY:-आपकी रजिस्ट्री} के क्रेडेंशियल नहीं हैं" \
         "इसे ऐसे बनाएँ: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-पता} --docker-username=admin --docker-password=..."
  fi
fi

# --- पॉड सचमुच शुरू हुए -----------------------------------------------
# हम ImagePullBackOff और ErrImagePull स्थितियों को अलग से संभालते हैं: यह ठीक वही विफलता
# है जो लैब जानबूझकर दिखाती है, और प्रतिभागी के लिए इसे देखकर पहचानना ज़रूरी है, बजाय
# एक सामान्य "पॉड काम नहीं कर रहे" पाने के। हम असली कारण को साक्ष्य के रूप में छापते हैं —
# रजिस्ट्री विफलता पर और इमेज नाम में टाइपो पर पॉड की स्थिति एक जैसी होती है।
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "एप्लिकेशन की चल रही प्रतियाँ: ${RUNNING}"
  evidence "एप्लिकेशन पॉड" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "इमेज डाउनलोड नहीं हो रही: ${BADSTATE}" \
       "यह रजिस्ट्री एक्सेस अस्वीकृति या इमेज नाम में टाइपो है; असली कारण kubectl describe pod -l app=passes-api दिखाएगा"
  evidence "विफलता का कारण" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "एप्लिकेशन की कोई चल रही प्रति नहीं है (स्थितियाँ: ${BADSTATE:-कोई पॉड नहीं})" \
       "kubectl describe pod -l app=passes-api देखें"
fi

# सबसे कठिन-निदान वाली लैब त्रुटि के लिए एक अलग जाँच: इमेज ARM के लिए बनी,
# जबकि क्लस्टर नोड्स x86 पर हैं। सब कुछ सही दिखता है — इमेज बनी, रजिस्ट्री में पुश हुई,
# नोड पर डाउनलोड हुई — पर प्रोसेस शुरू नहीं होता। आसपास कुछ भी प्रोसेसर आर्किटेक्चर
# का संकेत नहीं देता, और एकमात्र सुराग पॉड लॉग में है, इसलिए
# हम उन्हें एक अलग जाँच से देखते हैं और कारण सीधे बताते हैं।
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "इमेज किसी अन्य प्रोसेसर आर्किटेक्चर के लिए बनी है" \
       "इस फ़्लैग के साथ फिर से बनाएँ: docker build --platform linux/amd64 -t ${IMAGE} app/ और इसे फिर पुश करें"
fi

# --- एप्लिकेशन सार्थक रूप से जवाब देता है ----------------------------------
# चल रहा पॉड अभी काम करती सेवा नहीं है। हम क्लस्टर के अंदर जाते हैं, एप्लिकेशन को उसके
# आंतरिक नाम से अनुरोध करते हैं और जवाब से पॉड का नाम पढ़ते हैं। अगर यह सचमुच चल रहे
# पॉड से मेल खाता है — तो जवाब देने वाला ठीक वही एप्लिकेशन है जो हमने डिप्लॉय किया, न कि
# कुछ और जिसने गलती से यह पता ले लिया। मेल न होना warn है, fail नहीं:
# दो अनुरोधों के बीच कोई प्रति फिर से बन सकती थी, और यह प्रतिभागी की गलती नहीं।
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "${APP} नाम की कोई Service नहीं है" \
       "यह passes.yaml में वर्णित है — पूरी फ़ाइल लागू करें, केवल Deployment नहीं"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "सेवा ${APP} ने अपेक्षित JSON नहीं लौटाया" \
         "kubectl logs -l app=passes-api देखें और सुनिश्चित करें कि Service में पोर्ट एप्लिकेशन पोर्ट से मेल खाता है"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "सेवा JSON से जवाब देती है, जवाब सचमुच चल रहे पॉड ${SERVED_POD} से आया"
    evidence "सेवा का जवाब" "$BODY"
  else
    warn "सेवा ने पॉड ${SERVED_POD} की ओर से जवाब दिया, जो चल रहे पॉड्स में नहीं है" \
         "संभवतः प्रति अनुरोधों के बीच फिर से बनी — जाँच फिर से चलाएँ"
  fi
fi

finish
