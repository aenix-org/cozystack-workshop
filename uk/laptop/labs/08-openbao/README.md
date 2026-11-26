# Лаба 8 · Секрети не в маніфесті

| | |
|---|---|
| **Час** | 50 хвилин, частина з них — очікування, поки сховище піднімається і ви його розпечатуєте |
| **Що доводить** | Пароль можна прибрати з Git назавжди і міняти його, не торкаючись жодного файлу |
| **Що знадобиться** | Кластер із лаби 0 і `~/lab.kubeconfig`; доступ до дашборду свого тенанта; номер тенанта вигляду `workshopXX` |

> ⚠️ **`workshopXX` — це заглушка, а не ім'я.** Підставте свій номер тенанта, інакше
> команда піде в чужий тенант і ви отримаєте відмову в доступі або, що гірше, чужі
> дані. Свій номер ви отримали разом із паролем.

> ⚠️ **Щільна лаба: одинадцять кроків і незнайома модель доступу.**
> Плануйте її одним суцільним заходом, без перерви на середині.

## Навіщо це

Сервіс «Перепустка» працює: співробітник замовляє пропуск для гостя, охорона бачить список.
Служба ІБ прийшла з плановим аудитом і принесла один рядок із вашого репозиторію:

```yaml
- name: DB_PASSWORD
  value: "Propusk2019!"
```

Пароль від бази пропусків лежить у маніфесті. Маніфест лежить у Git. Git бачать дванадцять
людей із трьох команд, ще четверо звільнилися, а повна копія репозиторію є на ноутбуці
підрядника, який робив інтеграцію торік.

Питання від аудитора звучить буденно: **«поміняйте цей пароль і покажіть, хто його читав за
останній місяць»**. Відповісти нічого. Поміняти пароль — означає знайти всі місця, де він
захардкоджений; хто читав — невідомо, бо читання файлу з Git ніде не фіксується.

У цій лабі ми винесемо пароль в OpenBao, навчимо застосунок забирати його звідти, поміняємо
пароль однією командою і подивимося, що про це знає система.

Дорогою розберемося з питанням, на якому спотикаються майже всі: **чим Secret у
Kubernetes відрізняється від справжнього сховища секретів.**

Кожен термін цієї лаби розшифровується під час першої появи, а наступний розділ —
словничок уже введених.

## Словничок

| Термін | Що це | Схоже на… але |
|---|---|---|
| **Secret (Kubernetes)** | Об'єкт кластера з даними, записаними в base64 | **Файл із паролем на диску VM**, але виглядає захищеним і не захищений — розбираємо це нижче |
| **base64** | Спосіб записати будь-які байти друкованими символами | **uuencode, MIME-вкладення**, але це не шифрування. Ключа немає, зворотне перетворення робить хто завгодно |
| **Сховище секретів** | Окрема служба: зберігає секрети зашифрованими і видає їх за правилами | **Прямого аналога немає**, але це не «мережева тека з паролями», а сервіс із політиками, строками і журналом |
| **OpenBao** | Таке сховище. Форк HashiCorp Vault, живе під ліцензією MPL | команди й API збігаються з Vault, лише утиліта називається `bao` |
| **Root-токен** | Обліковий запис із повним доступом до всього | **root**, але ним користуються один раз при налаштуванні, далі випускають вузькі токени |

Решта слів цієї лаби — `sealed`, unseal-ключ, політика, токен, KV v2, ротація, аудит-лог,
init-контейнер — вводяться по ходу, у тому кроці, де вперше знадобляться. Заучувати їх зараз не
треба: у відриві від дії вони все одно не запам'ятаються.

<details>
<summary><b>Якщо хочете побачити весь список одразу</b></summary>

| Термін | Що це | Схоже на… але |
|---|---|---|
| **Запечатаний (sealed)** | Служба запущена, але майстер-ключ не в пам'яті: дані лежать зашифрованими, API відповідає відмовою | **«Служба піднялася, але том не примонтований»**, але після кожного перезапуску розпечатувати треба заново, руками |
| **Unseal-ключ** | Частка майстер-ключа, якою розпечатують сховище | **Ключ від сейфа**, але часток декілька, і за замовчуванням треба пред'явити не одну |
| **Політика (policy)** | Список шляхів і того, що з ними дозволено | **ACL на теку**, але шлях — це адреса в API, а не файл на диску |
| **Токен** | Тимчасовий пропуск до сховища | **Сесія**, але в токена є строк життя, він протухає сам і його можна відкликати |
| **KV v2** | Рушій «ключ-значення» з історією версій | **Тека з файлами й історією змін**, але зберігає всі версії і час кожного запису, старе значення не зникає |
| **Ротація** | Планова заміна секрета на новий | **Зміна пароля за регламентом**, але тут це одна команда, застосунок підхоплює її під час наступного запуску |
| **Аудит-лог** | Журнал «хто, коли, що запитував» | **Лог доступу до файлового ресурсу**, але пишеться на кожен запит до API, включно з невдалими і відмовами |
| **Секрет нульового рівня** | Той єдиний секрет, яким застосунок доводить право на всі інші | його не можна прибрати зовсім. Можна зробити коротким, вузьким і одноразовим |
| **Init-контейнер** | Контейнер, який відпрацьовує і завершується до запуску основного | **Скрипт в автозавантаженні до старту служби**, але якщо він упав — основний не стартує взагалі, і це якраз те, що потрібно |

</details>

## Що лежить у теці лаби

Усі файли вже у вас — ви забрали їх разом із репозиторієм. Створювати і друкувати заново
нічого не треба: там, де нижче написано `kubectl apply -f name.yaml`, файл береться звідси.

```bash
cd labs/08-openbao
```

| Файл | Що це | Коли знадобиться |
|---|---|---|
| `openbao.yaml` | Замовлення сховища секретів — те саме, що кнопка в дашборді | застосовуєте **в тенанті**, не в кластері `lab` |
| `secrets-demo-naive.yaml` | Як сервіс виглядає сьогодні: пароль прямо у файлі. Це і знайшов аудит | застосовуєте на своєму кластері `lab` |
| `secrets-demo-secret.yaml` | «Наївне виправлення»: пароль винесено в Secret — і чому цього мало | застосовуєте туди ж |
| `secrets-demo.yaml` | Фінальний варіант: пароля немає ні у відкритому вигляді, ні в base64 | застосовуєте туди ж |
| `check.sh` | Перевірка, що застосунок отримує пароль зі сховища | запускаєте наприкінці лаби |

