# Лабораторна 6 · Власний приватний реєстр образів

| | |
|---|---|
| **Час** | 45 хвилин, 10 з них — очікування |
| **Що це доводить** | Реєстр образів піднімається за десять хвилин, і кластер може тягнути образи лише з нього |
| **Що знадобиться** | Кластер із Лабораторної 0, `kubectl`, `docker` (або `podman`) на бастіоні, доступ до дашборда |

## Чому це важливо

Сервіс «Перепустки» дійшов до інформаційної безпеки — і надійшов лист.

> Образи контейнерів тягнуться з публічних реєстрів в інтернеті. Це неприпустимо:
> ніхто не перевіряв, що всередині образу, його вміст може змінитися під тією самою назвою,
> а якщо зовнішній ресурс недоступний — продакшн-сервіс не запуститься. Усі образи
> мають зберігатися у внутрішньому реєстрі організації.

Заперечити нічого — кожен пункт справедливий. Публічний образ із тегом `latest` сьогодні може бути одним,
а завтра іншим. Автор образу може його видалити. Зовнішній реєстр може
обмежити швидкість завантаження в найгірший момент — і це не гіпотеза, так робить кожен
великий публічний реєстр.

Отже, потрібен власний реєстр. Зазвичай це окремий проєкт: заявка на ВМ,
встановлення, сертифікати, сховище, резервні копії, чийсь квартал. Сьогодні це рядок у
каталозі.

А оскільки реєстр ваш і закритий — кластеру доведеться надати до нього доступ.
Саме тут усі спотикаються, і ми спіткнемося теж, навмисно.

## Маленький глосарій

| Термін | Що це | Схоже на… але |
|---|---|---|
| **Образ** | Знімок застосунку з усім необхідним для запуску | **Шаблон ВМ**, але незмінний: усередину не зайдеш і не полагодиш, збираєш новий |
| **Шар** | Частина образу. Образ збирається з шарів, і шари перевикористовуються | однакові шари різних образів зберігаються в реєстрі лише раз |
| **Тег** | Мітка версії образу: `passes-api:v1` | **Назва версії шаблону**, але тег можна переприв'язати до іншого образу, і це головне джерело проблем |
| **Реєстр** | Сховище образів, доступне через HTTP | **Content Library**, але роздає шари по мережі під час кожного запуску, а не копіює весь шаблон |
| **Harbor** | Реєстр з UI, проєктами, дозволами і сканером вразливостей | **Content Library + дозволи + звіти**, але вміє перевіряти вміст образів і підписувати їх |
| **Проєкт у Harbor** | Область усередині реєстру зі своїми дозволами | **Тека в Content Library**, але може бути публічною або приватною, і це визначає, чи потрібні облікові дані |
| **`imagePullSecret`** | Secret із логіном і паролем до реєстру, який читає вузол | **Обліковий запис для підключення Content Library**, але потрібен він **вузлу**, а не вам; ваш `docker login` кластеру нічим не допоможе |
| **Dockerfile** | Інструкція для збірки образу | **Інструкція з підготовки шаблону**, але виконується повністю і з нуля під час кожної збірки |
| **Downward API** | Спосіб дати Pod інформацію про себе через змінні оточення | **Guest-змінні з VMware Tools**, але значення підставляє кластер під час запуску; застосунок їх не запитує |

## Два kubeconfig: не переплутайте

Далі лабораторна працює з двома різними кластерами, і варто розвести їх ще до
першої команди.

| Kubeconfig | Що це | Що ми з ним робимо |
|---|---|---|
| `~/.kube/config` | Кластер керування Cozystack, ваш тенант | дивимося на керовані сервіси: Harbor, бази даних, черги |
| `~/lab.kubeconfig` | **Ваш** кластер `lab` із Лабораторної 0 | розгортаємо застосунок |

Обидва беруться з дашборда. Тенантний лежить у Secret `kubeconfig-tenant-workshopXX`
(вкладка Secrets), кластерний — у розділі доступу вашого кластера `lab`.

