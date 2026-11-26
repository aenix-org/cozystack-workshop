# Лабораторна 4 · Викочування нової версії та відкат

| | |
|---|---|
| **Час** | 30 хвилин |
| **Що доводить** | Версію можна змінити й повернути назад під живим трафіком, без вікна обслуговування |
| **Що знадобиться** | Кластер з лабораторної 0, `rickroll` з лабораторної 1, Fortio з лабораторної 3, три вікна термінала, браузер |

## Чому це важливо

Сервіс «Перепустка» ви викотите один раз, а оновлювати його будете десятки разів. У звичній схемі кожне оновлення означає домовитися про вікно, суботню ніч, знімок перед початком і людину, яка сидить і спостерігає. Коли зміна коштує так дорого, зміни накопичуються: замість десяти маленьких викочувань ви робите одне велике, а велике ламається охочіше.

Скільки це коштує, ми з'ясуємо тут, на піддослідних — тобто на тренувальному `rickroll`, а не на «Перепусткау». Ми поміняємо версію застосунку **прямо посеред навантаження** — не в тиху годину, а серед тисяч запитів на хвилину — і подивимося на лічильник помилок. Потім відкотимося, знову під навантаженням.

## Маленький словничок

| Термін | Що це | Схоже на… але |
|---|---|---|
| **RollingUpdate** | Заміна копій по одній, а не всіх одразу | **Оновлення ВМ по одній вручну**, але кластер робить це сам і зупиняється, якщо нова копія не піднімається |
| **Revision** | Збережений знімок опису застосунку | **Знімок ВМ**, але зберігає лише опис — даних усередині немає |
| **maxSurge** | Скільки копій понад запитану кількість можна підняти під час викочування | прямого аналога немає; рахується як відсоток від `replicas` і округлюється вгору |
| **maxUnavailable** | Скільки копій можна вимкнути, не чекаючи заміни | **Скільки ВМ ви вимикаєте за раз**, але округлюється вниз, тож на трьох копіях виходить нуль |
| **readinessProbe** | Перевірка «готовий приймати трафік» | **Health check у пулі балансувальника**, але вона ще й притримує викочування, а не лише виводить учасника з балансування |
| **ReplicaSet** | Набір однакових копій, що відповідає за одну версію опису | **Пул однакових ВМ із шаблону**, але кожна версія отримує свій набір, а попередній залишається поряд із нулем копій |
| **EndpointSlice** | Список адрес копій, готових приймати трафік | **Список учасників пулу балансувальника**, але кластер веде його за мітками, а не адміністратор вручну |
| **JSON Patch** | Точкова правка одного поля за його шляхом усередині об'єкта | прямого аналога немає; шлях указує на **індекс** елемента в списку, а не на його ім'я |

## Що лежить у теці лабораторної

Усі файли у вас уже є — ви отримали їх разом із репозиторієм. Створювати чи передруковувати нічого не треба: скрізь, де нижче ви бачите `kubectl apply -f name.yaml`, файл береться звідси.

```bash
# From here on, all commands are run from this folder: paths in `kubectl apply -f` are counted from it.
cd labs/04-rollout
```

| Файл | Що це | Коли знадобиться |
|---|---|---|
| `rickroll-page-v2.yaml` | Друга версія сторінки — те, що ми викочуємо під навантаженням | ви застосовуєте його на своєму кластері `lab` |
| `check.sh` | Перевірка, що викочування пройшло без втрати запитів | ви запускаєте її наприкінці лабораторної |
| — | Генератор навантаження беремо із сусідньої лабораторної: `../03-scale/fortio.yaml` | |

## Крок 1. Готуємо ґрунт

📍 **Де:** на бастіоні (у терміналі бастіона).

Перед викочуванням треба зробити дві речі, і жодна з них не косметична.

**Вимикаємо автомасштабування**, бо воно теж керує полем `replicas`. Спостерігати за викочуванням, поки хтось одночасно змінює кількість копій, — гарантований спосіб не зрозуміти, що сталося. Один механізм на одне поле.

**Робимо три копії**, щоб заміна була видна по одній. Копія тут — це Pod: найменша одиниця виконання в кластері, контейнер застосунку разом із його оточенням, найближчий аналог однієї ВМ. З однією копією викочування теж пройшло б без простою, але ви побачили б лише «був один Pod, тепер інший» і не побачили б порядку, у якому кластер замінює їх.

