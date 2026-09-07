#!/usr/bin/env bash
# Перевірка лаби 7: кеш справді пришвидшує, і це видно в цифрах.
#
# Головна перевірка тут поведінкова, а не структурна. Скрипт сам бере невикористаний
# ідентифікатор, запитує його двічі й дивиться: першого разу має бути промах на сотні
# мілісекунд, другого — влучання на одиниці. Маніфест із правильними змінними оточення
# таку перевірку не пройде, якщо кеш насправді не відповідає.
#
# Два кластери: KUBECONFIG — ваш кластер lab, COZY_KUBECONFIG — кластер керування
# Cozystack, де живе керований сервіс Redis.

# LAB_NAME і LAB_TITLE потрапляють у шапку звіту. Далі підключається спільна бібліотека
# перевірок: з неї беруться ok / warn / fail / evidence / finish і, головне,
# in_cluster_curl — вона піднімає одноразовий Pod із curl УСЕРЕДИНІ кластера. Зсередини,
# а не з віртуалки: сервіси лаби назовні не виставлені, за іменем passes-api їх видно
# лише з кластера. need_kubeconfig і need_tenant зупиняють скрипт заздалегідь,
# якщо доступ або номер тенанта не задані, — інакше всі перевірки проваляться разом
# і зі звіту не можна буде зрозуміти причину.
LAB_NAME="07-redis"
LAB_TITLE="Лаба 7 · Кеш перед повільним бекендом"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# Імена й адреси, на які дивиться вся перевірка, зібрані в одному місці: шукати їх
# за текстом скрипта не доведеться. COZY_KUBECONFIG можна перевизначити ззовні,
# якщо тенантний доступ у вас лежить не за замовчуванням.
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# Два скорочення на весь скрипт: kget звертається до кластера lab (того, що в KUBECONFIG),
# cozy — до кластера керування Cozystack. Повідомлення про помилки гасяться навмисно:
# відсутність об'єкта тут — звичайна ситуація, про яку скрипт скаже своїми словами
# і з підказкою, а не чужим текстом від kubectl.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# Дістати поле з JSON. Без jq: його немає на голій macOS, а python3 є всюди,
# де працює решта бібліотеки перевірок.
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- керований сервіс Redis на кластері керування ------------------------------
# Redis живе не у вашому кластері lab, а в тенанті на кластері керування: це
# керований сервіс, платформа тримає його сама. Права в тенанті в усіх різні, тому
# ні відмова в доступі, ні відсутність кубконфіга лабу не провалюють — роботу кеша
# нижче перевіряємо напряму, живими запитами, а це і є справжній доказ.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "не знайдено тенантний кубконфіг ${COZY_KUBECONFIG} — стан Redis не перевірявся" \
       "вкажіть шлях: export COZY_KUBECONFIG=~/.kube/config"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "не вдалося переглянути застосунки Redis у тенанті ${TENANT_NS}" \
         "роль у тенанті може не давати цю команду — це не помилка лаби; роботу кеша перевіряємо нижче напряму"
  elif [ -z "$REDIS_LIST" ]; then
    fail "у тенанті ${TENANT_NS} немає жодного застосунку Redis" \
         "створіть його в дашборді: Створити застосунок -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis «${R_NAME}» готовий, копій даних: ${R_REPLICAS:-за замовчуванням}"
    else
      warn "Redis «${R_NAME}» є, але не повідомляє про готовність" \
           "дивіться його стан у дашборді; піднімається три-п'ять хвилин"
    fi
    evidence "Redis у тенанті" "$REDIS_LIST"
  fi
fi

# --- повільний довідник на місці і справді повільний -------------------------
# Без цієї перевірки порівняння «до і після» нічого не означає: якщо довідник
# відповідає миттєво, пришвидшувати нічого і кеш нічим виміряти.
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "довідник ${HR} не працює" \
       "застосуйте hr-legacy.yaml і подивіться kubectl describe pod -l app=hr-legacy"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "довідник відповідає за ${HR_MS} мс — є що пришвидшувати"
    evidence "Затримка довідника" "${HR_MS} мс на запит /employee"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "довідник ${HR} не відповів на запит" \
         "дивіться kubectl logs -l app=hr-legacy"
  else
    warn "довідник відповідає за ${HR_MS} мс, це надто швидко для замірювання" \
         "перевірте, що в hr-legacy.yaml задано MODE=hr і HR_DELAY=800ms"
  fi
fi

# --- застосунок налаштований на кеш ------------------------------------------
# Розбираємо оточення контейнера пітоном, а не jsonpath: фільтри jsonpath за
# вкладеними списками поводяться по-різному в різних версіях kubectl, а нам важливо,
# щоб перевірка однаково працювала в усіх.
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

