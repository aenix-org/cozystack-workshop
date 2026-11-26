# Лабораторна 7 · Кеш перед повільним бекендом

| | |
|---|---|
| **Час** | 50 хвилин, 10 з них — очікування |
| **Що це доводить** | Виграш від кешу вимірюється, а не декларується: було 800 мс, стало — одиниці |
| **Що знадобиться** | Кластер із лабораторної 0, Harbor і образ із лабораторної 6, `kubectl`, `docker`, доступ до дашборда |

> ⚠️ **`workshopXX` — це заповнювач, а не назва.** Підставте власний номер тенанта, інакше
> команда піде в чужий тенант і ви отримаєте відмову в доступі — або, гірше,
> чужі дані. Свій номер ви отримали разом із паролем.

## Чому це важливо

Сервіс «Перепустки» працює, безпека задоволена, реєстр — власний. А потім приходить охорона.

> На КПП список гостей відкривається десять секунд. Люди стоять у черзі, ми
> дивимось в екран і чекаємо. Раніше було нормально.

Ось що відбувається. Кожен рядок списку — це гість, у кожного гостя є співробітник, який
його запросив, а записи про співробітників живуть не у вас. Вони живуть у HR-системі,
встановленій ще у 2011 році, і на запит вона відповідає **800 мілісекунд**. Дванадцять рядків
на екрані — майже десять секунд.

Переписати HR-систему ви не можете: вона не ваша, вона належить іншим, і черга змін до неї
розписана до наступного року. Пришвидшити її теж не можете, з тієї самої причини.

Що ви можете — так це перестати питати її так часто. Прізвище і відділ співробітника змінюються
приблизно раз на кілька років. Питати повільну систему про них **щоразу**, коли відкривається
список, — марнотратство: досить спитати один раз і запам’ятати відповідь.

Місце, де запам’ятовуються відповіді, називається кешем. Сьогодні ми його поставимо — і, що
важливіше, **виміряємо різницю до і після**. Не «стало швидше», а конкретне число.

## Міні-глосарій

| Термін | Що це | Схоже на… але |
|---|---|---|
| **Кеш** | Швидке сховище готових відповідей на повторювані питання | **кеш читання на масиві сховища**, але тут застосунок вирішує, що кешувати, а не пристрій |
| **Redis** | Сховище «ключ — значення», що цілком тримається в оперативній пам’яті | прямого аналога немає; найближче — memcached, якщо ви з ним стикались |
| **Ключ** | Рядок, за яким у кеші шукається значення | **ім’я файлу**, але ви його вигадуєте, і все залежить від того, як ви це робите |
| **TTL (time to live)** | Скільки запис живе, перш ніж сам зникне | **строк зберігання знімка**, але видалення відбувається без нічиєї участі і без запланованого завдання |
| **Промах (cache miss)** | Відповіді немає в кеші, доводиться йти в повільне джерело | **промах кешу читання на масиві сховища**, але промах тут коштує не мілісекунд, а походу в чужу систему |
| **Влучання (cache hit)** | Відповідь знайшлась у кеші | **влучання кешу читання**, але застосунок рахує влучання, і воно теж видно у відповіді, в полі `cached` |
| **Sentinel** | Сервіс, який стежить за Redis і перепризначає роль лідера при збої | **HA-агент**, але він працює всередині самого Redis, окремий кластер для нього не потрібен |
| **Керований сервіс** | Сервіс, який платформа встановлює, оновлює і резервує замість вас | ви не отримуєте root на машині, де він працює, — і в цьому суть |
| **Fortio** | Генератор навантаження з вебінтерфейсом і гістограмою затримок | у vSphere аналога немає: це інструмент не для вимірювання інфраструктури, а для вимірювання сервісу |
| **p50 / p99** | Медіана і «найгірші відсотки»: у 99% запитів затримка не вища за це число | середня затримка оманлива, ці два числа — ні |

## Два kubeconfig: не переплутайте їх

У цій лабораторній знову два кластери.

| Kubeconfig | Що це | Що ми в ньому робимо |
|---|---|---|
| `~/.kube/config` | Кластер керування Cozystack, ваш тенант | дивимось на Redis: адреса, стан |
| `~/lab.kubeconfig` | **Ваш** кластер `lab` із лабораторної 0 | розгортаємо застосунок і вимірюємо |

