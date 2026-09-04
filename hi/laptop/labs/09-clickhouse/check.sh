#!/usr/bin/env bash
# लैब 9 की जाँच: ClickHouse में प्रवेश-पास का लॉग रखा है और उसी से रिपोर्ट बनती है।
#
# हम "सेवा बन गई" नहीं, बल्कि सार जाँचते हैं: टेबल मौजूद है, कम से कम दस लाख पंक्तियाँ,
# डेटा विविध है और उसमें स्पष्ट शिखर हैं, मासिक रिपोर्ट मिलीसेकंड में चलती है,
# और एक ही कॉलम पर क्वेरी टेबल का बहुत छोटा हिस्सा पढ़ती है — यानी
# कॉलम-आधारित भंडारण सचमुच काम करता है, महज़ दावा नहीं है।
#
# चलाना (हर नए टर्मिनल विंडो में वेरिएबल फिर से सेट करने होते हैं):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX की जगह अपना नंबर
#   export CH_PASSWORD='analyst उपयोगकर्ता का पासवर्ड'
#   cd labs/09-clickhouse && ./check.sh
#
# पासवर्ड न छपता है और न रिपोर्ट में आता है।
# स्क्रिप्ट curl वाले एक-बार-के पॉड उठाती है, इसलिए इसमें लगभग एक मिनट लगता है।

# नाम और शीर्षक साझा लाइब्रेरी को चाहिए: वह इन्हीं से रिपोर्ट-आर्टिफैक्ट पर हस्ताक्षर करती है।
# lib.sh में ok/fail/warn/evidence/finish और नीचे के परिवेश-जाँच हैं — ताकि
# पंद्रह जाँच-स्क्रिप्ट एक जैसा छापें, न कि हर एक अपने तरीके से।
LAB_NAME="09-clickhouse"
LAB_TITLE="लैब 9 · दस लाख पंक्तियों पर विश्लेषण"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# दोनों जाँच स्क्रिप्ट को स्पष्ट संदेश के साथ रोक देती हैं यदि क्लस्टर एक्सेस फ़ाइल
# या टेनेंट नंबर सेट नहीं है। इनके बिना आगे kubectl की त्रुटियाँ आतीं।
need_kubeconfig
need_tenant

# प्रतिभागी COZY_TENANT को `workshop07` के रूप में सेट करता है, जबकि namespace
# `tenant-workshop07` कहलाता है। हम दोनों वर्तनी स्वीकार करते हैं।
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# डिफ़ॉल्ट नाम वही हैं जो लैब में हैं। ${X:-मान} रूप का अर्थ है "परिवेश
# वेरिएबल लो, और यदि वह न हो तो मान रख दो": यदि आपने ऐप को अलग नाम दिया —
# तो CH_APP=नाम ./check.sh के रूप में चलाएँ, स्क्रिप्ट संपादित करने की ज़रूरत नहीं।
# पता आंतरिक है, क्लस्टर के भीतर से: 8123 — ClickHouse के HTTP इंटरफ़ेस का पोर्ट।
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "ClickHouse पता" "$CH_URL"

# --- 1. क्या सेवा बिल्कुल भी जवाब देती है ------------------------------------
# /ping को पासवर्ड नहीं चाहिए, इसलिए यह पहली और सबसे सस्ती जाँच है:
# यह "कोई कनेक्शन नहीं" को "कनेक्शन है, पर पासवर्ड ग़लत" से अलग करती है।
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse टेनेंट के आंतरिक पते पर जवाब दे रहा है"
else
  fail "ClickHouse ${CH_HOST} पते पर जवाब नहीं दे रहा" \
       "COZY_TENANT में टेनेंट नंबर और ऐप का नाम जाँचें (डिफ़ॉल्ट 'analytics'; अन्यथा CH_APP=नाम ./check.sh); डैशबोर्ड में ऐप तैयार अवस्था में होना चाहिए"
  finish
  exit $?
fi

# आगे का सब कुछ डेटाबेस में लॉग-इन माँगता है। पासवर्ड के बिना स्क्रिप्ट अनुमान नहीं
# लगाती और चुप नहीं रहती, बल्कि ईमानदारी से कहती है कि डेटाबेस की सामग्री जाँची नहीं
# गई, और रिपोर्ट समाप्त कर देती है: वरना प्रतिभागी सोचता कि जाँच पास हो गई।
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "CH_PASSWORD वेरिएबल सेट नहीं है, डेटाबेस की सामग्री जाँची नहीं गई" \
       "export CH_PASSWORD='${CH_USER} उपयोगकर्ता का पासवर्ड' और स्क्रिप्ट फिर से चलाएँ; पासवर्ड डैशबोर्ड में दिखता है, सीक्रेट clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# स्टैंडर्ड इनपुट से SQL चलाओ और जवाब लौटाओ।
