# Лаба 7 · Кеш перед повільним бекендом

| | |
|---|---|
| **Час** | 50 хвилин, з них 10 — очікування |
| **Що доводить** | Виграш від кешу вимірюється, а не декларується: було 800 мс, стало одиниці |
| **Що знадобиться** | Кластер із лаби 0, Harbor і образ із лаби 6, `kubectl`, `docker`, доступ до дашборда |

> ⚠️ **`workshopXX` — це заглушка, а не ім'я.** Підставте свій номер тенанта, інакше
> команда піде в чужий тенант і ви отримаєте відмову в доступі або, що гірше, чужі
> дані. Свій номер ви отримали разом із паролем.

## Навіщо це

Сервіс «Перепустка» працює, ІБ задоволена, реєстр свій. І тут приходить охорона.

> На прохідній список гостей відкривається по десять секунд. Люди стоять у черзі, ми
> дивимося в екран і чекаємо. Раніше було нормально.

Ось що відбувається. Кожен рядок списку — це гість, у кожного гостя є співробітник, який
його запросив, а відомості про співробітників лежать не у вас. Вони лежать у кадровій
системі, яку поставили у 2011 році, і вона відповідає **800 мілісекунд** на запит.
Дванадцять рядків на екрані — майже десять секунд.

Переписати кадрову систему не можна: вона не ваша, вона чужа, і черга на доопрацювання там
розписана до наступного року. Пришвидшити її теж не можна з тієї ж причини.

Зате можна перестати питати її так часто. Прізвище й відділ співробітника змінюються
приблизно раз на кілька років. Питати їх у повільної системи **щоразу** при відкритті
списку — марнотратство: досить спитати один раз і запам'ятати відповідь.

Місце, де запам'ятовують відповіді, називається кешем. Сьогодні ми його поставимо — і, що
важливіше, **виміряємо різницю до і після**. Не «стало швидше», а конкретне число.

## Словничок

| Термін | Що це | Схоже на… але |
|---|---|---|
| **Кеш** | Швидке сховище готових відповідей на повторювані питання | **Кеш читання на масиві**, але тут вирішує, що кешувати, застосунок, а не пристрій |
| **Redis** | Сховище «ключ-значення» цілком в оперативній пам'яті | прямого аналога немає; найближче memcached, якщо стикалися |
| **Ключ** | Рядок, за яким у кеші шукають значення | **Ім'я файлу**, але вигадуєте ви, і від того, як вигадаєте, залежить усе |
| **TTL (time to live)** | Строк життя запису, після якого він зникає сам | **Строк зберігання знімка**, але видалення відбувається без чиєїсь участі та без завдання за розкладом |
| **Промах (cache miss)** | Відповіді в кеші немає, треба йти до повільного джерела | **Промах кешу читання на масиві**, але промах тут коштує не мілісекунди, а похід у чужу систему |
| **Влучення (cache hit)** | Відповідь знайшлася в кеші | **Влучення кешу читання**, але влучення рахує застосунок, і воно ж видно у відповіді полем `cached` |
| **Sentinel** | Служба, яка стежить за Redis і перемикає роль ведучого при відмові | **HA-агент**, але працює всередині самого Redis, окремого кластера під неї не потрібно |
| **Керований сервіс** | Сервіс, який платформа встановлює, оновлює і бекапить за вас | ви не отримуєте root на машину з ним — і в цьому суть |
| **Fortio** | Генератор навантаження з вебінтерфейсом і гістограмою затримок | свого аналога у vSphere немає: це не засіб вимірювати інфраструктуру, а засіб вимірювати сервіс |
| **p50 / p99** | Медіана і «найгірші відсотки»: у 99% запитів затримка не більша за це | середня затримка бреше, ці два числа — ні |

## Два кубконфіги: не переплутайте

У цій лабі знову два кластери.

| Кубконфіг | Що це | Що в ньому робимо |
|---|---|---|
| `~/.kube/workshop` | Кластер керування Cozystack, ваш тенант | дивимося на Redis: адреса, стан |
| `~/lab.kubeconfig` | **Ваш** кластер `lab` із лаби 0 | розгортаємо застосунок і міряємо |

Обидва беруться в дашборді: тенантний — у Secret `kubeconfig-tenant-workshopXX` на вкладці
Secrets, кластерний — у розділі доступів вашого кластера `lab`.

⚠️ **Перед кожним блоком команд написано, куди він адресований.** Якщо щось поводиться
дивно, найперше — `echo $KUBECONFIG`.

## Що лежить у папці лаби

Усі файли вже у вас — ви забрали їх разом із репозиторієм. Створювати й друкувати заново
нічого не потрібно: там, де нижче написано `kubectl apply -f name.yaml`, файл береться звідси.

```bash
# all commands in this lab run from the lab folder — switch into it
cd labs/07-redis
```

