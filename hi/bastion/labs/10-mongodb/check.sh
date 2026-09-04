#!/usr/bin/env bash
# लैब 10 की जाँच: MongoDB में अलग-अलग रूप के पास रखे हैं और उन पर खोज चलती है।
#
# हम «सेवा बन गई» नहीं, बल्कि सार जाँचते हैं: कलेक्शन में चारों रूपों के दस्तावेज़ हैं,
# नेस्टेड फ़ील्ड और सूची के भीतर खोज काम करती है, दुर्लभ फ़ील्ड पर
# विरल (sparse) इंडेक्स बना है, स्कीमा वैलिडेटर चालू है, और बिना टाइप वाले दस्तावेज़
# नहीं बचे हैं।
#
# चलाना (हर नई टर्मिनल विंडो में वेरिएबल फिर से सेट किए जाते हैं):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX की जगह अपना नंबर
#   export MONGO_PASSWORD='passapp उपयोगकर्ता का पासवर्ड'
#   cd labs/10-mongodb && ./check.sh
#
# पासवर्ड प्रिंट नहीं होता और रिपोर्ट में नहीं जाता।
# स्क्रिप्ट एक-बार-इस्तेमाल पॉड उठाती है, इसलिए लगभग एक मिनट लेती है।

# नाम और शीर्षक साझा लाइब्रेरी को चाहिए: वह इनसे रिपोर्ट-आर्टिफ़ैक्ट पर हस्ताक्षर करती है।
# lib.sh में ok/fail/warn/evidence/finish और नीचे के environment चेक हैं — ताकि
# पंद्रह जाँच स्क्रिप्ट एक जैसा प्रिंट करें, न कि हर एक अपने तरीके से।
LAB_NAME="10-mongodb"
LAB_TITLE="लैब 10 · डॉक्युमेंट स्टोर"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# दोनों जाँच स्क्रिप्ट को स्पष्ट संदेश के साथ रोक देती हैं, अगर क्लस्टर एक्सेस फ़ाइल
# या टेनेंट नंबर सेट न हो। इनके बिना आगे kubectl की त्रुटियाँ ढेर हो जातीं।
need_kubeconfig
need_tenant

# COZY_TENANT को प्रतिभागी `workshop07` के रूप में सेट करता है, जबकि namespace का नाम
# `tenant-workshop07` है। हम दोनों वर्तनी स्वीकार करते हैं।
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# डिफ़ॉल्ट नाम वही हैं जो लैब में हैं। लेखन ${X:-value} का अर्थ है «environment
# वेरिएबल लो, और अगर वह न हो तो value रख दो»: अगर एप्लिकेशन को
# अलग नाम दिया — इसे MONGO_APP=name ./check.sh के रूप में चलाएँ, स्क्रिप्ट बदलने की ज़रूरत नहीं।
# पता आंतरिक है, खुद क्लस्टर के भीतर से; नाम में rs0 वह रेप्लिका सेट है जिसमें
# हमारी एकमात्र प्रति रहती है।
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "MongoDB का पता" "$MONGO_HOST"

# --- 1. पोर्ट तक कोई कनेक्टिविटी है भी या नहीं -----------------------------
# MongoDB अपने पोर्ट पर HTTP अनुरोध का उत्तर एक स्पष्ट वाक्य से देता है कि
# यहाँ ड्राइवर से आना चाहिए, ब्राउज़र से नहीं। इतना काफ़ी है ताकि
# «नाम resolve नहीं होता / पोर्ट बंद है» को «कनेक्टिविटी है, क्रेडेंशियल ग़लत हैं» से अलग किया जा सके।
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB टेनेंट के आंतरिक पते पर उत्तर देता है"
else
  fail "पते ${MONGO_HOST} पर MongoDB से कोई कनेक्टिविटी नहीं" \
       "COZY_TENANT में टेनेंट नंबर और एप्लिकेशन का नाम जाँचें (डिफ़ॉल्ट 'passes'; अन्यथा MONGO_APP=name ./check.sh); डैशबोर्ड में एप्लिकेशन तैयार अवस्था में होना चाहिए"
  finish
  exit $?
fi

