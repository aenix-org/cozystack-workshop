#!/usr/bin/env bash
# लैब 6 की जाँच: एप्लिकेशन क्लस्टर में अपनी खुद की निजी रजिस्ट्री से आता है।
#
# हम «Harbor बन गया» नहीं, बल्कि पूरी श्रृंखला जाँचते हैं: रजिस्ट्री अपने API पर जवाब देती है,
# मैनिफ़ेस्ट में इमेज ठीक उसी में है, क्लस्टर के पास उसी पते के लिए क्रेडेंशियल हैं,
# और इस इमेज वाला pod सचमुच चलता है और जवाब देता है।
#
# दो क्लस्टर, और यही मुख्य कारण है कि यह स्क्रिप्ट अपने पड़ोसियों से ज़्यादा जटिल दिखती है:
# KUBECONFIG — आपका lab क्लस्टर, जहाँ एप्लिकेशन चलता है; COZY_KUBECONFIG —
# Cozystack प्रबंधन क्लस्टर, जहाँ आपके टेनेंट में managed-सेवा Harbor रहती है।
# इन्हें एक ही कमांड से नहीं पूछा जा सकता, इसलिए नीचे kubectl को बुलाने के दो अलग तरीके हैं।
#
# आपके द्वारा, लैब फ़ोल्डर से चलाया जाता है; कुछ नहीं बदलता, सिर्फ़ देखता है और रिपोर्ट छापता है:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/config
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="लैब 6 · अपनी निजी इमेज रजिस्ट्री"
# सभी लैब का साझा रैपर: ok / fail / warn / evidence / finish और एनवायरनमेंट जाँचें।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# क्लस्टर एक्सेस फ़ाइल और टेनेंट नंबर के बिना जाँचने को कुछ नहीं — तुरंत बाहर निकलते हैं।
need_kubeconfig
need_tenant

APP="passes-api"
# प्रबंधन क्लस्टर पर टेनेंट का नेमस्पेस: नाम प्रीफ़िक्स tenant- और आपके नंबर से बनता है,
# यानी tenant-workshopXX। नंबर एनवायरनमेंट से लिया जाता है,
# इसे स्क्रिप्ट के टेक्स्ट में हाथ से डालने की ज़रूरत नहीं।
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# kubectl को बुलाने के दो तरीके: kget आपके lab क्लस्टर में जाता है, cozy — प्रबंधन क्लस्टर में।
# त्रुटियाँ जानबूझकर दबाई जाती हैं: यहाँ किसी ऑब्जेक्ट का न होना विफलता नहीं बल्कि अपेक्षित
# परिणामों में से एक है, और इसे नीचे एक अलग शाखा में स्पष्ट सलाह के साथ संभाला जाता है।
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- प्रबंधन क्लस्टर पर managed-सेवा Harbor ---------------------------
# वैकल्पिक हिस्सा: टेनेंट kubeconfig के बिना भी लैब जाँची जा सकती है,
# पर प्लेटफ़ॉर्म की ओर से सेवा हमें नहीं दिखेगी।
#
# «कमांड नहीं चली» मामले को हम अलग से पकड़ते हैं: टेनेंट में रोल शायद एप्लिकेशन देखने की
# अनुमति न दे। यह प्रतिभागी की गलती नहीं और जाँच फेल करने का कारण नहीं, इसलिए
# यहाँ warn — «नहीं देखा», न कि fail — «गलत किया»। कमांड की त्रुटि और खाली
# जवाब को हम जानबूझकर अलग करते हैं: खाली सूची का मतलब Harbor बना ही नहीं।
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "टेनेंट kubeconfig ${COZY_KUBECONFIG} नहीं मिला — Harbor की स्थिति जाँची नहीं गई" \
       "पथ बताएँ: export COZY_KUBECONFIG=~/.kube/config"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "टेनेंट ${TENANT_NS} में Harbor एप्लिकेशन नहीं देखे जा सके" \
         "टेनेंट में रोल शायद यह कमांड न दे — यह लैब की गलती नहीं; बाकी सब नीचे जाँचा जाता है"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "टेनेंट ${TENANT_NS} में एक भी Harbor एप्लिकेशन नहीं है" \
         "इसे डैशबोर्ड में बनाएँ: एप्लिकेशन बनाएँ -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "managed-सेवा Harbor «${HARBOR_NAME}» तैयार है"
    else
      warn "Harbor «${HARBOR_NAME}» मौजूद है, पर तैयारी की सूचना नहीं देता" \
           "इसकी स्थिति डैशबोर्ड में देखें; Harbor को उठने में 5-10 मिनट लगते हैं, और टेनेंट में ऑब्जेक्ट स्टोरेज के बिना यह बिल्कुल नहीं उठेगा"
    fi
    evidence "टेनेंट में Harbor एप्लिकेशन" "$HARBOR_LIST"
    # क्रेडेंशियल वाला सीक्रेट हम पढ़ने की कोशिश नहीं करते: टेनेंट इस सीक्रेट को पढ़ सकता है
    # (प्लेटफ़ॉर्म हर एप्लिकेशन के क्रेडेंशियल के लिए अलग नियम बनाता है),
    # पर रिपोर्ट में पासवर्ड हमें वैसे भी नहीं चाहिए।
  fi