| Файл | Що це | Коли знадобиться |
|---|---|---|
| `app/` | Вихідники сервісу «Перепустка», версія з кешем | збираєте локально, `docker build` |
| `hr-legacy.yaml` | Заглушка легасі-довідника: відповідає повільно, як справжній | застосовуєте на своєму кластері `lab` |
| `passes-api.yaml` | Сервіс «Перепустка» без кешу — спершу вимірюємо, як погано | застосовуєте туди ж |
| `cache-patch-broken.yaml` | **Навмисно неповний** патч увімкнення кешу | застосовуєте, щоб побачити помилку |
| `cache-patch.yaml` | Робочий патч. Патч, а не повний маніфест: видно рівно те, що змінюється | застосовуєте після розбору |
| `fortio.yaml` | Генератор навантаження для замірів до і після | застосовуєте туди ж |
| `check.sh` | Перевірка, що другий запит на порядок швидший за перший | запускаєте наприкінці лаби |

## Крок 1. Збираємо версію v2 і кладемо у свій реєстр

📍 **Де:** на ноутбуці.

У папці `app/` лежить вихідник. Від версії з минулої лаби він відрізняється двома речами:
з'явився режим «повільний довідник» і з'явилася робота з кешем.

<details>
<summary><b>Придивімося ближче: що всередині app/</b></summary>

**Один образ, дві ролі.** Змінна `MODE` визначає, чим запуститься процес:

| `MODE` | Хто це | Що робить |
|---|---|---|
| `hr` | заглушка легасі-довідника | спить `HR_DELAY` (за умовчанням 800 мс) і віддає дані співробітника |
| `api` | сам сервіс «Перепустка» | ходить у довідник, а якщо задано `REDIS_ADDR` — спершу в кеш |

Два образи замість одного означали б два місця, де можна забути оновити версію.

**Як влаштований похід за даними.** Уся логіка кешування — приблизно двадцять рядків:

```go
if cache != nil {
    raw, found, err := cache.Get(key)
    switch {
    case err != nil:
        log.Printf("cache unavailable (%v), going to the directory", err)
    case found:
        if json.Unmarshal([]byte(raw), &emp) == nil {
            fromCache = true
        }
    }
}

if !fromCache {
    emp, err = fetchEmployee(hrClient, hrURL, id)
    ...
    cache.SetTTL(key, string(b), ttl)
}
```

Зверніть увагу на першу гілку: **якщо кеш недоступний, застосунок не падає.** Він пише в
журнал і йде в довідник — повільно, але правильно. Це не прикраса, а обов'язкова
властивість будь-якого кешу: кеш пришвидшує, але не може бути умовою працездатності. Якщо
сервіс лягає разом із кешем, ви побудували не кеш, а ще одну точку відмови.

Із цієї властивості, до речі, виросте передбачувана невдача трохи далі по лабі. Застосунок,
який мовчки продовжує працювати, — приємний у бою і підступний при відлагодженні.

**Ключ.** `employee:42` — ім'я сутності, двокрапка, ідентифікатор. Двокрапка тут не
синтаксис Redis, а загальноприйнята звичка: вона дозволяє потім шукати за зразком
`employee:*` і не плутати свої ключі з чужими, коли в одному Redis живуть два застосунки.

**Строк життя призначається тією ж командою, що й запис:**

```go
r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
```

Не `SET`, а потім `EXPIRE` двома командами. Між двома командами з'єднання може обірватися —
і ключ залишиться в кеші назавжди. Такі ключі потім шукають місяцями.

**Клієнт Redis тут свій, на п'ятдесят рядків.** Протокол Redis текстовий, і для `GET`
і `SET` він вміщується в одну функцію. У робочому проєкті беруть готову бібліотеку —
вона вміє пул з'єднань, повтори й sentinel. Тут свій потрібен рівно для того, щоб у
збірки не було зовнішніх залежностей: згадайте, з чого почалася минула лаба.

**Окремий клієнт HTTP зі збільшеним пулом з'єднань:**

```go
tr := http.DefaultTransport.(*http.Transport).Clone()
tr.MaxIdleConnsPerHost = 64
```

Без цього рядка під навантаженням половина часу йшла б на встановлення TCP-з'єднань
до довідника, і замір показав би не затримку довідника, а нашу власну неакуратність.
Перше правило вимірювань: переконайтеся, що ви вимірюєте те, що думаєте.

</details>

Збираємо і відправляємо у свій Harbor. `build` збере образ за `Dockerfile` і залишить його
на ноутбуці, `push` відправить його в реєстр. Ім'я образу те саме, що й у минулій лабі, а
тег інший — `v2`: у реєстрі тепер лежатимуть обидві версії, і стара нікуди не дінеться.

Підставте свою адресу:

```bash
cd labs/07-redis

# build = "build the image from the Dockerfile".
#   --platform linux/amd64  which processor to build for; the cluster nodes are x86
#   -t <host>/<project>/<name>:<tag>  what to name the result; the registry host at the
#                           start of the name is where push will send it later
#   app/                    the folder with the Dockerfile and sources to build from
docker build --platform linux/amd64 -t harbor.workshop03.example.org/passes/passes-api:v2 app/

# push = "send the image to the registry". The address is taken from the first part of the
# image name, the credentials — from the docker login you did in the previous lab.
docker push harbor.workshop03.example.org/passes/passes-api:v2
```

