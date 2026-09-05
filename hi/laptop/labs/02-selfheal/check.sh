#!/usr/bin/env bash
# लैब 2 की जाँच: स्व-उपचार (सेल्फ-हीलिंग)।
#
# हम यह नहीं जाँचते कि «कमांड टाइप की गईं», बल्कि लैब के बाद क्लस्टर की स्थिति: एप्लिकेशन फिर से
# Service के ज़रिए अनुरोधों की सेवा करता है, अपनी कॉपी का नाम लौटाता है, और यह नाम
# वास्तव में चल रहे पॉड का है। साथ ही हम इसके निशान ढूँढते हैं कि कॉपियाँ फिर से बनाई गई थीं।
#
# स्क्रिप्ट कुछ भी हटाती या बनाती नहीं, सिवाय एक बार के पॉड के जो क्लस्टर के अंदर से सेवा की
# उपलब्धता जाँचता है — वह खुद को हटा देता है।

LAB_NAME="02-selfheal"
LAB_TITLE="लैब 2 · एक पॉड को मारें और देखें क्या होता है"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# kubectl से RFC3339 (हमेशा Z के साथ UTC) को unix सेकंड में। python3 के ज़रिए, क्योंकि
# macOS पर BSD date और Linux पर GNU date तारीखों को अलग-अलग तरीके से पार्स करते हैं, और python हर जगह है,
# जहाँ lib.sh काम करता है।
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- एप्लिकेशन बिल्कुल मौजूद है ------------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "एप्लिकेशन ${APP} क्लस्टर में नहीं है" \
       "लैब के अंत में इसे वापस लाना था: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "namespace में क्या है" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "एप्लिकेशन ${APP} बहाल हो गया: ${WANT} में से ${HAVE} कॉपियाँ तैयार"
else
  fail "माँगी गई ${WANT} में से ${HAVE} कॉपियाँ तैयार" \
       "kubectl describe deployment ${APP} और kubectl get pods -l app=${APP} देखें"
fi
evidence "एप्लिकेशन की स्थिति" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- Deployment -> ReplicaSet -> Pod श्रृंखला -------------------------------
# लैब का मतलब यह है कि कॉपी को ReplicaSet वापस लाता है, न कि «क्लस्टर सामान्य रूप से»।
# अगर पॉड का मालिक ReplicaSet नहीं निकला, तो प्रतिभागी ने पॉड हाथ से उठाया,
# और उसे स्व-उपचार नहीं दिखेगा।
# हम पॉड्स को नाम से गिनते हैं, न कि मालिकों के अनूठे प्रकार इकट्ठा करते हैं: ownerReferences के बिना
# पॉड के लिए jsonpath खाली स्ट्रिंग लौटाता है, `sort -u` उसे एक अदृश्य तत्व में समेट देता है,
# और `*ReplicaSet*` तब तक मैच करता है जब तक कम से कम एक पॉड ReplicaSet द्वारा प्रबंधित है।
# इसी वजह से हाथ से उठाया गया बाहरी पॉड जाँच में बिना पकड़े पास हो जाता था।
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "app=${APP} लेबल वाला कोई भी पॉड नहीं है" \
         "एप्लिकेशन वापस लाएँ: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "कोई भी ${APP} पॉड ReplicaSet द्वारा प्रबंधित नहीं है — स्व-उपचार नहीं होगा" \
         "लगता है पॉड हाथ से उठाया गया (kubectl run)। उसे हटाएँ और ../01-deploy/rickroll.yaml लागू करें"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "app=${APP} लेबल बाहरी पॉड्स ने धारण किया है: ${PODS_TOTAL} में से ${PODS_BY_RS} ReplicaSet द्वारा प्रबंधित हैं" \
           "बाकी बैलेंसिंग में आ जाएँगे और पराया जवाब देंगे — उन्हें ढूँढें: kubectl get pods -l app=${APP} -o wide"
      evidence "पॉड्स के मालिक" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "कॉपियों को ReplicaSet प्रबंधित करता है — Deployment → ReplicaSet → Pod श्रृंखला बरकरार है"
    evidence "कौन किसका मालिक" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- कॉपियों के फिर से बनने के निशान ----------------------------------------
