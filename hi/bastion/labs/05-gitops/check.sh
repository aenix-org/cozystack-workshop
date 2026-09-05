#!/usr/bin/env bash
# लैब 5 की जाँच: क्लस्टर की स्थिति Git से आती है और सामंजस्य (reconciliation) द्वारा बनी रहती है।
#
# यह आपके `lab` क्लस्टर पर, लैब फ़ोल्डर से, आपके द्वारा चलाया जाता है:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# यह कुछ नहीं बदलता — केवल देखता है और एक रिपोर्ट छापता है: क्या जाँचा गया, क्या पास हुआ,
# क्या नहीं हुआ, और संलग्न प्रमाण।
#
# हम "Flux इंस्टॉल है" नहीं बल्कि "तंत्र काम करता है" जाँचते हैं: स्रोत पढ़ा जाता है, जो लागू
# किया गया वह Flux का है, सेवा जवाब देती है, सामंजस्य बंद नहीं है। इंस्टॉल किया गया पर
# निलंबित (suspended) Flux — लैब को पास करके उसका अर्थ चूकने का सबसे आम तरीका है।

LAB_NAME="05-gitops"
LAB_TITLE="लैब 5 · Git में इंफ्रास्ट्रक्चर"
# सभी लैब का साझा ढाँचा: इससे ok / fail / warn / evidence / finish और पर्यावरण जाँचें आती हैं।
# पथ इस फ़ाइल के स्थान के सापेक्ष निकाला जाता है, इसलिए स्क्रिप्ट किसी भी फ़ोल्डर से
# चलाई जा सकती है।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# क्लस्टर एक्सेस फ़ाइल के बिना जाँचने को कुछ नहीं है — स्पष्ट कारण के साथ तुरंत बाहर निकलें।
need_kubeconfig

# वे नाम जो यह लैब बनाती है। एक ही जगह इकट्ठा किए गए: यदि किसी प्रतिभागी ने ऑब्जेक्ट्स को
# अलग नाम दिया, तो पूरे स्क्रिप्ट में नाम ढूँढने के बजाय यहाँ संपादित करें।
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# किसी ऑब्जेक्ट का फ़ील्ड पढ़ें, और यदि ऑब्जेक्ट या CRD मौजूद न हो तो विफल न हों।
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux सेवाएँ -----------------------------------------------------------
# हम "पॉड मौजूद हैं" नहीं बल्कि "कम से कम एक प्रतिकृति Ready है" देखते हैं: कोई पॉड नोड पर
# मेमोरी न होने से Pending में अटका रह सकता है और फिर भी get pods आउटपुट में दिखता है।
# दोनों सेवाएँ अनिवार्य हैं और काम बाँटती हैं: source-controller रिपॉज़िटरी डाउनलोड करता है,
# kustomize-controller डाउनलोड किए गए को लागू करता है। दूसरे के बिना कुछ भी क्लस्टर तक नहीं पहुँचता।
if ! kget namespace flux-system >/dev/null; then
  fail "क्लस्टर में flux-system नेमस्पेस नहीं है" \
       "Flux इंस्टॉल नहीं है: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "Flux सेवाएँ चल रही हैं: source-controller और kustomize-controller"
    evidence "Flux पॉड" "$(kget pods -n flux-system -o wide)"
  else
    fail "Flux सेवाएँ नहीं चल रहीं:${FLUX_BAD}" \
         "kubectl get pods -n flux-system देखें; छोटे नोड पर उन्हें मेमोरी कम पड़ सकती है"
  fi
fi

# --- स्रोत: GitRepository ------------------------------------------------
# तीन अलग परिणाम, और इन्हें आपस में गड्डमड्ड नहीं करना चाहिए: ऑब्जेक्ट बिल्कुल मौजूद नहीं;
# ऑब्जेक्ट मौजूद है पर उसमें अभी भी पते का प्लेसहोल्डर है; ऑब्जेक्ट मौजूद है और पता असली है,
# पर Flux रिपॉज़िटरी नहीं पढ़ पाया। हर मामले में सलाह अलग है, इसलिए शाखाएँ भी अलग हैं।
#
# सफलता का संकेत हम status.conditions से लेते हैं — यह वही है जो Flux, Git तक पहुँचने की
# कोशिश के बाद, स्वयं अपने बारे में बताता है, न कि ऑब्जेक्ट की मौजूदगी पर हमारा अनुमान।
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "क्लस्टर में GitRepository प्रकार नहीं है" \
       "Flux इंस्टॉल नहीं है, या source-controller के बिना इंस्टॉल है"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "flux-system में ${GITREPO} नाम का कोई GitRepository नहीं मिला" \
         "flux/gitrepository.yaml को अपने रिपॉज़िटरी का पता भरकर लागू करें"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "GitRepository में अभी भी प्लेसहोल्डर पता है" \
         "flux/gitrepository.yaml खोलें और अपने GitHub रिपॉज़िटरी का पता दर्ज करें"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux आपका रिपॉज़िटरी पढ़ता है: ${GR_URL}"
    evidence "Git में स्रोत" "url: ${GR_URL}
