#!/usr/bin/env bash
# Спільна бібліотека для скриптів перевірки лабораторних.
# Підключається так:  . "$(dirname "$0")/../../check/lib.sh"
#
# Навмисно НЕ використовується `set -e`: скрипт зобов'язаний прогнати всі перевірки та
# показати повну картину, а не зупинятися на першій же невдачі. Читач запускає його
# саме тоді, коли застряг, — обривати його на півдорозі означає приховати половину відповіді.

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# Кольори лише коли вивід іде в термінал: у файлі та в CI escape-послідовності
# читаються як сміття.
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- машиночитний результат --------------------------------------------------
# result-<лаба>.json збирається паралельно людському звіту та містить ЛИШЕ
# ідентифікатор перевірки та її результат. Формулювання, вивід команд і свідчення туди
# не потрапляють: у markdown-звіт складаються хвости логів контейнерів, зовнішні адреси
# балансувальників, адреси вузлів і шлях до файлу доступу разом з ім'ям користувача.
# Вичистити це регулярками ненадійно — надійно не породжувати.
#
# Ідентифікатор виводиться сам: порядковий номер перевірки в лабі плюс короткий хеш
# формулювання. Номер дає стійкість, хеш ловить непомітну правку тексту —
# якщо формулювання змінили, служба це побачить і не прийме мовчки за ту саму перевірку.
_checks=()
_seq=0
_record() {   # _record <статус> <формулювання>
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

# fail "що не так" "що з цим робити"
fail() {
  _record fail "$1"
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - що робити: $2")
}

warn() {
  _record warn "$1"
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - примітка: $2")
}

# evidence "заголовок" "значення" — потрапляє в артефакт, у термінал не друкується.
# Свідчення потрібні, щоб звіт можна було комусь показати і він щось означав.
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# Ранні виходи зобов'язані залишати звіт: README радить «приходьте в спільноту,
# додавши звіт скрипта», а раніше при недоступному кластері додавати було нічого —
# тобто звіту не було саме в тому випадку, заради якого він і потрібен.
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "не задано змінну KUBECONFIG" \
         "спочатку: export KUBECONFIG=~/lab.kubeconfig (у кожному новому вікні термінала)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "кластер не відповідає за KUBECONFIG=${KUBECONFIG}" \
         "якщо kubectl get nodes висить без відповіді — сервер керування кластером не піднявся; дивіться статус застосунку Kubernetes у дашборді та події тенанта на нестачу квоти (exceeded quota)"
    evidence "Файл доступу" "$KUBECONFIG"
    evidence "Відповідь кластера" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s не задано змінну COZY_TENANT\n' "$_C_FAIL" "$_C_OFF"
    printf '         %sнаприклад: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# Час без GNU-розширень: BSD date на macOS не розуміє `-d`.
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# Куди складаються машиночитні результати. Поза репозиторієм навмисно: усередині
# клона їх стер би перший же `git pull` або зміна гілки, а збираються вони тижнями.
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # Ідентифікатор кластера — uid namespace kube-system. Він однаковий для всіх
  # прогонів на одному кластері й різний у різних людей, а головне — його не можна
  # «ввести руками», на відміну від імені тенанта.
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
    verdict="ЛАБУ ЗДАНО"
  else
    verdict="Є НЕЗАКРИТІ ПУНКТИ"
  fi

  _write_result_json "$([ "$_fail" -eq 0 ] && echo passed || echo failed)"

  printf '\n'
  printf 'перевірок: %d · пройдено: %d · провалено: %d · попереджень: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# Звіт: ${LAB_TITLE}"
    echo
    echo "- Дата: $(_now)"
    echo "- Підсумок: **${verdict}**"
    echo "- Перевірок: ${total} (пройдено ${_pass}, провалено ${_fail}, попереджень ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- Тенант: \`${COZY_TENANT}\`"
    echo
    echo "## Перевірки"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## Свідчення"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "Звіт отримано скриптом \`check.sh\` з лабораторних Cozystack."
    echo "Перевірялася працездатність по суті, а не факт застосування маніфестів."
  } > "$report"

  printf 'звіт: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# Версія САМЕ сервера. `kubectl version -o json` друкує і клієнтську, і серверну;
# наївний grep по gitVersion бере першу-ліпшу — клієнтську — і звіт починає
# брехати про версію кластера. Помилитися тут легко, тому винесено в бібліотеку.
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# Людиночитний розмір: Kubernetes віддає allocatable то в Ki, то в голих байтах,
# і «3258002390» у звіті читачеві нічого не каже.
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

# Запустити команду в одноразовому Pod, передавши секрети через змінні оточення,
# задані з тимчасового Secret'а, а не аргументами командного рядка.
#
# Навіщо так. Усе, що потрапляє в args Pod, видно будь-кому, у кого є `get pods`,
# лежить в etcd, іде в audit log і світиться в `ps` на вузлі. Лаби про бази даних
# окремо пояснюють, що пароль у командному рядку — погана практика; перевіряти їх
# скриптом, який робить рівно це, було б подвійним стандартом.
#
# Використання:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c 'команда, що читає $KEY1'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # Secret створюється з stdin, тому значення не потрапляють в аргументи kubectl.
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # securityContext тут теж обов'язковий: без нього Pod не створиться в кластері
  # з профілем `restricted`, і перевірки лаб з базами даних не відпрацюють.
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

# Зібрати override з securityContext, що проходить профіль `restricted`.
# Винесено окремо: та сама надбудова потрібна кожному одноразовому Pod,
# а без неї скрипти перевірки не працюють у суворих кластерах.
# Аргументи команди передаються КОЖЕН ОКРЕМО, а JSON збирається пітоном:
# ручне екранування лапок у bash уже призводило до битого override та мовчазної
# відмови Pod — помилку при цьому глушив 2>/dev/null.
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

# Виконати команду в одноразовому Pod та повернути її вивід.
# Потрібно там, де перевіряється доступність сервісу зсередини кластера: з ноутбука
# ClusterIP не видно. Pod видаляється за собою в будь-якому разі.
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext обов'язковий: у кластері з профілем `restricted` Pod без нього
  # не створиться, і учасник не зможе перевірити лабу взагалі.
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` видаляє Pod, лише поки клієнт приаттачений: обрив, таймаут або Ctrl+C
  # залишають його висіти. Явне видалення — щоб скрипт не смітив у кластері.
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# Зібрати відповіді від КІЛЬКОХ запитів поспіль, по одній на рядок.
#
# Один запит при кількох копіях за сервісом — лотерея: сторонній Pod з тією ж
# міткою потрапляє в балансування, але одиночна вибірка може його не зачепити, і перевірка
# радісно зеленіє на підміненому контенті. Перевірено: вісім з двадцяти запитів
# ішли самозванцю, а перевірка чотири рази поспіль казала «здано».
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
