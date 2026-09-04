#!/usr/bin/env bash
# लैब 3 की जाँच: ऑटोस्केलिंग।
#
# हम यह सत्यापित नहीं करते कि «hpa.yaml लागू हो गया», बल्कि यह कि तंत्र जीवित है और निर्णय लेने में सक्षम है:
#   - कंटेनर में requests.cpu है, वरना प्रतिशत किस आधार पर गिना जाए;
#   - HPA मौजूद है और ठीक हमारे Deployment को ही लक्षित करता है;
#   - सीमा सार्थक रूप से तय है (maxReplicas एक से अधिक, वरना बढ़ने की कोई जगह नहीं);
#   - मेट्रिक्स वास्तव में एकत्र हो रहे हैं: स्टेटस में संख्या है, <unknown> नहीं;
#   - स्केलिंग पहले ही चल चुकी है, यानी लोड वास्तव में दिया गया था।
#
# स्क्रिप्ट कुछ भी नहीं बदलती। एक बार का पॉड केवल यह जाँचने के लिए उठाया जाता है
# कि Fortio क्लस्टर के भीतर से जवाब देता है, और वह खुद को हटा देता है।
#
# लैपटॉप पर, इसी लैब के फ़ोल्डर से, प्रशिक्षण क्लस्टर `lab` तक पहुँच के साथ चलता है
# (प्रबंधन क्लस्टर के टेनेंट पर नहीं):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# यहाँ COZY_TENANT वेरिएबल की ज़रूरत नहीं: पूरी लैब `lab` क्लस्टर के भीतर चलती है।
#
# इसे सफ़ाई से पहले चलाएँ। कुछ जाँचें पहले ही हो चुके विकास के निशानों पर निर्भर हैं,
# और वे HPA ऑब्जेक्ट के साथ ही जीवित रहते हैं: उसे हटा दें और साबित करने को कुछ नहीं बचेगा।

# ये रिपोर्ट की हेडलाइन में और स्क्रिप्ट के पास फ़ाइल report-<लैब>-<तारीख>.md के नाम में जाते हैं।
LAB_NAME="03-scale"
LAB_TITLE="लैब 3 · लोड और ऑटोस्केलिंग"
# साझा लाइब्रेरी: ok / fail / warn / evidence / finish, क्लस्टर के भीतर से क्वेरी,
# रिपोर्ट लिखना। पथ स्क्रिप्ट की अपनी जगह से गिना जाता है, वर्तमान डायरेक्टरी से नहीं।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG के बिना kubectl लैपटॉप पर क्लस्टर ढूँढता है और सब कुछ एक ही त्रुटि में ढेर कर देता है,
# जिसमें असली कारण नहीं दिखता। हम तुरंत रुक जाते हैं।
need_kubeconfig

# नामों को वेरिएबल में निकाला गया है ताकि इस लैब में ऐप्लिकेशन का नाम और HPA का नाम मिलने पर
# ऐसा न लगे कि एक ही नाम गलती से दो बार लिख दिया गया हो।
APP=rickroll
HPA=rickroll

# --- स्केलिंग का लक्ष्य अपनी जगह पर -----------------------------------------
# लैब 1 का ऐप्लिकेशन वही है जिसे HPA प्रबंधित करता है। अगर वह नहीं है, तो आगे की सारी
# जाँचें झरने की तरह गिर पड़ेंगी और प्रतिभागी को एक स्पष्ट त्रुटि के बजाय दर्जनभर त्रुटियाँ
# मिलेंगी, इसलिए यही एकमात्र जगह है जहाँ स्क्रिप्ट समय से पहले समाप्त होती है।
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "ऐप्लिकेशन ${APP} क्लस्टर में नहीं है — स्केल करने को कुछ नहीं" \
       "इसे तैनात करें: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "ऐप्लिकेशन ${APP} अपनी जगह पर है"

