#!/usr/bin/env bash
# लैब 13 की जाँच: चार्ट और ऐप्लिकेशन परिभाषा एडमिन को सौंपने के लिए तैयार हैं।
#
# यह जाँच जानबूझकर स्थानीय है। टेनेंट ApplicationDefinition लागू नहीं कर सकता
# (यह ऑब्जेक्ट cluster-scoped है), इसलिए उसे क्लस्टर में ढूँढना बेकार है:
# ऑब्जेक्ट का न होना प्रतिभागी की गलती नहीं है। हम वही जाँचते हैं जिसके लिए वह
# ज़िम्मेदार है: चार्ट बनता है, स्कीमा काम करती है, परिभाषा पार्स होती है और चार्ट से मेल खाती है।
#
# लैब फ़ोल्डर से चलाएँ:
#   cd labs/13-catalog && ./check.sh
# क्लस्टर ज़रूरी नहीं: KUBECONFIG के बिना दो जाँचें त्रुटि के बजाय चेतावनी के साथ
# छोड़ दी जाती हैं।

LAB_NAME="13-catalog"
LAB_TITLE="लैब 13 · Cozystack कैटलॉग में आपका अपना ऐप्लिकेशन"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- उपकरण -----------------------------------------------------------------
# helm के बिना जाँचने को कुछ नहीं है, इसलिए स्क्रिप्ट यहीं रुक जाती है और आगे
# दर्जन भर एक जैसी विफलताएँ नहीं उगलती।
if ! command -v helm >/dev/null 2>&1; then
  fail "इस मशीन पर helm नहीं है" \
       "इसे इंस्टॉल करें: brew install helm (macOS) या https://helm.sh/docs/intro/install/ — इसके बिना लैब जाँची नहीं जा सकती"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm मौजूद है (${HELM_VER})"
evidence "helm संस्करण" "$HELM_VER"

# --- चार्ट मौजूद है --------------------------------------------------------
# «चार्ट टूटा है» को «स्क्रिप्ट गलत फ़ोल्डर से चलाई गई» से अलग करते हैं। दूसरी गलती
# पहली से ज़्यादा आम है, और उसका संदेश अलग होना चाहिए।
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "${CHART} में चार्ट नहीं मिला" \
       "स्क्रिप्ट को लैब फ़ोल्डर से चलाएँ: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- लिंटर -----------------------------------------------------------------
# helm lint चार्ट को टेक्स्ट की तरह पढ़ता है: टेम्पलेट में टाइपो, Chart.yaml के गायब
# फ़ील्ड, न मौजूद values के संदर्भ ढूँढता है। यहाँ बात क्लस्टर तक नहीं पहुँचती।
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "चार्ट helm lint पास करता है"
  evidence "helm lint" "$LINT_OUT"
else
  fail "चार्ट helm lint पास नहीं करता" \
       "नीचे दिया आउटपुट पढ़ें और बताई गई फ़ाइलें ठीक करें: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- रेंडर -----------------------------------------------------------------
# खाली आउटपुट और सिर्फ़ टिप्पणियों वाला आउटपुट लिंटर से बच निकलता, इसलिए हम देखते हैं
# कि रेंडर किए गए आउटपुट में Deployment है, और जो निकला उसे सूचीबद्ध करते हैं।
# यहाँ मुख्य बात «कमांड चल गई» नहीं, बल्कि «असली ऑब्जेक्ट बने» है।
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "चार्ट रेंडर होता है, ऑब्जेक्ट बनते हैं: ${KINDS}"
  evidence "चार्ट क्या रेंडर करता है" "$KINDS"
else
  fail "helm template ने एक भी Deployment नहीं बनाया" \
       "रेंडर त्रुटि देखें: helm template main chart"
  evidence "helm template आउटपुट" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- चार्ट असली क्लस्टर द्वारा स्वीकार किया जाता है -------------------------
