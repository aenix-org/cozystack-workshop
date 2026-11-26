# Лаба 6 · Свій приватний реєстр образів

| | |
|---|---|
| **Час** | 45 хвилин, з них 10 — очікування |
| **Що доводить** | Реєстр образів заводиться за десять хвилин, і кластер уміє тягнути тільки з нього |
| **Що знадобиться** | Кластер із лаби 0, `kubectl`, `docker` (або `podman`) на ноутбуці, доступ до дашборду |

## Навіщо це

Сервіс «Перепустка» дійшов до інформаційної безпеки, і звідти прийшов лист.

> Образи контейнерів тягнуться з публічних реєстрів в інтернеті. Це неприйнятно:
> склад образу ніким не перевірений, вміст може змінитися під тим самим іменем,
> а за недоступності зовнішнього ресурсу продуктивний сервіс не запуститься. Усі образи
> мають зберігатися у внутрішньому реєстрі організації.

Заперечити нічого — кожен пункт по суті. Публічний образ із тегом `latest` сьогодні й
завтра може бути різним. Автор образу може його видалити. Зовнішній реєстр може
обмежити вам швидкість завантаження в найбільш невідповідний момент — і це не гіпотеза, так
роблять усі великі публічні реєстри.

Отже, потрібен свій реєстр. Зазвичай це окремий проєкт: заявка на віртуалку, встановлення,
сертифікати, сховище, резервні копії, чийсь квартал. Сьогодні це позиція в каталозі.

І раз реєстр свій і закритий — кластеру доведеться видати в нього доступ. На цьому
спотикаються всі, і ми спіткнемося теж, спеціально.

## Словничок

| Термін | Що це | Схоже на… але |
|---|---|---|
| **Образ (image)** | Зліпок застосунку з усім, що потрібно для запуску | **Шаблон VM**, але незмінний: усередину не зайти й не виправити, збирають новий |
| **Шар (layer)** | Частина образу. Образ зібраний із шарів, шари перевикористовуються | однакові шари різних образів зберігаються в реєстрі один раз |
| **Тег (tag)** | Мітка версії образу: `passes-api:v1` | **Ім'я версії шаблону**, але тег можна перепризначити на інший образ, і це головне джерело бід |
| **Реєстр (registry)** | Сховище образів з доступом по HTTP | **Content Library**, але віддає шари по мережі при кожному запуску, а не копіює шаблон цілком |
| **Harbor** | Реєстр з інтерфейсом, проєктами, правами і сканером вразливостей | **Content Library + права + звіти**, але вміє перевіряти вміст образів і підписувати їх |
| **Проєкт у Harbor** | Область усередині реєстру зі своїми правами | **Тека в Content Library**, але буває публічним або закритим, і від цього залежить, чи потрібні реквізити |
| **`imagePullSecret`** | Секрет із логіном і паролем до реєстру, який читає вузол | **Обліковий запис для підключення Content Library**, але потрібен **вузлу**, а не вам; ваш `docker login` кластеру не допомагає |
| **Dockerfile** | Інструкція, як зібрати образ | **Інструкція з підготовки шаблону**, але виконується цілком і заново при кожній збірці |
| **Downward API** | Спосіб надати Pod'у відомості про нього самого через змінні середовища | **Гостьові змінні з VMware Tools**, але значення підставляє кластер при запуску, застосунок їх не запитує |

## Два kubeconfig'и: не переплутайте

Далі в лабі два різних кластери, і це варто розвести до першої команди.

| kubeconfig | Що це | Що в ньому робимо |
|---|---|---|
| `~/.kube/workshop` | Кластер керування Cozystack, ваш тенант | дивимося на керовані сервіси: Harbor, бази, черги |
| `~/lab.kubeconfig` | **Ваш** кластер `lab` із лаби 0 | розгортаємо застосунок |

Обидва беруться в дашборді. Тенантний лежить у секреті `kubeconfig-tenant-workshopXX`
(вкладка Secrets), кластерний — у розділі доступів вашого кластера `lab`.

⚠️ **Найчастіша причина «у мене нічого не працює» в цій лабі — команда пішла не в
той кластер.** Перед кожним блоком команд написано, куди він адресований. Якщо сумніваєтеся:

