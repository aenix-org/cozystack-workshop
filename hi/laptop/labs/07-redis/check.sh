#!/usr/bin/env bash
# लैब 7 की जाँच: कैश वास्तव में चीज़ों को तेज़ करता है, और आँकड़े यह दिखाते हैं।
#
# यहाँ मुख्य जाँच व्यवहारगत है, संरचनात्मक नहीं। स्क्रिप्ट एक अप्रयुक्त
# पहचानकर्ता चुनती है, उसे दो बार अनुरोध करती है और देखती है: पहली बार सैकड़ों
# मिलीसेकंड का मिस होना चाहिए, दूसरी बार — एकल अंकों का हिट। सही एनवायरनमेंट
# वेरिएबल्स वाला मेनिफ़ेस्ट यह जाँच पास नहीं करेगा अगर कैश वास्तव में जवाब नहीं दे रहा।
#
# दो क्लस्टर: KUBECONFIG — आपका lab क्लस्टर, COZY_KUBECONFIG — Cozystack
# प्रबंधन क्लस्टर, जहाँ managed Redis सेवा रहती है।

# LAB_NAME और LAB_TITLE रिपोर्ट हेडर में जाते हैं। फिर साझा जाँच लाइब्रेरी
# सोर्स की जाती है: यह ok / warn / fail / evidence / finish प्रदान करती है और, सबसे महत्वपूर्ण,
# in_cluster_curl — यह क्लस्टर के अंदर curl वाला एक-बार का पॉड चालू करती है। अंदर से,
# लैपटॉप से नहीं: लैब सेवाएँ बाहर उजागर नहीं हैं, और passes-api नाम से
# केवल क्लस्टर के भीतर से पहुँच योग्य है। need_kubeconfig और need_tenant स्क्रिप्ट को जल्दी रोक देते हैं
# अगर एक्सेस या टेनेंट नंबर सेट नहीं है — अन्यथा सभी जाँचें एक साथ विफल हो जातीं
# और रिपोर्ट कारण नहीं दिखा पाती।
LAB_NAME="07-redis"
LAB_TITLE="लैब 7 · धीमे बैकएंड के आगे कैश"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# जिन नामों और पतों को पूरी जाँच देखती है वे एक जगह इकट्ठा हैं: स्क्रिप्ट टेक्स्ट में
# उन्हें ढूँढने की ज़रूरत नहीं। COZY_KUBECONFIG को बाहर से ओवरराइड किया जा सकता है
# अगर आपका टेनेंट एक्सेस डिफ़ॉल्ट के अलावा कहीं और है।
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# पूरी स्क्रिप्ट के लिए दो शॉर्टकट: kget lab क्लस्टर से बात करता है (जो KUBECONFIG में है),
# cozy — Cozystack प्रबंधन क्लस्टर से। एरर संदेश जानबूझकर दबाए गए हैं:
# यहाँ किसी ऑब्जेक्ट का न होना सामान्य स्थिति है, जिसे स्क्रिप्ट अपने शब्दों में
# और एक संकेत के साथ समझाएगी, kubectl के किसी और के टेक्स्ट से नहीं।
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# JSON से एक फ़ील्ड निकालें। jq के बिना: यह बेयर macOS पर नहीं होता, लेकिन python3 हर जगह है
# जहाँ बाकी जाँच लाइब्रेरी काम करती है।
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- प्रबंधन क्लस्टर पर managed Redis सेवा ------------------------------------
# Redis आपके lab क्लस्टर में नहीं, बल्कि प्रबंधन क्लस्टर के एक टेनेंट में रहता है: यह एक
# managed सेवा है, प्लेटफ़ॉर्म इसे खुद चलाए रखता है। टेनेंट में अधिकार हर किसी के लिए
# अलग हैं, इसलिए न एक्सेस अस्वीकृति और न ही गायब kubeconfig लैब को विफल करते हैं — कैश के
# काम करने की जाँच नीचे सीधे, जीवंत अनुरोधों से होती है, और यही असली प्रमाण है।
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "टेनेंट kubeconfig ${COZY_KUBECONFIG} नहीं मिला — Redis की स्थिति जाँची नहीं गई" \
       "पथ निर्दिष्ट करें: export COZY_KUBECONFIG=~/.kube/workshop"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "टेनेंट ${TENANT_NS} में Redis एप्लिकेशन नहीं देख सके" \
         "आपकी टेनेंट भूमिका यह कमांड अनुमति न दे — यह लैब की त्रुटि नहीं है; कैश की जाँच नीचे सीधे होती है"
  elif [ -z "$REDIS_LIST" ]; then
    fail "टेनेंट ${TENANT_NS} में कोई Redis एप्लिकेशन नहीं है" \
         "इसे डैशबोर्ड में बनाएँ: एप्लिकेशन बनाएँ -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis «${R_NAME}» तैयार है, डेटा प्रतियाँ: ${R_REPLICAS:-डिफ़ॉल्ट}"
    else
      warn "Redis «${R_NAME}» मौजूद है, लेकिन तैयारी की सूचना नहीं देता" \
           "डैशबोर्ड में इसकी स्थिति देखें; यह तीन से पाँच मिनट में चालू होता है"
    fi
    evidence "टेनेंट में Redis" "$REDIS_LIST"
  fi