# पूरे लैब सेट में एकमात्र जाँच जो मैनिफ़ेस्ट को टेक्स्ट के बजाय असली क्लस्टर स्कीमा के
# विरुद्ध सत्यापित करती है।
#
# `helm lint` और `helm template` टेम्पलेट जाँचते हैं, पर Kubernetes स्कीमा नहीं: गलत जगह
# रखे फ़ील्ड वाला मैनिफ़ेस्ट इनसे बच निकलता है, जबकि क्लस्टर उसे अस्वीकार कर देता है।
# अपने अनुभव से सीखा — गलती से volumes के अंदर डाला गया securityContext दोनों से पास हो गया
# और सिर्फ़ सर्वर पर बिखरा। यह जाँच वहाँ ज़रूरी है जहाँ चार्ट लागू किया जाता है।
#
# lint और template इसकी जगह क्यों नहीं लेते:
#   helm lint      चार्ट की संरचना देखता है: फ़ाइलें मौजूद हैं, टेम्पलेट पार्स होते हैं;
#   helm template  values भरकर टेक्स्ट देता है — पर वे फ़ील्ड क्या हैं और ऐसे ऑब्जेक्ट में
#                  हो भी सकते हैं या नहीं, यह वह न जानता है न जान सकता है;
#   apply --dry-run=server मैनिफ़ेस्ट को apiserver को भेजता है, जो उसे टाइप स्कीमा और
#                  admission-कंट्रोल से गुज़ारकर बताता है कि स्वीकार करेगा या नहीं, कुछ भी
#                  बनाए बिना। इसीलिए `unknown field` और नीति द्वारा अस्वीकृति —
#                  ठीक वही जिस पर चार्ट ग्राहक के यहाँ ठोकर खाता है।
# --dry-run=client फ़्लैग यह जाँच नहीं देता: वह मैनिफ़ेस्ट को आपकी मशीन पर पार्स करता है।
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # अधिकार की अस्वीकृति और स्कीमा की अस्वीकृति अलग चीज़ें हैं, इन्हें मिलाना नहीं चाहिए।
  # टेनेंट एक्सेस (~/.kube/workshop) के तहत Deployment और ConfigMap पर अधिकार बिलकुल नहीं
  # हैं, इसलिए यहाँ Forbidden आएगा — और यह चार्ट की गुणवत्ता के बारे में कुछ नहीं कहता।
  # सार्थक जाँच सिर्फ़ `lab` क्लस्टर के एक्सेस से संभव है, जहाँ आप पूर्ण स्वामी हैं।
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "सर्वर-साइड चार्ट जाँच छोड़ी गई: मौजूदा एक्सेस इसकी अनुमति नहीं देता" \
         "इसे अपने क्लस्टर के एक्सेस से चलाएँ: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "क्लस्टर रेंडर किए चार्ट को अस्वीकार करता है" \
         "देखें: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "सर्वर की अस्वीकृति" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "क्लस्टर रेंडर किए चार्ट को स्वीकार करता है — फ़ील्ड और उनकी जगहें सही हैं"
  fi
else
  warn "क्लस्टर के विरुद्ध चार्ट जाँच छोड़ी गई: एक्सेस नहीं" \
       "helm template को kubectl apply --dry-run=server से चलाने के लिए KUBECONFIG सेट करें"
fi

# --- पैरामीटर सचमुच मैनिफ़ेस्ट तक पहुँचते हैं -------------------------------
# चार्ट बन और रेंडर हो सकता है जबकि पैरामीटर कहीं नहीं भरा जाता — उदाहरण के लिए,
# मान टेम्पलेट में संख्या के रूप में लिख दिया गया। इसलिए हर पैरामीटर को असल में जाँचते हैं:
# जानबूझकर एक असामान्य मान देते हैं और उसे तैयार मैनिफ़ेस्ट में ढूँढते हैं।
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "replicas पैरामीटर मैनिफ़ेस्ट तक पहुँचता है (--set replicas=5 से replicas: 5 मिलता है)"
else
  fail "replicas पैरामीटर मैनिफ़ेस्ट तक नहीं पहुँचता" \
       "templates/deployment.yaml में replicas: {{ .Values.replicas }} होना चाहिए"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "external पैरामीटर Service का प्रकार LoadBalancer में बदल देता है"
else
  warn "external पैरामीटर Service का प्रकार नहीं बदलता" \
       "चार्ट में खराबी नहीं, पर Cozystack कैटलॉग की परंपरा: ऐप्लिकेशन का external फ़ील्ड ठीक बाहरी एक्सेस का अर्थ रखता है"
fi