```bash
# echo prints the value of the variable: which access file kubectl is using right now.
# Empty means kubectl will use the default file ~/.kube/config, not the one you think.
echo $KUBECONFIG

# get nodes = "show the cluster's nodes". Here it's a litmus test:
# the answer tells you which of the two clusters the command went to.
kubectl get nodes
```

У кластері `lab` буде один вузол з іменем виду `kubernetes-lab-md0-...`. У кластері
керування ця команда, найімовірніше, поверне відмову — у тенанта немає прав дивитися вузли.

## Що лежить у теці лаби

Усі файли вже у вас — ви забрали їх разом із репозиторієм. Створювати й друкувати заново
нічого не потрібно: там, де нижче написано `kubectl apply -f name.yaml`, файл береться звідси.

```bash
# every command in this lab is run from the lab folder — change into it
cd labs/06-harbor
```

| Файл | Що це | Коли знадобиться |
|---|---|---|
| `app/` | Вихідники сервісу «Перепустка» на Go і `Dockerfile` — з них збираєте образ | збираєте локально, `docker build` |
| `passes-broken.yaml` | **Навмисно неповний** файл: без реквізитів доступу до реєстру | застосовуєте, щоб побачити відмову на власні очі |
| `passes.yaml` | Той самий файл, але з доступом до реєстру | застосовуєте після того, як розібралися |
| `check.sh` | Перевірка, що образ приїхав із вашого Harbor, а не з інтернету | запускаєте наприкінці лаби |

## Крок 1. Створюємо Harbor

📍 **Де:** у браузері, у дашборді Cozystack. Реєстр — спільний ресурс тенанта, а не вашого
навчального кластера, тому заводиться він там само, де заводився сам кластер.

Тенант → **Create application** → `Harbor`.

| Поле | Значення | Чому так |
|---|---|---|
| Name | `harbor` | потрапить в адресу реєстру; яка вийде — побачите після створення |
| Host | залишити порожнім | тоді адреса збереться сама з імені й домену тенанта |
| Storage class | `replicated` | дані ляжуть у трьох копіях на різні вузли |
| Trivy → enabled | **вимкнути** | сканер вразливостей завантажує базу на кілька гігабайтів; на навчальному тестовому середовищі це зайві двадцять хвилин очікування |
| Database → replicas | `1` | відмовостійкість бази реєстру сьогодні не перевіряємо |
| Database → size | `5Gi` | |
| Redis → replicas | `1` | |
| Redis → size | `1Gi` | |
| Core / Registry preset | залишити запропонований | |

⚠️ **Redis у цій формі — внутрішній кеш самого Harbor, до наступної лаби він відношення не
має.** У лабі про кешування ви заведете окремий Redis для свого застосунку. Ім'я
збігається, ролі різні.

Натискаємо створити і чекаємо. Harbor піднімається п'ять-десять хвилин: це не один застосунок,
а кілька служб плюс база даних плюс об'єктне сховище під самі шари образів.

⚠️ **Якщо Harbor висить у стані «не готовий» довше п'ятнадцяти хвилин** — подивіться, що
відбувається: `kubectl -n tenant-workshopXX get pods | grep harbor`. Найчастіше це черга
встановлення, спільна на всю платформу: ваш застосунок стоїть у ній за чужими і чекає.

Шари образів Harbor зберігає в S3-сумісному сховищі, і бакет під них створюється сам —
своє сховище в тенанті для цього вмикати не потрібно, підійде батьківське. Якщо Pod'и
все ж не з'являються більше півгодини, напишіть у чат воркшопу з виводом цієї команди.

## Крок 2. Забираємо реквізити і заходимо в реєстр

📍 **Де:** у дашборді, потім у терміналі на ноутбуці.

Відкрийте створений застосунок `harbor` і знайдіть вкладку із секретами. Там лежить секрет
з реквізитами реєстру, а в ньому три потрібних ключі:

| Ключ | Що в ньому |
|---|---|
| `url` | адреса вашого реєстру, виду `https://harbor-....<testbed domain>` |
| `admin-password` | пароль адміністратора |
| `redis-password` | внутрішній пароль Harbor, вам не потрібен |

Логін — `admin`.