revision: ${GR_REV:-अज्ञात}"
  else
    fail "Flux रिपॉज़िटरी ${GR_URL} नहीं पढ़ पा रहा" \
         "flux get sources git देखें; अक्सर यह पते में टाइपो, निजी रिपॉज़िटरी, या अलग ब्रांच होता है"
    evidence "स्रोत त्रुटि" "${GR_MSG:-कोई संदेश नहीं}"
  fi
fi

# --- लागू करना: Kustomization ----------------------------------------------
# यहाँ लागू होने का तथ्य नहीं, बल्कि तंत्र के तीन गुण जाँचे जाते हैं जिनके बिना लैब अपना अर्थ
# खो देती है: लागू किया गया रिविज़न Git से मेल खाता है, सामंजस्य निलंबित नहीं है, और
# रिपॉज़िटरी से गायब हुई चीज़ का हटाया जाना सक्षम है।
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "क्लस्टर में Kustomization प्रकार नहीं है" \
       "Flux kustomize-controller के बिना इंस्टॉल हुआ — दोनों घटकों के साथ पुनः इंस्टॉल करें"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "flux-system में ${KUSTOMIZATION} नाम का कोई Kustomization नहीं मिला" \
         "flux/kustomization.yaml लागू करें"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux ने Git से स्थिति लागू की, रिविज़न ${KS_REV}"
    evidence "लागू किया गया रिविज़न" "$KS_REV"
  else
    fail "Flux Git से स्थिति लागू नहीं कर पाया" \
         "flux get kustomizations और kubectl describe kustomization ${KUSTOMIZATION} -n flux-system देखें"
    evidence "लागू करने में त्रुटि" "${KS_MSG:-कोई संदेश नहीं}"
  fi

  # निलंबित Flux इंस्टॉल जैसा दिखता है और कुछ नहीं करता। यही लैब को उसका एक भी लाभ पाए बिना
  # "पास" करने का मुख्य तरीका है।
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "सामंजस्य निलंबित है (suspend: true) — Flux क्लस्टर पर नज़र नहीं रख रहा" \
         "इसे वापस चालू करें: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "सामंजस्य सक्रिय है: Git से विचलन स्वयं ठीक हो जाएगा, अंतराल ${KS_INTERVAL:-डिफ़ॉल्ट}"
  fi

  # यह warn है, fail नहीं: prune के बिना भी क्लस्टर Git से प्रबंधित होता है, लैब पास है।
  # पर विवरण एकतरफ़ा हो जाता है — फ़ाइल हटाने से क्लस्टर में कुछ नहीं हटता।
  if [ "$KS_PRUNE" = "true" ]; then
    ok "Git से गायब हुई चीज़ का हटाया जाना (prune) सक्षम है"
  else
    warn "prune बंद है — रिपॉज़िटरी से हटाई गई चीज़ क्लस्टर में चलती रहेगी" \
         "flux/kustomization.yaml में prune: true सेट करें, वरना Git स्थिति का केवल आधा हिस्सा वर्णित करता है"
  fi
fi

# --- क्लस्टर के ऑब्जेक्ट Flux के हैं, हाथ से लागू नहीं किए गए ---------
# यह लैब की मुख्य जाँच है, और यह मौजूदगी नहीं बल्कि उद्गम (provenance) के बारे में है। एप्लिकेशन
# क्लस्टर में दोनों स्थितियों में होता है: जब Flux उसे लाया, और जब प्रतिभागी ने वही फ़ाइलें
# kubectl apply से हाथ से लागू कीं। बाहर से इन्हें अलग नहीं किया जा सकता — Deployment एक जैसा है।
# स्वामी लेबल इन्हें अलग बताता है: इसे केवल kustomize-controller तब लगाता है जब वह रिपॉज़िटरी की
# सामग्री लागू करता है। हाथ से लागू किए गए ऑब्जेक्ट को वह लेबल नहीं मिलेगा।
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "${NS_APP} नेमस्पेस में passes एप्लिकेशन नहीं है" \
       "app/*.yaml को अपने रिपॉज़िटरी के apps फ़ोल्डर में रखें, push करें, और सामंजस्य की प्रतीक्षा करें"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "क्लस्टर में एप्लिकेशन Flux का है, हाथ से लागू नहीं किया गया"
