#!/usr/bin/env bash
# लैब 8 की जाँच: पासवर्ड मैनिफ़ेस्ट से बाहर OpenBao में ले जाया गया है और नियमों के अनुसार रहता है।
#
# हम "ऑब्जेक्ट बन गया" नहीं, बल्कि सार जाँचते हैं: वॉल्ट अनसील है, सीक्रेट टोकन से
# पढ़ा जा सकता है, एक से ज़्यादा वर्शन हैं (यानी रोटेशन सचमुच हुआ), ऑडिट चालू है,
# और लागू किए गए एप्लिकेशन मैनिफ़ेस्ट में कोई प्लेनटेक्स्ट पासवर्ड नहीं है।
#
# कोई भी सीक्रेट रिपोर्ट में नहीं जाता। मान कहीं भी प्रिंट नहीं होते।
#
# स्क्रिप्ट curl वाले एक-बार-इस्तेमाल पॉड चलाती है, इसलिए इसे चलने में करीब एक मिनट लगता है।

# LAB_NAME और LAB_TITLE रिपोर्ट के हेडर में जाते हैं। नीचे साझा जाँच लाइब्रेरी सोर्स की
# जाती है: उससे ok / warn / fail / evidence / finish और वे फ़ंक्शन आते हैं जो क्लस्टर के
# भीतर एक-बार-इस्तेमाल पॉड चलाते हैं। need_kubeconfig और need_tenant स्क्रिप्ट को पहले ही
# रोक देते हैं अगर एक्सेस या टेनेंट नंबर सेट न हो: वरना सब कुछ एक साथ फ़ेल हो जाएगा और
# रिपोर्ट से वजह का कोई सुराग नहीं मिलेगा।
LAB_NAME="08-openbao"
LAB_TITLE="लैब 8 · सीक्रेट मैनिफ़ेस्ट में नहीं"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- कहाँ देखना है ---------------------------------------------------------
# प्रतिभागी COZY_TENANT को `workshop07` के रूप में सेट करता है, लेकिन namespace का नाम
# `tenant-workshop07` होता है। हम दोनों वर्तनियाँ स्वीकार करते हैं: यहाँ चूकना आसान है,
# और एरर मैसेज अस्पष्ट होता («सेवा जवाब नहीं दे रही»).
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# क्या और कहाँ ढूँढ़ते हैं। BAO_APP टेनेंट में OpenBao एप्लिकेशन का नाम है, और यह वॉल्ट के
# आंतरिक पते का हिस्सा है: अगर आपने एप्लिकेशन को अलग नाम दिया है, तो जाँच को
# BAO_APP=नाम ./check.sh के रूप में चलाएँ। SECRET_PATH वॉल्ट के भीतर वह पथ है जहाँ लैब
# डेटाबेस का पासवर्ड रखती है।
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "वॉल्ट का पता" "$BAO_URL"

# स्टैंडर्ड इनपुट पर आए JSON से कुंजियों की एक शृंखला के ज़रिए मान निकालें।
# अगर पथ मौजूद नहीं है या यह JSON नहीं है तो 1 लौटाता है, ताकि कॉल करने वाला
# "ऐसी कोई कुंजी नहीं" को "खाली मान" से अलग कर सके।
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1:]:
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        sys.exit(1)
print("" if d is None else d)
' "$@" 2>/dev/null
}


# OpenBao को एक अनुरोध। हम टोकन को एक अस्थायी Secret से एन्वायरनमेंट वेरिएबल के ज़रिए भेजते
# हैं, न कि आर्गुमेंट में हेडर के रूप में: पॉड के आर्गुमेंट `get pods` वाले किसी को भी दिखते
# हैं, वे etcd में रहते हैं और ऑडिट लॉग में जाते हैं। यहाँ यह वॉल्ट का root टोकन है — ठीक वही
# लीक जिसके खिलाफ़ पूरी लैब लिखी गई है।
#
# परिभाषा पहले कॉल से पहले रखी गई है: जब यह else ब्रांच के भीतर थी, तो सबसे पहली जाँच एक
# न-मौजूद फ़ंक्शन को कॉल करती थी और लैब कभी पास नहीं होती थी।
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. वॉल्ट जवाब देता है -------------------------------------------------
# पहला ही अनुरोध एक साथ दो सवालों के जवाब देता है: क्या एप्लिकेशन ऊपर आया, और क्या टेनेंट
# नंबर सही है। हम सील स्थिति पूछते हैं — यही एकमात्र एंडपॉइंट है जिसे OpenBao बिना टोकन के
# देता है। आगे खाली जवाब का मतलब है "कोई कनेक्शन नहीं", और सामग्री की सभी जाँचें बेमानी हो जाती हैं।
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao ${BAO_URL} पर जवाब नहीं देता" \
       "COZY_TENANT में टेनेंट नंबर और एप्लिकेशन का नाम जाँचें (डिफ़ॉल्ट 'secrets'; वरना BAO_APP=नाम ./check.sh); डैशबोर्ड में एप्लिकेशन तैयार अवस्था में होना चाहिए"
