#!/usr/bin/env bash
# लैब 1 की जाँच: एप्लिकेशन तैनात है और वास्तव में काम कर रहा है।
#
# यहाँ «वास्तव में» का अर्थ है: पेज सचमुच HTTP पर परोसा जाता है, उसमें पॉड का
# नाम प्रतिस्थापित है, और वह नाम किसी सचमुच चल रही प्रतिलिपि के नाम से मेल खाता है।
# Deployment ऑब्जेक्ट के अस्तित्व की जाँच बेकार है — वह मौजूद रह सकता है और काम न करे।
#
# यह वर्चुअल मशीन पर, इसी लैब के फ़ोल्डर से, प्रशिक्षण क्लस्टर `lab` तक पहुँच के साथ चलता है
# (प्रबंधन क्लस्टर पर टेनेंट तक नहीं):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# COZY_TENANT चर की यहाँ ज़रूरत नहीं: पूरी लैब `lab` क्लस्टर के भीतर चलती है।
#
# स्क्रिप्ट क्लस्टर में कुछ नहीं बदलती — केवल पढ़ती है और HTTP अनुरोध भेजती है।
# इसे सफ़ाई से पहले चलाएँ: एप्लिकेशन हटाने के बाद जाँचने को कुछ नहीं बचेगा।

# इन दो चरों को lib.sh उठाता है — ये रिपोर्ट के शीर्षक में और उस फ़ाइल के नाम
# report-<लैब>-<तारीख>.md में जाते हैं, जिसे स्क्रिप्ट अपने बगल में रखती है।
LAB_NAME="01-deploy"
LAB_TITLE="लैब 1 · पहला एप्लिकेशन"
# साझा जाँच लाइब्रेरी: यहाँ से आते हैं ok / fail / warn / evidence / finish,
# क्लस्टर के भीतर से पेज अनुरोध और रिपोर्ट लिखना। पथ की गणना उस स्थान से होती है जहाँ
# स्क्रिप्ट स्वयं रहती है, इसलिए किसी भी निर्देशिका से चलाना एक जैसा काम करता है।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# अगर KUBECONFIG सेट नहीं है तो तुरंत रुक जाएँ। इसके बिना kubectl क्लस्टर को
# वर्चुअल मशीन पर ही ढूँढता है, नहीं पाता, और एक के बाद एक हर जाँच को उसी त्रुटि से
# गिरा देता है, जिससे असली कारण नहीं दिखता।
need_kubeconfig

# --- एप्लिकेशन ऑब्जेक्ट ------------------------------------------------------
# पहली रक्षा-पंक्ति: एप्लिकेशन सचमुच स्थापित है और कम से कम एक प्रतिलिपि तैयारी तक पहुँची।
# हम .status.readyReplicas देखते हैं, न कि Deployment के मात्र अस्तित्व को: ऑब्जेक्ट
# तत्काल और हमेशा सफलतापूर्वक बनता है, जबकि तैयारी का अर्थ है कि प्रतिलिपि उठी,
# अपनी रेडीनेस जाँच पास की और जवाब देने में सक्षम है।
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # विशेष स्थिति: ऑब्जेक्ट मौजूद है, पर उसके लिए शून्य प्रतिलिपियाँ माँगी गई हैं। संदेश
    # «कोई प्रतिलिपि तैयार नहीं (0 चाहिए)» निरर्थक लगता।
    fail "एप्लिकेशन रुका हुआ है — 0 प्रतिलिपियाँ माँगी गईं" \
         "प्रतिलिपि वापस लाएँ: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "एप्लिकेशन तैनात है, ${DESIRED} में से ${READY} प्रतिलिपियाँ तैयार"
    # अटकी हुई रोलआउट सेवा को नहीं गिराती: पुरानी प्रतिलिपि काम करती रहती है, और
    # readyReplicas एक पर बना रहता है। इस जाँच के बिना प्रतिभागी हरे निशान और ऐसे
    # डिप्लॉयमेंट के साथ चला जाता है जो सदा के लिए ErrImagePull में अटका रहता है।
    # हम प्रतिलिपियों को स्वयं देखते हैं, केवल ProgressDeadlineExceeded को नहीं: समयसीमा
    # दस मिनट बाद सक्रिय होती है, जबकि स्क्रिप्ट तुरंत चलाई जाती है। इस बीच पुरानी प्रतिलिपि
    # काम करती रहती है, readyReplicas एक पर बना रहता है, और इस जाँच के बिना प्रतिभागी हरे
    # निशान और ImagePullBackOff में अटके डिप्लॉयमेंट के साथ चला जाता है।
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "रोलआउट अटक गया: नई प्रतिलिपि नहीं उठ रही, केवल पुरानी काम कर रही है" \
           "देखें kubectl get pods -l app=rickroll — आमतौर पर इमेज डाउनलोड नहीं हुई; कार्यशील स्थिति बहाल करें: kubectl apply -f rickroll.yaml"
      evidence "जो प्रतिलिपियाँ शुरू नहीं होतीं" "${STUCK:-कारण Deployment की स्थिति में: $PROG_REASON}"
    fi
  else
    fail "एप्लिकेशन बना, पर कोई प्रतिलिपि तैयार नहीं (${DESIRED} चाहिए)" \
         "देखें kubectl get pods -l app=rickroll और kubectl describe deployment rickroll"
    evidence "पॉड की स्थिति" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "rickroll नाम का कोई Deployment नहीं मिला" \
       "मैनिफ़ेस्ट लागू करें: kubectl apply -f rickroll.yaml"
