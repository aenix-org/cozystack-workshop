#!/usr/bin/env bash
# लैब 10 की जाँच: MongoDB में अलग-अलग रूप के पास रखे हैं और उनके ज़रिए खोज होती है।
#
# हम "सेवा बन गई" नहीं, बल्कि असल बात जाँचते हैं: कलेक्शन में चारों रूपों के दस्तावेज़
# हैं, नेस्टेड फ़ील्ड और सूची के भीतर खोज काम करती है, किसी दुर्लभ फ़ील्ड पर स्पार्स
# इंडेक्स बना है, स्कीमा वैलिडेटर चालू है, और बिना टाइप वाला कोई दस्तावेज़ नहीं बचा है।
#
# चलाना (हर नई टर्मिनल विंडो में वेरिएबल दोबारा सेट किए जाते हैं):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX की जगह अपना नंबर
#   export MONGO_PASSWORD='passapp उपयोगकर्ता का पासवर्ड'
#   cd labs/10-mongodb && ./check.sh
#
# पासवर्ड न छपता है और न रिपोर्ट में आता है।
# स्क्रिप्ट एक-बार वाले पॉड उठाती है, इसलिए इसमें करीब एक मिनट लगता है।

# नाम और शीर्षक साझा लाइब्रेरी को चाहिए: वह इन्हीं से रिपोर्ट-आर्टिफ़ैक्ट पर हस्ताक्षर करती है।
# lib.sh में ok/fail/warn/evidence/finish और नीचे दी गई एनवायरनमेंट जाँचें हैं — ताकि
# पंद्रह जाँच स्क्रिप्ट एक जैसा छापें, हर एक अपने-अपने ढंग से नहीं।
LAB_NAME="10-mongodb"
LAB_TITLE="लैब 10 · डॉक्यूमेंट स्टोर"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# दोनों जाँचें स्क्रिप्ट को साफ़ संदेश के साथ रोक देती हैं अगर क्लस्टर-एक्सेस फ़ाइल
# या टेनेंट नंबर सेट न हो। उनके बिना आगे kubectl की त्रुटियाँ जमा होती जातीं।
need_kubeconfig
need_tenant

# प्रतिभागी COZY_TENANT को `workshop07` के रूप में सेट करता है, जबकि namespace को
# `tenant-workshop07` कहा जाता है। हम दोनों वर्तनियाँ स्वीकार करते हैं।
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# डिफ़ॉल्ट नाम वही हैं जो लैब में हैं। रूप ${X:-value} का अर्थ है "एनवायरनमेंट वेरिएबल
# लो, और अगर वह न हो तो value रख दो": अगर आपने ऐप को अलग नाम दिया है — तो इसे
# MONGO_APP=name ./check.sh के रूप में चलाइए, स्क्रिप्ट बदलने की ज़रूरत नहीं।
# पता आंतरिक है, स्वयं क्लस्टर से; नाम में rs0 वह रेप्लिका सेट है जिसमें हमारी
# इकलौती कॉपी रहती है।
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "MongoDB पता" "$MONGO_HOST"

# --- 1. पोर्ट तक कोई कनेक्टिविटी है भी या नहीं -----------------------------
# MongoDB अपने पोर्ट पर HTTP अनुरोध का उत्तर एक साफ़ वाक्य से देती है कि यहाँ
# ड्राइवर से पहुँचा जाता है, ब्राउज़र से नहीं। इतना काफ़ी है यह अलग करने के लिए कि
# "नाम रिज़ॉल्व नहीं होता / पोर्ट बंद है" बनाम "कनेक्टिविटी है, रीक्रेडेंशियल ग़लत हैं"।
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB टेनेंट के आंतरिक पते पर उत्तर देती है"
else
  fail "पते ${MONGO_HOST} पर MongoDB तक कोई कनेक्टिविटी नहीं" \
       "COZY_TENANT में टेनेंट नंबर और ऐप का नाम जाँचें (डिफ़ॉल्ट 'passes'; अन्यथा MONGO_APP=name ./check.sh); डैशबोर्ड में ऐप ready स्थिति में होना चाहिए"
  finish
  exit $?
