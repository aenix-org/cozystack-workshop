#!/usr/bin/env bash
# Перевірка лаби 13: чарт і опис застосунку готові до передавання адміну.
#
# Ця перевірка НАВМИСНО локальна. Застосувати ApplicationDefinition тенант не
# може (об'єкт cluster-scoped), тому шукати його в кластері безглуздо:
# відсутність об'єкта — не помилка учасника. Перевіряємо те, за що він відповідає:
# чарт збирається, схема працює, визначення розібране й узгоджене з чартом.
#
# Запуск із папки лаби:
#   cd labs/13-catalog && ./check.sh
# Кластер не обов'язковий: без KUBECONFIG дві перевірки будуть пропущені з попередженням,
# а не з помилкою.

LAB_NAME="13-catalog"
LAB_TITLE="Лаба 13 · Власний застосунок у каталозі Cozystack"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- інструменти -----------------------------------------------------------
# Без helm перевіряти нічого, тому тут скрипт зупиняється одразу й не сипле
# десятком однакових відмов далі за текстом.
if ! command -v helm >/dev/null 2>&1; then
  fail "на машині немає helm" \
       "встановіть: brew install helm (macOS) або https://helm.sh/docs/intro/install/ — без нього лаба не перевіряється"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm на місці (${HELM_VER})"
evidence "Версія helm" "$HELM_VER"

# --- чарт на місці ---------------------------------------------------------
# Відрізняємо «чарт зламано» від «скрипт запущено не з тієї папки». Друга помилка трапляється
# частіше за першу, і повідомлення про неї має бути окремим.
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "не знайдено чарт у ${CHART}" \
       "запускайте скрипт із папки лаби: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- лінтер ----------------------------------------------------------------
# helm lint читає чарт як текст: знаходить друкарські помилки в шаблонах, відсутні поля
# Chart.yaml, посилання на неіснуючі значення. До кластера справа тут не доходить.
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "чарт проходить helm lint"
  evidence "helm lint" "$LINT_OUT"
else
  fail "чарт не проходить helm lint" \
       "прочитайте вивід нижче й полагодьте вказані файли: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- рендер ----------------------------------------------------------------
# Порожній вивід і вивід із самих коментарів лінтер би пропустив, тому дивимось,
# що серед відрендереного є Deployment, і перелічуємо, що взагалі вийшло.
# Головне тут не «команда відпрацювала», а «вийшли справжні об'єкти».
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "чарт рендериться, виходять об'єкти: ${KINDS}"
  evidence "Що рендерить чарт" "$KINDS"
else
  fail "helm template не видав жодного Deployment" \
       "дивіться помилку рендера: helm template main chart"
  evidence "Вивід helm template" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- чарт приймається справжнім кластером ----------------------------------
# Єдина перевірка в усьому наборі лаб, яка звіряє маніфест зі справжньою схемою
# кластера, а не з текстом.
#
# `helm lint` і `helm template` перевіряють шаблони, але НЕ схему Kubernetes: маніфест
# з полем у невідповідному місці вони пропускають, а кластер відхиляє. Перевірено на власній
# шкурі — securityContext, помилково вставлений у volumes, пройшов обидва й розвалився
# лише на сервері. Перевірка потрібна там, де чарт застосовують.
#
# Чому lint і template її не замінюють:
#   helm lint      дивиться на будову чарта: файли на місці, шаблони розбираються;
#   helm template  підставляє значення й видає текст — але що це за поля й чи бувають
#                  вони в такого об'єкта, він не знає й знати не може;
#   apply --dry-run=server надсилає маніфест до apiserver, той проганяє його через схему
#                  типу й через admission-контроль і відповідає, прийняв би чи ні, нічого
#                  при цьому не створюючи. Звідси `unknown field` і відмова за політикою —
#                  саме те, об що чарт спотикається у замовника.
# Прапорець --dry-run=client такої перевірки не дає: він розбирає маніфест на вашій машині.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # Відмова у правах і відмова за схемою — різні речі, і плутати їх не можна. Під тенантним
  # доступом (~/.kube/workshop) прав на Deployment і ConfigMap немає зовсім, тому сюди
  # прилетить Forbidden — і це нічого не говорить про якість чарта. Перевірка по суті
  # можлива лише доступом до кластера `lab`, де ви повноправний господар.
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "серверна перевірка чарта пропущена: поточний доступ не дозволяє її виконати" \
         "проженіть її доступом до свого кластера: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "кластер відхиляє відрендерений чарт" \
         "дивіться: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "Відмова сервера" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "кластер приймає відрендерений чарт — поля та їхні місця правильні"
  fi
