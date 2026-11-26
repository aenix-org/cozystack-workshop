# Лаба 4 · Викочування нової версії та відкат

| | |
|---|---|
| **Час** | 30 хвилин |
| **Що доводить** | Версію можна міняти й повертати під бойовим трафіком, без вікна обслуговування |
| **Що знадобиться** | Кластер із лаби 0, `rickroll` із лаби 1, Fortio із лаби 3, три вікна термінала, браузер |

## Навіщо це

Сервіс «Перепустка» ви викотите один раз, а оновлювати будете десятки разів. Кожне оновлення у звичній схемі — це погодження вікна, ніч суботи, знімок перед початком і людина, яка сидить і дивиться. Така ціна за зміну призводить до того, що зміни копляться: замість десяти маленьких викочують одну велику, а велика ламається охочіше.

Скільки це коштує тут, розберемося на кішках — тобто на навчальному `rickroll`, а не на «Перепустці». Ми підмінимо версію застосунку **прямо під час навантаження** — не в тиху годину, а посеред тисяч запитів за хвилину, — і подивимося на лічильник помилок. Потім відкотимося, теж під навантаженням.

## Словничок

| Термін | Що це | Схоже на… але |
|---|---|---|
| **RollingUpdate** | Заміна копій по черзі, а не всіх разом | **Оновлення ВМ по одній вручну**, але кластер робить це сам і зупиняється, якщо нова копія не піднялася |
| **Ревізія** | Збережений знімок опису застосунку | **Знімок ВМ**, але зберігає лише опис, жодних даних усередині немає |
| **maxSurge** | Скільки копій понад замовлене дозволено підняти на час викочування | прямого аналога немає; рахується у відсотках від `replicas` і округлюється вгору |
| **maxUnavailable** | Скільки копій дозволено погасити, не дочекавшись заміни | **Скільки ВМ гасимо за раз**, але округлюється вниз, тому при трьох копіях виходить нуль |
| **readinessProbe** | Перевірка «готовий приймати трафік» | **Health check у пулі балансувальника**, але вона ж гальмує викочування, а не лише виводить із балансування |
| **ReplicaSet** | Набір однакових копій, що відповідає за одну версію опису | **Пул однакових ВМ із шаблону**, але на кожну версію заводиться свій набір, а попередній лишається поруч із нулем копій |
| **EndpointSlice** | Список адрес копій, готових приймати трафік | **Список членів пулу балансувальника**, але його веде кластер за мітками, а не адміністратор вручну |
| **JSON Patch** | Точкове виправлення одного поля за шляхом усередині об'єкта | прямого аналога немає; шлях указує **номер** елемента у списку, а не ім'я |

## Що лежить у папці лаби

Усі файли вже у вас — ви забрали їх разом із репозиторієм. Створювати й друкувати заново нічого не потрібно: там, де нижче написано `kubectl apply -f name.yaml`, файл береться звідси.

```bash
# From here on, all commands are run from this folder: paths in `kubectl apply -f` are counted from it.
cd labs/04-rollout
```

| Файл | Що це | Коли знадобиться |
|---|---|---|
| `rickroll-page-v2.yaml` | Друга версія сторінки — те, що викочуємо під навантаженням | застосовуєте на своєму кластері `lab` |
| `check.sh` | Перевірка, що викочування пройшло без втрати запитів | запускаєте наприкінці лаби |
| — | Генератор навантаження беремо із сусідньої лаби: `../03-scale/fortio.yaml` | |

## Крок 1. Готуємо майданчик

📍 **Де:** на ноутбуці.

Перед викочуванням потрібно зробити дві речі, і обидві не косметичні.

**Автомасштабування знімаємо**, бо воно теж керує полем `replicas`. Спостерігати за викочуванням, коли одночасно з ним хтось міняє кількість копій, — гарантований спосіб не зрозуміти, що сталося. Один механізм на одне поле.