⚠️ **Не вгадуйте адресу реєстру, візьміть її з ключа `url`.** Платформа додає до
імені застосунку префікс із типом сервісу, тому адреса може виявитися не тією, що ви
очікували за іменем. Та сама адреса видна у списку ingress-ів застосунку.

Той самий пароль доступний і командою. Читати **всі** секрети поспіль тенанту не дозволено —
перевірте самі, `kubectl auth can-i get secrets` відповість `no`. Але на кожен створений вами
застосунок платформа заводить окреме правило, що дозволяє саме його реквізити:

```bash
# get secret = "show the Secret object". The secret's name is assembled from the prefix
# for the application type and its name: harbor- + harbor.
#   -n tenant-workshopXX  which namespace to look in — your tenant
#   -o jsonpath='...'     pull a single field out of the object rather than printing the whole thing
#   base64 -d             decode: values inside secrets are stored in base64
#   ; echo                add a newline, otherwise the password runs into the prompt
kubectl -n tenant-workshopXX get secret harbor-harbor-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Дашборд зручніший тим, що не треба возитися з base64. Команда зручніша тим, що її можна
вставити у скрипт.

Відкрийте адресу в браузері і увійдіть. Ви побачите інтерфейс Harbor з одним проєктом
`library`.

Тепер те саме з термінала. `docker login` запитує ім'я і пароль і зберігає
реквізити на вашому ноутбуці, у файлі `~/.docker/config.json`. Після цього `docker push`
і `docker pull` ходять у цей реєстр, нічого не запитуючи.

```bash
# login = "remember the credentials for this registry".
# The argument is the registry address from the url key; harbor-harbor.workshop03.example.org here is an example.
# The command will ask for a username (admin) and a password; the password isn't shown as you type.
docker login harbor-harbor.workshop03.example.org
```

Далі за текстом `harbor-harbor.workshop03.example.org` — це **ваша** адреса, підставляйте свою.

**Що ви маєте побачити:**

```
Login Succeeded
```

⚠️ **Цей `docker login` навчив заходити в реєстр ваш ноутбук — і тільки його.** Кластеру
він не допоміг нічим. Запам'ятайте це, воно знадобиться трохи далі по лабі.

## Крок 3. Заводимо закритий проєкт

📍 **Де:** у браузері, у Harbor.

**Projects** → **New Project**.

| Поле | Значення | Чому так |
|---|---|---|
| Project Name | `passes` | по одному проєкту на сервіс — так простіше роздавати права |
| Access Level | **не позначати Public** | ІБ просила закритий реєстр, а не «свій, але відкритий усьому інтернету» |
| Storage quota | `-1` (без обмеження) | на тестовому середовищі квота тільки завадить |

Проєкт `library`, який був там від самого початку, — публічний. З нього образи тягнуться
без жодних реквізитів. Ми ним користуватися не будемо саме тому: він не покаже ту
саму помилку з доступом, заради якої лабу зроблено.

## Крок 4. Збираємо образ

📍 **Де:** на ноутбуці.

У теці цієї лаби лежить `app/` — вихідник сервісу «Перепустка» та інструкція зі збірки.
Перш ніж збирати, розберемо, що там.

<details>
<summary><b>Придивімося ближче: що всередині застосунку</b></summary>

Файл `app/main.go`, близько сімдесяти рядків на Go. Він робить рівно дві речі.

**Відповідає на `/healthz` словом `ok`.** Це адреса для перевірки готовності: кластер стукає
сюди й не пускає трафік на копію, поки не отримає відповідь.

**Відповідає на `/` невеликим JSON**, у якому повідомляє про себе:

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

Як застосунок знає своє ім'я, вузол і namespace? Він їх **не з'ясовує**.
Їх кладе кластер при запуску, у змінні середовища:

```go
Pod:  env("POD_NAME", "unknown"),
Node: env("NODE_NAME", "unknown"),
```

А в маніфесті написано, що туди покласти:

```yaml
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
```

Це називається downward API — «відомості, спущені згори». Найближчий аналог у vSphere —
гостьові змінні, які VMware Tools віддає всередину машини. Різниця в тому, що тут
застосунок нічого не запитує й нікуди не ходить: значення вже лежать у середовищі на
момент, коли процес стартував. Ні клієнта до API кластера, ні прав на цей API не
потрібно.

**Зовнішніх бібліотек у застосунку немає жодної, тільки стандартна бібліотека Go.** Це не
кокетство: збірка із залежностями пішла б в інтернет за пакетами, а вся лаба почалася
з того, що ІБ ходити в інтернет заборонила.

Файл `app/Dockerfile` — інструкція зі збірки. У ній два етапи:

```dockerfile
FROM golang:1.23-alpine AS build
...
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

