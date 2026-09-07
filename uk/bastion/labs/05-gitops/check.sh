#!/usr/bin/env bash
# Перевірка лаби 5: стан кластера приходить із Git і утримується звіркою.
#
# Запускається на вашому кластері `lab`, з теки лаби, вами ж:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# Нічого не змінює — лише дивиться й друкує звіт: що перевірено, що пройшло,
# що ні, і додані свідчення.
#
# Перевіряємо не «Flux встановлено», а «механізм працює»: джерело читається, застосоване
# належить Flux, сервіс відповідає, звірку не вимкнено. Встановлений, але
# призупинений Flux — це найпоширеніший спосіб пройти лабу повз сенс.

LAB_NAME="05-gitops"
LAB_TITLE="Лаба 5 · Інфраструктура в Git"
# Спільна обв'язка всіх лаб: з неї беруться ok / fail / warn / evidence / finish і
# перевірки оточення. Шлях рахується від розташування цього файлу, тому скрипт
# можна запускати з будь-якої теки.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Без файлу доступу до кластера перевіряти нема чого — виходимо одразу і зі зрозумілою причиною.
need_kubeconfig

# Імена, які лаба створює. Зібрані в одному місці: якщо учасник назвав об'єкти
# інакше, правити потрібно тут, а не шукати імена по всьому скрипту.
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# Читаємо поле об'єкта, не падаючи, якщо об'єкта чи CRD немає.
kget() { kubectl get "$@" 2>/dev/null; }

# --- служби Flux -----------------------------------------------------------
# Дивимося не «Pod існують», а «копій у стані Ready хоча б одна»: Pod може
# висіти в Pending без пам'яті на вузлі і при цьому бути присутнім у виводі get pods.
# Обидві служби обов'язкові й ділять роботу: source-controller завантажує репозиторій,
# kustomize-controller застосовує завантажене. Без другої нічого не поїде в кластер.
if ! kget namespace flux-system >/dev/null; then
  fail "у кластері немає namespace flux-system" \
       "Flux не встановлено: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "служби Flux працюють: source-controller і kustomize-controller"
    evidence "Pod Flux" "$(kget pods -n flux-system -o wide)"
  else
    fail "не працюють служби Flux:${FLUX_BAD}" \
         "дивіться kubectl get pods -n flux-system; на маленькому вузлі їм може бракувати пам'яті"
  fi
fi

# --- джерело: GitRepository ------------------------------------------------
# Три різних результати, і плутати їх не можна: об'єкта немає зовсім; об'єкт є, але в ньому
# лишилася заглушка адреси; об'єкт є і адреса справжня, але Flux не зміг прочитати
# репозиторій. Порада в кожному випадку різна, тому й гілки різні.
#
# Ознаку успіху беремо зі status.conditions — це те, що про себе повідомляє сам Flux
# після спроби сходити в Git, а не наше припущення за наявністю об'єкта.
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "у кластері немає типу GitRepository" \
       "Flux не встановлено або встановлено без source-controller"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "не знайдено GitRepository з іменем ${GITREPO} у flux-system" \
         "застосуйте flux/gitrepository.yaml, підставивши адресу свого репозиторію"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "у GitRepository лишилася адреса-заглушка" \
         "відкрийте flux/gitrepository.yaml і впишіть адресу свого репозиторію на GitHub"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux читає ваш репозиторій: ${GR_URL}"
    evidence "Джерело в Git" "url: ${GR_URL}
revision: ${GR_REV:-невідома}"
  else
    fail "Flux не може прочитати репозиторій ${GR_URL}" \
         "дивіться flux get sources git; найчастіше це друкарська помилка в адресі, приватний репозиторій або інша гілка"
    evidence "Помилка джерела" "${GR_MSG:-немає повідомлення}"
  fi
fi

# --- застосування: Kustomization ----------------------------------------------
# Тут перевіряється не факт застосування, а три властивості механізму, без яких лаба
# втрачає сенс: застосована ревізія збігається з Git, звірку не призупинено і
# увімкнено видалення зниклого з репозиторію.
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "у кластері немає типу Kustomization" \
       "Flux встановлено без kustomize-controller — перевстановіть з обома компонентами"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "не знайдено Kustomization з іменем ${KUSTOMIZATION} у flux-system" \
         "застосуйте flux/kustomization.yaml"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux застосував стан із Git, ревізія ${KS_REV}"
    evidence "Застосована ревізія" "$KS_REV"
  else
    fail "Flux не зміг застосувати стан із Git" \
         "дивіться flux get kustomizations і kubectl describe kustomization ${KUSTOMIZATION} -n flux-system"
    evidence "Помилка застосування" "${KS_MSG:-немає повідомлення}"
  fi

  # Призупинений Flux виглядає встановленим і не робить нічого. Це головний
  # спосіб «здати» лабу, не отримавши жодної її вигоди.
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "звірку призупинено (suspend: true) — Flux не стежить за кластером" \
         "увімкніть назад: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "звірка активна: розходження з Git буде усунуто само, інтервал ${KS_INTERVAL:-за замовчуванням}"
  fi

  # Це warn, а не fail: без prune кластер усе одно керується з Git, лабу пройдено.
  # Але опис стає одностороннім — видалення файлу нічого не видаляє в кластері.
  if [ "$KS_PRUNE" = "true" ]; then
    ok "увімкнено видалення того, що зникло з Git (prune)"
  else
    warn "prune вимкнено — видалене з репозиторію лишиться працювати в кластері" \
         "поставте prune: true у flux/kustomization.yaml, інакше Git описує стан лише наполовину"
  fi
