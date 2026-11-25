# Воркшоп: антифрод для карточных платежей в реальном времени на собственном облаке

Примерно за два часа вы построите работающую систему обнаружения мошенничества с картами в реальном времени, а затем прогоните её так, как банк гоняет продакшен: через всплеск трафика, потерю ноды базы данных и переезд сервера посреди потока платежей.

Всё работает на [Cozystack](https://cozystack.io) — открытой платформе из CNCF, которая превращает обычные серверы в частное облако. Вы работаете через общую ВМ, бастион, так что вам нужен только ноутбук с терминалом и браузером.

[English version](README.md)

## Легенда

Каждый раз, когда картой расплачиваются, терминал магазина задаёт банку-эмитенту один вопрос: одобрить или отклонить? Программа, которая принимает эти запросы, называется **свитч** (card authorization switch, процессинговый коммутатор). В большинстве банков он старый, работает на виртуальной машине, и трогать его никто не хочет. Наш ничем не лучше: он живёт на ВМ в вашем тенанте и одобряет всё, что меньше $5 000. Для мошеннической группировки — подарок.

Переписывать свитч вы не будете. Вы построите антифрод вокруг него:

```
  card terminals ──► switch (VM, legacy) ──► Kafka: auth.requests ──► scorer (your Kubernetes)
                        ▲   │                                           │  card history in Redis
                        │   │                Kafka: auth.decisions ◄────┘
                        └───┘ approve / decline in milliseconds;
                            │ no answer in 400 ms → the switch decides alone ("stand-in")
                            ▼
                     Kafka: auth.journal ──► cases ──► PostgreSQL ──► dashboard
                                               │
                                               └──► explainer: a small language model
                                                    in your cluster, "why was this blocked?"
```

| Компонент | Где работает | Что делает |
|---|---|---|
| switch | ВМ в вашем тенанте | отвечает терминалам; спрашивает scorer или решает сам — режим стенд-ин (stand-in) |
| Kafka | сервис из каталога | переносит каждый запрос авторизации, каждое решение и каждую запись журнала |
| Redis | сервис из каталога | помнит недавнюю активность каждой карты: как часто, где и на какие суммы |
| PostgreSQL | сервис из каталога, две реплики | база кейсов: каждая транзакция и каждое срабатывание |
| scorer, cases, dashboard | ваш собственный кластер Kubernetes | принимают решения, записывают, показывают |
| explainer | ваш собственный кластер Kubernetes | Qwen2.5 0.5B на CPU пишет простое объяснение для каждой блокировки |
| terminals | ваш собственный кластер Kubernetes | магазины по всем США, которые присылают обычные платежи |

Исходный код всех компонентов лежит в [`app/`](app/). Правила скоринга и их веса собраны в одном коротком файле — [`app/internal/scoring/rules.go`](app/internal/scoring/rules.go).

## Маршрут

| Часть | Что делаете | Минуты |
|---|---|---|
| 0 | Осматриваемся | 15 |
| 1 | Заказываем сервисы данных: GUI, YAML по документации и Git | 30 |
| 2 | Антифрод-скоринг | 25 |
| 3 | Расширяем систему каталогом | 30 |
| 4 | Продакшен-день | 30 |

Маршрут занимает 130 минут — чуть больше двух часов.

## Что выдал ведущий

У вас один логин (`austinNN`) и один пароль, одинаковые для бастиона и GitLab. Файл с учётными данными лежит на бастионе: `~/credentials.txt`.

| Куда | Адрес |
|---|---|
| Бастион | `ssh austinNN@<bastion-address>` |
| Дашборд Cozystack | https://dashboard.workshop.aenix.io |
| GitLab | https://gitlab.workshop.aenix.io |
| Антифрод-дашборд, после части 2 | `https://fraud.austinNN.workshop.aenix.io` |

Во всём тексте ниже `austinNN` — это ваш собственный логин. На бастионе всё уже заполнено вашим номером.

Ведущий подготовил ваш тенант `tenant-austinNN`: ВМ со старым свитчем и ваш собственный кластер Kubernetes `fraud`. В неймспейсе `fraud` вашего кластера карточные терминалы отправляют свитчу 20 платежей в секунду. Ваши материалы лежат в `~/workshop`: этот README, `manifests/` и `app/`.

Ваш репозиторий GitLab `austinNN/fraud-infra` уже склонирован в `~/fraud-infra`. В нём — `platform/kubernetes.yaml` с декларацией вашего кластера и `platform/switch-vm.yaml` со свитчем. Flux работает на платформе от имени вашего тенанта: он применяет `platform/` из ветки `main` в течение минуты после пуша, с правами вашего тенанта. Каждое приложение Cozystack, которое вы закажете, в итоге окажется в этом репозитории. В упражнениях с GUI вы сначала создаёте приложение в дашборде, а затем добавляете его декларацию в Git.

## Часть 0. Осматриваемся (15 мин)

### 0.1 Входим и находим свой тенант

📍 Сначала на своём ноутбуке, затем на бастионе.

```bash
ssh austinNN@<bastion-address>
cd ~/workshop
ls
```

**Вы должны увидеть:** материалы воркшопа, включая `README.md`, `manifests/` и `app/`.

У вас два контекста kubectl, по одному на каждый уровень облака:

| Контекст | С чем говорит | Что там живёт |
|---|---|---|
| `tenant` (по умолчанию) | Cozystack | ваш тенант: ВМ, сервисы из каталога и сам кластер |
| `fraud` | ваш собственный кластер Kubernetes | сервисы антифрода |

```bash
kubectl --context tenant get vminstances,kubernetes
kubectl --context tenant get resourcequota
kubectl --context tenant get applicationdefinitions
kubectl --context fraud get nodes
kubectl --context fraud -n fraud get pods
```

**Вы должны увидеть:** свитч-ВМ и кластер `fraud` в состоянии Ready, квоту вашего тенанта, каталог приложений, одну ноду кластера и работающий под `terminals`. Под `prepull-explainer` в статусе `Completed` — так и должно быть: ведущий заранее скачал им языковую модель.

Квота — это бюджет вашего тенанта: `hard` — лимит, `used` — сколько вы уже потратили. Список определений приложений показывает, что можно заказать. Откройте дашборд Cozystack, выберите свой тенант и найдите там же ВМ, кластер, бюджет и каталог.

### 0.2 Ваша инфраструктура — это Git-репозиторий

📍 На бастионе и в GitLab.

```bash
cd ~/fraud-infra && ls platform && cat platform/kubernetes.yaml
```

**Вы должны увидеть:** `kubernetes.yaml` и `switch-vm.yaml`, а затем декларацию вашего кластера `fraud`.

Откройте свой репозиторий в GitLab, `https://gitlab.workshop.aenix.io/austinNN/fraud-infra`, и войдите с логином и паролем от бастиона. Платформа применяет файлы из `platform/` ветки `main`. В каждом задании на Git ниже сохраняйте нужные файлы в этой копии, коммитьте и пушьте в `main`; дайте платформе около минуты на применение изменений.

### 0.3 Смотрим на «голый» свитч, затем атакуем его

📍 На бастионе, затем внутри ВМ свитча.

```bash
cd ~/workshop
virtctl console vm-instance-switch
```

**Вы должны увидеть:** приглашение к входу ВМ. Если экран остаётся пустым, нажмите Enter, затем войдите с пользователем `ubuntu`, пароль `ubuntu`.

Внутри ВМ:

```bash
journalctl -u auth-switch -f
```

**Вы должны увидеть:** каждые пять секунд строку `5s: 100 authorizations, 0 declined, stand-in 0.0%, p99 0 ms`. Свитч работает в legacy-режиме: отклоняет только платежи больше $5 000. Украденная карта, которой оплатили ужин на $40, проходит.

Остановите лог по `Ctrl-C` и выйдите из консоли по `Ctrl-]`.

Теперь докажите, что мошенничество проходит. Группировка атакует ваших держателей карт: кард-тестинг крошечными платежами, карта, использованная в двух странах с разницей в несколько минут, и проход по целому диапазону номеров карт:

```bash
kubectl --context fraud apply -f manifests/04-attack.yaml
kubectl --context fraud -n fraud logs job/attack -f
```

**Вы должны увидеть:** сначала как атака описывает сама себя (`attack: card testing on card …4750: 36 probes of $0.50–$3.00`, `attack: impossible travel …`, `attack: BIN attack on 411111 …`), затем каждые пять секунд строку вида `sent 30, approved 30, declined 0`. Каждый мошеннический платёж одобрен: ни один не превышает $5 000. Остановите вывод по `Ctrl-C`. В части 2 вы запустите ту же атаку, с теми же картами, против системы, которую сейчас построите.

## Часть 1. Заказываем сервисы данных (30 мин)

📍 На бастионе, вне консоли ВМ, и в дашборде Cozystack.

Все три сервиса берутся из каталога Cozystack — так же, как в публичном облаке заказывается управляемая база данных. Kafka переносит запросы, решения и журнал свитча. Redis помнит недавнюю активность каждой карты. PostgreSQL хранит каждую транзакцию и каждое срабатывание — primary и горячая реплика.

### 1.1 Redis: начинаем в GUI, затем переносим в Git

В дашборде Cozystack выберите свой тенант `tenant-austinNN`, откройте каталог и выберите Redis. Задайте имя `features`, одну реплику, размер `1Gi`, storage class `replicated` и отключите аутентификацию. Создайте его, затем посмотрите на тот же объект с бастиона:

```bash
kubectl --context tenant get redis features -o yaml
```

**Вы должны увидеть:** Redis `features` с настройками, которые вы выбрали в дашборде.

Напишите `~/fraud-infra/platform/redis.yaml` с той же декларацией. Подсказки: kind `Redis`, `metadata.name: features` и поля спецификации `replicas: 1`, `size: 1Gi`, `storageClass: replicated`, `authEnabled: false`. Из объекта, который вы только что посмотрели, возьмите только `apiVersion`, `kind`, `metadata.name` и эти поля `spec`; `status` и сгенерированные метаданные не переносите.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Redis
metadata:
  name: features
spec:
  replicas: 1
  size: 1Gi
  storageClass: replicated
  authEnabled: false
```

</details>

Закоммитьте с сообщением `Order Redis for card history` и запушьте. С этого момента Git — источник истины: объект, созданный в дашборде, управляется из репозитория.

### 1.2 Kafka: пишем манифест по документации

Воспользуйтесь [документацией Kafka](https://cozystack.io/docs/v1.6/applications/kafka/), чтобы написать `~/fraud-infra/platform/kafka.yaml` с именем `kafka`: один брокер и один ZooKeeper, оба на реплицированном хранилище (5Gi и 2Gi), пресет `c1.small` и три топика — `auth.requests`, `auth.decisions`, `auth.journal` — по 8 партиций и 1 реплике каждый.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Kafka
metadata:
  name: kafka
spec:
  kafka:
    replicas: 1
    size: 5Gi
    storageClass: replicated
    resourcesPreset: c1.small
  zookeeper:
    replicas: 1
    size: 2Gi
    storageClass: replicated
    resourcesPreset: c1.small
  topics:
    - {name: auth.requests, partitions: 8, replicas: 1, config: {}}
    - {name: auth.decisions, partitions: 8, replicas: 1, config: {}}
    - {name: auth.journal, partitions: 8, replicas: 1, config: {}}
```

</details>

`auth.requests` переносит вопросы свитча, `auth.decisions` — ответы scorer'а, а `auth.journal` — каждый ответ, который дал свитч, кем бы решение ни было принято. Восемь партиций позволяют восьми скорерам делить работу; в части 4 вы увидите, почему это число важно.

### 1.3 PostgreSQL: primary и горячая реплика

Воспользуйтесь [документацией PostgreSQL](https://cozystack.io/docs/v1.6/applications/postgres/), чтобы написать `~/fraud-infra/platform/postgres.yaml` с именем `cases`: primary и горячая реплика, по 2Gi на реплицированном хранилище, пресет `t1.micro`, пользователь `fraud` с паролем `Fraud2026` и база `fraud` в его владении. Подсказка: `replicas: 2` — это primary и одна реплика.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Postgres
metadata:
  name: cases
spec:
  replicas: 2
  size: 2Gi
  storageClass: replicated
  resourcesPreset: t1.micro
  users:
    fraud:
      password: Fraud2026
  databases:
    fraud:
      roles:
        admin: [fraud]
```

</details>

### 1.4 Коммитим, пушим и наблюдаем

Закоммитьте оба файла с сообщением `Order Kafka and the case database`, запушьте, затем наблюдайте за приложениями:

```bash
watch -n 5 kubectl --context tenant get kafka,redis,postgres
```

**Вы должны увидеть:** `features` (Redis) и `cases` (PostgreSQL) перейдут в `READY True` за минуту-две, `kafka` — за десять-двадцать минут; пока Kafka стартует, продолжайте с 1.5 и 1.6. Когда вся комната заказывает одновременно, платформа ставит сервисы по очереди. Остановите наблюдение по `Ctrl-C`. К части 2 можно переходить, как только готовы Redis и PostgreSQL: сервисы антифрода, которые вы там развернёте, подождут Kafka сами.

### 1.5 Под капотом (5 минут из этой части)

Посмотрите, что Cozystack сделал из ваших деклараций:

```bash
kubectl --context tenant get hr
kubectl --context tenant get clusters.postgresql.cnpg.io
kubectl --context tenant get pods -l cnpg.io/cluster=postgres-cases -L role
kubectl --context tenant get svc | grep postgres-cases
```

**Вы должны увидеть:** Helm-релизы, кластер CloudNativePG за `cases`, его поды primary и реплики, а также сервисы PostgreSQL с суффиксами `rw`, `ro` и `r`.

Эти сервисы поддерживают операторы: Strimzi управляет Kafka, CloudNativePG — PostgreSQL, оператор Redis — Redis. Cozystack превращает ваши декларации приложений в Helm-релизы и ресурсы операторов, а операторы обслуживают поды и сервисы под ними.

### 1.6 Дрейф: смотрим, как платформа возвращает удалённый объект

Удалите приложение Redis вручную, оставив его декларацию в Git:

```bash
kubectl --context tenant delete redis features
kubectl --context tenant get redis -w
```

**Вы должны увидеть:** как `features` вернётся примерно за минуту. Остановите наблюдение по `Ctrl-C`.

Механизм сверки сравнивает то, что есть, с тем, что задекларировано в Git, и возвращает недостающий объект. Постоянные изменения делайте в Git; ручное изменение желаемое состояние не меняет.

## Часть 2. Антифрод-скоринг (25 мин)

### 2.1 Разворачиваем scorer и подключаем свитч

📍 На бастионе.

Разверните сервисы антифрода в своём кластере. Scorer в `manifests/02-scoring.yaml` нарочно маленький, с лимитом CPU `500m`, чтобы в части 4 вы увидели, как ему перестаёт хватать мощности:

```bash
cd ~/workshop
kubectl --context fraud apply -f manifests/02-scoring.yaml
kubectl --context fraud -n fraud get pods -w
```

**Вы должны увидеть:** `scorer`, `cases` и `dashboard` в состоянии `Running`. Остановите вывод по `Ctrl-C`.

Сервисы находят Kafka, Redis и PostgreSQL по их платформенным именам, например `kafka-kafka-kafka-bootstrap.tenant-austinNN.svc.cozy.local`. Ваш кластер — тенант платформы, и сервисы платформы находятся в той же сети.

Scorer работает, но пока никто его ни о чём не спрашивает: свитч по-прежнему решает сам. Прежде чем подключать свитч, проверьте, что Kafka готова:

```bash
kubectl --context tenant get kafka
```

**Вы должны увидеть:** `kafka` с `READY True`. Если она ещё стартует, подождите и повторите команду: Kafka поднимается десять-двадцать минут после пуша в 1.4.

Вернитесь к свитчу:

```bash
virtctl console vm-instance-switch
```

**Вы должны увидеть:** консоль ВМ свитча. Войдите с `ubuntu` / `ubuntu`.

Внутри ВМ направьте свитч на Kafka и перезапустите его:

```bash
sudo sed -i 's#^KAFKA_BOOTSTRAP=.*#KAFKA_BOOTSTRAP=kafka-kafka-kafka-bootstrap:9092#' /etc/auth-switch/env
cat /etc/auth-switch/env
sudo systemctl restart auth-switch
journalctl -u auth-switch -f
```

**Вы должны увидеть:** `switch started in SCORING mode`, затем `100 authorizations, 0 declined, stand-in 0.0%`. Первые пять секунд может показываться небольшой стенд-ин, пока прогреваются соединения.

Короткого имени `kafka-kafka-kafka-bootstrap` достаточно: домен вашего тенанта уже прописан в поисковых доменах DNS ВМ.

Теперь каждый платёж проходит путь через Kafka к scorer'у в вашем кластере и обратно, а терминал по-прежнему получает ответ примерно за десять миллисекунд. Если scorer не отвечает в течение 400 мс, свитч возвращается к своему старому статическому правилу, поэтому медленный scorer никогда не остановит платёж. В банках это называется **обработкой в режиме стенд-ин** (stand-in processing).

Выйдите из консоли (`Ctrl-]`) и откройте свой дашборд: `https://fraud.austinNN.workshop.aenix.io`

**Вы должны увидеть:** около 20 авторизаций в секунду, почти ноль отказов, задержку принятия решения и близкий к нулю лаг Kafka.

### 2.2 Языковая модель объясняет каждый заблокированный платёж

📍 На бастионе.

Для каждого отказа нужна причина, которую сотрудник поддержки может зачитать клиенту. Её пишет небольшая языковая модель. Она работает внутри вашего кластера на CPU: Qwen2.5 0.5B Instruct, обслуживается llama.cpp. Веса модели попадают в ваш кластер; данные карт из него не выходят, и никакой внешний ИИ-сервис не участвует.

```bash
cat manifests/03-explainer.yaml
kubectl --context fraud apply -f manifests/03-explainer.yaml
kubectl --context fraud -n fraud rollout status deploy/explainer --timeout=5m
```

**Вы должны увидеть:** `successfully rolled out` в течение минуты-двух: под скачивает 400 МБ модели и загружает её. Если команда перестала ждать, запустите её ещё раз.

`cases` уже был настроен на адрес explainer'а и ждал его. Пока ничего не заблокировано, объяснять нечего. Шаг 2.3 это меняет.

### 2.3 Повторяем атаку

📍 На бастионе, с открытым дашбордом.

Группировка атакует ваших держателей карт сразу тремя способами:

* **кард-тестинг**: три украденные карты совершают десятки крошечных онлайн-платежей, чтобы проверить, что они работают, а затем пытаются купить дорогую электронику;
* **невозможное путешествие**: картой, только что использованной в Далласе, расплачиваются в Лагосе двумя минутами позже;
* **BIN-атака**: шестьдесят номеров карт подряд из одного банковского диапазона, по доллару.

```bash
kubectl --context fraud apply -f manifests/04-attack.yaml
kubectl --context fraud -n fraud logs job/attack -f
```

**Вы должны увидеть:** в логе атаки большинство платежей `declined`. Первые несколько проб каждой украденной карты одобрены: один крошечный платёж выглядит как любой другой, и картина проясняется только после нескольких попыток. На дашборде растут отказы и появляются заблокированные транзакции с кодами причин. В течение минуты-двух каждая из них получает простое объяснение от модели. Это очень маленькая модель на одном CPU: объяснения приходят по одному, и время от времени одно из них звучит коряво.

Прочитайте правила, которые остановили атаку: [`app/internal/scoring/rules.go`](app/internal/scoring/rules.go). Кард-тестинг останавливается примерно на шестой пробе, BIN-атака — примерно на восьмой карте.

## Часть 3. Расширяем систему каталогом (30 мин)

📍 На бастионе, в репозитории инфраструктуры и в дашборде Cozystack.

### 3.1 ClickHouse для антифрод-аналитиков

Воспользуйтесь [документацией ClickHouse](https://cozystack.io/docs/v1.6/applications/clickhouse/), чтобы написать `~/fraud-infra/platform/clickhouse.yaml` с именем `analytics`: один узел ClickHouse (одна реплика, один шард) на реплицированном хранилище, 5Gi, пресет `t1.medium` и пользователь `fraud` с паролем `Fraud2026`. Одиночному узлу ClickHouse Keeper не нужен: найдите, как его выключить. Не берите `t1.small`: ClickHouse не хватит памяти, чтобы читать платёжный журнал.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: ClickHouse
metadata:
  name: analytics
spec:
  replicas: 1
  shards: 1
  resourcesPreset: t1.medium
  size: 5Gi
  storageClass: replicated
  clickhouseKeeper:
    enabled: false
  users:
    fraud:
      password: Fraud2026
```

</details>

Закоммитьте файл, запушьте и дождитесь готовности `analytics` в дашборде.

### 3.2 Читаем журнал напрямую из Kafka

Откройте клиент ClickHouse:

```bash
kubectl --context tenant exec -it chi-clickhouse-analytics-clickhouse-0-0-0 -c clickhouse -- clickhouse-client --user fraud --password Fraud2026
```

**Вы должны увидеть:** SQL-приглашение ClickHouse, подключённого как `fraud`.

Откройте [`manifests/05-analytics.sql`](manifests/05-analytics.sql) из `~/workshop` и вставьте его SQL в клиент. Он создаёт три объекта: `journal_stream` — таблицу, которая читает Kafka-топик `auth.journal`; `payments` — таблицу MergeTree, где хранятся строки; и `payments_stream_mv` — materialized view, который перекладывает каждую запись журнала из первой таблицы во вторую. ClickHouse читает Kafka напрямую, без промежуточного приложения.

Выполните три примера запросов из файла: отказы по причинам в минуту, топ-10 мерчантов по отказам и стенд-ин в минуту. Например:

```sql
SELECT merchant, count(*)
FROM payments
WHERE decision = 'DECLINE'
GROUP BY merchant
ORDER BY count(*) DESC
LIMIT 10;
```

**Вы должны увидеть:** до десяти мерчантов с количеством отказов, от большего к меньшему. Остальные запросы показывают отказы, сгруппированные по минутам и причинам, а также количество и долю стенд-ин по минутам; значения зависят от трафика и атак, которые вы запускали.

### 3.3 Бакет для отчётов

В дашборде Cozystack откройте каталог → Bucket, назовите его `reports` и добавьте пользователя `analytics`. Положите ту же декларацию в `~/fraud-infra/platform/bucket.yaml`. Подсказка: `spec.users.analytics: {}`.

<details><summary>Решение</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: reports
spec:
  users:
    analytics: {}
```

</details>

Закоммитьте и запушьте. В дашборде откройте Bucket → reports → Secrets → `bucket-reports-analytics-credentials`. Вам нужны `accessKey`, `secretKey` и `bucketName`; endpoint `s3.workshop.aenix.io` уже есть в запросе. В клиенте ClickHouse замените заглушки этими значениями и выгрузите отчёт:

```sql
INSERT INTO FUNCTION s3('https://s3.workshop.aenix.io/<bucketName>/daily-report.csv', '<accessKey>', '<secretKey>', 'CSVWithNames')
SETTINGS s3_truncate_on_insert=1
SELECT merchant, count(*)
FROM payments
WHERE decision = 'DECLINE'
GROUP BY merchant
ORDER BY count(*) DESC
LIMIT 10;
```

**Вы должны увидеть:** `daily-report.csv` в интерфейсе бакета по адресу `https://bucket-reports.austinNN.workshop.aenix.io`. Откройте интерфейс и найдите файл.

## Часть 4. Продакшен-день (30 мин)

📍 На бастионе, с открытым дашбордом антифрода.

### 4.1 Чёрная пятница с автомасштабировщиком

Напишите `HorizontalPodAutoscaler` с именем `scorer` в неймспейсе `fraud`, нацеленный на Deployment `scorer`. Используйте минимум 1 реплику, максимум 8 и метрику CPU с типом цели `AverageValue` и значением `250m`. Восемь — максимально полезное число, потому что у `auth.requests` восемь партиций.

<details><summary>Решение</summary>

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: scorer
  namespace: fraud
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: scorer
  minReplicas: 1
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: AverageValue
          averageValue: 250m
```

</details>

Как и `VMPodScrape`, HPA относится к вашему собственному кластеру: сохраните его в `~/workshop` как `hpa.yaml` и примените командой `kubectl --context fraud apply -f hpa.yaml`. Терминалы читают свою интенсивность из ConfigMap, поэтому трафик можно поднять без рестарта; Kubernetes доставит новое значение в под в течение минуты:

```bash
kubectl --context fraud -n fraud patch configmap traffic -p '{"data":{"rate":"200"}}'
```

**Вы должны увидеть:** в течение минуты-двух стенд-ин поднимается до 100%, растёт **Scoring queue**. Стенд-ин означает, что свитч решал сам по статическому правилу: в настоящем банке именно в этот момент проходит мошенничество, потому что никто не проверил.

Наблюдайте за автомасштабировщиком:

```bash
kubectl --context fraud -n fraud get hpa scorer -w
```

**Вы должны увидеть:** реплики растут 1 → 2 → 4, затем примерно за три минуты стенд-ин падает до нескольких процентов. Остановите наблюдение по `Ctrl-C`.

Представьте супермаркет с восемью кассовыми лентами: добавление кассиров не создаёт новых лент. Партиции — это ленты, а скореры — кассиры. У `auth.requests` восемь партиций, и в consumer-группе Kafka одну партицию в каждый момент времени читает один консьюмер. Насколько масштабируется потоковая система, решается в момент создания топика, а не когда добавляются поды.

Необязательно: убедитесь в этом потолке сами. Закрепите автомасштабировщик на двенадцати скорерах, подождите минуту и прочитайте последнюю строку лога каждого:

```bash
kubectl --context fraud -n fraud patch hpa scorer -p '{"spec":{"minReplicas":12,"maxReplicas":12}}'
kubectl --context fraud -n fraud logs -l app=scorer --tail=1 --prefix
```

**Вы должны увидеть:** восемь скореров сообщают о платежах, а четыре — `scored 0`: лишним скорерам не досталось партиций. Верните автомасштабировщик:

```bash
kubectl --context fraud -n fraud patch hpa scorer -p '{"spec":{"minReplicas":1,"maxReplicas":8}}'
```

Возвращаемся к обычному дню:

```bash
kubectl --context fraud -n fraud patch configmap traffic -p '{"data":{"rate":"20"}}'
```

**Вы должны увидеть:** трафик возвращается к примерно 20 платежам в секунду, а HPA сам уменьшает число реплик примерно за пять минут.

### 4.2 Падает primary-нода базы данных

Найдите primary вашего кластера PostgreSQL:

```bash
kubectl --context tenant get pods -l cnpg.io/cluster=postgres-cases -L role
```

**Вы должны увидеть:** один под с `role=primary`, другой — реплику. Primary — тот, кому идут все записи.

Уберите его, как будто его сервер умер (`--grace-period=5` сокращает период корректного завершения):

```bash
kubectl --context tenant delete pod <под-primary> --grace-period=5
kubectl --context tenant get pods -l cnpg.io/cluster=postgres-cases -L role -w
```

**Вы должны увидеть:** за секунды другой под становится `primary`, а удалённый возвращается новой репликой. Остановите наблюдение по `Ctrl-C`.

Тем временем на антифрод-дашборде панель базы показывает `database unavailable` несколько секунд, а **Case management queue** растёт. Платежи не затронуты: свитч с базой не говорит. Его журнал ждёт в Kafka. Прочитайте лог `cases`:

```bash
kubectl --context fraud -n fraud logs deploy/cases --tail=20
```

**Вы должны увидеть:** `database unavailable, holding … messages, retrying`, а затем запись накопившегося хвоста. Строка сверки на дашборде сравнивает то, что свитч записал в журнал, с тем, что сохранилось в базе; когда хвост записан — в течение минуты-двух — она показывает `missing: 0`. Ни один кейс не пропал.

### 4.3 Свитч переезжает на другой сервер посреди потока

Сервер под вашим свитчем нуждается в обслуживании. В банке это обычно означает окно изменений в три ночи. Здесь ВМ переезжает на другой сервер, продолжая отвечать терминалам:

```bash
kubectl --context tenant get vmi vm-instance-switch -o wide
virtctl migrate vm-instance-switch
kubectl --context tenant get vmim -w
```

**Вы должны увидеть:** миграцию в статусах `Pending`, `Scheduling`, `TargetReady` и `Succeeded` в течение минуты. Остановите наблюдение по `Ctrl-C`.

Проверьте ноду снова:

```bash
kubectl --context tenant get vmi vm-instance-switch -o wide
```

**Вы должны увидеть:** ВМ на другой ноде. Память работающей ВМ копируется на новый сервер, пока она работает, а диск переезжать не должен: он на реплицированном хранилище, доступном обоим серверам.

На дашборде **Terminal errors остаются на нуле**. Секунду-две сеть ВМ перестраивается на новом сервере, и несколько авторизаций остаются без ответа; терминалы делают то, что делают настоящие терминалы, — повторяют их с тем же id транзакции. Дашборд показывает их в строке **repeated by the terminal**.

```bash
kubectl --context fraud -n fraud logs deploy/terminals --tail=20
```

**Вы должны увидеть:** терминалы продолжают отправлять платежи, пока **Terminal errors** на дашборде остаются на нуле.

## Что дальше

Ваше окружение остаётся с вами на две недели: бастион, кластер и дашборды продолжают работать. Меняйте правила в [`rules.go`](app/internal/scoring/rules.go), пишите новую атаку и используйте то же окружение для сертификационного задания, которое ведущий покажет в конце сессии. Ведущий также поделится ссылкой на чат поддержки.

Нашли ошибку в документации Cozystack? Откройте issue или PR в https://github.com/cozystack/website и укажите страницу, которой пользовались, и что ожидали увидеть.

## Если что-то пошло не так

| Симптом | Причина и решение |
|---|---|
| `virtctl console` ничего не показывает | Нажмите Enter. Приглашение к входу печатается только один раз. |
| В логе свитча после части 2 — `stand-in 100%` | Kafka ещё не готова или в адресе в `/etc/auth-switch/env` опечатка. `kubectl --context tenant get kafka` должен показывать `READY True`. |
| Дашборд отдаёт 502 или 503 | Под дашборда ещё не работает: `kubectl --context fraud -n fraud get pods`. |
| После атаки в части 2 нет объяснений | Explainer ещё загружает модель: `kubectl --context fraud -n fraud logs deploy/explainer`. |
| `forbidden` на команду | Проверьте контекст: сервисы каталога, ВМ и поды PostgreSQL живут в `tenant`; сервисы антифрода — в `fraud`. |
| `apply` падает с `SchemaError … unknown model in reference` | Отказала клиентская проверка, не кластер. Добавьте `--validate=false`. |
| Git push отклонён | Выполните `git pull --rebase`, затем запушьте снова. |
| Flux не применяет изменение или в YAML ошибка | `kubectl --context tenant get kustomization platform` покажет ошибку; исправьте файл, закоммитьте и запушьте. |
| ClickHouse сообщает `Memory limit exceeded` | Используйте пресет `t1.medium`. |
