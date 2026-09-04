#!/usr/bin/env bash
# लैब 8 की जाँच: पासवर्ड मैनिफ़ेस्ट से हटाकर OpenBao में रखा गया है और नियमों के अनुसार रहता है।
#
# हम «ऑब्जेक्ट बना» नहीं जाँचते, बल्कि सार जाँचते हैं: वॉल्ट अनसील है, सीक्रेट टोकन से
# पढ़ा जा सकता है, एक से ज़्यादा वर्ज़न हैं (यानी रोटेशन सचमुच हुआ), ऑडिट
# चालू है, और लागू किए गए ऐप्लिकेशन मैनिफ़ेस्ट में खुले टेक्स्ट में कोई पासवर्ड नहीं है।
#
# कोई भी सीक्रेट रिपोर्ट में नहीं आता। वैल्यू कहीं भी प्रिंट नहीं होती।
#
# स्क्रिप्ट curl वाले एक-बार-के पॉड चलाती है, इसलिए यह लगभग एक मिनट तक चलती है।

# LAB_NAME और LAB_TITLE रिपोर्ट के हेडर में जाते हैं। नीचे साझा जाँच-लाइब्रेरी
# जोड़ी जाती है: उससे ok / warn / fail / evidence / finish और वे फ़ंक्शन आते हैं जो
# क्लस्टर के अंदर एक-बार-के पॉड चलाते हैं। need_kubeconfig और need_tenant स्क्रिप्ट को
# पहले ही रोक देते हैं अगर एक्सेस या टेनेंट नंबर सेट नहीं है: वरना सब कुछ एक साथ
# फ़ेल हो जाएगा और रिपोर्ट से कारण समझ नहीं आएगा।
LAB_NAME="08-openbao"
LAB_TITLE="लैब 8 · सीक्रेट मैनिफ़ेस्ट में नहीं"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- कहाँ देखें ---------------------------------------------------------
# प्रतिभागी COZY_TENANT को `workshop07` के रूप में सेट करता है, लेकिन namespace
# `tenant-workshop07` कहलाता है। हम दोनों वर्तनियाँ स्वीकार करते हैं: यहाँ गलती करना
# आसान है, और एरर संदेश अस्पष्ट होता («सर्विस जवाब नहीं दे रही»)।
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# हम क्या और कहाँ ढूँढते हैं। BAO_APP टेनेंट में OpenBao ऐप्लिकेशन का नाम है, और यह
# वॉल्ट के आंतरिक पते का हिस्सा है: अगर आपने ऐप्लिकेशन का नाम अलग रखा है, तो जाँच को
# BAO_APP=नाम ./check.sh के रूप में चलाएँ। SECRET_PATH वॉल्ट के अंदर का वह पथ है जहाँ
# लैब डेटाबेस का पासवर्ड रखती है।
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "वॉल्ट का पता" "$BAO_URL"

# स्टैंडर्ड इनपुट पर आए JSON से कीज़ की शृंखला के अनुसार वैल्यू निकालें।
# अगर पथ मौजूद नहीं है या यह JSON नहीं है तो 1 लौटाता है, ताकि कॉल करने वाला
# «ऐसी की नहीं है» को «खाली वैल्यू» से अलग कर सके।
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


# OpenBao को अनुरोध। हम टोकन को एक अस्थायी Secret से एनवायरनमेंट वेरिएबल के ज़रिए
# भेजते हैं, आर्ग्युमेंट में हेडर के रूप में नहीं: पॉड के आर्ग्युमेंट `get pods` वाले किसी को भी
# दिखते हैं, वे etcd में रहते हैं और ऑडिट लॉग में चले जाते हैं। यहाँ यह वॉल्ट का root-टोकन है —
# ठीक वही लीक जिसके खिलाफ पूरी लैब लिखी गई है।
#
# परिभाषा पहले कॉल से पहले रखी गई है: जब यह else ब्रांच के अंदर थी, तो सबसे पहली जाँच एक
# न-मौजूद फ़ंक्शन को कॉल करती थी और लैब कभी पास नहीं होती थी।
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. वॉल्ट जवाब देता है -------------------------------------------------
# पहला ही अनुरोध एक साथ दो सवालों का जवाब देता है: क्या ऐप्लिकेशन ऊपर आया और क्या टेनेंट नंबर
# सही है। हम सील-स्थिति पूछते हैं — यही एकमात्र एंडपॉइंट है जिसे OpenBao बिना टोकन के देता है।
# इसके बाद खाली जवाब का मतलब है «कनेक्शन नहीं», और सामग्री की सारी जाँचें अर्थहीन हो जाती हैं।
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao ${BAO_URL} पते पर जवाब नहीं दे रहा" \
       "COZY_TENANT में टेनेंट नंबर और ऐप्लिकेशन का नाम जाँचें (डिफ़ॉल्ट 'secrets'; अन्यथा BAO_APP=नाम ./check.sh); डैशबोर्ड में ऐप्लिकेशन तैयार स्थिति में होना चाहिए"
