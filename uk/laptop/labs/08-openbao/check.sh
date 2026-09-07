#!/usr/bin/env bash
# Перевірка лаби 8: пароль винесено з маніфесту в OpenBao і він живе за правилами.
#
# Перевіряємо не «об'єкт створено», а суть: сховище розпечатане, секрет читається
# за токеном, версій більше однієї (отже, ротація справді була), аудит
# увімкнено, а в застосованому маніфесті застосунку немає паролів відкритим текстом.
#
# Жоден секрет до звіту не потрапляє. Значення не друкуються ніде.
#
# Скрипт піднімає одноразові Pod з curl, тому працює близько хвилини.

# LAB_NAME і LAB_TITLE ідуть у шапку звіту. Нижче підключається спільна бібліотека
# перевірок: з неї беруться ok / warn / fail / evidence / finish і функції, які
# запускають одноразові Pod всередині кластера. need_kubeconfig і need_tenant
# зупиняють скрипт заздалегідь, якщо доступ або номер тенанта не задано: інакше
# провалиться все одразу і за звітом неможливо буде зрозуміти причину.
LAB_NAME="08-openbao"
LAB_TITLE="Лаба 8 · Секрети не в маніфесті"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- куди дивитися ---------------------------------------------------------
# COZY_TENANT учасник задає як `workshop07`, але namespace називається
# `tenant-workshop07`. Приймаємо обидва написання: помилитися тут легко, а
# повідомлення про помилку було б невиразним («сервіс не відповідає»).
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Що і де шукаємо. BAO_APP — ім'я застосунку OpenBao у тенанті, і воно входить до
# внутрішньої адреси сховища: назвали застосунок інакше — запускайте перевірку
# як BAO_APP=ім'я ./check.sh. SECRET_PATH — шлях усередині сховища, за яким
# лаба кладе пароль від бази.
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "Адреса сховища" "$BAO_URL"

# Дістати значення за ланцюжком ключів із JSON на стандартному вводі.
# Повертає 1, якщо шляху немає або це не JSON, — так той, хто викликає, відрізняє
# «ключа немає» від «порожнє значення».
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1:]:
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        sys.exit(1)
print("" if d is None else d)
' "$@" 2>/dev/null
}


# Запит до OpenBao. Токен передаємо змінною оточення з тимчасового Secret'а,
# а НЕ заголовком в аргументах: аргументи Pod бачить будь-хто з `get pods`, вони лежать
# в etcd і йдуть в audit log. Тут це root-токен сховища — рівно той витік,
# проти якого написана вся лаба.
#
# Визначення стоїть ДО першого виклику: коли воно лежало всередині гілки else, найперша
# перевірка викликала неіснуючу функцію і лаба не складалася ніколи.
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. сховище відповідає -------------------------------------------------
# Перший же запит відповідає одразу на два питання: чи піднявся застосунок і чи вірно
# вказано номер тенанта. Питаємо стан печаті — це єдина адреса, яку
# OpenBao віддає без токена. Порожня відповідь далі означає «зв'язку немає», і всі перевірки
# вмісту втрачають сенс.
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao не відповідає за адресою ${BAO_URL}" \
       "перевірте номер тенанта в COZY_TENANT та ім'я застосунку (за замовчуванням 'secrets'; інакше BAO_APP=ім'я ./check.sh); у дашборді застосунок має бути в готовому стані"
else
  ok "OpenBao відповідає за внутрішньою адресою тенанта"
fi

# --- 2. ініціалізовано ----------------------------------------------------
# Ініціалізація — разова операція, при якій сховище створює собі майстер-ключ
# і перший токен. Поки її не зробили, всередині немає нічого: ні секретів, ні місця під них.
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "сховище ініціалізовано"
elif [ -n "$SEAL" ]; then
  fail "сховище не ініціалізовано" \
       "виконайте: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 і збережіть вивід"
fi