else
  fail "passes एप्लिकेशन मौजूद है, पर उसे Flux ने नहीं बनाया" \
       "इसे हटाएँ (kubectl delete ns ${NS_APP}) और Flux को इसे Git से फिर तैनात करने दें"
fi

# --- एप्लिकेशन वास्तव में जवाब देता है --------------------------------------
# क्लस्टर में ऑब्जेक्ट और चालू सेवा अलग चीज़ें हैं: Deployment बन सकता है जबकि पॉड लूप में
# क्रैश होते रहें। इसलिए हम क्लस्टर के अंदर जाकर सेवा को उसके आंतरिक नाम से माँगते हैं —
# उसी पथ से जिससे पड़ोसी एप्लिकेशन उस तक पहुँचते।
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'गेस्ट पास'; then
  ok "«गेस्ट पास» सेवा क्लस्टर के अंदर HTTP पर जवाब देती है (चालू प्रतिकृतियाँ: ${PODS_READY})"
else
  fail "«गेस्ट पास» सेवा passes.${NS_APP}.svc.cluster.local पर जवाब नहीं देती" \
       "kubectl get pods -n ${NS_APP} और kubectl logs -n ${NS_APP} deploy/passes देखें"
fi

# पेज में पॉड का नाम वास्तव में चल रही प्रतिकृति से मेल खाना चाहिए: इससे पता चलता है कि जवाब
# ठीक उसी पॉड से आया जो हम क्लस्टर में देखते हैं, न कि कोई कैश्ड उत्तर या वही नाम संयोग से ले
# लेने वाली दूसरी सेवा। बेमेल warn है, fail नहीं: प्रतिकृति दो अनुरोधों के बीच फिर से बन सकती
# थी, और यह प्रतिभागी की गलती नहीं है।
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "पेज को वास्तव में मौजूद पॉड ${SERVED_POD} ने परोसा"
  evidence "सेवा की प्रतिकृतियाँ" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "जवाब में मिला पॉड ${SERVED_POD} चल रहे पॉड्स में नहीं मिला" \
       "संभवतः प्रतिकृति दो अनुरोधों के बीच फिर से बनी — जाँच दोबारा चलाएँ"
fi

# --- आपके रिपॉज़िटरी क्लोन में परिवर्तन का इतिहास ----------------------------
# वैकल्पिक हिस्सा: जब तक स्क्रिप्ट को न बताया जाए, वह नहीं जानती कि क्लोन कहाँ है।
# यहाँ रोलबैक का तरीका जाँचा जाता है। kubectl rollout undo से भी क्लस्टर पिछली संस्करण पर
# लौट जाता है, पर Git को इसका पता नहीं चलता, और अगला ही सामंजस्य खराब परिवर्तन वापस ले आता है।
# इसलिए हम इतिहास में revert ढूँढते हैं — रोलबैक वहीं किया जाता है जहाँ सच्चाई रहती है। और हम
# जाँचते हैं कि क्लस्टर में लागू रिविज़न आपके HEAD से मेल खाता है: कमिट करके push भूल जाना आम
# बात है, और बाहर से यह "Flux अटक गया" जैसा दिखता है।
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "रिपॉज़िटरी इतिहास नहीं जाँचा गया: LAB_REPO वेरिएबल सेट नहीं है" \
       "इसे भी जाँचने के लिए: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "${REPO} में रिपॉज़िटरी का कोई क्लोन नहीं है" \
       "उस फ़ोल्डर की ओर इंगित करें जिसमें आपने git clone किया था"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "इतिहास में git revert के ज़रिए रोलबैक है — खराब परिवर्तन वहीं रद्द किया गया जहाँ सच्चाई रहती है"
    evidence "परिवर्तन इतिहास" "$LOG"
  else
    fail "पिछले कमिट्स में एक भी revert नहीं है" \
         "खराब परिवर्तन को git revert --no-edit HEAD से रोलबैक करके push करें, न कि kubectl rollout undo से"
  fi

  # क्लस्टर में जो लागू है वह ब्रांच के अंतिम कमिट से मेल खाना चाहिए।
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "क्लस्टर में ठीक वही चल रहा है जो आपकी ब्रांच में है (कमिट ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "क्लस्टर का कमिट (${KS_REV:-अज्ञात}) स्थानीय HEAD (${HEAD_SHA}) से अलग है" \
         "जाँचें कि स्थानीय कमिट्स push किए गए हैं (git push), और सामंजस्य अंतराल की प्रतीक्षा करें"
  fi
fi

finish
