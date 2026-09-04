## 29. Schritt 8: Client installieren und Schema anwenden

**Datenbankzugang:**
```
host:     postgres-db-rw.tenant-workshopXX.svc.cozy.local
database: orders
login:    orders
password: Orders2019!
```
Das Passwort ist in `manifests/04-managed.yaml` festgelegt; es muss nirgends sonst gesucht werden.

⚠️ **Das mitgelieferte psql von CentOS 7 taugt nicht.** Es hat Version 9.2, und unsere Datenbank verlangt
SCRAM-Authentifizierung, die es nicht beherrscht, weshalb es antwortet:
`psql: SCRAM authentication requires libpq version 10 or above`. Sie brauchen einen Client der Version 10 oder neuer.
Wir nehmen ihn aus dem PGDG-Repository — für CentOS 7 ist dort maximal Version 15 verfügbar.

Drei Befehle nacheinander, jeder aus einem eigenen Grund:

```bash
# 1. Das PGDG-Repository einbinden — die Quelle der PostgreSQL-Pakete.
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. Die Bibliothek libzstd, ohne die sich der Client nicht installieren lässt. In den
#    CentOS-7-Repositories ist sie nicht enthalten, deshalb nehmen wir sie aus dem EPEL-Archiv.
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. Der Client selbst — nur aus dem aktiven Repository pgdg15.
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

Der zweite und der dritte Befehl wirken überflüssig, aber ohne sie schlägt die Installation fehl, und
beide Fehler würden Sie andernfalls mit eigenen Augen sehen:

- ohne `libzstd` — `Requires: libzstd >= 1.4.0`;
- ohne `--disablerepo`/`--enablerepo` — `HTTPS Error 410 - Gone`. Das Repository-Paket
  zieht alle PostgreSQL-Versionen auf einmal herein, einschließlich der abgekündigten Versionen 12
  und 13, und vor der Installation durchläuft `yum` **jedes** aktivierte Repository und scheitert am ersten toten.
  Wir behalten ausdrücklich nur das, das wir brauchen.

Prüfen Sie, dass der Client vorhanden ist:

```bash
psql --version
```

Lautet die Antwort `command not found`, ist der Client außerhalb Ihres `PATH` gelandet; finden Sie ihn und ergänzen Sie
sein Verzeichnis für die aktuelle Sitzung:

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**Holen Sie sich die Schemadatei** — die Maschine hat bereits Netzwerk:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql
```

**Anwenden.** Zerlegen wir den Befehl Stück für Stück, damit Sie nicht blind tippen:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'` — das Passwort wird über eine Umgebungsvariable übergeben, damit `psql` nicht
  interaktiv danach fragt. So macht man es in Skripten.
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local` — die Adresse der Datenbank. Das ist **keine IP**,
  sondern ein interner Name innerhalb des Clusters. Das Suffix `-rw` ist wichtig: managed Postgres hat mehrere
  Kopien, und dieser Name zeigt immer auf jene, in die Sie **schreiben können**. Es gibt einen zugehörigen Namen mit `-ro`
  — nur zum Lesen. Wenn die Rollen zwischen den Kopien wechseln, ändert sich der Name nicht, weshalb die
  Einstellungen der Anwendung diesen Namen enthalten und nicht die Adresse eines bestimmten Servers.
- `-U orders` — als welcher Benutzer verbunden wird, `-d orders` — mit welcher Datenbank.
- `-f orders-schema.sql` — die Befehle aus der Datei ausführen.

Gerade die Möglichkeit, die Datenbank über einen festen Namen statt über eine IP zu erreichen, macht
den Wechsel der Kopien für die Anwendung unsichtbar. Auf der alten Maschine stand in Ihrer Konfiguration
`localhost`, und einen Wechsel gab es dort von vornherein überhaupt nicht.

Prüfen Sie, dass die Tabelle vorhanden ist:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

Ist sie da, wird nun eine Bestellung erzeugt. Das prüfen wir im nächsten Schritt, zusammen
mit der gesamten Kette.
