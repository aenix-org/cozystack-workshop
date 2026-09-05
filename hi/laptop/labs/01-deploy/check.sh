#!/usr/bin/env bash
# लैब 1 की जाँच: एप्लिकेशन तैनात है और वास्तव में काम कर रहा है।
#
# «वास्तव में» का यहाँ अर्थ है: पेज सचमुच HTTP पर परोसा जाता है, उसमें पॉड का
# नाम प्रतिस्थापित है, और यह नाम सचमुच चल रही किसी कॉपी के नाम से मेल खाता है।
# Deployment ऑब्जेक्ट का अस्तित्व जाँचना व्यर्थ है — वह मौजूद हो सकता है और काम न करे।
#
# लैपटॉप पर चलता है, इसी लैब के फ़ोल्डर से, प्रशिक्षण क्लस्टर `lab` तक पहुँच के साथ
# (प्रबंधन क्लस्टर पर किसी टेनेंट तक नहीं):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# COZY_TENANT वेरिएबल यहाँ ज़रूरी नहीं: पूरी लैब `lab` क्लस्टर के अंदर चलती है।
#
# स्क्रिप्ट क्लस्टर में कुछ नहीं बदलती — केवल पढ़ती है और HTTP अनुरोध भेजती है।
# इसे सफ़ाई से पहले चलाएँ: एप्लिकेशन हटाने के बाद जाँचने को कुछ नहीं बचेगा।

# ये दो वेरिएबल lib.sh उठा लेती है — वे रिपोर्ट के शीर्षक और उस फ़ाइल नाम
# report-<लैब>-<तारीख>.md में जाते हैं, जिसे स्क्रिप्ट अपने बगल में रखती है।
LAB_NAME="01-deploy"
LAB_TITLE="लैब 1 · आपका पहला एप्लिकेशन"
# साझा जाँच लाइब्रेरी: यहाँ से ok / fail / warn / evidence / finish आते हैं,
# साथ ही क्लस्टर के अंदर से पेज अनुरोध और रिपोर्ट लेखन। पथ की गणना उस स्थान से होती है
# जहाँ स्क्रिप्ट खुद रहती है, इसलिए किसी भी डायरेक्टरी से चलाना एक जैसा काम करता है।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# अगर KUBECONFIG सेट नहीं है तो तुरंत रुक जाएँ। इसके बिना kubectl खुद लैपटॉप पर
# क्लस्टर ढूँढता है, नहीं पाता, और एक ही त्रुटि से सारी जाँचें एक के बाद एक गिरा देता है,
# जिससे असली कारण नहीं दिखता।
need_kubeconfig

# --- एप्लिकेशन ऑब्जेक्ट ------------------------------------------------------
# पहली सीमा: एप्लिकेशन बिल्कुल बना है और कम से कम एक कॉपी तैयारी तक पहुँची है।
# हम .status.readyReplicas देखते हैं, न कि Deployment के अस्तित्व को: ऑब्जेक्ट
# तुरंत और हमेशा सफलतापूर्वक बनता है, जबकि तैयारी का मतलब है कि कॉपी उठी,
# अपनी तैयारी जाँच पास की, और जवाब देने में सक्षम है।
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # विशेष मामला: ऑब्जेक्ट मौजूद है, पर उसमें शून्य कॉपियाँ माँगी गई हैं। संदेश
    # «कोई कॉपी तैयार नहीं (0 चाहिए)» बेतुका लगता।
    fail "एप्लिकेशन रुका हुआ है — 0 कॉपियाँ माँगी गई हैं" \
         "कॉपी वापस लाएँ: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "एप्लिकेशन तैनात है, तैयार कॉपियाँ ${READY} में से ${DESIRED}"
    # अटकी हुई रोलआउट सेवा को गिराती नहीं: पुरानी कॉपी काम करती रहती है, और
    # readyReplicas एक पर बना रहता है। इस जाँच के बिना प्रतिभागी हरे निशान और
    # ErrImagePull में हमेशा के लिए अटके डिप्लॉयमेंट के साथ चला जाता है।
    # हम खुद कॉपियों को देखते हैं, केवल ProgressDeadlineExceeded को नहीं: डेडलाइन
    # दस मिनट बाद चलती है, पर स्क्रिप्ट तुरंत चलाई जाती है। पुरानी कॉपी इस बीच
    # काम करती रहती है, readyReplicas एक पर बना रहता है, और इस जाँच के बिना प्रतिभागी
    # हरे निशान और ImagePullBackOff में अटके डिप्लॉयमेंट के साथ चला जाता है।
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "रोलआउट अटक गई: नई कॉपी नहीं उठती, केवल पुरानी काम करती है" \
           "देखें kubectl get pods -l app=rickroll — आमतौर पर छवि डाउनलोड नहीं हुई; काम करती स्थिति लौटाएँ: kubectl apply -f rickroll.yaml"
      evidence "कॉपियाँ जो स्टार्ट नहीं होतीं" "${STUCK:-कारण Deployment की स्थिति में है: $PROG_REASON}"
    fi
  else
    fail "एप्लिकेशन बना है, पर कोई कॉपी तैयार नहीं (${DESIRED} चाहिए)" \
         "देखें kubectl get pods -l app=rickroll और kubectl describe deployment rickroll"
    evidence "पॉड की स्थिति" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "rickroll नाम का Deployment नहीं मिला" \
       "मैनिफ़ेस्ट लागू करें: kubectl apply -f rickroll.yaml"