⚠️ **Найчастіша причина «у мене нічого не працює» в цій лабораторній — команда, що пішла не в той
кластер.** Перед кожним блоком команд написано, для якого кластера він призначений. Якщо
ви не впевнені:

```bash
# echo prints the value of the variable: which access file kubectl is using right now.
# Empty means kubectl will use the default file ~/.kube/config, not the one you think.
echo $KUBECONFIG

# get nodes = "show the cluster's nodes". Here it's a litmus test:
# the answer tells you which of the two clusters the command went to.
kubectl get nodes
```

У кластері `lab` буде єдиний вузол з назвою на кшталт `kubernetes-lab-md0-...`. У
кластері керування ця команда найімовірніше поверне відмову — тенант не має права
дивитися вузли.

## Що є в теці лабораторної

Усі файли вже ваші — ви отримали їх разом із репозиторієм. Нічого створювати
чи набирати заново не треба: скрізь, де нижче написано `kubectl apply -f name.yaml`, файл береться
звідси.

```bash
# every command in this lab is run from the lab folder — change into it
cd labs/06-harbor
```

| Файл | Що це | Коли знадобиться |
|---|---|---|
| `app/` | Вихідники сервісу «Перепустки» на Go і `Dockerfile` — з них ви збираєте образ | збираєте локально, `docker build` |
| `passes-broken.yaml` | **Навмисно неповний** файл: без облікових даних для доступу до реєстру | застосовуєте його, щоб побачити відмову на власні очі |
| `passes.yaml` | Той самий файл, але з доступом до реєстру | застосовуєте, коли розберетеся |
| `check.sh` | Перевірка, що образ прийшов з вашого Harbor, а не з інтернету | запускаєте наприкінці лабораторної |

## Крок 1. Створити Harbor

📍 **Де:** у браузері, у дашборді Cozystack. Реєстр — спільний тенантний
ресурс, а не частина вашого кластера `lab`, тож створюється він там само, де створювався сам кластер.

Тенант → **Create application** → `Harbor`.

| Поле | Значення | Чому |
|---|---|---|
| Name | `harbor` | стає частиною адреси реєстру; що вийшло, побачите після створення |
| Host | залиште порожнім | тоді адреса збереться сама з назви і домену тенанта |
| Storage class | `replicated` | дані триматимуться у трьох копіях на різних вузлах |
| Trivy → enabled | **вимкнути** | сканер вразливостей завантажує базу на кілька гігабайтів; на навчальному тестовому середовищі це зайві двадцять хвилин очікування |
| Database → replicas | `1` | сьогодні ми не перевіряємо відмовостійкість бази реєстру |
| Database → size | `5Gi` | |
| Redis → replicas | `1` | |
| Redis → size | `1Gi` | |
| Core / Registry preset | залиште як запропоновано | |

⚠️ **Redis у цій формі — це власний внутрішній кеш Harbor; до наступної лабораторної він
не має жодного стосунку.** У лабораторній про кешування ви піднімете окремий Redis для власного застосунку. Назва
та сама, ролі різні.

Натисніть create і чекайте. Harbor піднімається за п'ять-десять хвилин: це не один застосунок, а
кілька сервісів плюс база даних плюс об'єктне сховище для самих шарів образів.

⚠️ **Якщо Harbor висить у стані «not ready» довше за п'ятнадцять хвилин** — подивіться, що
відбувається: `kubectl -n tenant-workshopXX get pods | grep harbor`. Найчастіше це черга
встановлення, спільна на всю платформу: ваш застосунок стоїть у ній за чужими і
чекає.

Harbor зберігає шари образів у S3-сумісному сховищі, і бакет для них створюється сам —
вам не потрібно вмикати власне сховище в тенанті для цього, підійде батьківське.
Якщо Pod'и так і не з'явилися більш ніж за півгодини — напишіть у чат воркшопу з
виводом цієї команди.

