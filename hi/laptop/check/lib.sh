#!/usr/bin/env bash
# लैब जाँच स्क्रिप्ट्स के लिए साझा लाइब्रेरी।
# इस तरह सोर्स की जाती है:  . "$(dirname "$0")/../../check/lib.sh"
#
# `set -e` का उपयोग जानबूझकर नहीं किया गया है: स्क्रिप्ट को हर जाँच चलानी चाहिए और
# पूरी तस्वीर दिखानी चाहिए, पहली ही विफलता पर रुकना नहीं चाहिए। पाठक इसे ठीक तभी
# चलाता है जब वह अटक जाता है — इसे आधे रास्ते में रोक देना आधे उत्तर को छिपा देता है।

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# रंग केवल तभी जब आउटपुट टर्मिनल पर जाता है: फ़ाइल में और CI में escape
# अनुक्रम कचरे के रूप में पढ़े जाते हैं।
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- मशीन-पठनीय परिणाम -------------------------------------------------------
# result-<lab>.json मानव रिपोर्ट के साथ-साथ बनाई जाती है और इसमें केवल जाँच
# पहचानकर्ता और उसका परिणाम होता है। शब्दांकन, कमांड आउटपुट और साक्ष्य वहाँ नहीं
# जाते: markdown रिपोर्ट में कंटेनर लॉग की पूँछ, बाहरी लोड बैलेंसर पते, नोड पते,
# और उपयोगकर्ता नाम के साथ एक्सेस फ़ाइल का पथ जमा हो जाते हैं। इसे regex से साफ़
# करना अविश्वसनीय है — विश्वसनीय तरीका इसे उत्पन्न ही न करना है।
#
# पहचानकर्ता स्वयं व्युत्पन्न होता है: लैब में जाँच का क्रमांक और शब्दांकन का एक
# छोटा हैश। संख्या स्थिरता देती है, हैश पाठ के मौन संपादन को पकड़ता है — यदि
# शब्दांकन बदला गया, तो सेवा इसे देखेगी और चुपचाप उसी जाँच के रूप में स्वीकार नहीं करेगी।
_checks=()
_seq=0
_record() {   # _record <स्थिति> <शब्दांकन>
  _seq=$((_seq + 1))
  local h
  h="$(printf '%s' "$2" | shasum -a 256 2>/dev/null | cut -c1-8)"
  [ -n "$h" ] || h="00000000"
  _checks+=("$(printf '%s-%02d-%s:%s' "$LAB_NAME" "$_seq" "$h" "$1")")
}

ok() {
  _pass=$((_pass + 1))
  _record ok "$1"
  printf '%s[  OK  ]%s %s\n' "$_C_OK" "$_C_OFF" "$1"
  _lines+=("- **OK** — $1")
}

# fail "क्या ग़लत है" "इसके बारे में क्या करें"
fail() {
  _record fail "$1"
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - क्या करें: $2")
}

warn() {
  _record warn "$1"
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - टिप्पणी: $2")
}

# evidence "शीर्षक" "मान" — आर्टिफ़ैक्ट में जाता है, टर्मिनल पर नहीं छापा जाता।
# साक्ष्य इसलिए मौजूद हैं ताकि रिपोर्ट किसी को दिखाई जा सके और वह कुछ अर्थ रखे।
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# जल्दी निकास को फिर भी एक रिपोर्ट छोड़नी चाहिए: README सलाह देता है «समुदाय में आएँ
# और स्क्रिप्ट की रिपोर्ट संलग्न करें», पर पहले, जब क्लस्टर अनुपलब्ध था तो संलग्न करने के लिए
# कुछ नहीं था — यानी ठीक उसी स्थिति में कोई रिपोर्ट नहीं थी जिसके लिए वह अस्तित्व में है।
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "KUBECONFIG वेरिएबल सेट नहीं है" \
         "पहले: export KUBECONFIG=~/lab.kubeconfig (हर नई टर्मिनल विंडो में)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "क्लस्टर KUBECONFIG=${KUBECONFIG} पर जवाब नहीं दे रहा" \
         "यदि kubectl get nodes बिना जवाब के अटका रहता है — क्लस्टर कंट्रोल प्लेन ऊपर नहीं आया; डैशबोर्ड में Kubernetes एप्लिकेशन की स्थिति और कोटा की कमी (exceeded quota) के लिए टेनेंट इवेंट्स देखें"
    evidence "एक्सेस फ़ाइल" "$KUBECONFIG"
    evidence "क्लस्टर का जवाब" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s COZY_TENANT वेरिएबल सेट नहीं है\n' "$_C_FAIL" "$_C_OFF"
    printf '         %sउदाहरण के लिए: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# GNU एक्सटेंशन के बिना समय: macOS पर BSD date `-d` को नहीं समझता।
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# मशीन-पठनीय परिणाम कहाँ संग्रहीत होते हैं। जानबूझकर रिपॉज़िटरी के बाहर: क्लोन के
# अंदर पहला ही `git pull` या ब्रांच स्विच उन्हें मिटा देता, और वे हफ़्तों में एकत्र होते हैं।
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # क्लस्टर पहचानकर्ता — kube-system नेमस्पेस का uid। यह एक क्लस्टर पर सभी प्रयोगों के
  # लिए समान होता है और अलग-अलग लोगों के बीच भिन्न, और मुख्य बात — इसे टेनेंट नाम के
  # विपरीत «हाथ से टाइप» नहीं किया जा सकता।
  local cluster_uid=""
  cluster_uid="$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  local kver=""
  kver="$(server_version 2>/dev/null || true)"
  CHECKS_LIST="$(printf '%s\n' "${_checks[@]:-}")" \
  LAB="$LAB_NAME" VERDICT="$1" P="$_pass" F="$_fail" W="$_warn" \
  CUID="$cluster_uid" KVER="$kver" TEN="${COZY_TENANT:-}" WHEN="$(_now)" \
  python3 - "$LAB_RESULTS_DIR/result-${LAB_NAME}.json" <<'PYEOF'