**Копій робимо три**, щоб заміну було видно поштучно. Копія тут — це Pod: мінімальна одиниця запуску в кластері, контейнер застосунку разом із його оточенням, найближчий аналог однієї ВМ. На одній копії викочування теж пройде без простою, але ви побачите лише «був один Pod, став інший» і не побачите, у якому порядку кластер їх міняє.

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

Якщо його немає — підніміть із сусідньої папки: `kubectl apply -f ../03-scale/fortio.yaml`.

## Крок 2. Кладемо в кластер другу версію

📍 **Де:** на ноутбуці.

У папці лежить `rickroll-page-v2.yaml` — опис об'єкта типу ConfigMap. ConfigMap тримає текстовий файл у кластері окремо від застосунку, а кластер потім підкладає цей файл усередину контейнера. Тут у ньому лежить сторінка, яку віддає nginx.

<details>
<summary><b>Розбираємо детальніше: що всередині rickroll-page-v2.yaml</b></summary>

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

Усередині одна сторінка: інший заголовок, інша колірна гама, помітна плашка «VERSION 2». Відмінності зроблені навмисне помітними — ви дивитиметеся в браузер, а не в diff.

Зверніть увагу на дві речі.

**`__POD__` лишився на місці.** Підміну імені копії роблять налаштування nginx із ConfigMap `rickroll-conf`, а він спільний для обох версій. Ми міняємо сторінку, а не поведінку сервера.

**Ім'я об'єкта — `rickroll-page-v2`, а не `rickroll-page`.** Це і є ключове рішення всієї лаби, і варто проговорити, чому саме так.

Напрошується ж інше: узяти наявний `rickroll-page-v1` і переписати в ньому вміст. Одна команда, жодних нових об'єктів. Так робити не треба, і ось чому.

По-перше, ви втратите старе. Відкату не буде: попередньої сторінки більше немає ніде, крім як у вашому файлі, — а якщо виправлення зробили через `kubectl edit`, то й у файлі його немає.

По-друге, оновлення вийде некерованим. Опис застосунку при виправленні ConfigMap не міняється, отже Deployment — об'єкт, який зберігає цей опис (який образ, скільки копій, звідки брати файли) і стежить за його виконанням, — нічого не помітить і жодного викочування не почне. Файли всередині працюючих Pod кластер при цьому все-таки підмінить — сам, у свій момент, протягом приблизно хвилини і в довільному порядку між копіями. Вийде зміна, якої немає в історії, яку не можна відкотити командою і яка доїхала до копій врозбрід.

Тому правило: **версії — це різні об'єкти, а перемикання версії — це зміна опису застосунку.** Саме так його побачить Deployment, так воно потрапить в історію ревізій, і так його можна буде скасувати.

</details>

Застосовуємо. У кластері з'явиться другий ConfigMap; працюючий застосунок він не зачепить, бо на нього поки що ніхто не посилається:

```bash
# apply = "bring the cluster to what's described in the file".
#   -f name.yaml   where to take the description from; the file is in this same folder
kubectl apply -f rickroll-page-v2.yaml
```

**Що ви маєте побачити:** `configmap/rickroll-page-v2 created`.

Тепер відкрийте застосунок і переконайтеся, що **нічого не змінилося**:

```bash
# port-forward = a temporary tunnel from the laptop into the cluster.
#   svc/rickroll  where it leads: into the Service, that is, with requests spread across the copies
#   8080:80       on the left the port on the laptop, on the right the service's port inside the cluster
# While the tunnel is open the window is busy; it closes on Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> — та сама перша версія. Ми поклали нову сторінку в кластер, але застосунок про неї не знає: його том, як і раніше, дивиться на `rickroll-page-v1`. Закрийте тунель (`Ctrl+C`), це ще не викочування.

## Крок 3. Розбираємося, як кластер буде міняти копії

📍 **Де:** на ноутбуці.

Перш ніж перемикати версію, подивимося на правила, за якими піде заміна копій. Вони лежать у самому описі застосунку:

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
<summary><b>Що означають ці відсотки при наших трьох копіях</b></summary>

Обидва числа рахуються від `replicas`, тобто від трьох. І округлюються вони в різні боки.

**`maxSurge: 25%`** — скільки копій дозволено підняти **понад** замовлене, поки йде заміна. 25% від трьох — це 0,75, округлення **вгору** дає 1. Значить на час викочування в кластері тимчасово може бути чотири копії.

**`maxUnavailable: 25%`** — скільки копій дозволено тримати **недоступними** одночасно. 25% від трьох — ті самі 0,75, але округлення **вниз** дає **0**.

Нуль — це жорстке обмеження. Кластер не має права погасити жодну працюючу копію, поки не з'явилася готова заміна. Не «постарається», а не має права: це обмеження, а не намір.

Звідси порядок дій на кожному кроці заміни:

1. підняти одну нову копію (дозволено `maxSurge`);
2. дочекатися, поки її `readinessProbe` відповість успіхом;
3. додати її в EndpointSlice, тобто пустити на неї трафік;
4. **тільки тепер** вивести з балансування і погасити одну стару;
5. повторити, поки старих не залишиться.

Усе тримається на третьому й четвертому пунктах, а вони тримаються на `readinessProbe`. Приберіть перевірку готовності з маніфесту — і кластер почне вважати копію придатною в момент запуску процесу. Трафік піде на nginx, який ще не прочитав конфіг, і ви отримаєте порцію п'ятисотих. Перевірка готовності тут не моніторинг, а **гальмо викочування**, і це її головна робота.

Корисний наслідок: якщо нова версія зламана настільки, що не проходить перевірку готовності, викочування **зупиниться**. Старі копії продовжать працювати. Ми це побачимо ближче до кінця лаби, тільки зламаємо по-іншому.

</details>

## Крок 4. Вмикаємо навантаження

Викочувати в тиші нецікаво — так робили і в vSphere. Пустимо трафік і будемо міняти версію під ним.

📍 **Вікно 1** — тунель до Fortio:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
# A tunnel to the load generator: port 8081 on the laptop → port 8080 of the fortio service.
# 8081 was chosen on the left so as not to collide with the tunnel to the application itself on 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **У браузері** — <http://localhost:8081/fortio/>. Заповнюємо:

| Поле | Значення | Чому так |
|---|---|---|
| URL | `http://rickroll/` | ім'я Service — постійної адреси, за якою стоять усі копії; трафік піде через балансування, а не в конкретний Pod |
| QPS | `300` | рівний фон; вичавлювати максимум зараз не потрібно |
| Duration | `180s` | три хвилини — вікно, усередині якого ми встигнемо і викотити, і відкотити |
| Connections | `20` | |

Натискаємо **Start** і **не чіпаємо браузер до кінця лаби**.

Те саме навантаження можна дати командою, якщо з формою не склалося:

```bash
# exec = run a command inside an already-running Pod. The load is generated not by your laptop,
# but by Fortio itself from inside the cluster, so no tunnel is needed for this.
#   deploy/fortio  in any copy of the fortio application
#   --             everything to the right is a command for the container, not for kubectl
#   -qps 300       three hundred requests per second
#   -c 20          twenty simultaneous connections
#   -t 180s        hold the load for three minutes
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **Вікно 2** — стежимо за копіями:

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — show only Pods with this label; others won't get into the output.
# -w = "watch and append": the window stays busy and prints a new line every time
# the state of some copy changes. Exit — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## Крок 5. Перемикаємо версію

📍 **Вікно 3** — вільне вікно. Перше тримає тунель до Fortio, друге зайняте спостереженням за Pod, тому патч виконуємо в третьому. Доступ у ньому потрібно задати заново:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
```