Обидва беруться з дашборда: тенантський — із Secret `kubeconfig-tenant-workshopXX` на вкладці
Secrets, кластерний — із розділу доступу вашого кластера `lab`.

⚠️ **Перед кожним блоком команд написано, куди він адресований.** Якщо щось поводиться
дивно, перше, що треба зробити, — `echo $KUBECONFIG`.

## Що лежить у теці лабораторної

Усі файли у вас уже є — ви взяли їх разом із репозиторієм. Нічого створювати чи набирати
заново не треба: усюди, де нижче написано `kubectl apply -f name.yaml`, файл береться звідси.

```bash
# all commands in this lab run from the lab folder — switch into it
cd labs/07-redis
```

| Файл | Що це | Коли стане у пригоді |
|---|---|---|
| `app/` | Вихідники сервісу «Перепустки», версія з кешем | ви збираєте його локально, `docker build` |
| `hr-legacy.yaml` | Заглушка застарілого довідника: відповідає повільно, як справжній | ви застосовуєте його на своєму кластері `lab` |
| `passes-api.yaml` | Сервіс «Перепустки» без кешу — спершу вимірюємо, наскільки це погано | ви застосовуєте його туди ж |
| `cache-patch-broken.yaml` | **Навмисно неповний** патч, який вмикає кеш | ви застосовуєте його, щоб побачити помилку |
| `cache-patch.yaml` | Робочий патч. Патч, а не повний маніфест: ви бачите саме те, що змінюється | ви застосовуєте його після розбору |
| `fortio.yaml` | Генератор навантаження для вимірювань до і після | ви застосовуєте його туди ж |
| `check.sh` | Перевірка, що другий запит на порядок швидший за перший | ви запускаєте її наприкінці лабораторної |

## Крок 1. Зібрати версію v2 і надіслати її у власний реєстр

📍 **Де:** на бастіоні (у терміналі бастіона).

Тека `app/` містить вихідний код. Від версії попередньої лабораторної він відрізняється двома
речами: режимом «повільного довідника» і обробкою кешу.

<details>
<summary><b>Пильніший погляд: що всередині app/</b></summary>

**Один образ, дві ролі.** Змінна `MODE` визначає, чим запускається процес:

| `MODE` | Що це | Що робить |
|---|---|---|
| `hr` | заглушка застарілого довідника | спить `HR_DELAY` (за замовчуванням 800 мс) і повертає дані співробітника |
| `api` | сам сервіс «Перепустки» | іде в довідник, а якщо задано `REDIS_ADDR` — спершу в кеш |

Два образи замість одного означали б два місця, де можна забути оновити версію.

**Як влаштований похід за даними.** Уся логіка кешування — це близько двадцяти рядків:

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

Зверніть увагу на першу гілку: **якщо кеш недоступний, застосунок не падає.** Він
пише в лог і йде в довідник — повільно, але правильно. Це не оздоблення, це
обов’язкова властивість будь-якого кешу: кеш пришвидшує, але не може бути умовою
працездатності. Якщо сервіс падає разом із кешем, ви побудували не кеш, а ще
одну точку відмови.

З цієї властивості, до речі, трохи далі в лабораторній виросте передбачувана відмова.
Застосунок, який мовчки продовжує працювати, приємний у продакшені й підступний під час зневадження.

**Ключ.** `employee:42` — назва сутності, двокрапка, ідентифікатор. Двокрапка тут не синтаксис
Redis, а широко прийнята звичка: вона дозволяє потім шукати за шаблоном `employee:*` і не
плутати свої ключі з чужими, коли два застосунки живуть в одному Redis.

**Час життя задається тією ж командою, що й запис:**

```go
r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
```

Не `SET`, а потім `EXPIRE` двома командами. Між двома командами з’єднання може обірватися — і
ключ залишиться в кеші назавжди. Такі ключі потім місяцями виловлюють.

**Клієнт Redis тут власний, п’ятдесят рядків.** Протокол Redis текстовий, і для `GET`
і `SET` він вміщується в одну функцію. У справжньому проєкті ви взяли б готову бібліотеку —
вона займається пулом з’єднань, повторами і sentinel. Тут власний потрібен саме для того, щоб
у збірки не було зовнішніх залежностей: згадайте, з чого починалась попередня лабораторна.