## Крок 2. Взяти облікові дані і залогінитися в реєстр

📍 **Де:** у дашборді, потім у терміналі на бастіоні.

Відкрийте створений застосунок `harbor` і знайдіть вкладку із секретами. Там ви знайдете
секрет з обліковими даними реєстру, а всередині нього три потрібні вам ключі:

| Ключ | Що в ньому |
|---|---|
| `url` | адреса вашого реєстру виду `https://harbor-....<домен тестового середовища>` |
| `admin-password` | пароль адміністратора |
| `redis-password` | внутрішній пароль Harbor, який вам не потрібен |

Логін — `admin`.

⚠️ **Не вгадуйте адресу реєстру, беріть її з ключа `url`.** Платформа додає до назви
застосунку префікс типу сервісу, тож адреса може вийти іншою, ніж ви
очікували за назвою. Та сама адреса видна у списку ingress'ів застосунку.

Той самий пароль доступний і через команду. Тенанту не дозволено читати **всі** секрети
поспіль — перевірте самі, `kubectl auth can-i get secrets` відповідає `no`. Але для кожного
створеного вами застосунку платформа налаштовує окреме правило, що дозволяє саме його облікові дані:

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

Дашборд зручніший тим, що не треба вовтузитися з base64. Команда зручніша тим, що
її можна вкинути у скрипт.

Відкрийте адресу в браузері і залогіньтеся. Ви побачите UI Harbor з єдиним проєктом,
`library`.

Тепер те саме з термінала. `docker login` запитує ім'я користувача і пароль і зберігає
облікові дані на вашому бастіоні, у файлі `~/.docker/config.json`. Після цього `docker push`
і `docker pull` ідуть у цей реєстр, нічого не запитуючи.

```bash
# login = "remember the credentials for this registry".
# The argument is the registry address from the url key; harbor-harbor.workshop03.example.org here is an example.
# The command will ask for a username (admin) and a password; the password isn't shown as you type.
docker login harbor-harbor.workshop03.example.org
```

Далі в тексті `harbor-harbor.workshop03.example.org` — це **ваша** адреса, підставляйте свою.

**Що ви маєте побачити:**

```
Login Succeeded
```

⚠️ **Цей `docker login` навчив логінитися в реєстр ваш бастіон — і тільки його.** Для
кластера він не зробив нічого. Запам'ятайте це; знадобиться трохи далі в лабораторній.

## Крок 3. Налаштувати приватний проєкт

📍 **Де:** у браузері, у Harbor.

**Projects** → **New Project**.

| Поле | Значення | Чому |
|---|---|---|
| Project Name | `passes` | один проєкт на сервіс — так простіше роздавати дозволи |
| Access Level | **не ставте Public** | безпека просила закритий реєстр, а не «ваш, але відкритий усьому інтернету» |
| Storage quota | `-1` (без обмежень) | на тестовому середовищі квота лише заважала б |

Проєкт `library`, який був там від самого початку, публічний. Образи тягнуться з нього
зовсім без облікових даних. Саме тому ми ним не користуватимемося: він не відтворить ту саму помилку
доступу, довкола якої побудована лабораторна.

## Крок 4. Зібрати образ

📍 **Де:** на бастіоні (у терміналі бастіона).

У теці цієї лабораторної є `app/` — вихідники сервісу «Перепустки» і інструкція для
збірки. Перед збіркою розберемося, що там усередині.

<details>
<summary><b>Придивимося ближче: що всередині застосунку</b></summary>

Файл `app/main.go`, близько сімдесяти рядків на Go. Він робить рівно дві речі.

**Відповідає на `/healthz` словом `ok`.** Це адреса перевірки готовності: кластер
стукає сюди і не надсилає трафік на репліку, доки не отримає відповідь.

**Відповідає на `/` невеликим JSON**, у якому звітує про себе:

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