FROM alpine:3.21
COPY --from=build /out/passes-api /usr/local/bin/passes-api
```

Перший етап — збірковий. Туди потрібен весь компілятор Go, це приблизно 350 МБ. Другий
етап — те, що реально поїде в кластер: із першого етапу переноситься **тільки готовий
бінарник**, усе інше викидається.

Підсумок — образ близько десяти мегабайтів замість трьохсот п'ятдесяти. Річ не тільки в розмірі:
всередині немає ні компілятора, ні вихідників, ні пакетного менеджера. Тому, хто в контейнер
все-таки потрапив, нічим скористатися.

Порівняйте з тим, як це влаштовано у шаблонів віртуальних машин. Шаблон несе в собі всю
операційну систему цілком, разом із компілятором, якщо він там колись опинився.
Зменшити його заднім числом майже неможливо.

Останні рядки:

```dockerfile
RUN adduser -D -u 10001 app
USER 10001
```

Застосунок працює не від root. У правильно налаштованому кластері Pod від root не пустять,
і це не наша прискіпливість, а вимога, з якою ви зіткнетеся в будь-якому сучасному
кластері.

</details>

Збирає образ команда `docker build`: вона читає `Dockerfile`, виконує описані там
кроки й кладе результат у сховище образів на вашому ноутбуці. Ім'я, під яким результат
там ляже, задається прапорцем `-t` і складається з трьох частин:

| Частина | Що означає |
|---|---|
| `harbor-harbor.workshop03.example.org` | адреса реєстру — куди підуть за образом |
| `passes/passes-api` | проєкт та ім'я всередині реєстру |
| `v1` | тег версії |

Адреса реєстру — частина імені образу. Саме тому переїзд на свій реєстр змінює всі
маніфести: ім'я образу стає іншим.

Збираємо. Замініть адресу на свою:

```bash
cd labs/06-harbor

# build = "build the image from the Dockerfile".
#   --platform linux/amd64  which processor to build for; the cluster nodes are on x86,
#                           and the laptop may be on ARM — then without the flag you get the wrong thing
#   -t <address>/<project>/<name>:<tag>  what to name the result. The registry address at the start of the name
#                           is where docker push will later send it
#   app/                    the last argument — the folder with the Dockerfile and sources;
#                           its entire contents are handed to the builder
docker build --platform linux/amd64 -t harbor-harbor.workshop03.example.org/passes/passes-api:v1 app/
```

⚠️ **`--platform linux/amd64` — не прикраса.** Якщо у вас Mac на Apple Silicon (M1–M4)
або ноутбук на ARM, без цього прапорця збереться образ під ARM. Він збереться без помилок,
запушиться без помилок, а в кластері — вузли там на звичайних x86 — Pod встане в
`CrashLoopBackOff`, і в логах буде `exec format error`. Діагностується це довго,
тому що ніщо навколо не натякає, що річ в архітектурі процесора.

**Що ви маєте побачити** — рядки про кроки збірки і в кінці:

```
Successfully tagged harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

## Крок 5. Відправляємо образ у свій реєстр

📍 **Де:** на ноутбуці.

Зібраний образ поки лежить тільки у вас на диску. `docker push` відправляє його в реєстр
шар за шаром; шари, які в реєстрі вже є, повторно не передаються.