# आगे जो कुछ है वह डेटाबेस में लॉग-इन की माँग करता है। पासवर्ड के बिना स्क्रिप्ट न अनुमान लगाती है न चुप रहती है,
# बल्कि ईमानदारी से कहती है कि डेटाबेस की सामग्री जाँची नहीं गई, और रिपोर्ट समाप्त कर देती है: अन्यथा
# प्रतिभागी यह समझ लेता कि जाँच पास हो गई।
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "MONGO_PASSWORD वेरिएबल सेट नहीं है, डेटाबेस की सामग्री जाँची नहीं गई" \
       "export MONGO_PASSWORD='${MONGO_USER} उपयोगकर्ता का पासवर्ड' और स्क्रिप्ट फिर से चलाएँ"
  finish
  exit $?
fi

# पासवर्ड percent-encode होता है: उसमें मौजूद @ : / ? # % वर्ण अन्यथा कनेक्शन
# स्ट्रिंग को तोड़ देते हैं, और व्यक्ति को «ग़लत पासवर्ड» के बजाय अस्पष्ट parse त्रुटि मिलती है।
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ कनेक्शन स्ट्रिंग में पासवर्ड है और यह पॉड के आर्गुमेंट के रूप में भेजी जाती है। यह सोचा-समझा
# समझौता है: check/lib.sh में `in_cluster_with_secrets` देखें — सुरक्षित रास्ता है, पर
# वह बहु-पंक्ति --eval के साथ बिना अति-जटिलता के असंगत है। पॉड कुछ सेकंड जीता है और
# ख़ुद हट जाता है; पासवर्ड रिपोर्ट में नहीं जाता। उत्पादन स्क्रिप्ट में ऐसा न करें।
#
# सभी जाँच एक ही बार में: हर कॉल एक पॉड उठाती है, और लगातार दस पॉड
# जाँच को बेवजह कई-मिनट के इंतज़ार में बदल देते।
# बाहर एक JSON पंक्ति दी जाती है, आगे उसे python पार्स करता है।
# `--overrides` securityContext के साथ: इसके बिना `restricted` प्रोफ़ाइल वाले क्लस्टर में
# पॉड नहीं बनेगा, और लैब ऐसे कारण से विफल होगी जिसका प्रतिभागी से कोई संबंध नहीं।
# `--command --` बना रहता है: kubectl इसे override के साथ जोड़ता है, जहाँ केवल
# सुरक्षा फ़ील्ड सेट हैं।
# mongosh के लिए प्रोग्राम। इसके भीतर के दोहरे उद्धरण सुरक्षित हैं: पाठ बाहर
# python के ज़रिए जाता है, जो ख़ुद उसे उद्धृत करता है, और डेटाबेस व कलेक्शन के नाम
# नीचे दिए मार्करों से प्रतिस्थापित होते हैं।
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

# कंटेनर कमांड override के भीतर रखी जाती है, न कि बाहर `--command --` में छोड़ी जाती है।
# kubectl override को JSON merge patch के रूप में लागू करता है, और उसमें containers सरणी
# पूरी तरह बदल जाती है: बाहर सेट किया `--command` पॉड तक नहीं पहुँचेगा, और mongosh के बजाय
# इमेज की डिफ़ॉल्ट प्रक्रिया चल पड़ती — यानी डेटाबेस ख़ुद। check/lib.sh में यही तरीका अपनाया गया है।
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

# mongosh द्वारा प्रिंट की गई JSON पंक्ति से एक फ़ील्ड निकालना। सूचियाँ अल्पविराम से
# जोड़ी जाती हैं, ताकि उन्हें प्रतिभागी को ज्यों का त्यों दिखाया जा सके।
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

# वही, पर संख्याओं के लिए: कोई भी अप्रत्याशित मान 0 में बदल जाता है, अन्यथा नीचे की
# तुलना स्पष्ट FAIL के बजाय अंकगणितीय त्रुटि से गिर जाती।
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# अगर उत्तर बिल्कुल नहीं है या mongosh ने त्रुटि बताई — आगे जाँचने को कुछ नहीं।
# प्रमाणीकरण की विफलता को अन्य त्रुटियों से अलग रखा गया है: इसका अपना आम कारण है —
# भूला हुआ authSource=admin, और संकेत को ठीक उसी की ओर ले जाना चाहिए।
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB ने ${MONGO_USER} उपयोगकर्ता के क्रेडेंशियल स्वीकार नहीं किए" \
           "पासवर्ड जाँचें और यह कि कनेक्शन स्ट्रिंग में authSource=admin है: उपयोगकर्ता admin डेटाबेस में बना है, जबकि अधिकार ${MONGO_DB} में दिए गए हैं" ;;
    *)
      fail "${MONGO_DB} डेटाबेस पर क्वेरी नहीं चला सके${ERR:+: $ERR}" \
           "मैन्युअल जाँचें: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "${MONGO_USER} उपयोगकर्ता के रूप में ${MONGO_DB} डेटाबेस से कनेक्शन काम करता है"

