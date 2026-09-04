# Workshop: Migration einer VMware-VM zu Cozystack (vom eigenen Laptop aus)

Wir nehmen eine Anwendung, die jahrelang auf einer virtuellen Maschine in VMware lief, und
verschieben sie zu Cozystack. Sie erledigen alles mit eigenen Händen.

> Wenn die Lehrkraft Ihnen eine gemeinsame VM (den Bastion) mit bereits vorhandenen Werkzeugen
> und Zugriff gegeben hat — dann brauchen Sie den anderen Satz, [`../bastion/`](../bastion/), dort
> ist bereits alles eingerichtet.

Diese Datei ist die Route: was worauf folgt, welche Befehle einzugeben sind und was am Ende
herauskommen soll. Die Erklärungen, warum die Dinge so aufgebaut sind, wie sie sind, sowie die
zeilenweisen Durchläufe der Manifeste und Skripte finden sich im Ordner [`chat/`](chat/) — eine
Datei pro Nachricht. Die Links stehen am Ende jedes Schritts.

## Die Route

Die Anwendung lebt auf drei Maschinen: die Anwendung selbst, die Datenbank und die
Nachrichtenwarteschlange. Wir verschieben nur die erste — die Datenbank und die Warteschlange
bleiben zurück, und an ihrer Stelle nehmen wir fertige aus dem Cozystack-Katalog.

| Phase | Was wir tun | Wo |
|---|---|---|
| 1 | Speicher für das Image einrichten | auf dem Laptop |
| 2 | Die Festplatte vom VMware-Format ins KVM-Format umpacken | in einer temporären Maschine |
| 3 | Die Maschine in ihrer neuen Heimat hochfahren | auf dem Laptop |
| 4 | Die Datenbank und die Warteschlange aus dem Katalog bestellen | auf dem Laptop |
| 5 | Das Netzwerk in Ordnung bringen und die Anwendung auf die neuen Adressen umstellen | in Ihrer Maschine |

Danach kommt die abschließende Prüfung: Eine in der Anwendung erstellte Bestellung gelangt den
ganzen Weg bis zur Datenbank und zur Warteschlange.

## Was die Lehrkraft Ihnen gegeben hat

Die Lehrkraft gibt Ihnen:

* das Dashboard https://dashboard.workshop.aenix.io
* den Benutzernamen `workshopXX`, das Passwort erhalten Sie vor Ort
* die kubeconfig — im Dashboard: `Info` → den Tab `Secrets` → das Secret `kubeconfig-tenant-workshopXX`

Ersetzen Sie überall im Folgenden `workshopXX` durch Ihre eigene Nummer.

## Vor dem Start: vier Dienstprogramme

Sie werden einmalig auf Ihrem Laptop installiert, vor dem Workshop.

| Dienstprogramm | Wofür | Installation |
|---|---|---|
| `kubectl` | wendet Dateien an, zeigt, was im Cluster ist | [chat/04](chat/04-install-kubectl.md) |
| `virtctl` | die Konsole der virtuellen Maschine und das Port-Forwarding | [chat/05](chat/05-install-virtctl.md) |
| `kubelogin` | Anmeldung über den Browser; ohne es lässt der Cluster Sie nicht hinein | [chat/06](chat/06-install-kubelogin.md) |
| `git` | um dieses Repository zu holen | [chat/09](chat/09-install-git.md) |

⚠️ **krew wird für diesen Workshop nicht benötigt** — warum, in [chat/07](chat/07-about-krew.md).

Eine Prüfung, dass alles vorhanden ist. Jeder Befehl gibt eine Version oder einen Hilfetext aus,
nicht „command not found“:

```bash
kubectl version --client
virtctl version --client
kubectl oidc-login --help
```

## Verbindung mit dem Cluster

Speichern Sie die kubeconfig aus dem Dashboard auf die Festplatte und richten Sie die Variable
`KUBECONFIG` darauf aus.

**macOS und Linux** — legen Sie den Inhalt des Secrets in `~/.kube/workshop` ab, dann:

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Windows (PowerShell):**

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # kubeconfig einfügen; Dateityp — "Alle Dateien"
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

Bei der ersten Anfrage öffnet sich ein Browser — melden Sie sich als `workshopXX` an.

⚠️ **Windows: Speichern Sie die Datei nur in UTF-8.** Notepad und die `>`-Umleitung in PowerShell
schreiben UTF-16, und `kubectl` liest eine solche Datei nicht — es antwortet
`x509: certificate signed by unknown authority`, obwohl mit dem Zertifikat alles in Ordnung ist.

