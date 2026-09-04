#!/usr/bin/env bash
# लैब 7 की जाँच: कैश वाकई चीज़ों को तेज़ करता है, और यह आँकड़ों में दिखता है।
#
# यहाँ मुख्य जाँच व्यवहारगत है, ढाँचागत नहीं। स्क्रिप्ट स्वयं एक अप्रयुक्त
# पहचानकर्ता लेती है, उसे दो बार अनुरोध करती है और देखती है: पहली बार सैकड़ों
# मिलीसेकंड का मिस होना चाहिए, दूसरी बार — इकाई अंकों वाला हिट। सही पर्यावरण
# चरों वाला मैनिफ़ेस्ट यह जाँच पास नहीं करेगा, अगर कैश वास्तव में जवाब न दे।
#
# दो क्लस्टर: KUBECONFIG — आपका lab क्लस्टर, COZY_KUBECONFIG — Cozystack प्रबंधन
# क्लस्टर, जहाँ managed Redis सेवा रहती है।

# LAB_NAME और LAB_TITLE रिपोर्ट के शीर्षक में जाते हैं। आगे साझा जाँच लाइब्रेरी
# सोर्स की जाती है: उससे ok / warn / fail / evidence / finish आते हैं और, सबसे
# ज़रूरी, in_cluster_curl — यह क्लस्टर के भीतर curl वाला एक-बार का पॉड खड़ा करती है।
# भीतर से, VM से नहीं: लैब की सेवाएँ बाहर एक्सपोज़ नहीं हैं, और passes-api नाम से
# केवल क्लस्टर के भीतर से पहुँच में है। need_kubeconfig और need_tenant स्क्रिप्ट को
# पहले ही रोक देते हैं, अगर पहुँच या टेनेंट नंबर सेट न हो, — वरना सभी जाँचें एक साथ
# विफल होंगी और रिपोर्ट से कारण समझ नहीं आएगा।
LAB_NAME="07-redis"
LAB_TITLE="लैब 7 · धीमे बैकएंड के आगे कैश"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# जिन नामों और पतों को पूरी जाँच देखती है वे एक जगह इकट्ठा हैं: उन्हें स्क्रिप्ट के
# पाठ में ढूँढना नहीं पड़ेगा। COZY_KUBECONFIG को बाहर से ओवरराइड किया जा सकता है,
# अगर आपकी टेनेंट पहुँच डिफ़ॉल्ट जगह पर न हो।
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# पूरी स्क्रिप्ट के लिए दो शॉर्टकट: kget lab क्लस्टर से बात करता है (जो KUBECONFIG में है),
# cozy — Cozystack प्रबंधन क्लस्टर से। त्रुटि संदेश जानबूझकर दबाए गए हैं:
# यहाँ किसी ऑब्जेक्ट का न होना सामान्य स्थिति है, जिसे स्क्रिप्ट अपने शब्दों में और
# सुझाव के साथ बताएगी, न कि kubectl के किसी और के पाठ से।
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# JSON से एक फ़ील्ड निकालें। jq के बिना: वह बेयर macOS पर नहीं होता, लेकिन python3
# हर जगह होता है जहाँ बाकी जाँच लाइब्रेरी काम करती है।
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- प्रबंधन क्लस्टर पर managed Redis सेवा -----------------------------------
# Redis आपके lab क्लस्टर में नहीं, बल्कि प्रबंधन क्लस्टर के एक टेनेंट में रहता है: यह
# managed सेवा है, प्लेटफ़ॉर्म इसे स्वयं चलाता रहता है। टेनेंट में अधिकार सबके लिए अलग
# होते हैं, इसलिए न पहुँच अस्वीकृति और न ही लापता kubeconfig लैब को विफल करते हैं — कैश
# का काम नीचे सीधे, जीवंत अनुरोधों से जाँचा जाता है, और यही असली प्रमाण है।
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "टेनेंट kubeconfig ${COZY_KUBECONFIG} नहीं मिला — Redis की स्थिति जाँची नहीं गई" \
       "पथ सेट करें: export COZY_KUBECONFIG=~/.kube/config"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "टेनेंट ${TENANT_NS} में Redis अनुप्रयोग देख नहीं सके" \
         "आपकी टेनेंट भूमिका शायद यह कमांड न देती हो — यह लैब की त्रुटि नहीं है; कैश का काम नीचे सीधे जाँचा जाता है"
  elif [ -z "$REDIS_LIST" ]; then
    fail "टेनेंट ${TENANT_NS} में एक भी Redis अनुप्रयोग नहीं है" \
         "इसे डैशबोर्ड में बनाएँ: अनुप्रयोग बनाएँ -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis «${R_NAME}» तैयार है, डेटा प्रतियाँ: ${R_REPLICAS:-डिफ़ॉल्ट}"
    else
      warn "Redis «${R_NAME}» मौजूद है, पर तैयार होने की सूचना नहीं देता" \
           "इसकी स्थिति डैशबोर्ड में देखें; तीन-से-पाँच मिनट में खड़ा होता है"
    fi
    evidence "टेनेंट में Redis" "$REDIS_LIST"
  fi