⚠️ **`--platform linux/amd64` обов'язковий, якщо у вас Mac на Apple Silicon або ноутбук на
ARM.** Без нього образ збереться під ARM, запушиться без помилок, а в кластері дасть
`CrashLoopBackOff` з `exec format error` у логах.

## Крок 2. Розгортаємо довідник і сервіс

📍 **Де:** на ноутбуці, кластер `lab`.

В обох маніфестах замість адреси реєстру стоїть заглушка `HARBOR-HOST`: її замінює `sed`,
правлячи файли на місці. Далі `apply` передає кластеру описане у файлах, а
`rollout status` чекає, поки копії піднімуться.

```bash
# KUBECONFIG tells kubectl which access file to use. We switch to
# your `lab` cluster; it holds until you close the terminal window.
export KUBECONFIG=~/lab.kubeconfig

# sed -i = "edit the file in place".
#   's|old|new|g'  replace every occurrence; the | separator is used instead of / because
#                  the address contains slashes
#   The macOS version of sed requires a mandatory argument after -i; empty quotes
#   mean "don't make a backup". On Linux that argument must not be there.
#   There are two files at the end of the line: sed accepts several at once and edits them in one pass.

# Linux
sed -i    's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml

# apply = "bring the cluster to what's described in the files". The -f flag is repeated for each file.
kubectl apply -f hr-legacy.yaml -f passes-api.yaml

# rollout status waits for the copies to be ready and exits on its own; if they don't, it returns an error
kubectl rollout status deployment/hr-legacy
kubectl rollout status deployment/passes-api
```

⚠️ Обидва маніфести посилаються на Secret `harbor` — той самий `imagePullSecret` із минулої
лаби. Якщо ви її не робили, Pod'и стануть у `ImagePullBackOff`. Створити Secret:

```bash
# create secret docker-registry = "create a Secret with registry credentials";
# such a Secret can be read by the kubelet itself when it pulls the image onto a node.
#   harbor             the Secret's name in the cluster — both manifests reference it
#   --docker-server    which registry these credentials are for
#   --docker-username  who logs in; --docker-password — the Harbor administrator password
kubectl create secret docker-registry harbor \
  --docker-server=harbor.workshop03.example.org \
  --docker-username=admin --docker-password='YOUR-PASSWORD'
```

Перевіримо, що ланцюжок працює. Сервіс видно лише зсередини кластера, тому запит до нього
робимо звідти ж: підіймаємо одноразовий Pod з `curl`, він питає сервіс `passes-api`,
друкує відповідь і зникає.

```bash
# run probe = "run a Pod named probe".
#   --rm              delete the Pod as soon as it's done
#   -i                show us its output
#   --restart=Never   don't restart: this is a one-time command, not a permanent service
#   --image=...       which image to use; the version is pinned so nothing new arrives
#   --quiet           don't print service lines, only the answer
#   --                everything after these two dashes is the command inside the Pod
# An address of the form <service>.<namespace>.svc.cluster.local is the service's internal name;
# by it the Pods find each other without knowing addresses.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Що ви маєте побачити:**

```json
{"cache":"off","cached":false,"dept":"Logistics","id":"42","name":"Poole E.",
 "pod":"passes-api-6f8b9c7d5-x2ktm","took_ms":803,"ttl_s":60}
```

Ключові поля: `cache: off` — кешу немає, `took_ms: 803` — ось вони, ваші вісімсот
мілісекунд. Саме цю цифру ми й будемо зменшувати.

## Крок 3. Міряємо, як погано зараз

📍 **Де:** на ноутбуці, кластер `lab`.

Один запит — не вимірювання. Потрібне навантаження, схоже на робоче, і розподіл затримок.

Розгортаємо генератор. Він піднімається як звичайний застосунок і живе в кластері поряд
із сервісом — так замір не залежить від вашого інтернету і від тунелю:

```bash
# the file has two objects: the generator itself and a service for it
kubectl apply -f fortio.yaml
kubectl rollout status deployment/fortio
```

Тепер запускаємо навантаження. Команда `kubectl exec` виконує що-небудь усередині вже
працюючого Pod — тут усередині генератора запускається він сам, у режимі обстрілу:

```bash
# exec deploy/fortio = run a command inside this application's Pod
#   --            the boundary: kubectl on the left, on the right the command that goes into the Pod
#   fortio load   bombardment mode: send requests and measure the response time
#   -qps 20       twenty requests per second — we set a pace, not "push as hard as we can"
#   -t 20s        how long the measurement lasts
#   -c 16         sixteen parallel connections. The number isn't arbitrary:
#                 the directory answers in 800 ms, so one connection manages
#                 a little more than one request per second. To hold the set 20 per
#                 second, you need no fewer than sixteen connections — otherwise Fortio
#                 will hit the latency wall and not deliver the requested pace.
#   the last argument is the address we're bombarding
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Що ви маєте побачити** — наприкінці виводу гістограму і рядки з процентилями:

```
# target 50% 0.801
# target 90% 0.806
# target 99% 0.812
Code 200 : 400 (100.0 %)
```

**Запишіть ці числа.** Через десять хвилин вони знадобляться для порівняння, а пам'ять
влаштована так, що «ну було десь вісімсот» перетворюється на «ну було десь пів секунди».

