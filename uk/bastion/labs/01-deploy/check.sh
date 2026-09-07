#!/usr/bin/env bash
# Перевірка лаби 1: застосунок розгорнуто і справді працює по суті.
#
# «По суті» тут значить: сторінка реально віддається по HTTP, у ній підставлено
# ім'я Pod, і це ім'я збігається з ім'ям реально запущеної копії. Перевіряти
# існування об'єкта Deployment безглуздо — він може існувати і не працювати.
#
# Запускається на віртуалці, з теки цієї лаби, за доступом до навчального кластера `lab`
# (не до тенанта на кластері керування):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# Змінна COZY_TENANT тут не потрібна: вся лаба йде всередині кластера `lab`.
#
# Скрипт нічого не змінює в кластері — тільки читає і надсилає HTTP-запити.
# Запускати його до прибирання: після видалення застосунку перевіряти буде нічого.

# Ці дві змінні підхоплює lib.sh — вони потрапляють у заголовок звіту і в ім'я
# файлу report-<лаба>-<дата>.md, який скрипт кладе поряд із собою.
LAB_NAME="01-deploy"
LAB_TITLE="Лаба 1 · Перший застосунок"
# Спільна бібліотека перевірок: звідси приходять ok / fail / warn / evidence / finish,
# запит сторінки зсередини кластера і запис звіту. Шлях рахується від місця, де
# лежить сам скрипт, тому запуск із будь-якого каталогу працює однаково.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Зупиняємося одразу, якщо KUBECONFIG не заданий. Без нього kubectl шукає кластер
# на самій віртуалці, не знаходить і валить усі перевірки поспіль однією й тією ж помилкою,
# з якої справжню причину не видно.
need_kubeconfig

# --- об'єкт застосунку ------------------------------------------------------
# Перший рубіж: застосунок узагалі заведено і хоча б одна копія дійшла до готовності.
# Дивимося на .status.readyReplicas, а не на факт існування Deployment: об'єкт
# створюється миттєво і завжди успішно, готовність же означає, що копія піднялася,
# пройшла перевірку готовності і здатна відповідати.
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # Окремий випадок: об'єкт є, але у нього запрошено нуль копій. Повідомлення
    # «жодна копія не готова (потрібно 0)» звучало б безглуздям.
    fail "застосунок зупинено — запрошено 0 копій" \
         "поверніть копію: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "застосунок розгорнуто, готових копій ${READY} з ${DESIRED}"
    # Застрягла викатка не роняє сервіс: стара копія продовжує працювати, і
    # readyReplicas залишається одиницею. Без цієї перевірки учасник іде з зеленою
    # галочкою і деплойментом, який назавжди застряг у ErrImagePull.
    # Дивимося на самі копії, а не тільки на ProgressDeadlineExceeded: дедлайн
    # спрацьовує через десять хвилин, а скрипт запускають одразу. Стара копія при
    # цьому працює, readyReplicas залишається одиницею, і без цієї перевірки учасник
    # іде з зеленою галочкою і деплойментом, застряглим у ImagePullBackOff.
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "викатка застрягла: нова копія не піднімається, працює тільки стара" \
           "дивіться kubectl get pods -l app=rickroll — зазвичай образ не скачався; повернути робочий стан: kubectl apply -f rickroll.yaml"
      evidence "Копії, які не стартують" "${STUCK:-причина у статусі Deployment: $PROG_REASON}"
    fi
  else
    fail "застосунок створено, але жодна копія не готова (потрібно ${DESIRED})" \
         "дивіться kubectl get pods -l app=rickroll і kubectl describe deployment rickroll"
    evidence "Стан Pod" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "не знайдено Deployment з ім'ям rickroll" \
       "застосуйте маніфест: kubectl apply -f rickroll.yaml"
fi

# --- налаштування і сторінка ------------------------------------------------
# Обидва ConfigMap створюються тим самим файлом, що й застосунок, тому пропасти вони можуть
# тільки разом із ним або від ручного видалення. Перевіряємо їх окремо, щоб при
# поломці сторінки учасник одразу бачив, чого саме не вистачає: без rickroll-conf
# nginx не підставить ім'я Pod, а без rickroll-page-v1 не буде з чим порівнювати
# другу версію в лабі 4 і нікуди відкочуватися.
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "налаштування на місці: ConfigMap ${cm}"
  else
    fail "не знайдено ConfigMap ${cm}" \
         "він створюється тим самим файлом: kubectl apply -f rickroll.yaml"
  fi
