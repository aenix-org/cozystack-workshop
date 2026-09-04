#!/usr/bin/env bash
# लैब 2 की जाँच: स्व-उपचार।
#
# हम "कमांड टाइप की गईं" की नहीं, बल्कि लैब के बाद क्लस्टर की स्थिति की जाँच करते हैं: ऐप फिर से
# Service के ज़रिये अनुरोधों की सेवा देता है, अपनी कॉपी का नाम लौटाता है, और वह नाम एक
# वास्तव में चल रहे पॉड का है। साथ ही हम इस बात के निशान ढूँढते हैं कि कॉपियाँ फिर से बनाई गई थीं।
#
# स्क्रिप्ट कुछ भी नहीं हटाती और नहीं बनाती, सिवाय एक बार-उपयोग वाले पॉड के, जो क्लस्टर के अंदर से
# सेवा की उपलब्धता जाँचता है — वह खुद को हटा देता है।

LAB_NAME="02-selfheal"
LAB_TITLE="लैब 2 · पॉड को मारें और देखें कि क्या होता है"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# kubectl का RFC3339 (हमेशा UTC, Z के साथ) यूनिक्स सेकंड में। python3 के ज़रिये, क्योंकि
# macOS पर BSD date और Linux पर GNU date तारीखों को अलग-अलग पार्स करते हैं, जबकि python हर जगह मौजूद है,
# जहाँ lib.sh चलता है।
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- क्या ऐप बिल्कुल मौजूद है ------------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "ऐप ${APP} क्लस्टर में नहीं है" \
       "लैब के अंत में इसे वापस लाना था: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "namespace में क्या है" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "ऐप ${APP} बहाल हो गया: ${WANT} में से ${HAVE} कॉपियाँ तैयार"
else
  fail "${WANT} अनुरोधित में से ${HAVE} कॉपियाँ तैयार" \
       "देखें kubectl describe deployment ${APP} और kubectl get pods -l app=${APP}"
fi
evidence "ऐप की स्थिति" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- शृंखला Deployment -> ReplicaSet -> Pod -------------------------------
# लैब का मतलब यह है कि कॉपी को ReplicaSet वापस लाता है, न कि "सामान्य रूप से क्लस्टर"।
# अगर पॉड का मालिक ReplicaSet नहीं निकला, तो प्रतिभागी ने पॉड हाथ से खड़ा किया है,
# और उसे स्व-उपचार नहीं दिखेगा।
# हम पॉड को नाम से गिनते हैं, न कि मालिकों के अद्वितीय प्रकार इकट्ठा करते हैं: बिना
# ownerReferences वाले पॉड के लिए jsonpath खाली स्ट्रिंग लौटाता है, `sort -u` उसे एक अदृश्य
# तत्व में समेट देता है, और `*ReplicaSet*` तब तक मैच करता है जब तक कम-से-कम एक पॉड ReplicaSet द्वारा प्रबंधित है।
# इसी वजह से हाथ से खड़ा किया गया बाहरी पॉड जाँच को बिना पकड़े पार कर जाता था।
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "app=${APP} लेबल वाला एक भी पॉड नहीं है" \
         "ऐप वापस लाएँ: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "कोई भी ${APP} पॉड ReplicaSet द्वारा प्रबंधित नहीं है — स्व-उपचार नहीं होगा" \
         "लगता है पॉड हाथ से खड़ा किया गया (kubectl run)। उसे हटाएँ और ../01-deploy/rickroll.yaml लागू करें"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "app=${APP} लेबल बाहरी पॉड पहने हुए हैं: ${PODS_TOTAL} में से ${PODS_BY_RS} ReplicaSet द्वारा प्रबंधित हैं" \
           "बाकी बैलेंसिंग में आ जाएँगे और किसी और का उत्तर देंगे — उन्हें ढूँढें: kubectl get pods -l app=${APP} -o wide"
      evidence "पॉड के मालिक" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "कॉपियों को ReplicaSet प्रबंधित करता है — शृंखला Deployment → ReplicaSet → Pod अखंड है"
    evidence "कौन किसका मालिक" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- कॉपियों के फिर से बनने के निशान ----------------------------------------