## Крок 1. Дивимося на проблему власними очима

📍 **Де:** на ноутбуці, у лабораторному кластері.

Відтворимо знахідку аудиту в себе: піднімемо в лабораторному кластері маленький сервіс
`secrets-demo`, якому пароль передано прямо з опису. Спочатку розбираємо файл,
потім застосовуємо.

<details>
<summary><b>Придивімося: що всередині secrets-demo-naive.yaml</b></summary>

Це звичайний `Deployment` — опис застосунку: який образ узяти і скільки копій тримати
запущеними. **Образ** — готовий зліпок файлової системи з програмою всередині; найближчий
аналог із vSphere — шаблон віртуальної машини, тільки без операційної системи.
**Контейнер** — запущений екземпляр образу. **Pod** — найменша одиниця запуску
в Kubernetes: один або кілька контейнерів, які завжди живуть і вмирають разом.
Deployment стежить, щоб кількість запущених Pod відповідала замовленій.

```yaml
      containers:
        - name: app
          image: busybox:1.36
```

Справжній «Перепустка», який ви зібрали на Go в лабі про свій реєстр, ми тут не чіпаємо:
він працює, і ламати його заради вправи ні до чого. Тому поруч піднімаємо окремий
маленький сервіс `secrets-demo` — нас цікавить не застосунок, а шлях,
яким у нього потрапляє пароль. Тому замість нього крихітний контейнер, який робить
єдину осмислену річ — раз на десять секунд пише в лог, з яким паролем він
працює.

```yaml
          env:
            - name: DB_PASSWORD
              value: "Propusk2019!"
```

Ось цей рядок і є предметом розмови. Змінні оточення — найзвичайніший спосіб
передати застосунку налаштування: `env` у маніфесті перетворюється на змінну всередині
контейнера. Спосіб добрий, а от **значення прямо у файлі** — погане.

```yaml
                  "$(printf %s "$DB_PASSWORD" | sha256sum | cut -c1-12)"
```

Застосунок друкує не пароль, а його **відбиток** — перші дванадцять символів від
sha256. За відбитком видно, що пароль змінився, але відновити сам пароль не можна.
Так і треба писати логи; ми користуватимемося цим до кінця лаби.

`resources.requests` — скільки ресурсів зарезервувати гарантовано (аналог
reservation у vSphere), `resources.limits` — вище чого не давати піднятися (аналог
limit). Значення крихітні навмисне: застосунок нічого не робить.

</details>

**Застосовуємо.**

```bash
# KUBECONFIG tells kubectl which cluster to talk to. Here it's the lab cluster
# from Lab 0; the tenant will be needed later, at the step where we order the store.
export KUBECONFIG=~/lab.kubeconfig
cd labs/08-openbao
# apply = "bring the cluster to what's described in the file". -f = take the description from the file.
# No object with this name exists yet, so it will be created.
kubectl apply -f secrets-demo-naive.yaml
```

**Що ви маєте побачити** — рядок, що закінчується словом `created`.

Дивимося, що вийшло:

```bash
# logs = show what the application printed to its output. There's no separate log file.
#   deploy/secrets-demo  take the output from the Pod brought up by this description
#   --tail=2             only the last two lines, not everything since startup
kubectl logs deploy/secrets-demo --tail=2
```

**Що ви маєте побачити** — приблизно таке:

```
08:14:31 connecting to passes-db.internal as passes_app, password fingerprint sha256:a609df223d57
```

Застосунок працює. Пароль — у файлі, файл — у Git. Це рівно та ситуація, яку знайшов
аудит.

## Крок 2. Наївне виправлення: виносимо пароль у Secret

📍 **Де:** на ноутбуці, у лабораторному кластері.

Перше, що пропонує будь-який пошук в інтернеті: «в Kubernetes для цього є Secret».
Зробимо, як радять, — і спочатку подивимося, що змінюється у файлі.

<details>
<summary><b>Що змінилося в маніфесті</b></summary>

З'явився окремий об'єкт:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: passes-db
type: Opaque
data:
  password: UHJvcHVzazIwMTkh
```

`Secret` — об'єкт кластера, призначений для чутливих даних. Значення в полі
`data` записуються в base64, тому у файлі замість `Propusk2019!` тепер стоїть
`UHJvcHVzazIwMTkh`.

А в Deployment замість значення з'явилося посилання:

```yaml
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: passes-db
                  key: password
