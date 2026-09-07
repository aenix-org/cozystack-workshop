#!/usr/bin/env bash
# Перевірка лаби 0: навчальний кластер піднявся і ви до нього підключилися.
#
# Перевіряємо не «об'єкт створено», а що кластер працює по суті:
#   1) кластер lab відповідає за вашим файлом доступу (KUBECONFIG=~/lab.kubeconfig),
#   2) хоча б один вузол у стані Ready,
#   3) на вузлах є вільні ресурси під майбутні застосунки.
# Якщо задано COZY_TENANT — додатково дивимося у кластері КЕРУВАННЯ, що замовлення
# Kubernetes/lab дійшло до Ready і що ввімкнено збір метрик (без нього лаба 14 порожня).
#
# Запускається на віртуалці, з теки цієї лаби:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # для перевірок з боку тенанта (необов'язково)
#     cd labs/00-cluster && ./check.sh
#
# Скрипт лише читає — стан кластера не змінює.
LAB_NAME="00-cluster"
LAB_TITLE="Лаба 0 · Свій кластер Kubernetes"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Без доступу до самого кластера lab перевіряти нічого — це і є головний
# доказ лаби. need_kubeconfig зупинить скрипт із зрозумілою підказкою,
# якщо KUBECONFIG не задано або кластер не відповідає.
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) Підключення до кластера lab -------------------------------------------
# need_kubeconfig вже переконався, що сервер відповідає. Фіксуємо це окремим
# результатом і кладемо версію сервера в звіт.
KVER="$(server_version)"
ok "кластер lab відповідає — файл доступу робочий"
[ -n "$KVER" ] && evidence "Версія сервера кластера lab" "$KVER"

# --- 2) Вузли в строю ---------------------------------------------------------
# Рахуємо, скільки вузлів у стані Ready. Порожній список означає, що кластер
# піднявся, але вузлова група md0 ще розгортається.
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "вузли в строю: ${READY_NODES} з ${TOTAL_NODES} у стані Ready"
  [ -n "$NODES_WIDE" ] && evidence "Вузли кластера" "$NODES_WIDE"
else
  fail "жоден вузол не в стані Ready (вузлів усього: ${TOTAL_NODES:-0})" \
       "зачекайте пару хвилин, поки вузлова група md0 розгорнеться; статус — у дашборді на застосунку lab, або: kubectl get nodes"
  evidence "Вузли кластера" "${NODES_WIDE:-немає вузлів}"
fi

# --- 3) Чи є місце під майбутні застосунки ----------------------------------
# allocatable першого вузла: якщо ресурсів немає, далі нічого не запуститься.
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "на вузлах є ресурси під застосунки (на вузлі: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "Вільні ресурси вузла (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "не вдалося прочитати вільні ресурси вузлів" \
       "зазвичай це тимчасово — повторіть за хвилину"
fi

# --- 4) З боку кластера керування (якщо задано тенант) -----------------
# Не обов'язково для лаби 0: підключення до самого кластера вище вже все довело.
# Але якщо тенантний доступ є — підтвердимо замовлення і перевіримо збір метрик.
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "тенантний доступ ${COZY_KUBECONFIG} не знайдено — замовлення кластера з боку керування не перевірялося" \
         "це не провал лаби; шлях задається: export COZY_KUBECONFIG=~/.kube/workshop"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "у кластері керування замовлення Kubernetes/lab у стані Ready"
    elif [ -n "$LAB_READY" ]; then
      warn "замовлення Kubernetes/lab ще не Ready (зараз: ${LAB_READY})" \
           "кластер уже відповідає, платформа ще зводить його до заданого; погляньте: kubectl --kubeconfig ~/.kube/workshop -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "не знайшов замовлення Kubernetes/lab у тенанті ${TENANT_NS}" \
           "якщо кластер ви називали інакше — підставте своє ім'я; або роль у тенанті не дає цю команду (не помилка лаби)"
    fi
    # Збір метрик: лаба 14 спирається на дані, які накопичуються з моменту ввімкнення.
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "збір метрик увімкнено (знадобиться в лабі 14)"
    elif [ -n "$LAB_READY" ]; then
      warn "збір метрик вимкнено — лаба 14 залишиться без даних" \
           "увімкнути: дашборд → застосунок lab → Addons → Monitoring agents (заднім числом метрики не з'являться)"
    fi
  fi
else
  warn "COZY_TENANT не задано — перевірки з боку кластера керування пропущені" \
       "не обов'язково для лаби 0; щоб увімкнути: export COZY_TENANT=workshopXX"
fi

finish