# --- 2. दस्तावेज़ मौजूद हैं --------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "${MONGO_COLL} कलेक्शन में दस्तावेज़: ${TOTAL}"
else
  fail "${MONGO_COLL} कलेक्शन में केवल ${TOTAL} दस्तावेज़ हैं, कम से कम चार अपेक्षित थे" \
       "पास लोड करें: mo < passes.js (फ़ाइल की व्याख्या README में है)"
fi

# --- 3. रूप सचमुच अलग-अलग हैं ------------------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "कलेक्शन में ${TYPES} अलग-अलग पास टाइप हैं"
else
  fail "अलग-अलग पास टाइप केवल ${TYPES}, चार अपेक्षित थे" \
       "जाँचें कि passes.js पूरा लोड हुआ: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "नेस्टेड ऑब्जेक्ट (car.plate) वाले दस्तावेज़ हैं: ${WITH_CAR}"
else
  fail "नेस्टेड car ऑब्जेक्ट वाला एक भी दस्तावेज़ नहीं" \
       "वाहन पास लोड नहीं हुआ; mo < passes.js दोहराएँ"
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
  ok "ऑब्जेक्ट सूची के भीतर खोज (members.name) दस्तावेज़ ढूँढती है"
else
  fail "members.name पर खोज को कुछ नहीं मिला" \
       "सदस्यों की सूची वाला समूह पास लोड नहीं हुआ; mo < passes.js दोहराएँ"
fi

evidence "कलेक्शन की संरचना" "दस्तावेज़: ${TOTAL}
अलग-अलग पास टाइप: ${TYPES}
नेस्टेड car ऑब्जेक्ट के साथ: ${WITH_CAR}
सूचियों के साथ: ${WITH_ARRAY}"

# --- 4. दुर्लभ फ़ील्ड पर इंडेक्स --------------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "विरल (या आंशिक) इंडेक्स बना है: ${SPARSE}"
  evidence "कलेक्शन के इंडेक्स" "सभी: ${IDX}
विरल: ${SPARSE}"
else
  fail "विरल इंडेक्स नहीं है — कार नंबर पर खोज पूर्ण स्कैन से होती है" \
       "बनाएँ: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "कलेक्शन के इंडेक्स" "सभी: ${IDX}"
fi

# --- 5. स्कीमा वैलिडेटर चालू है --------------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "स्कीमा वैलिडेटर चालू है (उल्लंघन पर कार्रवाई: ${ACTION:-डिफ़ॉल्ट})"
  if [ "$ACTION" = "warn" ]; then
    warn "वैलिडेटर केवल चेतावनी देता है पर दस्तावेज़ फिर भी स्वीकार करता है" \
         "उत्पादन कलेक्शन के लिए validationAction: error चाहिए"
  fi
else
  fail "स्कीमा वैलिडेटर चालू नहीं है — फ़ील्ड नाम में टाइपो चुपचाप पास हो जाएगा" \
       "चालू करें: mo < validator.js (README में पूर्वानुमेय विफलता की व्याख्या देखें)"
fi

# --- 6. ख़राब दस्तावेज़ हटा दिए गए ------------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "type फ़ील्ड के बिना कोई दस्तावेज़ नहीं बचा"
else
  fail "कलेक्शन में ${TYPELESS} दस्तावेज़ type फ़ील्ड के बिना हैं — सुरक्षा उन्हें नहीं देखेगी" \
       "ढूँढें और हटाएँ: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish इतिवृत्त प्रिंट करता है और रिपोर्ट-आर्टिफ़ैक्ट फ़ाइल में रखता है; रिटर्न कोड ग़ैर-शून्य है,
# अगर एक भी जाँच विफल हुई।
finish