**Окремий HTTP-клієнт зі збільшеним пулом з’єднань:**

```go
tr := http.DefaultTransport.(*http.Transport).Clone()
tr.MaxIdleConnsPerHost = 64
```

Без цього рядка під навантаженням половина часу йшла б на встановлення TCP-з’єднань до
довідника, і вимірювання показувало б не затримку довідника, а нашу власну недбалість.
Перше правило вимірювання: переконайтеся, що вимірюєте саме те, що думаєте.

</details>

Зберіть його і надішліть у свій Harbor. `build` збирає образ із `Dockerfile` і лишає
його на бастіоні, `push` відправляє його в реєстр. Ім’я образу таке саме, як у попередній
лабораторній, але тег інший — `v2`: у реєстрі тепер лежатимуть обидві версії, і стара
нікуди не подінеться.

Підставте власну адресу:

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

⚠️ **`--platform linux/amd64` обов’язковий, якщо у вас Mac на Apple Silicon або ВМ на
ARM.** Без нього образ збереться під ARM, запушиться без помилок, а в кластері дасть
`CrashLoopBackOff` з `exec format error` у логах.

## Крок 2. Розгорнути довідник і сервіс

📍 **Де:** на бастіоні, кластер `lab`.

В обох маніфестах замість адреси реєстру стоїть заповнювач `HARBOR-HOST`: `sed`
замінює його, редагуючи файли на місці. Далі `apply` віддає кластеру те, що описано у
файлах, а `rollout status` чекає, поки копії піднімуться.

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

⚠️ Обидва маніфести посилаються на Secret `harbor` — той самий `imagePullSecret` із попередньої
лабораторної. Якщо ви його не зробили, Pod’и опиняться в `ImagePullBackOff`. Щоб створити Secret:

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

Перевіримо, що ланцюжок працює. Сервіс видно лише зсередини кластера, тому запит ми робимо
теж звідти: піднімаємо одноразовий Pod з `curl`, він питає сервіс `passes-api`,
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
{"cache":"off","cached":false,"dept":"Logistics","id":"42","name":"Popova E. K.",
 "pod":"passes-api-6f8b9c7d5-x2ktm","took_ms":803,"ttl_s":60}
```

Ключові поля: `cache: off` — кешу немає, `took_ms: 803` — ось вони, ваші вісімсот
мілісекунд. Це те саме число, яке ми збираємось зменшити.

## Крок 3. Виміряти, наскільки погано зараз

📍 **Де:** на бастіоні, кластер `lab`.

Один запит — це не вимірювання. Потрібне навантаження, схоже на справжнє, і розподіл затримок.

Розгорніть генератор. Він піднімається як звичайний застосунок і живе в кластері поряд із
сервісом — так вимірювання не залежить від вашого інтернету чи від тунелю:

```bash
# the file has two objects: the generator itself and a service for it
kubectl apply -f fortio.yaml
kubectl rollout status deployment/fortio
```

Тепер запускаємо навантаження. Команда `kubectl exec` виконує щось усередині вже
запущеного Pod’а — тут, усередині генератора, запускається сам генератор, у режимі бомбардування:

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

**Що ви маєте побачити** — наприкінці виводу гістограма і рядки з перцентилями:

```
# target 50% 0.801
# target 90% 0.806
# target 99% 0.812
Code 200 : 400 (100.0 %)
```

**Запишіть ці числа.** За десять хвилин вони знадобляться для порівняння, а пам’ять
влаштована так, що «ну, було десь вісімсот» перетворюється на «ну, було десь пів секунди».

### Те саме мишкою

Мишкою — це не дашборд Cozystack: він працює з кластером керування і показує
записи каталогу тенанта, але не заглядає всередину вашого кластера `lab`. У самого генератора
є свій вебінтерфейс, і до нього треба дістатися через тунель.

```bash
# port-forward svc/fortio = a tunnel from the bastion to the generator's service in the cluster
#   8081:8080 — the left number is the port on your bastion, the right one the service port in the cluster
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