```bash
# push = "send the image to the registry". Where to send it, docker takes from the image name:
# the first part of the name is the registry address, and there it goes, with the credentials from docker login.
docker push harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

**Що ви маєте побачити** — як від'їжджають шари, і в кінці рядок із довгим хешем `digest`.

Загляньте в Harbor у браузері: **Projects** → `passes` → там з'явився репозиторій
`passes/passes-api`, а в ньому тег `v1`. Видно розмір, дату і той самий `digest`.

Ось цей `digest` — точний вміст образу. Тег `v1` можна завтра перепризначити на
інший образ, і ніхто не помітить; `digest` підробити не можна. Звідси правило, яке
рано чи пізно вивчає кожен: **у продуктив котять по digest, а не по тегу.**

## Крок 6. Розгортаємо в кластер

📍 **Де:** на ноутбуці, кластер `lab`.

```bash
# KUBECONFIG tells kubectl which access file to use. We switch to your `lab` cluster:
# from here on all kubectl commands go to it.
# It stays in effect until the terminal window is closed.
export KUBECONFIG=~/lab.kubeconfig
```

У теці лаби лежить `passes-broken.yaml`. У ньому замість адреси реєстру стоїть заглушка
`HARBOR-HOST` — її треба замінити на вашу адресу. Робить це `sed`: він редагує файл на місці,
нічого не запитуючи й не показуючи. Візьміть рядок для своєї системи:

```bash
# sed -i = "edit the file in place"
#   's|what|with what|g'  replace all occurrences; the separator | is used instead of / because
#                     the address has slashes and they would have to be escaped
#   The sed in macOS requires a mandatory argument after -i; the empty quotes
#   mean "make no backup copy". On Linux there must be no such argument.

# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
```

Застосовуємо:

```bash
# apply = "bring the cluster to what's described in the file"
kubectl apply -f passes-broken.yaml

# get pods = "show the Pods".
#   -l app=passes-api  only the ones with this label, not everything
#   -w                 don't exit, print changes as they appear;
#                      stop watching — Ctrl+C
kubectl get pods -l app=passes-api -w
```

**Що ви побачите** — і це не те, чого ви чекали:

```
NAME                          READY   STATUS             RESTARTS   AGE
passes-api-6c9d4f7b8-2xk4n    0/1     ErrImagePull       0          8s
passes-api-6c9d4f7b8-2xk4n    0/1     ImagePullBackOff   0          22s
```

Перервіть спостереження по `Ctrl+C` і подивіться, що каже кластер:

```bash
# describe = "tell me about the object in detail". At the very end of the output comes the event log:
# what the cluster tried to do with the Pod and how it ended.
# tail -12 keeps the last twelve lines — the events are right there.
kubectl describe pod -l app=passes-api | tail -12
```

```
  Warning  Failed   kubelet  Failed to pull image
    "harbor-harbor.workshop03.example.org/passes/passes-api:v1":
    failed to resolve reference: unexpected status from HEAD request: 401 Unauthorized
