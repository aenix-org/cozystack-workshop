#!/usr/bin/env bash
# लैब 13 की जाँच: चार्ट और एप्लिकेशन परिभाषा एडमिन को सौंपने के लिए तैयार हैं।
#
# यह जाँच जानबूझकर लोकल है। टेनेंट ApplicationDefinition को अप्लाई नहीं
# कर सकता (ऑब्जेक्ट cluster-scoped है), इसलिए उसे क्लस्टर में ढूँढना व्यर्थ है:
# ऑब्जेक्ट का न होना प्रतिभागी की गलती नहीं है। हम वह जाँचते हैं जिसके लिए वह जिम्मेदार है:
# चार्ट बनता है, स्कीमा काम करती है, परिभाषा पार्स होती है और चार्ट के साथ मेल खाती है।
#
# लैब फ़ोल्डर से चलाएँ:
#   cd labs/13-catalog && ./check.sh
# क्लस्टर अनिवार्य नहीं है: KUBECONFIG के बिना दो जाँचें चेतावनी के साथ छोड़ दी जाएँगी,
# त्रुटि के साथ नहीं।

LAB_NAME="13-catalog"
LAB_TITLE="लैब 13 · Cozystack कैटलॉग में आपका अपना एप्लिकेशन"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- टूल -----------------------------------------------------------
# helm के बिना जाँचने के लिए कुछ नहीं है, इसलिए स्क्रिप्ट यहीं तुरंत रुक जाती है और आगे
# दर्जनों एक जैसी विफलताएँ नहीं उगलती।
if ! command -v helm >/dev/null 2>&1; then
  fail "इस मशीन पर helm इंस्टॉल नहीं है" \
       "इसे इंस्टॉल करें: brew install helm (macOS) या https://helm.sh/docs/intro/install/ — इसके बिना लैब की जाँच नहीं हो सकती"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm मौजूद है (${HELM_VER})"
evidence "helm संस्करण" "$HELM_VER"

# --- चार्ट मौजूद है ---------------------------------------------------------
# हम «चार्ट टूटा है» को «स्क्रिप्ट गलत फ़ोल्डर से चलाई गई» से अलग करते हैं। दूसरी गलती
# पहली से ज़्यादा आम है, और उसका संदेश अलग होना चाहिए।
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "${CHART} में चार्ट नहीं मिला" \
       "स्क्रिप्ट को लैब फ़ोल्डर से चलाएँ: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- लिंटर ----------------------------------------------------------------
# helm lint चार्ट को टेक्स्ट की तरह पढ़ता है: टेम्पलेट में टाइपो, Chart.yaml के गायब
# फ़ील्ड, न मौजूद वैल्यू के संदर्भ खोजता है। यहाँ बात क्लस्टर तक नहीं पहुँचती।
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "चार्ट helm lint पास करता है"
  evidence "helm lint" "$LINT_OUT"
else
  fail "चार्ट helm lint पास नहीं करता" \
       "नीचे दिया गया आउटपुट पढ़ें और बताई गई फ़ाइलें ठीक करें: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- रेंडर ----------------------------------------------------------------
# खाली आउटपुट और केवल टिप्पणियों वाला आउटपुट लिंटर छोड़ देता, इसलिए हम देखते हैं
# कि रेंडर किए गए में एक Deployment है, और सूचीबद्ध करते हैं कि असल में क्या निकला।
# यहाँ मुख्य बात «कमांड चल गई» नहीं, बल्कि «असली ऑब्जेक्ट निकले» है।
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "चार्ट रेंडर होता है, ऑब्जेक्ट निकलते हैं: ${KINDS}"
  evidence "चार्ट क्या रेंडर करता है" "$KINDS"
else
  fail "helm template ने एक भी Deployment नहीं निकाला" \
       "रेंडर त्रुटि देखें: helm template main chart"
  evidence "helm template आउटपुट" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- चार्ट को असली क्लस्टर स्वीकार करता है ----------------------------------
