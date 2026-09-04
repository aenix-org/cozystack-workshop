#!/usr/bin/env bash
# लैब 14 की जाँच: ऑब्ज़र्वेबिलिटी वास्तव में काम करती है।
#
# «प्रतिभागी ने ग्राफ़ देखा» — इसकी जाँच नहीं की जा सकती, और यह दिखावा करना कि की जा सकती है, बेईमानी है।
# इसलिए हम वह जाँचते हैं जिसके बिना ग्राफ़ संभव ही नहीं है:
#   1) मेट्रिक्स संग्रह एजेंट क्लस्टर में चल रहा है,
#   2) वह जो इकट्ठा करता है उसे आपके टेनेंट को भेजता है, शून्य में नहीं,
#   3) लॉग संग्रह भी काम करता है — इसके बिना आधी लैब बेमानी है,
#   4) क्लस्टर में लैब 3 के लोड का निशान है, जिसे ग्राफ़ में खोजा जा सकता है।

LAB_NAME="14-observability"
LAB_TITLE="लैब 14 · ऑब्ज़र्वेबिलिटी: ग्राफ़ में अपना स्पाइक खोजें"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- संग्रह namespace -------------------------------------------------------
# Namespace अपने आप में कुछ साबित नहीं करता: प्लेटफ़ॉर्म वहीं metrics-server भी रखता है,
# जो etcd वाले किसी भी क्लस्टर पर इंस्टॉल होता है और ऐडऑन पर निर्भर नहीं करता। हम इसकी
# उपस्थिति केवल इसलिए जाँचते हैं ताकि «क्लस्टर अनुपलब्ध» को «संग्रह बंद है» से अलग किया जा सके।
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "क्लस्टर में namespace ${MON_NS} नहीं है — क्लस्टर ने अपेक्षा के अनुसार जवाब नहीं दिया" \
       "ऐडऑन चालू करें: डैशबोर्ड -> Kubernetes -> lab -> संपादित करें -> Addons -> Monitoring agents. ध्यान दें: रिकॉर्ड इसी क्षण से दिखेंगे"
  finish
  exit $?
fi

# --- मेट्रिक्स एजेंट ---------------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "मेट्रिक्स संग्रह एजेंट चल रहा है (vmagent पॉड: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "मेट्रिक्स संग्रह एजेंट मौजूद है, पर चल नहीं रहा (${VMAGENT_TOTAL} में से ${VMAGENT_RUNNING} Running में)" \
       "कारण देखें: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "${MON_NS} में एक भी vmagent पॉड नहीं है — Monitoring agents ऐडऑन बंद है" \
       "इसे चालू करें: डैशबोर्ड -> Kubernetes -> lab -> संपादित करें -> Addons -> Monitoring agents. रिकॉर्ड इसी क्षण से जमा होना शुरू होंगे, बीता हुआ वापस नहीं आएगा"
fi
evidence "${MON_NS} में संग्रह पॉड" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- मेट्रिक्स आख़िर जाती कहाँ हैं ------------------------------------------
# एक चालू एजेंट जो शून्य में लिखता है, बिल्कुल एक कार्यशील एजेंट जैसा ही दिखता है।
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "मेट्रिक्स टेनेंट को भेजी जा रही हैं${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "मेट्रिक्स ऐसे पते पर भेजी जा रही हैं जो टेनेंट पते जैसा नहीं दिखता" \
           "यह ठीक हो सकता है यदि होस्ट ने साझा भंडारण सेट किया हो; पता साक्ष्य में है"
      ;;
  esac
  evidence "मेट्रिक्स कहाँ भेजी जाती हैं" "$RW_URL"