```bash
# KUBECONFIG — the file with the cluster's address and the credentials to log into it. While the
# variable is set, every kubectl command goes to the `lab` cluster, not the one it was issued from.
export KUBECONFIG=~/lab.kubeconfig

# hpa — the autoscaler set up in the scaling lab. We delete it
# so the number of copies changes only on our command.
#   --ignore-not-found  don't treat it as an error if it's no longer in the cluster
kubectl delete hpa rickroll --ignore-not-found

# scale = "keep this many copies". The number goes into the application's description,
# and the cluster then brings up the missing ones itself.
kubectl scale deployment rickroll --replicas=3

# rollout status = "wait until the requested becomes actual". The command keeps the window
# busy until all three copies are ready, and only then returns the prompt.
kubectl rollout status deployment/rickroll
```

Перевірте, що генератор навантаження Fortio на місці:

```bash
# get = "show what's there". The reply `Error from server (NotFound)` means it isn't there.
kubectl get deployment fortio
```

Якщо його немає, підніміть із сусідньої теки: `kubectl apply -f ../03-scale/fortio.yaml`.

## Крок 2. Кладемо другу версію в кластер

📍 **Де:** на бастіоні (у терміналі бастіона).

У теці лежить `rickroll-page-v2.yaml` — опис об'єкта типу ConfigMap. ConfigMap тримає текстовий файл у кластері окремо від застосунку, а кластер потім кладе цей файл усередину контейнера. Тут він тримає сторінку, яку віддає nginx.

<details>
<summary><b>Придивимося ближче: що всередині rickroll-page-v2.yaml</b></summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rickroll-page-v2
data:
  index.html: |
    ...
    <div class="tag">VERSION 2</div>
    <h1>We're No Strangers To Love</h1>
    ...
    <div class="pod">served by pod<b>__POD__</b></div>
```

Усередині — одна сторінка: інший заголовок, інша колірна схема, помітний значок «VERSION 2». Відмінності зроблено навмисно кидкими — ви дивитиметеся в браузер, а не в diff.

Зверніть увагу на дві речі.

**`__POD__` усе ще на місці.** Підстановкою імені копії займаються налаштування nginx із ConfigMap `rickroll-conf`, спільного для обох версій. Ми змінюємо сторінку, а не поведінку сервера.

**Ім'я об'єкта — `rickroll-page-v2`, а не `rickroll-page`.** Це ключове рішення всієї лабораторної, і варто розписати чому.

Очевидний хід — інший: узяти наявний `rickroll-page-v1` і переписати його вміст. Одна команда, жодних нових об'єктів. Не робіть так, і ось чому.

По-перше, ви втратили б стару. Відкату не було б: попередня сторінка більше ніде не існує, крім вашого файлу — а якщо ви робили правку через `kubectl edit`, то її немає навіть у файлі.

По-друге, оновлення було б неконтрольованим. Опис застосунку не змінюється, коли ви правите ConfigMap, а отже Deployment — об'єкт, який зберігає цей опис (який образ, скільки копій, звідки брати файли) і стежить, щоб його було виконано, — нічого б не помітив і ніякого викочування не почав. Кластер тим не менш поміняв би файли всередині запущених Pod'ів — сам, у свій час, приблизно за хвилину, і в довільному порядку по копіях. Ви отримали б зміну, якої немає в історії, яку не можна відкотити командою і яка дійшла до копій урозсинхрон.

Звідси правило: **версії — це різні об'єкти, а перемикання версії — це зміна опису застосунку.** Саме так це бачить Deployment, саме так це потрапляє в історію ревізій і саме так це можна скасувати.

</details>

Застосуйте його. У кластері з'являється другий ConfigMap; запущеного застосунку він не торкнеться, бо на нього поки що ніщо не посилається:

```bash
# apply = "bring the cluster to what's described in the file".
#   -f name.yaml   where to take the description from; the file is in this same folder
kubectl apply -f rickroll-page-v2.yaml
```

**Що ви маєте побачити:** `configmap/rickroll-page-v2 created`.

Тепер відкрийте застосунок і переконайтеся, що **нічого не змінилося**:

```bash
# port-forward = a temporary tunnel from the bastion into the cluster.
#   svc/rickroll  where it leads: into the Service, that is, with requests spread across the copies
#   8080:80       on the left the port on the bastion, on the right the service's port inside the cluster
# While the tunnel is open the window is busy; it closes on Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> — та сама перша версія. Ми поклали нову сторінку в кластер, але застосунок про неї не знає: його том усе ще вказує на `rickroll-page-v1`. Закрийте тунель (`Ctrl+C`), це ще не викочування.