Натисніть **Start**. Унизу намалюється гістограма затримок. Вона наочніша за числа:
видно, що всі запити зібрались в одну вузьку смугу біля 800 мс — тобто повільно не
«іноді», а завжди й на одну й ту саму величину.


<details>
<summary><b>Чому p50 і p99, а не середня затримка</b></summary>

Середня затримка — найоманливіша метрика в експлуатації.

Уявіть: дев’яносто запитів по 10 мс і десять запитів по 2000 мс. Середнє — 209 мс, і за
звітом усе виглядає пристойно. Але насправді кожен десятий користувач чекав дві секунди й пішов.

**p50 (медіана)** — половина запитів швидша за це число, половина повільніша. Вона відповідає на
питання «скільки чекає звичайний користувач».

**p99** — 99% запитів швидші за це число. Воно відповідає на питання «наскільки погано буває».
Саме p99 визначає, чи скаржитиметься охорона на КПП: люди скаржаться не
на середнє, а на той один раз, коли довелось чекати.

У нашому вимірюванні p50 і p99 майже збіглися — 801 і 812 мс. Це ознака того, що повільність не
випадкова, а системна: повільно рівно завжди. Це лікується кешем. Якби p50 був 10 мс, а p99 —
2000 мс, причина була б інша, і кеш би не допоміг.

</details>

## Крок 4. Створити Redis

📍 **Де:** у браузері, у дашборді Cozystack. Redis — спільний ресурс тенанта, як Harbor.

Тенант → **Create application** → `Redis`.

| Поле | Значення | Чому так |
|---|---|---|
| Name | `cache` | воно йде в імена сервісів, коротше — зручніше |
| Replicas | `2` | одна лідерська копія і одна відомча: побачимо, що це дає |
| Size | `1Gi` | довідник співробітників уміститься в пам’яті з великим запасом |
| Storage class | `replicated` | |
| Resources preset | лишіть запропонований | |
| Version | `v8` | |
| Auth enabled | **увімкнено** (за замовчуванням) | платформа сама генерує пароль |
| External | **вимкнено** | немає причин виставляти цей кеш назовні |

Розраховуйте почекати три-п’ять хвилин, поки він буде готовий.

⚠️ **Цей Redis не має нічого спільного з Redis, який ви могли бачити у формі створення Harbor.**
Там це власний внутрішній кеш реєстру. Цей — ваш власний, для вашого застосунку.

<details>
<summary><b>Чим керований Redis відрізняється від Redis, встановленого на ВМ</b></summary>

Встановити Redis на віртуальну машину — робота на пів години: `apt install redis`, підправити `bind`
і `requirepass`, увімкнути автозапуск. Саме тому керований сервіс здається надмірним.
Різниця не в установці, а в тому, що відбувається потім.

**Реплікація.** Ви задали `replicas: 2` — і отримали дві копії даних на різних вузлах плюс
три sentinel, які за ними стежать. Якщо вузол з лідерською копією помирає, sentinel проводять
вибори і роблять лідером другу копію. Застосунок переживе це з паузою в
кілька секунд. Зібрати те саме руками — день роботи, а потім іще день, щоб перевірити, що воно
справді робить failover, а не просто виглядає налаштованим.

**Оновлення.** Вразливість у Redis — не рідкість. На ВМ оновлення означає `apt upgrade`, перезапуск
і надію, що конфіг переживе зміну мажорної версії. Тут оновлення образу приходить разом
з оновленням платформи, і порядок перезапуску копій влаштований так, щоб сервіс
не зникав.

**Спостережуваність.** Метрики вже збираються: поряд із кожною копією працює
експортер, графіки є без жодних зусиль з вашого боку. На ВМ це ще один пакет, ще один
конфіг і ще одна річ, про яку забули.

**Від чого ви відмовляєтесь.** Чесно: root на машині з Redis. Ви не зайдете по SSH, не відредагуєте
конфіг руками, не покладете поряд свій скрипт. Усе, що не винесено як
параметр застосунку, для вас недосяжне — а винесено далеко не все. Якщо вам потрібна
нестандартна `maxmemory-policy` чи модуль Redis, керований сервіс вам цього не дасть, і
доведеться ставити свій на ВМ. Це реальне обмеження, а не дрібниця.