### Те саме мишкою

Мишкою — це не дашборд Cozystack: він працює з кластером керування і показує позиції
каталогу тенанта, а всередину вашого кластера `lab` не заглядає. Свій вебінтерфейс є в
самого генератора, і до нього треба дотягнутися тунелем.

```bash
# port-forward svc/fortio = a tunnel from your laptop to the generator's service in the cluster
#   8081:8080 — the left number is the port on your laptop, the right one the service port in the cluster
# Port 8081 is used because 8080 might be taken by something else on your machine.
# Don't close the window: the tunnel lives as long as the command runs. To stop it — Ctrl+C.
kubectl port-forward svc/fortio 8081:8080
```

Відкрийте <http://localhost:8081/fortio>. Заповніть:

| Поле | Значення |
|---|---|
| URL | `http://passes-api.default.svc.cluster.local/employee?id=42` |
| QPS | `20` |
| Duration | `20s` |
| Connections | `16` |

Натисніть **Start**. Унизу намалюється гістограма затримок. Вона наочніша за числа: видно,
що всі запити зібралися в одну вузьку смугу близько 800 мс — тобто гальмує не «іноді», а
завжди й однаково.


<details>
<summary><b>Чому p50 і p99, а не середня затримка</b></summary>

Середня затримка — найоманливіша метрика в експлуатації.

Уявіть: дев'яносто запитів по 10 мс і десять запитів по 2000 мс. Середня — 209 мс, і за
звітом усе пристойно. А насправді кожен десятий користувач чекав дві секунди і пішов.

**p50 (медіана)** — половина запитів швидша за це число, половина повільніша. Відповідає на
питання «скільки чекає звичайний користувач».

**p99** — 99% запитів швидші за це число. Відповідає на питання «як буває погано». Саме p99
визначає, чи буде охорона на прохідній скаржитися: скаржаться не на середнє, а на той раз,
коли довелося чекати.

У нашому замірі p50 і p99 майже збіглися — 801 і 812 мс. Це ознака, що гальма не випадкові,
а системні: повільно рівно завжди. Таке лікується кешем. Якби p50 був 10 мс, а p99 —
2000 мс, причина була б іншою, і кеш би не допоміг.

</details>

## Крок 4. Створюємо Redis

📍 **Де:** у браузері, у дашборді Cozystack. Redis — спільний ресурс тенанта, як і Harbor.

Тенант → **Створити застосунок** → `Redis`.

| Поле | Значення | Чому так |
|---|---|---|
| Name | `cache` | потрапить в імена сервісів, коротке зручніше |
| Replicas | `2` | одна ведуча копія й одна ведена: подивимося, що це дає |
| Size | `1Gi` | довідник співробітників у пам'ять поміститься з великим запасом |
| Storage class | `replicated` | |
| Resources preset | залишити запропонований | |
| Version | `v8` | |
| Auth enabled | **увімкнено** (за умовчанням) | платформа згенерує пароль сама |
| External | **вимкнено** | назовні цей кеш виставляти нема навіщо |

Готовності чекати три-п'ять хвилин.

⚠️ **Цей Redis не має відношення до того Redis, який ви могли бачити у формі створення
Harbor.** Там він внутрішній кеш самого реєстру. Цей — ваш власний, для вашого застосунку.

<details>
<summary><b>Чим керований Redis відрізняється від Redis, поставленого на віртуалку</b></summary>

Поставити Redis на віртуальну машину — робота на пів години: `apt install redis`, поправити
`bind` і `requirepass`, увімкнути в автозавантаження. Саме тому керований сервіс здається
надмірним. Різниця не у встановленні, а в тому, що відбувається далі.

**Реплікація.** Ви поставили `replicas: 2` — і отримали дві копії даних на різних вузлах
плюс три sentinel, які за ними стежать. Якщо вузол із ведучою копією помре, sentinel
проведуть вибори і призначать ведучою другу копію. Застосунок переживе це з паузою в кілька
секунд. Зібрати те саме руками — день роботи і потім ще день на перевірку, що воно справді
перемикається, а не лише має вигляд налаштованого.

**Оновлення.** Вразливість у Redis — не рідкість. На віртуалці оновлення означає
`apt upgrade`, перезапуск і надію, що конфіг переживе зміну мажорної версії. Тут оновлення
образу приїжджає разом з оновленням платформи, і порядок перезапуску копій витриманий так,
щоб сервіс не пропав.

**Спостережуваність.** Метрики вже збираються: експортер піднято поряд із кожною копією,
графіки є без вашої участі. На віртуалці це ще один пакет, ще один конфіг і ще одна річ,
яку забули налаштувати.

**Чого ви позбавляєтеся.** Чесно: root на машині з Redis. Не можна зайти по SSH, не можна
поправити конфіг руками, не можна поставити поряд свій скрипт. Усе, що не виведено в
параметри застосунку, вам недоступне — а виведено далеко не все. Якщо вам потрібен
нестандартний `maxmemory-policy` або модуль Redis, керований сервіс вам його не дасть, і
доведеться ставити своє на віртуалці. Це реальне обмеження, а не дрібниця.

</details>