# अलग फ़ंक्शन, in_cluster_curl नहीं: क्वेरी POST की बॉडी में जाती है, और बॉडी को
# स्टैंडर्ड इनपुट चाहिए, जो साझा फ़ंक्शन के पास नहीं है।
# पासवर्ड पॉड में एक अस्थायी Secret से परिवेश वेरिएबल के रूप में जाता है, तर्क के रूप में नहीं:
# जो कुछ args में जाता है, वह `get pods` वाले किसी को भी दिखता है, etcd में रहता है और audit
# log में चमकता है। लैब ख़ुद इसी की बात करती है — उसे ऐसी स्क्रिप्ट से जाँचना जो उल्टा करे,
# दोहरा मापदंड होता।
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# JSON-प्रारूप जवाब के statistics ब्लॉक से एक संख्या निकालो।
chstat() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
key = sys.argv[1]
src = d.get("statistics", {}) if key in ("elapsed",) else d
val = src.get(key, d.get("statistics", {}).get(key))
if val is None:
    sys.exit(1)
print(val)
' "$1" 2>/dev/null
}

# --- 2. टेबल मौजूद है -------------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "टेबल ${CH_TABLE} मौजूद है"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse ने उपयोगकर्ता ${CH_USER} का पासवर्ड अस्वीकार कर दिया" \
         "डैशबोर्ड में पासवर्ड मिलाएँ: ऐप ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "टेबल ${CH_TABLE} मौजूद नहीं है" \
         "इसे बनाएँ: ch < 01-schema.sql (स्कीमा का विवरण — README में)"
  fi
  finish
  exit $?
fi

# --- 3. कितना डेटा है और वह कितना विविध है ----------------------------------
# छह के बजाय एक ही क्वेरी: हर ch_query कॉल एक पॉड उठाती है, और लगातार छह
# पॉड इस जाँच को बिना वजह एक मिनट के इंतज़ार में बदल देते।
STATS="$(ch_query <<SQL
SELECT
    (SELECT count() FROM ${CH_TABLE}),
    (SELECT uniqExact(entrance) FROM ${CH_TABLE}),
    (SELECT uniqExact(pass_type) FROM ${CH_TABLE}),
    (SELECT uniqExact(toStartOfMonth(created_at)) FROM ${CH_TABLE}),
    (SELECT max(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT min(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT sum(data_uncompressed_bytes) FROM system.columns
      WHERE database = currentDatabase() AND table = '${CH_TABLE}')
SQL
)"

ROWS="$(printf '%s' "$STATS" | awk 'NR==1{print $1}')"
UNIQ_ENT="$(printf '%s' "$STATS" | awk 'NR==1{print $2}')"
UNIQ_TYPE="$(printf '%s' "$STATS" | awk 'NR==1{print $3}')"
UNIQ_MONTH="$(printf '%s' "$STATS" | awk 'NR==1{print $4}')"
PEAK_MAX="$(printf '%s' "$STATS" | awk 'NR==1{print $5}')"
PEAK_MIN="$(printf '%s' "$STATS" | awk 'NR==1{print $6}')"
TABLE_BYTES="$(printf '%s' "$STATS" | awk 'NR==1{print $7}')"

for v in ROWS UNIQ_ENT UNIQ_TYPE UNIQ_MONTH PEAK_MAX PEAK_MIN TABLE_BYTES; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*) eval "$v=0" ;;
  esac
done

if [ "$ROWS" -ge 1000000 ]; then
  ok "टेबल में ${ROWS} पंक्तियाँ हैं — दस लाख बन गईं"
else
  fail "टेबल में ${ROWS} पंक्तियाँ हैं, दस लाख अपेक्षित थीं" \
       "जनरेटर चलाएँ: ch < 02-generate.sql (जनरेटर का विवरण — README में)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "डेटा विविध है: प्रवेश ${UNIQ_ENT}, पास प्रकार ${UNIQ_TYPE}, महीने ${UNIQ_MONTH}"
else
  fail "डेटा एकरस है: प्रवेश ${UNIQ_ENT}, प्रकार ${UNIQ_TYPE}, महीने ${UNIQ_MONTH}" \
       "ऐसे डेटा पर रिपोर्ट कुछ नहीं दिखाएगी; फिर से बनाएँ: TRUNCATE TABLE ${CH_TABLE}, फिर ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "डेटा में घंटेवार स्पष्ट शिखर हैं (सबसे व्यस्त घंटे का सबसे शांत घंटे से — कम से कम दोगुना)"
  evidence "घंटे के अनुसार वितरण" "प्रति घंटे अधिकतम: ${PEAK_MAX}
प्रति घंटे न्यूनतम: ${PEAK_MIN}"
else
  warn "घंटेवार कोई शिखर नहीं दिखता: अधिकतम ${PEAK_MAX}, न्यूनतम ${PEAK_MIN}" \
       "ऐसे डेटा पर 'शिखर कब हैं' रिपोर्ट निरर्थक है; जाँचें कि जनरेटर पूरा चला"