fi

# --- सेटिंग्स और पेज --------------------------------------------------------
# दोनों ConfigMap उसी फ़ाइल से बनते हैं जिससे एप्लिकेशन, इसलिए वे केवल उसके साथ या
# हाथ से हटाने पर ही ग़ायब हो सकते हैं। हम उन्हें अलग से जाँचते हैं ताकि पेज टूटने पर
# प्रतिभागी तुरंत देखे कि ठीक क्या कमी है: rickroll-conf के बिना nginx पॉड का नाम
# प्रतिस्थापित नहीं करेगा, और rickroll-page-v1 के बिना लैब 4 में दूसरे संस्करण से
# तुलना करने को कुछ नहीं होगा और वापस लौटने को कहीं नहीं।
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "सेटिंग्स अपनी जगह पर: ConfigMap ${cm}"
  else
    fail "ConfigMap ${cm} नहीं मिला" \
         "यह उसी फ़ाइल से बनता है: kubectl apply -f rickroll.yaml"
  fi
done

# --- स्थायी पता -------------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # बिना एंडपॉइंट वाली Service एक सामान्य और अनदेखी रह जाने वाली खराबी है: ऑब्जेक्ट है,
  # पर पॉड के लेबल सेलेक्टर से मेल नहीं खाए, और पते के पीछे कुछ नहीं।
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "स्थायी पता काम कर रहा है, उसके पीछे कॉपियाँ: ${EPS_N}"
    evidence "सेवा के पीछे के पते" "$EPS"
  else
    fail "Service rickroll है, पर उसके पीछे एक भी कॉपी नहीं" \
         "आमतौर पर कारण यह है कि पॉड के लेबल सेवा के selector से मेल नहीं खाए — app: rickroll मिलाएँ"
  fi
else
  fail "rickroll नाम की Service नहीं मिली" \
       "यह उसी फ़ाइल से बनती है: kubectl apply -f rickroll.yaml"
fi