```

> **Зупиніться і подумайте, перш ніж читати далі.**
>
> Ви щойно успішно зайшли в реєстр командою `docker login` і успішно відправили туди
> образ. Реєстр вас знає. Чому кластер отримує відмову?

<details>
<summary><b>Відповідь і урок, ширший за цю помилку</b></summary>

**Образ завантажуєте не ви.** Його завантажує `kubelet` — служба на вузлі кластера. Це інша
машина, інший процес та інший користувач.

Ваш `docker login` записав реквізити у файл `~/.docker/config.json` на **вашому ноутбуці**.
Вузол кластера про цей файл не знає й знати не може: між ним і вашим ноутбуком немає
взагалі нічого спільного, крім того, що ви відправляєте туди команди.

Поверніться до попередження після `docker login` трохи раніше по лабі. Там було сказано
рівно це, але поки не було видно наслідків.

**Як правильно.** Реквізити потрібно покласти в сам кластер — в об'єкт типу `Secret`
спеціального виду, — а потім у маніфесті застосунку вказати, яким секретом
користуватися при завантаженні. Такий секрет називається `imagePullSecret`.

**Чому кластеру потрібні окремі реквізити, а не ваші.** Три причини, і всі три
практичні.

Перша: вас може не бути. Вузол перезапуститься о третій годині ночі й піде завантажувати образ
заново. Якби він ходив під вашим обліковим записом, усе трималося б на тому, що ви працюєте
в цій компанії і ваш пароль не сплив.

Друга: права різні. Вам потрібне право **писати** в реєстр, щоб відправляти туди збірки.
Кластеру потрібно тільки **читати**. Давати кластеру право стирати образи з реєстру — погана
ідея, а з вашим обліковим записом ви дали б саме його.

Третя: сліди різні. Коли в журналі реєстру видно, що образ завантажив `robot$passes-puller`,
а не `admin`, розбір інциденту стає можливим.

**Чому не налаштувати вузол напряму.** Можна покласти реквізити прямо на вузол, у конфіг
середовища виконання контейнерів, — тоді `imagePullSecret` не потрібен. Так іноді роблять.
Але вузли в кластері одноразові: їх перестворюють при оновленні, додають при зростанні
навантаження, вбивають при збої. Налаштування, зроблене руками на вузлі, живе до першої заміни
вузла. Секрет у кластері переживає будь-яку заміну.

**Урок ширший за цю помилку.** `ImagePullBackOff` — це майже завжди одне з трьох: друкарська помилка в
імені образу, немає реквізитів, або образ є, але не під ту архітектуру процесора.
Дивіться не на статус Pod'а, а на `kubectl describe pod` — там написана справжня причина.

</details>

## Крок 7. Видаємо кластеру доступ до реєстру

📍 **Де:** на ноутбуці, кластер `lab`.

Створюємо секрет із реквізитами реєстру. Окремий різновид команди `create secret`
робить секрет такого виду, який `kubelet` уміє читати сам при завантаженні образів:

```bash
# create secret docker-registry = "create a secret with registry credentials"
#   harbor             the secret's name inside the cluster; the application manifest will refer to it
#   --docker-server    which registry these credentials are for — the same address as in the image name
#   --docker-username  who's logging in
#   --docker-password  the password; single quotes are needed if it has a $, ! or space
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password='YOUR-PASSWORD'
```

⚠️ **Пароль у командному рядку залишається в історії оболонки.** На тестовому середовищі це неважливо,
у робочому середовищі — важливо. Спосіб без історії:

```bash
# read puts what's typed at the keyboard into the HARBOR_PASS variable:
#   -s  don't show what's typed on the screen
#   -r  don't treat a backslash as a special character
# Nothing will appear on the screen after this line: paste the password and press Enter.
read -rs HARBOR_PASS

# From here the password is substituted from the variable, so only the variable name
# goes into the shell history. The double quotes are mandatory: without them spaces would break the value.
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password="$HARBOR_PASS"

# unset erases the variable so the password doesn't reach the next commands in this window
unset HARBOR_PASS
```

<details>
<summary><b>Що всередині цього секрета і чому в нього окремий тип</b></summary>

Запитаємо в кластера, якого виду секрет вийшов:

```bash
#   -o jsonpath='{.type}'  print a single field of the object — the secret's type
#   {"\n"}                 add a newline, otherwise the output runs into the prompt
kubectl get secret harbor -o jsonpath='{.type}{"\n"}'
```

```
kubernetes.io/dockerconfigjson
```

У секрета є **тип**, і він не декоративний. Звичайний секрет — це набір пар
«ключ-значення», і що з ними робити, вирішує застосунок. Секрет типу
`kubernetes.io/dockerconfigjson` розуміє сам `kubelet`: він знає, що всередині лежить
файл того самого формату, що й `~/.docker/config.json`, і вміє ним користуватися при
завантаженні образів.

Подивитися вміст (пароль там у base64 — це **не шифрування**, а спосіб
записати бінарні дані текстом, розкодувати може будь-хто):

```bash
# .data.\.dockerconfigjson — the key inside the secret. The key name itself starts with a dot,
# so it's escaped: otherwise jsonpath would take it for a path separator.
# base64 -d decodes the value back into text — you'll see the same format
# as in the file ~/.docker/config.json on your laptop.
kubectl get secret harbor -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Звідси важливе: **секрет у Kubernetes за замовчуванням не зашифрований**, він лише відділений
правами доступу. Той, хто може читати секрети в namespace, бачить паролі. Як
із цим бути по-людськи — окрема лаба про сховище секретів.

**Як це роблять у бою.** Не обліковим записом `admin`. У Harbor є роботи: **Projects** →
`passes` → **Robot Accounts** → створити робота з правом тільки `pull`. Реквізити робота
кладуть у `imagePullSecret`, і тоді витік секрета з кластера означає, що хтось може
завантажити ваші образи, — неприємно, але не смертельно. Витік `admin` означає, що хтось
може їх підмінити.