## Крок 5. Знаходимо адресу Redis і перевіряємо зв'язність

📍 **Де:** на ноутбуці, **кластер керування**.

Redis живе у вашому тенанті на кластері керування, а застосунок — у вашому кластері `lab`.
Це два різні кластери, і найперше треба переконатися, що другий дотягується до першого.

Дивимося, які сервіси з'явилися:

```bash
# --kubeconfig sets the access file right in the command — just once, without touching KUBECONFIG.
# This way two commands in a row can be addressed to different clusters without getting confused.
#   -n tenant-workshopXX  the namespace of your tenant
#   get svc               "show the services" — permanent addresses backed by Pods
#   | grep redis          keep only the lines with the word redis in the output
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX get svc | grep redis
```

**Що ви маєте побачити** — кілька сервісів із промовистими префіксами:

| Ім'я | Що за ним стоїть |
|---|---|
| `rfrm-redis-cache` | ведуча копія (master) — сюди пишуть і читають |
| `rfrs-redis-cache` | ведені копії (replicas) — лише читання |
| `rfs-redis-cache` | sentinel — служба, яка стежить і перемикає ролі |

⚠️ **Звідки в іменах узялося зайве `redis-`.** Платформа додає до імені застосунку префікс
із типом сервісу: застосунок `cache` типу Redis усередині називається `redis-cache`. Звідси
`rfrm-redis-cache`, а не `rfrm-cache`. Не вгадуйте імена — дивіться на вивід команди вище,
він і є джерело істини.

Нам потрібен `rfrm-redis-cache`: кеш і пише, і читає, а писати можна лише у ведучу копію.

Повне ім'я, за яким його видно з вашого кластера, збирається так:

```
rfrm-redis-cache.tenant-workshopXX.svc.cozy.local
```

Забираємо пароль. 📍 **Де:** у дашборді, застосунок `cache`, вкладка з секретами. Потрібен
Secret `redis-cache-auth`, ключ `password`.

Тепер — перевірка зв'язності. 📍 **Де:** на ноутбуці, кластер **`lab`**.

У своєму кластері підіймаємо одноразовий Pod із клієнтом Redis і просимо його сказати Redis
слово `ping`. Якщо відповідь прийде, значить із кластера `lab` видно кеш у тенанті — а це
і є те єдине, що ми зараз перевіряємо.

⚠️ **Пароль передаємо змінною `REDISCLI_AUTH`, а не прапором `-a`.** Усе, що потрапляє в
аргументи команди, видно в списку процесів на вузлі і залишається в описі Pod — а його
читає будь-хто, у кого є доступ до вашого namespace. Сам `redis-cli` про це попереджає, і
глушити попередження замість того, щоб прибрати причину, — погана звичка.

```bash
export KUBECONFIG=~/lab.kubeconfig

# run redis-probe = a one-off Pod with the redis-cli client:
#   --rm --restart=Never  it did its job and deleted itself, no need to restart
#   -i --quiet            show us the output and don't print service lines
#   --env=REDISCLI_AUTH   the password goes into the Pod as an environment variable, not an argument
#   --                    to the right of these dashes is the command that goes into the Pod
#   redis-cli -h <name>   which server to connect to; the name is that same full one
#   ping                  a short "are you alive"; the answer to it is PONG
kubectl run redis-probe --rm -i --restart=Never --image=redis:7-alpine --quiet \
  --env=REDISCLI_AUTH='YOUR-PASSWORD' -- \
  redis-cli -h rfrm-redis-cache.tenant-workshopXX.svc.cozy.local ping
```

**Що ви маєте побачити:**

```
PONG
```

⚠️ **Якщо замість `PONG` ви побачили помилку розв'язання імені** — значить, із вашого
кластера не видно внутрішніх імен кластера керування. Це лікується зверненням за адресою:

```bash
# -o jsonpath='{.spec.clusterIP}' — print one field of the object: the internal address
# the platform assigned to this service. {"\n"} adds a line break.
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX get svc rfrm-redis-cache \
  -o jsonpath='{.spec.clusterIP}{"\n"}'
```

Далі всюди підставляйте отриману адресу замість імені. Працювати буде так само; гірше лише
тим, що при перестворенні Redis адреса зміниться, а ім'я — ні. Якщо і за адресою не
відповідає — напишіть у чат воркшопу, це налаштування тестового середовища, а не ваша
помилка.

## Крок 6. Вмикаємо кеш

📍 **Де:** на ноутбуці, кластер `lab`.

Змінюємо застосунок не цілим маніфестом, а патчем — так видно рівно те, що змінюється.
Спершу підставляємо в патч адресу свого Redis, потім віддаємо патч кластеру: `kubectl patch`
дописує зміни у вже наявний об'єкт, а не замінює його цілком.

```bash
# the same address substitution as before, only the placeholder is different — REDIS-ADDR

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml

# patch deployment passes-api = "fix up this object with what's in the file"
#   --patch-file  where to take the changes from
# Changing environment variables means new Pods: the old ones will be replaced.
kubectl patch deployment passes-api --patch-file cache-patch-broken.yaml

# wait until the new copies become ready — otherwise we'll measure the old ones still
kubectl rollout status deployment/passes-api
```