```

`valueFrom` замість `value` означає: «візьми значення не звідси, а он із того об'єкта».
Kubernetes підставить вміст ключа `password` із секрета `passes-db` у змінну
`DB_PASSWORD` під час запуску контейнера.

Само по собі це правильний прийом — посилатися на секрет, а не вписувати значення.
Питання в тому, що лежить за посиланням.

</details>

**Застосовуємо.**

```bash
# The same apply. The file holds two objects — a Secret and the changed Deployment; the cluster will
# compare what's described against what it already has and bring the two into line.
kubectl apply -f secrets-demo-secret.yaml
```

Переконаємося, що застосунок так само працює:

```bash
# rollout status waits until the new version of the application has fully replaced the old one, and only
# then returns control. Without it you might read the logs of the old Pod.
kubectl rollout status deploy/secrets-demo
kubectl logs deploy/secrets-demo --tail=2
```

Відбиток той самий — `sha256:a609df223d57`. Застосунок отримав той самий пароль іншим шляхом.

**Проблему вирішено?** Пароль більше не написаний у Deployment. У файлі стоїть незрозумілий
рядок. Перевіримо.

## Передбачувана невдача · «Secret» — це не «зашифровано»

Спробуйте переконатися, що тепер усе добре. Спитайте в кластера, що лежить у секреті:

```bash
# get … -o yaml = "show the object in full, exactly as the cluster stores it".
# Look at the data field — that's the secret's contents.
kubectl get secret passes-db -o yaml
```

Ви побачите той самий рядок `UHJvcHVzazIwMTkh`. Виглядає незрозуміло, а отже безпечно.

Тепер одна команда:

```bash
#   -o jsonpath='{.data.password}'  pull exactly one field out of the object, without the wrapper
#   | base64 -d                     pass it along and decode it: d = decode
#   ; echo                          print a trailing newline, otherwise the result runs into
#                                   the next terminal prompt
kubectl get secret passes-db -o jsonpath='{.data.password}' | base64 -d; echo
```

> **Зупиніться і подумайте, перш ніж читати далі.**
>
> Що саме ви зараз зробили, щоб отримати пароль? Який ключ вам знадобився? У кого
> ще є можливість виконати цю команду?

<details>
<summary><b>Відповідь і урок, ширший за цю помилку</b></summary>

Вивід — `Propusk2019!`. Відкритим текстом.

**base64 — це не шифрування, а кодування.** Його придумали, щоб передавати
довільні байти каналами, розрахованими на текст: вкладення в пошті, дані в JSON,
бінарники в конфігах. Ключа в ньому немає, бо й захисту в ньому немає. Зворотне
перетворення робить будь-яка людина, будь-який браузер і будь-який сайт-декодер.

Kubernetes використовує base64 в Secret рівно з цієї причини: у YAML не можна покласти
довільні байти (наприклад, сертифікат або ключ), а в base64 — можна. Слово «Secret»
у назві об'єкта означає «сюди кладуть чутливе», а не «тут воно захищене».

Що з цього випливає практично:

| Твердження | Правда? |
|---|---|
| Secret зашифрований у кластері | Ні. У сховищі кластера він лежить майже відкритим текстом, якщо адміністратор окремо не ввімкнув шифрування сховища |
| Secret можна покласти в Git | Ні. Це те саме, що покласти туди пароль |
| Хто прочитав Secret — видно | Ні. Звичайне читання об'єкта ніде не фіксується |
| Secret не можна прочитати без прав | Правда, і це єдиний реальний захист. Права в кластері доступ обмежують |
| Secret змінюється сам за розкладом | Ні. Міняєте ви, руками, у всіх місцях одразу |

**Урок ширший за цю помилку.** І головне. Навіть якби все це було вирішено, залишається
питання аудитора: **покажіть, хто читав пароль за місяць.** Kubernetes на нього не
відповідає в принципі — не тому що погано зроблений, а тому що це не його задача.
Зберігання секретів — окрема робота, і для неї є окрема служба.

До речі, ваша роль у тенанті Cozystack секрети через `kubectl` читати **не дає** —
спробуєте і отримаєте відмову. Але лабораторний кластер із лаби 0 ваш цілком, і там ви
адміністратор. Саме тому команда вище і спрацювала.

</details>

## Крок 3. Замовляємо OpenBao

📍 **Де:** у браузері, у дашборді Cozystack, у своєму тенанті.

Тенант → **Створити застосунок** → `OpenBAO`.

| Поле | Значення | Чому так |
|---|---|---|
| Ім'я | `secrets` | коротко, далі його доведеться набирати в адресах |
| Replicas | **1** | навчальне тестове середовище. При двох і більше чарт вмикає Raft-реплікацію, і це вже інший режим зберігання |
| Size | `2Gi` | секрети займають кілобайти, місце потрібне під службові дані |
| Storage class | `replicated` | дані ляжуть у трьох копіях на різні вузли |
| Resources preset | `t1.small` | 1 процесор, 512 МБ |
| UI | увімкнено | вебінтерфейс усередині кластера |
| External | вимкнено | назовні не виставляємо |

⚠️ **Перемикання між однією копією і кількома — не галочка.** Одна копія зберігає
дані у файлі, кілька — у Raft. Зміна режиму вимагає перенесення даних, тому в
проді рішення ухвалюють до встановлення, а не після.

### Те саме текстом — і розбір полів

У теці лаби лежить `openbao.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: OpenBAO
metadata:
  name: secrets
  namespace: tenant-workshopXX
spec:
  replicas: 1
  size: 2Gi
  storageClass: replicated
  resourcesPreset: t1.small
  ui: true
  external: false
```

`apiVersion: apps.cozystack.io/v1alpha1` — це і є каталог Cozystack, тільки з того
боку, звідки його видно як API. Дашборд при натисканні кнопки збирає рівно такий
об'єкт і надсилає його в кластер. Кнопка — надбудова над текстом, а не альтернатива.

`kind: OpenBAO` — позиція в каталозі. Зверніть увагу на регістр: `OpenBAO`, а не
`OpenBao`. Кластер до регістру прискіпливий.

`namespace: tenant-workshopXX` — **керовані сервіси живуть у вашому тенанті на
кластері керування, а не в лабораторному кластері з лаби 0.** Це два різні кластери,
і це важливо пам'ятати весь залишок лаби: застосунок буде в одному, сховище — в іншому.

`replicas`, `size`, `storageClass`, `resourcesPreset` — те саме, що ви заповнювали мишкою.

`ui: true` — підняти вебінтерфейс. `external: false` — не видавати сервісу зовнішню
адресу; зсередини кластера він і так доступний.

Застосовується цей файл **не в лабораторний кластер**, а в тенант:

```bash
# --kubeconfig names the access file explicitly and overrides the KUBECONFIG variable.
# So the order goes to the tenant on the management cluster, not to the lab cluster.
kubectl --kubeconfig ~/.kube/workshop apply -f openbao.yaml
```

Kubeconfig тенанта береться в дашборді: **Info → вкладка Secrets →
`kubeconfig-tenant-workshopXX`**. Збережіть його в `~/.kube/workshop`.

Далі по тексту ми цим файлом майже не користуємося: замовлення сервісів іде мишкою, а
робота з самим OpenBao — через його власний API.

Дочекайтеся, поки застосунок перейде в готовий стан. Це одна-дві хвилини.

## Крок 4. Заводимо робочий Pod і перевіряємо зв'язок

📍 **Де:** на ноутбуці, у лабораторному кластері.

Тут треба зупинитися і зрозуміти розстановку.

**OpenBao живе у вашому тенанті на кластері керування.** Ваша роль у тенанті дозволяє
замовляти й видаляти сервіси, але не запускати там свої Pod і не під'єднуватися до сервісів
пробросом порту. Це не поломка, а межа: тенант — місце для керованих сервісів, а не
робочий майданчик.

**Ваш робочий майданчик — лабораторний кластер із лаби 0.** Там ви адміністратор. Звідти
ми й будемо ходити в OpenBao — за внутрішньою адресою, яка є в будь-якого сервісу:

```
openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
```

Розберемо ім'я на частини:

| Частина | Що означає |
|---|---|
| `openbao-` | префікс, який каталог додає до імені. Ви назвали застосунок `secrets`, об'єкти отримали імена `openbao-secrets…` |
| `secrets` | ім'я, яке ви задали в дашборді |
| `tenant-workshopXX` | ваш тенант. Підставте свій номер |
| `svc.cozy.local` | зона внутрішніх імен кластера керування |
| `8200` | порт API OpenBao |

Піднімаємо робочий Pod. Усередині нього буде утиліта `bao` — нею й будемо командувати
сховищем, а на ноутбук ставити її не доведеться. Підставте свій номер тенанта:

```bash
# run creates a single Pod from the given image — a disposable little machine inside the cluster.
#   --image          where to take the contents from: the official OpenBao image with the bao utility
#   --restart=Never  don't bring it up again once the command inside finishes
#   --env            the Pod's environment variable: any command inside it will see it
#   --command --     everything after the two dashes is the command the Pod will run
# sleep 86400 = "do nothing for a day": we need the Pod only as a workspace.
kubectl run bao-workbench \
  --image=openbao/openbao:2.5.1 \
  --restart=Never \
  --env=BAO_ADDR=http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200 \
  --command -- sleep 86400
