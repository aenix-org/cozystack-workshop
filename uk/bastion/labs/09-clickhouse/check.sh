#!/usr/bin/env bash
# Перевірка лаби 9: у ClickHouse лежить журнал проходів і по ньому рахується звіт.
#
# Перевіряємо не «сервіс створено», а суть: таблиця є, рядків не менше мільйона,
# дані різноманітні та з вираженими піками, звіт по місяцях відпрацьовує за
# мілісекунди, а запит по одній колонці читає малу частку таблиці — тобто
# колоночність працює, а не заявлена.
#
# Запуск (у кожному новому вікні термінала змінні задаються заново):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # свій номер замість XX
#   export CH_PASSWORD='пароль користувача analyst'
#   cd labs/09-clickhouse && ./check.sh
#
# Пароль не друкується і в звіт не потрапляє.
# Скрипт піднімає одноразові Pod з curl, тому працює близько хвилини.

# Ім'я та заголовок потрібні спільній бібліотеці: вона підписує ними звіт-артефакт.
# У lib.sh лежать ok/fail/warn/evidence/finish і перевірки оточення нижче — щоб
# п'ятнадцять скриптів перевірки друкували однаково, а не кожен по-своєму.
LAB_NAME="09-clickhouse"
LAB_TITLE="Лаба 9 · Аналітика на мільйоні рядків"
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
# інакше — запустіть як CH_APP=ім'я ./check.sh, правити скрипт не потрібно.
# Адреса внутрішня, з самого кластера: 8123 — порт HTTP-інтерфейсу ClickHouse.
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "Адреса ClickHouse" "$CH_URL"

# --- 1. сервіс взагалі відповідає ------------------------------------------
# /ping не потребує пароля, тому це перша і найдешевша перевірка:
# відділяє «немає зв'язку» від «зв'язок є, пароль не той».
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse відповідає за внутрішньою адресою тенанта"
else
  fail "ClickHouse не відповідає за адресою ${CH_HOST}" \
       "перевірте номер тенанта в COZY_TENANT та ім'я застосунку (за замовчуванням 'analytics'; інакше CH_APP=ім'я ./check.sh); у дашборді застосунок має бути в готовому стані"
  finish
  exit $?
fi

# Усе, що далі, потребує входу в базу. Без пароля скрипт не вгадує і не мовчить,
# а чесно каже, що вміст бази не перевірено, і завершує звіт: інакше
# учасник вирішив би, що перевірку пройдено.
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "не задано змінну CH_PASSWORD, вміст бази не перевірено" \
       "export CH_PASSWORD='пароль користувача ${CH_USER}' і запустіть скрипт знову; пароль видно в дашборді, секрет clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# Виконати SQL зі стандартного вводу і повернути відповідь.
# Окрема функція, а не in_cluster_curl: запит іде тілом POST, а тілу
# потрібен стандартний ввід, якого у спільної функції немає.
# Пароль іде в Pod змінною оточення з тимчасового Secret'а, а не аргументом:
# усе, що потрапляє в args, видно будь-кому з `get pods`, лежить в etcd і світиться в audit
# log. Сама лаба про це й каже — перевіряти її скриптом, який робить навпаки,
# було б подвійним стандартом.
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# Дістати число з блоку statistics відповіді у форматі JSON.
chstat() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
key = sys.argv[1]
src = d.get("statistics", {}) if key in ("elapsed",) else d
val = src.get(key, d.get("statistics", {}).get(key))
if val is None:
    sys.exit(1)
print(val)
' "$1" 2>/dev/null
}

# --- 2. таблиця існує -------------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "таблиця ${CH_TABLE} існує"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse не прийняв пароль користувача ${CH_USER}" \
         "звірте пароль у дашборді: застосунок ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "таблиці ${CH_TABLE} немає" \
         "створіть її: ch < 01-schema.sql (розбір схеми — у README)"
  fi
  finish
  exit $?
fi

# --- 3. скільки даних і наскільки вони різноманітні -------------------------
# Одним запитом замість шести: кожен виклик ch_query піднімає Pod, і шість
# Pod поспіль перетворили б перевірку на хвилинне очікування на рівному місці.
STATS="$(ch_query <<SQL
SELECT
    (SELECT count() FROM ${CH_TABLE}),
    (SELECT uniqExact(entrance) FROM ${CH_TABLE}),
    (SELECT uniqExact(pass_type) FROM ${CH_TABLE}),
    (SELECT uniqExact(toStartOfMonth(created_at)) FROM ${CH_TABLE}),
    (SELECT max(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT min(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT sum(data_uncompressed_bytes) FROM system.columns
      WHERE database = currentDatabase() AND table = '${CH_TABLE}')
SQL
)"

ROWS="$(printf '%s' "$STATS" | awk 'NR==1{print $1}')"
UNIQ_ENT="$(printf '%s' "$STATS" | awk 'NR==1{print $2}')"
UNIQ_TYPE="$(printf '%s' "$STATS" | awk 'NR==1{print $3}')"
UNIQ_MONTH="$(printf '%s' "$STATS" | awk 'NR==1{print $4}')"
PEAK_MAX="$(printf '%s' "$STATS" | awk 'NR==1{print $5}')"
PEAK_MIN="$(printf '%s' "$STATS" | awk 'NR==1{print $6}')"
TABLE_BYTES="$(printf '%s' "$STATS" | awk 'NR==1{print $7}')"

for v in ROWS UNIQ_ENT UNIQ_TYPE UNIQ_MONTH PEAK_MAX PEAK_MIN TABLE_BYTES; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*) eval "$v=0" ;;
  esac