Міряємо ще раз — тією ж командою, якою міряли до ввімкнення кешу. Умови обстрілу мають
збігатися до останнього прапора, інакше порівнювати не буде чого:

```bash
# the same twenty requests per second, the same twenty seconds, the same sixteen connections
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

> **Зупиніться і подумайте, перш ніж читати далі.**
>
> Числа не змінилися: ті самі вісімсот мілісекунд. При цьому жоден Pod не впав, помилок
> у відповідях немає, усі запити повернули `200`. Redis створено, адреса правильна — ви
> щойно отримали від нього `PONG`.
>
> Де дивитися?

<details>
<summary><b>Відповідь і урок, ширший за цю помилку</b></summary>

Спершу подивіться, що відповідає сам застосунок: у відповіді є поля, за якими видно, чи
ввімкнено кеш і чи прийшла відповідь із нього.

```bash
# the same one-off Pod with curl as before: we ask the service from inside the cluster
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

```json
{"cache":"redis","cached":false,"took_ms":802, ...}
```

`cache: redis` — кеш увімкнено. `cached: false` — і при цьому відповідь прийшла не з нього.
Причому **завжди** false, скільки не повторюй.

Тепер журнал. Застосунок пише туди, що в нього не вийшло, — і це єдине місце, де зараз
видно правду:

```bash
# logs = "show what the application wrote to its output".
#   -l app=passes-api  across all copies with this label at once, not one named copy
#   --tail=20          the last twenty lines of each copy, not the whole log
kubectl logs -l app=passes-api --tail=20
```

```
cache unavailable (redis: NOAUTH Authentication required.), going to the directory
cache unavailable (redis: NOAUTH Authentication required.), going to the directory
```

Ось і відповідь. Ми вказали адресу Redis, але не вказали пароль. Redis вимагає
автентифікації — ви самі ввімкнули `Auth enabled` при створенні, і це правильне
налаштування. Застосунок чесно спробував, отримав відмову, записав це в журнал і пішов у
довідник.

**Чому це не мало вигляду поломки.** Тому що поломки й не було. Застосунок спроєктований
так, щоб переживати недоступність кешу: кеш пришвидшує, але не може бути умовою
працездатності. У бою це рятує — падіння Redis не роняє сервіс. При відлагодженні ця ж
властивість ховає проблему: усе зелене, помилок немає, але не швидше.

**Урок ширший за цю помилку.** Відмова, яка не заважає працювати, — найдорожчий вид
відмови. Вона не піднімає тривоги і живе в проді місяцями. Звідси практичне правило:
**у кожного пришвидшувача має бути спостережувана ознака того, що він працює.** У нас це
поле `cached` у відповіді. Якби його не було, ви б зараз гадали.

У справжній системі на цьому місці стоїть метрика «частка влучень у кеш» і сповіщення на
випадок, якщо вона впала до нуля.

</details>

## Крок 7. Кладемо пароль і міряємо знову

📍 **Де:** на ноутбуці, кластер `lab`.

Пароль від Redis живе в кластері керування, а потрібен він застосунку у вашому. Переносимо —
через змінну оболонки, щоб пароль не потрапив в історію команд:

```bash
# read puts what's typed on the keyboard into the REDIS_PASS variable:
#   -s  don't show what's typed on the screen
#   -r  don't treat a backslash as a special character
# Nothing will appear on screen after this line: paste the password from the dashboard and Enter.
read -rs REDIS_PASS

# create secret generic = an ordinary Secret, a set of key-value pairs.
#   redis-password              the Secret's name in the cluster
#   --from-literal=password=... create a password key in it with this value;
#                               it's the "Secret name + key" pair the patch will reference
kubectl create secret generic redis-password --from-literal=password="$REDIS_PASS"

# unset erases the variable so the password doesn't reach the next commands in this window
unset REDIS_PASS
```

Застосовуємо повний патч. У ньому та сама адреса Redis плюс посилання на щойно створений
Secret і строк життя записів у кеші; розбір — у спойлері одразу після команди.

```bash
# the same address substitution, now in the working patch file

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml

# fix up the existing Deployment with the file's contents and wait for the new copies
kubectl patch deployment passes-api --patch-file cache-patch.yaml
kubectl rollout status deployment/passes-api
```

<details>
<summary><b>Придивімося ближче: що всередині cache-patch.yaml</b></summary>

```yaml
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: REDIS_ADDR
              value: "rfrm-redis-cache.tenant-workshopXX.svc.cozy.local:6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-password
                  key: password
            - name: CACHE_TTL
              value: "60"
```

**Чому патч, а не повний маніфест.** Патч — це «змінити ось це», а не «стан має бути таким».
У файлі видно рівно те, що змінюється, а не двісті рядків, серед яких треба шукати очима
три нові.

**Чому це не затирає решту змінних.** Списки в Kubernetes уміють зливатися за ключем. Для
`env` ключ — поле `name`: три записи з патча додадуться до тих, що вже є, а запис
`REDIS_ADDR` замінить однойменний, що залишився від зламаного патча. Списки контейнерів
зливаються так само, за іменем, — тому `- name: api` обов'язковий, без нього Kubernetes не
зрозуміє, який контейнер ви правите.