Звідки застосунок знає власну назву, вузол і namespace? Він **їх не дізнається**.
Кластер кладе їх туди під час запуску, у змінні оточення:

```go
Pod:  env("POD_NAME", "unknown"),
Node: env("NODE_NAME", "unknown"),
```

А маніфест каже, що туди покласти:

```yaml
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
```

Це називається downward API — «інформація, передана згори». Найближчий аналог у
vSphere — guest-змінні, які VMware Tools передає в машину. Різниця в тому, що
тут застосунок нічого не запитує і нікуди не йде: значення вже лежать в оточенні
на момент старту процесу. Жодного клієнта до API кластера, жодних дозволів на це
API не потрібно.

**У застосунку немає жодної зовнішньої бібліотеки, лише стандартна бібліотека Go.** Це
не забаганка: збірка з залежностями пішла б в інтернет по пакети, а вся
лабораторна почалася з того, що безпека заборонила походи в інтернет.

Файл `app/Dockerfile` — інструкція збірки. У неї два етапи:

```dockerfile
FROM golang:1.23-alpine AS build
...
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

FROM alpine:3.21
COPY --from=build /out/passes-api /usr/local/bin/passes-api
```

Перший етап — етап збірки. Йому потрібен увесь компілятор Go, приблизно 350 МБ. Другий
етап — те, що насправді їде в кластер: з першого етапу переноситься **тільки готовий бінарник**,
усе інше викидається.

Результат — образ приблизно на десять мегабайтів замість трьохсот п'ятдесяти. Річ
не тільки в розмірі: усередині немає ні компілятора, ні вихідників, ні пакетного менеджера.
Тому, хто таки заліз у контейнер, немає з чим працювати.

Порівняйте це з тим, як воно влаштовано в шаблонах віртуальних машин. Шаблон несе всередині цілу
операційну систему, разом із компілятором, якщо він туди колись потрапив. Стиснути її після
факту майже неможливо.

Останні рядки:

```dockerfile
RUN adduser -D -u 10001 app
USER 10001
```

Застосунок не працює під root. У правильно налаштованому кластері Pod'у не дозволять
запуститися під root, і це не наша прискіпливість, а вимога, з якою ви зіткнетеся в будь-якому сучасному
кластері.

</details>

Команда `docker build` збирає образ: читає `Dockerfile`, виконує описані там
кроки і кладе результат у сховище образів на вашому бастіоні. Назва, під якою
зберігається результат, задається прапорцем `-t` і складається з трьох частин:

| Частина | Що означає |
|---|---|
| `harbor-harbor.workshop03.example.org` | адреса реєстру — куди підуть по образ |
| `passes/passes-api` | проєкт і назва всередині реєстру |
| `v1` | тег версії |

Адреса реєстру — частина назви образу. Саме тому перехід на власний реєстр
змінює кожен маніфест: назва образу стає іншою.

Збираймо. Замініть адресу на свою:

```bash
cd labs/06-harbor

# build = "build the image from the Dockerfile".
#   --platform linux/amd64  which processor to build for; the cluster nodes are on x86,
#                           and the bastion may be on ARM — then without the flag you get the wrong thing
#   -t <address>/<project>/<name>:<tag>  what to name the result. The registry address at the start of the name
#                           is where docker push will later send it
#   app/                    the last argument — the folder with the Dockerfile and sources;
#                           its entire contents are handed to the builder
docker build --platform linux/amd64 -t harbor-harbor.workshop03.example.org/passes/passes-api:v1 app/
```

⚠️ **`--platform linux/amd64` — не прикраса.** Якщо у вас Mac на Apple Silicon (M1–M4) або
ARM-бастіон, без цього прапорця ви зберете ARM-образ. Він збереться без помилок, зробить push
без помилок, а в кластері — вузли там на звичайному x86 — Pod потрапить у
`CrashLoopBackOff`, а в логах буде `exec format error`. Це довго діагностувати,
бо ніщо навколо не натякає, що річ в архітектурі процесора.

