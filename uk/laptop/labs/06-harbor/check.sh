#!/usr/bin/env bash
# Перевірка лаби 6: застосунок приїжджає в кластер зі СВОГО закритого реєстру.
#
# Перевіряємо не «Harbor створено», а весь ланцюжок: реєстр відповідає своїм API,
# образ у маніфесті лежить саме в ньому, кластер має реквізити на цю саму адресу,
# і Pod із цим образом справді працює й відповідає.
#
# Два кластери, і це головне, через що скрипт виглядає складнішим за сусідні:
# KUBECONFIG — ваш кластер lab, де працює застосунок; COZY_KUBECONFIG —
# кластер керування Cozystack, де у вашому тенанті живе керований сервіс Harbor.
# Однією командою їх не опитати, тому нижче два різні способи викликати kubectl.
#
# Запускається вами, з теки лаби; нічого не змінює, лише дивиться й друкує звіт:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/workshop
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="Лаба 6 · Власний приватний реєстр образів"
# Спільна обв'язка всіх лаб: ok / fail / warn / evidence / finish і перевірки оточення.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Без файлу доступу до кластера й без номера тенанта перевіряти нічого — виходимо одразу.
need_kubeconfig
need_tenant

APP="passes-api"
# namespace тенанта на кластері керування: ім'я складається з префікса
# tenant- і вашого номера, тобто tenant-workshopXX. Номер береться з оточення,
# підставляти його в текст скрипта руками не потрібно.
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# Два способи викликати kubectl: kget іде у ваш кластер lab, cozy — у кластер керування.
# Помилки глушаться навмисно: відсутність об'єкта тут не аварія, а один з очікуваних
# результатів, і розбирається він нижче окремою гілкою зі зрозумілою порадою.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- керований сервіс Harbor на кластері керування -----------------------------
# Необов'язкова частина: без тенантного кубконфіга лаба все одно перевіряється,
# але сервіс з боку платформи ми не побачимо.
#
# Окремо ловимо випадок «команда не відпрацювала»: роль у тенанті може не давати
# дивитися застосунки. Це не помилка учасника й не привід валити перевірку, тому
# тут warn — «не подивилися», а не fail — «зроблено неправильно». Помилку команди й
# порожню відповідь розрізняємо навмисно: порожній список означає, що Harbor не створено взагалі.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "не знайдено тенантний кубконфіг ${COZY_KUBECONFIG} — стан Harbor не перевірявся" \
       "вкажіть шлях: export COZY_KUBECONFIG=~/.kube/workshop"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "не вдалося подивитися застосунки Harbor у тенанті ${TENANT_NS}" \
         "роль у тенанті може не давати цю команду — це не помилка лаби; усе інше перевіряється нижче"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "у тенанті ${TENANT_NS} немає жодного застосунку Harbor" \
         "створіть його в дашборді: Створити застосунок -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "керований сервіс Harbor «${HARBOR_NAME}» готовий"
    else
      warn "Harbor «${HARBOR_NAME}» є, але не повідомляє про готовність" \
           "дивіться його стан у дашборді; Harbor піднімається 5-10 хвилин, а без об'єктного сховища в тенанті не підніметься зовсім"
    fi
    evidence "Застосунки Harbor у тенанті" "$HARBOR_LIST"
    # Секрет із реквізитами читати не намагаємось: тенант цей секрет прочитати може,
    # але пароль у звіті нам все одно не потрібен.
  fi
fi

# --- звідки застосунок бере образ -------------------------------------------
# Сенс лаби — образ приїхав з вашого реєстру, а не з інтернету. Перевіряється це
# за іменем образу в маніфесті: перша частина імені до косої риски — адреса реєстру.
# Якщо в ній немає ні крапки, ні двокрапки, адреси там немає зовсім, і кластер мовчки пішов
# би за образом у Docker Hub — тобто рівно туди, куди ІБ заборонила.
# Заглушку HARBOR-HOST і відомі публічні реєстри ловимо окремими гілками:
# формально адреса на місці, а вимога лаби не виконана, і порада в кожному випадку своя.
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "у кластері lab немає застосунку ${APP}" \
       "застосуйте passes.yaml, підставивши в нього адресу свого Harbor"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # схоже на адресу реєстру
    *) REGISTRY="" ;;          # адреси немає — отже образ тягнеться з Docker Hub
  esac

  if [ -z "$REGISTRY" ]; then
    fail "образ ${IMAGE} тягнеться з публічного реєстру, а не з вашого" \
         "в імені образу першою частиною має йти адреса вашого Harbor"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "у маніфесті залишилась адреса-заглушка HARBOR-HOST" \
         "підставте адресу свого Harbor: sed -i 's|HARBOR-HOST|harbor.вашдомен|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "образ тягнеться з публічного реєстру ${REGISTRY}" \
         "ІБ просила закритий реєстр — зберіть і запуште образ у свій Harbor"
  else
    ok "застосунок запускається з вашого реєстру: ${REGISTRY}"
    evidence "Образ застосунку" "$IMAGE"
  fi
fi

# --- реєстр справді працює --------------------------------------------------
# Адреса в маніфесті може бути написана правильно, а реєстру за нею не бути: Harbor
# піднімається не миттєво, і одрук у домені виглядає точно так само. Тому
# стукаємось у його API і чекаємо на відповідь «pong» — це підтверджує, що там саме Harbor,
# а не чужий сайт і не заглушка балансувальника.
if [ -z "$REGISTRY" ]; then
  : # уже відзвітували вище