# --- स्कीमा सचमुच सुरक्षा करती है -------------------------------------------
# जो स्कीमा कुछ भी अस्वीकार नहीं करती वह बेकार है। हम जाँचते हैं कि वह अस्वीकार करती है।
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "values स्कीमा स्पष्ट रूप से गलत मान को अस्वीकार नहीं करती (replicas=abc पास हो गया)" \
       "जाँचें कि values.schema.json, values.yaml के बगल में है और उसमें replicas integer के रूप में घोषित है"
else
  ok "values स्कीमा गलत प्रकार अस्वीकार करती है (replicas=abc पास नहीं होता)"
fi

# --- ApplicationDefinition: अनिवार्य फ़ील्ड ---------------------------------
# प्रतिभागी परिभाषा लागू नहीं कर सकता, इसलिए उसे apiserver की अस्वीकृति भी नहीं दिखेगी।
# इसलिए अनिवार्य फ़ील्ड यहीं गिनते हैं: इनमें से किसी के बिना एडमिन को अपनी ओर अस्वीकृति
# मिलेगी, और सुलझाना फ़ाइल के लेखक को ही पड़ेगा।
if [ ! -f "$APPDEF" ]; then
  fail "नहीं मिला: ${APPDEF}" \
       "फ़ाइल चार्ट के बगल में होनी चाहिए; इसे लैब रिपॉज़िटरी से लें"
else
  MISSING=""
  # कुंजियाँ पंक्ति-दर-पंक्ति ढूँढते हैं, YAML पार्स किए बिना: PyYAML हर मशीन पर नहीं होता,
  # और एक फ़ाइल जाँचने के लिए निर्भरता जोड़ना ठीक नहीं।
  check_key() {
    grep -Eq "$1" "$APPDEF" || MISSING="$MISSING $2"
  }
  check_key '^kind:[[:space:]]+ApplicationDefinition[[:space:]]*$' 'kind: ApplicationDefinition'
  check_key '^apiVersion:[[:space:]]+cozystack\.io/v1alpha1[[:space:]]*$' 'apiVersion: cozystack.io/v1alpha1'
  check_key '^[[:space:]]{4}kind:[[:space:]]+\S+' 'application.kind'
  check_key '^[[:space:]]{4}plural:[[:space:]]+\S+' 'application.plural'
  check_key '^[[:space:]]{4}singular:[[:space:]]+\S+' 'application.singular'
  check_key '^[[:space:]]{4}openAPISchema:' 'application.openAPISchema'
  check_key '^[[:space:]]{4}prefix:[[:space:]]+\S+' 'release.prefix'
  check_key '^[[:space:]]{6}kind:[[:space:]]+(OCIRepository|HelmChart|ExternalArtifact)' 'release.chartRef.kind'
  check_key '^[[:space:]]{4}category:[[:space:]]+\S+' 'dashboard.category'
  check_key '^[[:space:]]{4}icon:[[:space:]]+\S+' 'dashboard.icon'

  if [ -z "$MISSING" ]; then
    ok "ApplicationDefinition में सभी अनिवार्य फ़ील्ड मौजूद हैं"
  else
    fail "ApplicationDefinition में फ़ील्ड नहीं हैं:${MISSING}" \
         "README में दिए विवरण से मिलान करें — इनमें से किसी के बिना एडमिन को लागू करते समय अस्वीकृति मिलेगी"
  fi

  # --- परिभाषा की स्कीमा पार्स होती है और चार्ट स्कीमा से मेल खाती है -------
  # ये एक ही चीज़ की दो अलग प्रतियाँ हैं, और इनके बीच कोई संबंध नहीं। अगर ये अलग हो जाएँ —
  # डैशबोर्ड फ़ॉर्म वे फ़ील्ड दिखाएगा जिनकी चार्ट अपेक्षा नहीं करता।
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "ApplicationDefinition में openAPISchema खाली है" \
         "वहाँ chart/values.schema.json की सामग्री एक ही पंक्ति में डालें"
  else
    CMP="$(SCHEMA_LINE="$SCHEMA_LINE" python3 - "$CHART/values.schema.json" <<'PY' 2>&1
import os, sys, json
try:
    inline = json.loads(os.environ["SCHEMA_LINE"])
except Exception as e:
    print("BADJSON %s" % e); raise SystemExit
try:
    chart = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOCHART %s" % e); raise SystemExit
