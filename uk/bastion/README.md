# Воркшоп: міграція VMware-VM у Cozystack (через бастіон)

Беремо застосунок, який роками працював на віртуальній машині у VMware, і перевозимо
його в Cozystack. Усе робите власними руками.

**Це шлях через спільну ВМ (бастіон).** Ставити на свій ноутбук нічого не потрібно:
`kubectl`, `virtctl` і `git` уже стоять на бастіоні, а ваш доступ до кластера там уже
налаштований. Ви заходите на нього по SSH і працюєте прямо там, а готовий застосунок
відкриваєте у браузері за доменним іменем.

> Якщо ви працюєте зі свого ноутбука (ставите інструменти самі, ходите в застосунок
> через `port-forward`) — вам потрібен другий набір, [`../laptop/`](../laptop/).

Цей файл — маршрут: що за чим іде, які команди набирати і що має вийти. Пояснення,
чому все влаштовано саме так, і розбори маніфестів та скриптів построково лежать
у теці [`chat/`](chat/) — по одному файлу на повідомлення. Посилання стоять у кінці
кожного кроку.

## Маршрут

Застосунок живе на трьох машинах: сам застосунок, база даних і черга повідомлень.
Перевозимо лише першу — база і черга залишаться в минулому, замість них візьмемо
готові з каталогу Cozystack.

| Фаза | Що робимо | Де |
|---|---|---|
| 1 | Заводимо сховище під образ | на бастіоні |
| 2 | Переупаковуємо диск із формату VMware у формат KVM | у тимчасовій машині |
| 3 | Піднімаємо машину на новому місці | на бастіоні |
| 4 | Замовляємо базу і чергу з каталогу | на бастіоні |
| 5 | Лагодимо мережу і перемикаємо застосунок на нові адреси | у вашій машині |

Далі — фінальна перевірка: замовлення, створене в застосунку, доїжджає до бази і черги.

## Що вам видав викладач

Один логін і один пароль — вони однакові в усіх трьох місцях:

* **дашборд** https://dashboard.workshop.aenix.io — вхід у браузері, namespace `tenant-workshopXX`
* **бастіон** — вхід по SSH: `ssh workshopXX@<адреса-бастіона>`
* усередині бастіона доступ до кластера вже налаштований, а kubeconfig лежить у `~/.kube/config`

Скрізь далі `workshopXX` міняйте на свій номер (його видав викладач).

## Заходимо на бастіон

```bash
ssh workshopXX@<адреса-бастіона>
```

Пароль — той самий, що й від дашборда. SSH-ключ не потрібен: вхід за паролем. Перевіряємо,
що доступ до кластера на місці (браузер при цьому не відкривається — на бастіоні налаштований
прямий доступ за токеном, без Keycloak):

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Маєте побачити:** ім'я контексту `tenant-workshopXX` і (поки що порожній) список машин.

## Матеріали вже на бастіоні

Клонувати нічого не потрібно — тека з матеріалами лежить у вашій домашній директорії,
і ваш номер тенанта в маніфестах та скриптах **уже підставлений**: заглушки
`tenant-workshopXX` замінені на ваш `tenant-workshopNN` під час підготовки бастіона.
Нічого шукати і замінювати не потрібно — одразу застосовуйте файли як є.

```bash
cd ~/workshop
ls manifests scripts
grep -rl tenant-workshop manifests | head -1 | xargs grep -m1 namespace   # побачите свій номер
```

Одне місце залишається заглушкою навмисне: у `manifests/03-app-vm.yaml` рядок
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` — це посилання ви отримаєте після другої фази і впишете самі.

Детально: [chat/10](chat/10-clone-and-set-number.md) ·
карта файлів [chat/11](chat/11-file-map.md)

---

## Фаза 1. Сховище під образ

📍 На бастіоні.

Переупакований диск потрібно покласти туди, звідки його забере платформа по мережі.
Заводимо бакет — об'єктне сховище з S3-інтерфейсом.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**Маєте побачити:** `bucket.apps.cozystack.io/my-images created`, потім `READY: True`.

⚠️ **Ім'я типу пишемо повністю, не `bucket`.** Слово зайняте в кластері тричі: наш тип
із каталогу, тип Flux і тип стандарту об'єктних сховищ. Який із трьох підставить `kubectl`
за коротким іменем — заздалегідь невідомо, і якщо чужий, ви отримаєте відмову в правах на
ресурс, якого не просили: `buckets.source.toolkit.fluxcd.io is forbidden`. Це не проблема
з доступом, лагодити її не треба.

⚠️ **Якщо `apply` падає з `SchemaError … unknown model in reference`** — спотикається
перевірка на вашому боці, а не кластер; маніфест правильний. Обійти:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`. Прапорець знімає лише місцеву
перевірку; сервер усе одно перевірить об'єкт у себе.