# wait holds the terminal until the condition is met.
#   --for=condition=Ready  the Pod has started and is ready to accept commands
#   --timeout=120s         give up after two minutes and return an error
kubectl wait --for=condition=Ready pod/bao-workbench --timeout=120s
```

`BAO_ADDR` — змінна, з якої утиліта `bao` бере адресу сховища. Задана один
раз при створенні Pod, вона позбавляє нас `-address=…` у кожній команді.

Pod — одноразовий робочий майданчик, його не шкода: наприкінці лаби видалимо однією командою.

Перевіряємо, що з лабораторного кластера видно тенант:

```bash
# exec = run a command inside an already-running Pod; the command itself comes after --.
# bao status asks the store about its state: whether it's sealed, whether it's initialized.
# Here it doubles as a connectivity check: a reply arrived at all — so the tenant is visible.
kubectl exec bao-workbench -- bao status
```

**Що ви маєте побачити** — таблицю стану. Значення `Initialized false` і
`Sealed true` тут правильні: сховище працює, але ще не заведене і закрите:

```
Key                Value
---                -----
Seal Type          shamir
Initialized        false
Sealed             true
Total Shares       0
Threshold          0
Version            2.5.0
Storage Type       file
```

⚠️ **Команда поверне ненульовий код повернення — 2, і це не помилка.** У `bao status`
код повернення означає стан сховища, а не успіх команди: 0 — розпечатано,
2 — запечатано. Якщо ваша оболонка підсвічує ненульовий код або ви побачите приписку
`command terminated with exit code 2` — не лякайтеся, усе йде як треба.

⚠️ **Якщо команда падає з `connection refused`, `no such host` або `i/o timeout` —**
далі йти безглуздо, спочатку зв'язок. Часті причини за спаданням імовірності:
не підставили свій номер замість `workshopXX`; застосунок у дашборді ще не готовий;
одрук в імені. Ім'я збирається за правилом `openbao-<application name>`: застосунок ви
назвали `secrets`, отже в адресі стоїть `openbao-secrets`, а не `secrets`.

## Передбачувана невдача · Сховище відповідає відмовою

Зв'язок є, отже можна класти пароль. Спробуйте:

```bash
# bao kv put = place a record in the store.
#   secret/passes/db  the path where it will live
#   password=…        the record's contents: a "field name = value" pair
kubectl exec bao-workbench -- bao kv put secret/passes/db password=Propusk2026
```

**Що ви побачите** — замість підтвердження запису відмову:

```
Error making API request.
Code: 503. Errors:
* Vault is sealed
```

> **Зупиніться і подумайте, перш ніж читати далі.**
>
> Сервіс запущений, порт відповідає, а сховище працювати відмовляється. Чому запущена
> служба може свідомо не обслуговувати запити? І чому це, найпевніше,
> правильно?

<details>
<summary><b>Відповідь і урок, ширший за цю помилку</b></summary>

Подивіться на вивід `bao status` з попереднього кроку уважніше:

```
Sealed             true
Initialized        false
```

**Запечатане сховище — штатний стан щойно встановленого OpenBao.** Дані
на диску зашифровані майстер-ключем, а майстер-ключа в пам'яті процесу немає. Поки його туди
не покладуть, служба не може ні прочитати, ні записати нічого і чесно відповідає відмовою
на все.

Далі по лабі «розпечатати» означає рівно одне: пред'явити сховищу частки майстер-ключа,
щоб воно поклало ключ собі в пам'ять. До друку на папері слово стосунку не має.

Чому так зроблено. Якби майстер-ключ лежав поруч із зашифрованими даними, шифрування
не означало б нічого: той, хто вкрав диск, отримав би і те, і те. Тому ключ живе
**тільки в оперативній пам'яті** і потрапляє туди, коли його пред'явить людина або зовнішня
система.

Звідси наслідок, який варто прийняти одразу: **після кожного перезапуску Pod OpenBao
запечатується знову.** Перезавантажили вузол, оновили версію, кластер переселив Pod —
сховище знову не відповідає, поки його не розпечатають. У проді це вирішують
авторозпечатуванням через зовнішній модуль (хмарний KMS, апаратний HSM), і це окремий
проєкт. У лабі будемо розпечатувати руками і побачимо механіку наживо.

**Урок ширший за цю помилку.** **Керований сервіс зняв із вас установлення, оновлення,
реплікацію і бекапи, але не зняв операційних рішень.** Cozystack підняв вам процес OpenBao за
дві хвилини. Де зберігати unseal-ключі, хто має право розпечатувати, що робити о третій годині
ночі, коли вузол перезавантажився, — це так само ваші питання, і добре, що платформа
не вирішила їх за вас мовчки.

</details>

## Крок 5. Ініціалізуємо і розпечатуємо

📍 **Де:** на ноутбуці, у лабораторному кластері.

**Що зараз відбудеться:** OpenBao згенерує майстер-ключ, розріже його на частки і віддасть
їх нам разом із root-токеном. Другого разу цього не буде ніколи — ключі показують
рівно один раз.

```bash
# operator init runs once in the life of the store: it creates the master key and prints
# its shares together with a root token. No one will show these values again.
#   -key-shares=1     how many shares to cut the master key into
#   -key-threshold=1  how many shares must be presented to reassemble it
kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1
```

**Що ви маєте побачити:**

```
Unseal Key 1: 8kJq…=
Initial Root Token: s.7Yx…
```

⚠️ **Скопіюйте обидва значення у файл на ноутбуці просто зараз** — наприклад у
`~/openbao-lab.txt`, а не лише в буфер обміну. Повторно їх не покаже ніхто. Втратите
unseal-ключ — втратите всі секрети у сховищі, відновити їх неможливо by design.

Обидва знадобляться ще не раз, і ось коли:

- **unseal-ключ** — щоразу, коли Pod сховища перезапуститься. При перезапуску воно
  запечатується заново, і всі команди починають відповідати `Code: 503 ... * Vault is sealed`.
  Лікується повторним розпечатуванням тією ж командою, з того ж місця, де зупинилися;
- **root-токен** — наприкінці лаби, для скрипта перевірки. Між цими моментами пройде
  майже вся лаба, і термінал ви на той час, найпевніше, закриєте.

<details>
<summary><b>Що означають `-key-shares` і `-key-threshold`, і чому в проді не так</b></summary>

Майстер-ключ не видається цілком. Він розрізається на `key-shares` часток, і щоб зібрати
його назад, треба пред'явити `key-threshold` із них. Схема називається розділенням
секрета Шаміра.

Сенс у тому, щоб **розпечатування не могла зробити одна людина**. Класичне
production-налаштування — п'ять часток, поріг три: частки роздають п'ятьом власникам у різних
підрозділах, і щоб підняти сховище після перезавантаження, треба зібрати будь-яких трьох.
Один адміністратор, що звільнився, не забирає із собою доступ, один недобросовісний — не
отримує його наодинці.

Ми ставимо одну частку і поріг один, бо в лабі ви один і нам потрібна механіка, а не
процедура. **У проді так робити не можна**, і це не формальність: єдина частка
означає єдину точку, звідки витече все.

</details>

Розпечатуємо. Підставте свій unseal-ключ:

```bash
# unseal hands the store one share of the master key. Once the shares reach the threshold,
# the key ends up in the process's memory and the store starts serving requests.
kubectl exec bao-workbench -- bao operator unseal <your-unseal-key>
# We repeat status to see the changed state.
kubectl exec bao-workbench -- bao status
```

**Що ви маєте побачити** — `Sealed  false` і `Initialized  true`.

Тепер входимо root-токеном. Він запам'ятається всередині робочого Pod, і наступні команди
токен питати не будуть:

```bash
# login exchanges the entered token for an entry in a file inside the Pod — from then on the utility
# takes the token from there itself, and you won't have to type it into every command.
# -it gives the Pod a terminal: without it the utility has nowhere to print its prompt and nowhere to take input.
kubectl exec -it bao-workbench -- bao login
```

Утиліта спитає токен і **не покаже його під час вводу** — так і задумано. Вставте
Initial Root Token із виводу `init`.

⚠️ **Якщо `bao login` скаржиться, що не може записати файл токена**, передавайте токен
змінною оточення в кожній команді:
`kubectl exec bao-workbench -- env BAO_TOKEN='your-token' bao status`.
Спосіб робочий, але токен потрапляє в історію команд — у лабі терпимо, у проді ні.

## Крок 6. Вмикаємо рушій і кладемо пароль

📍 **Де:** на ноутбуці, у лабораторному кластері.

Свіжий OpenBao порожній: у ньому немає жодного місця, куди можна щось покласти. Рушії
секретів підключають явно.

```bash
# secrets enable turns on an engine — a part of the store that knows one kind of work.
#   -path=secret  which path to hang it on: from here on everything is written as secret/…
#   kv-v2         which engine exactly: "key-value" with version history
kubectl exec bao-workbench -- bao secrets enable -path=secret kv-v2
```

<details>
<summary><b>Що таке рушій секретів і чому їх кілька</b></summary>

OpenBao не одне сховище, а набір рушіїв, кожен із яких уміє свою роботу і
підключається на свій шлях:

| Рушій | Що робить |
|---|---|
| `kv-v2` | зберігає те, що ви в нього поклали, з історією версій. Звичайний «ключ-значення» |
| рушії баз даних | **самі** заводять у PostgreSQL або MongoDB тимчасового користувача на дві години і самі його видаляють |
| PKI | випускає сертифікати за запитом, замість річної заявки у відділ ІБ |
| transit | шифрує дані за запитом, не зберігаючи їх: ключ не залишає сховище |

`-path=secret` — на який шлях підключити. Далі всі звернення до цього рушія йдуть
через `secret/…`.

Ми беремо `kv-v2` — найпростіший випадок: у нас є готовий пароль, його треба покласти.
Куди цікавіші рушії баз даних: вони прибирають постійний пароль як явище, видаючи
застосунку тимчасову обліковку під кожен запуск. Це наступний рівень, і до нього треба
дорости; починати розумно звідси.

</details>

Кладемо пароль:

```bash
# kv put writes a whole new version: the listed fields become its contents.
# There can be any number of fields; here there are two — the password and the database username.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026 username=passes_app
```

**Що ви маєте побачити** — табличку з `version  1` і часом створення.

Перевіряємо, що читається:

```bash
# kv get reads the record and prints its fields as a table. We're still reading with the root token — that is,
# we're checking that the record landed, not that the application will have enough permissions.
kubectl exec bao-workbench -- bao kv get secret/passes/db
```

## Крок 7. Видаємо застосунку доступ — рівно на один рядок

📍 **Де:** на ноутбуці, у лабораторному кластері.

Root-токен застосунку давати не можна: з ним можна все, включно з читанням чужих секретів і
видаленням сховища. Застосунку потрібен доступ лише на читання одного шляху.

Пишемо політику:

```bash
# policy write saves a named list of permissions in the store.
#   passes-read  the policy's name; it's later granted to a token by this name
#   -            take the policy text from standard input rather than from a file
#   -i           in kubectl exec: forward that input into the Pod
# <<'HCL' … HCL is a way to pass multi-line text straight into the command, without a file.
kubectl exec -i bao-workbench -- bao policy write passes-read - <<'HCL'
path "secret/data/passes/db" {
  capabilities = ["read"]
}
path "secret/metadata/passes/db" {
  capabilities = ["read"]
}
HCL
```

<details>
<summary><b>Розбираємо політику</b></summary>

Політика — список шляхів і того, що з ними дозволено. Усе, що не дозволено явно,
заборонено; окремого «заборонити» писати не треба.

```hcl
path "secret/data/passes/db" {
  capabilities = ["read"]
}
```

`secret/data/passes/db` — шлях **в API**, а не у файловій системі. У рушія `kv-v2` він
влаштований так: `secret` — куди підключений рушій, `data` — службовий префікс самого
рушія, `passes/db` — те, що ви задавали в команді `kv put`.

⚠️ **Цей префікс `data` — джерело половини незрозумілих відмов.** У командному рядку
ви пишете `secret/passes/db`, а в політиці — `secret/data/passes/db`. Утиліта `bao kv`
підставляє `data` за вас, політика — ні.

`capabilities = ["read"]` — можна лише читати. Не писати, не видаляти, не перелічувати
сусідні шляхи.

Другий блок, `secret/metadata/passes/db`, — доступ до відомостей про версії: коли
записували, скільки версій, яка поточна. Теж лише читання.

`bao policy write passes-read -` — останній дефіс означає «читай вміст зі
стандартного вводу». Тому команда запускається з `kubectl exec -i`: прапорець `-i`
пробрасує ввід усередину Pod.

</details>

Випускаємо токен із цією політикою:

```bash
# token create issues a new token and binds a set of permissions to it.
#   -policy=passes-read  which permissions: the policy written above
#   -ttl=24h             lifetime; after a day the token stops working on its own
#   -field=token         print only the token value, without the table around it —
#                        that way it's easy to copy and pass along
kubectl exec bao-workbench -- \
  bao token create -policy=passes-read -ttl=24h -field=token