# --- requests.cpu: इसके बिना HPA प्रतिशत नहीं गिनता ------------------------
# «HPA काम नहीं करता» का सबसे आम कारण, और मैनिफ़ेस्ट से यह नहीं दिखता:
# ऑब्जेक्ट सफलतापूर्वक बन जाता है, पर TARGETS हमेशा के लिए <unknown> बना रहता है।
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "कंटेनर में requests.cpu = ${REQ_CPU} तय है — प्रतिशत गिनने का आधार है"
  evidence "कंटेनर के संसाधन" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-तय नहीं}"
else
  fail "कंटेनर ${APP} में requests.cpu तय नहीं है" \
       "Utilization के आधार पर HPA इसके बिना काम नहीं करता; ../01-deploy/rickroll.yaml दोबारा लागू करें"
fi

# --- स्वयं HPA ---------------------------------------------------------------
# हम केवल ऑब्जेक्ट का होना ही नहीं, बल्कि यह भी जाँचते हैं कि वह किसे लक्षित करता है। scaleTargetRef में
# टाइपो वाला HPA सफलतापूर्वक बनता है और सूची में काम करता हुआ दिखता है, पर पूरी लैब भर
# वह एक अनुपस्थित ऐप्लिकेशन को प्रबंधित करता है।
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "क्लस्टर में ${HPA} नाम का कोई HorizontalPodAutoscaler नहीं है" \
       "इसे लागू करें: kubectl apply -f hpa.yaml (जाँच सफ़ाई से पहले चलाएँ)"
  evidence "ऑटोस्केलिंग से क्या मौजूद है" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA} Deployment/${APP} को लक्षित करता है"
else
  fail "HPA ${HPA} ऑब्जेक्ट ${TARGET_KIND}/${TARGET_NAME} को प्रबंधित करता है, न कि Deployment/${APP} को" \
       "hpa.yaml में scaleTargetRef ठीक करें और दोबारा लागू करें"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "सीमा तय है: ${MINR} से ${MAXR} प्रतियों तक — बढ़ने की जगह है"
else
  fail "सीमा की ऊपरी हद ${MAXR:-तय नहीं} है — बढ़ने की जगह नहीं" \
       "hpa.yaml में maxReplicas एक से अधिक होना चाहिए"
fi

# --- मेट्रिक के आधार पर लक्ष्य -------------------------------------------------------
# यहाँ warn है, fail नहीं: AverageValue वाला विकल्प (मिलीकोर में सीमा) भी काम करता है,
# लैब दोनों में से केवल एक को समझाती है। इसके लिए फ़ेल करना असत्य होगा।
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "सीमा तय है: requests.cpu का ${TGT_VAL}% (${REQ_CPU:-?})"
else
  warn "सीमा requests के प्रतिशत में तय नहीं है (प्रकार: ${TGT_TYPE:-कोई नहीं})" \
       "लैब Utilization वाला विकल्प समझाती है; इससे काम करने पर असर नहीं पड़ता"
fi

# --- सबसे मुख्य: मेट्रिक्स वास्तव में एकत्र हो रहे हैं -----------------------------------
# ठीक यहीं «ऑब्जेक्ट बना» और «तंत्र काम करता है» के बीच का फ़र्क दिखता है।
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "मेट्रिक्स एकत्र हो रहे हैं: वर्तमान लोड requests का ${CUR_UTIL}%, HPA निर्णय ले रहा है"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA निर्णय ले रहा है (ScalingActive=True), मेट्रिक का वर्तमान मान अभी नहीं दिया गया है"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA को मेट्रिक्स नहीं मिल रहे — TARGETS में <unknown> दिखेगा, निर्णय लेने का कोई आधार नहीं" \
       "apply के बाद पहले दो मिनट यह सामान्य है, प्रतीक्षा करें और दोहराएँ; अगर फिर भी न हो — kubectl top pods और kubectl describe hpa ${HPA}"
  evidence "HPA सक्रिय क्यों नहीं है" "${REASON:-स्टेटस में कारण नहीं बताया गया}"
fi