else
  ok "OpenBao टेनेंट के आंतरिक पते पर जवाब देता है"
fi

# --- 2. इनिशियलाइज़्ड ----------------------------------------------------
# इनिशियलाइज़ेशन एक-बार का ऑपरेशन है जिसमें वॉल्ट अपनी मास्टर-की और पहला टोकन बनाता है।
# जब तक यह नहीं हुआ, अंदर कुछ नहीं होता: न सीक्रेट, न उनके लिए जगह।
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "वॉल्ट इनिशियलाइज़्ड है"
elif [ -n "$SEAL" ]; then
  fail "वॉल्ट इनिशियलाइज़्ड नहीं है" \
       "चलाएँ: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 और आउटपुट सहेजें"
fi

# --- 3. अनसील किया गया --------------------------------------------------------
# सील किया गया वॉल्ट पॉड रीस्टार्ट के बाद की सामान्य स्थिति है: डेटा डिस्क पर होता है, पर
# जब तक unseal-की नहीं डाली जाती उसे पढ़ने का कोई ज़रिया नहीं होता। इसीलिए व्यवहार जाँचने की
# शर्त है, ऑब्जेक्ट के होने की नहीं: «ऐप्लिकेशन तैयार है» और «सीक्रेट दिए जा रहे हैं» —
# ये दो अलग कथन हैं, और दूसरा पहले से नहीं निकलता।
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "वॉल्ट अनसील है और अनुरोधों की सेवा कर रहा है"
  evidence "वॉल्ट की स्थिति" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "वॉल्ट सील है — हर अनुरोध पर वह 503 इनकार से जवाब देता है" \
       "चलाएँ: kubectl exec bao-workbench -- bao operator unseal <आपकी-unseal-की>"
  evidence "वॉल्ट की स्थिति" "$SEAL"
fi

# --- 4. सीक्रेट अपनी जगह है और पढ़ा जा सकता है -----------------------------------------
# आगे टोकन चाहिए। उसके बिना जाँचने को कुछ नहीं, पर चुपचाप छोड़ना भी नहीं चाहिए:
# पाठक को दिखना चाहिए कि क्या कमी है।
if [ -z "$SEAL" ]; then
  # कनेक्शन नहीं — सामग्री जाँचना बेकार है। हम चुप रहते हैं ताकि रिपोर्ट को चार फ़ेल से न भर दें,
  # जिनका एक ही कारण है, जो ऊपर बताया गया है।
  warn "वॉल्ट की सामग्री जाँची नहीं गई: OpenBao तक कोई कनेक्शन नहीं" \
       "कनेक्शन ठीक करें, फिर स्क्रिप्ट दोबारा चलाएँ"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "BAO_TOKEN वेरिएबल सेट नहीं है, इसलिए वॉल्ट की सामग्री जाँची नहीं गई" \
       "export BAO_TOKEN='वॉल्ट पहली बार अनसील करते समय प्रिंट हुआ root-टोकन' और स्क्रिप्ट दोबारा चलाएँ"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "सीक्रेट secret/${SECRET_PATH} टोकन से पढ़ा जा सकता है, password फ़ील्ड खाली नहीं है"
    # रिपोर्ट में हम वर्ज़न नंबर डालते हैं, वैल्यू नहीं।
    evidence "सीक्रेट" "पथ: secret/${SECRET_PATH}