```

**Що ви маєте побачити** — один рядок із токеном.

Скопіюйте токен — зараз він знадобиться.

Строк життя тут не формальність. Пішов токен у лог, потрапив у бекап, витік із ноутбуком —
післязавтра він марний. Пароль у маніфесті такої властивості не має.

## Крок 8. Кладемо токен у кластер і прибираємо пароль із маніфеста

📍 **Де:** на ноутбуці, у лабораторному кластері.

Застосунку треба чимось довести OpenBao, що він — це він. Цим і буде токен.

```bash
# create secret generic creates a Secret object directly in the cluster, bypassing a file on disk.
#   passes-bao-token      the object's name; the application's description will reference the secret by it
#   --from-literal=name=…  set the value as a string from the command line
#                          (there's also --from-file, when the value is in a file)
kubectl create secret generic passes-bao-token \
  --from-literal=token='paste-the-token-from-the-previous-step'
```

**Зверніть увагу: команда, а не файл.** Токен створюється прямо в кластері і в Git не
потрапляє ніколи — там немає файлу, у який він міг би потрапити.

<details>
<summary><b>Секрет нульового рівня: чесно про те, чого ми не перемогли</b></summary>

Логічне заперечення: ми прибрали пароль від бази, але поклали в кластер токен. Чи не поміняли
ми шило на мило?

Не поміняли, і ось чим токен відрізняється від пароля:

| | Пароль у маніфесті | Токен у кластері |
|---|---|---|
| Лежить у Git | так, назавжди, у всій історії комітів | ні, його створили командою |
| Строк життя | вічний | доба, далі сам мертвий |
| Що дає | повний доступ до бази пропусків | читання одного рядка у сховищі |
| Відкликання | змінити пароль скрізь, де він прописаний | одна команда, миттєво |
| Видно, хто користувався | ні | так, в аудит-лозі |

Але повністю проблему це не закриває, і вдавати, що закриває, нечесно. **Завжди
залишається один секрет, яким застосунок доводить своє право на інші.** У нього
навіть є ім'я — секрет нульового рівня. Прибрати його неможливо: чимось відрекомендуватися треба.

Що з ним роблять дорослі системи:

- **Kubernetes-автентифікація.** OpenBao перевіряє службовий токен Pod у самому
  Kubernetes і видає свій в обмін. Тоді «секретом нульового рівня» стає
  ідентичність Pod, яку видає кластер, а не рядок, який поклала людина
- **Одноразові токени (response wrapping).** Оператор видає токен, який можна
  використати один раз. Якщо застосунок отримав відмову «вже використаний» — значить,
  токен перехопили, і це видно одразу

Обидва способи існують і працюють, але в цій лабі вони завели б нас далеко. Тримайте в
голові, що шлях є, і що мета — не «нуль секретів», а «один короткий, вузький і
відкликаний замість десятка вічних».

</details>

Тепер застосовуємо чистий маніфест. Спочатку підставте свій номер тенанта:

```bash
# sed edits text by the pattern s/what-to-replace/with-what/g; g = in every place on the line,
# not just the first. -i means "edit the file itself" rather than print the result
# to the screen. In place of workshop03 from the example, substitute your own number.