**Що ви маєте побачити** — рядки про кроки збірки і наприкінці:

```
Successfully tagged harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

## Крок 5. Надіслати образ у ваш реєстр

📍 **Де:** на бастіоні (у терміналі бастіона).

Зібраний образ поки що лежить лише на вашому диску. `docker push` надсилає його в реєстр шар
за шаром; шари, що вже є в реєстрі, повторно не надсилаються.

```bash
# push = "send the image to the registry". Where to send it, docker takes from the image name:
# the first part of the name is the registry address, and there it goes, with the credentials from docker login.
docker push harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

**Що ви маєте побачити** — шари, що йдуть назовні, а наприкінці рядок із довгим хешем,
`digest`.

Загляньте в Harbor у браузері: **Projects** → `passes` → там з'явився репозиторій `passes/passes-api`,
а в ньому тег `v1`. Видно розмір, дату і той самий `digest`.

Цей `digest` — точний вміст образу. Тег `v1` можна завтра переприв'язати до
іншого образу, і ніхто не помітить; `digest` підробити не можна. Звідси правило, яке всі
рано чи пізно засвоюють: **у продакшн відвантажують за digest, а не за тегом.**

## Крок 6. Розгорнути в кластері

📍 **Де:** на бастіоні, кластер `lab`.

```bash
# KUBECONFIG tells kubectl which access file to use. We switch to your `lab` cluster:
# from here on all kubectl commands go to it.
# It stays in effect until the terminal window is closed.
export KUBECONFIG=~/lab.kubeconfig
```

У теці лабораторної є `passes-broken.yaml`. Замість адреси реєстру в ньому
плейсхолдер `HARBOR-HOST` — його треба замінити на вашу адресу. Це робить `sed`: він редагує
файл на місці, нічого не запитуючи і не показуючи. Візьміть рядок для своєї системи:

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

Застосуйте:

```bash
# apply = "bring the cluster to what's described in the file"
kubectl apply -f passes-broken.yaml

# get pods = "show the Pods".
#   -l app=passes-api  only the ones with this label, not everything
#   -w                 don't exit, print changes as they appear;
#                      stop watching — Ctrl+C
kubectl get pods -l app=passes-api -w
```

**Що ви побачите** — і це не те, на що ви очікували:

```
NAME                          READY   STATUS             RESTARTS   AGE
passes-api-6c9d4f7b8-2xk4n    0/1     ErrImagePull       0          8s
passes-api-6c9d4f7b8-2xk4n    0/1     ImagePullBackOff   0          22s
```

Припиніть спостереження через `Ctrl+C` і подивіться, що каже кластер:

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
> Ви щойно успішно залогінилися в реєстр через `docker login` і успішно надіслали
> образ туди. Реєстр вас знає. Чому кластер отримує відмову?

<details>
<summary><b>Відповідь і урок, ширший за цю помилку</b></summary>

**Образ завантажуєте не ви.** Його завантажує `kubelet` — сервіс на вузлі кластера.
Це інша машина, інший процес і інший користувач.

Ваш `docker login` записав облікові дані у файл `~/.docker/config.json` на **вашому
бастіоні**. Вузол кластера про цей файл нічого не знає і не може: між ним і вашим бастіоном
немає взагалі нічого спільного, крім того факту, що ви надсилаєте туди команди.

Поверніться до попередження після `docker login` трохи раніше в лабораторній. Саме про це
там і йшлося, але наслідки ще не було видно.

**Як зробити правильно.** Облікові дані треба помістити в сам кластер — в об'єкт Secret
особливого типу — і потім у маніфесті застосунку сказати, який секрет використовувати
під час завантаження. Такий секрет називається `imagePullSecret`.

**Чому кластеру потрібні окремі облікові дані, а не ваші.** Три причини, і всі три
практичні.