</details>

## Крок 5. Знайти адресу Redis і перевірити зв’язність

📍 **Де:** на бастіоні, **кластер керування**.

Redis живе у вашому тенанті на кластері керування, а застосунок — у вашому кластері `lab`.
Це два різні кластери, і перше, що треба зробити, — переконатися, що другий може дістатися
до першого.

Подивимось, які сервіси з’явились:

```bash
# --kubeconfig sets the access file right in the command — just once, without touching KUBECONFIG.
# This way two commands in a row can be addressed to different clusters without getting confused.
#   -n tenant-workshopXX  the namespace of your tenant
#   get svc               "show the services" — permanent addresses backed by Pods
#   | grep redis          keep only the lines with the word redis in the output
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX get svc | grep redis
```

**Що ви маєте побачити** — кілька сервісів із промовистими префіксами:

| Ім’я | Що за ним |
|---|---|
| `rfrm-redis-cache` | лідерська копія (master) — сюди пишуть і звідси читають |
| `rfrs-redis-cache` | відомчі копії (replicas) — тільки читання |
| `rfs-redis-cache` | sentinel — сервіс, що стежить і перемикає ролі |

⚠️ **Звідки в іменах зайве `redis-`.** Платформа додає до імені застосунку префікс із
типом сервісу: застосунок `cache` типу Redis усередині зветься `redis-cache`.
Звідси `rfrm-redis-cache`, а не `rfrm-cache`. Не вгадуйте імена — дивіться на вивід
команди вище, це джерело істини.

Нам потрібен `rfrm-redis-cache`: кеш і пише, і читає, а писати можна лише в лідерську копію.

Повне ім’я, за яким його видно з вашого кластера, збирається так:

```
rfrm-redis-cache.tenant-workshopXX.svc.cozy.local
```

Візьміть пароль. 📍 **Де:** у дашборді, застосунок `cache`, вкладка secrets. Вам
потрібен Secret `redis-cache-auth`, ключ `password`.

Тепер — перевірка зв’язності. 📍 **Де:** на бастіоні, кластер **`lab`**.

У вашому кластері піднімаємо одноразовий Pod з клієнтом Redis і просимо його сказати слово `ping`
до Redis. Якщо відповідь повертається, то кеш у тенанті видно з кластера `lab` —
і це єдине, що ми зараз перевіряємо.

⚠️ **Пароль ми передаємо через змінну `REDISCLI_AUTH`, а не через прапорець `-a`.** Усе, що
потрапляє в аргументи команди, видно в списку процесів на вузлі й лишається в описі
Pod’а — а його може прочитати будь-хто з доступом до вашого namespace. `redis-cli`
сам про це попереджає, і глушити попередження замість того, щоб усунути причину, — погана звичка.

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

⚠️ **Якщо замість `PONG` ви отримали помилку резолву імені** — то внутрішні імена
кластера керування не видно з вашого кластера. Це лікується зверненням за IP:

```bash
# -o jsonpath='{.spec.clusterIP}' — print one field of the object: the internal address
# the platform assigned to this service. {"\n"} adds a line break.
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX get svc rfrm-redis-cache \
  -o jsonpath='{.spec.clusterIP}{"\n"}'
```

Далі всюди підставляйте отриману адресу замість імені. Працюватиме так само;
єдиний мінус — якщо Redis перестворити, адреса зміниться, а ім’я — ні. Якщо
й за адресою не відповідає — напишіть у чат воркшопу, це проблема конфігурації
тестового середовища, а не ваша помилка.

## Крок 6. Увімкнути кеш

📍 **Де:** на бастіоні, кластер `lab`.

Ми змінюємо застосунок не цілим маніфестом, а патчем — так ви бачите саме те,
що змінюється. Спершу підставляємо адресу вашого Redis у патч, потім віддаємо патч
кластеру: `kubectl patch` додає зміни до вже наявного об’єкта, а не замінює
його цілком.

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

Виміряємо знову — тією ж командою, якою вимірювали до ввімкнення кешу. Умови
бомбардування мають збігатися до останнього прапорця, інакше не буде що порівнювати:

```bash
# the same twenty requests per second, the same twenty seconds, the same sixteen connections
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

> **Зупиніться і подумайте, перш ніж читати далі.**
>
> Числа не змінились: ті самі вісімсот мілісекунд. І при цьому жоден Pod не
> впав, у відповідях немає помилок, кожен запит повернув `200`. Redis створено,
> адреса правильна — ви щойно отримали від нього `PONG`.
>
> Куди дивитись?

<details>
<summary><b>Відповідь і урок, ширший за цю помилку</b></summary>

Спершу подивіться, що відповідає сам застосунок: у відповіді є поля, які показують, чи
кеш увімкнено і чи прийшла відповідь із нього.

```bash
# the same one-off Pod with curl as before: we ask the service from inside the cluster
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

```json
{"cache":"redis","cached":false,"took_ms":802, ...}
```

`cache: redis` — кеш увімкнено. `cached: false` — і все ж відповідь прийшла не з нього. І
воно **завжди** false, скільки б разів ви не повторювали.

Тепер лог. Застосунок пише туди те, чого не зміг зробити — і це єдине місце, де
істина зараз видна:

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

Ось і відповідь. Ми вказали адресу Redis, але не пароль. Redis вимагає
автентифікації — ви самі ввімкнули `Auth enabled` при створенні, і це правильне налаштування.
Застосунок чесно спробував, отримав відмову, записав це в лог і пішов у довідник.

**Чому це не виглядало як поломка.** Тому що поломки не було. Застосунок
спроєктований так, щоб пережити недоступність кешу: кеш пришвидшує, але не може бути
умовою працездатності. У продакшені це вас рятує — падіння Redis не тягне за собою
сервіс. Під час зневадження ця сама властивість ховає проблему: усе зелене, помилок
немає, але не швидше.

**Урок ширший за цю помилку.** Відмова, яка не заважає працювати, — це
найдорожчий вид відмови. Вона не здіймає тривоги і живе в продакшені місяцями. Звідси
практичне правило: **у кожного прискорювача має бути спостережувана ознака того, що він працює.** Для нас це
поле `cached` у відповіді. Якби його не було, ви б зараз гадали.

У справжній системі в цьому місці є метрика «cache hit ratio» і алерт на випадок, якщо вона впаде до нуля.

</details>

## Крок 7. Вставити пароль і виміряти знову

📍 **Де:** на бастіоні, кластер `lab`.

Пароль Redis живе в кластері керування, а застосунку він потрібен у вашому. Ми
переносимо його — через змінну оболонки, щоб пароль не потрапив в історію команд:

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

Застосуйте повний патч. У ньому та сама адреса Redis плюс посилання на щойно створений Secret і
час життя записів кешу; розбір — у спойлері одразу після команди.

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
<summary><b>Пильніший погляд: що всередині cache-patch.yaml</b></summary>

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

**Чому патч, а не повний маніфест.** Патч — це «зміни оце», а не «стан має бути такий-от».
У файлі ви бачите саме те, що змінюється, а не двісті рядків, серед яких доводиться
очима вишукувати три нові.

**Чому це не затирає інші змінні.** Списки в Kubernetes уміють зливатися за ключем. Для `env`
ключ — це поле `name`: три записи з патча додаються до тих, що вже є, а
запис `REDIS_ADDR` замінює однойменний, що лишився від зламаного патча. Списки контейнерів
зливаються так само, за іменем — тому `- name: api` обов’язковий; без нього Kubernetes
не зрозуміє, який контейнер ви редагуєте.

**Чому пароль через `secretKeyRef`, а не текстом.** Значення приходить із
Secret `redis-password` у момент старту Pod’а. У самому маніфесті пароля немає —
і це важливо, бо маніфест піде в Git, де лишився б назавжди. Secret
у Git не потрапить.

Чесно: Secret у кластері все одно лежить у відкритому вигляді, просто в іншому місці. Будь-хто, хто
може читати Secret’и в цьому namespace, побачить пароль. Справжнє рішення — зовнішнє
сховище секретів, і це окрема лабораторна.

**`CACHE_TTL: 60`.** Шістдесят секунд — компроміс. Нижче — читайте наступний спойлер.

</details>

Перевіримо по одному, перш ніж давати навантаження. Два однакові запити поспіль для
ідентифікатора, який ще не питали: перший неодмінно повільний, другий — швидкий.

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