# macOS: the empty quotes after -i are mandatory — otherwise sed will take the next word
# as a backup-file extension and replace nothing
sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
# Linux
sed -i 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
```

<details>
<summary><b>Придивімося: що всередині secrets-demo.yaml</b></summary>

Почнемо з головного: **знайдіть у цьому файлі пароль.** Його там немає — ні відкритим
текстом, ні в base64, ні посиланням на об'єкт, у якому він лежав би.

```yaml
      volumes:
        - name: secrets
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
```

`emptyDir` — тимчасова тека, яка живе стільки ж, скільки Pod, і зникає разом із
ним. `medium: Memory` означає, що це не файл на диску, а область в оперативній пам'яті.
Пароль не потрапить ні на диск вузла, ні в знімок тому, ні в бекап.

```yaml
      initContainers:
        - name: fetch-secret
          image: openbao/openbao:2.5.1
```

Init-контейнер — контейнер, який відпрацьовує **до** основного і має успішно
завершитися. Якщо він упаде, основний не запуститься взагалі. Для отримання секрета це
саме та поведінка, яка потрібна: застосунок не повинен стартувати з порожнім паролем і
падати потім на першому запиті до бази.

```yaml
              bao kv get -field=password secret/passes/db \
                | tr -d '\n' > /secrets/db_password
              chmod 0400 /secrets/db_password
