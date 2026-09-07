## 29. Крок 8: ставимо клієнт і накочуємо схему

**Доступ до бази:**
```
host:     postgres-db-rw.tenant-workshopXX.svc.cozy.local
database: orders
login:    orders
password: Orders2019!
```
Пароль задано в `manifests/04-managed.yaml`, шукати його більше ніде не треба.

⚠️ **Штатний psql із CentOS 7 не підійде.** Йому 9.2 року випуску, а наша база вимагає
автентифікації SCRAM, якої він не вміє, і відповідає:
`psql: SCRAM authentication requires libpq version 10 or above`. Потрібен клієнт версії 10 або новіший.
Беремо з репозиторію PGDG — для CentOS 7 там доступний щонайбільше 15-й.

Три команди поспіль, по одній причині на кожну:

```bash
# 1. Підключаємо репозиторій PGDG — джерело пакетів PostgreSQL.
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. Бібліотека libzstd, без неї клієнт не встановиться. У репозиторіях CentOS 7 її немає,
#    беремо з архіву EPEL.
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. Сам клієнт — тільки з живого репозиторію pgdg15.
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

Друга й третя команди виглядають надмірними, але без них установлення падає, і обидві помилки
ви інакше побачите на власні очі:

- без `libzstd` — `Requires: libzstd >= 1.4.0`;
- без `--disablerepo`/`--enablerepo` — `HTTPS Error 410 - Gone`. Пакет репозиторію
  вмикає одразу всі версії PostgreSQL, включно зі знятими з підтримки 12-ю та 13-ю, а `yum`
  перед установленням обходить **кожен** увімкнений репозиторій і падає на першому мертвому.
  Ми явно лишаємо лише той, який нам потрібен.

Перевіряємо, що клієнт на місці:

```bash
psql --version
```

Якщо відповідь — `command not found`, клієнт поклало повз `PATH`; знайдіть його й допишіть
каталог на поточну сесію:

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**Забираємо файл схеми** — мережа в машини вже є:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql
```

**Накочуємо.** Розберемо команду по частинах, щоб не вводити наосліп:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'` — пароль передається змінною оточення, щоб `psql` не
  питав його в діалозі. Так роблять у скриптах.
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local` — адреса бази. Це **не IP**, а
  внутрішнє ім'я в кластері. Суфікс `-rw` важливий: у керованого Postgres кілька копій,
  і це ім'я завжди вказує на ту, у яку **можна писати**. Є парне ім'я з `-ro`
  — тільки для читання. Коли ролі перемикаються між копіями, ім'я не змінюється, тому в
  налаштуваннях застосунку прописують його, а не адресу конкретного сервера.
- `-U orders` — під яким користувачем, `-d orders` — у яку базу.
- `-f orders-schema.sql` — виконати команди з файлу.

Саме можливість звертатися до бази за сталим ім'ям, а не за IP, і робить
перемикання копій непомітним для застосунку. На старій машині у вас у конфізі стояв
`localhost`, і жодного перемикання не було в принципі.

Перевіряємо, що таблиця на місці:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

З'явилася — отже, замовлення тепер створиться. Перевіримо це на наступному кроці, разом
з усім ланцюжком.