# --- मुख्य बात: पेज सचमुच परोसा जाता है --------------------------------------
# यही सब कुछ करने का मकसद था। पिछली सभी जाँचें केवल यह बताती हैं कि क्लस्टर के ऑब्जेक्ट
# सही ढंग से वर्णित हैं; यह — कि उपयोगकर्ता को पेज मिलता है। अनुरोध क्लस्टर के
# अंदर से जाता है, एक बार के पॉड से: बाहर से rickroll का पता मौजूद नहीं, और
# port-forward यहाँ आपके लैपटॉप की जाँच होती, क्लस्टर की नहीं।
# हम कई बार अनुरोध करते हैं: सेवा के पीछे कई कॉपियों के होने पर एकल नमूना
# प्रतिस्थापित कॉपी तक न पहुँचे, और जाँच किसी और की सामग्री पर हरी हो जाए।
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# मार्कर पेज पर ठीक एक बार आना चाहिए, वरना जवाबों का काउंटर झूठ बोलता है:
# «Never Gonna Give You Up» <title> में भी है और <h1> में भी, और इससे दोगुना हो रहा था।
ANSWERS="$(printf '%s' "$BODY" | grep -c 'सेवा प्रदान करने वाला Pod')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "एप्लिकेशन HTTP पर जवाब देता है और अपना पेज परोसता है (${ANSWERS} अनुरोध जाँचे गए)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "सेवा के पीछे केवल आपका एप्लिकेशन जवाब नहीं देता: आपका अपना पेज ${TOTAL_LINES} में से ${ANSWERS} बार आया" \
       "कोई और भी app=rickroll लेबल पहनता है — देखें kubectl get pods -l app=rickroll और अतिरिक्त हटाएँ"
else
  fail "एप्लिकेशन ने अपेक्षित पेज नहीं परोसा" \
       "हाथ से जाँचें: kubectl port-forward svc/rickroll 8080:80, फिर http://localhost:8080 खोलें"
  evidence "पेज के बजाय क्या लौटा" "$(printf '%s' "$BODY" | head -20)"
fi

# --- पॉड का नाम प्रतिस्थापन --------------------------------------------------
# इसी के लिए लैब बनी है: पेज में नाम असली पॉड से मेल खाना चाहिए।
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# हम एप्लिकेशन के ReplicaSet द्वारा प्रबंधित पॉड लेते हैं, न कि हर वह चीज़ जो
# app=rickroll लेबल पहनती है। वरना उस लेबल वाला एक बाहरी पॉड «असली» की सूची में
# घुस जाता है और खुद की पुष्टि करता है — जाँचा गया, एक भेदिया इस तरह जाँच पास कर गया।
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "बाहरी पॉड app=rickroll लेबल पहनते हैं — वे लोड बैलेंसिंग में घुस जाएँगे" \
       "अतिरिक्त हटाएँ: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "एप्लिकेशन लेबल के अंतर्गत बाहरी पॉड" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "पेज में पॉड का नाम नहीं है" \
       "जाँचें कि ConfigMap rickroll-conf प्रतिस्थापित हुआ — उसमें पंक्ति sub_filter '__POD__' '\$hostname' है"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "पॉड का नाम प्रतिस्थापित नहीं हुआ — पेज में प्लेसहोल्डर __POD__ रह गया" \
       "nginx ने sub_filter लागू नहीं किया: जाँचें कि सेटिंग्स वॉल्यूम /etc/nginx/conf.d पर माउंट है"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "पॉड का नाम प्रतिस्थापित होता है और सचमुच चल रही कॉपी से मेल खाता है: ${SERVED_BY}"
  evidence "किसने अनुरोध परोसा" "$SERVED_BY"
  evidence "चल रही कॉपियाँ" "$REAL_PODS"
else
  fail "पेज पॉड «${SERVED_BY}» को नाम देता है, पर क्लस्टर में ऐसा कोई पॉड नहीं" \
       "शायद कॉपी अनुरोध और जाँच के बीच फिर से बनी — स्क्रिप्ट दोबारा चलाएँ"
fi

# --- तैयारी जाँच कॉन्फ़िगर की गई ----------------------------------------------
# इसके बिना संस्करण-रोलआउट वाली लैब में डाउनटाइम होगा, और प्रतिभागी तय करेगा कि हमने झूठ बोला।
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "तैयारी जाँच कॉन्फ़िगर है (${PROBE_PATH}) — अपडेट बिना डाउनटाइम के होगा"
else
  warn "एप्लिकेशन में कोई तैयारी जाँच नहीं" \
       "बिना डाउनटाइम अपडेट पर लैब 4 ऐसे एप्लिकेशन पर त्रुटियाँ देगी — rickroll.yaml से readinessProbe लौटाएँ"
fi

finish
