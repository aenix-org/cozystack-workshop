#!/usr/bin/env bash
# Перевірка лаби 14: спостережуваність справді працює.
#
# «Учасник подивився на графік» перевірити неможливо, і вдавати, що можна, нечесно.
# Тому перевіряємо те, без чого графік неможливий:
#   1) агент збору метрик працює в кластері,
#   2) він надсилає зібране до вашого тенанта, а не в нікуди,
#   3) збір логів теж працює — без нього половина лаби безглузда,
#   4) у кластері є слід навантаження з лаби 3, який на графіках можна знайти.

LAB_NAME="14-observability"
LAB_TITLE="Лаба 14 · Спостережуваність: знайти свій сплеск на графіках"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- namespace збору --------------------------------------------------------
# Namespace сам по собі нічого не доводить: платформа кладе туди ж metrics-server,
# який встановлюється в будь-який кластер з etcd і від доповнення не залежить. Перевіряємо його
# наявність лише щоб відрізнити «кластер недоступний» від «збір вимкнено».
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "у кластері немає namespace ${MON_NS} — кластер відповідає не так, як очікувалося" \
       "увімкніть доповнення: дашборд -> Kubernetes -> lab -> змінити -> Addons -> Monitoring agents. Зверніть увагу: записи з'являться лише з цього моменту"
  finish
  exit $?
fi

# --- агент метрик -----------------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "агент збору метрик працює (Pod vmagent: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "агент збору метрик є, але не працює (${VMAGENT_RUNNING} з ${VMAGENT_TOTAL} у Running)" \
       "дивіться причину: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "у ${MON_NS} немає жодного Pod vmagent — доповнення Monitoring agents вимкнено" \
       "увімкніть його: дашборд -> Kubernetes -> lab -> змінити -> Addons -> Monitoring agents. Записи почнуть накопичуватися лише з цього моменту, минуле не повернути"
fi
evidence "Pod збору в ${MON_NS}" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- куди саме їдуть метрики -------------------------------------------
# Працюючий агент, який пише в нікуди, виглядає точно так само, як робочий.
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "метрики надсилаються до тенанта${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "метрики надсилаються за адресою, не схожою на тенантну" \
           "це може бути нормально, якщо викладач налаштував спільне сховище; адреса у свідченнях"
      ;;
  esac
  evidence "Куди надсилаються метрики" "$RW_URL"
else
  warn "не вдалося прочитати адресу надсилання метрик" \
       "подивіться руками: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- збір логів -------------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "збір логів працює на всіх вузлах (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "збір логів запущено не на всіх вузлах (${FB_READY:-0} з ${FB_DESIRED})" \
       "дивіться: kubectl -n ${MON_NS} get pods | grep fluent-bit — без нього крок з пошуком по журналах не спрацює"
else
  warn "збирач логів fluent-bit не знайдено" \
       "джерело vlogs-generic у Grafana буде порожнім; крок з пошуком по журналах виконати не вийде"
fi

# --- чи є що шукати на графіках -----------------------------------------
# Метрики можуть збиратися ідеально, але якщо навантаження не було, шукати нічого.
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "слід навантаження є: автомасштабування спрацьовувало (востаннє ${LAST_SCALE})"
    evidence "Стан автомасштабування" "$(kubectl get hpa rickroll 2>/dev/null)
останнє спрацювання: ${LAST_SCALE}
зараз копій: ${CUR:-?}, потрібно: ${DES:-?}"
  else
    warn "автомасштабування налаштовано, але жодного разу не спрацьовувало" \
         "сходинку зростання копій ви не знайдете; повторіть навантаження з лаби 3 генератором fortio"
  fi
else
  warn "у кластері немає HorizontalPodAutoscaler з іменем rickroll" \
       "кроки з графіками в цій лабі спираються на лабу 3; без неї знайдете лише сплеск процесора, але не сходинку"
fi

# --- самі метрики про застосунок ----------------------------------------------
# Опосередковано, але по суті: якщо Pod застосунку живі, їхнє споживання на графіках є.
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "Pod застосунку на місці (${APP_PODS} шт.) — їхнє споживання видно на графіках"
  evidence "Pod застосунку" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "Pod застосунку rickroll у кластері немає" \
       "історичні метрики за час лаби 3 при цьому збереглися; просто виставте в Grafana той діапазон часу"
fi

# --- де шукати Grafana -----------------------------------------------------
# Не перевірка, а допомога: адресу Grafana учасники шукають найдовше.
: "${COZY_KUBECONFIG:=$HOME/.kube/config}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "Grafana для ваших метрик: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
метрики тенанта ${TNS} зберігаються в namespace ${MON_TARGET}"
    else
      warn "моніторинг вашого тенанта живе в ${MON_TARGET}, але адресу Grafana прочитати не вдалося" \
           "якщо ${MON_TARGET} — не ваш namespace, значить Grafana спільна: запитайте адресу у викладача"
      evidence "Моніторинг тенанта" "namespace з моніторингом: ${MON_TARGET}"
    fi
  else
    warn "не вдалося визначити, куди йдуть метрики тенанта ${TNS}" \
         "адресу Grafana запитайте у викладача або знайдіть у дашборді: застосунок Monitoring -> Ingress"
  fi
else
  warn "адресу Grafana не визначено" \
       "задайте COZY_TENANT і COZY_KUBECONFIG, і скрипт знайде її сам; на складання лаби це не впливає"
fi

finish
