#!/usr/bin/env bash
# लैब 5 की जाँच: क्लस्टर की स्थिति Git से आती है और reconciliation द्वारा बनाए रखी जाती है।
#
# आपके `lab` क्लस्टर पर, लैब फ़ोल्डर से, आपके द्वारा चलाया जाता है:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# यह कुछ नहीं बदलता — केवल देखता है और एक रिपोर्ट छापता है: क्या जाँचा गया, क्या पास हुआ,
# क्या नहीं हुआ, और संलग्न साक्ष्य।
#
# हम "Flux इंस्टॉल है" नहीं जाँचते, बल्कि "तंत्र काम करता है": स्रोत पढ़ा जाता है, जो लागू
# हुआ है वह Flux का है, सेवा जवाब देती है, reconciliation बंद नहीं है। इंस्टॉल किया हुआ लेकिन
# निलंबित (suspended) Flux लैब को उसके मर्म से चूकते हुए पास करने का सबसे आम तरीका है।

LAB_NAME="05-gitops"
LAB_TITLE="लैब 5 · Git में इंफ्रास्ट्रक्चर"
# सभी लैब का साझा हार्नेस: इससे ok / fail / warn / evidence / finish और
# पर्यावरण जाँचें मिलती हैं। पथ इस फ़ाइल के स्थान से निकाला जाता है, इसलिए स्क्रिप्ट
# किसी भी फ़ोल्डर से चलाई जा सकती है।
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# क्लस्टर एक्सेस फ़ाइल के बिना जाँचने को कुछ नहीं — स्पष्ट कारण के साथ तुरंत बाहर निकलते हैं।
need_kubeconfig

# वे नाम जो लैब बनाती है। एक जगह इकट्ठा किए गए: अगर प्रतिभागी ने ऑब्जेक्ट्स को
# अलग नाम दिया हो, तो यहाँ ठीक करें, न कि पूरे स्क्रिप्ट में नाम खोजें।
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# ऑब्जेक्ट का एक फ़ील्ड पढ़ते हैं, अगर ऑब्जेक्ट या CRD न हो तो बिना विफल हुए।
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux सेवाएँ -----------------------------------------------------------
# हम "pods मौजूद हैं" नहीं देखते, बल्कि "कम से कम एक replica Ready है": एक pod
# नोड पर मेमोरी न होने से Pending में लटका रह सकता है और फिर भी get pods के आउटपुट में दिखे।
# दोनों सेवाएँ अनिवार्य हैं और काम बाँटती हैं: source-controller रिपॉज़िटरी डाउनलोड करता है,
# kustomize-controller डाउनलोड किए हुए को लागू करता है। दूसरे के बिना कुछ भी क्लस्टर तक नहीं पहुँचेगा।
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
    evidence "Flux के pods" "$(kget pods -n flux-system -o wide)"
  else
    fail "Flux सेवाएँ नहीं चल रही हैं:${FLUX_BAD}" \
         "देखें kubectl get pods -n flux-system; छोटे नोड पर उन्हें मेमोरी कम पड़ सकती है"
  fi
fi

# --- स्रोत: GitRepository ------------------------------------------------
# तीन अलग-अलग परिणाम, और उन्हें भ्रमित नहीं करना चाहिए: ऑब्जेक्ट बिलकुल नहीं है; ऑब्जेक्ट है, लेकिन उसमें
# पते की प्लेसहोल्डर रह गई है; ऑब्जेक्ट है और पता असली है, लेकिन Flux रिपॉज़िटरी नहीं
# पढ़ सका। हर मामले में सलाह अलग है, इसलिए शाखाएँ भी अलग हैं।
#
# सफलता का संकेत हम status.conditions से लेते हैं — यह वह है जो Flux स्वयं अपने बारे में
# Git तक पहुँचने की कोशिश के बाद बताता है, न कि ऑब्जेक्ट की मौजूदगी पर हमारा अनुमान।
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
    fail "flux-system में ${GITREPO} नाम का GitRepository नहीं मिला" \
         "flux/gitrepository.yaml लागू करें, अपने रिपॉज़िटरी का पता डालते हुए"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "GitRepository में प्लेसहोल्डर पता रह गया है" \
         "flux/gitrepository.yaml खोलें और GitHub पर अपने रिपॉज़िटरी का पता लिखें"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux आपका रिपॉज़िटरी पढ़ता है: ${GR_URL}"
    evidence "Git में स्रोत" "url: ${GR_URL}
