#!/usr/bin/env bash
# Перевірка лаби 3: автомасштабування.
#
# Перевіряємо не «hpa.yaml застосовано», а що механізм живий і здатний ухвалювати рішення:
#   - у контейнера є requests.cpu, інакше відсоток немає від чого рахувати;
#   - HPA існує і націлений саме на наш Deployment;
#   - коридор заданий осмислено (maxReplicas більше одного, інакше нема куди рости);
#   - метрики РЕАЛЬНО збираються: у статусі є число, а не <unknown>;
#   - масштабування вже спрацьовувало, тобто навантаження справді давали.
#
# Скрипт нічого не змінює. Одноразовий Pod піднімається лише щоб перевірити,
# що Fortio відповідає зсередини кластера, і прибирає себе сам.
#
# Запускається на ноутбуці, з теки цієї лаби, за доступом до навчального кластера `lab`
# (не до тенанта на кластері керування):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# Змінна COZY_TENANT тут не потрібна: вся лаба йде всередині кластера `lab`.
#
# Запускати ДО прибирання. Частина перевірок спирається на сліди вже наявного зростання,
# а вони живуть разом з об'єктом HPA: видаліть його — і доводити буде нічим.

# Потрапляють у заголовок звіту та в ім'я файлу report-<лаба>-<дата>.md поруч зі скриптом.
LAB_NAME="03-scale"
LAB_TITLE="Лаба 3 · Навантаження та автомасштабування"
# Спільна бібліотека: ok / fail / warn / evidence / finish, запити зсередини кластера,
# запис звіту. Шлях обчислюється від місця самого скрипта, а не від поточного каталогу.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Без KUBECONFIG kubectl шукає кластер на ноутбуці й валить усе поспіль однією помилкою,
# у якій справжньої причини не розгледіти. Зупиняємося одразу.
need_kubeconfig

# Імена винесені у змінні, щоб збіг імені застосунку та імені HPA
# у цій лабі не виглядав як одне й те саме ім'я, випадково написане двічі.
APP=rickroll
HPA=rickroll

# --- ціль масштабування на місці -------------------------------------------
# Застосунок з лаби 1 — те, чим HPA керує. Якщо його немає, усі подальші
# перевірки посиплються каскадом і учасник отримає десяток помилок замість однієї
# виразної, тому тут єдине місце, де скрипт завершується достроково.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "застосунку ${APP} немає в кластері — масштабувати нема чого" \
       "розгорніть його: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "застосунок ${APP} на місці"

# --- requests.cpu: без нього HPA не рахує відсотки -------------------------
# Найчастіша причина «HPA не працює», і за маніфестом її не видно:
# об'єкт створюється успішно, а TARGETS назавжди лишається <unknown>.
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "у контейнера заданий requests.cpu = ${REQ_CPU} — є від чого рахувати відсотки"
  evidence "Ресурси контейнера" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-не заданий}"
else
  fail "у контейнера ${APP} не заданий requests.cpu" \
       "HPA за Utilization без нього не працює; застосуйте ../01-deploy/rickroll.yaml заново"
fi

# --- сам HPA ---------------------------------------------------------------
# Перевіряємо не лише наявність об'єкта, а й на кого він націлений. HPA з помилкою
# у scaleTargetRef створюється успішно й виглядає у списку як робочий, але всю лабу
# керує неіснуючим застосунком.
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "у кластері немає HorizontalPodAutoscaler з іменем ${HPA}" \
       "застосуйте його: kubectl apply -f hpa.yaml (перевірку запускайте до прибирання)"
  evidence "Що є з автомасштабування" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA} націлений на Deployment/${APP}"
else
  fail "HPA ${HPA} керує об'єктом ${TARGET_KIND}/${TARGET_NAME}, а не Deployment/${APP}" \
       "виправте scaleTargetRef у hpa.yaml і застосуйте заново"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "коридор заданий: від ${MINR} до ${MAXR} копій — рости є куди"
else
  fail "верхня межа коридору дорівнює ${MAXR:-не задана} — нема куди рости" \
       "у hpa.yaml має бути maxReplicas більше одиниці"