a = sorted((inline.get("properties") or {}).keys())
b = sorted((chart.get("properties") or {}).keys())
if a == b:
    print("SAME %s" % ",".join(a))
else:
    only_def = sorted(set(a) - set(b))
    only_chart = sorted(set(b) - set(a))
    print("DIFF सिर्फ़ परिभाषा में: %s | सिर्फ़ चार्ट में: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "परिभाषा की स्कीमा पार्स होती है और चार्ट स्कीमा से मेल खाती है (${CMP#SAME })"
        evidence "ऐप्लिकेशन पैरामीटर" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "परिभाषा की स्कीमा चार्ट स्कीमा से अलग हो गई: ${CMP#DIFF }" \
             "इन्हें मिलाएँ: openAPISchema की सामग्री एक ही पंक्ति में chart/values.schema.json है"
        ;;
      BADJSON*)
        fail "openAPISchema JSON के रूप में पार्स नहीं होता: ${CMP#BADJSON }" \
             "स्कीमा 'openAPISchema: |-' के नीचे सही JSON की एक ही पंक्ति होनी चाहिए"
        ;;
      *)
        warn "स्कीमाओं की तुलना नहीं हो सकी (${CMP})" \
             "हाथ से जाँचें कि openAPISchema, chart/values.schema.json से मेल खाता है"
        ;;
    esac
  fi

  # --- आइकन -----------------------------------------------------------------
  # डैशबोर्ड base64 में पैक किया गया SVG चाहता है, और तस्वीर के लिए कहीं नहीं जाता। यहाँ
  # त्रुटि खामोश है: मैनिफ़ेस्ट लागू हो जाता है, पर कैटलॉग में आइकन की जगह खाली रहती है।
  # इसलिए स्ट्रिंग को डिकोड करके देखते हैं कि अंदर सचमुच SVG है।
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "आइकन base64 से डिकोड होता है और SVG निकलता है"
        evidence "आइकन की शुरुआत" "$ICON_HEAD"
        ;;
      "")
        fail "आइकन base64 से डिकोड नहीं होता" \
             "स्ट्रिंग दोबारा बनाएँ: base64 -i icon.svg | tr -d '\\n' (Linux पर: base64 -w0 icon.svg)"
        ;;
      *)
        fail "आइकन डिकोड होता है, पर यह SVG नहीं है" \
             "डैशबोर्ड ठीक SVG चाहता है; रास्टर तस्वीर को वह कचरे की तरह दिखाएगा"
        ;;
    esac
  fi
fi

# --- अधिकार: यहाँ अस्वीकृति अपेक्षित है ------------------------------------
# यह प्रतिभागी की जाँच नहीं, बल्कि इस बात की पुष्टि है कि प्लेटफ़ॉर्म कैसे बना है। इसलिए
# `no` उत्तर सफलता है, और `yes` खुशी नहीं, बल्कि हैरानी की वजह है।
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "पुष्टि: आपको ApplicationDefinition लागू करने की अनुमति नहीं है (can-i -> no)"
      evidence "ApplicationDefinition पर अधिकार" \
        "kubectl auth can-i create applicationdefinitions -> no
ऑब्जेक्ट cluster-scoped है और सभी टेनेंट के लिए कैटलॉग बदलता है, इसलिए इसे प्लेटफ़ॉर्म एडमिन लागू करता है।"
      ;;
    yes)
      warn "आपके पास ApplicationDefinition लागू करने का अधिकार है (can-i -> yes)" \
           "इसका मतलब आप एडमिन खाते के तहत काम कर रहे हैं, टेनेंट के नहीं; लैब टेनेंट खाते के लिए है"
      ;;
    *)
      warn "क्लस्टर से अधिकारों के बारे में नहीं पूछा जा सका" \
           "लैब पास करने में बाधा नहीं: जाँच स्थानीय है, यहाँ क्लस्टर की ज़रूरत नहीं"
      ;;
  esac
else
  warn "क्लस्टर से नहीं पूछा गया (KUBECONFIG सेट नहीं या जवाब नहीं दे रहा)" \
       "जाँच स्थानीय है, यहाँ क्लस्टर की ज़रूरत नहीं। अधिकार की अस्वीकृति देखने के लिए: export KUBECONFIG=~/.kube/workshop"
fi

finish
