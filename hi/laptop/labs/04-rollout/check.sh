#!/usr/bin/env bash
# लैब 4 की जाँच: नए संस्करण की रोलआउट और रोलबैक।
#
# हम टाइप किए गए कमांड नहीं, बल्कि सार की जाँच करते हैं:
#   - ऐप के इतिहास में कई रिवीज़न हैं, यानी संस्करण वाकई बदला गया था;
#   - दूसरे संस्करण का ConfigMap क्लस्टर में एक अलग ऑब्जेक्ट के रूप में मौजूद है, पहले वाले की एडिट नहीं;
#   - कंटेनर में readinessProbe है — इसके बिना ज़ीरो डाउनटाइम पुनरुत्पादनीय नहीं है;
#   - रोलआउट पूरी तरह हो चुका है, अटका नहीं है;
#   - Service द्वारा परोसा गया पेज उस ConfigMap से मेल खाता है जिसका उल्लेख
#     स्पेक में है। यह उस स्थिति को पकड़ता है «स्पेक रोलबैक हो गया, पर पॉड्स दोबारा नहीं बने»।
#
# स्क्रिप्ट कुछ भी नहीं बदलती। एक-बार का पॉड सिर्फ़ इसलिए चाहिए ताकि क्लस्टर के अंदर से
# पेज ले सके, और वह ख़ुद को हटा देता है।
#
# लैपटॉप पर चलता है, इसी लैब के फ़ोल्डर से, प्रशिक्षण क्लस्टर `lab` तक पहुँच के साथ
# (प्रबंधन क्लस्टर के टेनेंट तक नहीं):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# यहाँ COZY_TENANT वेरिएबल की ज़रूरत नहीं: पूरी लैब `lab` क्लस्टर के अंदर चलती है।
#
# सफ़ाई से पहले और रोलबैक पूरा होने के बाद चलाएँ: रिवीज़न इतिहास Deployment के
# साथ रहता है, और उसी के साथ ग़ायब हो जाता है।

# ये रिपोर्ट के शीर्षक में और स्क्रिप्ट के पास वाली फ़ाइल report-<लैब>-<तारीख>.md के नाम में जाते हैं।
LAB_NAME="04-rollout"
LAB_TITLE="लैब 4 · नए संस्करण की रोलआउट और रोलबैक"
# साझा लाइब्रेरी: ok / fail / warn / evidence / finish, क्लस्टर के अंदर से अनुरोध,
# रिपोर्ट लिखना। पथ स्क्रिप्ट के अपने स्थान से हल होता है, मौजूदा डायरेक्टरी से नहीं।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG के बिना kubectl लैपटॉप पर क्लस्टर ढूँढता है और सब कुछ एक ही त्रुटि से गिरा देता है
# जिसमें असली वजह दिखती नहीं। हम तुरंत रुक जाते हैं।
need_kubeconfig

APP=rickroll

# --- ऐप मौजूद है और कार्यशील स्थिति में लाया गया है ------------------
# ऐप न हो तो जाँचने को कुछ नहीं, इसलिए यही एकमात्र समय-पूर्व निकास है।
# आगे हम सिर्फ़ तैयार प्रतियों की संख्या नहीं देखते, बल्कि Progressing स्थिति में
# वजह भी देखते हैं: NewReplicaSetAvailable का अर्थ है कि रोलआउट पूरा हुआ। सिर्फ़
# तैयार प्रतियाँ पर्याप्त नहीं — अटके अपडेट में पुराना संस्करण चलता है, काउंटर
# अपेक्षित संख्या दिखाता है, जबकि नई प्रति एक बार भी नहीं उठी।
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "ऐप ${APP} क्लस्टर में नहीं है" \
       "इसे तैनात करें: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "रोलआउट पूरा हुआ: ${WANT} में से ${HAVE} प्रतियाँ तैयार"
else
  fail "ऐप पूर्ण स्थिति में नहीं है (${WANT} में से ${HAVE} तैयार, वजह: ${PROG_REASON:-कोई नहीं})" \
       "अगर रोलआउट अटका है — रोलबैक से उबरें: kubectl rollout undo deployment/${APP}"