revision: ${GR_REV:-अज्ञात}"
  else
    fail "Flux रिपॉज़िटरी ${GR_URL} नहीं पढ़ सकता" \
         "देखें flux get sources git; अक्सर यह पते में टाइपो, निजी रिपॉज़िटरी, या दूसरी शाखा होती है"
    evidence "स्रोत की त्रुटि" "${GR_MSG:-कोई संदेश नहीं}"
  fi
fi

# --- लागू करना: Kustomization ----------------------------------------------
# यहाँ लागू होने का तथ्य नहीं, बल्कि तंत्र के तीन गुण जाँचे जाते हैं, जिनके बिना लैब
# अपना अर्थ खो देती है: लागू की गई revision Git से मेल खाती है, reconciliation निलंबित नहीं है, और
# रिपॉज़िटरी से गायब हुए को हटाना सक्षम है।
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "क्लस्टर में Kustomization प्रकार नहीं है" \
       "Flux kustomize-controller के बिना इंस्टॉल है — दोनों कंपोनेंट के साथ फिर से इंस्टॉल करें"
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
    fail "flux-system में ${KUSTOMIZATION} नाम का Kustomization नहीं मिला" \
         "flux/kustomization.yaml लागू करें"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux ने Git से स्थिति लागू की, revision ${KS_REV}"
    evidence "लागू की गई revision" "$KS_REV"
  else
    fail "Flux Git से स्थिति लागू नहीं कर सका" \
         "देखें flux get kustomizations और kubectl describe kustomization ${KUSTOMIZATION} -n flux-system"
    evidence "लागू करने की त्रुटि" "${KS_MSG:-कोई संदेश नहीं}"
  fi

  # निलंबित Flux इंस्टॉल दिखता है और कुछ नहीं करता। यह लैब को "पास" करने का मुख्य
  # तरीका है, उसका एक भी लाभ पाए बिना।
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "reconciliation निलंबित है (suspend: true) — Flux क्लस्टर पर नज़र नहीं रख रहा" \
         "वापस चालू करें: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "reconciliation सक्रिय है: Git से विचलन अपने आप ठीक होगा, अंतराल ${KS_INTERVAL:-डिफ़ॉल्ट}"
  fi

  # यह warn है, fail नहीं: prune के बिना भी क्लस्टर Git से प्रबंधित होता है, लैब पास है।
  # लेकिन विवरण एकतरफ़ा हो जाता है — फ़ाइल हटाने से क्लस्टर में कुछ नहीं हटता।
  if [ "$KS_PRUNE" = "true" ]; then
    ok "Git से गायब हुए को हटाना सक्षम है (prune)"
  else
    warn "prune बंद है — रिपॉज़िटरी से हटाया गया क्लस्टर में चलता रहेगा" \
         "flux/kustomization.yaml में prune: true सेट करें, वरना Git स्थिति का केवल आधा वर्णन करता है"
  fi
fi

# --- क्लस्टर में ऑब्जेक्ट्स Flux के हैं, हाथ से लागू नहीं किए गए ---------
# यह लैब की मुख्य जाँच है, और यह उत्पत्ति के बारे में है, मौजूदगी के बारे में नहीं। एप्लिकेशन
# दोनों मामलों में क्लस्टर में होता है: चाहे उसे Flux लाया हो, या प्रतिभागी ने
# वही फ़ाइलें kubectl apply से हाथ से लागू की हों। बाहर से अंतर नहीं दिखता — Deployment एक जैसा है।
# मालिक का label अंतर बताता है: इसे केवल kustomize-controller लगाता है, जब वह
# रिपॉज़िटरी की सामग्री लागू करता है। हाथ से लागू किए ऑब्जेक्ट को यह label नहीं मिलता।
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "नेमस्पेस ${NS_APP} में passes एप्लिकेशन नहीं है" \
       "app/*.yaml को अपने रिपॉज़िटरी के apps फ़ोल्डर में रखें, push करें और reconciliation की प्रतीक्षा करें"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "क्लस्टर में एप्लिकेशन Flux का है, हाथ से लागू नहीं किया गया"