fi

# --- 4. मासिक रिपोर्ट तेज़ी से गणना होती है ----------------------------------
REPORT="$(ch_query <<SQL
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM ${CH_TABLE}
GROUP BY month
ORDER BY month
FORMAT JSON
SQL
)"

ELAPSED="$(printf '%s' "$REPORT" | chstat elapsed)"
READ_ROWS="$(printf '%s' "$REPORT" | chstat rows_read)"

if [ -z "$ELAPSED" ]; then
  fail "मासिक रिपोर्ट नहीं चली" \
       "इसे हाथ से चलाएँ: ch < 03-report.sql और त्रुटि का पाठ देखें"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # दहलीज़ को हम उसी के पास रखते हैं जो लैब वादा करती है। पिछले पाँच सेकंड
  # चार-सेकंड की रिपोर्ट को सफलता गिन लेते — जबकि लैब की शीर्ष-पंक्ति कहती है
  # "मिलीसेकंड में गणना होती है"। स्क्रिप्ट को वह पुष्टि नहीं करनी चाहिए जो उसने जाँचा नहीं।
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "मासिक रिपोर्ट ${MS} मि.से. में गणना हुई, पढ़ी गई पंक्तियाँ: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "मासिक रिपोर्ट ${MS} मि.से. में गणना हुई — यह वह परिमाण-कोटि नहीं जिसकी लैब बात करती है" \
         "खाली स्टैंड पर दस लाख पंक्तियाँ दसियों मिलीसेकंड में समा जाती हैं; जाँचें कि सेवा किसी पड़ोसी लोड में व्यस्त तो नहीं, और दोबारा करें"
  else
    warn "मासिक रिपोर्ट ${MS} मि.से. में गणना हुई — अपेक्षा से धीमी, पर उचित सीमा में" \
         "व्यस्त स्टैंड पर ऐसा होता है; खाली स्टैंड पर ऐसी रिपोर्ट दसियों मिलीसेकंड में समा जाती है"
  fi
  evidence "मासिक रिपोर्ट" "समय: ${MS} मि.से.
पढ़ी गई पंक्तियाँ: ${READ_ROWS}"
fi

# --- 5. कॉलम-आधारित भंडारण सचमुच काम करता है, महज़ दावा नहीं ------------------
# क्वेरी एक छोटे कॉलम को छूती है। यदि भंडारण कॉलम-आधारित है, तो पढ़ी गई मात्रा
# पूरी टेबल के वज़न से स्पष्ट रूप से कम होगी।
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# दोनों मात्राएँ असंपीड़ित हैं: क्वेरी आँकड़ों में `bytes_read` असंपीड़ित
# आयतन है, और system.columns से हम `data_uncompressed_bytes` लेते हैं। इसकी
# `data_compressed_bytes` से तुलना डिस्क-आकार का अंश देती और प्रतिभागी को
# ग़लत संख्या छापती — अच्छी तरह संपीड़ित टेबल पर वह सौ प्रतिशत पार कर सकती थी।
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "एक कॉलम का पठन" "पढ़े गए बाइट: ${NARROW_BYTES}
पूरी टेबल बिना संपीड़न, बाइट: ${TABLE_BYTES}
अंश: ${SHARE}%"
  # एक दहलीज़, महज़ "पूरे से कम" नहीं। सात में से एक संकरा कॉलम इकाई अंकों में
  # प्रतिशत देना चाहिए; "100% के बजाय 99%" औपचारिक रूप से कम है पर कुछ साबित नहीं
  # करता — और ठीक यही दावा लैब अपने शीर्षक में रखती है।
  if [ "$SHARE" -le 25 ]; then
    ok "एक-कॉलम क्वेरी ने टेबल के डेटा का ${SHARE}% पढ़ा — कॉलम-आधारित भंडारण काम करता है"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "एक-कॉलम क्वेरी ने टेबल के डेटा का ${SHARE}% पढ़ा — पूरे से कम, पर लाभ अपेक्षा से मामूली" \
         "इकाई अंकों में प्रतिशत अपेक्षित था; जाँचें कि क्वेरी एक संकरे कॉलम को संबोधित करती है, कई को नहीं"
  else
    warn "एक-कॉलम क्वेरी ने पूरी टेबल से कम नहीं पढ़ा" \
         "यह बहुत छोटी टेबलों पर होता है; जाँचें कि सचमुच दस लाख पंक्तियाँ हैं"
  fi
else
  warn "मापा नहीं जा सका कि संकरी क्वेरी ने कितना पढ़ा" \
       "हाथ से चलाएँ: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON और bytes_read देखें"
fi

# finish सारांश छापता है और रिपोर्ट-आर्टिफैक्ट को एक फ़ाइल में लिखता है; रिटर्न कोड शून्येतर होता है
# यदि कम से कम एक जाँच विफल रही।
finish