import json, os, sys
checks = []
for line in os.environ.get("CHECKS_LIST", "").split("\n"):
    line = line.strip()
    if not line or ":" not in line:
        continue
    cid, status = line.rsplit(":", 1)
    checks.append({"id": cid, "status": status})
doc = {
    "schema_version": 1,
    "lab": os.environ["LAB"],
    "verdict": os.environ["VERDICT"],
    "finished_at": os.environ["WHEN"],
    "totals": {"pass": int(os.environ["P"]), "fail": int(os.environ["F"]),
               "warn": int(os.environ["W"])},
    "env": {"kubernetes_server_version": os.environ.get("KVER") or None,
            "cluster_uid": os.environ.get("CUID") or None,
            "tenant": os.environ.get("TEN") or None},
    "checks": checks,
}
with open(sys.argv[1], "w") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=1)
PYEOF
}

finish() {
  local total=$((_pass + _fail + _warn))
  local report="report-${LAB_NAME}-$(_stamp).md"
  local verdict

  if [ "$_fail" -eq 0 ]; then
    verdict="लैब पास"
  else
    verdict="खुले आइटम बाकी हैं"
  fi

  _write_result_json "$([ "$_fail" -eq 0 ] && echo passed || echo failed)"

  printf '\n'
  printf 'जाँचें: %d · पास: %d · विफल: %d · चेतावनियाँ: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# रिपोर्ट: ${LAB_TITLE}"
    echo
    echo "- दिनांक: $(_now)"
    echo "- परिणाम: **${verdict}**"
    echo "- जाँचें: ${total} (पास ${_pass}, विफल ${_fail}, चेतावनियाँ ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- टेनेंट: \`${COZY_TENANT}\`"
    echo
    echo "## जाँचें"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## साक्ष्य"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "यह रिपोर्ट Cozystack लैब्स की \`check.sh\` स्क्रिप्ट द्वारा तैयार की गई थी।"
    echo "इसने वास्तविक कार्यक्षमता की गुण-दोष के आधार पर जाँच की, न कि केवल यह तथ्य कि मैनिफ़ेस्ट लागू किए गए थे।"
  } > "$report"

  printf 'रिपोर्ट: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# विशेष रूप से सर्वर संस्करण। `kubectl version -o json` क्लाइंट और सर्वर दोनों छापता है;
# gitVersion पर एक सरल grep पहला मैच लेता है — क्लाइंट वाला — और रिपोर्ट क्लस्टर संस्करण
# के बारे में झूठ बोलने लगती है। यहाँ ग़लती करना आसान है, इसलिए इसे लाइब्रेरी में रखा गया है।
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# मानव-पठनीय आकार: Kubernetes allocatable को कभी Ki में, कभी नंगे बाइट्स में देता है,
# और रिपोर्ट में «3258002390» पाठक को कुछ नहीं बताता।
human_bytes() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, re
v = sys.argv[1].strip()
m = re.fullmatch(r'(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|K|M|G|T)?', v)
if not m:
    print(v); raise SystemExit
n = float(m.group(1))
mult = {'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4,
        'K':1000,'M':1000**2,'G':1000**3,'T':1000**4}.get(m.group(2), 1)
b = n * mult
for unit, size in (('Gi',1024**3), ('Mi',1024**2), ('Ki',1024)):
    if b >= size:
        print(f"{b/size:.1f}{unit}"); break
else:
    print(f"{int(b)}B")
PY
}