fi

# --- धीमी निर्देशिका मौजूद है और वाकई धीमी है --------------------------------
# इस जाँच के बिना «पहले और बाद» की तुलना का कोई मतलब नहीं: अगर निर्देशिका तुरंत
# जवाब देती है, तो तेज़ करने को कुछ नहीं है और कैश के मापने को कुछ नहीं।
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "निर्देशिका ${HR} नहीं चल रही" \
       "hr-legacy.yaml लागू करें और kubectl describe pod -l app=hr-legacy देखें"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "निर्देशिका ${HR_MS} मि.से. में जवाब देती है — तेज़ करने को कुछ है"
    evidence "निर्देशिका की विलंबता" "${HR_MS} मि.से. प्रति /employee अनुरोध"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "निर्देशिका ${HR} ने अनुरोध का जवाब नहीं दिया" \
         "kubectl logs -l app=hr-legacy देखें"
  else
    warn "निर्देशिका ${HR_MS} मि.से. में जवाब देती है, यह मापने के लिए बहुत तेज़ है" \
         "सुनिश्चित करें कि hr-legacy.yaml में MODE=hr और HR_DELAY=800ms सेट है"
  fi
fi

# --- अनुप्रयोग कैशिंग के लिए कॉन्फ़िगर किया गया है ---------------------------
# हम कंटेनर का पर्यावरण python से पार्स करते हैं, jsonpath से नहीं: नेस्टेड सूचियों पर
# jsonpath फ़िल्टर अलग-अलग kubectl संस्करणों में अलग व्यवहार करते हैं, और हमारे लिए
# यह मायने रखता है कि जाँच सबके लिए एक-सी काम करे।
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

# शिकायतें क्रम में संभाली जाती हैं — सबसे सामान्य से सबसे विशिष्ट तक: कोई
# अनुप्रयोग नहीं, कोई चर नहीं, पते के बजाय बचा हुआ प्लेसहोल्डर। यहाँ का क्रम
# सजावटी नहीं है: वरना प्रतिभागी को «Redis का पता भरें» सलाह उस समय मिलेगी जब
# सेवा खुद ही अभी तैनात नहीं है, और वह गलत जगह त्रुटि ढूँढेगा।
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "lab क्लस्टर में ${APP} अनुप्रयोग नहीं है" \
       "passes-api.yaml लागू करें, अपना Harbor पता भरते हुए"
elif [ -z "$REDIS_ADDR" ]; then
  fail "${APP} में REDIS_ADDR चर सेट नहीं है — कैश बंद है" \
       "पैच लागू करें: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "पैच में प्लेसहोल्डर पता REDIS-ADDR अब भी है" \
       "अपना Redis पता भरें, उदाहरण के लिए rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "अनुप्रयोग ${REDIS_ADDR} पर कैश के लिए कॉन्फ़िगर है, प्रविष्टि जीवनकाल ${TTL:-डिफ़ॉल्ट} से."
fi

# हम केवल यह देखते हैं कि चर का नाम मौजूद है या नहीं, उसका मान कहीं पढ़ते या छापते नहीं।
# लोग लैब रिपोर्ट एक-दूसरे को भेजते हैं और टिकटों में जोड़ते हैं — वहाँ पहुँचा पासवर्ड
# हमेशा के लिए वहीं रह जाएगा।
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "Redis पासवर्ड अनुप्रयोग तक पहुँचता है (मान: <छिपा हुआ>)"
else
  fail "${APP} में REDIS_PASSWORD चर सेट नहीं है" \
       "Redis को प्रमाणीकरण चाहिए; redis-password सीक्रेट बनाएँ और cache-patch.yaml लागू करें"