else
  warn "मेट्रिक्स भेजने का पता पढ़ा नहीं जा सका" \
       "हाथ से देखें: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- लॉग संग्रह -------------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "लॉग संग्रह सभी नोड्स पर काम कर रहा है (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "लॉग संग्रह सभी नोड्स पर नहीं चल रहा (${FB_DESIRED} में से ${FB_READY:-0})" \
       "देखें: kubectl -n ${MON_NS} get pods | grep fluent-bit — इसके बिना लॉग-खोज वाला चरण काम नहीं करेगा"
else
  warn "fluent-bit लॉग कलेक्टर नहीं मिला" \
       "Grafana में vlogs-generic स्रोत खाली रहेगा; लॉग-खोज वाला चरण पूरा नहीं किया जा सकेगा"
fi

# --- ग्राफ़ में खोजने के लिए कुछ है भी या नहीं ------------------------------
# मेट्रिक्स बिल्कुल सही ढंग से इकट्ठा हो सकती हैं, पर यदि कोई लोड नहीं था, तो खोजने के लिए कुछ नहीं है।
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "लोड का निशान है: ऑटोस्केलिंग सक्रिय हुई थी (आख़िरी बार ${LAST_SCALE})"
    evidence "ऑटोस्केलिंग की स्थिति" "$(kubectl get hpa rickroll 2>/dev/null)
आख़िरी बार सक्रिय हुई: ${LAST_SCALE}
अभी कॉपियाँ: ${CUR:-?}, आवश्यक: ${DES:-?}"
  else
    warn "ऑटोस्केलिंग कॉन्फ़िगर है, पर एक बार भी सक्रिय नहीं हुई" \
         "कॉपियों की वृद्धि वाली सीढ़ी आपको नहीं मिलेगी; लैब 3 का लोड fortio जनरेटर से दोहराएँ"
  fi
else
  warn "क्लस्टर में rickroll नाम का कोई HorizontalPodAutoscaler नहीं है" \
       "इस लैब के ग्राफ़ वाले चरण लैब 3 पर निर्भर हैं; उसके बिना आपको केवल CPU स्पाइक मिलेगा, सीढ़ी नहीं"
fi

# --- स्वयं एप्लिकेशन की मेट्रिक्स --------------------------------------------
# अप्रत्यक्ष, पर सारगर्भित: यदि एप्लिकेशन के पॉड जीवित हैं, तो उनका उपभोग ग्राफ़ में है।
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "एप्लिकेशन के पॉड मौजूद हैं (${APP_PODS} अदद) — उनका उपभोग ग्राफ़ में दिखता है"
  evidence "एप्लिकेशन के पॉड" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "क्लस्टर में rickroll एप्लिकेशन के कोई पॉड नहीं हैं" \
       "लैब 3 के समय की ऐतिहासिक मेट्रिक्स फिर भी सुरक्षित हैं; बस Grafana में वह समय-सीमा सेट करें"
fi

# --- Grafana कहाँ खोजें -----------------------------------------------------
# जाँच नहीं, बल्कि मदद: Grafana का पता प्रतिभागी सबसे ज़्यादा देर तक ढूँढते हैं।
: "${COZY_KUBECONFIG:=$HOME/.kube/config}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "आपकी मेट्रिक्स के लिए Grafana: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
टेनेंट ${TNS} की मेट्रिक्स namespace ${MON_TARGET} में संग्रहीत हैं"
    else
      warn "आपके टेनेंट की मॉनिटरिंग ${MON_TARGET} में रहती है, पर Grafana का पता पढ़ा नहीं जा सका" \
           "यदि ${MON_TARGET} आपका namespace नहीं है, तो Grafana साझा है: पता होस्ट से पूछें"
      evidence "टेनेंट की मॉनिटरिंग" "मॉनिटरिंग वाला namespace: ${MON_TARGET}"
    fi
  else
    warn "यह निर्धारित नहीं किया जा सका कि टेनेंट ${TNS} की मेट्रिक्स कहाँ जाती हैं" \
         "Grafana का पता होस्ट से पूछें या डैशबोर्ड में खोजें: Monitoring एप्लिकेशन -> Ingress"
  fi
else
  warn "Grafana का पता निर्धारित नहीं हुआ" \
       "COZY_TENANT और COZY_KUBECONFIG सेट करें, और स्क्रिप्ट इसे स्वयं खोज लेगी; इससे लैब पास करने पर कोई असर नहीं पड़ता"
fi

finish