fi

# --- एप्लिकेशन इमेज कहाँ से लेता है ------------------------------------------
# लैब का मतलब — इमेज आपकी रजिस्ट्री से आई, इंटरनेट से नहीं। यह मैनिफ़ेस्ट में इमेज के
# नाम से जाँचा जाता है: नाम का स्लैश तक का पहला हिस्सा रजिस्ट्री का पता है।
# अगर उसमें न बिंदु है न कोलन, तो वहाँ पता है ही नहीं, और क्लस्टर चुपचाप
# इमेज के लिए Docker Hub चला जाता — यानी ठीक वहीं, जहाँ सुरक्षा टीम ने मना किया।
# HARBOR-HOST प्लेसहोल्डर और ज्ञात सार्वजनिक रजिस्ट्री को अलग शाखाओं में पकड़ते हैं:
# औपचारिक रूप से पता मौजूद है, पर लैब की शर्त पूरी नहीं, और हर मामले में सलाह अलग है।
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "lab क्लस्टर में ${APP} एप्लिकेशन नहीं है" \
       "passes.yaml लागू करें, उसमें अपने Harbor का पता डालकर"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # रजिस्ट्री के पते जैसा दिखता है
    *) REGISTRY="" ;;          # पता नहीं — यानी इमेज Docker Hub से खींची जाती है
  esac

  if [ -z "$REGISTRY" ]; then
    fail "इमेज ${IMAGE} सार्वजनिक रजिस्ट्री से खींची जाती है, आपकी से नहीं" \
         "इमेज के नाम का पहला हिस्सा आपके Harbor का पता होना चाहिए"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "मैनिफ़ेस्ट में प्लेसहोल्डर पता HARBOR-HOST रह गया है" \
         "अपने Harbor का पता डालें: sed -i 's|HARBOR-HOST|harbor.yourdomain|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "इमेज सार्वजनिक रजिस्ट्री ${REGISTRY} से खींची जाती है" \
         "सुरक्षा टीम ने निजी रजिस्ट्री माँगी — इमेज बनाकर अपने Harbor में पुश करें"
  else
    ok "एप्लिकेशन आपकी रजिस्ट्री से चलता है: ${REGISTRY}"
    evidence "एप्लिकेशन इमेज" "$IMAGE"
  fi
fi

# --- रजिस्ट्री सचमुच काम करती है ------------------------------------------
# मैनिफ़ेस्ट में पता सही लिखा हो सकता है, पर उस पर रजिस्ट्री न हो: Harbor
# तुरंत नहीं उठता, और डोमेन में टाइपो भी बिल्कुल वैसा ही दिखता है। इसलिए हम
# उसके API पर दस्तक देते हैं और «pong» जवाब का इंतज़ार करते हैं — यह पुष्टि करता है कि वहाँ Harbor ही है,
# कोई और साइट या लोड बैलेंसर का स्टब नहीं।
if [ -z "$REGISTRY" ]; then
  : # ऊपर पहले ही रिपोर्ट कर दी
elif ! command -v curl >/dev/null 2>&1; then
  warn "curl उपयोगिता नहीं है — रजिस्ट्री की उपलब्धता जाँची नहीं गई" \
       "https://${REGISTRY} को ब्राउज़र में खोलें, वहाँ Harbor इंटरफ़ेस होना चाहिए"
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
    fail "रजिस्ट्री https://${REGISTRY} /api/v2.0/ping अनुरोध का जवाब नहीं देती" \
         "पता और डैशबोर्ड में Harbor एप्लिकेशन की स्थिति जाँचें"
  fi
fi