fi

# लापता सीक्रेट चेतावनी है, विफलता नहीं: पासवर्ड को पॉड तक और तरीके से भी पहुँचाया जा
# सकता है। यहाँ जाँचा गया गुण अलग है — मैनिफ़ेस्ट में एक संदर्भ है, मान नहीं।
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "Redis पासवर्ड वाला redis-password सीक्रेट मौजूद है"
else
  warn "क्लस्टर में redis-password सीक्रेट नहीं है" \
       "बनाएँ: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- मुख्य जाँच: कैश वाकई तेज़ करता है --------------------------------------
# हम जानबूझकर नया पहचानकर्ता लेते हैं ताकि पहला अनुरोध निश्चित रूप से मिस हो।
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "सेवा ${APP} ने अपेक्षित JSON नहीं लौटाया" \
       "kubectl logs -l app=passes-api देखें; सुनिश्चित करें कि इमेज इस लैब के app/ से बनी है (टैग v2)"
  evidence "सेवा ने क्या जवाब दिया" "पहला अनुरोध: ${R1:-खाली}
दूसरा अनुरोध: ${R2:-खाली}"
elif [ "$MODE" != "redis" ]; then
  fail "अनुप्रयोग सूचित करता है कि कैश बंद है (cache: ${MODE})" \
       "REDIS_ADDR चर चल रहे पॉड तक नहीं पहुँचा — kubectl rollout status deployment/${APP} देखें"
elif [ "$C1" = "True" ]; then
  warn "पहला अनुरोध पहले ही कैश से आया — तुलना के लिए कुछ नहीं" \
       "पहचानकर्ता का असंभावित टकराव; जाँच फिर से चलाएँ"
elif [ "$C2" != "True" ]; then
  fail "उसी पहचानकर्ता का दूसरा अनुरोध फिर कैश में नहीं मिला" \
       "अनुप्रयोग Redis में लिख नहीं सकता: kubectl logs -l app=passes-api देखें, आमतौर पर वहाँ NOAUTH या टाइमआउट होता है"
  evidence "सेवा के जवाब" "पहला:  ${R1}
दूसरा: ${R2}"
else
  ok "कैश काम करता है: मिस ${T1} मि.से., हिट ${T2} मि.से."
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "1000 से अधिक")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "जीवंत सेवा पर माप" "पहचानकर्ता: ${PROBE_ID}
पहला अनुरोध (मिस):   ${T1} मि.से.
दूसरा अनुरोध (हिट): ${T2} मि.से.
लाभ: लगभग ${SPEEDUP} गुना
प्रविष्टि जीवनकाल: ${TTL:-डिफ़ॉल्ट} से."

  # सख़्त हिस्सा: हिट मिस से एक क्रम अधिक तेज़ होना चाहिए। वरना «कैश काम करता है»
  # का केवल यह मतलब है कि कुंजी लिखी गई, पर कोई लाभ नहीं।
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "लाभ मापने योग्य है: हिट मिस से लगभग ${SPEEDUP} गुना तेज़ है"
  else
    warn "कैश हिट कोई ध्यान देने योग्य लाभ नहीं देता (${T1} मि.से. बनाम ${T2} मि.से.)" \
         "सुनिश्चित करें कि निर्देशिका वाकई धीमी है, और Redis उसी पॉड पर नहीं है"
  fi
fi

# --- सेवा की कितनी प्रतियाँ एक कैश साझा करती हैं ----------------------------
# कैश सभी प्रतियों में साझा है — यह रिपोर्ट में देखने लायक है: हिट मिस वाले पॉड से
# अलग पॉड से आ सकता है, और यह सही है।
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "सेवा की चल रही प्रतियाँ: ${API_PODS} (वे कैश साझा करती हैं)"
  evidence "सेवा की प्रतियाँ" "$(kget pods -l app=passes-api -o wide)"
else
  fail "${APP} की एक भी चल रही प्रति नहीं" \
       "kubectl describe pod -l app=passes-api देखें"
fi

finish