fi

# आगे का सब कुछ डेटाबेस में लॉगिन माँगता है। पासवर्ड के बिना स्क्रिप्ट न अनुमान लगाती है
# और न चुप रहती है, बल्कि ईमानदारी से कहती है कि डेटाबेस की सामग्री जाँची नहीं गई, और
# रिपोर्ट समाप्त कर देती है: वरना प्रतिभागी समझ लेता कि जाँच पास हो गई।
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "MONGO_PASSWORD वेरिएबल सेट नहीं है, डेटाबेस की सामग्री जाँची नहीं गई" \
       "export MONGO_PASSWORD='${MONGO_USER} उपयोगकर्ता का पासवर्ड' और स्क्रिप्ट दोबारा चलाएँ"
  finish
  exit $?
fi

# पासवर्ड को प्रतिशत-एन्कोड किया जाता है: उसमें मौजूद @ : / ? # % वर्ण वरना कनेक्शन
# स्ट्रिंग को तोड़ देते, और व्यक्ति को "ग़लत पासवर्ड" के बजाय एक अस्पष्ट पार्स त्रुटि मिलती।
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ कनेक्शन स्ट्रिंग में पासवर्ड है और यह पॉड आर्ग्युमेंट के रूप में भेजी जाती है। यह एक सोचा-समझा
# समझौता है: check/lib.sh में `in_cluster_with_secrets` देखें — सुरक्षित रास्ता मौजूद है, पर
# बिना ओवरकॉम्प्लिकेशन के वह बहु-पंक्ति --eval के साथ असंगत है। पॉड सेकंडों जीता है और
# अपने पीछे साफ़ हो जाता है; पासवर्ड रिपोर्ट में नहीं आता। प्रोडक्शन स्क्रिप्ट में ऐसा न करें।
#
# सभी जाँचें एक ही बार में: हर कॉल एक पॉड उठाती है, और लगातार दस पॉड
# जाँच को बेवजह कई-मिनट के इंतज़ार में बदल देते।
# बाहर JSON की एक पंक्ति भेजी जाती है, जिसे बाद में python पार्स करता है।
# `--overrides` securityContext के साथ: उसके बिना `restricted` प्रोफ़ाइल वाले क्लस्टर में पॉड
# बनता ही नहीं, और लैब प्रतिभागी से असंबंधित किसी कारण से फ़ेल हो जाती।
# `--command --` बना रहता है: kubectl इसे override के साथ जोड़ देता है, जहाँ केवल
# सुरक्षा फ़ील्ड सेट हैं।
# mongosh के लिए प्रोग्राम। इसके भीतर दोहरे उद्धरण सुरक्षित हैं: पाठ बाहर python के
# ज़रिए जाता है, जो उसे स्वयं उद्धृत कर देता है, और डेटाबेस व कलेक्शन के नाम नीचे दिए
# मार्करों से प्रतिस्थापित होते हैं।
MONGO_EVAL=$(cat <<'JSEOF'

var out = {};
try {
  var c = db.getSiblingDB("__DB__").getCollection("__COLL__");
  out.ok = 1;
  out.total = c.countDocuments({});
  out.types = c.distinct("type").length;
  out.withCar = c.countDocuments({ "car.plate": { $exists: true } });
  out.withArray = c.countDocuments({
    $or: [ { entrances: { $exists: true } }, { members: { $exists: true } } ]
  });
  out.nested = c.countDocuments({ "members.name": { $exists: true } });
  out.typeless = c.countDocuments({ type: { $exists: false } });
  var idx = c.getIndexes();
  out.indexes = idx.map(function (i) { return i.name; });
  out.sparse = idx.filter(function (i) {
    return i.sparse === true || i.partialFilterExpression !== undefined;
  }).map(function (i) { return i.name; });
  var info = db.getSiblingDB("__DB__").getCollectionInfos({ name: "__COLL__" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
JSEOF
)
MONGO_EVAL="${MONGO_EVAL//__DB__/$MONGO_DB}"
MONGO_EVAL="${MONGO_EVAL//__COLL__/$MONGO_COLL}"

# कंटेनर कमांड override के भीतर रखी जाती है, `--command --` में बाहर नहीं छोड़ी जाती।
# kubectl override को JSON merge patch के रूप में लागू करता है, और उसमें containers सरणी
# पूरी की पूरी बदल दी जाती है: बाहर सेट किया गया `--command` पॉड तक नहीं पहुँचता, और mongosh के
# बजाय इमेज की डिफ़ॉल्ट प्रोसेस शुरू हो जाती — यानी स्वयं डेटाबेस। check/lib.sh में भी यह इसी तरह किया गया है।
MONGO_SC="$(python3 - "$MONGO_URI" "$MONGO_EVAL" <<'PYEOF'
import json, sys
uri, script = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {
  "securityContext": {"runAsNonRoot": True, "runAsUser": 999,
                      "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "mongo-check", "image": "mongo:8.0", "stdin": True,
                  "securityContext": {"allowPrivilegeEscalation": False,
                                      "capabilities": {"drop": ["ALL"]}},
                  "command": ["mongosh", "--quiet", uri, "--eval", script]}]}}))