⚠️ Der Fehler `dial tcp [::1]:8080 ... refused` bedeutet, dass `kubectl` die kubeconfig nicht gefunden
hat, nicht dass der Cluster nicht erreichbar ist. Ein Durchlauf zu beiden — in [chat/08](chat/08-connect-to-cluster.md).

## Die Materialien holen

```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/laptop
```

⚠️ Das Suffix `/laptop` ist zwingend: Dieser Ordner enthält die Materialien für den Laptop-Weg,
mit den Manifesten und Skripten; ohne ihn finden die Befehle weder `manifests` noch `scripts`.

In jeder Datei gibt es einen Platzhalter `tenant-workshopXX`. Ersetzen Sie ihn auf einen Schlag
durch Ihre eigene Nummer (im Beispiel — `workshop03`):

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +

# macOS — dasselbe sed, aber es verlangt leere Anführungszeichen nach -i
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

```powershell
# Windows
Get-ChildItem -Path manifests,scripts -File -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw) -replace 'tenant-workshopXX','tenant-workshop03' |
    Set-Content $_.FullName -NoNewline
}
```

Wir prüfen, dass kein einziger Platzhalter übrig bleibt:

```bash
grep -rn tenant-workshopXX manifests scripts || echo "all clean, you can continue"
```

Eine Stelle lässt der Befehl absichtlich unberührt: in `manifests/03-app-vm.yaml` die Zeile
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` — diesen Link erhalten Sie nach der zweiten Phase.

Im Detail: [chat/10](chat/10-clone-and-set-number.md) ·
Dateiübersicht [chat/11](chat/11-file-map.md)

---

## Phase 1. Speicher für das Image

📍 Auf dem Laptop.

Die umgepackte Festplatte muss irgendwo landen, von wo die Plattform sie über das Netzwerk beziehen
kann. Wir richten einen Bucket ein — Objektspeicher mit einer S3-Schnittstelle.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**Sie sollten sehen:** `bucket.apps.cozystack.io/my-images created`, dann `READY: True`.

⚠️ **Schreiben Sie den Typnamen vollständig aus, nicht `bucket`.** Das Wort ist im Cluster dreifach
belegt: unser Typ aus dem Katalog, der Flux-Typ und der Typ aus dem Objektspeicher-Standard. Welchen
der drei `kubectl` für den Kurznamen einsetzt, ist im Voraus nicht bekannt, und wenn es der falsche
ist, erhalten Sie eine Rechteverweigerung auf eine Ressource, die Sie nie angefordert haben:
`buckets.source.toolkit.fluxcd.io is forbidden`. Das ist kein Zugriffsproblem, und es gibt nichts zu beheben.

⚠️ **Falls `apply` mit `SchemaError … unknown model in reference` fehlschlägt** — es ist die
clientseitige Validierung, die stolpert, nicht der Cluster; das Manifest ist korrekt. Als Workaround:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`. Das Flag schaltet nur die lokale Prüfung
ab; der Server validiert das Objekt weiterhin auf seiner Seite.

**Als Nächstes brauchen Sie die Schlüssel:** Dashboard → `Bucket` → `my-images` → der Tab `Secrets` →
das Secret `bucket-my-images-app-credentials`. Von dort nehmen Sie `bucketName`, `accessKey`
und `secretKey` — die Sie in der nächsten Phase in das Skript eintragen.

Manifest-Durchlauf: [chat/13](chat/13-bucket-manifest.md) ·
der ganze Schritt: [chat/14](chat/14-step-1-bucket.md)

---

## Phase 2. Umpacken der Festplatte

📍 Zuerst auf dem Laptop, dann in der temporären Maschine.

Die Festplatte aus VMware ist im VMDK-Format geschrieben, während KVM QCOW2 liest. `virt-v2v`
übernimmt das Umpacken; es lohnt sich nicht, es für einen einmaligen Einsatz auf dem Laptop zu
installieren, deshalb fahren wir eine temporäre Maschine hoch, auf der die Werkzeuge bereits vorhanden sind.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**Sie sollten sehen:** zwei Zeilen mit `created`, dann `Running`.

⚠️ `Running` bedeutet „eingeschaltet“, nicht „bereit“: Im Inneren arbeitet `cloudInit` noch einige
Minuten weiter — installiert Pakete und lädt `mc` herunter. Melden Sie sich zu früh an, finden Sie `virt-v2v` nicht.