Перша: вас може не бути поруч. Вузол перезапуститься о третій ночі і піде завантажувати
образ знову. Якби він ходив під вашим обліковим записом, усе трималося б на тому, що ви
досі працюєте в цій компанії і ваш пароль не протермінувався.

Друга: дозволи різні. Вам потрібен дозвіл **записувати** в реєстр, надсилати туди збірки.
Кластеру потрібно лише **читати**. Дати кластеру дозвіл стирати образи з
реєстру — погана ідея, а з вашим обліковим записом ви дали б йому саме це.

Третя: слід різний. Коли в журналі реєстру видно, що образ завантажив
`robot$passes-puller`, а не `admin`, розслідування інциденту стає можливим.

**Чому не налаштувати вузол напряму.** Можна покласти облікові дані прямо на вузол, у
конфіг контейнерного середовища — тоді `imagePullSecret` не потрібен. Так іноді роблять. Але
вузли в кластері одноразові: вони перестворюються під час оновлення, додаються зі зростанням
навантаження, вбиваються під час збою. Налаштування, зроблене руками на вузлі, живе до першої
заміни вузла. Секрет у кластері переживає будь-яку заміну.

**Урок ширший за цю помилку.** `ImagePullBackOff` — майже завжди одне з трьох: друкарська
помилка в назві образу, відсутність облікових даних або образ існує, але не під ту
архітектуру процесора. Дивіться не на статус Pod'а, а на `kubectl describe pod` — саме там
написана справжня причина.

</details>

## Крок 7. Надати кластеру доступ до реєстру

📍 **Де:** на бастіоні, кластер `lab`.

Створюємо секрет з обліковими даними реєстру. Окремий варіант команди `create secret`
робить секрет такого типу, який `kubelet` може прочитати сам під час завантаження образів:

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

⚠️ **Пароль у командному рядку залишається в історії shell.** На тестовому середовищі це не
має значення, у робочому — має. Спосіб без історії:

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
<summary><b>Що всередині цього секрету і чому в нього окремий тип</b></summary>

Запитаймо в кластера, який секрет вийшов:

```bash
#   -o jsonpath='{.type}'  print a single field of the object — the secret's type
#   {"\n"}                 add a newline, otherwise the output runs into the prompt
kubectl get secret harbor -o jsonpath='{.type}{"\n"}'
```

```
kubernetes.io/dockerconfigjson
```

У секрету є **тип**, і він не декоративний. Звичайний секрет — це набір пар ключ-значення,
і що з ними робити, вирішує застосунок. Секрет типу
`kubernetes.io/dockerconfigjson` розуміє сам `kubelet`: він знає, що всередині файл
того самого формату, що й `~/.docker/config.json`, і може використати його під час завантаження образів.

Щоб подивитися вміст (пароль там у base64 — це **не шифрування**, а спосіб
записати бінарні дані як текст, і розкодувати їх може будь-хто):

```bash
# .data.\.dockerconfigjson — the key inside the secret. The key name itself starts with a dot,
# so it's escaped: otherwise jsonpath would take it for a path separator.
# base64 -d decodes the value back into text — you'll see the same format
# as in the file ~/.docker/config.json on your bastion.
kubectl get secret harbor -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Звідси важливе: **Secret у Kubernetes за замовчуванням не зашифрований**, він лише
відгороджений дозволами доступу. Хто може читати секрети в namespace, той бачить паролі.
Як поводитися з цим по-людськи — окрема лабораторна про сховище секретів.

**Як це роблять на практиці.** Не під обліковим записом `admin`. У Harbor є роботи: **Projects** →
`passes` → **Robot Accounts** → створіть робота лише з дозволом `pull`. Облікові дані робота
йдуть у `imagePullSecret`, і тоді витік секрету з кластера означає, що хтось може завантажити
ваші образи — неприємно, але не фатально. Витік `admin` означає, що хтось може їх підмінити.

Ми використовуємо `admin`, щоб не затягувати лабораторну. Знайте, що це спрощення.

</details>

Тепер застосуйте правильний маніфест. Спершу та сама підстановка адреси, що й раніше, тільки в
іншому файлі; потім приберіть зламаний застосунок і поставте робочий:

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

Різниця між робочим маніфестом і зламаним — рівно два рядки:

```yaml
      imagePullSecrets:
        - name: harbor