PYEOF
)"

SUMMARY="$(kubectl run "mongo-check" --rm -i --restart=Never --quiet \
  --pod-running-timeout=90s --overrides="$MONGO_SC" \
  --image=mongo:8.0 </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

# mongosh द्वारा छापी गई JSON स्ट्रिंग से एक फ़ील्ड निकालना। सूचियाँ अल्पविराम से जोड़ी
# जाती हैं, ताकि उन्हें प्रतिभागी को जैसे-का-तैसा दिखाया जा सके।
mget() {
  printf '%s' "$SUMMARY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v if not isinstance(v, list) else ", ".join(str(x) for x in v))
' "$1" 2>/dev/null
}

# वही, पर संख्याओं के लिए: कोई भी अप्रत्याशित मान 0 में बदल जाता है, वरना नीचे की तुलना
# साफ़ FAIL के बजाय अंकगणित त्रुटि के साथ गिर जाती।
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# अगर उत्तर बिल्कुल न हो या mongosh ने कोई त्रुटि बताई हो — तो आगे जाँचने को कुछ नहीं।
# प्रमाणीकरण अस्वीकृति को अन्य त्रुटियों से अलग रखा गया है: उसका अपना एक आम कारण है —
# भूला हुआ authSource=admin, और संकेत को ठीक उसी की ओर ले जाना चाहिए।
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB ने ${MONGO_USER} उपयोगकर्ता के रीक्रेडेंशियल स्वीकार नहीं किए" \
           "पासवर्ड जाँचें और यह कि कनेक्शन स्ट्रिंग में authSource=admin है: उपयोगकर्ता admin डेटाबेस में बनाया गया है, जबकि अधिकार ${MONGO_DB} में दिए गए हैं" ;;
    *)
      fail "${MONGO_DB} डेटाबेस पर क्वेरी चलाने में विफल${ERR:+: $ERR}" \
           "हाथ से जाँचें: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "${MONGO_USER} उपयोगकर्ता के रूप में ${MONGO_DB} डेटाबेस से कनेक्शन काम करता है"

# --- 2. दस्तावेज़ मौजूद हैं ---------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "${MONGO_COLL} कलेक्शन में दस्तावेज़: ${TOTAL}"
else
  fail "${MONGO_COLL} कलेक्शन में केवल ${TOTAL} दस्तावेज़ हैं, कम से कम चार अपेक्षित थे" \
       "पास लोड करें: mo < passes.js (फ़ाइल का विवरण README में है)"