else
  warn "перевірка чарта на кластері пропущена: немає доступу" \
       "задайте KUBECONFIG, щоб прогнати helm template через kubectl apply --dry-run=server"
fi

# --- параметри справді доходять до маніфестів -------------------------------
# Чарт може збиратися й рендеритися, а параметр при цьому нікуди не підставлятися —
# наприклад, значення записали в шаблон числом. Тому кожен параметр перевіряємо ділом:
# задаємо свідомо незвичне значення й шукаємо його в готовому маніфесті.
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "параметр replicas доходить до маніфесту (--set replicas=5 дає replicas: 5)"
else
  fail "параметр replicas не доходить до маніфесту" \
       "в templates/deployment.yaml має стояти replicas: {{ .Values.replicas }}"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "параметр external перемикає тип Service на LoadBalancer"
else
  warn "параметр external не перемикає тип Service" \
       "не поломка чарта, але угода каталогу Cozystack: поле external у застосунків означає саме зовнішній доступ"
fi

# --- схема справді захищає ------------------------------------------
# Схема, яка нічого не відхиляє, марна. Перевіряємо, що вона відхиляє.
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "схема значень не відхиляє свідомо неправильне значення (replicas=abc пройшло)" \
       "перевірте, що поряд із values.yaml лежить values.schema.json і в ньому replicas оголошений як integer"
else
  ok "схема значень відхиляє неправильний тип (replicas=abc не проходить)"
fi

# --- ApplicationDefinition: обов'язкові поля ------------------------------
# Застосувати визначення учасник не може, отже й відмови apiserver він не побачить.
# Тому обов'язкові поля перераховуємо тут: без будь-якого з них адмін отримає відмову
# вже у себе, а розбиратися доведеться авторові файлу.
if [ ! -f "$APPDEF" ]; then
  fail "не знайдено ${APPDEF}" \
       "файл має лежати поряд із чартом; візьміть його з репозиторію лаб"
else
  MISSING=""
  # Шукаємо ключі построково, без розбору YAML: PyYAML є не на кожній машині,
  # а тягнути залежність заради перевірки одного файлу не варто.
  check_key() {
    grep -Eq "$1" "$APPDEF" || MISSING="$MISSING $2"
  }
  check_key '^kind:[[:space:]]+ApplicationDefinition[[:space:]]*$' 'kind: ApplicationDefinition'
  check_key '^apiVersion:[[:space:]]+cozystack\.io/v1alpha1[[:space:]]*$' 'apiVersion: cozystack.io/v1alpha1'
  check_key '^[[:space:]]{4}kind:[[:space:]]+\S+' 'application.kind'
  check_key '^[[:space:]]{4}plural:[[:space:]]+\S+' 'application.plural'
  check_key '^[[:space:]]{4}singular:[[:space:]]+\S+' 'application.singular'
  check_key '^[[:space:]]{4}openAPISchema:' 'application.openAPISchema'
  check_key '^[[:space:]]{4}prefix:[[:space:]]+\S+' 'release.prefix'
  check_key '^[[:space:]]{6}kind:[[:space:]]+(OCIRepository|HelmChart|ExternalArtifact)' 'release.chartRef.kind'
  check_key '^[[:space:]]{4}category:[[:space:]]+\S+' 'dashboard.category'
  check_key '^[[:space:]]{4}icon:[[:space:]]+\S+' 'dashboard.icon'

  if [ -z "$MISSING" ]; then
    ok "в ApplicationDefinition на місці всі обов'язкові поля"
  else
    fail "в ApplicationDefinition не вистачає полів:${MISSING}" \
         "звіртеся з розбором у README — без будь-якого з них адмін отримає відмову при застосуванні"
  fi

  # --- схема у визначенні розбирається й збігається зі схемою чарта ---------
  # Це дві різні копії того самого, і зв'язку між ними немає жодного.
  # Розійшлися — форма в дашборді покаже не ті поля, що чекає чарт.
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "в ApplicationDefinition порожній openAPISchema" \
         "вставте туди вміст chart/values.schema.json одним рядком"
  else
    CMP="$(SCHEMA_LINE="$SCHEMA_LINE" python3 - "$CHART/values.schema.json" <<'PY' 2>&1