fi

# --- सेटिंग्स और पेज ---------------------------------------------------------
# दोनों ConfigMap उसी फ़ाइल से बनते हैं जिससे एप्लिकेशन, इसलिए वे केवल उसी के साथ या
# हाथ से हटाने पर ही गायब हो सकते हैं। हम इन्हें अलग से जाँचते हैं ताकि पेज टूटने पर
# प्रतिभागी को तुरंत दिखे कि वास्तव में क्या कमी है: rickroll-conf के बिना nginx पॉड का
# नाम प्रतिस्थापित नहीं करेगा, और rickroll-page-v1 के बिना लैब 4 में दूसरे संस्करण से
# तुलना करने को कुछ नहीं होगा और वापस लौटने के लिए कहीं नहीं होगा।
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "सेटिंग्स मौजूद हैं: ConfigMap ${cm}"
  else
    fail "ConfigMap ${cm} नहीं मिला" \
         "यह उसी फ़ाइल से बनता है: kubectl apply -f rickroll.yaml"
  fi
done

# --- स्थायी पता -------------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # बिना एंडपॉइंट वाला Service एक आम और अनदेखी खराबी है: ऑब्जेक्ट मौजूद है,
  # पर पॉड पर लगे लेबल सिलेक्टर से मेल नहीं खाए, और पते के पीछे खाली है।
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "स्थायी पता काम कर रहा है, उसके पीछे प्रतिलिपियाँ: ${EPS_N}"
    evidence "सेवा के पीछे के पते" "$EPS"
  else
    fail "Service rickroll मौजूद है, पर उसके पीछे एक भी प्रतिलिपि नहीं" \
         "आमतौर पर कारण यह है कि पॉड के लेबल सेवा के selector से मेल नहीं खाए — app: rickroll मिलाएँ"
  fi
else
  fail "rickroll नाम का कोई Service नहीं मिला" \
       "यह उसी फ़ाइल से बनता है: kubectl apply -f rickroll.yaml"
fi