```

Забираємо одне поле і кладемо у файл. `tr -d '\n'` прибирає перехід рядка, якщо він раптом
з'явиться: пароль із зайвим символом на кінці не підійде базі, а шукати таке неприємно.
`chmod 0400` — читати може лише власник.

```yaml
          env:
            - name: BAO_ADDR
              value: http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: passes-bao-token
                  key: token
```

Адреса сховища і токен. Токен — за посиланням на об'єкт, який ви створили командою.
У файлі лише ім'я об'єкта, а ім'я — не секрет.

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        fsGroup: 1000
```

Усе працює не від root. `fsGroup` потрібен, щоб обидва контейнери — той, що пише файл, і
той, що його читає, — мали до теки доступ. Без цього init-контейнер напише файл,
який основний не зможе відкрити, і ви пів години будете думати, де помилилися.

```yaml
          volumeMounts:
            - name: secrets
              mountPath: /secrets
              readOnly: true
```

Основному контейнеру тека віддана лише на читання. Застосунок не може ні зіпсувати
пароль, ні підмінити його.

</details>

**Застосовуємо.** Deployment зміниться новою версією: init-контейнер сходить у сховище,
покладе пароль у пам'ять Pod і лише після цього запуститься саме застосунок.

```bash
kubectl apply -f secrets-demo.yaml
# We wait until the new version has fully replaced the old one. If the init container can't fetch
# the password, the wait won't finish — and that's exactly the behavior we want.
kubectl rollout status deploy/secrets-demo
```

## Крок 9. Перевіряємо, що застосунок отримав пароль зі сховища

📍 **Де:** на ноутбуці, у лабораторному кластері.

Спочатку подивимося, що сказав init-контейнер:

```bash
# -c selects a container inside the Pod. There are two here, and without -c kubectl can't guess which
# one you mean. fetch-secret is the one that ran before the application started.
kubectl logs deploy/secrets-demo -c fetch-secret
```

**Що ви маєте побачити:**

```
password fetched from OpenBao, not present in the manifest
```

Тепер сам сервіс:

```bash
# The main container: it reads the file the init container placed.
kubectl logs deploy/secrets-demo -c app --tail=2
```

Відбиток **змінився** — раніше був `sha256:a609df223d57`, тепер інший. Застосунок
працює з новим паролем, якого немає в жодному файлі репозиторію.

Приберемо наївний секрет, він більше не потрібен і лише заважає:

```bash
# delete removes the object from the cluster. The application no longer references it,
# so the deletion won't break anything.
kubectl delete secret passes-db
```

## Крок 10. Ротація: міняємо пароль, не торкаючись жодного файлу

📍 **Де:** на ноутбуці, у лабораторному кластері.

Повертаємося до першої вимоги аудитора: «поміняйте пароль». Раніше це означало
знайти всі місця, де він прописаний, поправити, закомітити, викотити і сподіватися, що
нічого не забули.

Тепер:

```bash
# The same kv put. The previous version of the record isn't erased — a second one appears alongside it.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026-autumn username=passes_app
# rollout restart recreates the application's Pods without changing a single line in its description.
# This is what it was all for: the new password is picked up on the next start.
kubectl rollout restart deploy/secrets-demo
kubectl rollout status deploy/secrets-demo
# The fingerprint in the log will show that the password changed, without showing the password itself.
kubectl logs deploy/secrets-demo -c app --tail=2
```

**Що ви маєте побачити** — відбиток знову змінився. Дві команди, нуль змінених
файлів, нуль комітів.

⚠️ **Застосунок підхоплює нове значення при перезапуску, а не миттєво.** Ми
забираємо секрет init-контейнером на старті — простий і надійний спосіб, але оновлення
вимагає рестарту. Якщо сервіс має підхоплювати секрет на льоту, застосовують
додатковий контейнер поруч, який перечитує значення за таймером і оновлює
файл. Це складніше, і починати варто не з цього.

Подивимося історію:

```bash
# kv metadata get shows not the values but information about the record's versions: how many there are,
# when each was created, and which is current now.
kubectl exec bao-workbench -- bao kv metadata get secret/passes/db
```

**Що ви маєте побачити** — обидві версії з часом створення. Старе значення не пропало:
якщо з'ясується, що новий пароль базі не підійшов, є куди повернутися.

Попереднє значення можна й прочитати цілком:

```bash
# -version=1 reads the first version written instead of the current one.
kubectl exec bao-workbench -- bao kv get -version=1 secret/passes/db
```

Ось це і є **ротація**: заміна секрета на новий за планом, а не за фактом витоку.
Регламент на кшталт «паролі службових обліковок міняються раз на квартал» із
нездійсненного стає рядком у розкладі.

## Крок 11. Аудит-лог: хто і що запитував

📍 **Де:** на ноутбуці, у лабораторному кластері.

Друга вимога аудитора — «покажіть, хто читав пароль». Вмикаємо журнал:

```bash
# audit enable turns on an audit device.
#   file              the device type: write records as text
#   file_path=stdout  instead of a file on disk — to the Pod's standard output, from where
#                     the platform collects the logs
kubectl exec bao-workbench -- bao audit enable file file_path=stdout
# audit list lists the enabled devices — a check that the command above went through.
kubectl exec bao-workbench -- bao audit list
```