## Крок 3. Розуміємо, як кластер замінюватиме копії

📍 **Де:** на бастіоні (у терміналі бастіона).

Перш ніж перемикати версію, погляньмо на правила, за якими піде заміна. Вони живуть у самому описі застосунку:

```bash
# -o jsonpath=... — instead of a table, print a single field of the object by giving the path to it.
#   {.spec.strategy}  the block of rules by which the cluster replaces copies
#   {"\n"}            a newline at the end, otherwise the output runs into the prompt
kubectl get deployment rickroll -o jsonpath='{.spec.strategy}{"\n"}'
```

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

Цього блоку немає в `rickroll.yaml` — кластер підставив значення за замовчуванням.

<details>
<summary><b>Що означають ці відсотки з нашими трьома копіями</b></summary>

Обидва числа рахуються від `replicas`, тобто від трьох. І округлюються вони у протилежні боки.

**`maxSurge: 25%`** — скільки копій можна підняти **понад** запитану кількість, поки триває заміна. 25% від трьох — це 0.75, і округлення **вгору** дає 1. Тож під час викочування кластер може тимчасово мати чотири копії.

**`maxUnavailable: 25%`** — скільки копій можна одночасно тримати **недоступними**. 25% від трьох — ті самі 0.75, але округлення **вниз** дає **0**.

Нуль — жорстке обмеження. Кластеру не дозволено вимкнути жодну робочу копію, поки не з'явиться готова заміна. Не «спробує», а не дозволено: це обмеження, а не намір.

Звідси порядок дій на кожному кроці заміни:

1. підняти одну нову копію (дозволено `maxSurge`);
2. дочекатися, поки її `readinessProbe` відповість успіхом;
3. додати її в EndpointSlice, тобто направити на неї трафік;
4. **лише тепер** вивести одну стару копію з балансування і вимкнути її;
5. повторювати, поки не залишиться старих копій.

Усе тримається на третьому й четвертому пунктах, а вони тримаються на `readinessProbe`. Приберіть перевірку готовності з маніфесту — і кластер почне вважати копію придатною тієї ж миті, як запускається процес. Трафік піде на nginx, який ще не прочитав свій конфіг, і ви отримаєте порцію 500-х. Перевірка готовності тут — не моніторинг, а **гальмо викочування**, і це її головна робота.

Корисний наслідок: якщо нова версія зламана достатньо сильно, щоб не пройти перевірку готовності, викочування **зупиниться**. Старі копії продовжують працювати. Ми побачимо це ближче до кінця лабораторної, тільки зламаємо іншим способом.

</details>

## Крок 4. Вмикаємо навантаження

Викочувати мовчки нецікаво — так робили й у vSphere. Направмо трафік і поміняймо версію під ним.

📍 **Вікно 1** — тунель до Fortio:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
# A tunnel to the load generator: port 8081 on the bastion → port 8080 of the fortio service.
# 8081 was chosen on the left so as not to collide with the tunnel to the application itself on 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **У браузері** — <http://localhost:8081/fortio/>. Заповніть:

| Поле | Значення | Чому так |
|---|---|---|
| URL | `http://rickroll/` | ім'я Service — стала адреса, за якою стоять усі копії; трафік піде через балансування, а не на конкретний Pod |
| QPS | `300` | рівний фон; вичавлювати максимум зараз не треба |
| Duration | `180s` | три хвилини — вікно, за яке ми встигнемо і викотити, і відкотити |
| Connections | `20` | |

Натисніть **Start** і **не чіпайте браузер до кінця лабораторної**.

Те саме навантаження можна згенерувати командою, якщо з формою не склалося:

```bash
# exec = run a command inside an already-running Pod. The load is generated not by your bastion,
# but by Fortio itself from inside the cluster, so no tunnel is needed for this.
#   deploy/fortio  in any copy of the fortio application
#   --             everything to the right is a command for the container, not for kubectl
#   -qps 300       three hundred requests per second
#   -c 20          twenty simultaneous connections
#   -t 180s        hold the load for three minutes
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **Вікно 2** — спостерігаємо за копіями:

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — show only Pods with this label; others won't get into the output.
# -w = "watch and append": the window stays busy and prints a new line every time
# the state of some copy changes. Exit — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## Крок 5. Перемикаємо версію

📍 **Вікно 3** — вільне вікно. Перше тримає тунель до Fortio, друге зайняте спостереженням за Pod'ами, тож patch запускаємо в третьому. Доступ у ньому треба налаштувати знову:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
```

Тепер ми змінимо рівно одне поле в описі застосунку: том на ім'я `page` — тека, яку кладуть усередину контейнера — має брати свій вміст із ConfigMap `rickroll-page-v2`. Команди «онови застосунок» немає й ніколи не буде: є лише новий запис про те, як має бути. Кластер сам помітить розбіжність із фактичним станом і почне замінювати копії.

```bash
# patch = change a field in an object pinpoint-style, without rewriting the whole object.
#   --type=json  the edit format: "operation + path + value"
#   op: replace  replace what sits at this path
#   path         the address of the field inside the object; volumes/0 — the first volume in the list (see below)
#   value        the new ConfigMap name from which the volume will take the page
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v2"}]'
```

**Що ви маєте побачити:**

```
deployment.apps/rickroll patched
```

⚠️ **Цей patch крихкий, і про це треба сказати прямо.** Шлях `/spec/template/spec/volumes/0/...` адресує том **за його індексом у списку**. У `rickroll.yaml` том `page` іде першим, а `conf` другим — там про це навіть є коментар. Але якщо хтось поміняє їх місцями (а YAML цього ніяк не забороняє), та сама команда без жодної помилки перезапише ім'я конфіга nginx, і застосунок зламається спантеличливо.

<details>
<summary><b>Чому ми все одно робимо так, і як зробити правильно</b></summary>

Ми взяли JSON Patch, бо він показує механіку в чистому вигляді: одна команда, одне поле, видимий наслідок. Для лабораторної це цінно.

**Безпечніше** — те саме звичайним merge patch. Списки в Kubernetes можуть зливатися за ключем, і для `volumes` цей ключ — `name`:

```bash
# Without --type=json this is a merge patch: you describe a piece of the object in the same form
# it has in the manifest, and the cluster merges it with what's already there. The volumes list merges
# by the `name` key, so here the `page` volume is addressed, not "the volume at such-and-such index".
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

Тут адресація за іменем тому, порядок у списку не має значення, і сплутати нічого.

**Правильно** — не патчити взагалі. Patch, як і `kubectl edit`, змінює об'єкт у кластері, але не змінює ваш файл. За тиждень хтось застосує `rickroll.yaml` із репозиторію, і застосунок тихо з'їде назад до першої версії. Ніхто не зрозуміє чому.

У нормальній роботі версію змінюють так: ви правите рядок у файлі, відправляєте зміну на рев'ю, а після мержу автоматика застосовує її. Тоді стан кластера й вміст репозиторію завжди збігаються. Саме це ми й зробимо в лабораторній 5.

</details>

Дивіться, як іде заміна:

```bash
# rollout status prints the progress of the replacement line by line and finishes when all copies are updated.
# If the rollout doesn't converge, the command returns a non-zero exit code — convenient for
# stopping it in scripts.
kubectl rollout status deployment/rickroll
```

```
Waiting for deployment "rickroll" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "rickroll" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "rickroll" successfully rolled out
```

📍 **У вікні 2** ви тим часом можете побачити, як копії замінюються по одній: спершу з'являється нова й доходить до `1/1 Running`, і лише після цього одна зі старих переходить у `Terminating`.

Зверніть увагу на хвіст імен: у нових копій змінилася й середня частина — це інший ReplicaSet. Deployment не переробляв старий, а створив другий поряд і переливає копії з одного в інший. Старий нікуди не подівся; у нього нуль копій, і він чекає за лаштунками:

```bash
# rs — shorthand for ReplicaSet, a set of copies of one version of the description.
# DESIRED — how many copies are requested in this set, READY — how many of them are ready to answer.
kubectl get rs -l app=rickroll
```

```
NAME                  DESIRED   CURRENT   READY   AGE
rickroll-6f4b9c8d57   0         0         0       48m
rickroll-7c5d4f9b21   3         3         3       40s
```

## Крок 6. Рахуємо помилки

📍 **Де:** на бастіоні, у вікні 3 — воно звільнилося після попередньої команди.

Відкрийте тунель до застосунку:

```bash
# The same tunnel as at the start of the lab: port 8080 on the bastion → port 80 of the rickroll service.
kubectl port-forward svc/rickroll 8080:80
```

📍 **У браузері** <http://localhost:8080> — зелена сторінка зі значком «VERSION 2». Оновіть її кілька разів: ім'я копії внизу змінюється, бо Service розподіляє запити по трьох копіях.

Закрийте тунель (`Ctrl+C`).

📍 **Тепер головне — вкладка Fortio.** Дочекайтеся завершення прогону і знайдіть рядки з кодами відповідей:

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**Нуль помилок.** Застосунок повністю змінив свою версію, під безперервним трафіком, і жоден із п'ятдесяти чотирьох тисяч запитів не постраждав.

Заплатили ми за це одним блоком у маніфесті — тим самим `readinessProbe` з лабораторної 1. Без нього кластер вивів би стару копію з балансування ще до того, як переконався, що нова готова відповідати, і цей рядок виглядав би інакше.

⚠️ **Кілька десятків помилок на десятки тисяч запитів замість нуля** — це не зламане тестове середовище. Виведення копії з балансування і зупинка процесу всередині неї відбуваються паралельно, і під швидким трафіком жменя з'єднань устигає прослизнути в цей зазор. Лікується це паузою перед вимкненням (`preStop`) і акуратним дозливанням з'єднань у самому застосунку. У лабораторній ми навмисно цього не робимо: корисніше знати, що зазор існує, ніж припускати, що він закривається сам собою.

## Крок 7. Відкат

Запустіть навантаження в Fortio ще раз (ті самі параметри) і, поки воно йде, подивіться історію змін:

```bash
# history = the list of saved revisions of the description. Each line is a state you can
# return to with a single command. CHANGE-CAUSE — an optional note on why it was changed.
kubectl rollout history deployment/rickroll
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

Дві ревізії. Кожна — збережений знімок опису застосунку на момент зміни. Перша з `rickroll-page-v1`, друга з `v2`. Зберігаються вони саме тому, що старі ReplicaSet не видаляються: за замовчуванням кластер тримає десять останніх.

Відкат:

```bash
# undo with no extra parameters = return to the previous revision. This isn't "rewinding
# time", it's an ordinary rollout of the old description: copies are replaced one at a time, by the same
# maxSurge and maxUnavailable rules.
kubectl rollout undo deployment/rickroll
# We wait until the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

📍 **У вікні 2** — та сама процедура у зворотний бік: три нові копії піднімаються по одній, три поточні йдуть. `kubectl get rs -l app=rickroll` покаже, що копії повернулися в перший ReplicaSet — той, що висів із нулем.

📍 **У браузері** застосунок знову першої версії.

📍 **У Fortio** — знову `Code 200 ... (100.0 %)`.

**Порівняйте це з відкатом у vSphere.** Там відкат — це відновлення зі знімка: машина вимикається, файли повертаються, машина завантажується. Хвилини недоступності плюс втрата всього, що сталося після зняття знімка. Тут відкат — це повернення опису до попередньої ревізії, і він нічим не відрізняється від звичайного викочування: ті самі копії по одній, той самий нульовий простій.

⚠️ **`CHANGE-CAUSE` порожній, і це незручно.** Історія зберігає, *що* змінилося, але не зберігає, *чому*. За місяць ревізія 2 не скаже вам нічого. Заповнити причину можна анотацією `kubernetes.io/change-cause`, але справжня відповідь на це питання — не анотація, а Git, де в кожної зміни є автор, дата й текст коміту.

## Крок 8. Перевірка, яка не пройде

Механізм зрозумілий. Тепер погляньмо, що буває, коли викочування йде з помилкою — а це трапляється частіше, ніж хотілося б.

Уявіть звичайний ранок: колега готує третю версію сторінки, поспішає й робить в імені одрук. Маніфест при цьому валідний — кластер не зобов'язаний знати, що такого об'єкта немає. Відтворимо саме це:

```bash
# The same patch as when switching to the second version, but with a mistake in the ConfigMap name:
# there is no object `rickroll-page-v3` in the cluster. The reference's existence isn't checked on acceptance,
# so the command will finish successfully.
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v3"}]'

