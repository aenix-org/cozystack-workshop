#!/usr/bin/env bash
# Перевірка лаби 2: самовідновлення.
#
# Перевіряємо не «команди набрані», а стан кластера після лаби: застосунок знову
# обслуговує запити через Service, віддає ім'я своєї копії, і це ім'я належить
# реально працюючому Pod. Плюс шукаємо сліди того, що копії перестворювалися.
#
# Скрипт нічого не видаляє і не створює, окрім одноразового Pod для перевірки
# доступності сервісу зсередини кластера — він прибирає себе сам.

LAB_NAME="02-selfheal"
LAB_TITLE="Лаба 2 · Вбити Pod і подивитися, що буде"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# RFC3339 з kubectl (завжди UTC з Z) в unix-секунди. Через python3, тому що
# BSD date на macOS і GNU date на Linux розбирають дати по-різному, а python є всюди,
# де працює lib.sh.
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- застосунок взагалі є ---------------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "застосунку ${APP} немає в кластері" \
       "наприкінці лаби його треба було повернути: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "Що є в namespace" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "застосунок ${APP} відновлено: готових копій ${HAVE} з ${WANT}"
else
  fail "копій готово ${HAVE} із замовлених ${WANT}" \
       "дивіться kubectl describe deployment ${APP} і kubectl get pods -l app=${APP}"
fi
evidence "Стан застосунку" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- ланцюжок Deployment -> ReplicaSet -> Pod ------------------------------
# Сенс лаби в тому, що копію повертає ReplicaSet, а не «кластер взагалі».
# Якщо власником Pod виявився не ReplicaSet, значить учасник підняв Pod руками,
# і самовідновлення він не побачить.
# Рахуємо Pod поіменно, а не збираємо унікальні види власників: у Pod без
# ownerReferences jsonpath віддає порожній рядок, `sort -u` схлопує його в невидимий
# елемент, і `*ReplicaSet*` матчиться, поки хоч один Pod керується ReplicaSet.
# Через це сторонній Pod, піднятий руками, проходив перевірку непоміченим.
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "немає жодного Pod з міткою app=${APP}" \
         "поверніть застосунок: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "жоден Pod ${APP} не керується ReplicaSet — самовідновлення не буде" \
         "схоже, Pod піднятий руками (kubectl run). Видаліть його і застосуйте ../01-deploy/rickroll.yaml"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "мітку app=${APP} носять сторонні Pod: ${PODS_BY_RS} із ${PODS_TOTAL} керуються ReplicaSet" \
           "решта потраплять у балансування і віддаватимуть чужу відповідь — знайдіть їх: kubectl get pods -l app=${APP} -o wide"
      evidence "Власники Pod" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "копіями керує ReplicaSet — ланцюжок Deployment → ReplicaSet → Pod цілий"
    evidence "Хто чий власник" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- сліди перестворення копій ---------------------------------------------
# Прямих доказів «Pod вбивали» кластер не зберігає. Є два непрямі, і обидва достатні:
# Pod помітно молодший за свій Deployment, і в подіях ReplicaSet більше одного створення.
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "копія молодша за застосунок на ${DELTA} с — значить попередню прибирали, а цю створили натомість"
  else
    warn "копія майже ровесниця застосунку (різниця ${DELTA} с)" \
         "якщо ви відновлювали застосунок цілком у самому кінці — це нормально; інакше крок з видаленням Pod не виконано"
  fi
  evidence "Вік об'єктів" "deployment створений: ${DEP_TS}
pod створений:     ${POD_TS}
різниця:           ${DELTA} с"
else
  warn "не вдалося порівняти вік Pod і застосунку" \
       "потрібен python3 в PATH; на проходження лаби це не впливає"
fi

# Події живуть близько години, тому їхня відсутність — не провал, а зауваження.
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "в подіях кластера ${CREATES} створення копії — самовідновлення справді спрацьовувало"
  evidence "Події створення копій" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "в подіях кластера видно створення копії лише ${CREATES} раз" \
       "події зберігаються близько години і могли спливти"
fi

# Жодна з двох ознак окремо не блокуюча: події живуть близько години,
# а вік збігається у того, хто законно відновив застосунок цілком наприкінці лаби.
# Але якщо НЕ виконано жодної — копію не видаляли зовсім, і лаба не зроблена. Без цієї
# зв'язки скрипт друкував «ЛАБУ ЗДАНО» одразу після лаби 1, не дочекавшись жодного видалення.
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "слідів самовідновлення не знайдено: копію не видаляли" \
       "видаліть копію: kubectl delete pod -l app=${APP} — і запустіть перевірку протягом години, поки живі події"
fi

# --- сервіс реально обслуговує ---------------------------------------------
# Головна перевірка по суті: не «об'єкт є», а «через Service приходить сторінка
# і в ній ім'я живої копії».
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} не віддав сторінку зсередини кластера" \
       "перевірте ендпоінти: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "сторінка віддається, але ім'я копії в неї не підставилося" \
       "втрачено ConfigMap rickroll-conf: застосуйте ../01-deploy/rickroll.yaml цілком"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "у відповіді Service немає імені копії" \
         "сторінка прийшла не від нашого застосунку — перевірте kubectl get svc ${APP} -o yaml"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service віддає сторінку, її обслужила жива копія ${SERVED}"
    evidence "Відповідь Service (фрагмент)" \
      "$(printf '%s' "$BODY" | grep -o "вас обслужив Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "сторінку віддала копія ${SERVED}, але такого Pod в кластері вже немає" \
         "почекайте десяток секунд і запустіть перевірку знову — ймовірно, копія змінювалася просто зараз"
  fi
fi

# --- готовність до наступної лаби ------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "кількість копій повернено до однієї — лаба 3 почнеться з чистого аркуша"
else
  warn "зараз замовлено копій: ${WANT}" \
       "перед лабою 3 поверніть одну: kubectl scale deployment ${APP} --replicas=1"
fi

finish