Melden Sie sich an (Benutzername `ubuntu`, Passwort `ubuntu`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

Im Inneren: `nano convert.sh`, fügen Sie den Text von `scripts/convert.sh` ein, setzen Sie Ihre
eigenen `bucketName`, `accessKey` und `secretKey` anstelle von `ВСТАВЬТЕ_...` ein und führen Sie
`bash convert.sh` aus.

**Sie sollten sehen:** am Ende der Ausgabe, nach dem Wort `Share:` — einen signierten Link zum Image.
Sie brauchen ihn in der nächsten Phase.

Manifest-Durchlauf: [chat/15](chat/15-conversion-vm-manifest.md) ·
Skript-Durchlauf: [chat/17](chat/17-convert-script.md) ·
beide Schritte vollständig: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## Phase 3. Die Maschine in ihrer neuen Heimat

📍 Auf dem Laptop.

⚠️ Fahren Sie zuerst die Konverter-Maschine herunter — sie hat ihre Arbeit getan und belegt 8Gi
Ihrer Quota. Wenn Sie sie nicht entfernen, bleibt die neue Maschine in `Pending` hängen:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

Tragen Sie den erhaltenen Link in `manifests/03-app-vm.yaml` anstelle von
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` ein, dann:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**Sie sollten sehen:** zwei Zeilen mit `created`, dann `Running`. Das Warten dauert hier länger —
die Plattform lädt das Image von Ihrem Link herunter.

Melden Sie sich an (Benutzername `root`, Passwort `cozydemo`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **Im Inneren gibt es kein Netzwerk.** Das ist keine kaputte Testumgebung — es soll so sein. Wir
bringen es in Phase fünf in Ordnung.

Manifest-Durchlauf: [chat/20](chat/20-app-vm-manifest.md) ·
der ganze Schritt: [chat/21](chat/21-step-4-your-vm.md)

---

## Phase 4. Die Datenbank und die Warteschlange aus dem Katalog

📍 Auf dem Laptop.

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**Sie sollten sehen:** `postgres.apps.cozystack.io/db created` und
`kafka.apps.cozystack.io/kafka created`. Kafka braucht merklich länger zum Hochkommen als Postgres.

Manifest-Durchlauf: [chat/23](chat/23-managed-manifest.md) ·
der ganze Schritt: [chat/24](chat/24-step-5-database-and-queue.md)

---

## Phase 5. Die Anwendung anbinden

📍 In Ihrer virtuellen Maschine.

Drei Aktionen in strikter Reihenfolge: ohne Netzwerk erreicht das Skript die Datenbank nicht, und
ohne die Datenbank nimmt es das Schema nicht an.

| Schritt | Was wir beheben | Womit |
|---|---|---|
| 5.1 | die Maschine hat kein Netzwerk | `scripts/netfix-dhcp.sh` |
| 5.2 | die Anwendung sucht nach den alten Adressen | `scripts/connect-managed.sh` |
| 5.3 | die neue Datenbank hat keine Tabellen | `scripts/orders-schema.sql` |

**5.1.** Das Skript ändert `BOOTPROTO=static` in `dhcp` und entfernt die Adresse aus dem VMware-Netzwerk.
Sie tippen es von Hand ab — die Maschine hat noch kein Netzwerk, Sie können die Datei also nicht
herunterladen. Danach braucht die Maschine einen **Neustart**: CentOS 7 wendet Netzwerkeinstellungen beim Booten an.

**5.2.** Das Skript ersetzt die fest verdrahteten Adressen `192.168.10.30` und `192.168.10.40` in
`/etc/orders/application.properties` durch Servicenamen und startet die Anwendung neu.

**5.3.** Wir installieren den `psql`-Client und wenden das Schema an — die Befehle stehen unten, in
der abschließenden Prüfung.

Im Detail: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## Die abschließende Prüfung: drei Schritte der Reihe nach

### Schritt 1. firewalld herunterfahren

📍 In Ihrer Maschine. Die Regeln stammen noch aus dem alten Netzwerk und schneiden Anfragen an die Anwendung ab.

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**Sie sollten sehen:** `200`. Falls `503` — etwas von der Datenbank oder der Warteschlange hat sich
nicht verbunden.

### Schritt 2. Das Datenbankschema

📍 In Ihrer Maschine. Das mitgelieferte psql aus CentOS 7 hat Version 9.2; es beherrscht SCRAM nicht
und antwortet `SCRAM authentication requires libpq version 10 or above`. Wir installieren ein frisches:

```bash
# 1. Das PGDG-Repository — die Quelle der PostgreSQL-Pakete
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: nicht in den CentOS-7-Repositories, deshalb holen wir es aus dem EPEL-Archiv
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. Der Client selbst — nur aus dem aktiven pgdg15-Repository
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ Der zweite und der dritte Befehl sind nicht überflüssig. Ohne `libzstd` scheitert die Installation
an `Requires: libzstd >= 1.4.0`. Ohne `--disablerepo`/`--enablerepo` — an `HTTPS Error 410 - Gone`:
Das Repository-Paket aktiviert jede PostgreSQL-Version auf einmal, einschließlich der abgekündigten
12 und 13, und vor der Installation durchläuft `yum` jedes aktivierte Repository und scheitert am ersten toten.

```bash
psql --version
```

Falls `command not found` — der Client ist außerhalb von `PATH` gelandet: schauen Sie in
`ls /usr/pgsql-*/bin/psql`, dann `export PATH="$PATH:/usr/pgsql-15/bin"`.

Wir holen das Schema und wenden es an:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**Sie sollten sehen:** beim letzten Befehl — die Tabelle `orders`.

Die Adresse der Datenbank ist keine IP, sondern ein Name: `postgres-db-rw` (der Service `db`,
read-write), `tenant-workshopXX` (Ihr namespace), `svc.cozy.local` (das Suffix für die clusterinternen
Namen). Das Passwort ist in `manifests/04-managed.yaml` festgelegt, Sie müssen also nirgends danach suchen.

Im Detail: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### Schritt 3. Port-Forwarding und Prüfen von außen

📍 Auf dem Laptop.

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

Schließen Sie das Fenster nicht — der Tunnel lebt, solange der Befehl läuft. In einem zweiten Fenster:

```bash
curl -s http://localhost:8080/actuator/health

curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s http://localhost:8080/api/orders
```

**Sie sollten sehen:** die Bestellung in der Liste. Die ganze Reise ist abgeschlossen.

Im Detail: [chat/30](chat/30-step-9-verify-chain.md)

---

## Spickzettel

> **Nicht jeder Befehl braucht das Präfix `vmi/`, und das ist kein Tippfehler.** Die beiden Befehle
> haben eine unterschiedliche Zielsyntax. `virtctl console` erwartet nur den Namen und antwortet mit
> dem Präfix `forbidden`, weil es das Wort `vmi` für den Namen der Maschine hält. `virtctl port-forward`
> verlangt `type/name` und antwortet ohne das Präfix
> `target must contain type and name separated by '/'`.

```bash
# an der App-VM anmelden (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# an der Conversion-VM anmelden (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# den Port der Anwendung an den Laptop weiterleiten
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

Um die Konsole zu verlassen — `Ctrl+]`. Falls der Bildschirm nach dem Verbinden leer ist, drücken Sie
Enter. Dasselbe gibt es mit der Maus: die Schaltfläche **VNC** auf der Seite der Maschine im Dashboard.

## Wo man leicht steckenbleibt

* Verwenden Sie für die Conversion-VM nur `ubuntu-20.04`. Auf 24.04 gerät der Kernel in Panic; auf
  22.04 kann `virt-v2v` die alte CentOS-7-RPM-Datenbank nicht lesen.
* Die VMDisk für ein Katalog-Image muss größer sein als das Image selbst, sonst geht der Klon nicht
  durch und die Festplatte bleibt in `Terminating` hängen. Für `ubuntu-20.04` reichen 25Gi.
* Auf einer frischen App-VM zuerst `netfix`, dann `connect` — sonst sieht die Anwendung die Managed
  Services nicht.
* Öffnen Sie `.yaml`-Dateien nicht in Word oder Google Docs: Sie tauschen die Anführungszeichen und
  Bindestriche aus, die Datei lässt sich nicht mehr anwenden, und der Fehler sieht unerklärlich aus.

Die übrigen Fallstricke — [chat/31](chat/31-troubleshooting.md).

## Für alle, die die Testumgebung aufsetzen

Quotas, die Reihenfolge beim Erstellen der Tenants und die Plattformversion — in [REQUIREMENTS.md](../REQUIREMENTS.md).

## Alle Nachrichten der Reihe nach

Die Liste der 32 Nachrichten — [chat/README.md](chat/README.md).
</content>
</invoke>