# --- 3. розпечатано --------------------------------------------------------
# Запечатане сховище — звичайний стан після перезапуску Pod: дані на диску
# лежать, але прочитати їх нічим, поки не введено unseal-ключ. Звідси й вимога
# перевіряти поведінку, а не наявність об'єкта: «застосунок готовий» і «секрети віддаються» —
# це два різні твердження, і друге з першого не випливає.
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "сховище розпечатане й обслуговує запити"
  evidence "Стан сховища" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "сховище запечатане — на будь-який запит воно відповідає відмовою 503" \
       "виконайте: kubectl exec bao-workbench -- bao operator unseal <ваш-unseal-ключ>"
  evidence "Стан сховища" "$SEAL"
fi

# --- 4. секрет на місці і читається -----------------------------------------
# Далі потрібен токен. Без нього перевіряти нічого, але й мовчки пропускати не можна:
# читач має побачити, чого не вистачає.
if [ -z "$SEAL" ]; then
  # Зв'язку немає — перевіряти вміст безглуздо. Мовчимо, щоб не завалити
  # звіт чотирма провалами, у яких одна й та сама причина, названа вище.
  warn "вміст сховища не перевірено: до OpenBao немає зв'язку" \
       "розберіться зі зв'язком, потім запустіть скрипт знову"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "не задано змінну BAO_TOKEN, тому вміст сховища не перевірено" \
       "export BAO_TOKEN='root-токен, надрукований під час першого розпечатування сховища' і запустіть скрипт знову"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "секрет secret/${SECRET_PATH} читається за токеном, поле password не порожнє"
    # У звіт кладемо номер версії, а не значення.
    evidence "Секрет" "шлях: secret/${SECRET_PATH}
поле password: є (значення приховано)
поточна версія: ${DATA_VERSION:-невідома}"
  else
    fail "за шляхом secret/${SECRET_PATH} немає поля password" \
         "покладіть його: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; якщо рушій ще не увімкнено — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. ротація справді була --------------------------------------------
  # Одна-єдина версія секрета означає, що його поклали й забули. Ротація —
  # те, заради чого сховище й заводять: змінити пароль в одному місці, а не шукати його
  # по маніфестах. Рахуємо не обіцянки, а версії: їх лік сховище веде саме.
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "секрет змінювався: версій ${CUR_VER}, отже ротація проходила не лише на словах"
    evidence "Історія версій секрета" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "у секрета всього одна версія — ротацію не робили" \
         "змініть пароль: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<новий> і перезапустіть застосунок"
  fi

  # --- 6. політика вузька, а не «все можна» ---------------------------------
  # Політика і є відповідь на питання «що зможе зробити той, хто здобув токен». Тому
  # дивимося не на факт її існування, а на вміст: чи видана вона на конкретний
  # шлях замість усього сховища і чи лише на читання.
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "політика passes-read існує"
    evidence "Політика passes-read" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "політика видана на конкретний шлях, а не на все сховище"
    else
      warn "політика є, але шляху secret/data/${SECRET_PATH} у ній не видно" \
           "перевірте, що в політиці вказано приставку data: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "політика дозволяє не лише читання" \
           "застосунку достатньо read; зайві права варто прибрати"
    fi
  else
    fail "політику passes-read не знайдено" \
         "створіть її: kubectl exec -i bao-workbench -- bao policy write passes-read - < ваш файл політики (розбір політики — в README)"
  fi

  # --- 7. аудит увімкнено ----------------------------------------------------
  # Без журналу аудиту на питання «хто і коли читав цей секрет» відповісти нічим — а це
  # перше питання, яке ставлять після інциденту. Рахуємо підключені пристрої
  # журналювання: хоча б один має бути.
  AUD="$(bao_get "/v1/sys/audit")"
  AUD_COUNT="$(printf '%s' "$AUD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