fi

# --- धीमी डायरेक्टरी अपनी जगह है और वास्तव में धीमी है ------------------------
# इस जाँच के बिना «पहले और बाद» की तुलना का कोई अर्थ नहीं: अगर डायरेक्टरी
# तुरंत जवाब देती है, तो तेज़ करने को कुछ नहीं और कैश के मापने को कुछ नहीं।
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "डायरेक्टरी ${HR} नहीं चल रही" \
       "hr-legacy.yaml लागू करें और kubectl describe pod -l app=hr-legacy देखें"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "डायरेक्टरी ${HR_MS} मिलीसेकंड में जवाब देती है — तेज़ करने को कुछ है"
    evidence "डायरेक्टरी विलंबता" "${HR_MS} मिलीसेकंड प्रति /employee अनुरोध"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "डायरेक्टरी ${HR} ने अनुरोध का जवाब नहीं दिया" \
         "kubectl logs -l app=hr-legacy देखें"
  else
    warn "डायरेक्टरी ${HR_MS} मिलीसेकंड में जवाब देती है, यह मापने के लिए बहुत तेज़ है" \
         "सुनिश्चित करें कि hr-legacy.yaml में MODE=hr और HR_DELAY=800ms सेट है"
  fi
fi

# --- एप्लिकेशन कैश के लिए कॉन्फ़िगर है ----------------------------------------
# हम कंटेनर एनवायरनमेंट को python से पार्स करते हैं, jsonpath से नहीं: नेस्टेड सूचियों पर
# jsonpath फ़िल्टर अलग-अलग kubectl संस्करणों में अलग व्यवहार करते हैं, और हम चाहते हैं कि
# जाँच सबके लिए एक जैसी काम करे।
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
# एप्लिकेशन नहीं, कोई वेरिएबल नहीं, पते के बजाय एक प्लेसहोल्डर बचा। यहाँ क्रम
# कॉस्मेटिक नहीं है: अन्यथा प्रतिभागी को «Redis पता भरें» की सलाह उस समय मिलती
# जब सेवा खुद अभी तैनात नहीं हुई, और वह त्रुटि को गलत जगह ढूँढता।
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "lab क्लस्टर में ${APP} एप्लिकेशन नहीं है" \
       "passes-api.yaml लागू करें, अपना Harbor पता भरते हुए"
elif [ -z "$REDIS_ADDR" ]; then
  fail "${APP} में REDIS_ADDR वेरिएबल सेट नहीं है — कैश बंद है" \
       "पैच लागू करें: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "पैच में प्लेसहोल्डर पता REDIS-ADDR अभी भी है" \
       "अपना Redis पता भरें, उदाहरण के लिए rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "एप्लिकेशन ${REDIS_ADDR} पर कैश के लिए कॉन्फ़िगर है, प्रविष्टि जीवनकाल ${TTL:-डिफ़ॉल्ट} सेकंड"
fi