evidence "HPA की स्थिति" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server सीधे जवाब देता है --------------------------------------
# पिछली जाँच को दूसरी ओर से दोहराता है और दो अलग-अलग खराबियों को अलग करता है:
# «पूरे क्लस्टर में मेट्रिक्स नहीं हैं» और «मेट्रिक्स हैं, पर HPA उन तक नहीं पहुँचा»।
# पहला क्लस्टर एडमिनिस्ट्रेटर ठीक करता है, दूसरा प्रतिभागी अपने मैनिफ़ेस्ट में।
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` जब कोई पॉड नहीं होता तो «No resources found» छापता है और 0 लौटाता है —
# खालीपन की स्पष्ट जाँच के बिना यह वहाँ भी हरा देता था जहाँ मेट्रिक्स बिल्कुल नहीं हैं।
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top पॉड की खपत नहीं देता" \
       "क्लस्टर में कोई कार्यरत metrics-server नहीं है — उसके बिना CPU के आधार पर ऑटोस्केलिंग असंभव है"
  evidence "kubectl top का जवाब" "$TOP"
else
  ok "metrics-server ${APP} पॉड की खपत देता है"
  evidence "प्रतियों की खपत" "$TOP"
fi

# --- स्केलिंग वास्तव में चली थी --------------------------------------------
# lastScaleTime उतने ही समय तक जीवित रहता है जितना स्वयं HPA, इसलिए यह जाँच इस पर निर्भर नहीं करती
# कि क्लस्टर की घटनाएँ समाप्त हो चुकी हैं या नहीं।
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# अकेला एक टाइमस्टैम्प काफ़ी नहीं: यह प्रतियाँ घटाने पर भी लग जाता है, यानी
# उसके पास भी आ जाता है जिसने रेप्लिका हाथ से बढ़ाईं और HPA को अतिरिक्त हटाने दिया। हम ठीक
# लोड के कारण हुई वृद्धि ढूँढते हैं — सीमा पार करने वाली घटना।
#
# और इसके उलट: टाइमस्टैम्प खुद हमेशा जीवित नहीं रहता। जिस क्लस्टर पर एक घंटा पहले लोड दिया गया था,
# वहाँ lastScaleTime खाली हो सकता है जबकि घटनाएँ अभी जीवित हैं — इसलिए घटनाएँ
# पहले जाँची जाती हैं, वरना पूरी हुई लैब झूठे तौर पर फ़ेल हो जाती है।
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA ने लोड के कारण प्रतियों की संख्या बढ़ाई — सीमा पार करने वाली घटना अपनी जगह पर है"
  evidence "स्केलिंग" "वृद्धि की घटनाएँ: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-कोई नहीं}
currentReplicas: ${CUR_REPL:-अज्ञात}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA ने प्रतियों की संख्या बदली (आखिरी बार: ${LAST_SCALE})"
  evidence "स्केलिंग का टाइमस्टैम्प" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-अज्ञात}"
else
  fail "ऑटोस्केलिंग के काम करने का कोई निशान नहीं" \
       "Fortio से लोड दें: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: लैब 4 में ज़रूरी ------------------------------------------------
# लैब 3 से इसका अब कोई सरोकार नहीं, इसलिए warn, fail नहीं। मतलब यह है कि प्रतिभागी
# जनरेटर के गायब होने का पता यहीं लगा ले, न कि लोड के तहत रोलआउट के बीच में,
# जब रुककर उसे तैनात करना असुविधाजनक होगा।
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "लोड जनरेटर Fortio काम करता है और क्लस्टर के भीतर से जवाब देता है"
  else
    warn "Fortio तैनात है, पर उसका वेब-इंटरफ़ेस जवाब नहीं दिया" \
         "जाँचें: kubectl rollout status deployment/fortio और kubectl logs deploy/fortio"
  fi
else
  warn "क्लस्टर में Fortio नहीं है" \
       "अगर लैब 4 करने वाले हैं, तो वहाँ इसकी ज़रूरत होगी: kubectl apply -f fortio.yaml"
fi

finish