fi

# --- 3. रूप सचमुच अलग-अलग हैं ------------------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "कलेक्शन में ${TYPES} अलग-अलग पास प्रकार हैं"
else
  fail "केवल ${TYPES} अलग-अलग पास प्रकार, चार अपेक्षित थे" \
       "जाँचें कि passes.js पूरा लोड हुआ: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "नेस्टेड ऑब्जेक्ट (car.plate) वाले दस्तावेज़ हैं: ${WITH_CAR}"
else
  fail "नेस्टेड car ऑब्जेक्ट वाला एक भी दस्तावेज़ नहीं" \
       "कार पास लोड नहीं हुआ; mo < passes.js दोहराएँ"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "सूचियों (entrances और members) वाले दस्तावेज़ हैं: ${WITH_ARRAY}"
else
  fail "सूचियों वाले दस्तावेज़ ${WITH_ARRAY}, कम से कम दो अपेक्षित थे" \
       "साप्ताहिक और समूह पास लोड नहीं हुए; mo < passes.js दोहराएँ"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "ऑब्जेक्ट की सूची के भीतर खोज (members.name) दस्तावेज़ ढूँढ़ती है"
else
  fail "members.name द्वारा खोज को कुछ नहीं मिला" \
       "सदस्य-सूची वाला समूह पास लोड नहीं हुआ; mo < passes.js दोहराएँ"
fi

evidence "कलेक्शन की संरचना" "दस्तावेज़: ${TOTAL}
अलग-अलग पास प्रकार: ${TYPES}
नेस्टेड car ऑब्जेक्ट के साथ: ${WITH_CAR}
सूचियों के साथ: ${WITH_ARRAY}"

# --- 4. दुर्लभ फ़ील्ड पर इंडेक्स --------------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "स्पार्स (या पार्शियल) इंडेक्स बना है: ${SPARSE}"
  evidence "कलेक्शन के इंडेक्स" "सभी: ${IDX}
स्पार्स: ${SPARSE}"
else
  fail "कोई स्पार्स इंडेक्स नहीं — कार नंबर से खोज पूरे स्कैन के रूप में चलती है" \
       "इसे बनाएँ: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "कलेक्शन के इंडेक्स" "सभी: ${IDX}"
fi

# --- 5. स्कीमा वैलिडेटर चालू है ---------------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "स्कीमा वैलिडेटर चालू है (उल्लंघन पर कार्रवाई: ${ACTION:-डिफ़ॉल्ट})"
  if [ "$ACTION" = "warn" ]; then
    warn "वैलिडेटर केवल चेतावनी देता है पर दस्तावेज़ स्वीकार कर लेता है" \
         "प्रोडक्शन कलेक्शन को validationAction: error चाहिए"
  fi
else
  fail "स्कीमा वैलिडेटर चालू नहीं है — फ़ील्ड नाम की टाइपो चुपचाप पास हो जाएगी" \
       "इसे चालू करें: mo < validator.js (पूर्वानुमेय विफलता का विवरण README में देखें)"
fi

# --- 6. भ्रष्ट दस्तावेज़ हटा दिए गए ---------------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "बिना type फ़ील्ड वाला कोई दस्तावेज़ नहीं बचा"
else
  fail "कलेक्शन में ${TYPELESS} दस्तावेज़ बिना type फ़ील्ड के हैं — सुरक्षाकर्मी उन्हें नहीं देख पाएँगे" \
       "उन्हें ढूँढ़कर हटाएँ: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish सारांश छापता है और रिपोर्ट-आर्टिफ़ैक्ट को एक फ़ाइल में रखता है; रिटर्न कोड ग़ैर-शून्य होता है
# अगर कम से कम एक जाँच फ़ेल हुई हो।
finish