done

# --- постійна адреса --------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # Service без ендпоінтів — типова і непомітна поломка: об'єкт є,
  # а мітки на Pod не збіглися із селектором, і за адресою порожньо.
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "постійна адреса працює, за нею копій: ${EPS_N}"
    evidence "Адреси за сервісом" "$EPS"
  else
    fail "Service rickroll є, але за ним немає жодної копії" \
         "зазвичай причина в тому, що мітки Pod не збіглися із selector сервісу — звірте app: rickroll"
  fi
else
  fail "не знайдено Service з ім'ям rickroll" \
       "він створюється тим самим файлом: kubectl apply -f rickroll.yaml"
fi

# --- головне: сторінка реально віддається -----------------------------------
# Заради цієї перевірки все й затівалося. Усі попередні говорять лише про те, що об'єкти
# в кластері описані вірно; ця — що користувач отримує сторінку. Запит іде
# ЗСЕРЕДИНИ кластера, одноразовим Pod: ззовні адреси rickroll не існує, і
# port-forward тут був би перевіркою вашої віртуалки, а не кластера.
# Запитуємо кілька разів: при кількох копіях за сервісом одиночна вибірка
# може не зачепити підмінену, і перевірка зеленіє на чужому контенті.
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# Маркер має траплятися РІВНО РАЗ на сторінку, інакше лічильник відповідей бреше:
# «Never Gonna Give You Up» стоїть і в <title>, і в <h1>, і давало подвоєння.
ANSWERS="$(printf '%s' "$BODY" | grep -c 'вас обслужив Pod')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "застосунок відповідає по HTTP і віддає свою сторінку (перевірено ${ANSWERS} запитів)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "за сервісом відповідає не тільки ваш застосунок: своя сторінка прийшла ${ANSWERS} разів із ${TOTAL_LINES}" \
       "хтось іще носить мітку app=rickroll — дивіться kubectl get pods -l app=rickroll і видаліть зайве"
else
  fail "застосунок не віддав очікувану сторінку" \
       "перевірте вручну: kubectl port-forward svc/rickroll 8080:80, потім відкрийте http://localhost:8080"
  evidence "Що повернулося замість сторінки" "$(printf '%s' "$BODY" | head -20)"
fi

# --- підстановка імені Pod -------------------------------------------------
# Заради цього лаба й зроблена: ім'я в сторінці має збігатися з реальним Pod.
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# Беремо Pod, якими керує ReplicaSet застосунку, а НЕ все, що носить мітку
# app=rickroll. Інакше сторонній Pod із такою міткою потрапляє в список «справжніх»
# і сам себе підтверджує — перевірено, самозванець так проходив перевірку.
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "мітку app=rickroll носять сторонні Pod — вони потраплять у балансування" \
       "видаліть зайве: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "Сторонні Pod під міткою застосунку" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "у сторінці немає імені Pod" \
       "перевірте, що підставився ConfigMap rickroll-conf — у ньому рядок sub_filter '__POD__' '\$hostname'"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "ім'я Pod не підставилося — у сторінці залишилася заглушка __POD__" \
       "nginx не застосував sub_filter: перевірте, що том із налаштуваннями змонтований у /etc/nginx/conf.d"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "ім'я Pod підставляється і збігається з реально запущеною копією: ${SERVED_BY}"
  evidence "Хто обслужив запит" "$SERVED_BY"
  evidence "Запущені копії" "$REAL_PODS"
else
  fail "сторінка називає Pod «${SERVED_BY}», але такого Pod в кластері немає" \
       "можливо, копія перестворилася між запитом і перевіркою — запустіть скрипт ще раз"
fi

# --- перевірка готовності налаштована ---------------------------------------
# Без неї в лабі про викатку версій буде простій, і учасник вирішить, що ми збрехали.
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "перевірка готовності налаштована (${PROBE_PATH}) — оновлення пройде без простою"
else
  warn "у застосунку немає перевірки готовності" \
       "лаба 4 про оновлення без простою на такому застосунку дасть помилки — поверніть readinessProbe з rickroll.yaml"
fi

finish