elif ! command -v curl >/dev/null 2>&1; then
  warn "немає утиліти curl — доступність реєстру не перевірялась" \
       "відкрийте https://${REGISTRY} у браузері, там має бути інтерфейс Harbor"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","невідома"))' 2>/dev/null)"
    ok "реєстр відповідає через API: https://${REGISTRY} (Harbor ${VER:-версія невідома})"
    evidence "Реєстр" "https://${REGISTRY}
API ping: ${PING}
версія Harbor: ${VER:-невідома}"
  else
    fail "реєстр https://${REGISTRY} не відповідає на запит /api/v2.0/ping" \
         "перевірте адресу й стан застосунку Harbor у дашборді"
  fi
fi

# --- реквізити доступу у кластера -------------------------------------------
# Мало того, що секрет вказаний у маніфесті, — важливо, що він із реквізитами саме
# до того реєстру, з якого тягнеться образ. Найчастіша помилка лаби виглядає
# справною: секрет створений, у маніфесті названий, але адреса всередині нього не та
# (зайвий https://, порт, інше ім'я хоста), і kubelet його не застосує.
# Тому розпаковуємо вміст секрета й порівнюємо адреси, а не імена.
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # застосунку немає, відзвітували вище
elif [ -z "$PULL_SECRETS" ]; then
  fail "у маніфесті ${APP} не вказано жодного imagePullSecret" \
       "образ із закритого реєстру без реквізитів не завантажиться: додайте imagePullSecrets, див. passes.yaml"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # Розбираємо конфіг пітоном: base64 -d поводиться по-різному на macOS і Linux,
    # а друкувати пароль у звіт не можна — беремо лише список адрес.
    SERVERS="$(kget secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' \
      | python3 -c 'import sys,json,base64
raw = sys.stdin.read().strip()
try:
    cfg = json.loads(base64.b64decode(raw))
    print(" ".join(cfg.get("auths", {}).keys()))
except Exception:
    pass' 2>/dev/null)"
    if [ -n "$REGISTRY" ] && printf '%s' "$SERVERS" | grep -q "$REGISTRY"; then
      SECRET_OK="$s"
      break
    fi
  done

  if [ -n "$SECRET_OK" ]; then
    ok "кластер має реквізити до ${REGISTRY} в секреті ${SECRET_OK} (пароль: <приховано>)"
  else
    fail "жоден із вказаних секретів (${PULL_SECRETS}) не містить реквізитів до ${REGISTRY:-вашого реєстру}" \
         "створіть так: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-АДРЕСА} --docker-username=admin --docker-password=..."
  fi
fi

# --- Pod справді запустилися -----------------------------------------------
# Окремо розбираємо стани ImagePullBackOff і ErrImagePull: це саме та відмова,
# яку лаба показує навмисно, і учаснику важливо впізнати її в обличчя, а не
# отримати загальне «Pod не працюють». Справжню причину друкуємо свідченням —
# у відмові реєстру і в одруку в імені образу стан Pod однаковий.
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "копій застосунку працює: ${RUNNING}"
  evidence "Pod застосунку" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "образ не завантажується: ${BADSTATE}" \
       "це відмова в доступі до реєстру або одрук в імені образу; справжню причину покаже kubectl describe pod -l app=passes-api"
  evidence "Причина відмови" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "немає жодної працюючої копії застосунку (стани: ${BADSTATE:-Pod немає})" \
       "дивіться kubectl describe pod -l app=passes-api"
fi

# Окрема перевірка на найважчу для діагностики помилку лаби: образ зібраний
# під ARM, а вузли кластера на x86. Усе виглядає правильно — образ зібрався, поїхав
# у реєстр, завантажився на вузол, — але процес не стартує. Ніщо навколо не натякає
# на архітектуру процесора, і єдина зачіпка лежить у логах Pod, тому
# дивимось їх окремою перевіркою й називаємо причину прямо.
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "образ зібраний під іншу архітектуру процесора" \
       "перезберіть з прапорцем: docker build --platform linux/amd64 -t ${IMAGE} app/ і запуште заново"
fi

# --- застосунок відповідає по суті ------------------------------------------
# Запущений Pod ще не означає працюючий сервіс. Ідемо всередину кластера, запитуємо
# застосунок за його внутрішнім іменем і читаємо з відповіді ім'я Pod. Збіглося з реально
# запущеним — отже відповідає саме той застосунок, який ми розгорнули, а не
# щось інше, що випадково зайняло цю адресу. Незбіг — warn, а не fail:
# копія могла перестворитися між двома запитами, і провини учасника тут немає.
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "немає Service з іменем ${APP}" \
       "він описаний у passes.yaml — застосуйте файл цілком, а не тільки Deployment"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "сервіс ${APP} не віддав очікуваний JSON" \
         "дивіться kubectl logs -l app=passes-api і переконайтеся, що порт у Service збігається з портом застосунку"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "сервіс відповідає JSON, відповідь прийшла від реально працюючого Pod ${SERVED_POD}"
    evidence "Відповідь сервісу" "$BODY"
  else
    warn "сервіс відповів від імені Pod ${SERVED_POD}, якого немає серед запущених" \
         "найімовірніше копія перестворилася між запитами — запустіть перевірку ще раз"
  fi
fi

finish