# --timeout=90s — don't wait forever: not having gotten ready copies, the command gives up after a
# minute and a half and returns an error. The rollout itself won't go anywhere and will stay hanging.
kubectl rollout status deployment/rickroll --timeout=90s
```

**Що ви побачите:**

```
Waiting for deployment "rickroll" rollout to finish: 0 of 3 updated replicas are available...
error: timed out waiting for the condition
```

Погляньте на склад копій: три попередні працюють, нова застрягла на запуску.

```bash
# The READY column counts the ready containers inside the Pod: 1/1 — ready, 0/1 — not.
# STATUS says exactly where the startup stalled.
kubectl get pods -l app=rickroll
```

```
NAME                        READY   STATUS              RESTARTS   AGE
rickroll-6f4b9c8d57-4kk2p   1/1     Running             0          6m
rickroll-6f4b9c8d57-9dnvt   1/1     Running             0          6m
rickroll-6f4b9c8d57-lm7bq   1/1     Running             0          6m
rickroll-8b6a1e5c39-wr4tz   0/1     ContainerCreating   0          90s
```

> **Зупиніться і подумайте, перш ніж читати далі.**
>
> Тут два питання, і друге важливіше за перше. Перше: чому нова копія не запускається? Друге: що відбувається зі сервісом просто зараз — він лежить?

<details>
<summary><b>Відповідь і урок, ширший за цю помилку</b></summary>

**Чому копія не піднялася.** Ми ніколи не створювали ConfigMap на ім'я `rickroll-page-v3` — його немає в кластері. Спитайте кластер напряму:

```bash
# events — the cluster's log of occurrences, the nearest analogue of the Tasks & Events tab in vCenter.
#   --field-selector reason=FailedMount  keep only the records about a failed volume mount
#   --sort-by=.lastTimestamp             sort by time, the freshest end up at the bottom
#   | tail -3                            show the last three lines, discard the rest
kubectl get events --field-selector reason=FailedMount --sort-by=.lastTimestamp | tail -3
```

```
Warning  FailedMount  kubelet  MountVolume.SetUp failed for volume "page":
         configmap "rickroll-page-v3" not found
```

Зверніть увагу: команда `kubectl patch` завершилася успішно й надрукувала `patched`. Кластер прийняв опис, у якому посилання веде в нікуди, і не сказав ані слова. Перевірки, що ConfigMap існує, під час прийняття маніфесту немає — вона була б можлива лише в момент запуску Pod'а, що якраз і сталося.

**А тепер друге питання, заради якого зроблено цей крок.** Відкрийте застосунок просто посеред застряглого викочування:

```bash
# The same tunnel. Traffic will go only to the copies that passed the readiness check,
# that is, to the three old ones: the stuck one didn't make it into balancing.
kubectl port-forward svc/rickroll 8080:80
```

Він працює. Перша версія, три копії, без помилок. Якби у вас у цю мить крутилося навантаження в Fortio — звіт усе одно показує сто відсотків 200-х.

**Цілком зламане викочування не поклало сервіс.** Це прямий наслідок `maxUnavailable: 0`, який ми з'ясували на початку лабораторної: кластеру не було дозволено вимкнути жодну робочу копію, поки він не отримає готову заміну. Заміни він не отримав — тож і не вимкнув нічого. Викочування зупинилося рівно там, де почало ламатися, і залишилося в цьому стані.

**Урок ширший за цю помилку.**

> Невдале викочування в Kubernetes за замовчуванням **застрягає**, а не обвалюється.

Це перевертає звичну логіку оновлення з ніг на голову. У схемі «зупини, онови, запусти» будь-яка помилка посеред означає простій, і саме тому оновлення роблять уночі, з людьми на телефоні. У схемі «підніми нове, переконайся, перемкни» помилка означає, що перемикання не відбулося — а старе продовжує працювати так само, як працювало.

Звідси практичний висновок для того, хто чергує: **застрягле викочування — не інцидент.** Воно не розбудить вас уночі. Розібратися з ним можна вранці — або відкотити однією командою й розібратися пізніше.

Саме це ми зараз і зробимо.

</details>

Виходимо:

```bash
# We return the previous revision — the one where the ConfigMap name is written correctly.
kubectl rollout undo deployment/rickroll
# We wait until the stuck copy disappears and the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