Зараз ми змінимо рівно одне поле в описі застосунку: том з іменем `page` — папка, яка підкладається всередину контейнера, — має брати вміст із ConfigMap `rickroll-page-v2`. Команди «онови застосунок» немає і не буде: є лише новий запис про те, як має бути. Розходження з фактичним станом кластер помітить сам і почне заміну копій.

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

⚠️ **Цей патч крихкий, і про це треба сказати прямо.** Шлях `/spec/template/spec/volumes/0/...` адресує том **за номером у списку**. У `rickroll.yaml` першим іде том `page`, другим `conf` — там навіть стоїть коментар про це. Але якщо хтось поміняє їх місцями (а YAML це ніяк не забороняє), та сама команда без жодної помилки перепише ім'я конфіга nginx, і застосунок зламається незрозумілим чином.

<details>
<summary><b>Чому ми все-таки робимо так і як правильно</b></summary>

JSON Patch узято тому, що він показує механіку в чистому вигляді: одна команда, одне поле, видимий наслідок. Для лаби це цінно.

**Безпечніше** — те саме звичайним патчем-злиттям. Списки в Kubernetes уміють зливатися за ключем, і в `volumes` цей ключ — `name`:

```bash
# Without --type=json this is a merge patch: you describe a piece of the object in the same form
# it has in the manifest, and the cluster merges it with what's already there. The volumes list merges
# by the `name` key, so here the `page` volume is addressed, not "the volume at such-and-such index".
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

Тут адресація йде за іменем тома, порядок у списку не має значення, і переплутати нічого.

**Правильно** — не патчити взагалі. Патч, як і `kubectl edit`, міняє об'єкт у кластері, але не міняє ваш файл. Через тиждень хтось застосує `rickroll.yaml` із репозиторію, і застосунок мовчки поїде назад на першу версію. Ніхто не зрозуміє, чому.

У нормальній роботі версію міняють так: правлять рядок у файлі, відправляють зміну на рев'ю, після злиття його застосовує автоматика. Тоді стан кластера і вміст репозиторію збігаються завжди. Саме цим ми займемося в лабі 5.

</details>

Дивимося, як іде заміна:

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

📍 **У вікні 2** тим часом видно, як копії змінюються по одній: спочатку з'являється нова і доходить до `1/1 Running`, і лише після цього одна зі старих іде в `Terminating`.

Зверніть увагу на хвіст імен: у нових копій змінилася й середня частина — це інший ReplicaSet. Deployment не переробляв старий, він створив поруч другий і переливає копії з одного в інший. Старий нікуди не подівся, у ньому нуль копій, і він чекає своєї години:

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

📍 **Де:** на ноутбуці, у вікні 3 — воно звільнилося після попередньої команди.

Відкриваємо тунель до застосунку:

```bash
# The same tunnel as at the start of the lab: port 8080 on the laptop → port 80 of the rickroll service.
kubectl port-forward svc/rickroll 8080:80
```

📍 **У браузері** <http://localhost:8080> — зелена сторінка з плашкою «VERSION 2». Оновіть кілька разів: ім'я копії внизу міняється, бо Service розкладає запити по трьох копіях.

Закрийте тунель (`Ctrl+C`).

📍 **Тепер головне — вкладка Fortio.** Дочекайтеся кінця прогону і знайдіть рядки з кодами відповіді:

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**Помилок нуль.** Застосунок змінив версію цілком, під безперервним трафіком, і жоден із п'ятдесяти чотирьох тисяч запитів не постраждав.

Заплатили за це одним блоком у маніфесті — тією самою `readinessProbe` із лаби 1. Без неї кластер виводив би стару копію з балансування, не переконавшись, що нова готова відповідати, і цей рядок виглядав би інакше.

⚠️ **Кілька десятків помилок на десятки тисяч запитів замість нуля** — це не поломка тестового середовища. Видалення копії з балансування і зупинка процесу в ній відбуваються паралельно, і на швидкому трафіку в цей зазор устигає потрапити жменя з'єднань. Лікується це паузою перед зупинкою (`preStop`) і коректним завершенням з'єднань у самому застосунку. Ми цього в лабі не робимо навмисне: корисніше знати, що зазор існує, ніж вважати, буцімто він закривається сам.

## Крок 7. Відкочуємося

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

Дві ревізії. Кожна — збережений знімок опису застосунку на момент зміни. Перша з `rickroll-page-v1`, друга з `v2`. Зберігаються вони рівно тому, що старі ReplicaSet не видаляються: за замовчуванням кластер тримає десять останніх.

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

**Порівняйте з відкатом у vSphere.** Там відкат — це відновлення зі знімка: машина вимикається, файли повертаються, машина завантажується. Хвилини недоступності плюс втрата всього, що сталося після зняття знімка. Тут відкат — це повернення опису до попередньої ревізії, і він нічим не відрізняється від звичайного викочування: ті самі копії по одній, той самий нульовий простій.

⚠️ **`CHANGE-CAUSE` порожній, і це незручно.** Історія зберігає, *що* помінялося, але не зберігає, *чому*. Через місяць ревізія 2 не скаже вам нічого. Заповнити причину можна анотацією `kubernetes.io/change-cause`, але справжня відповідь на це питання — не анотація, а Git, де в кожної зміни є автор, дата і текст коміту.

## Крок 8. Перевірка, яка не пройде

Механізм зрозумілий. Тепер подивимося, що буває, коли викочування йде з помилкою — а це трапляється частіше, ніж хотілося б.

Уявіть звичайний ранок: колега готує третю версію сторінки, поспішає і в імені робить одрук. Маніфест при цьому валідний — кластер не зобов'язаний знати, що такого об'єкта немає. Відтворимо рівно це:

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

Дивимося на склад копій: три попередні працюють, нова застрягла на запуску.

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
> Питань тут два, і друге важливіше за перше. Перше: чому нова копія не запускається? Друге: що зараз відбувається із сервісом — він лежить?

<details>
<summary><b>Відповідь і урок, ширший за цю помилку</b></summary>

**Чому копія не піднялася.** ConfigMap з іменем `rickroll-page-v3` ми не створювали — його в кластері немає. Спитайте в кластера напряму:

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

Зауважте: команда `kubectl patch` відпрацювала успішно і надрукувала `patched`. Кластер прийняв опис, у якому посилання веде в нікуди, і не сказав ні слова. Перевірки на існування ConfigMap при прийманні маніфесту немає — вона була б можлива лише в момент запуску Pod, що й сталося.

**А тепер друге питання, заради якого крок і зроблено.** Відкрийте застосунок прямо посеред застряглого викочування:

```bash
# The same tunnel. Traffic will go only to the copies that passed the readiness check,
# that is, to the three old ones: the stuck one didn't make it into balancing.
kubectl port-forward svc/rickroll 8080:80
```

Воно працює. Перша версія, три копії, помилок немає. Якщо у вас у цей момент ішло навантаження в Fortio — у звіті, як і раніше, сто відсотків двохсотих.

**Повністю зламане викочування не поклало сервіс.** Це прямий наслідок `maxUnavailable: 0`, яке ми рахували на початку лаби: кластер не мав права погасити жодної працюючої копії, поки не отримав готову заміну. Заміни він не отримав — значить і гасити не став. Викочування зупинилося рівно там, де почало ламатися, і залишилося в цьому стані.

**Урок ширший за цю помилку.**

> Невдале викочування в Kubernetes за замовчуванням **застрягає**, а не обвалюється.

Це перевертає звичну логіку оновлення. У схемі «зупинили, оновили, запустили» будь-яка помилка посередині означає простій, і тому оновлення роблять уночі, з людьми на телефоні. У схемі «підніми нове, переконайся, переключи» помилка означає, що перемикання не сталося, — а старе як працювало, так і працює.

Звідси практичний наслідок для чергового: **застрягле викочування — не інцидент.** Воно не будить вас уночі. Його можна розібрати вранці — або відкотити однією командою і розбиратися потім.

Саме це ми зараз і зробимо.

</details>

Вибираємося:

```bash
# We return the previous revision — the one where the ConfigMap name is written correctly.
kubectl rollout undo deployment/rickroll
# We wait until the stuck copy disappears and the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