**Далі знадобляться ключі:** дашборд → `Bucket` → `my-images` → вкладка `Secrets` →
секрет `bucket-my-images-app-credentials`. Звідти берете `bucketName`, `accessKey`
і `secretKey` — впишете їх у скрипт на наступній фазі.

Розбір маніфеста: [chat/13](chat/13-bucket-manifest.md) ·
крок цілком: [chat/14](chat/14-step-1-bucket.md)

---

## Фаза 2. Переупаковка диска

📍 Спочатку на бастіоні, потім усередині тимчасової машини.

Диск із VMware записаний у форматі VMDK, а KVM читає QCOW2. Переупаковкою займається
`virt-v2v`; ставити його на бастіон заради одного разу немає сенсу, тому піднімаємо
тимчасову машину з уже готовими інструментами.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**Маєте побачити:** два рядки з `created`, потім `Running`.

⚠️ `Running` означає «увімкнулася», а не «готова»: усередині ще кілька хвилин працює
`cloudInit` — ставить пакети і качає `mc`. Зайдете раніше — не знайдете `virt-v2v`.

Заходимо всередину (логін `ubuntu`, пароль `ubuntu`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

Усередині: `nano convert.sh`, вставити текст `scripts/convert.sh`, вписати свої
`bucketName`, `accessKey` і `secretKey` замість `ВСТАВЬТЕ_...`.

⚠️ **Запускайте конвертацію в `screen`** — вона йде хвилин п'ять, і якщо SSH-сесія
до бастіона обірветься, звичайний запуск перерветься на середині. `screen` тримає процес,
навіть коли зв'язок пропав:

```bash
screen -S convert          # увійти в окрему сесію
sudo bash convert.sh       # запустити всередині неї
#  зв'язок обірвався? знову ssh на бастіон, потім:  screen -r convert
```

**Маєте побачити:** у кінці виводу після слова `Share:` — підписане посилання на образ.
Воно знадобиться на наступній фазі.

Розбір маніфеста: [chat/15](chat/15-conversion-vm-manifest.md) ·
розбір скрипта: [chat/17](chat/17-convert-script.md) ·
обидва кроки цілком: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## Фаза 3. Машина на новому місці

📍 На бастіоні.

⚠️ Спочатку погасіть машину-конвертер — вона своє відпрацювала і тримає 8Gi вашої квоти.
Якщо її не прибрати, нова машина повисне в `Pending`:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

Впишіть отримане посилання в `manifests/03-app-vm.yaml` замість
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`, потім:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**Маєте побачити:** два рядки з `created`, потім `Running`. Тут очікування довше —
платформа завантажує образ за вашим посиланням.

Заходимо всередину (логін `root`, пароль `cozydemo`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **Мережі всередині не буде.** Це не поломка тестового середовища — так і має бути.
Лагодимо на п'ятій фазі.

Розбір маніфеста: [chat/20](chat/20-app-vm-manifest.md) ·
крок цілком: [chat/21](chat/21-step-4-your-vm.md)

---

## Фаза 4. База і черга з каталогу

📍 На бастіоні.

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**Маєте побачити:** `postgres.apps.cozystack.io/db created` і
`kafka.apps.cozystack.io/kafka created`. Kafka піднімається помітно довше за Postgres.

Розбір маніфеста: [chat/23](chat/23-managed-manifest.md) ·
крок цілком: [chat/24](chat/24-step-5-database-and-queue.md)

---

## Фаза 5. Підключаємо застосунок

📍 Усередині вашої віртуальної машини.

Три дії строго по порядку: без мережі скрипт не достукається до бази, а без бази
не прийме схему.

| Крок | Що лагодимо | Чим |
|---|---|---|
| 5.1 | машина не в мережі | `scripts/netfix-dhcp.sh` |
| 5.2 | застосунок шукає старі адреси | `scripts/connect-managed.sh` |
| 5.3 | у новій базі немає таблиць | `scripts/orders-schema.sql` |

**5.1.** Скрипт міняє `BOOTPROTO=static` на `dhcp` і прибирає адресу з мережі VMware.
Набирається руками — мережі в машини ще немає, скачати файл не вийде. Після цього
машину потрібно **перезавантажити**: CentOS 7 застосовує налаштування мережі під час завантаження.

**5.2.** Скрипт замінює в `/etc/orders/application.properties` прибиті адреси
`192.168.10.30` і `192.168.10.40` на імена сервісів і перезапускає застосунок.

**5.3.** Ставимо клієнт `psql` і накатуємо схему — команди нижче, у фінальній перевірці.

Детально: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## Фінальна перевірка: три кроки по порядку

### Крок 1. Погасити firewalld

📍 Усередині вашої машини. Правила залишилися зі старої мережі і ріжуть звернення до застосунку.

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**Маєте побачити:** `200`. Якщо `503` — щось із бази або черги не підключилося.
Тут `localhost` — це сама машина, у якій ви сидите: застосунок перевіряється зсередини.

### Крок 2. Схема бази

📍 Усередині вашої машини. Штатному psql із CentOS 7 версія 9.2, він не вміє SCRAM і
відповідає `SCRAM authentication requires libpq version 10 or above`. Ставимо свіжий:

```bash
# 1. Репозиторій PGDG — джерело пакетів PostgreSQL
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: у репозиторіях CentOS 7 її немає, беремо з архіву EPEL
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. Сам клієнт — лише з живого репозиторію pgdg15
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ Друга і третя команди не зайві. Без `libzstd` встановлення падає на
`Requires: libzstd >= 1.4.0`. Без `--disablerepo`/`--enablerepo` — на
`HTTPS Error 410 - Gone`: пакет репозиторію вмикає разом усі версії PostgreSQL,
включно зі знятими з підтримки 12-ю і 13-ю, а `yum` перед встановленням обходить кожен
увімкнений репозиторій і падає на першому мертвому.

```bash
psql --version
```

Якщо `command not found` — клієнт ліг повз `PATH`: подивіться
`ls /usr/pgsql-*/bin/psql`, потім `export PATH="$PATH:/usr/pgsql-15/bin"`.

Забираємо схему і накатуємо (ця app-VM в інтернет ходить, файл скачається):

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**Маєте побачити:** в останній команді — таблицю `orders`.

Адреса бази — не IP, а ім'я: `postgres-db-rw` (сервіс `db` на читання-запис),
`tenant-workshopXX` (ваш namespace), `svc.cozy.local` (суфікс внутрішніх імен
кластера). Пароль заданий у `manifests/04-managed.yaml`, шукати його ніде не треба.

Детально: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### Крок 3. Перевірка ззовні — за доменним іменем

📍 У браузері на своєму ноутбуці або через `curl` на бастіоні.

Тут і проявляється головна відмінність цього шляху: **проброс порту не потрібен.** Викладач
заздалегідь створив у вашому тенанті `Ingress`, і щойно застосунок усередині машини слухає
`8080`, магазин публікується за адресою `https://app.workshopXX.workshop.aenix.io`
(`XX` — ваш номер). Перевіряйте прямо звідти:

```bash
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

**Маєте побачити:** замовлення у списку. Шлях пройдено цілком.

⚠️ Поки app-VM не піднята або ще вантажиться, домен відповідає `503` — це нормально:
`Ingress` чекає бекенд. Після старту машини (усередині слухається `8080`) стане `200`.

Детально: [chat/30](chat/30-step-9-verify-chain.md)

---

## Шпаргалка

> **Префікс `vmi/` потрібен не всім командам, і це не помилка.** Під правами тенанта
> `virtctl console` приймає лише **голе** ім'я (`vm-instance-app-1`); з `vmi/` він
> відповідає `forbidden`, прийнявши слово `vmi` за ім'я машини. А `virtctl ssh` і
> `virtctl port-forward`, навпаки, вимагають форму `vmi/<ім'я>`.

```bash
# зайти в app-VM (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# зайти в conversion-VM (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# оболонка всередині app-VM по SSH (коли мережа в машині вже піднята)
virtctl ssh ubuntu@vmi/vm-instance-app-1 --namespace=tenant-workshopXX
```

Перевірка застосунку — за доменом `https://app.workshopXX.workshop.aenix.io`; `port-forward`
на цьому шляху не потрібен. Вийти з консолі — `Ctrl+]`. Якщо після підключення екран порожній,
натисніть Enter. Те саме доступне мишкою: кнопка **VNC** на сторінці машини в дашборді.

## На чому легко застрягнути

* Для conversion-VM беріть лише `ubuntu-20.04`. На 24.04 ядро панікує, на 22.04
  `virt-v2v` не розбирає стару RPM-базу CentOS 7.
* VMDisk під каталожний образ має бути більшим за сам образ, інакше клон не пройде,
  а диск зависне в `Terminating`. Для `ubuntu-20.04` вистачає 25Gi.
* На свіжій app-VM спочатку `netfix`, потім `connect` — інакше застосунок не побачить
  керовані сервіси.
* Довгу конвертацію запускайте в `screen` — інакше розрив SSH перерве її на середині.

Решта граблів — [chat/31](chat/31-troubleshooting.md).

## Для тих, хто розгортає тестове середовище

Квоти, порядок створення тенантів і версія платформи — у [REQUIREMENTS.md](../REQUIREMENTS.md).

## Усі повідомлення по порядку

Список із 27 повідомлень — [chat/README.md](chat/README.md).