else
  ok "OpenBao टेनेंट के आंतरिक पते पर जवाब देता है"
fi

# --- 2. इनिशियलाइज़्ड ----------------------------------------------------
# इनिशियलाइज़ेशन एक-बार का ऑपरेशन है जिसमें वॉल्ट अपनी मास्टर-की और पहला टोकन बनाता है।
# जब तक यह न हो, अंदर कुछ नहीं होता: न सीक्रेट, न उनके लिए जगह।
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "वॉल्ट इनिशियलाइज़्ड है"
elif [ -n "$SEAL" ]; then
  fail "वॉल्ट इनिशियलाइज़्ड नहीं है" \
       "चलाएँ: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 और आउटपुट सेव करें"
fi

# --- 3. अनसील किया गया --------------------------------------------------------
# सील किया हुआ वॉल्ट पॉड रीस्टार्ट के बाद की सामान्य अवस्था है: डेटा डिस्क पर पड़ा है, लेकिन
# जब तक अनसील-की न डाली जाए, उसे पढ़ने का कोई साधन नहीं है। इसीलिए व्यवहार जाँचने की माँग है,
# ऑब्जेक्ट की मौजूदगी की नहीं: "एप्लिकेशन तैयार" और "सीक्रेट मिल रहे हैं" — ये दो अलग कथन हैं,
# और दूसरा पहले से नहीं निकलता।
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "वॉल्ट अनसील है और अनुरोधों की सेवा कर रहा है"
  evidence "वॉल्ट स्थिति" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "वॉल्ट सील है — यह किसी भी अनुरोध का जवाब 503 अस्वीकृति से देता है" \
       "चलाएँ: kubectl exec bao-workbench -- bao operator unseal <आपकी-unseal-की>"
  evidence "वॉल्ट स्थिति" "$SEAL"
fi

# --- 4. सीक्रेट अपनी जगह पर है और पढ़ा जा सकता है -----------------------------------------
# आगे हमें टोकन चाहिए। इसके बिना जाँचने को कुछ नहीं, पर चुपचाप छोड़ भी नहीं सकते:
# पढ़ने वाले को दिखना चाहिए कि क्या कमी है।
if [ -z "$SEAL" ]; then
  # कोई कनेक्शन नहीं — सामग्री जाँचना बेकार है। हम चुप रहते हैं ताकि रिपोर्ट को चार विफलताओं
  # से न भर दें जिनकी एक ही वजह है, जो ऊपर बताई गई है।
  warn "वॉल्ट की सामग्री जाँची नहीं गई: OpenBao से कोई कनेक्शन नहीं" \
       "कनेक्शन ठीक करें, फिर स्क्रिप्ट दोबारा चलाएँ"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "BAO_TOKEN वेरिएबल सेट नहीं है, इसलिए वॉल्ट की सामग्री जाँची नहीं गई" \
       "export BAO_TOKEN='वॉल्ट की पहली अनसील के समय प्रिंट हुआ root टोकन' करें और स्क्रिप्ट दोबारा चलाएँ"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "सीक्रेट secret/${SECRET_PATH} टोकन से पढ़ा जा सकता है, password फ़ील्ड खाली नहीं है"
    # रिपोर्ट में हम वर्शन नंबर डालते हैं, मान नहीं।
    evidence "सीक्रेट" "पथ: secret/${SECRET_PATH}