data = d.get("data", d)
print(len([k for k in data if isinstance(data.get(k), dict)]))
' 2>/dev/null)"
  case "$AUD_COUNT" in
    ''|*[!0-9]*) AUD_COUNT=0 ;;
  esac
  if [ "$AUD_COUNT" -ge 1 ]; then
    ok "аудит-журнал увімкнено (пристроїв: ${AUD_COUNT})"
    evidence "Аудит-пристрої" "$AUD"
  else
    fail "аудит-журнал не увімкнено — відповісти, хто читав секрет, буде нічим" \
         "увімкніть: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. застосунок у лабораторному кластері ---------------------------------
# Досі ми перевіряли сховище на кластері керування. Далі — ваш кластер lab,
# де живе сам застосунок. Важливий тут не факт, що Deployment створено, а наявність
# готових копій: init-контейнер, що не зумів забрати пароль, не дасть Pod піднятися,
# і саме цей стан треба відрізнити від «все добре».
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "у лабораторному кластері немає застосунку ${APP_DEPLOY}" \
       "застосуйте: kubectl apply -f secrets-demo.yaml (не забувши підставити свій номер тенанта)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "застосунок ${APP_DEPLOY} запущено (готових копій: ${READY})"
  else
    fail "застосунок ${APP_DEPLOY} є, але жодна копія не готова" \
         "дивіться kubectl describe deploy/${APP_DEPLOY} та kubectl logs deploy/${APP_DEPLOY} -c fetch-secret — зазвичай init-контейнер не зміг достукатися до сховища або отримав відмову за токеном"
  fi

  # --- 9. у маніфесті немає паролів відкритим текстом -------------------------
  # Дивимося застосований об'єкт, а не файл на диску: застосувати могли будь-що.
  LEAKS="$(kubectl get deploy "$APP_DEPLOY" -o json 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
suspicious = re.compile(r"(?i)pass|secret|token|key|cred")
spec = d.get("spec", {}).get("template", {}).get("spec", {})
found = []
for c in list(spec.get("initContainers", [])) + list(spec.get("containers", [])):
    for e in c.get("env", []):
        if "value" in e and suspicious.search(e.get("name", "")):
            found.append("%s / env %s задано значенням, а не посиланням" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "у маніфесті застосунку немає змінних з паролем, заданим значенням"
  else
    fail "у маніфесті застосунку залишилися чутливі значення відкритим текстом" \
         "приберіть їх: значення має приходити зі сховища, а в маніфесті — лише посилання. Див. secrets-demo.yaml"
    evidence "Що знайдено в маніфесті" "$LEAKS"
  fi

  # --- 10. застосунок справді отримав секрет ------------------------
  # Останній доказ беремо з логів, а не з опису об'єкта. Маніфест може
  # бути бездоганним, а пароль у Pod так і не приїхати. Дивимося на дві речі одразу:
  # init-контейнер повідомив, що сходив у сховище, і застосунок друкує відбиток —
  # отже, з отриманим паролем він справді працює.
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init-контейнер забрав секрет зі сховища"
    evidence "Лог init-контейнера" "$INIT_LOG"
  else
    fail "не видно, щоб init-контейнер забирав секрет зі сховища" \
         "перевірте kubectl logs deploy/${APP_DEPLOY} -c fetch-secret; якщо контейнера немає — застосовано старий маніфест"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "застосунок працює з отриманим паролем (у лог пишеться відбиток, а не значення)"
    evidence "Лог застосунку" "$APP_LOG"
  else
    fail "у лозі застосунку немає відбитка пароля" \
         "перевірте kubectl logs deploy/${APP_DEPLOY} -c app — контейнер міг не стартувати"
  fi
fi

# --- 11. наївний секрет прибрано ----------------------------------------------
# Зараховуємо «видалено» лише якщо лабу взагалі робили: на чистому кластері секрета
# не було ніколи, і звіт хвалив би учасника за прибирання, якого не відбувалося.
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "у кластері залишився секрет passes-db з наївного ступеня" \
       "він більше не потрібен і містить старий пароль: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "наївний секрет passes-db видалено"
fi

finish