**Чому пароль через `secretKeyRef`, а не текстом.** Значення приїжджає із Secret
`redis-password` у момент запуску Pod. У самому маніфесті пароля немає — і це важливо, тому
що маніфест поїде в Git, де він залишиться назавжди. Secret у Git не потрапить.

Чесно: Secret у кластері, як і раніше, лежить у відкритому вигляді, лише в іншому місці. Той,
хто може читати Secret'и в цьому namespace, побачить пароль. Справжнє рішення — зовнішнє
сховище секретів, і це окрема лаба.

**`CACHE_TTL: 60`.** Шістдесят секунд — компроміс. Нижче — читайте наступний спойлер.

</details>

Перевіряємо поштучно, перш ніж навантажувати. Два однакові запити поспіль за
ідентифікатором, якого ще не питали: перший зобов'язаний бути повільним, другий — швидким.

```bash
# the same one-off Pod with curl, but an sh shell is launched inside it:
#   sh -c '...'  run several commands passed as a single string
#   ; echo       insert a line break between the answers so they don't run together
# id=777 is used because this employee hasn't been asked for yet: it's definitely not in the cache.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  sh -c 'curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"; echo;
         curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"'
```

**Що ви маєте побачити** — дві відповіді, і вони різні:

```json
{"cached":false,"took_ms":804, ...}
{"cached":true,"took_ms":1, ...}
```

Перший запит — промах: у кеші порожньо, довелося йти в довідник, 804 мс. Другий —
влучення: відповідь уже лежала, 1 мс.

Тепер замір під навантаженням, та сама команда з тими самими прапорами, третій раз:

```bash
# we change nothing in the bombardment conditions: only what's inside the service changes
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Що ви маєте побачити:**

```
# target 50% 0.0012
# target 90% 0.0021
# target 99% 0.0043
Code 200 : 400 (100.0 %)
```

## Крок 8. Рахуємо вигоду

📍 **Де:** на папірці.

Зберіть три числа в таблицю. Ваші відрізнятимуться — тестове середовище, мережа, сусіди по
вузлу:

| | p50 | p99 | Що це означає для охорони |
|---|---|---|---|
| Без кешу | 801 мс | 812 мс | список із 12 рядків відкривається ~9,6 с |
| Кеш увімкнено, пароля немає | 802 мс | 815 мс | нічого не змінилося |
| Кеш працює | 1,2 мс | 4,3 мс | той самий список — ~0,05 с |

Різниця в **кілька сотень разів**, і це не мовний зворот, а частка двох виміряних чисел.

Зауважте, чого ми **не** робили. Не переписували кадрову систему. Не додавали вузлів. Не
міняли жодного рядка в логіці сервісу «Перепустка» — лише навчили його не питати одне й те саме
двічі. Зміна вмістилася в три змінні оточення.

<details>
<summary><b>Коли кеш не допомагає, і як це побачити заздалегідь</b></summary>

Кеш — не універсальне пришвидшення. Він допомагає за однієї умови: **одне й те саме питання
ставлять багаторазово.** Перевірте себе на трьох випадках.

**Кожен запит унікальний.** Якби список гостей запитував відомості про нового співробітника
щоразу, влучень не було б зовсім, а до кожного запиту додався б похід у Redis. Стало б
повільніше. Переконатися можна так — проженіть дві короткі серії за різними ідентифікаторами
і подивіться на перші запити кожної:

```bash
# two bombardments in a row over different employees, ten seconds each.
# At the start of each series the cache is empty for that key — and the first request goes to the directory.
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=1"
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=2"
```

Перші запити кожної серії — промахи. На великому наборі рідко повторюваних ключів кеш
вироджується в накладні витрати.

**Дані змінюються частіше, ніж TTL.** Якби відомості про співробітника змінювалися кожні
десять секунд, а TTL стояв 60, охорона бачила б застарілі дані до хвилини. Кеш завжди
торгує свіжістю за швидкість, і вирішувати, скільки свіжості не шкода, — не технічне
рішення, а питання до замовника.

**Повільно не завжди, а іноді.** Пам'ятаєте різницю p50 і p99 з першого заміру? Якщо p50
маленький, а p99 величезний, гальмує не джерело даних, а щось плаваюче: збирання сміття,
сусіди по вузлу, блокування в базі. Кеш це замаскує, але не вилікує, і одного дня ви будете
розбиратися з тим самим, тільки на рік пізніше і з кешем поверх.

</details>

<details>
<summary><b>Як обирають TTL</b></summary>

TTL — єдиний справжній параметр кешу, і обирається він не з технічних міркувань.

Питання звучить так: **скільки часу ви готові показувати застарілі дані?**

Для довідника співробітників: прізвище міняють раз на кілька років, відділ — раз на рік.
Вчорашній відділ на прохідній нікому не завадить. TTL міг би бути і година, і доба.

Ми поставили шістдесят секунд, щоб лаба була спостережуваною: почекайте хвилину, повторіть
запит — побачите `cached: false` знову, тому що запис минув і сходив у довідник. З TTL у
добу це довелося б приймати на віру.

Крайні випадки:

| TTL | Що виходить |
|---|---|
| Занадто малий | влучень мало, кеш майже не працює, навантаження на джерело залишилося |
| Занадто великий | швидко, але користувачі бачать вчорашні дані і скаржаться на інше |
| Не заданий зовсім | ключі копляться, пам'ять закінчується, Redis починає викидати що попало |

Останній рядок — найпідступніший. Кеш без TTL з часом перетворюється на базу даних, яку
ніхто не бекапить.

</details>

## Перевірка

📍 **Де:** на ноутбуці, у тому самому вікні термінала, де ви працювали з `kubectl`.

Скрипт ходить в обидва кластери одразу і бере їх зі змінних оточення. Перші дві обов'язкові,
третя — шлях до тенантного кубконфіга.

```bash
cd labs/07-redis