```

## Крок 8. Подивитися, що з цього вийшло

📍 **Де:** на бастіоні, кластер `lab`.

Застосунок назовні не виставлений, але подивитися на нього треба. `port-forward` копає
тунель з бастіона в кластер: доки команда працює, запит до
`localhost:8080` іде на сервіс `passes-api`. Найближчий аналог — тимчасовий проброс
порту на NAT-шлюзі, тільки без втручання в мережу.

```bash
# port-forward svc/passes-api = a tunnel to the service, not to a specific Pod
#   8080:80 — the left number is the port on your bastion, the right one the service port in the cluster
# Don't close the window: the tunnel lives as long as the command runs.
kubectl port-forward svc/passes-api 8080:80
```

В іншому вікні термінала:

```bash
# curl — "go to the address and show the answer".
#   -s     don't show the progress indicator
#   ; echo add a newline: the answer comes as a single line, and without it
#          it runs into the shell prompt
curl -s http://localhost:8080/; echo
```

**Що ви маєте побачити** — JSON, у якому застосунок звітує, яка репліка відповіла, на якому
вузлі вона працює і з якого реєстру прибула:

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

Поле `pod` у відповіді — назва репліки, що відповіла. Порівняйте його зі
списком реплік:

```bash
# a new terminal window knows nothing about the KUBECONFIG variable — set it here too,
# otherwise kubectl will go to the wrong cluster
export KUBECONFIG=~/lab.kubeconfig

# the same selection by label: the list should contain the name you saw in the answer
kubectl get pods -l app=passes-api
```

Повторіть запит кілька разів — назва залишиться **тією самою**, і це не
несправність. `port-forward` вибирає єдину репліку в момент старту і тримає тунель саме до
неї до `Ctrl+C`; балансування на цьому шляху немає взагалі. Воно є на
`Service`, але побачити його можна лише зсередини кластера — ззовні ви говорите з
конкретним Pod'ом.

Перевірити балансування по-справжньому можна так — вісім запитів із тимчасового Pod'а, що живе
всередині кластера:

```bash
# run brings up a one-off Pod, --rm cleans it up afterwards.
# Everything after -- runs inside the Pod: eight times we hit the service by its internal name
# and print the line with the name of the replica that answered.
kubectl run probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
  -- sh -c 'for i in $(seq 1 8); do curl -s http://passes-api/ | grep -o "passes-api-[a-z0-9-]*"; done'
```

**Що ви маєте побачити:** дві різні назви впереміш — це `Service` розкидає
запити по репліках.

Щоб закрити тунель — `Ctrl+C` у першому вікні.

Замкніть коло: зайдіть у Harbor у браузері, у проєкт `passes`. На
репозиторії `passes/passes-api` лічильник завантажень (**Pulls**) став ненульовим. Ваш кластер
справді пішов саме сюди.

## Перевірка

📍 **Де:** на бастіоні, у тому самому вікні термінала, де ви працювали з `kubectl`.

Скрипт іде в обидва кластери одразу і бере їх зі змінних оточення. Перші дві
обов'язкові, третя — шлях до тенантного kubeconfig.

```bash
cd labs/06-harbor

# which cluster to check the application in — your `lab`
export KUBECONFIG=~/lab.kubeconfig
# your tenant number: from it the script assembles the namespace name tenant-workshop03
export COZY_TENANT=workshop03
# where the access to the management cluster lives — there the script will look at Harbor itself.
# You can leave it unset: then the script looks for ~/.kube/config, and not finding it — skips
# the checks on the management cluster and says so.
export COZY_KUBECONFIG=~/.kube/config

