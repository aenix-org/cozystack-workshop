#!/usr/bin/env bash
# Перевірка лаби 10: у MongoDB лежать перепустки різної форми, і за ними шукають.
#
# Перевіряємо не «сервіс створено», а суть: у колекції є документи всіх чотирьох
# форм, пошук за вкладеним полем і всередину списку працює, на рідкісне поле
# побудовано розріджений індекс, валідатор схеми ввімкнено, а документів без типу
# не залишилось.
#
# Запуск (у кожному новому вікні термінала змінні задаються заново):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # свій номер замість XX
#   export MONGO_PASSWORD='пароль користувача passapp'
#   cd labs/10-mongodb && ./check.sh
#
# Пароль не друкується і до звіту не потрапляє.
# Скрипт піднімає одноразові Pod, тому працює близько хвилини.

# Ім'я і заголовок потрібні спільній бібліотеці: вона підписує ними звіт-артефакт.
# У lib.sh лежать ok/fail/warn/evidence/finish і перевірки оточення нижче — щоб
# п'ятнадцять скриптів перевірки друкували однаково, а не кожен по-своєму.
LAB_NAME="10-mongodb"
LAB_TITLE="Лаба 10 · Документне сховище"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Обидві перевірки зупиняють скрипт зі зрозумілим повідомленням, якщо не задано файл доступу
# до кластера або номер тенанта. Без них далі сипалися б помилки kubectl.
need_kubeconfig
need_tenant

# COZY_TENANT учасник задає як `workshop07`, а namespace називається
# `tenant-workshop07`. Приймаємо обидва написання.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Імена за замовчуванням — ті самі, що в лабі. Запис ${X:-значення} означає «взяти
# змінну оточення, а якщо її немає, підставити значення»: назвали застосунок
# інакше — запустіть як MONGO_APP=ім'я ./check.sh, правити скрипт не потрібно.
# Адреса внутрішня, із самого кластера; rs0 в імені — це набір реплік, у якому
# наша єдина копія і живе.
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "Адреса MongoDB" "$MONGO_HOST"

# --- 1. чи є взагалі зв'язок до порту ---------------------------------------
# MongoDB на своєму порту відповідає на HTTP-запит зрозумілою фразою про те, що
# сюди ходять драйвером, а не браузером. Цього достатньо, щоб відділити
# «ім'я не розв'язується / порт закрито» від «зв'язок є, реквізити не ті».
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB відповідає за внутрішньою адресою тенанта"
else
  fail "до MongoDB немає зв'язку за адресою ${MONGO_HOST}" \
       "перевірте номер тенанта в COZY_TENANT та ім'я застосунку (за замовчуванням 'passes'; інакше MONGO_APP=ім'я ./check.sh); у дашборді застосунок має бути в готовому стані"
  finish
  exit $?
fi

# Усе, що далі, потребує входу в базу. Без пароля скрипт не вгадує і не мовчить,
# а чесно каже, що вміст бази не перевірено, і завершує звіт: інакше
# учасник вирішив би, що перевірку пройдено.
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "не задано змінну MONGO_PASSWORD, вміст бази не перевірено" \
       "export MONGO_PASSWORD='пароль користувача ${MONGO_USER}' і запустіть скрипт знову"
  finish
  exit $?
fi

# Пароль відсотково кодується: символи @ : / ? # % в ньому інакше розвалюють рядок
# підключення, і людина отримує незрозумілу помилку розбору замість «невірний пароль».
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ Рядок підключення містить пароль і передається аргументом Pod. Це свідомий
# компроміс: див. `in_cluster_with_secrets` у check/lib.sh — безпечний шлях є, але
# він несумісний з багаторядковим --eval без переускладнення. Pod живе секунди і
# видаляється за собою; до звіту пароль не потрапляє. У бойових скриптах так не робіть.
#
# Усі перевірки одним заходом: кожен виклик піднімає Pod, і десять Pod поспіль
# перетворили б перевірку на багатохвилинне очікування на рівному місці.
# Назовні віддається один рядок JSON, далі його розбирає python.
# `--overrides` з securityContext: без нього Pod не створиться в кластері з профілем
# `restricted`, і лаба провалиться з причини, що учасника не стосується.
# `--command --` залишається: kubectl об'єднує його з override, де задано лише
# поля безпеки.
# Програма для mongosh. Подвійні лапки всередині неї безпечні: назовні текст іде
# через python, який сам його візьме в лапки, а імена бази й колекції підставляються
# за мітками нижче.
MONGO_EVAL=$(cat <<'JSEOF'

var out = {};
try {
  var c = db.getSiblingDB("__DB__").getCollection("__COLL__");
  out.ok = 1;
  out.total = c.countDocuments({});
  out.types = c.distinct("type").length;
  out.withCar = c.countDocuments({ "car.plate": { $exists: true } });
  out.withArray = c.countDocuments({
    $or: [ { entrances: { $exists: true } }, { members: { $exists: true } } ]
  });
  out.nested = c.countDocuments({ "members.name": { $exists: true } });
  out.typeless = c.countDocuments({ type: { $exists: false } });
  var idx = c.getIndexes();
  out.indexes = idx.map(function (i) { return i.name; });
  out.sparse = idx.filter(function (i) {
    return i.sparse === true || i.partialFilterExpression !== undefined;
  }).map(function (i) { return i.name; });
  var info = db.getSiblingDB("__DB__").getCollectionInfos({ name: "__COLL__" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
JSEOF
)
MONGO_EVAL="${MONGO_EVAL//__DB__/$MONGO_DB}"
MONGO_EVAL="${MONGO_EVAL//__COLL__/$MONGO_COLL}"

# Команда контейнера кладеться ВСЕРЕДИНУ override, а не залишається зовні в `--command --`.
# kubectl застосовує override як JSON merge patch, а в ньому масив containers замінюється
# цілком: заданий зовні `--command` до Pod не доїде, і замість mongosh запустився б
# штатний процес образу — тобто сама база. Так само це зроблено в check/lib.sh.
MONGO_SC="$(python3 - "$MONGO_URI" "$MONGO_EVAL" <<'PYEOF'
import json, sys
uri, script = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {
  "securityContext": {"runAsNonRoot": True, "runAsUser": 999,
                      "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "mongo-check", "image": "mongo:8.0", "stdin": True,
                  "securityContext": {"allowPrivilegeEscalation": False,
                                      "capabilities": {"drop": ["ALL"]}},
                  "command": ["mongosh", "--quiet", uri, "--eval", script]}]}}))