# Скарги розбираються по порядку — від найзагальнішої до найконкретнішої: немає
# застосунку, немає змінної, лишилася заглушка замість адреси. Порядок тут не косметика:
# інакше учасник отримає пораду «підставте адресу Redis» у момент, коли в нього
# ще не розгорнуто сам сервіс, і шукатиме помилку не там.
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "у кластері lab немає застосунку ${APP}" \
       "застосуйте passes-api.yaml, підставивши адресу свого Harbor"
elif [ -z "$REDIS_ADDR" ]; then
  fail "у ${APP} не задано змінну REDIS_ADDR — кеш вимкнено" \
       "застосуйте патч: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "у патчі лишилася адреса-заглушка REDIS-ADDR" \
       "підставте адресу свого Redis, наприклад rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "застосунок налаштований на кеш за адресою ${REDIS_ADDR}, термін життя запису ${TTL:-за замовчуванням} с"
fi

# Дивимося лише на наявність імені змінної, значення не читаємо і не друкуємо ніде.
# Звіт про лабу люди пересилають одне одному і додають до тикетів — пароль, що
# туди потрапив, залишиться там назавжди.
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "пароль до Redis приїжджає в застосунок (значення: <приховано>)"
else
  fail "у ${APP} не задано змінну REDIS_PASSWORD" \
       "Redis вимагає автентифікації; створіть секрет redis-password і застосуйте cache-patch.yaml"
fi

# Відсутність секрета — попередження, а не провал: пароль можна доставити в Pod
# і в інший спосіб. Властивість, що перевіряється тут, інша — у маніфесті лежить
# посилання, а не значення.
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "секрет redis-password із паролем від Redis існує"
else
  warn "у кластері немає секрета redis-password" \
       "створіть: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- головна перевірка: кеш справді пришвидшує -------------------------------
# Ідентифікатор беремо свідомо новий, щоб перший запит гарантовано був промахом.
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "сервіс ${APP} не віддав очікуваний JSON" \
       "дивіться kubectl logs -l app=passes-api; перевірте, що образ зібрано з app/ цієї лаби (тег v2)"
  evidence "Що відповів сервіс" "перший запит: ${R1:-порожньо}
другий запит: ${R2:-порожньо}"
elif [ "$MODE" != "redis" ]; then
  fail "застосунок повідомляє, що кеш вимкнено (cache: ${MODE})" \
       "змінна REDIS_ADDR не доїхала до працюючих Pod — перевірте kubectl rollout status deployment/${APP}"
elif [ "$C1" = "True" ]; then
  warn "перший запит уже прийшов із кеша — порівняти нема з чим" \
       "малоймовірний збіг за ідентифікатором; запустіть перевірку ще раз"
elif [ "$C2" != "True" ]; then
  fail "другий запит за тим самим ідентифікатором знову не влучив у кеш" \
       "застосунок не може писати в Redis: дивіться kubectl logs -l app=passes-api, зазвичай там NOAUTH або таймаут"
  evidence "Відповіді сервісу" "перший:  ${R1}
другий: ${R2}"
else
  ok "кеш працює: промах ${T1} мс, влучання ${T2} мс"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "більше ніж у 1000")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "Замір на живому сервісі" "ідентифікатор: ${PROBE_ID}
перший запит (промах):   ${T1} мс
другий запит (влучання): ${T2} мс
виграш: приблизно в ${SPEEDUP} разів
термін життя запису: ${TTL:-за замовчуванням} с"

  # Сувора частина: влучання має бути на порядок швидше за промах. Інакше
  # «кеш працює» означає лише, що ключ записався, а вигоди немає.
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "виграш вимірний: влучання приблизно в ${SPEEDUP} разів швидше за промах"
  else
    warn "влучання в кеш не дає помітного виграшу (${T1} мс проти ${T2} мс)" \
         "перевірте, що довідник справді повільний, а Redis знаходиться не на тому самому Pod"
  fi
fi

# --- скільки копій сервісу поділяють один кеш --------------------------------
# Кеш спільний для всіх копій — це варто побачити у звіті: влучання могло прийти
# від іншого Pod, ніж промах, і це правильно.
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "копій сервісу працює: ${API_PODS} (кеш у них спільний)"
  evidence "Копії сервісу" "$(kget pods -l app=passes-api -o wide)"
else
  fail "немає жодної працюючої копії ${APP}" \
       "дивіться kubectl describe pod -l app=passes-api"
fi

finish