Ми беремо `admin`, щоб не розтягувати лабу. Знайте, що це спрощення.

</details>

Тепер застосовуємо правильний маніфест. Спочатку та сама підстановка адреси, що й раніше,
тільки в іншому файлі; потім прибираємо зламаний застосунок і ставимо робочий:

```bash
# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml

# delete -f = remove from the cluster exactly the objects described in the file
kubectl delete -f passes-broken.yaml
kubectl apply -f passes.yaml

# rollout status waits until the new replicas become ready, then finishes on its own.
# If it doesn't get there, it returns an error, which is why such a line is handy in scripts.
kubectl rollout status deployment/passes-api
```

**Що ви маєте побачити:**

```
deployment "passes-api" successfully rolled out
```

Відмінність робочого маніфеста від зламаного — рівно два рядки:

```yaml
      imagePullSecrets:
        - name: harbor
```

## Крок 8. Дивимося, що вийшло

📍 **Де:** на ноутбуці, кластер `lab`.

Назовні застосунок не виставлено, а подивитися на нього треба. `port-forward` риє тунель
з ноутбука всередину кластера: поки команда працює, звернення на `localhost:8080` йде
на сервіс `passes-api`. Найближчий аналог — тимчасовий проброс порту на NAT-шлюзі, тільки
без правки мережі.

```bash
# port-forward svc/passes-api = a tunnel to the service, not to a specific Pod
#   8080:80 — the left number is the port on your laptop, the right one the service port in the cluster
# Don't close the window: the tunnel lives as long as the command runs.
kubectl port-forward svc/passes-api 8080:80
```

У іншому вікні термінала:

```bash
# curl — "go to the address and show the answer".
#   -s     don't show the progress indicator
#   ; echo add a newline: the answer comes as a single line, and without it
#          it runs into the shell prompt
curl -s http://localhost:8080/; echo
```

**Що ви маєте побачити** — JSON, у якому застосунок повідомляє, яка копія відповіла,
на якому вузлі вона працює і з якого реєстру приїхала:

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

Поле `pod` у відповіді — ім'я копії, яка відповіла. Звірте його зі списком копій:

```bash
# a new terminal window knows nothing about the KUBECONFIG variable — set it here too,
# otherwise kubectl will go to the wrong cluster
export KUBECONFIG=~/lab.kubeconfig

# the same selection by label: the list should contain the name you saw in the answer
kubectl get pods -l app=passes-api
```

Повторіть запит кілька разів — ім'я залишиться **тим самим**, і це не поломка.
`port-forward` вибирає одну копію в момент запуску і тримає тунель саме до неї до
`Ctrl+C`; балансування в цьому шляху немає взагалі. Воно є у `Service`, але побачити його можна
тільки зсередини кластера — ззовні ви розмовляєте з конкретним Pod'ом.

Перевірити балансування по-справжньому можна так — вісім запитів із тимчасового Pod'а,
який живе всередині кластера:

```bash
# run brings up a one-off Pod, --rm cleans it up afterwards.
# Everything after -- runs inside the Pod: eight times we hit the service by its internal name
# and print the line with the name of the replica that answered.
kubectl run probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
  -- sh -c 'for i in $(seq 1 8); do curl -s http://passes-api/ | grep -o "passes-api-[a-z0-9-]*"; done'
```

**Що ви маєте побачити:** два різних імені вперемішку — ось це і є `Service`,
що розкладає запити по копіях.

Закрити тунель — `Ctrl+C` у першому вікні.

Замкніть коло: зайдіть у Harbor у браузері, у проєкт `passes`. У репозиторію
`passes/passes-api` лічильник завантажень (**Pulls**) став ненульовим. Ваш кластер
справді ходив саме сюди.

## Перевірка

📍 **Де:** на ноутбуці, у тому самому вікні термінала, де ви працювали з `kubectl`.

Скрипт ходить в обидва кластери одразу і бере їх зі змінних середовища. Перші дві
обов'язкові, третя — шлях до тенантного kubeconfig'а.