else
  fail "passes एप्लिकेशन मौजूद है, लेकिन उसे Flux ने नहीं बनाया" \
       "इसे हटाएँ (kubectl delete ns ${NS_APP}) और Flux को इसे Git से फिर से तैनात करने दें"
fi

# --- एप्लिकेशन वास्तव में जवाब देता है --------------------------------------
# क्लस्टर में ऑब्जेक्ट और चलती हुई सेवा अलग चीज़ें हैं: Deployment बन सकता है,
# जबकि pods लूप में क्रैश होते रहें। इसलिए हम क्लस्टर के भीतर जाते हैं और सेवा को उसके
# आंतरिक नाम से अनुरोध करते हैं — उसी पथ से जिससे पड़ोसी एप्लिकेशन उस तक पहुँचते।
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'गेस्ट पास'; then
  ok "«गेस्ट पास» सेवा क्लस्टर के भीतर HTTP पर जवाब देती है (चलती replicas: ${PODS_READY})"
else
  fail "«गेस्ट पास» सेवा passes.${NS_APP}.svc.cluster.local पर जवाब नहीं देती" \
       "देखें kubectl get pods -n ${NS_APP} और kubectl logs -n ${NS_APP} deploy/passes"
fi

# पेज पर pod का नाम वास्तव में चल रही replica से मेल खाना चाहिए: इससे दिखता है
# कि जवाब ठीक उसी pod से आता है जिसे हम क्लस्टर में देखते हैं, न कि कैश किया गया
# जवाब या कोई दूसरी सेवा जिसने संयोग से वही नाम ले लिया। बेमेल warn है, fail
# नहीं: दो अनुरोधों के बीच replica फिर से बन सकती थी, और यह प्रतिभागी की गलती नहीं है।
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "पेज वास्तव में मौजूद pod ${SERVED_POD} ने दिया"
  evidence "सेवा की replicas" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "जवाब में मिला pod ${SERVED_POD} चल रहे pods में नहीं मिला" \
       "संभवतः दो अनुरोधों के बीच replica फिर से बन गई — जाँच फिर से चलाएँ"
fi

# --- आपके रिपॉज़िटरी क्लोन में परिवर्तनों का इतिहास ----------------------------
# वैकल्पिक हिस्सा: स्क्रिप्ट को तब तक नहीं पता कि क्लोन कहाँ है जब तक बताया न जाए।
# यहाँ रोलबैक का तरीका जाँचा जाता है। kubectl rollout undo से भी क्लस्टर पिछले
# संस्करण पर लौट आएगा, पर Git को इसका पता नहीं चलेगा, और अगली ही reconciliation खराब
# परिवर्तन को वापस ले आएगी। इसलिए हम इतिहास में revert खोजते हैं — रोलबैक वहाँ किया जाता
# है जहाँ सच्चाई रहती है। और हम जाँचते हैं कि क्लस्टर में लागू revision आपके HEAD से मेल खाती है:
# commit करके push भूल जाना आम बात है, और बाहर से यह "Flux अटक गया" जैसा दिखता है।
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "रिपॉज़िटरी का इतिहास नहीं जाँचा गया: LAB_REPO वेरिएबल सेट नहीं है" \
       "इसे भी जाँचने के लिए: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "${REPO} में रिपॉज़िटरी का क्लोन नहीं है" \
       "वह फ़ोल्डर बताएँ जिसमें आपने git clone किया था"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "इतिहास में git revert के ज़रिए रोलबैक है — खराब परिवर्तन वहाँ रद्द किया गया जहाँ सच्चाई रहती है"
    evidence "परिवर्तनों का इतिहास" "$LOG"
  else
    fail "हाल के commits में एक भी revert नहीं है" \
         "खराब परिवर्तन को git revert --no-edit HEAD से रोलबैक करें और push करें, न कि kubectl rollout undo से"
  fi

  # क्लस्टर में लागू किया गया शाखा के अंतिम commit से मेल खाना चाहिए।
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "क्लस्टर में ठीक वही चलता है जो आपकी शाखा में है (commit ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "क्लस्टर में commit (${KS_REV:-अज्ञात}) स्थानीय HEAD (${HEAD_SHA}) से अलग है" \
         "जाँचें कि स्थानीय commits भेजे गए हैं (git push), और reconciliation अंतराल की प्रतीक्षा करें"
  fi
fi

finish
