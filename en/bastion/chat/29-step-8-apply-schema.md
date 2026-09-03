## 29. Step 8: install the client and apply the schema

**Database access:**
```
host:     postgres-db-rw.tenant-workshopXX.svc.cozy.local
database: orders
login:    orders
password: Orders2019!
```
The password is set in `manifests/04-managed.yaml`; there's no need to look for it anywhere else.

⚠️ **The stock psql from CentOS 7 won't do.** It's version 9.2, and our database requires
SCRAM authentication, which it can't handle, so it replies:
`psql: SCRAM authentication requires libpq version 10 or above`. You need a client version 10 or newer.
We take it from the PGDG repository — for CentOS 7 the newest available there is 15.

Three commands in a row, one reason for each:

```bash
# 1. Wire up the PGDG repository — the source of PostgreSQL packages.
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. The libzstd library, without which the client won't install. It's not in the CentOS 7
#    repositories, so we take it from the EPEL archive.
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. The client itself — only from the live pgdg15 repository.
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

The second and third commands look redundant, but without them the install fails, and you'd
otherwise see both errors with your own eyes:

- without `libzstd` — `Requires: libzstd >= 1.4.0`;
- without `--disablerepo`/`--enablerepo` — `HTTPS Error 410 - Gone`. The repository package
  pulls in every PostgreSQL version at once, including the end-of-life 12 and 13, and before
  installing, `yum` walks **every** enabled repository and fails on the first dead one.
  We explicitly keep only the one we need.

Check that the client is in place:

```bash
psql --version
```

If the answer is `command not found`, the client landed outside your `PATH`; find it and add
its directory for the current session:

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**Grab the schema file** — the machine already has network:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql
```

**Apply it.** Let's break the command down part by part, so you're not typing blind:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'` — the password is passed via an environment variable, so `psql` doesn't
  prompt for it interactively. That's how it's done in scripts.
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local` — the database address. This is **not an IP**,
  but an internal name within the cluster. The `-rw` suffix matters: managed Postgres has several
  copies, and this name always points to the one you **can write to**. There's a paired name with `-ro`
  — read-only. When roles switch between copies, the name doesn't change, which is why the application's
  settings hold this name rather than the address of a specific server.
- `-U orders` — which user to connect as, `-d orders` — which database.
- `-f orders-schema.sql` — run the commands from the file.

It's precisely the ability to reach the database by a stable name, rather than by IP, that makes
switching copies invisible to the application. On the old machine your config held
`localhost`, and there was no switching at all in the first place.

Check that the table is in place:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

If it's there, an order will now be created. We'll verify that in the next step, together
with the whole chain.
