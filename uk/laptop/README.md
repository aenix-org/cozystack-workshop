# Воркшоп: міграція VMware-ВМ на Cozystack (з власного ноутбука)

Ми беремо застосунок, який роками працював на віртуальній машині у VMware, і переносимо
його на Cozystack. Усе це ви робите власними руками.

> Якщо викладач дав вам спільну ВМ (бастіон) із уже налаштованими інструментами й доступом —
> вам потрібен інший набір, [`../bastion/`](../bastion/), де все вже налаштоване.

Цей файл — маршрут: що йде за чим, які команди набирати і що має вийти в підсумку. Пояснення,
чому все влаштоване саме так, і порядкові розбори маніфестів та скриптів лежать у теці
[`chat/`](chat/) — по одному файлу на повідомлення. Посилання стоять у кінці кожного кроку.

## Маршрут

Застосунок живе на трьох машинах: сам застосунок, база даних і черга повідомлень. Ми
переносимо лише першу — база даних і черга залишаються, а замість них ми беремо готові
з каталогу Cozystack.

| Фаза | Що робимо | Де |
|---|---|---|
| 1 | Налаштовуємо сховище для образу | на ноутбуці |
| 2 | Переупаковуємо диск із формату VMware у формат KVM | у тимчасовій машині |
| 3 | Піднімаємо машину на новому місці | на ноутбуці |
| 4 | Замовляємо базу даних і чергу з каталогу | на ноутбуці |
| 5 | Лагодимо мережу і перемикаємо застосунок на нові адреси | у вашій машині |

Після цього — фінальна перевірка: замовлення, створене у застосунку, доходить аж до бази
даних і черги.

## Що вам дав викладач

Викладач дає вам:

* дашборд https://dashboard.workshop.aenix.io
* ім'я користувача `workshopXX`, пароль дадуть на місці
* kubeconfig — у дашборді: `Info` → вкладка `Secrets` → секрет `kubeconfig-tenant-workshopXX`

Усюди нижче замінюйте `workshopXX` на свій номер.

## Перш ніж почати: чотири утиліти

Вони встановлюються на ноутбук один раз, перед воркшопом.

| Утиліта | Навіщо | Встановлення |
|---|---|---|
| `kubectl` | застосовує файли, показує, що є в кластері | [chat/04](chat/04-install-kubectl.md) |
| `virtctl` | консоль віртуальної машини і проброс портів | [chat/05](chat/05-install-virtctl.md) |
| `kubelogin` | вхід через браузер; без нього кластер вас не пустить | [chat/06](chat/06-install-kubelogin.md) |
| `git` | щоб завантажити цей репозиторій | [chat/09](chat/09-install-git.md) |

⚠️ **krew для цього воркшопу не потрібен** — чому, в [chat/07](chat/07-about-krew.md).

Перевірка, що все на місці. Кожна команда друкує версію або довідку, а не
«command not found»:

```bash
kubectl version --client
virtctl version --client
kubectl oidc-login --help
```

## Підключення до кластера

Збережіть kubeconfig із дашборда на диск і вкажіть на нього змінну `KUBECONFIG`.

**macOS і Linux** — покладіть вміст секрету в `~/.kube/workshop`, потім:

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Windows (PowerShell):**

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # вставте kubeconfig; тип файлу — «All Files»
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

На перший запит відкриється браузер — увійдіть як `workshopXX`.

⚠️ **Windows: зберігайте файл лише в UTF-8.** Notepad і перенаправлення `>` у PowerShell
пишуть UTF-16, і `kubectl` не прочитає такий файл — він відповість
`x509: certificate signed by unknown authority`, хоча із сертифікатом усе гаразд.

⚠️ Помилка `dial tcp [::1]:8080 ... refused` означає, що `kubectl` не знайшов kubeconfig,
а не те, що кластер недосяжний. Розбір обох — у [chat/08](chat/08-connect-to-cluster.md).

## Отримання матеріалів

```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/laptop
```

⚠️ Хвіст `/laptop` обов'язковий: у цій теці лежать матеріали для шляху з ноутбука,
з маніфестами і скриптами; без неї команди не знайдуть ні `manifests`, ні `scripts`.

У кожному файлі є заповнювач `tenant-workshopXX`. Підставте свій номер за один раз
(у прикладі — `workshop03`):

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +

# macOS — той самий sed, але потребує порожніх лапок після -i
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

```powershell
# Windows
Get-ChildItem -Path manifests,scripts -File -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw) -replace 'tenant-workshopXX','tenant-workshop03' |
    Set-Content $_.FullName -NoNewline
}
```

Перевіряємо, що не лишилося жодного заповнювача:

```bash
grep -rn tenant-workshopXX manifests scripts || echo "all clean, you can continue"
```