# which cluster to check the application in — your `lab`
export KUBECONFIG=~/lab.kubeconfig
# your tenant number: from it the script assembles the namespace name tenant-workshop03
export COZY_TENANT=workshop03
# where the access to the management cluster lives — there the script looks at Redis itself.
# You can leave it unset: then the script looks for ~/.kube/workshop, and not finding it — skips
# the checks on the management cluster and says so.
export COZY_KUBECONFIG=~/.kube/workshop

./check.sh
```

⚠️ **На Windows скрипт запускається з WSL**, а не з PowerShell — як його поставити, написано
на початку лаби 0. Без WSL лабу можна пройти, але звіту-артефакту не буде.

Скрипт не вірить на слово жодному маніфесту. Він сам робить два запити поспіль за випадковим
ідентифікатором і дивиться: перший має бути промахом і зайняти сотні мілісекунд, другий —
влученням і зайняти одиниці. Різницю він записує у звіт числами. Заодно перевіряє, що
повільний довідник справді повільний: без цього порівняння нічого не значило б.

## Прибирання

Усе знадобиться в наступних лабах — зараз не видаляємо.

Коли закінчите з усіма лабами:

```bash
# delete -f = remove from the cluster exactly the objects described in the files
kubectl delete -f passes-api.yaml -f hr-legacy.yaml -f fortio.yaml
# the Secret was created by a command, not a file — we delete it by name
kubectl delete secret redis-password
```

Сам Redis видаляється через дашборд, як звичайний застосунок.

Видалити кеш — операція дешева й майже безпечна, і це окрема властивість кешів: **у кеші
немає даних, яких немає більше ніде.** Усе, що в ньому лежить, відновлюване походом до
джерела. Втратити Redis означає втратити швидкість на кілька хвилин, поки він наповниться
заново, — але не втратити інформацію. З базою даних так не вийде, і в лабі про базу ви до
цього повернетеся.

## Що ми тепер уміємо

- Заводити керований Redis і пояснювати, що дає реплікація, якої ви не налаштовували
- Вимірювати затримку до і після зміни, а не розмірковувати про неї
- Читати p50 і p99 і розуміти, чому середня затримка обманює
- Обирати TTL виходячи з того, скільки застарівання терпить замовник
- Знаходити відмову, яка не заважає працювати, — найдорожчий вид відмови

## А у vSphere це було б

Аналога в цієї задачі у vSphere немає, і це варто сказати прямо. Кеш — не інфраструктурний
об'єкт, а частина архітектури застосунку. Гіпервізор не вміє кешувати відповіді кадрової
системи і не повинен уміти.

Що робили б у світі віртуальних машин: заявка на віртуалку під Redis, встановлення,
налаштування `requirepass`, налаштування автозапуску, потім — якщо дійдуть руки — друга
віртуалка під репліку, sentinel, перевірка перемикання. Дні роботи, з яких власне кеш
займає пів години, а решта — обв'язка. Звідси й береться звичка, знайома будь-якому
адміністратору: «давайте поки без репліки, потім додамо». Потім не додають.

Різниця не в тому, що тут Redis ставиться швидше. Різниця в тому, що репліка, перемикання
при відмові, метрики й оновлення приїжджають за умовчанням, і «поки без репліки» не виникає
як варіант.

**Де vSphere зручніший, чесно.** Три речі.

**Повний контроль.** На своїй віртуалці ви поставите будь-яку версію Redis, будь-який
модуль, будь-який `maxmemory-policy` і свій скрипт моніторингу поряд. Тут вам доступне лише
те, що виведено в параметри застосунку, — а виведено далеко не все.

**Діагностика.** Коли Redis на віртуалці поводиться дивно, ви заходите по SSH і дивитеся
`redis-cli INFO`, `SLOWLOG`, системні лічильники. Тут SSH немає, і добиратися до тих самих
відомостей доводиться через `kubectl exec` і метрики — довше і з меншою роздільністю.

**Передбачуваність сусідів.** Віртуалка з Redis — це гарантовані ядра й пам'ять, які ви
бачите у vCenter. Керований сервіс живе на спільних вузлах поряд із чужим навантаженням;
ліміти його захищають, але «чому сьогодні на дві мілісекунди повільніше» ви будете
з'ясовувати довше, ніж з'ясували б на виділеній машині.