```bash
cd labs/06-harbor

# which cluster to check the application in — your `lab`
export KUBECONFIG=~/lab.kubeconfig
# your tenant number: from it the script assembles the namespace name tenant-workshop03
export COZY_TENANT=workshop03
# where the access to the management cluster lives — there the script will look at Harbor itself.
# You can leave it unset: then the script looks for ~/.kube/workshop, and not finding it — skips
# the checks on the management cluster and says so.
export COZY_KUBECONFIG=~/.kube/workshop

./check.sh
```

⚠️ **На Windows скрипт запускається з WSL**, а не з PowerShell — як його поставити,
написано на початку лаби 0. Без WSL лабу можна пройти, але звіту-артефакту не буде.

Скрипт перевіряє не факт створення Harbor, а роботу по суті: реєстр відповідає за своїм
API, застосунок у кластері запущено з образу, що лежить саме у вашому реєстрі, секрет із
реквізитами існує і вказує на ту саму адресу, а сам сервіс віддає JSON з іменем
Pod'а, який справді існує.

## Прибирання

Застосунок і Harbor знадобляться в наступній лабі — зараз не видаляємо.

Коли закінчите з усіма лабами:

```bash
# delete the objects described in the file: both the Deployment and the Service
kubectl delete -f passes.yaml
# the secret was created by a command, not a file — delete it by name
kubectl delete secret harbor
```

Сам Harbor видаляється через дашборд, як звичайний застосунок. Разом із ним піде й
сховище шарів — це десяток секунд, а не заявка на списання віртуалки.

Варто розуміти, що саме ви видаляєте. Реєстр — це не тільки місце, де лежать образи,
але й єдина відповідь на питання «а що ми взагалі викочували в продуктив за останній
рік». Видаляти його в робочому середовищі так само легко, як тут, вам не захочеться.

## Що ми тепер уміємо

- Заводити собі реєстр образів і пояснювати, чим він відрізняється від Content Library
- Збирати образ двоетапною збіркою і розуміти, чому підсумок виходить у тридцять разів менший
- Відрізняти `docker login` на ноутбуці від доступу, який потрібен кластеру
- Читати `ImagePullBackOff` і знаходити справжню причину в `describe pod`
- Віддавати Pod'у відомості про нього самого через downward API, не даючи йому прав на API кластера

## А в vSphere це було б

Найближчий аналог реєстру — Content Library. Схожість є: і те й інше зберігає образи
і роздає їх машинам, і те й інше вміє права і синхронізацію між майданчиками.

Далі розходиться, і різниця не в дрібницях.

**Content Library копіює шаблон цілком.** Реєстр роздає шари і зберігає однакові шари
один раз. Якщо у вас двадцять сервісів на одній базовій Alpine, база лежить у реєстрі в
єдиному екземплярі, і при запуску двадцять першого сервісу вузол завантажить тільки його
власний шар — лічені мегабайти.

**Шаблон іменується, образ адресується.** У образу є digest — хеш вмісту. За ним
можна перевірити, що ви запускаєте рівно той код, який зібрали, і ніякий інший.
У шаблону такого немає: ви покладаєтеся на те, що ніхто його не підмінив.

**Реєстр — це HTTP-сервіс.** З цього випливає те, заради чого все й затівалося: збірка
в конвеєрі кладе туди образ однією командою, кластер забирає його іншою, ніхто не
монтує сховищ і не копіює файлів між майданчиками руками.

**Де vSphere зручніше, чесно.** Три речі.

Content Library не вимагає нічого розуміти про реквізити. Підключили — працює. Тут
вам довелося окремо пояснювати кластеру, як ходити в реєстр, і ви на цьому спіткнулися,
як спотикаються всі.

Права в vCenter — єдині. Один обліковий запис на все: і на машини, і на бібліотеку, і на мережу.
Тут права в дашборді, права в кластері і права в Harbor — три різних набори, які
треба тримати узгодженими. Це ціна того, що реєстр — самостійний продукт, а не
частина платформи.

Шаблон можна виправити. Розгорнули з шаблону машину, донастроїли, зняли новий шаблон —
і те, що точна послідовність дій ніде не записана, нічому не заважає. Образ так
не збирають: якщо збірка не відтворюється з `Dockerfile`, ви потрапили в халепу.
Дисципліна корисна, але звикати до неї важко, і вдавати, що це не так, безглуздо.