Зависла копія зникає, опис повертається до робочого.

## Перевірка

📍 **Де:** на ноутбуці, у тому ж вікні термінала, де ви працювали з `kubectl`.

```bash
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **На Windows скрипт запускається з WSL**, а не з PowerShell — як його поставити, написано на початку лаби 0. Без WSL лабу можна пройти, але звіту-артефакту не буде.

Скрипт дивиться на суть справи, а не на набрані команди: в історії застосунку є кілька ревізій (значить версію справді міняли і повертали), у кластері лежить ConfigMap другої версії, застосунок відповідає по HTTP, і віддана ним сторінка відповідає тому ConfigMap, на який указує опис. Окремо перевіряється `readinessProbe` — без неї нульовий простій не відтворити.

## Прибирання

Застосунок `rickroll` знадобиться далі — не видаляємо. Поверніть йому одну копію:

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

ConfigMap `rickroll-page-v2` можна лишити: він займає пару кілобайтів і не споживає ні процесора, ні пам'яті. Описи в Kubernetes зберігаються в базі площини керування (control plane) і нічого не коштують, поки на них ніхто не посилається, — на відміну від знімка віртуальної машини, який займає місце на сховищі і тим сильніше сповільнює машину, чим довше живе.

## Що ми тепер уміємо

- Міняти версію застосунку під бойовим трафіком і перевіряти за лічильником, що помилок не було
- Пояснювати, звідки береться нульовий простій: `maxUnavailable`, `readinessProbe` і порядок
  «спочатку готово, потім перемикаємо»
- Читати історію ревізій і відкочуватися однією командою
- Розуміти, чому версії роблять різними об'єктами, а не виправленням наявного
- Знати, що зламане викочування застрягає, а не валить сервіс, і чому це не інцидент

## А в vSphere це було б

Вікно обслуговування, погоджене заздалегідь. Знімок перед початком — хвилини і місце на сховищі. Оновлення на місці. Якщо не злетіло — відновлення зі знімка, ще хвилини недоступності. Усе це вночі, бо вдень не можна.

Тут — одна команда вдень, під трафіком, і друга команда, якщо не сподобалося.

**Де vSphere зручніше, чесно.** Три речі.

По-перше і головне: **знімок забирає стан цілком, а `rollout undo` — лише опис.** Якщо ваш застосунок за час роботи нової версії встиг щось записати в базу або змінити схему, відкат поверне код і не поверне дані. Ви отримаєте стару версію поверх нових даних — іноді це гірше, ніж лишити як було. Знімок віртуалки від цього рятує, `rollout undo` — ні. Рівно тому міграції схеми БД пишуть сумісними в обидва боки, і це дисципліна, якої Kubernetes від вас вимагатиме, а vSphere не вимагав.

По-друге, відкат у vSphere повертає взагалі все: пакети, які доставили руками, виправлення в конфізі, зроблене по телефону. Тут відкочується лише те, що було описано в маніфесті. Усе, що хтось зробив в обхід, не відкотиться, бо кластер про нього не знає.

По-третє, знімок не вимагає, щоб застосунок умів працювати у двох версіях одночасно. А `RollingUpdate` вимагає: під час викочування старі й нові копії обслуговують запити разом, за однією адресою. Якщо вони несумісні між собою — за форматом сесії, за схемою даних, за протоколом — нульового простою не буде, буде каша. Для застосунків, які до цього не готові, існує стратегія `Recreate`: погасити всі, потім підняти всі. Вона дає простій, зате передбачувана, і іноді чесніше вибрати її.