# पूरे लैब सेट में एकमात्र जाँच जो मैनिफ़ेस्ट को टेक्स्ट से नहीं, बल्कि असली क्लस्टर
# स्कीमा से मिलाती है।
#
# `helm lint` और `helm template` टेम्पलेट जाँचते हैं, पर Kubernetes स्कीमा नहीं: गलत
# जगह पर फ़ील्ड वाला मैनिफ़ेस्ट वे छोड़ देते हैं, पर क्लस्टर उसे अस्वीकार करता है। खुद पर
# अनुभव किया — गलती से volumes में डाला गया securityContext दोनों पास कर गया और सिर्फ़
# सर्वर पर टूटा। यह जाँच वहाँ ज़रूरी है जहाँ चार्ट अप्लाई किया जाता है।
#
# lint और template इसकी जगह क्यों नहीं लेते:
#   helm lint      चार्ट की बनावट देखता है: फ़ाइलें मौजूद हैं, टेम्पलेट पार्स होते हैं;
#   helm template  वैल्यू भरता है और टेक्स्ट निकालता है — पर वे फ़ील्ड क्या हैं और ऐसे
#                  ऑब्जेक्ट में होते भी हैं या नहीं, यह वह न जानता है न जान सकता है;
#   apply --dry-run=server मैनिफ़ेस्ट को apiserver को भेजता है, वह उसे टाइप स्कीमा और
#                  admission-कंट्रोल से गुज़ारता है और जवाब देता है कि स्वीकार करता या नहीं,
#                  इस दौरान कुछ बनाए बिना। यहीं से `unknown field` और नीति द्वारा अस्वीकृति —
#                  ठीक वही, जिस पर चार्ट ग्राहक के यहाँ ठोकर खाता है।
# --dry-run=client फ़्लैग यह जाँच नहीं देता: वह मैनिफ़ेस्ट को आपकी मशीन पर पार्स करता है।
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # अधिकारों की अस्वीकृति और स्कीमा की अस्वीकृति अलग चीज़ें हैं, इन्हें मिलाना नहीं चाहिए। टेनेंट
  # एक्सेस (~/.kube/config) के तहत Deployment और ConfigMap पर अधिकार बिल्कुल नहीं हैं, इसलिए यहाँ
  # Forbidden आएगा — और यह चार्ट की गुणवत्ता के बारे में कुछ नहीं कहता। असल जाँच केवल
  # `lab` क्लस्टर के एक्सेस से संभव है, जहाँ आप पूर्ण अधिकारी हैं।
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "सर्वर-साइड चार्ट जाँच छोड़ी गई: वर्तमान एक्सेस इसे चलाने की अनुमति नहीं देता" \
         "इसे अपने क्लस्टर के एक्सेस से चलाएँ: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "क्लस्टर रेंडर किए गए चार्ट को अस्वीकार करता है" \
         "देखें: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "सर्वर की अस्वीकृति" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "क्लस्टर रेंडर किए गए चार्ट को स्वीकार करता है — फ़ील्ड और उनकी जगहें सही हैं"
  fi
else
  warn "क्लस्टर पर चार्ट जाँच छोड़ी गई: एक्सेस नहीं है" \
       "helm template को kubectl apply --dry-run=server से चलाने के लिए KUBECONFIG सेट करें"
fi

# --- पैरामीटर वाकई मैनिफ़ेस्ट तक पहुँचते हैं -------------------------
# चार्ट बन और रेंडर हो सकता है, फिर भी पैरामीटर कहीं न भरा जाए —
# उदाहरण के लिए, वैल्यू को टेम्पलेट में संख्या के रूप में लिख दिया गया। इसलिए हर पैरामीटर को असल में जाँचते हैं:
# एक जानबूझकर असामान्य वैल्यू देते हैं और उसे तैयार मैनिफ़ेस्ट में खोजते हैं।
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "replicas पैरामीटर मैनिफ़ेस्ट तक पहुँचता है (--set replicas=5 से replicas: 5 मिलता है)"
else
  fail "replicas पैरामीटर मैनिफ़ेस्ट तक नहीं पहुँचता" \
       "templates/deployment.yaml में replicas: {{ .Values.replicas }} होना चाहिए"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "external पैरामीटर Service टाइप को LoadBalancer में बदल देता है"
else
  warn "external पैरामीटर Service टाइप नहीं बदलता" \
       "चार्ट की खराबी नहीं, पर Cozystack कैटलॉग की परंपरा: एप्लिकेशन पर external फ़ील्ड का अर्थ ठीक बाहरी एक्सेस है"
fi

# --- स्कीमा वाकई सुरक्षा देती है ------------------------------------------
# ऐसी स्कीमा जो कुछ भी अस्वीकार नहीं करती, बेकार है। हम जाँचते हैं कि वह अस्वीकार करती है।
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "वैल्यू स्कीमा जानबूझकर गलत वैल्यू को अस्वीकार नहीं करती (replicas=abc पास हो गया)" \
       "जाँचें कि values.yaml के पास values.schema.json है और उसमें replicas को integer घोषित किया गया है"
else
  ok "वैल्यू स्कीमा गलत टाइप को अस्वीकार करती है (replicas=abc पास नहीं होता)"
fi

# --- ApplicationDefinition: अनिवार्य फ़ील्ड ------------------------------
# प्रतिभागी परिभाषा को अप्लाई नहीं कर सकता, यानी उसे apiserver की अस्वीकृति भी नहीं दिखेगी।
# इसलिए अनिवार्य फ़ील्ड यहीं गिनते हैं: इनमें से किसी के बिना एडमिन को अपने यहाँ अस्वीकृति
# मिलेगी, और सुलझाना फ़ाइल के लेखक को पड़ेगा।
if [ ! -f "$APPDEF" ]; then
  fail "${APPDEF} नहीं मिला" \
       "फ़ाइल चार्ट के पास होनी चाहिए; इसे लैब रिपॉज़िटरी से लें"