# --- क्लस्टर के पास एक्सेस क्रेडेंशियल -------------------------------------------
# इतना ही काफ़ी नहीं कि सीक्रेट मैनिफ़ेस्ट में बताया गया हो — मायने यह रखता है कि उसमें ठीक उसी
# रजिस्ट्री के क्रेडेंशियल हों जिससे इमेज खींची जाती है। लैब की सबसे आम गलती
# सही दिखती है: सीक्रेट बना, मैनिफ़ेस्ट में नामित, पर उसके अंदर का पता ग़लत है
# (अतिरिक्त https://, पोर्ट, दूसरा होस्ट नाम), और kubelet उसे लागू नहीं करेगा।
# इसलिए हम सीक्रेट की सामग्री खोलकर पते मिलाते हैं, नाम नहीं।
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # एप्लिकेशन नहीं है, ऊपर रिपोर्ट कर दी
elif [ -z "$PULL_SECRETS" ]; then
  fail "${APP} मैनिफ़ेस्ट में एक भी imagePullSecret नहीं बताया गया" \
       "निजी रजिस्ट्री से इमेज क्रेडेंशियल के बिना डाउनलोड नहीं होगी: imagePullSecrets जोड़ें, passes.yaml देखें"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # हम कॉन्फ़िग को python से पार्स करते हैं: base64 -d macOS और Linux पर अलग-अलग व्यवहार करता है,
    # और पासवर्ड रिपोर्ट में छापना मना है — हम सिर्फ़ पतों की सूची लेते हैं।
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
    ok "क्लस्टर के पास ${REGISTRY} के लिए क्रेडेंशियल सीक्रेट ${SECRET_OK} में हैं (पासवर्ड: <छिपा हुआ>)"
  else
    fail "बताए गए किसी भी सीक्रेट (${PULL_SECRETS}) में ${REGISTRY:-आपकी रजिस्ट्री} के क्रेडेंशियल नहीं हैं" \
         "ऐसे बनाएँ: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-पता} --docker-username=admin --docker-password=..."
  fi
fi

# --- pods सचमुच शुरू हुए ----------------------------------------------
# हम ImagePullBackOff और ErrImagePull स्थितियों को अलग से संभालते हैं: यह ठीक वही विफलता है
# जो लैब जानबूझकर दिखाती है, और प्रतिभागी के लिए इसे देखते ही पहचानना ज़रूरी है, न कि
# सामान्य «pods काम नहीं करते» पाना। असली कारण हम साक्ष्य के रूप में छापते हैं —
# रजिस्ट्री विफलता और इमेज नाम में टाइपो में pod की स्थिति एक जैसी होती है।
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "एप्लिकेशन की चल रही प्रतियाँ: ${RUNNING}"
  evidence "एप्लिकेशन के pods" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "इमेज डाउनलोड नहीं हो रही: ${BADSTATE}" \
       "यह रजिस्ट्री एक्सेस से इनकार या इमेज नाम में टाइपो है; असली कारण kubectl describe pod -l app=passes-api दिखाएगा"
  evidence "विफलता का कारण" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "एप्लिकेशन की एक भी चल रही प्रति नहीं (स्थितियाँ: ${BADSTATE:-कोई pod नहीं})" \
       "kubectl describe pod -l app=passes-api देखें"
fi

# लैब की सबसे कठिन-निदान गलती के लिए अलग जाँच: इमेज ARM के लिए बनी,
# और क्लस्टर के नोड x86 पर हैं। सब सही दिखता है — इमेज बनी, रजिस्ट्री में गई,
# नोड पर डाउनलोड हुई — पर प्रोसेस शुरू नहीं होता। आसपास कुछ भी प्रोसेसर
# आर्किटेक्चर का संकेत नहीं देता, और एकमात्र सुराग pod के लॉग में है, इसलिए
# हम उन्हें अलग जाँच से देखते हैं और कारण सीधे बताते हैं।
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "इमेज किसी दूसरे प्रोसेसर आर्किटेक्चर के लिए बनी है" \
       "फ़्लैग के साथ दोबारा बनाएँ: docker build --platform linux/amd64 -t ${IMAGE} app/ और फिर से पुश करें"
fi

# --- एप्लिकेशन सारगर्भित जवाब देता है ----------------------------------------
# शुरू हुआ pod अभी काम करती सेवा का मतलब नहीं। हम क्लस्टर के अंदर जाकर, एप्लिकेशन को
# उसके आंतरिक नाम से अनुरोध करते हैं और जवाब से pod का नाम पढ़ते हैं। अगर यह सचमुच चल रहे
# pod से मिलता है — तो जवाब ठीक उसी एप्लिकेशन से आता है जिसे हमने तैनात किया, न कि
# किसी और से जिसने गलती से यह पता ले लिया। असमानता warn है, fail नहीं:
# दो अनुरोधों के बीच प्रति दोबारा बन सकती थी, और इसमें प्रतिभागी का दोष नहीं।
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "${APP} नाम का कोई Service नहीं है" \
       "यह passes.yaml में वर्णित है — पूरी फ़ाइल लागू करें, सिर्फ़ Deployment नहीं"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "सेवा ${APP} ने अपेक्षित JSON नहीं लौटाया" \
         "kubectl logs -l app=passes-api देखें और सुनिश्चित करें कि Service में पोर्ट एप्लिकेशन के पोर्ट से मेल खाता है"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "सेवा JSON में जवाब देती है, जवाब सचमुच चल रहे pod ${SERVED_POD} से आया"
    evidence "सेवा का जवाब" "$BODY"
  else
    warn "सेवा ने pod ${SERVED_POD} के नाम से जवाब दिया, जो चल रहे pods में नहीं है" \
         "संभवतः प्रति अनुरोधों के बीच दोबारा बनी — जाँच फिर से चलाएँ"
  fi
fi

finish