./check.sh
```

⚠️ **На Windows скрипт запускається з WSL**, а не з PowerShell — як його встановити, написано
на початку Лабораторної 0. Без WSL лабораторну зробити можна, але артефакт-звіту не буде.

Скрипт перевіряє не факт, що Harbor створено, а роботу по суті: реєстр
відповідає через своє API, застосунок у кластері запущений з образу, що лежить у вашому
власному реєстрі, секрет з обліковими даними існує і вказує на ту саму адресу, а
сам сервіс повертає JSON з назвою Pod'а, який справді існує.

## Прибирання

Застосунок і Harbor знадобляться в наступній лабораторній — не видаляйте їх зараз.

Коли закінчите з усіма лабораторними:

```bash
# delete the objects described in the file: both the Deployment and the Service
kubectl delete -f passes.yaml
# the secret was created by a command, not a file — delete it by name
kubectl delete secret harbor
```

Сам Harbor видаляється через дашборд, як будь-який звичайний застосунок. Разом із ним
іде і сховище шарів — це десяток секунд, а не заявка на списання ВМ.

Варто розуміти, що саме ви видаляєте. Реєстр — це не тільки місце, де лежать
образи, а й єдина відповідь на питання «що ми насправді відвантажили в продакшн за
минулий рік». Видаляти його в робочому середовищі так само легко, як тут, ви не
захочете.

## Що ми тепер уміємо

- Підняти собі реєстр образів і пояснити, чим він відрізняється від Content Library
- Зібрати образ двоетапною збіркою і зрозуміти, чому результат виходить у тридцять разів меншим
- Відрізнити `docker login` на бастіоні від доступу, потрібного кластеру
- Прочитати `ImagePullBackOff` і знайти справжню причину в `describe pod`
- Дати Pod'у інформацію про себе через downward API, не надаючи йому дозволів на API кластера

## У vSphere це було б

Найближчий аналог реєстру — Content Library. Схожість є: обидва зберігають образи
і роздають їх машинам, обидва вміють дозволи і синхронізацію між майданчиками.

Далі вони розходяться, і різниця не в дрібницях.

**Content Library копіює весь шаблон.** Реєстр роздає шари і зберігає однакові
шари один раз. Якщо у вас двадцять сервісів на одному базовому Alpine, база лежить у реєстрі в
одному екземплярі, і коли запускається двадцять перший сервіс, вузол завантажить лише свій власний
шар — кілька мегабайтів.

**Шаблон іменований, образ адресований.** У образу є digest — хеш його вмісту. За
ним можна переконатися, що ви запускаєте рівно той код, який зібрали, і жодний інший. У шаблону
такого немає: ви покладаєтеся на те, що ніхто його не підмінив.

**Реєстр — це HTTP-сервіс.** Звідси випливає весь сенс вправи: збірка в
конвеєрі кладе туди образ однією командою, кластер забирає його іншою, і ніхто
не монтує сховище і не копіює файли між майданчиками руками.

**Де vSphere зручніший, чесно.** Три речі.

Content Library не вимагає розуміти нічого про облікові дані. Підключіть її — вона працює.
Тут вам довелося окремо пояснювати кластеру, як дістатися реєстру, і ви на цьому
спіткнулися, як усі.

Дозволи у vCenter єдині. Один обліковий запис на все: машини, бібліотека і
мережа. Тут дозволи в дашборді, дозволи в кластері і дозволи в Harbor —
три різні набори, які треба тримати синхронними. Це плата за те, що реєстр —
самостійний продукт, а не частина платформи.

Шаблон можна редагувати. Ви розгортаєте машину з шаблону, донастроюєте її, знімаєте новий
шаблон — і те, що точна послідовність кроків ніде не записана, нічому не
заважає. Образи так не збирають: якщо збірка не відтворюється з
`Dockerfile`, ви в біді. Дисципліна корисна, але звикати до неї важко, і
вдавати інакше — нерозумно.