Одне місце команда навмисно не чіпає: у `manifests/03-app-vm.yaml` рядок
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` — це посилання ви отримаєте після другої фази.

Докладно: [chat/10](chat/10-clone-and-set-number.md) ·
карта файлів [chat/11](chat/11-file-map.md)

---

## Фаза 1. Сховище для образу

📍 На ноутбуці.

Переупакований диск має лягти туди, звідки платформа зможе завантажити його мережею.
Ми налаштовуємо бакет — об'єктне сховище з інтерфейсом S3.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**Ви маєте побачити:** `bucket.apps.cozystack.io/my-images created`, потім `READY: True`.

⚠️ **Пишіть назву типу повністю, а не `bucket`.** Це слово в кластері зайняте тричі:
наш тип із каталогу, тип Flux і тип зі стандарту об'єктного сховища. Який із трьох
`kubectl` підставить замість короткої назви, наперед не відомо, і якщо не той, ви отримаєте
відмову в правах на ресурс, який не замовляли: `buckets.source.toolkit.fluxcd.io is forbidden`.
Це не проблема доступу, і лагодити нічого не треба.

⚠️ **Якщо `apply` падає з `SchemaError … unknown model in reference`** — це спотикається
клієнтська валідація, а не кластер; маніфест правильний. Щоб обійти:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`. Прапорець вимикає лише локальну
перевірку; сервер усе одно перевірить об'єкт на своєму боці.

**Далі знадобляться ключі:** дашборд → `Bucket` → `my-images` → вкладка `Secrets` →
секрет `bucket-my-images-app-credentials`. Звідти ви берете `bucketName`, `accessKey`
і `secretKey` — вставите їх у скрипт у наступній фазі.

Розбір маніфесту: [chat/13](chat/13-bucket-manifest.md) ·
весь крок: [chat/14](chat/14-step-1-bucket.md)

---

## Фаза 2. Переупаковка диска

📍 Спершу на ноутбуці, потім усередині тимчасової машини.

Диск із VMware записаний у форматі VMDK, а KVM читає QCOW2. Переупаковку виконує `virt-v2v`;
ставити його на ноутбук заради разової операції немає сенсу, тож ми піднімаємо тимчасову
машину з уже готовими інструментами.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**Ви маєте побачити:** два рядки з `created`, потім `Running`.

⚠️ `Running` означає «увімкнено», а не «готово»: усередині `cloudInit` працює ще кілька
хвилин — встановлює пакети і завантажує `mc`. Увійдете зарано — не знайдете `virt-v2v`.