**Що ви маєте побачити** — таблицю з одним увімкненим пристроєм типу `file`.

<details>
<summary><b>Що потрапляє в аудит-лог і чим він відрізняється від звичайного лога</b></summary>

З цього моменту OpenBao пише запис **на кожен запит до API**: хто спитав (який
токен, яка політика), що саме, коли, з якої адреси і що відповіли. Записи дві на
запит — сам запит і відповідь на нього.

Три відмінності від звичного лога застосунку:

**Пишуться і відмови.** Спроба прочитати чужий шлях залишає слід рівно так само, як
успішне читання. Саме відмови цікаві службі ІБ: успішні читання — це робота,
а серія відмов — це розвідка.

**Значення секретів не потрапляють у журнал.** Шляхи, імена і токени хешуються, самі
секрети не пишуться. Журнал можна віддати назовні, не віддавши разом із ним вміст.

**Якщо журнал писати нікуди, OpenBao перестає працювати.** Це свідоме рішення:
сховище, яке обслуговує запити, не маючи змоги їх записати, гірше за неробоче.
Звідси практичний наслідок — не вмикайте єдиний аудит-пристрій у файл на диску, який
може заповнитися.

⚠️ **Прочитати цей журнал у лабі вам не дадуть, і це треба сказати прямо.** Ми направили
його в стандартний вивід Pod OpenBao, а логи Pod у тенанті ваша роль читати не може —
тенант віддає вам керування сервісами, але не доступ до їхніх нутрощів. У справжній
інсталяції журнал забирає збирач логів платформи і кладе туди, де його дивиться
служба ІБ, а не ви через `kubectl`.

Що при цьому все-таки видно вам самим — історія версій із попереднього кроку
(`bao kv metadata get`): хто і коли **писав**, з точністю до секунди. Це не повний
аудит, але на питання «коли востаннє міняли пароль» відповідає.

</details>

## Перевірка

📍 **Де:** на ноутбуці, у тому самому вікні термінала, де ви працювали з `kubectl`.

```bash
cd labs/08-openbao
# The script reads these three environment variables, so you must set them before running it
# and in the same terminal window.
export KUBECONFIG=~/lab.kubeconfig     # which cluster to check
export COZY_TENANT=workshop03          # your tenant number
export BAO_TOKEN='your-root-token'     # the one bao operator init printed
./check.sh
```

⚠️ **На Windows скрипт запускається з WSL**, а не з PowerShell — як його поставити,
написано на початку лаби 0. Без WSL лабу можна пройти, але звіту-артефакту не буде.

Скрипт перевірить не факт застосування маніфестів, а роботу по суті: сховище
розпечатане, секрет читається за токеном, версій більше однієї (значить, ротація була),
аудит увімкнений, а в маніфесті застосунку немає жодного пароля відкритим текстом.

Поруч з'явиться файл звіту. **У звіт не потрапляє жоден секрет** — лише версії,
імена і відбитки.

## Прибирання

```bash
# delete -f = "remove from the cluster everything described in this file".
kubectl delete -f secrets-demo.yaml
# What was created by a command rather than a file is deleted by name.
kubectl delete secret passes-bao-token
kubectl delete pod bao-workbench
```

Сам OpenBao видаляється в дашборді: застосунок `secrets` → видалити.

Чому це дешево. Сховище секретів у класичній інсталяції — проєкт: сервер,
кластеризація, сертифікати, регламент розпечатування, інтеграція з моніторингом. Тут
ви отримали його за дві хвилини і віддали назад за десять секунд, а зайняте ним місце
звільнилося.

⚠️ **З видаленням зникнуть усі секрети всередині.** Unseal-ключ і root-токен від видаленого
сховища перетворюються на марні рядки. Якщо ви клали туди щось справжнє —
спочатку заберіть.

## Що ми тепер уміємо

- Пояснювати колезі, чому Secret у Kubernetes — це не «зашифровано», і підкріплювати
  це однією командою
- Замовляти OpenBao, ініціалізувати його і розпечатувати, розуміючи, що відбувається
- Класти секрет у сховище і видавати застосунку доступ рівно на один шлях коротким
  токеном
- Міняти пароль, не торкаючись жодного файлу в репозиторії, і бачити історію версій
- Виразно відповідати на питання «хто читав цей пароль» — і розуміти, звідки береться відповідь

## А в vSphere це було б

Прямого аналога немає, і це чесна відповідь. Паролі службових обліковок у класичній
інфраструктурі живуть у трьох місцях одночасно: у файлі налаштувань на віртуалці, у
парольному менеджері відділу і в голові того, хто налаштовував. Ротація означає похід по
всіх трьох, тому її не роблять. Питання «хто читав» не має відповіді, бо читання
файлу ніхто не записує.

Є vSphere Credential Store, є Windows Credential Manager, є корпоративні
парольні менеджери — усі вони вирішують задачу «людині зручно зберігати паролі». Задачу
«застосунок отримує пароль сам, за політикою, на час і під запис» вони не вирішують.

**Де vSphere зручніший, чесно.** Ні в чому з переліченого — але за зручність
доводиться платити, і ось чим.

Пароль у файлі на віртуалці **завжди доступний**: перезавантажився хост, піднялася
машина, служба прочитала файл і запрацювала. Нікого не треба будити о третій годині ночі.
OpenBao після перезапуску запечатаний, і поки його не розпечатають, застосунки не стартують.
Це додає у вашу інфраструктуру нову точку відмови і новий регламент — із черговими, із
носіями ключів, з описаною процедурою. Авторозпечатування через зовнішній KMS цю проблему
знімає, але додає залежність від того самого зовнішнього KMS.

І друге. Файл на диску розуміє будь-який адміністратор з першого погляду. Шляхи, політики,
токени, TTL, префікс `data` в середині шляху — це окрема модель, яку команді
доведеться вивчити, і перші пару місяців вона буде джерелом незрозумілих відмов.

Виграш усе одно переважує, але він не безкоштовний, і планувати перехід треба з цією
ціною в умі.