# हम केवल यह देखते हैं कि वेरिएबल नाम मौजूद है या नहीं, इसका मान कहीं नहीं पढ़ते
# या छापते। लोग लैब रिपोर्ट एक-दूसरे को भेजते हैं और टिकटों में जोड़ते हैं — वहाँ पहुँचा
# पासवर्ड हमेशा के लिए वहीं रह जाएगा।
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "Redis पासवर्ड एप्लिकेशन तक पहुँचता है (मान: <छिपा हुआ>)"
else
  fail "${APP} में REDIS_PASSWORD वेरिएबल सेट नहीं है" \
       "Redis को प्रमाणीकरण चाहिए; redis-password सीक्रेट बनाएँ और cache-patch.yaml लागू करें"
fi

# गायब सीक्रेट एक चेतावनी है, विफलता नहीं: पासवर्ड को पॉड तक किसी और तरीके से
# पहुँचाया जा सकता है। यहाँ जाँची जा रही संपत्ति अलग है — मेनिफ़ेस्ट में एक संदर्भ है,
# मान नहीं।
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "Redis पासवर्ड वाला redis-password सीक्रेट मौजूद है"
else
  warn "क्लस्टर में redis-password सीक्रेट नहीं है" \
       "इसे बनाएँ: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- मुख्य जाँच: कैश वास्तव में गति बढ़ाता है ---------------------------------
# हम जानबूझकर एक नया पहचानकर्ता चुनते हैं ताकि पहला अनुरोध निश्चित रूप से मिस हो।
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
  fail "एप्लिकेशन बताता है कि कैश बंद है (cache: ${MODE})" \
       "REDIS_ADDR वेरिएबल चल रहे पॉड्स तक नहीं पहुँचा — kubectl rollout status deployment/${APP} देखें"
elif [ "$C1" = "True" ]; then
  warn "पहला अनुरोध पहले ही कैश से आया — तुलना करने को कुछ नहीं" \
       "एक असंभावित पहचानकर्ता टकराव; जाँच फिर से चलाएँ"
elif [ "$C2" != "True" ]; then
  fail "उसी पहचानकर्ता के लिए दूसरा अनुरोध फिर कैश से चूक गया" \
       "एप्लिकेशन Redis में नहीं लिख सकता: kubectl logs -l app=passes-api देखें, आमतौर पर वहाँ NOAUTH या टाइमआउट होता है"
  evidence "सेवा के जवाब" "पहला:  ${R1}
दूसरा: ${R2}"
else
  ok "कैश काम करता है: मिस ${T1} मिलीसेकंड, हिट ${T2} मिलीसेकंड"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "1000 से अधिक")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "जीवंत सेवा पर माप" "पहचानकर्ता: ${PROBE_ID}
पहला अनुरोध (मिस):   ${T1} मिलीसेकंड
दूसरा अनुरोध (हिट): ${T2} मिलीसेकंड
लाभ: लगभग ${SPEEDUP}x
प्रविष्टि जीवनकाल: ${TTL:-डिफ़ॉल्ट} सेकंड"

  # सख्त हिस्सा: हिट मिस से एक क्रम-परिमाण तेज़ होना चाहिए। अन्यथा
  # «कैश काम करता है» का मतलब बस इतना है कि कुंजी लिखी गई, लेकिन कोई लाभ नहीं।
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "लाभ मापने योग्य है: हिट मिस से लगभग ${SPEEDUP}x तेज़ है"
  else
    warn "कैश हिट कोई उल्लेखनीय लाभ नहीं देता (${T1} मिलीसेकंड बनाम ${T2} मिलीसेकंड)" \
         "सुनिश्चित करें कि डायरेक्टरी वास्तव में धीमी है, और Redis उसी पॉड पर नहीं है"
  fi
fi

# --- कितनी सेवा प्रतियाँ एक कैश साझा करती हैं --------------------------------
# कैश सभी प्रतियों में साझा है — यह रिपोर्ट में देखने लायक है: हिट किसी
# दूसरे पॉड से आ सकता था, न कि मिस वाले से, और यह सही है।
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "चल रही सेवा प्रतियाँ: ${API_PODS} (वे कैश साझा करती हैं)"
  evidence "सेवा प्रतियाँ" "$(kget pods -l app=passes-api -o wide)"
else
  fail "${APP} की कोई भी चल रही प्रति नहीं" \
       "kubectl describe pod -l app=passes-api देखें"
fi

finish