fi
evidence "ऐप की स्थिति" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: वह जिससे ज़ीरो डाउनटाइम चुकाया जाता है -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "कंटेनर में readinessProbe है (${PROBE}) — प्रतियाँ तैयार होने के बाद ही बदली जाती हैं"
else
  fail "कंटेनर में readinessProbe नहीं है" \
       "इसके बिना क्लस्टर अ-तैयार प्रति पर ट्रैफ़िक भेजता है; ../01-deploy/rickroll.yaml लागू करें"
fi

# --- संस्करण अलग-अलग ऑब्जेक्ट के रूप में बनाए गए हैं --------------------------------------
# पेज के दोनों संस्करण क्लस्टर में दो अलग-अलग ConfigMap के रूप में मौजूद होने चाहिए।
# जिसने इसके बजाय rickroll-page-v1 को उसी जगह ठीक कर दिया, उसे स्क्रीन पर नया पेज
# दिखेगा और वह तय कर लेगा कि लैब हो गई — पर रोलबैक करने को कहीं जगह नहीं होगी,
# और न प्रति की अदला-बदली होगी, न रिवीज़न इतिहास में कोई प्रविष्टि।
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2 क्लस्टर में एक अलग ऑब्जेक्ट के रूप में मौजूद है"
else
  fail "क्लस्टर में ConfigMap rickroll-page-v2 नहीं है" \
       "इसे लागू करें: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "पेज का पहला संस्करण भी सहेजा गया है — रोलबैक करने को जगह है"
else
  warn "क्लस्टर में ConfigMap rickroll-page-v1 नहीं मिला" \
       "इसके बिना पहले संस्करण पर रोलबैक पॉड्स नहीं उठाएगा: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- रिवीज़न इतिहास -------------------------------------------------------
# हम इतिहास की पंक्तियों की संख्या नहीं, बल्कि अंतिम रिवीज़न का नंबर देखते हैं। रोलबैक
# नया ReplicaSet नहीं जोड़ता — वह पुराने को दोबारा इस्तेमाल कर उसका नंबर बढ़ाता है,
# इसलिए रोलबैक के बाद इतिहास में पंक्तियाँ उतनी ही रहती हैं, पर नंबर बढ़ जाता है।
#   1 — स्पेक कभी नहीं बदला गया
#   2 — संस्करण स्विच किया गया
#   3 और अधिक — स्विच किया और वापस लौटाया
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "ऐप का अंतिम रिवीज़न — ${REV_MAX}: संस्करण स्विच किया गया और वापस लौटाया गया"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "अंतिम रिवीज़न — 2: रोलआउट हो गया, रोलबैक अभी नहीं" \
       "पहला संस्करण बहाल करें: kubectl rollout undo deployment/${APP}"
else
  fail "अंतिम रिवीज़न — ${REV_MAX}: ऐप का स्पेक कभी नहीं बदला गया" \
       "लैब के पैच से वॉल्यूम को दूसरे संस्करण पर स्विच करें, फिर रोलबैक करें"
fi
evidence "रिवीज़न इतिहास" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- स्पेक किस संस्करण की ओर इशारा करता है --------------------------------------
# वॉल्यूम को हम नाम page से ढूँढते हैं, हालाँकि लैब का पैच उसे इंडेक्स से संबोधित करता है।
# फ़र्क़ यहीं पकड़ा जाता है: अगर पैच सूची के ग़लत तत्व पर गया, तो page नाम पुराने ConfigMap
# की ओर इशारा करेगा या ग़ायब हो जाएगा, और प्रतिभागी को यह अजीब nginx त्रुटि के ज़रिए नहीं,
# बल्कि शब्दों में पता चलेगा।
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "ऐप का स्पेक पेज के पहले संस्करण पर वापस लौटा दिया गया है"
    ;;
  rickroll-page-v2)
    warn "ऐप का स्पेक पेज के दूसरे संस्करण की ओर इशारा करता है" \
         "लैब रोलबैक के साथ ख़त्म होती है; अगर ऐसा ही चाहा था — कोई बात नहीं, वरना: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "स्पेक में page नाम का कोई वॉल्यूम नहीं है" \
         "लगता है पैच ग़लत जगह गया (इंडेक्स से संबोधन!); ../01-deploy/rickroll.yaml दोबारा लागू करें"
    ;;
  *)
    fail "page वॉल्यूम ConfigMap ${VOL_CM} की ओर इशारा करता है, जिसे लैब ने नहीं बनाया" \
         "रोलबैक करें: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- क्लाइंट को वास्तव में क्या परोसा जाता है ------------------------------------