else
  MISSING=""
  # हम कुंजियों को पंक्ति-दर-पंक्ति खोजते हैं, YAML पार्स किए बिना: PyYAML हर मशीन पर नहीं होता,
  # और एक फ़ाइल की जाँच के लिए निर्भरता खींचना उचित नहीं।
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
    fail "ApplicationDefinition में फ़ील्ड कम हैं:${MISSING}" \
         "README में दिए विवरण से मिलाएँ — इनमें से किसी के बिना एडमिन को अप्लाई के समय अस्वीकृति मिलेगी"
  fi

  # --- परिभाषा में स्कीमा पार्स होती है और चार्ट की स्कीमा से मेल खाती है ---------
  # ये एक ही चीज़ की दो अलग प्रतियाँ हैं, और इनके बीच कोई संबंध नहीं है।
  # अलग हो गईं — तो डैशबोर्ड में फ़ॉर्म वे फ़ील्ड नहीं दिखाएगा जिनकी चार्ट अपेक्षा करता है।
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "ApplicationDefinition में openAPISchema खाली है" \
         "वहाँ chart/values.schema.json की सामग्री एक पंक्ति में डालें"
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
    print("DIFF केवल परिभाषा में: %s | केवल चार्ट में: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "परिभाषा में स्कीमा पार्स होती है और चार्ट की स्कीमा से मेल खाती है (${CMP#SAME })"
        evidence "एप्लिकेशन पैरामीटर" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "परिभाषा में स्कीमा चार्ट की स्कीमा से अलग हो गई: ${CMP#DIFF }" \
             "इन्हें मेल में लाएँ: openAPISchema की सामग्री chart/values.schema.json एक पंक्ति में है"
        ;;
      BADJSON*)
        fail "openAPISchema JSON के रूप में पार्स नहीं होता: ${CMP#BADJSON }" \
             "स्कीमा 'openAPISchema: |-' के नीचे सही JSON की एक पंक्ति होनी चाहिए"
        ;;
      *)
        warn "स्कीमाओं का मिलान नहीं हो सका (${CMP})" \
             "हाथ से जाँचें कि openAPISchema chart/values.schema.json से मेल खाता है"
        ;;
    esac
  fi

  # --- आइकन ---------------------------------------------------------------
  # डैशबोर्ड base64 में पैक किए गए SVG की अपेक्षा करता है और तस्वीर के लिए कहीं नहीं जाता। यहाँ त्रुटि
  # खामोश होती है: मैनिफ़ेस्ट अप्लाई हो जाएगा, पर कैटलॉग में आइकन की जगह खाली रहेगी। इसलिए स्ट्रिंग को
  # डिकोड करते हैं और देखते हैं कि अंदर वाकई SVG है।
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
             "स्ट्रिंग फिर से बनाएँ: base64 -i icon.svg | tr -d '\\n' (Linux पर: base64 -w0 icon.svg)"
        ;;
      *)
        fail "आइकन डिकोड होता है, पर यह SVG नहीं है" \
             "डैशबोर्ड ठीक SVG की अपेक्षा करता है; रास्टर तस्वीर को वह कचरे की तरह दिखाएगा"
        ;;
    esac
  fi
fi

# --- अधिकार: यहाँ अस्वीकृति अपेक्षित है --------------------------------------
# यह प्रतिभागी की जाँच नहीं, बल्कि प्लेटफ़ॉर्म की बनावट की पुष्टि है। इसलिए
# जवाब `no` सफलता है, और `yes` खुश होने का नहीं, हैरान होने का कारण है।
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "पुष्टि हुई: आपको ApplicationDefinition अप्लाई करने की अनुमति नहीं है (can-i -> no)"
      evidence "ApplicationDefinition पर अधिकार" \
        "kubectl auth can-i create applicationdefinitions -> no
ऑब्जेक्ट cluster-scoped है और सभी टेनेंट के लिए कैटलॉग बदलता है, इसलिए इसे प्लेटफ़ॉर्म एडमिन अप्लाई करता है।"
      ;;
    yes)
      warn "आपके पास ApplicationDefinition अप्लाई करने के अधिकार हैं (can-i -> yes)" \
           "इसका मतलब आप एडमिन अकाउंट से काम कर रहे हैं, टेनेंट से नहीं; लैब टेनेंट अकाउंट के लिए बनी है"
      ;;
    *)
      warn "क्लस्टर से अधिकारों के बारे में नहीं पूछा जा सका" \
           "लैब पास करने में बाधा नहीं: जाँच लोकल है, यहाँ क्लस्टर की ज़रूरत नहीं"
      ;;
  esac
else
  warn "क्लस्टर से पूछताछ नहीं हुई (KUBECONFIG सेट नहीं है या जवाब नहीं देता)" \
       "जाँच लोकल है, यहाँ क्लस्टर की ज़रूरत नहीं। अधिकारों की अस्वीकृति देखने के लिए: export KUBECONFIG=~/.kube/config"
fi

finish