PYEOF
)"

SUMMARY="$(kubectl run "mongo-check" --rm -i --restart=Never --quiet \
  --pod-running-timeout=90s --overrides="$MONGO_SC" \
  --image=mongo:8.0 </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

# Дістати поле з рядка JSON, який надрукував mongosh. Списки склеюються через
# кому, щоб їх можна було показати учаснику як є.
mget() {
  printf '%s' "$SUMMARY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v if not isinstance(v, list) else ", ".join(str(x) for x in v))
' "$1" 2>/dev/null
}

# Те саме, але для чисел: будь-яке неочікуване значення перетворюється на 0, інакше порівняння
# нижче впало б з помилкою арифметики замість зрозумілого FAIL.
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# Якщо відповіді немає зовсім або mongosh повідомив про помилку — далі перевіряти нічого.
# Відмову в автентифікації відокремлено від інших помилок: у неї своя часта причина —
# забутий authSource=admin, і підказка має вести саме до неї.
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB не прийняла реквізити користувача ${MONGO_USER}" \
           "перевірте пароль і те, що в рядку підключення є authSource=admin: користувача заведено в базі admin, а права видано в ${MONGO_DB}" ;;
    *)
      fail "не вдалося виконати запит до бази ${MONGO_DB}${ERR:+: $ERR}" \
           "перевірте вручну: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "підключення до бази ${MONGO_DB} під користувачем ${MONGO_USER} працює"

# --- 2. документи є ---------------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "у колекції ${MONGO_COLL} документів: ${TOTAL}"
else
  fail "у колекції ${MONGO_COLL} лише ${TOTAL} документів, очікувалося не менше чотирьох" \
       "завантажте перепустки: mo < passes.js (розбір файлу — у README)"
fi

# --- 3. форми справді різні -------------------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "у колекції ${TYPES} різних типів перепустки"
else
  fail "різних типів перепустки лише ${TYPES}, очікувалося чотири" \
       "перевірте, що passes.js завантажився цілком: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "є документи з вкладеним об'єктом (car.plate): ${WITH_CAR}"
else
  fail "немає жодного документа з вкладеним об'єктом car" \
       "автомобільна перепустка не завантажилася; повторіть mo < passes.js"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "є документи зі списками (entrances і members): ${WITH_ARRAY}"
else
  fail "документів зі списками ${WITH_ARRAY}, очікувалося не менше двох" \
       "тижнева і групова перепустки не завантажилися; повторіть mo < passes.js"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "пошук усередину списку об'єктів (members.name) знаходить документи"
else
  fail "пошук за members.name нічого не знайшов" \
       "групова перепустка зі списком учасників не завантажилася; повторіть mo < passes.js"
fi

evidence "Склад колекції" "документів: ${TOTAL}
різних типів перепустки: ${TYPES}
з вкладеним об'єктом car: ${WITH_CAR}
зі списками: ${WITH_ARRAY}"

# --- 4. індекс на рідкісне поле ---------------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "побудовано розріджений (або частковий) індекс: ${SPARSE}"
  evidence "Індекси колекції" "усі: ${IDX}
розріджені: ${SPARSE}"
else
  fail "розрідженого індексу немає — пошук за номером машини йде перебором" \
       "створіть: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "Індекси колекції" "усі: ${IDX}"
fi

# --- 5. валідатор схеми ввімкнено -------------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "валідатор схеми ввімкнено (дія при порушенні: ${ACTION:-за замовчуванням})"
  if [ "$ACTION" = "warn" ]; then
    warn "валідатор лише попереджає, але документи приймає" \
         "для бойової колекції потрібен validationAction: error"
  fi
else
  fail "валідатор схеми не ввімкнено — друкарська помилка в імені поля пройде мовчки" \
       "увімкніть: mo < validator.js (див. розбір передбачуваної невдачі в README)"
fi

# --- 6. зіпсовані документи прибрано ----------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "документів без поля type не залишилось"
else
  fail "у колекції ${TYPELESS} документів без поля type — охорона їх не побачить" \
       "знайдіть і приберіть: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish друкує підсумок і складає звіт-артефакт у файл; код повернення — ненульовий,
# якщо хоч одна перевірка провалилася.
finish