# «पॉड को मारा गया» के सीधे सबूत क्लस्टर नहीं रखता। दो अप्रत्यक्ष हैं, और दोनों पर्याप्त हैं:
# पॉड अपने Deployment से काफ़ी नया है, और ReplicaSet की घटनाओं में एक से ज़्यादा निर्माण हैं।
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "कॉपी एप्लिकेशन से ${DELTA} सेकंड नई है — मतलब पिछली हटाई गई और इसे बदले में बनाया गया"
  else
    warn "कॉपी एप्लिकेशन की लगभग समवयस्क है (अंतर ${DELTA} सेकंड)" \
         "अगर आपने बिलकुल अंत में पूरा एप्लिकेशन बहाल किया — यह सामान्य है; वरना पॉड हटाने का चरण नहीं हुआ"
  fi
  evidence "ऑब्जेक्ट्स की उम्र" "deployment बना: ${DEP_TS}
pod बना:        ${POD_TS}
अंतर:           ${DELTA} सेकंड"
else
  warn "पॉड और एप्लिकेशन की उम्र की तुलना नहीं कर सके" \
       "PATH में python3 चाहिए; लैब पास करने पर इसका असर नहीं पड़ता"
fi

# घटनाएँ लगभग एक घंटा जीती हैं, इसलिए उनका न होना विफलता नहीं बल्कि टिप्पणी है।
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "क्लस्टर की घटनाओं में ${CREATES} बार कॉपी बनी — स्व-उपचार वाकई हुआ"
  evidence "कॉपी बनने की घटनाएँ" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "क्लस्टर की घटनाओं में कॉपी बनना केवल ${CREATES} बार दिखता है" \
       "घटनाएँ लगभग एक घंटा रखी जाती हैं और समाप्त हो सकती हैं"
fi

# दोनों में से कोई भी संकेत अकेले ब्लॉक नहीं करता: घटनाएँ लगभग एक घंटा जीती हैं,
# और उम्र उसी के लिए मेल खाती है जिसने लैब के अंत में जायज़ तौर पर पूरा एप्लिकेशन बहाल किया।
# लेकिन अगर एक भी नहीं टिकता — कॉपी को हटाया ही नहीं गया, और लैब पूरी नहीं हुई। इस
# जोड़ी के बिना स्क्रिप्ट लैब 1 के तुरंत बाद «लैब पास» छाप देती थी, बिना एक भी हटाने का इंतज़ार किए।
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "स्व-उपचार के कोई निशान नहीं मिले: कॉपी को हटाया नहीं गया" \
       "कॉपी हटाएँ: kubectl delete pod -l app=${APP} — और एक घंटे के भीतर जाँच चलाएँ, जब तक घटनाएँ जीवित हैं"
fi

# --- सेवा वाकई सेवा देती है --------------------------------------------
# मुख्य सारभूत जाँच: «ऑब्जेक्ट मौजूद है» नहीं, बल्कि «Service के ज़रिए एक पेज आता है
# और उसमें जीवित कॉपी का नाम है»।
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} ने क्लस्टर के अंदर से पेज नहीं लौटाया" \
       "एंडपॉइंट्स जाँचें: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "पेज दिया जा रहा है, लेकिन उसमें कॉपी का नाम नहीं भरा गया" \
       "ConfigMap rickroll-conf खो गया: ../01-deploy/rickroll.yaml को पूरा लागू करें"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "Service के जवाब में कॉपी का नाम नहीं है" \
         "पेज हमारे एप्लिकेशन से नहीं आया — kubectl get svc ${APP} -o yaml जाँचें"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service पेज देता है, उसे जीवित कॉपी ${SERVED} ने सेवा दी"
    evidence "Service का जवाब (अंश)" \
      "$(printf '%s' "$BODY" | grep -o "सेवा प्रदान करने वाला Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "पेज को कॉपी ${SERVED} ने दिया, लेकिन ऐसा पॉड क्लस्टर में अब नहीं है" \
         "दस सेकंड इंतज़ार करें और जाँच फिर चलाएँ — शायद कॉपी अभी ही बदल रही थी"
  fi
fi

# --- अगली लैब के लिए तैयारी -------------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "कॉपियों की संख्या एक पर वापस आ गई — लैब 3 साफ़ शुरुआत से शुरू होगी"
else
  warn "अभी माँगी गई कॉपियाँ: ${WANT}" \
       "लैब 3 से पहले एक वापस लाएँ: kubectl scale deployment ${APP} --replicas=1"
fi

finish