fi

# --- ціль за метрикою ------------------------------------------------------
# Тут warn, а не fail: варіант з AverageValue (поріг у міліядрах) теж робочий,
# лаба розбирає лише один із двох. Завалювати за нього було б неправдою.
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "поріг заданий: ${TGT_VAL}% від requests.cpu (${REQ_CPU:-?})"
else
  warn "поріг заданий не у відсотках від requests (тип: ${TGT_TYPE:-немає})" \
       "лаба розбирає варіант Utilization; на працездатність це не впливає"
fi

# --- ГОЛОВНЕ: метрики реально збираються -----------------------------------
# Саме тут видно різницю між «об'єкт створено» та «механізм працює».
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "метрики збираються: поточне навантаження ${CUR_UTIL}% від requests, HPA ухвалює рішення"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA ухвалює рішення (ScalingActive=True), поточне значення метрики ще не віддано"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA не отримує метрики — у TARGETS буде <unknown>, вирішувати йому нема на чому" \
       "перші дві хвилини після apply це нормально, зачекайте та повторіть; якщо не пройшло — kubectl top pods і kubectl describe hpa ${HPA}"
  evidence "Чому HPA не активний" "${REASON:-причина не вказана у статусі}"
fi

evidence "Стан HPA" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server відповідає напряму -------------------------------------
# Дублює попередню перевірку з іншого боку та розділяє дві різні поломки:
# «метрик немає в усьому кластері» та «метрики є, але HPA до них не дістався».
# Перше лагодить адміністратор кластера, друге — учасник у своєму маніфесті.
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` за відсутності Pod друкує «No resources found» і повертає 0 —
# без явної перевірки на порожнечу це давало зелений там, де метрик немає взагалі.
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top не віддає споживання Pod" \
       "у кластері немає працюючого metrics-server — без нього автомасштабування за CPU неможливе"
  evidence "Відповідь kubectl top" "$TOP"
else
  ok "metrics-server віддає споживання Pod ${APP}"
  evidence "Споживання копій" "$TOP"
fi

# --- масштабування справді спрацьовувало -----------------------------------
# lastScaleTime живе стільки ж, скільки сам HPA, тому перевірка не залежить
# від того, чи минув строк подій кластера, чи ні.
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# Однієї позначки часу замало: вона проставляється і при скороченні копій, тобто
# з'являється навіть у того, хто підняв репліки руками й дав HPA прибрати зайві. Шукаємо
# саме зростання ЗА НАВАНТАЖЕННЯМ — подію з перевищенням порога.
#
# І навпаки: сама позначка живе не завжди. На кластері, де навантаження давали годину
# тому, lastScaleTime може бути порожнім, а події ще живі — тому події
# перевіряються ПЕРШИМИ, інакше виконана лаба хибно завалюється.
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA піднімав кількість копій через навантаження — подія з перевищенням порога на місці"
  evidence "Масштабування" "подій зростання: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-немає}
currentReplicas: ${CUR_REPL:-невідомо}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA змінював кількість копій (останній раз: ${LAST_SCALE})"
  evidence "Позначка про масштабування" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-невідомо}"
else
  fail "слідів роботи автомасштабування немає" \
       "дайте навантаження з Fortio: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: потрібен у лабі 4 ---------------------------------------------
# До самої лаби 3 стосунку вже не має, тому warn, а не fail. Сенс у тому, щоб
# учасник дізнався про зникнення генератора тут, а не посеред викочування під навантаженням,
# коли зупинятися й розгортати його буде недоречно.
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "генератор навантаження Fortio працює й відповідає зсередини кластера"
  else
    warn "Fortio розгорнуто, але його вебінтерфейс не відповів" \
         "перевірте: kubectl rollout status deployment/fortio і kubectl logs deploy/fortio"
  fi
else
  warn "Fortio у кластері немає" \
       "якщо збираєтеся робити лабу 4, він там знадобиться: kubectl apply -f fortio.yaml"
fi

finish