password फ़ील्ड: मौजूद (वैल्यू छिपी हुई)
वर्तमान वर्ज़न: ${DATA_VERSION:-अज्ञात}"
  else
    fail "secret/${SECRET_PATH} पर password फ़ील्ड नहीं है" \
         "उसे रखें: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; अगर इंजन अभी चालू नहीं है — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. रोटेशन सचमुच हुआ --------------------------------------------
  # सीक्रेट का केवल एक ही वर्ज़न मतलब कि उसे रखकर भुला दिया गया। रोटेशन वही वजह है जिसके लिए
  # वॉल्ट बनाया जाता है: पासवर्ड एक जगह बदलें, मैनिफ़ेस्ट में ढूँढते न फिरें। हम वादे नहीं,
  # वर्ज़न गिनते हैं: उनकी गिनती वॉल्ट खुद रखता है।
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "सीक्रेट बदला गया: ${CUR_VER} वर्ज़न, यानी रोटेशन सिर्फ़ बातों में नहीं हुआ"
    evidence "सीक्रेट का वर्ज़न इतिहास" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "सीक्रेट के केवल एक ही वर्ज़न है — रोटेशन नहीं किया गया" \
         "पासवर्ड बदलें: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<नया> और ऐप्लिकेशन को रीस्टार्ट करें"
  fi

  # --- 6. पॉलिसी संकरी है, «सब कुछ चलता है» नहीं ---------------------------
  # पॉलिसी ही इस सवाल का जवाब है कि «टोकन पाने वाला क्या कर सकेगा»। इसलिए हम उसके होने के तथ्य
  # को नहीं, बल्कि उसकी सामग्री को देखते हैं: क्या वह पूरे वॉल्ट के बजाय किसी विशिष्ट पथ पर दी गई है
  # और केवल पढ़ने के लिए।
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "पॉलिसी passes-read मौजूद है"
    evidence "पॉलिसी passes-read" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "पॉलिसी किसी विशिष्ट पथ पर दी गई है, पूरे वॉल्ट पर नहीं"
    else
      warn "पॉलिसी है, पर उसमें secret/data/${SECRET_PATH} पथ नहीं दिखता" \
           "जाँचें कि पॉलिसी में data उपसर्ग दर्ज है: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "पॉलिसी केवल पढ़ने से ज़्यादा की अनुमति देती है" \
           "ऐप्लिकेशन को केवल read चाहिए; अतिरिक्त अधिकार हटा देने चाहिए"
    fi
  else
    fail "पॉलिसी passes-read नहीं मिली" \
         "उसे बनाएँ: kubectl exec -i bao-workbench -- bao policy write passes-read - < आपकी पॉलिसी फ़ाइल (पॉलिसी का विश्लेषण README में है)"
  fi

  # --- 7. ऑडिट चालू है ----------------------------------------------------
  # ऑडिट लॉग के बिना «यह सीक्रेट किसने और कब पढ़ा» का जवाब देने को कुछ नहीं — और यही
  # पहला सवाल है जो घटना के बाद पूछा जाता है। हम जुड़े हुए लॉगिंग डिवाइस गिनते हैं:
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
    ok "ऑडिट-लॉग चालू है (डिवाइस: ${AUD_COUNT})"
    evidence "ऑडिट-डिवाइस" "$AUD"
  else
    fail "ऑडिट-लॉग चालू नहीं है — सीक्रेट किसने पढ़ा, इसका जवाब देने को कुछ नहीं होगा" \
         "चालू करें: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. लैब क्लस्टर में ऐप्लिकेशन ---------------------------------------------