Увійдіть (ім'я користувача `ubuntu`, пароль `ubuntu`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

Усередині: `nano convert.sh`, вставте текст `scripts/convert.sh`, підставте свої
`bucketName`, `accessKey` і `secretKey` замість `ВСТАВЬТЕ_...` і запустіть
`bash convert.sh`.

**Ви маєте побачити:** у кінці виводу, після слова `Share:` — підписане посилання на образ.
Воно знадобиться в наступній фазі.

Розбір маніфесту: [chat/15](chat/15-conversion-vm-manifest.md) ·
розбір скрипту: [chat/17](chat/17-convert-script.md) ·
обидва кроки повністю: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## Фаза 3. Машина на новому місці

📍 На ноутбуці.

⚠️ Спершу вимкніть машину-конвертер — вона зробила свою справу і тримає 8Gi вашої квоти.
Якщо її не видалити, нова машина зависне в `Pending`:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

Вставте отримане посилання в `manifests/03-app-vm.yaml` замість
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`, потім:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**Ви маєте побачити:** два рядки з `created`, потім `Running`. Тут чекати довше —
платформа завантажує образ за вашим посиланням.

Увійдіть (ім'я користувача `root`, пароль `cozydemo`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **Мережі всередині не буде.** Це не зламане тестове середовище — так і має бути. Ми
полагодимо це у фазі п'ять.

Розбір маніфесту: [chat/20](chat/20-app-vm-manifest.md) ·
весь крок: [chat/21](chat/21-step-4-your-vm.md)

---

## Фаза 4. База даних і черга з каталогу

📍 На ноутбуці.

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**Ви маєте побачити:** `postgres.apps.cozystack.io/db created` і
`kafka.apps.cozystack.io/kafka created`. Kafka піднімається помітно довше за Postgres.

Розбір маніфесту: [chat/23](chat/23-managed-manifest.md) ·
весь крок: [chat/24](chat/24-step-5-database-and-queue.md)

---

## Фаза 5. Підключення застосунку

📍 Усередині вашої віртуальної машини.

Три дії в суворому порядку: без мережі скрипт не дістанеться до бази даних, а без бази
даних не пройде схема.

| Крок | Що лагодимо | Чим |
|---|---|---|
| 5.1 | у машини немає мережі | `scripts/netfix-dhcp.sh` |
| 5.2 | застосунок шукає старі адреси | `scripts/connect-managed.sh` |
| 5.3 | у новій базі даних немає таблиць | `scripts/orders-schema.sql` |

**5.1.** Скрипт міняє `BOOTPROTO=static` на `dhcp` і прибирає адресу з мережі VMware.
Ви набираєте його вручну — мережі в машині ще немає, тож завантажити файл не вийде.
Після цього машині потрібне **перезавантаження**: CentOS 7 застосовує мережеві налаштування
під час завантаження.

**5.2.** Скрипт замінює жорстко прописані адреси `192.168.10.30` і `192.168.10.40` у
`/etc/orders/application.properties` на імена сервісів і перезапускає застосунок.

**5.3.** Ми встановлюємо клієнт `psql` і застосовуємо схему — команди нижче, у фінальній
перевірці.

Докладно: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## Фінальна перевірка: три кроки по порядку

### Крок 1. Вимкнути firewalld

📍 Усередині вашої машини. Правила лишилися від старої мережі й відсікають запити до застосунку.

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**Ви маєте побачити:** `200`. Якщо `503` — щось із бази даних або черги не під'єдналося.

### Крок 2. Схема бази даних

📍 Усередині вашої машини. Штатний psql із CentOS 7 — версії 9.2; він не вміє SCRAM і
відповідає `SCRAM authentication requires libpq version 10 or above`. Ми встановлюємо свіжий:

```bash
# 1. Репозиторій PGDG — джерело пакетів PostgreSQL
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: немає в репозиторіях CentOS 7, тож беремо з архіву EPEL
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. Сам клієнт — лише з живого репозиторію pgdg15
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ Друга і третя команди не зайві. Без `libzstd` встановлення падає на
`Requires: libzstd >= 1.4.0`. Без `--disablerepo`/`--enablerepo` — на
`HTTPS Error 410 - Gone`: пакет репозиторію вмикає одразу всі версії PostgreSQL,
зокрема застарілі 12 і 13, і перед встановленням `yum` обходить кожен увімкнений
репозиторій і падає на першому мертвому.

```bash
psql --version
```

Якщо `command not found` — клієнт потрапив поза `PATH`: гляньте
`ls /usr/pgsql-*/bin/psql`, потім `export PATH="$PATH:/usr/pgsql-15/bin"`.

Завантажуємо схему і застосовуємо її:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**Ви маєте побачити:** в останній команді — таблицю `orders`.

Адреса бази даних — не IP, а ім'я: `postgres-db-rw` (сервіс `db`, read-write),
`tenant-workshopXX` (ваш namespace), `svc.cozy.local` (суфікс для внутрішніх імен кластера).
Пароль заданий у `manifests/04-managed.yaml`, тож ніде його шукати не треба.

Докладно: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### Крок 3. Проброс порту і перевірка ззовні

📍 На ноутбуці.

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

Не закривайте вікно — тунель живе, доки виконується команда. У другому вікні:

```bash
curl -s http://localhost:8080/actuator/health

curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s http://localhost:8080/api/orders
```

**Ви маєте побачити:** замовлення у списку. Весь шлях пройдено.

Докладно: [chat/30](chat/30-step-9-verify-chain.md)

---

## Шпаргалка

> **Префікс `vmi/` потрібен не кожній команді, і це не помилка.** У двох команд різний
> синтаксис цілі. `virtctl console` очікує лише ім'я і з префіксом відповідає `forbidden`,
> бо приймає слово `vmi` за ім'я машини. `virtctl port-forward` вимагає `type/name` і без
> префікса відповідає `target must contain type and name separated by '/'`.

```bash
# вхід у app-VM (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# вхід у conversion-VM (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# проброс порту застосунку на ноутбук
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

Щоб вийти з консолі — `Ctrl+]`. Якщо після підключення екран порожній, натисніть Enter.
Те саме доступне мишею: кнопка **VNC** на сторінці машини в дашборді.

## Де легко застрягти

* Для conversion-VM використовуйте лише `ubuntu-20.04`. На 24.04 ядро панікує; на 22.04
  `virt-v2v` не може розібрати стару базу RPM з CentOS 7.
* VMDisk для образу з каталогу має бути більшим за сам образ, інакше клонування не пройде
  і диск зависне в `Terminating`. Для `ubuntu-20.04` вистачає 25Gi.
* На свіжій app-VM спершу `netfix`, потім `connect` — інакше застосунок не побачить
  керовані сервіси.
* Не відкривайте файли `.yaml` у Word чи Google Docs: вони підміняють лапки й тире, файл
  перестає застосовуватися, а помилка виглядає незбагненною.

Решта підводних каменів — [chat/31](chat/31-troubleshooting.md).

## Для тих, хто налаштовує тестове середовище

Квоти, порядок створення тенантів і версія платформи — у [REQUIREMENTS.md](../REQUIREMENTS.md).

## Усі повідомлення по порядку

Список із 32 повідомлень — [chat/README.md](chat/README.md).