fi

# --- об'єкти в кластері належать Flux, а не застосовані руками ---------
# Це ключова перевірка лаби, і вона про походження, а не про наявність. Застосунок
# у кластері є в обох випадках: і коли його привіз Flux, і коли учасник застосував
# ті самі файли руками через kubectl apply. Зовні не відрізнити — Deployment однаковий.
# Відрізняє мітка власника: її ставить лише kustomize-controller, коли застосовує
# вміст репозиторію. Руками застосований об'єкт такої мітки не отримає.
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "у namespace ${NS_APP} немає застосунку passes" \
       "покладіть app/*.yaml у теку apps свого репозиторію, зробіть push і дочекайтеся звірки"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "застосунок у кластері належить Flux, а не застосований руками"
else
  fail "застосунок passes є, але його створив не Flux" \
       "приберіть його (kubectl delete ns ${NS_APP}) і дайте Flux розгорнути його з Git наново"
fi

# --- застосунок справді відповідає --------------------------------------
# Об'єкт у кластері й працюючий сервіс — різні речі: Deployment може бути створений,
# а Pod падати в циклі. Тому йдемо всередину кластера й запитуємо сервіс за його
# внутрішнім іменем — тим самим шляхом, яким до нього зверталися б сусідні застосунки.
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Перепустка'; then
  ok "сервіс «Перепустка» відповідає по HTTP усередині кластера (працюючих копій: ${PODS_READY})"
else
  fail "сервіс «Перепустка» не відповідає за адресою passes.${NS_APP}.svc.cluster.local" \
       "дивіться kubectl get pods -n ${NS_APP} і kubectl logs -n ${NS_APP} deploy/passes"
fi

# Ім'я Pod на сторінці має збігатися з реально запущеною копією: так видно,
# що відповідає саме той Pod, який ми бачимо в кластері, а не закешована
# відповідь чи чужий сервіс, що випадково зайняв те саме ім'я. Розбіжність — warn, а не
# fail: копія могла перестворитися між двома запитами, і це не помилка учасника.
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "сторінку віддав реально існуючий Pod ${SERVED_POD}"
  evidence "Копії сервісу" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "Pod ${SERVED_POD} з відповіді не знайдено серед запущених" \
       "найімовірніше копія перестворилася між двома запитами — запустіть перевірку ще раз"
fi

# --- історія змін у вашому клоні репозиторію ----------------------------
# Необов'язкова частина: скрипт не знає, де лежить клон, доки йому не скажуть.
# Перевіряється тут спосіб відкату. Через kubectl rollout undo кластер теж повернеться
# до минулої версії, але Git про це не дізнається, і наступна ж звірка поверне погану
# зміну назад. Тому шукаємо в історії revert — відкат зроблено там, де живе
# істина. І звіряємо, що застосована в кластері ревізія збігається з вашим HEAD:
# закомітити й забути про push — звична річ, а зовні це виглядає як «Flux завис».
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "історію репозиторію не перевіряли: не задано змінну LAB_REPO" \
       "щоб перевірити і її: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "у ${REPO} немає клону репозиторію" \
       "вкажіть теку, в яку ви робили git clone"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "в історії є відкат через git revert — погану зміну скасовано там, де живе істина"
    evidence "Історія змін" "$LOG"
  else
    fail "в останніх комітах немає жодного revert" \
         "відкотіть погану зміну через git revert --no-edit HEAD і зробіть push, а не через kubectl rollout undo"
  fi

  # Застосоване в кластері має збігатися з останнім комітом у гілці.
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "у кластері працює рівно те, що лежить у вашій гілці (коміт ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "коміт у кластері (${KS_REV:-невідомий}) відрізняється від локального HEAD (${HEAD_SHA})" \
         "перевірте, що локальні коміти відправлені (git push), і зачекайте інтервал звірки"
  fi
fi

finish