# सबसे सार्थक जाँच: हम स्पेक की तुलना उससे करते हैं जो उपयोगकर्ता देखता है।
# यहाँ बेमेल का अर्थ है कि पॉड्स नए स्पेक के लिए दोबारा नहीं बने।
# आठ अनुरोध, एक नहीं। Service के पीछे तीन प्रतियाँ हैं; अगर रोलआउट पूरी तरह नहीं जमा,
# तो एक अकेले अनुरोध के तीन में एक की संभावना से सही संस्करण पर पहुँचकर बेमेल छिपा देगा।
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP} ने क्लस्टर के अंदर से पेज नहीं लौटाया" \
       "एंडपॉइंट जाँचें: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # दोनों संस्करणों को हम सकारात्मक रूप से पहचानते हैं, हर एक को उसके अपने मार्कर से। शाखा «अगर v2 नहीं,
  # तो v1» किसी भी चीज़ को पहला संस्करण मान लेती थी: डिफ़ॉल्ट nginx पेज, 404, किसी और का ऐप,
  # कचरा — जाँचा गया, कचरे पर स्क्रिप्ट «लैब पास» दिखा देती थी।
  if printf '%s' "$BODY" | grep -q 'संस्करण 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "सेवा के पते पर ऐप के पेज के बजाय कुछ और परोसा जा रहा है" \
         "जवाब में कोई परिचित मार्कर नहीं — मूल बहाल करें: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "पेज के बजाय क्या लौटा" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "क्लाइंट को ठीक वही संस्करण परोसा जाता है जो स्पेक में दर्ज है (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "स्पेक ${VOL_CM} की ओर इशारा करता है, पर क्लाइंट को ${SERVED_VER} परोसा जाता है" \
         "प्रतियाँ नए स्पेक के लिए दोबारा नहीं बनीं: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "प्रति का नाम पेज में प्रतिस्थापित नहीं होता" \
         "ConfigMap rickroll-conf खो गया: पूरा ../01-deploy/rickroll.yaml लागू करें"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "पेज को जीवित प्रति ${SERVED_POD} ने परोसा"
    else
      warn "पेज के नाम को किसी चालू प्रति से मिलाया नहीं जा सका" \
           "शायद जाँच के दौरान ही प्रतियाँ बदल रही थीं — स्क्रिप्ट फिर से चलाएँ"
    fi
  fi

  evidence "परोसा गया पेज (अंश)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "सेवा प्रदान करने वाला Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- अगली लैब्स के लिए तैयारी ------------------------------------------
# लैब ने प्रतियाँ तीन तक बढ़ाई थीं ताकि अदला-बदली एक-एक करके दिखे। पीछे छोड़ी गई तीन
# प्रतियाँ कुछ नहीं तोड़तीं — इसलिए warn, fail नहीं — पर प्रशिक्षण नोड पर जगह घेरती हैं,
# जो आगे पड़ोसी लैब्स के लिए कम पड़ेगी।
if [ "$WANT" = "1" ]; then
  ok "प्रतियों की संख्या वापस एक कर दी गई है"
else
  warn "अभी अनुरोधित प्रतियाँ: ${WANT}" \
       "लैब के बाद एक पर लौटना उचित है: kubectl scale deployment ${APP} --replicas=1"
fi

finish