Перший запит — промах: кеш був порожній, довелось іти в довідник, 804 мс. Другий
— влучання: відповідь уже була там, 1 мс.

Тепер вимірювання під навантаженням, та сама команда з тими самими прапорцями, втретє:

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

## Крок 8. Підбити виграш

📍 **Де:** на клаптику паперу.

Зберіть три числа в таблицю. Ваші відрізнятимуться — тестове середовище, мережа, сусіди
на вузлі:

| | p50 | p99 | Що це означає для охорони |
|---|---|---|---|
| Без кешу | 801 мс | 812 мс | список із 12 рядків відкривається за ~9,6 с |
| Кеш увімкнено, без пароля | 802 мс | 815 мс | нічого не змінилось |
| Кеш працює | 1,2 мс | 4,3 мс | той самий список — ~0,05 с |

Різниця — **у кілька сотень разів**, і це не фігура мови, а частка
двох виміряних чисел.

Зверніть увагу, чого ми **не** робили. Ми не переписували HR-систему. Ми не додавали вузлів. Ми не
змінили жодного рядка в логіці сервісу «Перепустки» — ми лише навчили його не питати те саме
двічі. Зміна вмістилась у три змінні оточення.

<details>
<summary><b>Коли кеш не допомагає і як побачити це заздалегідь</b></summary>

Кеш — не універсальне прискорення. Він допомагає за однієї умови: **те саме питання ставиться багато
разів.** Перевірте себе на трьох випадках.

**Кожен запит унікальний.** Якби список гостей щоразу запитував інформацію про нового співробітника,
влучань не було б зовсім, а до кожного запиту додався б похід у Redis. Стало б
повільніше. Підтвердити це можна так — запустіть дві короткі серії по різних ідентифікаторах і подивіться
на перші запити кожної:

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

**Дані змінюються частіше, ніж TTL.** Якби інформація про співробітника змінювалась кожні десять
секунд, а TTL був заданий на 60, охорона бачила б застарілі дані до хвилини. Кеш
завжди міняє свіжість на швидкість, а вирішувати, скільки свіжості ви можете віддати, — це не технічне
рішення, а питання до замовника.

**Повільно не завжди, а іноді.** Пам’ятаєте різницю між p50 і p99 з першого
вимірювання? Якщо p50 малий, а p99 величезний, то повільне не джерело даних, а щось
періодичне: збирання сміття, сусіди на вузлі, блокування в базі. Кеш це замаскує,
але не вилікує, і одного дня ви розплутуватимете те саме, тільки на рік пізніше і
з кешем зверху.

</details>

<details>
<summary><b>Як обирається TTL</b></summary>

TTL — єдиний реальний параметр кешу, і обирається він не з технічних міркувань.

Питання звучить так: **скільки ви готові показувати застарілі дані?**

Для довідника співробітників: прізвище змінюється раз на кілька років, відділ — раз на рік.
Вчорашній відділ на КПП нікого не потурбує. TTL цілком міг би бути й
годиною, і добою.

Ми задали шістдесят секунд, щоб лабораторна була спостережуваною: почекайте хвилину, повторіть запит — побачите
`cached: false` знову, бо запис протермінувався і пішов у довідник. З TTL у добу
довелось би вірити на слово.

Крайні випадки:

| TTL | Що виходить |
|---|---|
| Замалий | мало влучань, кеш ледь працює, навантаження на джерело лишається |
| Завеликий | швидко, але користувачі бачать учорашні дані й скаржаться на щось інше |
| Не заданий взагалі | ключі накопичуються, пам’ять закінчується, Redis починає витісняти будь-що |

Останній рядок — найпідступніший. Кеш без TTL з часом перетворюється на базу даних, яку ніхто
не резервує.

</details>

## Перевірка

📍 **Де:** на бастіоні, у тому самому вікні термінала, де ви працювали з `kubectl`.

Скрипт іде в обидва кластери одразу й бере їх зі змінних оточення. Перші дві
обов’язкові, третя — шлях до тенантського kubeconfig.