import os, sys, json
try:
    inline = json.loads(os.environ["SCHEMA_LINE"])
except Exception as e:
    print("BADJSON %s" % e); raise SystemExit
try:
    chart = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOCHART %s" % e); raise SystemExit
a = sorted((inline.get("properties") or {}).keys())
b = sorted((chart.get("properties") or {}).keys())
if a == b:
    print("SAME %s" % ",".join(a))
else:
    only_def = sorted(set(a) - set(b))
    only_chart = sorted(set(b) - set(a))
    print("DIFF тільки у визначенні: %s | тільки в чарті: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "схема у визначенні розбирається й збігається зі схемою чарта (${CMP#SAME })"
        evidence "Параметри застосунку" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "схема у визначенні розійшлася зі схемою чарта: ${CMP#DIFF }" \
             "приведіть їх у відповідність: вміст openAPISchema — це chart/values.schema.json одним рядком"
        ;;
      BADJSON*)
        fail "openAPISchema не розбирається як JSON: ${CMP#BADJSON }" \
             "схема має бути одним рядком коректного JSON під 'openAPISchema: |-'"
        ;;
      *)
        warn "не вдалося звірити схеми (${CMP})" \
             "перевірте руками, що openAPISchema збігається з chart/values.schema.json"
        ;;
    esac
  fi

  # --- іконка ---------------------------------------------------------------
  # Дашборд чекає SVG, укладений у base64, і нікуди за картинкою не ходить. Помилка тут
  # тиха: маніфест застосується, а в каталозі на місці іконки буде порожньо. Тому рядок
  # розкодовуємо й дивимось, що всередині справді SVG.
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "іконка розкодовується з base64 і виявляється SVG"
        evidence "Початок іконки" "$ICON_HEAD"
        ;;
      "")
        fail "іконка не розкодовується з base64" \
             "перезберіть рядок: base64 -i icon.svg | tr -d '\\n' (на Linux: base64 -w0 icon.svg)"
        ;;
      *)
        fail "іконка розкодовується, але це не SVG" \
             "дашборд чекає саме SVG; растрову картинку він покаже як сміття"
        ;;
    esac
  fi
fi

# --- права: відмова тут очікувана --------------------------------------------
# Це не перевірка учасника, а підтвердження будови платформи. Тому
# відповідь `no` — успіх, а `yes` — привід здивуватися, а не радіти.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "підтверджено: застосовувати ApplicationDefinition вам не належить (can-i -> no)"
      evidence "Права на ApplicationDefinition" \
        "kubectl auth can-i create applicationdefinitions -> no
Об'єкт cluster-scoped і змінює каталог для всіх тенантів, тому його застосовує адмін платформи."
      ;;
    yes)
      warn "у вас є права застосовувати ApplicationDefinition (can-i -> yes)" \
           "отже, ви працюєте під адмінським обліковим записом, а не під тенантним; лаба розрахована на тенантний"
      ;;
    *)
      warn "не вдалося запитати кластер про права" \
           "не заважає складанню лаби: перевірка локальна, кластер тут не потрібен"
      ;;
  esac
else
  warn "кластер не опитано (KUBECONFIG не задано або не відповідає)" \
       "перевірка локальна, кластер тут не потрібен. Щоб побачити відмову у правах: export KUBECONFIG=~/.kube/workshop"
fi

finish