# एक बार-उपयोग वाले पॉड में कमांड चलाएँ, रहस्यों को कमांड-लाइन आर्गुमेंट्स के बजाय
# एक अस्थायी Secret से सेट किए गए पर्यावरण वेरिएबल्स के माध्यम से पास करते हुए।
#
# ऐसा क्यों। पॉड के args में जाने वाली हर चीज़ `get pods` रखने वाले किसी भी व्यक्ति को
# दिखती है, etcd में रहती है, audit log में पहुँचती है, और नोड पर `ps` में दिखती है।
# डेटाबेस लैब्स अलग से समझाती हैं कि कमांड लाइन पर पासवर्ड एक बुरी प्रथा है; उन्हें ठीक
# ऐसा करने वाली स्क्रिप्ट से जाँचना दोहरा मापदंड होगा।
#
# उपयोग:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c 'कमांड जो $KEY1 पढ़ती है'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # Secret को stdin से बनाया जाता है, इसलिए मान kubectl आर्गुमेंट्स में नहीं जाते।
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # securityContext यहाँ भी अनिवार्य है: इसके बिना `restricted` प्रोफ़ाइल वाले क्लस्टर में
  # पॉड नहीं बनेगा, और डेटाबेस लैब्स की जाँचें नहीं चलेंगी।
  local cmd_json
  cmd_json="$(printf '%s\n' "$@" | python3 -c 'import sys,json;print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image="$image" --pod-running-timeout=90s \
    --overrides="{\"spec\":{\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65532,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"$name\",\"image\":\"$image\",\"stdin\":true,\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}},\"envFrom\":[{\"secretRef\":{\"name\":\"$sec\"}}],\"command\":$cmd_json}]}}" \
    2>/dev/null
  local rc=$?

  kubectl delete secret "$sec" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# `restricted` प्रोफ़ाइल पास करने वाले securityContext के साथ एक override बनाएँ।
# अलग से निकाला गया: वही ऐड-ऑन हर बार-उपयोग वाले पॉड को चाहिए, और इसके बिना
# जाँच स्क्रिप्ट्स सख़्त क्लस्टरों में काम नहीं करतीं।
# कमांड आर्गुमेंट्स प्रत्येक अलग-अलग पास किए जाते हैं, और JSON python द्वारा असेंबल किया
# जाता है: bash में हाथ से कोट्स एस्केप करना पहले ही एक टूटे हुए override और पॉड की मौन
# विफलता का कारण बन चुका है — जिसमें त्रुटि 2>/dev/null द्वारा दबा दी गई थी।
_restricted_overrides() {
  local name="$1" image="$2"; shift 2
  python3 - "$name" "$image" "$@" <<'PYJSON'
import sys, json
name, image, *cmd = sys.argv[1:]
print(json.dumps({"spec": {
    "securityContext": {"runAsNonRoot": True, "runAsUser": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": name, "image": image, "stdin": True,
                    "securityContext": {"allowPrivilegeEscalation": False,
                                        "capabilities": {"drop": ["ALL"]}},
                    "command": cmd}]}}))
PYJSON
}

# एक बार-उपयोग वाले पॉड में कमांड चलाएँ और उसका आउटपुट लौटाएँ।
# वहाँ आवश्यक जहाँ क्लस्टर के अंदर से सेवा की पहुँच जाँची जाती है: लैपटॉप से
# ClusterIP दिखाई नहीं देता। पॉड हर हाल में अपने पीछे सफ़ाई कर देता है।
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext अनिवार्य है: `restricted` प्रोफ़ाइल वाले क्लस्टर में इसके बिना पॉड
  # नहीं बनेगा, और प्रतिभागी लैब की जाँच बिल्कुल नहीं कर पाएगा।
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` पॉड को केवल तब तक हटाता है जब तक क्लाइंट अटैच रहता है: डिस्कनेक्ट, टाइमआउट
  # या Ctrl+C उसे लटका छोड़ देते हैं। स्पष्ट डिलीट — ताकि स्क्रिप्ट क्लस्टर में कचरा न फैलाए।
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# लगातार कई अनुरोधों से जवाब एकत्र करें, प्रति पंक्ति एक।
#
# एक सेवा के पीछे कई प्रतियों के साथ एकल अनुरोध एक लॉटरी है: उसी लेबल वाला एक भटका हुआ
# पॉड लोड बैलेंसिंग में आ जाता है, पर एकल नमूना उसे चूक सकता है, और जाँच खुशी-खुशी बदले
# हुए कंटेंट पर हरी हो जाती है। सत्यापित: बीस में से आठ अनुरोध नकली के पास गए, और जाँच
# लगातार चार बार «पास» बोली।
in_cluster_curl_many() {
  local url="$1" times="${2:-8}"
  local name="check-$$-$RANDOM"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      sh -c "for i in \$(seq 1 $times); do curl -s --max-time 10 '$url'; echo; done")" \
    2>/dev/null
  local rc=$?
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}
