#!/usr/bin/env bash
# लैब 0 की जाँच: प्रशिक्षण क्लस्टर चालू है और आप उससे जुड़ चुके हैं।
#
# हम "ऑब्जेक्ट बन गया" नहीं जाँचते, बल्कि यह जाँचते हैं कि क्लस्टर वास्तव में काम करता है:
#   1) lab क्लस्टर आपकी एक्सेस फ़ाइल के ज़रिए जवाब देता है (KUBECONFIG=~/lab.kubeconfig),
#   2) कम-से-कम एक नोड Ready स्थिति में है,
#   3) नोड्स पर भविष्य के एप्लिकेशन के लिए खाली संसाधन हैं।
# अगर COZY_TENANT सेट है — तो अतिरिक्त रूप से MANAGEMENT क्लस्टर पर जाँचते हैं कि
# Kubernetes/lab ऑर्डर Ready तक पहुँचा और मेट्रिक्स संग्रह सक्षम है (इसके बिना लैब 14 खाली रहती है)।
#
# इसे VM पर, इस लैब के फ़ोल्डर से चलाएँ:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # टेनेंट-साइड जाँचों के लिए (वैकल्पिक)
#     cd labs/00-cluster && ./check.sh
#
# स्क्रिप्ट केवल पढ़ती है — यह क्लस्टर की स्थिति नहीं बदलती।
LAB_NAME="00-cluster"
LAB_TITLE="लैब 0 · आपका अपना Kubernetes क्लस्टर"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# lab क्लस्टर तक पहुँच के बिना जाँचने को कुछ नहीं है — यही लैब का मुख्य
# प्रमाण है। अगर KUBECONFIG सेट नहीं है या क्लस्टर जवाब नहीं देता, तो
# need_kubeconfig स्क्रिप्ट को स्पष्ट संकेत के साथ रोक देगा।
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) lab क्लस्टर से कनेक्शन ------------------------------------------------
# need_kubeconfig पहले ही सुनिश्चित कर चुका है कि सर्वर जवाब देता है। इसे एक अलग
# परिणाम के रूप में दर्ज करते हैं और सर्वर संस्करण को रिपोर्ट में डालते हैं।
KVER="$(server_version)"
ok "lab क्लस्टर जवाब देता है — एक्सेस फ़ाइल काम कर रही है"
[ -n "$KVER" ] && evidence "lab क्लस्टर का सर्वर संस्करण" "$KVER"

# --- 2) नोड्स सेवा में -------------------------------------------------------
# गिनते हैं कि कितने नोड Ready स्थिति में हैं। खाली सूची का मतलब है कि क्लस्टर
# चालू है, पर md0 नोड समूह अभी भी तैनात हो रहा है।
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "नोड्स सेवा में: ${TOTAL_NODES} में से ${READY_NODES} Ready स्थिति में"
  [ -n "$NODES_WIDE" ] && evidence "क्लस्टर नोड्स" "$NODES_WIDE"
else
  fail "कोई भी नोड Ready स्थिति में नहीं है (कुल नोड्स: ${TOTAL_NODES:-0})" \
       "md0 नोड समूह के तैनात होने तक कुछ मिनट प्रतीक्षा करें; स्थिति lab एप्लिकेशन के डैशबोर्ड में है, या: kubectl get nodes"
  evidence "क्लस्टर नोड्स" "${NODES_WIDE:-कोई नोड नहीं}"
fi

# --- 3) क्या भविष्य के एप्लिकेशन के लिए जगह है -------------------------------
# पहले नोड का allocatable: अगर संसाधन नहीं हैं, तो आगे कुछ भी शुरू नहीं होगा।
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "नोड्स पर एप्लिकेशन के लिए संसाधन हैं (नोड पर: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "खाली नोड संसाधन (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "नोड्स के खाली संसाधन पढ़े नहीं जा सके" \
       "आमतौर पर यह अस्थायी होता है — एक मिनट बाद फिर प्रयास करें"
fi

# --- 4) management क्लस्टर की ओर से (अगर टेनेंट सेट है) -----------------------
# लैब 0 के लिए ज़रूरी नहीं: ऊपर क्लस्टर से सीधा कनेक्शन पहले ही सब कुछ साबित कर चुका है।
# पर अगर टेनेंट एक्सेस उपलब्ध है — तो ऑर्डर की पुष्टि और मेट्रिक्स संग्रह की जाँच करते हैं।
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "टेनेंट एक्सेस ${COZY_KUBECONFIG} नहीं मिला — management क्लस्टर पर क्लस्टर ऑर्डर की जाँच नहीं हुई" \
         "यह लैब की विफलता नहीं है; पथ इस तरह सेट होता है: export COZY_KUBECONFIG=~/.kube/config"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "management क्लस्टर पर Kubernetes/lab ऑर्डर Ready स्थिति में है"
    elif [ -n "$LAB_READY" ]; then
      warn "Kubernetes/lab ऑर्डर अभी Ready नहीं है (अभी: ${LAB_READY})" \
           "क्लस्टर पहले से जवाब देता है, प्लेटफ़ॉर्म अभी भी उसे वांछित स्थिति में समेट रहा है; देखें: kubectl --kubeconfig ~/.kube/config -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "टेनेंट ${TENANT_NS} में Kubernetes/lab ऑर्डर नहीं मिला" \
           "अगर आपने क्लस्टर को कोई और नाम दिया है — तो अपना नाम डालें; या टेनेंट में भूमिका इस कमांड की अनुमति नहीं देती (लैब की त्रुटि नहीं)"
    fi
    # मेट्रिक्स संग्रह: लैब 14 उन डेटा पर निर्भर है जो सक्षम होने के क्षण से जमा होता है।
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "मेट्रिक्स संग्रह सक्षम है (लैब 14 में आवश्यक)"
    elif [ -n "$LAB_READY" ]; then
      warn "मेट्रिक्स संग्रह अक्षम है — लैब 14 बिना डेटा के रह जाएगी" \
           "सक्षम करने के लिए: डैशबोर्ड → lab एप्लिकेशन → Addons → Monitoring agents (मेट्रिक्स पिछली तारीख से नहीं आएँगे)"
    fi
  fi
else
  warn "COZY_TENANT सेट नहीं है — management-क्लस्टर-साइड जाँचें छोड़ दी गईं" \
       "लैब 0 के लिए ज़रूरी नहीं; सक्षम करने के लिए: export COZY_TENANT=workshopXX"
fi

finish