# अब तक हमने मैनेजमेंट क्लस्टर पर वॉल्ट जाँचा। आगे — आपका lab क्लस्टर,
# जहाँ ऐप्लिकेशन खुद रहता है। यहाँ महत्वपूर्ण यह नहीं कि Deployment बनाया गया, बल्कि तैयार
# कॉपियों का होना: वह init-कंटेनर जो पासवर्ड नहीं ला सका, पॉड को ऊपर नहीं आने देगा,
# और ठीक इसी स्थिति को «सब ठीक है» से अलग पहचानना है।
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "लैब क्लस्टर में ${APP_DEPLOY} ऐप्लिकेशन नहीं है" \
       "लागू करें: kubectl apply -f secrets-demo.yaml (अपना टेनेंट नंबर डालना न भूलें)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "ऐप्लिकेशन ${APP_DEPLOY} चल रहा है (तैयार कॉपियाँ: ${READY})"
  else
    fail "ऐप्लिकेशन ${APP_DEPLOY} है, पर कोई भी कॉपी तैयार नहीं" \
         "देखें kubectl describe deploy/${APP_DEPLOY} और kubectl logs deploy/${APP_DEPLOY} -c fetch-secret — आम तौर पर init-कंटेनर वॉल्ट तक नहीं पहुँच सका या टोकन से इनकार मिला"
  fi

  # --- 9. मैनिफ़ेस्ट में खुले टेक्स्ट में कोई पासवर्ड नहीं -------------------------
  # हम लागू किए गए ऑब्जेक्ट को देखते हैं, डिस्क पर की फ़ाइल को नहीं: कुछ भी लागू किया जा सकता था।
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
            found.append("%s / env %s वैल्यू से सेट है, रेफ़रेंस से नहीं" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "ऐप्लिकेशन मैनिफ़ेस्ट में वैल्यू से सेट किए पासवर्ड वाला कोई वेरिएबल नहीं"
  else
    fail "ऐप्लिकेशन मैनिफ़ेस्ट में अब भी खुले टेक्स्ट में संवेदनशील वैल्यू हैं" \
         "उन्हें हटाएँ: वैल्यू वॉल्ट से आनी चाहिए, और मैनिफ़ेस्ट में — केवल रेफ़रेंस। देखें secrets-demo.yaml"
    evidence "मैनिफ़ेस्ट में क्या मिला" "$LEAKS"
  fi

  # --- 10. ऐप्लिकेशन ने सीक्रेट सचमुच प्राप्त किया ------------------------
  # आख़िरी सबूत हम लॉग से लेते हैं, ऑब्जेक्ट के विवरण से नहीं। मैनिफ़ेस्ट बेदाग हो सकता है,
  # पर पासवर्ड पॉड में कभी न पहुँचे। हम एक साथ दो चीज़ें देखते हैं:
  # init-कंटेनर ने बताया कि वह वॉल्ट तक गया, और ऐप्लिकेशन फ़िंगरप्रिंट प्रिंट करता है —
  # यानी प्राप्त पासवर्ड के साथ वह सचमुच काम करता है।
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init-कंटेनर ने वॉल्ट से सीक्रेट ले लिया"
    evidence "init-कंटेनर का लॉग" "$INIT_LOG"
  else
    fail "यह नहीं दिखता कि init-कंटेनर ने वॉल्ट से सीक्रेट लिया हो" \
         "जाँचें kubectl logs deploy/${APP_DEPLOY} -c fetch-secret; अगर कंटेनर नहीं है — पुराना मैनिफ़ेस्ट लागू किया गया है"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "ऐप्लिकेशन प्राप्त पासवर्ड के साथ काम करता है (लॉग में फ़िंगरप्रिंट लिखा जाता है, वैल्यू नहीं)"
    evidence "ऐप्लिकेशन का लॉग" "$APP_LOG"
  else
    fail "ऐप्लिकेशन के लॉग में पासवर्ड का फ़िंगरप्रिंट नहीं है" \
         "जाँचें kubectl logs deploy/${APP_DEPLOY} -c app — कंटेनर शायद स्टार्ट न हो सका हो"
  fi
fi

# --- 11. नैव सीक्रेट हटा दिया गया ----------------------------------------------
# «हटा दिया» तभी गिनते हैं जब लैब वाकई की गई हो: साफ़ क्लस्टर पर सीक्रेट कभी था ही नहीं,
# और रिपोर्ट प्रतिभागी को उस सफ़ाई के लिए सराहती जो कभी हुई ही नहीं।
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "क्लस्टर में नैव चरण का सीक्रेट passes-db अब भी बचा है" \
       "उसकी अब ज़रूरत नहीं और उसमें पुराना पासवर्ड है: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "नैव सीक्रेट passes-db हटा दिया गया"
fi

finish