password फ़ील्ड: मौजूद (मान छिपा हुआ)
वर्तमान वर्शन: ${DATA_VERSION:-अज्ञात}"
  else
    fail "secret/${SECRET_PATH} पर कोई password फ़ील्ड नहीं है" \
         "इसे वहाँ रखें: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; अगर इंजन अभी चालू नहीं है — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. रोटेशन सचमुच हुआ --------------------------------------------------
  # सीक्रेट का एक ही वर्शन मतलब उसे एक बार सेट कर के भुला दिया गया। रोटेशन ही वॉल्ट रखने का
  # पूरा कारण है: पासवर्ड को मैनिफ़ेस्टों में ढूँढ़ने के बजाय एक ही जगह बदलना। हम वादे नहीं,
  # वर्शन गिनते हैं: वह गिनती वॉल्ट खुद रखता है।
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "सीक्रेट बदला गया: ${CUR_VER} वर्शन, यानी रोटेशन सचमुच हुआ न कि सिर्फ़ बातों में"
    evidence "सीक्रेट का वर्शन इतिहास" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "सीक्रेट के सिर्फ़ एक वर्शन है — रोटेशन नहीं किया गया" \
         "पासवर्ड बदलें: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<नया> और एप्लिकेशन रीस्टार्ट करें"
  fi

  # --- 6. पॉलिसी संकीर्ण है, "सब कुछ चलेगा" नहीं ---------------------------
  # पॉलिसी ही इस सवाल का जवाब है कि "टोकन हासिल करने वाला क्या कर पाएगा"। इसलिए हम इसके
  # होने के तथ्य को नहीं, इसकी सामग्री को देखते हैं: क्या यह पूरे वॉल्ट के बजाय एक विशिष्ट
  # पथ पर दी गई है, और क्या यह केवल-पढ़ने वाली है।
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "passes-read पॉलिसी मौजूद है"
    evidence "passes-read पॉलिसी" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "पॉलिसी एक विशिष्ट पथ पर दी गई है, पूरे वॉल्ट पर नहीं"
    else
      warn "पॉलिसी मौजूद है, पर उसमें पथ secret/data/${SECRET_PATH} नहीं दिखता" \
           "जाँचें कि पॉलिसी में data प्रीफ़िक्स इस्तेमाल हुआ है: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "पॉलिसी सिर्फ़ पढ़ने से ज़्यादा की अनुमति देती है" \
           "एप्लिकेशन को केवल read चाहिए; अतिरिक्त अनुमतियाँ हटा देनी चाहिए"
    fi
  else
    fail "passes-read पॉलिसी नहीं मिली" \
         "इसे बनाएँ: kubectl exec -i bao-workbench -- bao policy write passes-read - < आपकी पॉलिसी फ़ाइल (पॉलिसी की व्याख्या — README में)"
  fi

  # --- 7. ऑडिट चालू है ----------------------------------------------------
  # ऑडिट लॉग के बिना "यह सीक्रेट किसने और कब पढ़ा" का जवाब देने को कुछ नहीं होता — और यही
  # किसी घटना के बाद पूछा जाने वाला पहला सवाल है। हम जुड़े हुए ऑडिट डिवाइस गिनते हैं:
  # कम से कम एक होना चाहिए।
  AUD="$(bao_get "/v1/sys/audit")"
  AUD_COUNT="$(printf '%s' "$AUD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
data = d.get("data", d)
print(len([k for k in data if isinstance(data.get(k), dict)]))
' 2>/dev/null)"
  case "$AUD_COUNT" in
    ''|*[!0-9]*) AUD_COUNT=0 ;;
  esac
  if [ "$AUD_COUNT" -ge 1 ]; then
    ok "ऑडिट लॉग चालू है (डिवाइस: ${AUD_COUNT})"
    evidence "ऑडिट डिवाइस" "$AUD"
  else
    fail "ऑडिट लॉग चालू नहीं है — सीक्रेट किसने पढ़ा, इसका जवाब देने को कुछ नहीं होगा" \
         "इसे चालू करें: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. लैब क्लस्टर में एप्लिकेशन ---------------------------------------------