# --- मुख्य बात: पेज सचमुच परोसा जाता है --------------------------------------
# यही जाँच जिसके लिए सब कुछ किया गया। पिछली सभी जाँचें केवल यह बताती हैं कि क्लस्टर में
# ऑब्जेक्ट सही ढंग से वर्णित हैं; यह जाँच बताती है कि उपयोगकर्ता को पेज मिलता है। अनुरोध
# क्लस्टर के भीतर से, एक बार के पॉड से जाता है: बाहर से rickroll का पता मौजूद नहीं है, और
# यहाँ port-forward आपकी वर्चुअल मशीन की जाँच होती, क्लस्टर की नहीं।
# हम कई बार अनुरोध करते हैं: सेवा के पीछे कई प्रतिलिपियाँ होने पर एक बार का नमूना
# प्रतिस्थापित प्रतिलिपि को छू नहीं पाता, और जाँच किसी और की सामग्री पर हरी हो जाती है।
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# मार्कर पेज पर ठीक एक बार आना चाहिए, वरना जवाबों का काउंटर झूठ बोलता है:
# «Never Gonna Give You Up» <title> में भी है और <h1> में भी, और इससे दुगुनापन आ रहा था।
ANSWERS="$(printf '%s' "$BODY" | grep -c 'вас обслужил под')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "एप्लिकेशन HTTP पर जवाब देता है और अपना पेज परोसता है (${ANSWERS} अनुरोध जाँचे गए)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "सेवा के पीछे केवल आपका एप्लिकेशन जवाब नहीं देता: आपका पेज ${TOTAL_LINES} में से ${ANSWERS} बार आया" \
       "कोई और भी app=rickroll लेबल पहने है — देखें kubectl get pods -l app=rickroll और अतिरिक्त हटाएँ"
else
  fail "एप्लिकेशन ने अपेक्षित पेज नहीं परोसा" \
       "हाथ से जाँचें: kubectl port-forward svc/rickroll 8080:80, फिर http://localhost:8080 खोलें"
  evidence "पेज के बदले क्या लौटा" "$(printf '%s' "$BODY" | head -20)"
fi

# --- पॉड नाम प्रतिस्थापन -----------------------------------------------------
# लैब इसी के लिए बनी है: पेज में नाम असली पॉड से मेल खाना चाहिए।
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# हम एप्लिकेशन के ReplicaSet द्वारा प्रबंधित पॉड लेते हैं, न कि हर वह चीज़ जो
# app=rickroll लेबल पहने है। वरना ऐसे लेबल वाला कोई बाहरी पॉड «असली» की सूची में
# आ जाता है और खुद को पुष्ट करता है — जाँचा गया, एक धोखेबाज़ इस तरह जाँच पास कर गया।
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "app=rickroll लेबल बाहरी पॉड पहने हैं — वे लोड बैलेंसिंग में शामिल हो जाएँगे" \
       "अतिरिक्त हटाएँ: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "एप्लिकेशन के लेबल के नीचे बाहरी पॉड" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "पेज में पॉड का नाम नहीं है" \
       "जाँचें कि ConfigMap rickroll-conf प्रतिस्थापित हुआ — उसमें पंक्ति sub_filter '__POD__' '\$hostname' है"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "पॉड का नाम प्रतिस्थापित नहीं हुआ — पेज में प्लेसहोल्डर __POD__ रह गया" \
       "nginx ने sub_filter लागू नहीं किया: जाँचें कि सेटिंग्स वाला वॉल्यूम /etc/nginx/conf.d पर माउंट है"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "पॉड का नाम प्रतिस्थापित होता है और सचमुच चल रही प्रतिलिपि से मेल खाता है: ${SERVED_BY}"
  evidence "किसने अनुरोध परोसा" "$SERVED_BY"
  evidence "चल रही प्रतिलिपियाँ" "$REAL_PODS"
else
  fail "पेज पॉड को «${SERVED_BY}» कहता है, पर क्लस्टर में ऐसा कोई पॉड नहीं है" \
       "संभव है प्रतिलिपि अनुरोध और जाँच के बीच फिर से बनी हो — स्क्रिप्ट दोबारा चलाएँ"
fi

# --- रेडीनेस जाँच कॉन्फ़िगर है -----------------------------------------------
# इसके बिना संस्करण रोलआउट वाली लैब में डाउनटाइम होगा, और प्रतिभागी सोचेगा कि हमने झूठ बोला।
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "रेडीनेस जाँच कॉन्फ़िगर है (${PROBE_PATH}) — अपडेट बिना डाउनटाइम के होगा"
else
  warn "एप्लिकेशन में कोई रेडीनेस जाँच नहीं है" \
       "ऐसे एप्लिकेशन पर बिना-डाउनटाइम अपडेट वाली लैब 4 त्रुटियाँ देगी — rickroll.yaml से readinessProbe बहाल करें"
fi

finish