Застрягла копія зникає, а опис повертається до робочого.

## Перевірка

📍 **Де:** на бастіоні, у тому самому вікні термінала, де ви працювали з `kubectl`.

```bash
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **На Windows скрипт запускається з WSL**, а не з PowerShell — як його встановити, написано на початку лабораторної 0. Без WSL лабораторну пройти можна, але артефакта-звіту не буде.

Скрипт дивиться на суть справи, а не на команди, які ви набирали: в історії застосунку кілька ревізій (отже, версію справді змінювали й повертали назад), ConfigMap другої версії лежить у кластері, застосунок відповідає по HTTP, а сторінка, яку він віддає, збігається з ConfigMap, на який указує опис. Окремо він перевіряє `readinessProbe` — без нього нульовий простій не відтворити.

## Прибирання

Застосунок `rickroll` знадобиться далі — ми його не видаляємо. Поверніть його до однієї копії:

```bash
# Two extra copies will free up the node's memory — there won't be any load in the labs ahead.
kubectl scale deployment rickroll --replicas=1
```

Генератор навантаження більше не потрібен:

```bash
# delete -f = delete exactly the objects listed in the file, and nothing besides them.
# The path leads to the neighboring folder, because the file is where the scaling lab is.
kubectl delete -f ../03-scale/fortio.yaml
```

ConfigMap `rickroll-page-v2` можна залишити як є: він займає пару кілобайтів і не споживає ні CPU, ні пам'яті. Описи в Kubernetes зберігаються в базі площини керування й нічого не коштують, поки на них ніщо не посилається — на відміну від знімка віртуальної машини, який займає місце в сховищі й уповільнює машину тим сильніше, чим довше живе.

## Що ми тепер уміємо

- Змінити версію застосунку під живим трафіком і підтвердити за лічильником, що помилок не було
- Пояснити, звідки береться нульовий простій: `maxUnavailable`, `readinessProbe` і порядок «спершу готовий, потім перемикай»
- Прочитати історію ревізій і відкотитися однією командою
- Зрозуміти, чому версії роблять окремими об'єктами, а не правкою наявного
- Знати, що зламане викочування застрягає, а не кладе сервіс, і чому це не інцидент

## А у vSphere це було б

Вікно обслуговування, узгоджене заздалегідь. Знімок перед початком — хвилини й місце в сховищі. Оновлення на місці. Якщо не злетіло — відновлення зі знімка, ще хвилини недоступності. Усе це вночі, бо вдень так не можна.

Тут — одна команда вдень, під трафіком, і друга команда, якщо результат вам не сподобався.

**Де vSphere зручніший, чесно.** Три речі.

Найперше: **знімок бере весь стан, а `rollout undo` — лише опис.** Якщо за час, поки нова версія працювала, ваш застосунок устиг записати щось у базу чи змінити схему, відкат повертає код і не повертає дані. Ви отримаєте стару версію поверх нових даних — іноді це гірше, ніж залишити все як було. Знімок ВМ рятує вас від цього, `rollout undo` — ні. Саме з цієї причини міграції схеми бази даних пишуть сумісними в обидва боки, і це дисципліна, якої Kubernetes вимагатиме від вас там, де vSphere не вимагав.

По-друге, відкат у vSphere повертає геть усе: пакети, установлені руками, правку, внесену в конфіг по телефону. Тут відкочується лише те, що було описано в маніфесті. Усе, що хтось зробив збоку, не відкотиться, бо кластер про це не знає.

По-третє, знімок не вимагає від застосунку вміти працювати у двох версіях одночасно. А `RollingUpdate` вимагає: під час викочування старі й нові копії обслуговують запити разом, за однією адресою. Якщо вони несумісні між собою — за форматом сесій, за схемою даних, за протоколом — нульового простою не буде, буде каша. Для застосунків, що не готові до цього, є стратегія `Recreate`: вимкнути всі, потім підняти всі. Вона дає простій, але передбачуваний, і іноді чесніше обрати саме її.