```bash
cd labs/07-redis

# which cluster to check the application in — your `lab`
export KUBECONFIG=~/lab.kubeconfig
# your tenant number: from it the script assembles the namespace name tenant-workshop03
export COZY_TENANT=workshop03
# where the access to the management cluster lives — there the script looks at Redis itself.
# You can leave it unset: then the script looks for ~/.kube/config, and not finding it — skips
# the checks on the management cluster and says so.
export COZY_KUBECONFIG=~/.kube/config

./check.sh
```

⚠️ **У Windows скрипт запускається з WSL**, а не з PowerShell — як його встановити, написано на
початку лабораторної 0. Без WSL лабораторну все одно можна пройти, але звіту-артефакту не буде.

Скрипт не вірить на слово жодному маніфесту. Він сам робить два запити поспіль для
випадкового ідентифікатора і стежить: перший має бути промахом і зайняти сотні мілісекунд, другий
— влучанням і зайняти одиниці. Різницю він записує у звіт числами. Дорогою
перевіряє, що повільний довідник справді повільний: без цього порівняння нічого б не значило.

## Прибирання

Усе знадобиться в наступних лабораторних — зараз ми нічого не видаляємо.

Коли завершите всі лабораторні:

```bash
# delete -f = remove from the cluster exactly the objects described in the files
kubectl delete -f passes-api.yaml -f hr-legacy.yaml -f fortio.yaml
# the Secret was created by a command, not a file — we delete it by name
kubectl delete secret redis-password
```

Сам Redis видаляється через дашборд, як звичайний застосунок.

Видалення кешу — дешева й майже безпечна операція, і це окрема властивість кешів:
**кеш не тримає даних, яких немає більше ніде.** Усе, що в ньому, можна відновити походом
у джерело. Втратити Redis означає втратити швидкість на кілька хвилин, поки він знову
наповнюється, — але не втратити інформацію. З базою даних так не вийде, і в лабораторній про базу ви
повернетесь до цього.

## Що ми тепер вміємо

- Розгорнути керований Redis і пояснити, що дає реплікація, яку ви не налаштовували
- Вимірювати затримку до і після зміни, а не говорити про неї
- Читати p50 і p99 і розуміти, чому середня затримка обманює
- Обирати TTL, виходячи з того, скільки застарілості терпить замовник
- Знайти відмову, яка не заважає працювати, — найдорожчий вид відмови

## А в vSphere це було б

Аналога цієї задачі у vSphere немає, і це варто сказати прямо. Кеш — не
інфраструктурний об’єкт, а частина архітектури застосунку. Гіпервізор не може кешувати відповіді
HR-системи і не повинен уміти.

Що ви робили б у світі віртуальних машин: запит на ВМ для Redis, встановлення,
налаштування `requirepass`, налаштування автозапуску, потім — якщо дійдуть руки — друга ВМ для
репліки, sentinel, перевірка failover. Дні роботи, з яких власне кеш займає пів
години, а решта — це риштування. Звідси й береться звичка, знайома будь-якому
адміністратору: «давай поки без репліки, додамо потім». Потім не додають.

Різниця не в тому, що Redis тут ставиться швидше. Різниця в тому, що репліка, failover,
метрики й оновлення приходять за замовчуванням, а «поки без репліки» взагалі не постає як варіант.

**Де vSphere зручніший, чесно.** Три речі.

**Повний контроль.** На власній ВМ ви можете встановити будь-яку версію Redis, будь-який модуль, будь-яку
`maxmemory-policy` і свій скрипт моніторингу поряд. Тут у вас доступ лише до того, що
винесено як параметри застосунку — а винесено далеко не все.

**Діагностика.** Коли Redis на ВМ поводиться дивно, ви заходите по SSH і дивитесь на `redis-cli INFO`,
`SLOWLOG`, системні лічильники. Тут SSH немає, і дістатися до тієї самої інформації доводиться
через `kubectl exec` і метрики — повільніше і з нижчою роздільністю.

**Передбачуваність сусідів.** ВМ з Redis означає гарантовані ядра й пам’ять, які ви бачите в
vCenter. Керований сервіс живе на спільних вузлах поряд із чужим навантаженням; ліміти захищають
його, але «чому сьогодні на дві мілісекунди повільніше» ви розбиратимете довше, ніж це було б
на виділеній машині.