# क्लस्टर "पॉड मारा गया था" का सीधा सबूत नहीं रखता। दो अप्रत्यक्ष हैं, और दोनों पर्याप्त हैं:
# पॉड अपने Deployment से काफ़ी छोटा है, और ReplicaSet की घटनाओं में एक से ज़्यादा निर्माण दिखते हैं।
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "कॉपी ऐप से ${DELTA} सेकंड छोटी है — मतलब पुरानी को हटाया गया और इसे बदले में बनाया गया"
  else
    warn "कॉपी ऐप की लगभग हमउम्र है (अंतर ${DELTA} सेकंड)" \
         "अगर आपने पूरे ऐप को बिल्कुल अंत में बहाल किया — यह सामान्य है; वरना पॉड हटाने का चरण नहीं किया गया"
  fi
  evidence "ऑब्जेक्ट की उम्र" "deployment बना: ${DEP_TS}
pod बना:        ${POD_TS}
अंतर:           ${DELTA} सेकंड"
else
  warn "पॉड और ऐप की उम्र की तुलना नहीं कर सके" \
       "PATH में python3 चाहिए; लैब पास करने पर इसका असर नहीं पड़ता"
fi

# घटनाएँ लगभग एक घंटे रहती हैं, इसलिए उनकी अनुपस्थिति विफलता नहीं, बल्कि एक टिप्पणी है।
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "क्लस्टर की घटनाओं में ${CREATES} कॉपी-निर्माण — स्व-उपचार सचमुच सक्रिय हुआ था"
  evidence "कॉपी-निर्माण की घटनाएँ" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "क्लस्टर की घटनाओं में कॉपी-निर्माण केवल ${CREATES} बार दिखता है" \
       "घटनाएँ लगभग एक घंटे रखी जाती हैं और समाप्त हो सकती थीं"
fi

# दोनों में से कोई भी एक संकेत अकेले अवरोधक नहीं है: घटनाएँ लगभग एक घंटे रहती हैं,
# और उम्र उसी के लिए मेल खाती है जिसने लैब के अंत में पूरे ऐप को वैध रूप से बहाल किया।
# लेकिन अगर एक भी पूरा नहीं हुआ — कॉपी कभी हटाई ही नहीं गई, और लैब नहीं हुई। इस
# संयोजन के बिना स्क्रिप्ट लैब 1 के तुरंत बाद "लैब पास" छाप देती थी, एक भी हटाने का इंतज़ार किए बिना।
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "स्व-उपचार के निशान नहीं मिले: कॉपी नहीं हटाई गई" \
       "कॉपी हटाएँ: kubectl delete pod -l app=${APP} — और एक घंटे के भीतर जाँच चलाएँ, जब तक घटनाएँ जीवित हैं"
fi

# --- सर्विस वास्तव में सेवा देती है --------------------------------------------
# मुख्य ठोस जाँच: "ऑब्जेक्ट मौजूद है" नहीं, बल्कि "Service के ज़रिये एक पेज आता है
# और उसमें एक जीवित कॉपी का नाम है"।
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} ने क्लस्टर के अंदर से पेज नहीं लौटाया" \
       "एंडपॉइंट जाँचें: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "पेज दिया जा रहा है, पर कॉपी का नाम उसमें प्रतिस्थापित नहीं हुआ" \
       "ConfigMap rickroll-conf खो गया: ../01-deploy/rickroll.yaml पूरा लागू करें"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "Service के उत्तर में कॉपी का नाम नहीं है" \
         "पेज हमारे ऐप से नहीं आया — जाँचें kubectl get svc ${APP} -o yaml"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service पेज देता है, उसे जीवित कॉपी ${SERVED} ने परोसा"
    evidence "Service का उत्तर (अंश)" \
      "$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "पेज कॉपी ${SERVED} ने दिया, पर ऐसा पॉड क्लस्टर में अब नहीं है" \
         "दस-एक सेकंड रुकें और जाँच फिर चलाएँ — शायद कॉपी अभी ठीक बदल रही थी"
  fi
fi

# --- अगली लैब के लिए तैयारी -------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "कॉपियों की संख्या एक पर वापस लाई गई — लैब 3 साफ़ शुरुआत से शुरू होगी"
else
  warn "अभी अनुरोधित कॉपियाँ: ${WANT}" \
       "लैब 3 से पहले एक पर लाएँ: kubectl scale deployment ${APP} --replicas=1"
fi

finish