# अब तक हमने मैनेजमेंट क्लस्टर पर वॉल्ट जाँचा। आगे आपका lab क्लस्टर है, जहाँ एप्लिकेशन खुद
# रहता है। यहाँ मायने यह नहीं रखता कि Deployment बना है, बल्कि तैयार रेप्लिका की मौजूदगी:
# जो init कंटेनर पासवर्ड नहीं ला सका वह पॉड को ऊपर नहीं आने देगा, और ठीक इसी अवस्था को
# "सब ठीक है" से अलग पहचानना ज़रूरी है।
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "लैब क्लस्टर में एप्लिकेशन ${APP_DEPLOY} नहीं है" \
       "लागू करें: kubectl apply -f secrets-demo.yaml (अपना टेनेंट नंबर डालना न भूलें)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "एप्लिकेशन ${APP_DEPLOY} चल रहा है (तैयार रेप्लिका: ${READY})"
  else
    fail "एप्लिकेशन ${APP_DEPLOY} मौजूद है, पर कोई रेप्लिका तैयार नहीं है" \
         "देखें kubectl describe deploy/${APP_DEPLOY} और kubectl logs deploy/${APP_DEPLOY} -c fetch-secret — आमतौर पर init कंटेनर वॉल्ट तक नहीं पहुँच सका या टोकन से अस्वीकार हुआ"
  fi

  # --- 9. मैनिफ़ेस्ट में कोई प्लेनटेक्स्ट पासवर्ड नहीं -------------------------
  # हम लागू किए गए ऑब्जेक्ट को देखते हैं, डिस्क की फ़ाइल को नहीं: लागू कुछ भी किया जा सकता था।
  LEAKS="$(kubectl get deploy "$APP_DEPLOY" -o json 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
suspicious = re.compile(r"(?i)pass|secret|token|key|cred")
spec = d.get("spec", {}).get("template", {}).get("spec", {})
found = []
for c in list(spec.get("initContainers", [])) + list(spec.get("containers", [])):
    for e in c.get("env", []):
        if "value" in e and suspicious.search(e.get("name", "")):
            found.append("%s / env %s मान द्वारा सेट है, संदर्भ द्वारा नहीं" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "एप्लिकेशन मैनिफ़ेस्ट में मान द्वारा सेट किए गए पासवर्ड वाला कोई वेरिएबल नहीं है"
  else
    fail "एप्लिकेशन मैनिफ़ेस्ट में अभी भी संवेदनशील मान प्लेनटेक्स्ट में हैं" \
         "उन्हें हटाएँ: मान वॉल्ट से आना चाहिए, और मैनिफ़ेस्ट में — सिर्फ़ एक संदर्भ। देखें secrets-demo.yaml"
    evidence "मैनिफ़ेस्ट में क्या मिला" "$LEAKS"
  fi

  # --- 10. एप्लिकेशन को सचमुच सीक्रेट मिला --------------------------
  # अंतिम प्रमाण लॉग से आता है, ऑब्जेक्ट के विवरण से नहीं। मैनिफ़ेस्ट निर्दोष हो सकता है जबकि
  # पासवर्ड पॉड में कभी न पहुँचे। हम एक साथ दो चीज़ें देखते हैं: init कंटेनर ने बताया कि वह
  # वॉल्ट में गया, और एप्लिकेशन एक फ़िंगरप्रिंट प्रिंट करता है — यानी वह सचमुच मिले हुए पासवर्ड
  # के साथ काम करता है।
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init कंटेनर ने वॉल्ट से सीक्रेट ले लिया"
    evidence "init कंटेनर लॉग" "$INIT_LOG"
  else
    fail "ऐसा कोई संकेत नहीं कि init कंटेनर ने वॉल्ट से सीक्रेट लिया" \
         "जाँचें kubectl logs deploy/${APP_DEPLOY} -c fetch-secret; अगर ऐसा कोई कंटेनर नहीं है — पुराना मैनिफ़ेस्ट लागू किया गया था"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "एप्लिकेशन मिले हुए पासवर्ड के साथ काम करता है (लॉग में मान नहीं, फ़िंगरप्रिंट लिखा जाता है)"
    evidence "एप्लिकेशन लॉग" "$APP_LOG"
  else
    fail "एप्लिकेशन लॉग में पासवर्ड का कोई फ़िंगरप्रिंट नहीं है" \
         "जाँचें kubectl logs deploy/${APP_DEPLOY} -c app — कंटेनर शुरू होने में विफल रहा हो सकता है"
  fi
fi

# --- 11. भोला सीक्रेट हटाया गया ----------------------------------------------
# हम इसे "हटाया गया" तभी गिनते हैं जब लैब सचमुच की गई हो: साफ़ क्लस्टर पर सीक्रेट कभी था ही
# नहीं, और रिपोर्ट प्रतिभागी की उस सफ़ाई के लिए तारीफ़ कर देती जो कभी हुई ही नहीं।
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "क्लस्टर में अभी भी भोले चरण का passes-db सीक्रेट मौजूद है" \
       "इसकी अब ज़रूरत नहीं है और इसमें पुराना पासवर्ड है: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "भोला passes-db सीक्रेट हटा दिया गया है"
fi

finish
