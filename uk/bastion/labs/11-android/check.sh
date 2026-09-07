#!/usr/bin/env bash
# Перевірка лаби 11: збірка Android дійшла до кінця, а APK — до бакета.
#
# Перевіряємо не «Job створено», а три різні твердження, і вони не рівні одне одному:
#   1) Job завершився успішно,
#   2) всередині нього справді зібрався APK (BUILD SUCCESSFUL),
#   3) файл справді поїхав до об'єктного сховища (маркер APK-UPLOADED).
# Job може завершитися успішно і не зібрати нічого — якщо хтось поправив скрипт.
#
# Запускається на віртуалці, з теки цієї лаби, за доступом до навчального кластера `lab`
# (не до тенанта на кластері керування — збірка йде в кластері):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# Скрипт нічого не змінює в кластері — тільки читає і надсилає HTTP-запити.
# Запускати його до прибирання: разом із Job видаляються і його логи, а без логів підтвердити
# два з трьох тверджень вище нічим.

# Ці дві змінні підхоплює lib.sh — вони потрапляють у заголовок звіту і в ім'я
# файлу report-<лаба>-<дата>.md, який скрипт кладе поруч із собою.
LAB_NAME="11-android"
LAB_TITLE="Лаба 11 · Збірка мобільного застосунку в кластері"
# Спільна бібліотека перевірок: звідси приходять ok / fail / warn / evidence / finish,
# запит зсередини кластера і запис звіту. Шлях рахується від місця, де лежить сам
# скрипт, тому запуск із будь-якого каталогу працює однаково.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Зупиняємось одразу, якщо KUBECONFIG не задано. Без нього kubectl шукає кластер
# на самій віртуалці, не знаходить і валить усі перевірки поспіль однією й тією ж помилкою,
# з якої справжню причину не видно.
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# Значення ключа секрету. base64 -d є не скрізь однаковий (BSD проти GNU),
# тому декодуємо пітоном — він уже потрібен бібліотеці перевірок.
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- секрет з доступом до бакета -------------------------------------------
# Перевіряємо не існування секрету, а те, що в ньому заповнені всі чотири поля.
# Секрет створюється руками, чотирма --from-literal поспіль, і найчастіша біда —
# порожнє або пропущене значення: об'єкт при цьому створюється успішно, а збірка падає
# на останньому кроці, коли збірка вже пройшла. Дешевше дізнатися зараз.
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "секрет ${SECRET} на місці, усі чотири ключі заповнені"
    # Значення ключів у звіт не потрапляють — тільки імена полів.
    evidence "Поля секрету ${SECRET}" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <приховано>
secretKey: <приховано>"
  else
    fail "у секреті ${SECRET} не заповнені поля:${MISSING}" \
         "перестворіть секрет командою з README, значення беруться в дашборді: Bucket -> builds -> Secrets"
  fi
else
  fail "у кластері немає секрету ${SECRET}" \
       "створіть секрет: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (чотири поля)"
fi

# --- чи доступне сховище зсередини кластера --------------------------------
# Найчастіша причина «Job упав на п'ятому кроці» — не ключі, а те, що до
# сховища з кластера не достукатися. Перевіряємо це окремо від збірки.
# Запит іде з Pod, а не з віртуалки: у віртуалки своя мережа і свої маршрути,
# і його успішна відповідь нічого не сказала б про те, чи дотягнеться туди збірка.
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # Без -k навмисно: збірка ходить у сховище з перевіркою сертифіката, і перевірка
  # зобов'язана падати там же, де впаде Job, а не видавати зелений на протухлому серті.
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "сховище ${EP} відповідає зсередини кластера (HTTP ${CODE})"
      evidence "Відповідь сховища" "GET https://${EP}/ -> HTTP ${CODE}
Коди 403 і 404 тут нормальні: анонімний запит до кореня S3 і має бути відхилений."
      ;;
    5*)
      warn "сховище ${EP} відповідає помилкою HTTP ${CODE}" \
           "збірка може пройти, але вивантаження APK — ні; скажіть викладачеві"
      ;;
    *)
      fail "сховище ${EP} не відповідає зсередини кластера" \
           "перевірте поле endpoint у секреті: воно має бути БЕЗ https:// і без слеша на кінці"
      ;;
  esac
else
  warn "не перевіряю доступність сховища" \
       "спочатку потрібен секрет ${SECRET} з полем endpoint"
fi

# --- сам Job ---------------------------------------------------------------
# Дивимось на .status.succeeded, а не на факт існування Job: об'єкт створюється
# миттєво і завжди успішно, а успіх задачі означає, що Pod завершився з кодом 0.
# Стан Pod розбирається окремо, тому що «ще йде» і «висить у Pending» для
# людини — різні новини: перше означає почекати, друге — що чекати марно
# і потрібно збільшувати вузол.
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "у кластері немає Job ${JOB}" \
       "запустіть збірку: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} завершився успішно"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
завершено: ${DURATION:-невідомо}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "Pod збірки висить у Pending — він не запустився і сам не запуститься" \
         "дивіться причину: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; при Insufficient memory збільшіть вузол до u1.large — як це зробити, написано в README"
    evidence "Події Pod збірки" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} завершився з помилкою (невдалих спроб: ${FAILED})" \
         "дивіться останні рядки лога: kubectl logs job/${JOB} --tail=40"
    evidence "Хвіст лога впалої збірки" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} ще не завершився (стан Pod: ${POD_PHASE:-невідомо})" \
         "перша збірка займає від пари хвилин до чверті години, залежно від каналу; стежте: kubectl logs -f job/${JOB}"
  fi

  # --- що саме сталося всередині ----------------------------------------
  # Успішний Job сам по собі не доводить нічого, крім нульового коду повернення.
  # Тому розкриваємо лог і шукаємо в ньому два різні свідчення: BUILD SUCCESSFUL —
  # що компіляція дійшла до кінця, і рядок-маркер APK-UPLOADED, який скрипт друкує
  # тільки після копіювання файлу в бакет. Друге сильніше за перше: APK може зібратися
  # і залишитися лежати всередині Pod, який ось-ось зникне.
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "логи збірки недоступні" \
         "Pod збірки видалено або ще не створено; без логів не можна підтвердити, що APK справді зібрався"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK справді зібрався (${GRADLE_LINE})"
    else
      fail "у логах немає рядка BUILD SUCCESSFUL — компіляція не дійшла до кінця" \
           "шукайте перший рядок з FAILURE: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK поїхав у бакет: ${UPLOADED}"
      evidence "Вміст бакета після збірки" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK у бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK зібрався, але в бакет не поїхав" \
           "дивіться хвіст лога: kubectl logs job/${JOB} --tail=20; найчастіше винен bucketName — у ньому потрібне довге ім'я з дашборда, а не 'builds'"
    fi
  fi
fi

# --- чи вистачає вузлу місця під таку збірку --------------------------------
# Не вирок, а пояснення: якщо Job не помістився, причина майже завжди тут.
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "найбільший вузол віддає ${BIGGEST_H} пам'яті — збірці вистачає"
      else
        warn "найбільший вузол віддає всього ${BIGGEST_H} пам'яті" \
             "збірка просить 4Gi тільки під requests; якщо Job висить у Pending, збільшіть тип вузла до u1.large — як, написано в README"
      fi
      ;;
    *)
      warn "на вузлах менше гігабайта доступної пам'яті (${BIGGEST_H})" \
           "збірка Android туди не поміститься, збільшіть тип вузла — як, написано в README"
      ;;
  esac
  evidence "Ресурси вузлів" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