done

if [ "$ROWS" -ge 1000000 ]; then
  ok "у таблиці ${ROWS} рядків — мільйон згенеровано"
else
  fail "у таблиці ${ROWS} рядків, очікувався мільйон" \
       "запустіть генератор: ch < 02-generate.sql (розбір генератора — у README)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "дані різноманітні: входів ${UNIQ_ENT}, типів пропуску ${UNIQ_TYPE}, місяців ${UNIQ_MONTH}"
else
  fail "дані одноманітні: входів ${UNIQ_ENT}, типів ${UNIQ_TYPE}, місяців ${UNIQ_MONTH}" \
       "на таких даних звіт нічого не покаже; перегенеруйте: TRUNCATE TABLE ${CH_TABLE}, потім ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "у даних є виражені піки по годинах (найнавантаженіша година до найтихішої — не менше ніж удвічі)"
  evidence "Розподіл по годинах" "максимум за годину: ${PEAK_MAX}
мінімум за годину: ${PEAK_MIN}"
else
  warn "піків по годинах не видно: максимум ${PEAK_MAX}, мінімум ${PEAK_MIN}" \
       "звіт «коли піки» на таких даних безглуздий; перевірте, що генератор відпрацював цілком"
fi

# --- 4. звіт по місяцях рахується швидко ------------------------------------
REPORT="$(ch_query <<SQL
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM ${CH_TABLE}
GROUP BY month
ORDER BY month
FORMAT JSON
SQL
)"

ELAPSED="$(printf '%s' "$REPORT" | chstat elapsed)"
READ_ROWS="$(printf '%s' "$REPORT" | chstat rows_read)"

if [ -z "$ELAPSED" ]; then
  fail "звіт по місяцях не відпрацював" \
       "запустіть його вручну: ch < 03-report.sql і подивіться на текст помилки"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # Поріг тримаємо близько до того, що обіцяє лаба. Попередні п'ять секунд зараховували
  # як успіх звіт за чотири секунди — при тому що в шапці лаби написано
  # «рахується за мілісекунди». Скрипт не повинен підтверджувати те, чого не перевірив.
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "звіт по місяцях пораховано за ${MS} мс, прочитано рядків: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "звіт по місяцях рахувався ${MS} мс — це не той порядок, про який лаба" \
         "мільйон рядків у вільному тестовому середовищі вкладається в десятки мілісекунд; перевірте, що сервіс не зайнятий сусіднім навантаженням, і повторіть"
  else
    warn "звіт по місяцях пораховано за ${MS} мс — повільніше очікуваного, але в межах розумного" \
         "у зайнятому тестовому середовищі так буває; у вільному такий звіт вкладається в десятки мілісекунд"
  fi
  evidence "Звіт по місяцях" "час: ${MS} мс
прочитано рядків: ${READ_ROWS}"
fi

# --- 5. колоночність працює, а не заявлена ----------------------------------
# Запит торкається однієї маленької колонки. Якщо сховище колоночне, прочитано
# буде помітно менше, ніж важить уся таблиця.
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# Обидві величини НЕСТИСНЕНІ: `bytes_read` у статистиці запиту — це розпакований
# обсяг, а з system.columns береться `data_uncompressed_bytes`. Порівняння з
# `data_compressed_bytes` давало частку від розміру на диску і друкувало учаснику
# невірне число — на добре стиснутій таблиці вона могла перевалити за сто відсотків.
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "Читання однієї колонки" "прочитано байт: ${NARROW_BYTES}
уся таблиця без стиснення, байт: ${TABLE_BYTES}
частка: ${SHARE}%"
  # Поріг, а не просто «менше цілого». Одна вузька колонка із семи має дати одиниці
  # відсотків; «99% замість 100%» формально менше, але нічого не доводить — а саме
  # це твердження лаба й виносить у заголовок.
  if [ "$SHARE" -le 25 ]; then
    ok "запит по одній колонці прочитав ${SHARE}% даних таблиці — колоночне зберігання працює"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "запит по одній колонці прочитав ${SHARE}% даних таблиці — менше цілого, але виграш скромніший за очікуваний" \
         "очікувалися одиниці відсотків; перевірте, що запит звертається до однієї вузької колонки, а не до кількох"
  else
    warn "запит по одній колонці прочитав не менше всієї таблиці" \
         "так буває на дуже маленьких таблицях; перевірте, що рядків справді мільйон"
  fi
else
  warn "не вдалося виміряти, скільки прочитав вузький запит" \
       "виконайте вручну: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON і подивіться bytes_read"
fi

# finish друкує підсумок і складає звіт-артефакт у файл; код повернення — ненульовий,
# якщо хоч одна перевірка провалилася.
finish
