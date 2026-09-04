# Lab 9 · Analytik über eine Million Zeilen

| | |
|---|---|
| **Dauer** | 45 Minuten |
| **Was es zeigt** | Ein Bericht über eine Million Datensätze wird in Millisekunden berechnet, und die Einrichtung dauert zehn Minuten |
| **Was Sie brauchen** | Der Cluster aus Lab 0 und `~/lab.kubeconfig`; Zugang zum Dashboard Ihres Tenants; eine Tenant-Nummer der Form `workshopXX`; die Fähigkeit, SQL zu lesen |

> ⚠️ **Ein dichtes Lab, das SQL-Lesekenntnisse erfordert. Planen Sie es nicht direkt nach Lab 8.**

## Warum das wichtig ist

Der Dienst „Pass“ läuft nun seit einem halben Jahr. Die Geschäftsführung kommt mit einer Frage, die
harmlos klingt:

> Wie viele Gäste haben wir pro Monat, steigt oder sinkt die Zahl, und zu welchen Stunden bildet
> sich eine Schlange am Eingang? Wir möchten einmal im Monat hineinschauen, idealerweise jeden Tag.

Die Datenbank, in der die Pässe selbst liegen, enthält das nicht — sie hat aktuelle Anfragen, keine
jahrelange Historie. Die Historie liegt im Zutrittsprotokoll: jeder Durchgang durch ein Drehkreuz
über die gesamte Laufzeit des Dienstes. Das sind bereits eine Million Zeilen, und es werden stetig
mehr.

Dann beginnt das Altbekannte. Jemand schreibt eine `GROUP BY`-Abfrage gegen die
Produktionsdatenbank; sie läuft zwei Minuten und legt den Pass-Dienst für diese zwei Minuten lahm.
Jemand schlägt den Export nach Excel vor — und stößt an das Zeilenlimit. Jemand richtet einen
nächtlichen Export in eine separate Datenbank ein, und ein halbes Jahr später erinnert sich niemand
mehr, warum die Zahlen im Bericht nicht mit der Realität übereinstimmen.

Die richtige Antwort ist **eine separate Datenbank für Analytik, anders gebaut**. Nicht „dieselbe,
nur auf einem anderen Server“, sondern innen anders. In diesem Lab starten wir ClickHouse, laden eine
Million Zutrittsdatensätze hinein und sehen, wie lange die Berechnung des Berichts dauert.

Unterwegs erarbeiten wir uns, **warum eine spaltenorientierte Datenbank bei Analytik schnell und bei
punktgenauen Operationen langsam ist** — denn die zweite Hälfte ist ebenso wichtig wie die erste, und
genau ihr Nichtwissen führt dazu, dass Leute ClickHouse dort einsetzen, wo es nicht gebraucht wird.

Jeder Begriff in diesem Lab wird bei seinem ersten Auftreten erklärt, und der nächste Abschnitt ist
ein Glossar der bereits eingeführten.

## Glossar

| Begriff | Was es ist | Wie… aber |
|---|---|---|
| **OLAP** | Eine Last aus „wenigen Abfragen, aber jede liest Millionen von Zeilen“ | **Ein vierteljährlicher vRealize-Bericht**, aber die Aufschlüsselung wird in dem Moment erfunden, in dem die Frage gestellt wird, nicht im Voraus geplant |
| **Spaltenorientiertes DBMS** | Speichert jedes Feld als separaten Strom | **Kein direktes Analogon**, aber es liest nur die Felder, nach denen Sie fragen. Einen einzelnen Wert zu ändern ist dagegen teuer |
| **ClickHouse** | Ein spaltenorientiertes DBMS; hier ein Managed Service aus dem Katalog | kein Ersatz für PostgreSQL, sondern eine Ergänzung dazu |
| **MergeTree** | Die wichtigste Art, wie Tabellen in ClickHouse gespeichert werden | Daten liegen in Parts, und Parts werden periodisch zu größeren zusammengeführt |
| **Sortierschlüssel (`ORDER BY`)** | Die Reihenfolge, in der Daten innerhalb der Parts angeordnet sind | **Die Reihenfolge der Dateien auf der Festplatte**, aber es ist der einzige echte „Index“. Es gibt einen pro Tabelle, und Sie wählen ihn im Voraus |
| **HTTP-Schnittstelle** | Eine Möglichkeit, mit ClickHouse über eine gewöhnliche HTTP-Anfrage zu sprechen | die Abfrage geht als Text im Rumpf eines POST hinaus, die Antwort kommt als Tabelle zurück |

Die übrigen Begriffe dieses Labs — OLTP, zeilenorientiertes DBMS, Part, Mutation, Shard, Replik,
Keeper — werden im Verlauf eingeführt, in dem Schritt, in dem sie zuerst gebraucht werden. Sie müssen
sie jetzt nicht auswendig lernen: losgelöst von der Handlung bleiben sie nicht hängen.

<details>
<summary><b>Falls Sie lieber die ganze Liste auf einmal sehen</b></summary>

| Begriff | Was es ist | Wie… aber |
|---|---|---|
| **OLTP** | Eine Last aus „vielen kleinen Operationen“: eine Anfrage erstellen, einen Status ändern | **vCenter, das mit seiner eigenen Datenbank arbeitet**, aber jede Operation berührt eine Handvoll Zeilen — es sind nur sehr viele |
| **Zeilenorientiertes DBMS** | Speichert Datensätze als Ganzes, Zeile für Zeile | **Dateien auf einem Datastore: jede liegt als Ganzes**, aber genau deshalb ist eine Zeile leicht zu ändern und eine Spalte schwer schnell zu summieren |
| **Part** | Ein Datenblock auf der Festplatte, der durch ein einzelnes Insert entsteht | Sie fassen sie nicht von Hand an, aber ihre Anzahl und Größe erklären das Verhalten |
| **Mutation** | Eine aufgeschobene Änderung oder Löschung von Zeilen | sie geschieht nicht an Ort und Stelle: sie schreibt ganze Parts neu, im Hintergrund |
| **Shard** | Ein Teil der Daten auf einer separaten Gruppe von Servern | es geht um Volumen, nicht um Zuverlässigkeit |
| **Replik** | Eine vollständige Kopie der Daten | **Eine Datastore-Replik**, aber es geht um Zuverlässigkeit, nicht um Volumen |
| **Keeper** | Der Dienst, über den sich Kopien untereinander koordinieren | **Eine Quorum-Disk**, aber nur nötig, wenn es mehr als eine Kopie gibt |

</details>

## Was im Lab-Ordner liegt

Sie haben bereits alle Dateien — Sie haben sie mit dem Repository erhalten. Es gibt nichts zu
erstellen oder abzutippen: wo unten `kubectl apply -f name.yaml` steht, stammt die Datei von hier.

```bash
cd labs/09-clickhouse
```

| Datei | Was es ist | Wann Sie sie verwenden |
|---|---|---|
| `clickhouse.yaml` | Die Bestellung für eine Analytik-Datenbank — dasselbe wie der Knopf im Dashboard | Sie wenden sie **im Tenant** an, nicht im `lab`-Cluster |
| `01-schema.sql` | Die Tabelle für Zutrittsereignisse | Sie führen sie in der Datenbank aus |
| `02-generate.sql` | Die Erzeugung einer Million Zeilen, damit es etwas zu berechnen gibt | Sie führen sie als Nächstes aus |
| `03-report.sql` | Der Bericht selbst — „wie viele Gäste und wann die Spitzen sind“ | Sie führen ihn zuletzt aus |
| `check.sh` | Eine Prüfung, dass der Bericht wirklich berechnet wird, und in vertretbarer Zeit | Sie führen sie am Ende des Labs aus |

## Schritt 1. ClickHouse bestellen

📍 **Wo:** im Browser, im Cozystack-Dashboard, in Ihrem Tenant.

Tenant → **Create application** → `ClickHouse`.

| Feld | Wert | Warum |
|---|---|---|
| Name | `analytics` | kurz — Sie tippen ihn später in Adressen |
| Replicas | **1** | eine Trainings-Testumgebung. Das sind Kopien des **Servers**, nicht der Daten — siehe die Warnung unten |
| Shards | **1** | eine Million Zeilen ist wenig. Sie sharden, wenn die Daten nicht auf einen Server passen |
| Size | `5Gi` | eine Million Zeilen belegt ein paar Megabyte; der Rest ist Reserve |
| Log storage size | `2Gi` | das Volume für die eigenen Textlogs des Servers, `/var/log/clickhouse-server` |
| Log TTL | `15` | das Abfrageprotokoll, das älter als fünfzehn Tage ist, wird verworfen |
| Storage class | `replicated` | die Daten landen in drei Kopien auf verschiedenen Nodes |
| Resources preset | `u1.small` | 1 Prozessor, 4 GB. Gruppierungen werden im Arbeitsspeicher berechnet |
| Users | Benutzer `analyst`, denken Sie sich ein Passwort aus | das ist der Benutzer, als der wir arbeiten |
| ClickHouse Keeper → enabled | **ausschalten** | Keeper koordiniert Kopien untereinander. Es gibt eine Kopie — nichts zu koordinieren |

> ⚠️ **Eine Server-Kopie ist keine Daten-Kopie.** Das Feld `Replicas` bringt mehrere ClickHouse-
> Server hoch, aber die Tabellen selbst werden nicht repliziert: ein gewöhnlicher `MergeTree`, den
> wir im nächsten Schritt erstellen, lebt auf dem Server, auf dem er erstellt wurde. Setzen Sie zwei
> Repliken mit einer solchen Tabelle, gehen die Inserts an einen Server, während die Abfragen mal auf
> ihm, mal auf seinem leeren Nachbarn landen.
>
> Damit die Daten tatsächlich dupliziert werden, erstellen Sie die Tabelle als
> `ReplicatedMergeTree`, und die Koordination erfordert eingeschalteten Keeper. Das ist ein eigenes
> Thema und in einer Trainings-Testumgebung sinnlos — aber Sie müssen von diesem Unterschied wissen,
> bevor Sie in der Produktion eine Zwei einstellen.

⚠️ **Denken Sie sich ein ordentliches Passwort aus und schreiben Sie es auf.** Sie brauchen es
später, sowohl in Befehlen als auch im Prüfskript. Sie können es danach im Dashboard nachsehen:
Anwendung `analytics` → Reiter **Secrets** → `clickhouse-analytics-credentials`.

⚠️ **Keeper ist standardmäßig an, und das ist der richtige Standard.** Sobald es mehr als eine Kopie
gibt, brauchen sie einen Ort, um sich zu einigen, wer was geschrieben hat. Wir haben eine Kopie, und
drei Keeper-Kopien würden die Ressourcen der Testumgebung für nichts verschwenden. Falls Sie dieses
Kontrollkästchen in Ihrem Formular nicht sehen, klappen Sie den Abschnitt mit den zusätzlichen
Parametern auf.

### Genauer betrachtet: was in clickhouse.yaml steckt

Der Lab-Ordner enthält `clickhouse.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: ClickHouse
metadata:
  name: analytics
  namespace: tenant-workshopXX
spec:
  replicas: 1
  shards: 1
  size: 5Gi
  logStorageSize: 2Gi
  logTTL: 15
  storageClass: replicated
  resourcesPreset: u1.small
  users:
    analyst:
      password: YourPasswordHere
  backup:
    enabled: false
  clickhouseKeeper:
    enabled: false
```

`apiVersion: apps.cozystack.io/v1alpha1` — der Cozystack-Katalog von der Seite gesehen, von der er
wie eine API aussieht. Wenn Sie den Knopf klicken, baut das Dashboard genau dieses Objekt zusammen.

`namespace: tenant-workshopXX` — **Managed Services leben in Ihrem Tenant auf dem Management-Cluster,
nicht im Lab-Cluster aus Lab 0.** Das sind zwei verschiedene Cluster, und Sie müssen das für den Rest
des Labs im Kopf behalten.

`shards` und `replicas` sind zwei verschiedene Dinge, die Leute ständig verwechseln. **Bei Shards
geht es um Volumen:** die Daten werden auf Gruppen von Servern aufgeteilt, jede hält ihren eigenen
Teil. **Bei Repliken geht es um Zuverlässigkeit:** jede hält alles vollständig. Eine Million Zeilen
sind ein paar Megabyte — es gibt nichts zu sharden.

`users` — eine Map von Benutzern. ClickHouse erstellt `analyst` mit dem angegebenen Passwort und legt
ihn im Secret `clickhouse-analytics-credentials` ab, das im Dashboard sichtbar ist.

⚠️ Neben Ihrem Benutzer erscheint in diesem Secret ein weiterer — `backup`. Der Chart erstellt ihn
selbst, für den Backup-Mechanismus. Sie müssen ihn nicht anfassen.

`backup.enabled: false` — Backups werden im Lab nicht gebraucht. In der Produktion ist es das Erste,
was Sie einschalten.

`clickhouseKeeper.enabled: false` — siehe oben, zur einzelnen Kopie.

Diese Datei wird **nicht auf den Lab-Cluster** angewendet, sondern auf den Tenant:

```bash
# --kubeconfig benennt die Zugangsdatei explizit und überschreibt die Variable KUBECONFIG.
# So geht die Bestellung an den Tenant auf dem Management-Cluster, nicht an den Lab-Cluster.
kubectl --kubeconfig ~/.kube/workshop apply -f clickhouse.yaml
```

Das Tenant-kubeconfig wird aus dem Dashboard geholt: **Info → Reiter Secrets →
`kubeconfig-tenant-workshopXX`**. Speichern Sie es unter `~/.kube/workshop`.

Warten Sie, bis es bereit ist. Das sind zwei bis vier Minuten: der Server kommt hoch, das Volume wird
erstellt, der Benutzer wird eingerichtet.

## Schritt 2. Einen Arbeits-Pod einrichten

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Hier müssen wir innehalten und den Aufbau verstehen.

**Ein Pod** ist die kleinste Ausführungseinheit in Kubernetes: ein oder mehrere Container, die immer
zusammen leben und sterben. Das nächste Analogon aus vSphere ist eine virtuelle Maschine, nur ohne
eigenes Betriebssystem und ohne eigene Festplatte. Von hier an taucht dieses Wort ständig auf.

**ClickHouse lebt in Ihrem Tenant auf dem Management-Cluster.** Ihre Rolle im Tenant erlaubt Ihnen,
Dienste zu bestellen und zu löschen, aber nicht, dort eigene Pods auszuführen oder Ports
weiterzuleiten. Das ist kein Defekt, sondern eine Grenze.

**Ihr Arbeitsbereich ist der Lab-Cluster aus Lab 0.** Von dort erreichen wir ClickHouse, über seine
interne Adresse:

```
chendpoint-clickhouse-analytics.tenant-workshopXX.svc.cozy.local:8123
```

Zerlegen wir den Namen in seine Teile:

| Teil | Was er bedeutet |
|---|---|
| `chendpoint-` | ein Präfix, das der ClickHouse-Operator seinem Service hinzufügt |
| `clickhouse-` | ein Präfix, das der Cozystack-Katalog dem Anwendungsnamen hinzufügt |
| `analytics` | der Name, den Sie im Dashboard gesetzt haben |
| `tenant-workshopXX` | Ihr Tenant. Setzen Sie Ihre eigene Nummer ein |
| `svc.cozy.local` | die interne Namenszone des Management-Clusters |
| `8123` | der Port der HTTP-Schnittstelle. Es gibt auch 9000 — für das native Protokoll |

Bringen Sie den Arbeits-Pod hoch. Setzen Sie Ihre Tenant-Nummer und Ihr Passwort ein:

```bash
# Alles ab hier passiert im Lab-Cluster, also stellen wir kubectl darauf um.
export KUBECONFIG=~/lab.kubeconfig
# run erstellt einen einzelnen Pod aus dem angegebenen Image — eine kleine Wegwerfmaschine im Cluster.
# Das Image bringt curl mit, und das genügt: ein separater ClickHouse-Client wird nicht gebraucht.
#   --restart=Never  ihn nicht erneut hochbringen, wenn der Befehl darin endet
#   --env=CH_URL     die Adresse der HTTP-Schnittstelle des Speichers; der abschließende Schrägstrich ist erforderlich
#   --env=CH_AUTH    das Paar "Benutzer:Passwort" für gewöhnliche HTTP-Authentifizierung
#   --command --     alles nach den zwei Bindestrichen ist der Befehl, den der Pod ausführt
# sleep 86400 = "einen Tag lang nichts tun": der Pod wird nur als Arbeitsbereich gebraucht.
kubectl run ch-workbench \
  --image=curlimages/curl:8.11.1 \
  --restart=Never \
  --env=CH_URL="http://chendpoint-clickhouse-analytics.tenant-workshopXX.svc.cozy.local:8123/" \
  --env=CH_AUTH="analyst:YourPasswordHere" \
  --command -- sleep 86400
# wait hält das Terminal an, bis der Pod startet, aber nicht länger als zwei Minuten.
kubectl wait --for=condition=Ready pod/ch-workbench --timeout=120s
```

**Warum Adresse und Passwort Pod-Variablen sind und nicht direkt im Befehl stehen.** Alles, was Sie
in `kubectl exec` tippen, landet in der Historie Ihrer Shell und in der Prozessliste auf dem Node.
Die Variablen des Pods werden einmal gesetzt, und danach erscheint das Passwort nie wieder in
Befehlen.

⚠️ **Das löst das Problem nicht vollständig, und es ist ehrlicher, das vorab zu sagen.** Ein über
`--env` übergebener Wert bleibt in der Beschreibung des Pods: er ist für jeden sichtbar, der das
Recht hat, Pods in Ihrem Namespace zu lesen, er liegt in der Datenbank des Clusters, und er landet im
Audit-Log. Für eine Trainings-Testumgebung ist das akzeptabel; für eine produktive nicht: dort kommt
das Passwort in ein separates Cluster-Objekt (`Secret` — ein Objekt für sensible Werte) und wird über
eine Referenz darauf eingebunden, während das Objekt selbst aus einem Secrets-Store befüllt wird.
Genau darum geht es im Lab über Secrets.

Nun richten wir einen kurzen Befehl ein, damit wir nicht jedes Mal `curl` tippen müssen. Zuerst
zerlegen wir, woraus er besteht.

<details>
<summary><b>Diesen Befehl Stück für Stück zerlegen</b></summary>

`kubectl exec -i ch-workbench` — etwas im Arbeits-Pod ausführen. Das Flag `-i` leitet die
Standardeingabe nach innen weiter: ohne es gelangt die Abfrage nicht zu ClickHouse.

`sh -c '…'` in einfachen Anführungszeichen — die Zeichenkette wird unverändert nach innen übergeben,
und `$CH_AUTH` wird **innerhalb des Pods** expandiert, aus der Variable des Pods. Ihr Laptop sieht
diese Werte nicht und schreibt sie nicht in die Befehlshistorie.

`curl -sS` — leise, aber Fehler doch melden. `-s` entfernt die Fortschrittsanzeige, `-S` bringt die
Fehlermeldungen zurück, die `-s` sonst verschlucken würde.

`-u "$CH_AUTH"` — Benutzername und Passwort. ClickHouse akzeptiert gewöhnliche HTTP-Authentifizierung.

`--data-binary @-` — „nimm den Anfragerumpf unverändert aus der Standardeingabe“. Genau so gelangt SQL
in ClickHouse: **die Abfrage ist der Rumpf einer gewöhnlichen POST-Anfrage**, kein spezielles
Protokoll. Daraus folgt: um ClickHouse zu erreichen, brauchen Sie keinen Treiber. `curl` genügt, und
das hilft oft bei der Fehlersuche.

`?default_format=PrettyCompact` — die Form, in der die Antwort zurückkommen soll. `PrettyCompact` ist
eine Tabelle für Menschen. Es gibt mehr als dreißig Formate; unten brauchen wir `JSON`.

</details>

```bash
# Wir definieren ch — einen kurzen Namen für einen langen Befehl. Ab hier bedeutet "ch": sende
# an ClickHouse das SQL, das auf der Standardeingabe ankommt, und zeige die Antwort als Tabelle.
# Der Name lebt, bis Sie dieses Terminalfenster schließen; in einem neuen Fenster definieren Sie ihn erneut.
ch() {
  kubectl exec -i ch-workbench -- sh -c \
    'curl -sS -u "$CH_AUTH" --data-binary @- "$CH_URL?default_format=PrettyCompact"'
}
```

Prüfen wir die Verbindung:

```bash
# echo gibt eine Zeichenkette aus, | reicht sie an die Eingabe von ch weiter. SELECT version() ist die
# billigstmögliche Abfrage: der Server liest nichts von der Festplatte, er nennt nur seine Version.
echo 'SELECT version()' | ch
```

**Was Sie sehen sollten** — die ClickHouse-Versionsnummer in einem kleinen Rahmen.

⚠️ **Falls der Befehl schweigt oder mit `Could not resolve host` / `Connection refused` fehlschlägt**
— es hat keinen Sinn weiterzumachen. Häufige Ursachen, in absteigender Wahrscheinlichkeit: Sie haben
`workshopXX` nicht durch Ihre eigene Nummer ersetzt; die Anwendung im Dashboard ist noch nicht
bereit; ein Tippfehler im Service-Namen. Ist die Antwort `Authentication failed`, besteht die
Verbindung, aber das Passwort ist falsch: erstellen Sie den Pod mit dem richtigen `CH_AUTH` neu.

Windows-PowerShell-Nutzer, Ihre Version:

```powershell
# $input — das, was durch die Pipeline links in die Funktion kam.
# Das Backtick am Zeilenende setzt den Befehl in der nächsten Zeile fort.
function ch {
  $input | kubectl exec -i ch-workbench -- sh -c `
    'curl -sS -u "$CH_AUTH" --data-binary @- "$CH_URL?default_format=PrettyCompact"'
}
"SELECT version()" | ch
```

## Schritt 3. Die Zutrittsprotokoll-Tabelle erstellen

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Wir richten eine Tabelle für das Zutrittsprotokoll ein: eine Zeile pro Durchgang durch das Drehkreuz.
Die Datei `01-schema.sql` liegt im Lab-Ordner, und es lohnt sich, sie zu lesen, bevor Sie sie
anwenden — zwei Zeilen darin bestimmen, welche Abfragen später schnell ausfallen und welche nicht.

<details>
<summary><b>Das Schema Zeile für Zeile durchgehen</b></summary>

```sql
-- IF NOT EXISTS — nicht meckern, wenn die Tabelle schon existiert. Die Datei kann zweimal angewendet werden.
CREATE TABLE IF NOT EXISTS passes
(
    pass_id      UInt64,                 -- die Pass-Nummer
    created_at   DateTime,               -- wann die Person durch das Drehkreuz ging
    guest_name   String,                 -- der Name des Gastes: jeder hat seinen eigenen
    host_dept    LowCardinality(String), -- die Abteilung des Gastgebers: wenige Werte
    entrance     LowCardinality(String), -- der Eingang: es gibt drei
    pass_type    LowCardinality(String), -- einmalig, wöchentlich, Fahrzeug
    duration_min UInt16                  -- wie viele Minuten der Gast drinnen blieb
)
ENGINE = MergeTree               -- wie speichern: Parts auf der Festplatte, Zusammenführen im Hintergrund
ORDER BY (created_at, entrance)  -- in welcher Reihenfolge die Daten ablegen; zugleich der Index
```

`UInt64`, `UInt16` — vorzeichenlose Ganzzahlen von 8 und 2 Byte. In ClickHouse wählen Sie die Größe
eines Typs bewusst: eine Milliarde Zeilen mal vier zusätzliche Byte sind vier Gigabyte. Für eine Dauer
in Minuten sind zwei Byte mehr als genug.

`LowCardinality(String)` — eine Zeichenkette mit wenigen verschiedenen Werten. Wir haben drei
Eingangsnamen und fünf Abteilungen. ClickHouse speichert solche Felder als Wörterbuch: auf der
Festplatte stehen Zahlen, nicht millionenfach wiederholte Wörter. Die Ersparnis ist enorm, und wir
werden sie in Zahlen sehen.

⚠️ **Die Regel lautet:** bis zu ein paar tausend verschiedene Werte — `LowCardinality`; mehr als das
— ein einfaches `String`. Den Namen eines Gastes, der fast immer eindeutig ist, in `LowCardinality`
zu verpacken, macht die Sache schlechter: das Wörterbuch würde größer werden als die Daten selbst.

`ENGINE = MergeTree` — die wichtigste Art zu speichern. Jedes Insert legt einen neuen **Part** auf die
Festplatte, und Parts werden im Hintergrund zu größeren zusammengeführt. Daraus folgt übrigens eine
wichtige praktische Regel: Sie sollten **in Stapeln von vielen Zeilen** einfügen, nicht eine nach der
anderen. Eine Million Ein-Zeilen-Inserts würden eine Million Parts erzeugen und den Server lahmlegen.

```sql
ORDER BY (created_at, entrance)
```

Das ist die wichtigste Zeile in der Datei, und Sie wählen sie, bevor Sie mit dem Schreiben von Daten
beginnen.

`ORDER BY` legt **die Reihenfolge fest, in der die Daten physisch auf der Festplatte liegen**. Er
dient zugleich als einziger echter Index: ClickHouse setzt alle paar tausend Zeilen Marken und
ermittelt daraus, welche Teile der Datei es komplett überspringen kann.

Die Abfrage „wie viele Zutritte gab es im März“ wird zu „lies diesen Abschnitt der Datei“. Die Abfrage
„finde den Zutritt mit Nummer 424242“ wird zu nichts: `pass_id` steht nicht im Sortierschlüssel, also
muss die ganze Spalte gelesen werden. Wir werden das in einem eigenen Schritt sehen, und es ist kein
Mangel der Implementierung, sondern eine direkte Folge des Entwurfs.

**Eine Analogie aus einer vertrauten Welt.** Der Sortierschlüssel ist wie die Entscheidung, in welcher
Reihenfolge man Papierpässe im Archiv ablegt: nach Datum oder nach Nachname. Legen Sie sie nach Datum
ab, wird der März-Ordner sofort herausgezogen, während ein bestimmter Iwanow gefunden wird, indem man
sie einzeln durchgeht. Und niemand wird nachträglich eine Million Blätter neu einsortieren.

</details>

**Wenden Sie es an.**

```bash
cd labs/09-clickhouse
# < liest die Datei und reicht sie an die Eingabe von ch weiter, sendet also den Inhalt der Datei
# in einer einzigen Abfrage an ClickHouse. CREATE TABLE gibt eine leere Antwort zurück — das ist Erfolg.
ch < 01-schema.sql
```

## Schritt 4. Eine Million Datensätze erzeugen

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Wir haben keine Zutrittsdaten, und wir brauchen eine Million. Wir erzeugen sie direkt in ClickHouse —
keine Exporte, Skripte oder Zwischendateien. Sehen wir uns zuerst an, woraus der Generator besteht.

<details>
<summary><b>Den Generator Zeile für Zeile durchgehen</b></summary>

```sql
INSERT INTO passes
SELECT …
FROM numbers(1000000)
```

`numbers(1000000)` — eine eingebaute Generatortabelle: eine Million Zeilen mit einer einzigen Spalte
`number` von 0 bis 999999. Sie liest nichts von der Festplatte, sie existiert nicht in der Natur, sie
wird zur Laufzeit berechnet. Das ist ein Standardtrick: alle Testdaten in ClickHouse entstehen so.

```sql
    number AS pass_id,
```

Die Pass-Nummer. Eindeutig, weil `number` eindeutig ist.

```sql
    addDays(
        toDateTime('2026-01-01 00:00:00'),
        toUInt16(sqrt(cityHash64(number, 'day') % 57600))
    )
```

`cityHash64(number, 'day')` — eine schnelle Hash-Funktion. Aus der Nummer einer Zeile macht sie eine
pseudozufällige Zahl, und dieselbe Eingabe liefert stets dasselbe Ergebnis. Das zweite Argument,
`'day'`, ist das „Salz“: mit einem anderen Salz liefert dieselbe Zahl ein anderes Ergebnis. So machen
wir aus einem einzigen `number` beliebig viele unabhängige Zufallswerte.

`% 57600` ergibt eine Zahl von 0 bis 57599, und `sqrt` davon ergibt 0 bis 239, also einen Tag
innerhalb von acht Monaten. Die Quadratwurzel hier ist nicht zur Zierde: sie **konzentriert die Daten
zum Ende des Zeitraums hin**. Gäste werden mit der Zeit zahlreicher — wie im Leben, und genau das will
die Geschäftsführung im Bericht sehen.

```sql
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
```

Die Ankunftsstunde. Statt eines gleichmäßigen „8 bis 18“ nehmen wir einen Wert aus einem Array, in dem
sich die Stunden mit unterschiedlichen Häufigkeiten wiederholen: die Zehn erscheint dreimal, die
Fünfzehn dreimal, die Acht nur einmal. Das erzeugt **zwei ausgeprägte Spitzen** — vor dem Mittag und
danach. Genau die sollten wir laut Geschäftsführung finden, und es ist gut, wenn die Testdaten das
enthalten, wonach wir gleich suchen.

⚠️ Die Array-Indizierung in ClickHouse beginnt bei eins, nicht bei null. Daher das `1 + …`.

```sql
    ['Северная', 'Северная', 'Северная',
     'Южная', 'Южная', 'Западная'][1 + cityHash64(number, 'entrance') % 6] AS entrance
```

Derselbe Trick für eine ungleichmäßige Verteilung: der Nordeingang erhält die Hälfte des Stroms, der
Süden ein Drittel, der Westen den Rest. Gleichmäßige Daten wirken in Berichten unglaubwürdig und
zeigen nichts.

```sql
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
```

Besuchsdauer von 30 bis 329 Minuten. `toUInt16` ist nötig, weil der Typ der Spalte explizit deklariert
ist, während das Ergebnis der Arithmetik breiter ist.

**Wie lange es dauerte.** Eine Million Zeilen wurden in Sekunden erzeugt und geschrieben, vollständig
innerhalb des Servers. Die Daten liefen nicht über das Netz, gingen nicht durch Ihren Laptop und
lagen nicht in einer Zwischendatei. Vergleichen Sie das mit der üblichen Art, Testdaten zu erzeugen —
einem Skript, das eine Zeile nach der anderen einfügt.

</details>

**Wenden Sie es an.**

```bash
# Die Datei enthält ein einzelnes INSERT … SELECT: ClickHouse erfindet eine Million Zeilen selbst und schreibt sie,
# ohne je den Server zu verlassen.
ch < 02-generate.sql
```

**Was Sie sehen sollten** — eine leere Antwort und die Eingabeaufforderung, die nach ein paar Sekunden
zurückkehrt. Eine leere Antwort von `INSERT` ist Erfolg.

Prüfen wir, was wir bekommen haben:

```bash
# count() ohne Bedingungen beantwortet die Frage "wie viele Zeilen sind insgesamt in der Tabelle".
echo 'SELECT count() FROM passes' | ch
```

**Was Sie sehen sollten** — `1000000`.

## Schritt 5. Der Bericht, für den die Geschäftsführung kam

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Genau der Bericht, für den die Geschäftsführung kam: wie viele Gäste in jedem Monat, wie lange ein
Besuch im Durchschnitt dauert, zu welcher Stunde die Leute am häufigsten ankommen und welcher Eingang
stärker frequentiert ist. Die Datei `03-report.sql` ist eine einzige Abfrage; wir zerlegen sie, bevor
wir sie ausführen.

<details>
<summary><b>Den Bericht Zeile für Zeile durchgehen</b></summary>

```sql
-- Eine Berichtszeile für jeden Monat, der in den Daten vorkommt.
SELECT
    toStartOfMonth(created_at)          AS month,        -- welchem Monat es zugeordnet wird
    count()                             AS guests,       -- wie viele Zutritte darin
    round(avg(duration_min))            AS avg_minutes,  -- durchschnittliche Besuchsdauer
    topK(1)(toHour(created_at))[1]      AS peak_hour,    -- die häufigste Ankunftsstunde
    topK(1)(entrance)[1]                AS busiest_entrance  -- der häufigste Eingang
FROM passes
GROUP BY month   -- alle Zeilen eines Monats in eine einzige Antwortzeile zusammenfassen
ORDER BY month   -- die Monate in aufsteigender Reihenfolge ausgeben
```

`toStartOfMonth` verwandelt eine exakte Zeit in den ersten Tag des Monats. Ein klassischer Trick zum
Gruppieren nach Zeitraum: statt „nach Jahr und Monat gruppieren“ — ein einziger Wert, nach dem wir
sowohl gruppieren als auch sortieren.

`count()` — wie viele Zeilen in die Gruppe fielen. Das ist genau „wie viele Gäste pro Monat“.

`topK(1)(x)[1]` — der häufigste Wert von `x` in der Gruppe. `topK(1)` gibt ein Array mit einem Element
zurück, `[1]` holt es heraus. So landen sowohl die Spitzenstunde als auch der meistfrequentierte
Eingang in einer einzigen Berichtszeile.

Es lohnt sich, gesondert zu vermerken, was die Abfrage nicht hat: Unterabfragen, temporäre Tabellen
oder Joins. Alles wird in einem einzigen Durchgang über die Daten berechnet.

</details>

**Wenden Sie es an.**

```bash
# Eine Gruppierung über die ganze Tabelle. Die Antwort hat so viele Zeilen, wie es Monate
# gibt, die in den Daten vorkommen.
ch < 03-report.sql
```

**Was Sie sehen sollten** — acht Zeilen, eine pro Monat, mit einer wachsenden Zahl von Gästen.

Nun das Wichtigste — **wie lange die Berechnung dauerte**. Das Format `JSON` am Ende der Abfrage fügt
der Antwort einen Statistikblock hinzu:

```bash
# <<'SQL' … SQL — eine Möglichkeit, mehrzeiligen Text an die Eingabe eines Befehls zu übergeben, ohne Datei.
# Die Anführungszeichen um SQL bedeuten "lass den Inhalt in Ruhe": sonst würde die Shell versuchen,
# die Zeichen innerhalb der Abfrage als ihre eigenen zu interpretieren.
ch <<'SQL'
-- Derselbe Bericht, auf zwei Spalten gekürzt: Monat und Gästezahl.
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM passes
GROUP BY month
ORDER BY month
FORMAT JSON  -- die Antwort nicht als Tabelle, sondern als JSON zurückgeben: es enthält einen Statistikblock
SQL
```

Scrollen Sie die Ausgabe bis zum Ende:

```json
    "statistics": {
        "elapsed": 0.0089,
        "rows_read": 1000000,
        "bytes_read": 4000000
    }
```

**Eine Million Zeilen, etwa neun Millisekunden.** Ihre Zahl wird Ihre eigene sein, aber die
Größenordnung ist dieselbe — einzelne oder Dutzende Millisekunden.

<details>
<summary><b>Wie derselbe Bericht auf einer gewöhnlichen Datenbank erstellt würde</b></summary>

Nehmen wir das vertraute Szenario: das Zutrittsprotokoll liegt in PostgreSQL oder MS SQL, direkt neben
dem Pass-Dienst selbst.

**Was mit der Abfrage passiert.** Eine zeilenorientierte Datenbank speichert einen Datensatz als
Ganzes: Nummer, Zeit, Gastname, Abteilung, Eingang, Typ, Dauer — alles in einer Zeile, eines nach dem
anderen. Um `count()` nach Monat zu berechnen, muss sie jede Zeile durchgehen, was bedeutet, **alle
Felder von der Festplatte zu lesen**, einschließlich der Gastnamen, die im Bericht nicht vorkommen.
Bei einer Million Zeilen sind das Dutzende Sekunden; bei zehn Millionen Minuten.

Sie können das mit einem Index auf `created_at`, einem abdeckenden Index, einer materialisierten View
oder einer voraggregierten Tabelle umgehen. Jede dieser Lösungen funktioniert, und jede bedeutet:
jemand musste **im Voraus wissen, welcher Bericht verlangt würde**. Verlangen Sie eine andere
Aufschlüsselung, und Sie stehen wieder am Anfang.

**Was mit dem Dienst passiert.** Eine schwere Abfrage konkurriert mit der Produktionslast um
Festplatte und Arbeitsspeicher. Während der Bericht berechnet wird, sehen die Wachen am Eingang eine
sich drehende Anzeige. Daher kommt die Regel „Berichte nur nachts“, und daraus — eine Lese-Replik, ein
nächtlicher Export, unstimmige Zahlen und die Frage „warum zeigt der Bericht die Daten von gestern“.

**Was man in der Praxis macht.** Man stellt eine zweite Datenbank daneben, für Analytik gebaut, und
gießt die Daten hinein. Genau das haben wir gerade getan, nur kam die zweite Datenbank in zehn Minuten
aus einem Katalog hoch statt über ein Quartal mit einem Rollout-Projekt.

| | Zeilenorientiert (PostgreSQL) | Spaltenorientiert (ClickHouse) |
|---|---|---|
| Einen Pass nach Nummer finden | Mikrosekunden, über den Index | liest die ganze Spalte |
| Den Status eines Passes ändern | Mikrosekunden | schreibt Parts im Hintergrund neu |
| Gäste nach Monat zählen | Sekunden oder Minuten | Millisekunden |
| Eine Zeile hinzufügen | Routine | besser im Stapel; einzeln ist schlecht |
| Transaktionen | vollwertig | keine im üblichen Sinn |

Keine der Spalten ist „besser“. Das sind Werkzeuge für unterschiedliche Arbeit, und die richtige
Antwort ist fast immer beides, jedes an seinem Platz.

</details>

## Schritt 6. Warum es schnell ist: ein Blick auf die Spalten

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Das Wort „spaltenorientiert“ klingt abstrakt, bis Sie die Zahlen sehen.

```bash
ch <<'SQL'
-- Wir fragen ClickHouse selbst, wie viel Platz jede Spalte der Tabelle belegt.
SELECT
    name,                                                    -- der Name der Spalte
    formatReadableSize(data_compressed_bytes)   AS on_disk,  -- wie viel auf der Festplatte liegt
    formatReadableSize(data_uncompressed_bytes) AS raw,      -- wie viel es ohne Kompression wäre
    round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio  -- wie oft es komprimiert wurde
FROM system.columns   -- eine Systemtabelle: darin beschreibt ClickHouse sich selbst
WHERE database = currentDatabase() AND table = 'passes'   -- nur unsere Tabelle
ORDER BY data_compressed_bytes DESC   -- die schwersten Spalten oben
SQL
```

**Was Sie sehen sollten** — ungefähr dieses Bild:

```
name          on_disk    raw       ratio
guest_name    5.20 MiB   13.4 MiB  2.6
pass_id       3.81 MiB   7.63 MiB  2.0
created_at    1.20 MiB   3.81 MiB  3.2
duration_min  1.10 MiB   1.91 MiB  1.7
entrance      35.1 KiB   1.00 MiB  29.2
pass_type     41.0 KiB   1.05 MiB  26.1
host_dept     52.3 KiB   1.10 MiB  21.4
```

Ihre Zahlen werden Ihre eigenen sein, aber die Verhältnisse sind dieselben.

<details>
<summary><b>Was hier zu sehen ist und warum es die Geschwindigkeit erklärt</b></summary>

**Erstens: jedes Feld liegt getrennt.** Das bedeutet „spaltenorientiert“. In einer zeilenorientierten
Datenbank geht die Festplatte „Zeile 1 ganz, Zeile 2 ganz, Zeile 3 ganz“. Hier ist es „ganz
`created_at` am Stück, ganz `entrance` am Stück, ganz `guest_name` am Stück“.

Daher die Folge, für die das Ganze überhaupt unternommen wurde: **eine Abfrage liest nur die Felder,
die sie nennt.** Der Monatsbericht braucht `created_at` und einen Zeilenzähler. Er liest etwas mehr als
ein Megabyte und rührt die Gastnamen nicht an, die fünfmal so viel belegen.

Eine zeilenorientierte Datenbank liest für dieselbe Abfrage alles. Nicht weil sie schlecht geschrieben
ist, sondern weil die Felder vermischt liegen: um an die Zeit in Zeile 500001 zu gelangen, müssen Sie
den Block lesen, der die Zeit zusammen mit allem anderen enthält.

**Zweitens: sehen Sie sich das `ratio` für `entrance` an.** Neunundzwanzigfach. Eine Million Werte aus
drei Optionen, komprimiert auf fast nichts.

So funktioniert `LowCardinality`: auf der Festplatte liegt ein Wörterbuch aus drei Zeichenketten und
einer Million kleiner Zahlen, und daneben die allgemeine Kompression, für die identische Zahlen
hintereinander ein Geschenk sind. Für `guest_name`, wo jeder Wert verschieden ist, beträgt die
Kompression nur das Zweieinhalbfache.

**Drittens, und das widerspricht der Intuition: Kompression beschleunigt, sie bremst nicht.** Es
scheint, als sei das Dekomprimieren zusätzliche Arbeit. In der Praxis ist der Engpass die Festplatte,
nicht der Prozessor: 35 Kilobyte zu lesen und
zu dekomprimieren ist schneller, als ein Megabyte zu lesen. Deshalb komprimieren spaltenorientierte
Datenbanken aggressiv und gewinnen doppelt — an Platz und an Zeit.

</details>

Bestätigen wir, dass die Abfrage wirklich wenig liest. Wir zählen über eine einzige kleine Spalte:

```bash
ch <<'SQL'
-- Wir zählen Besuche, die länger als hundert Minuten dauern. Die Abfrage nennt eine Spalte von sieben — sie
-- sollte also nur einen kleinen Teil der Tabelle lesen. Das prüfen wir anhand von bytes_read.
SELECT count() FROM passes WHERE duration_min > 100 FORMAT JSON
SQL
```

Sehen Sie sich `bytes_read` am Ende der Ausgabe an und vergleichen Sie es mit dem Datenvolumen der
Tabelle:

```bash
ch <<'SQL'
-- Wir summieren das unkomprimierte Volumen aller Spalten. Das ist genau "wie viele Daten es insgesamt gibt" —
-- die Zahl, mit der bytes_read aus der vorigen Ausgabe verglichen werden soll.
SELECT formatReadableSize(sum(data_uncompressed_bytes)) AS total
FROM system.columns
WHERE database = currentDatabase() AND table = 'passes'
SQL
```

⚠️ **Sie müssen mit dem unkomprimierten Volumen vergleichen, nicht mit der Größe auf der Festplatte.**
`bytes_read` in der Abfragestatistik ist das, was die Datenbank dekomprimiert und gelesen hat — eine
unkomprimierte Zahl. Teilen Sie sie durch `bytes_on_disk`, erhalten Sie einen Bruchteil der
komprimierten Daten, und bei einer Tabelle mit guter Kompression läuft ein solcher „Bruchteil“ leicht
über hundert Prozent. Die Zahlen müssen vergleichbar sein, sonst ist die Zahl hübsch, aber
bedeutungslos.

Die Abfrage lief über eine Million Zeilen und las dabei nur wenige Prozent der Daten: sie las
`duration_min` und rührte `guest_name` nicht an.

## Schritt 7. Die Spitzen finden

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Die zweite Hälfte der Frage der Geschäftsführung betrifft die Schlange am Eingang. Wir zählen, wie
viele Zutritte auf jede Stunde des Tages fielen, und zeichnen es als Balken direkt im Terminal. Die
Abfrage hat zwei Teile — wir zerlegen sie, bevor wir sie ausführen.

<details>
<summary><b>Die Abfrage zerlegen</b></summary>

Die innere Abfrage ist eine gewöhnliche Gruppierung: wie viele Zutritte auf jede Stunde des Tages
fielen. Es kommen elf Zeilen heraus.

Die äußere fügt ihnen ein Bild hinzu. `bar(value, from, to, width)` zeichnet einen Balken aus
Pseudografik — eine eingebaute ClickHouse-Funktion, genau dafür gemacht, dass Sie das Ergebnis im
Terminal betrachten können, ohne Excel zu öffnen.

`max(guests) OVER ()` — eine Fensterfunktion: das Maximum über das **gesamte Ergebnis**, nicht über
eine Gruppe. Die leeren Klammern nach `OVER` bedeuten „das Fenster ist die gesamte Menge der Zeilen“.
Sie wird gebraucht, damit der längste Balken genau fünfzig Zeichen lang ist und die übrigen
proportional sind.

Warum Sie nicht einfach `max(guests)` ohne `OVER ()` schreiben könnten: es wäre eine Aggregatfunktion,
und sie würde die elf Zeilen zu einer zusammenfassen. Die Fensterfunktion berechnet dasselbe, lässt
aber die Zeilen an ihrem Platz.

</details>

```bash
ch <<'SQL'
SELECT
    hour,                                     -- die Stunde des Tages
    guests,                                   -- wie viele Zutritte auf diese Stunde fielen
    bar(guests, 0, max(guests) OVER (), 50) AS chart  -- ein Balken aus Pseudografik
FROM
(
    -- Die innere Abfrage: eine gewöhnliche Gruppierung nach Stunde
    SELECT toHour(created_at) AS hour, count() AS guests
    FROM passes
    GROUP BY hour
)
ORDER BY hour   -- Stunden aufsteigend, damit das Bild von oben nach unten zu lesen ist
SQL
```

**Was Sie sehen sollten** — zwei Höcker: gegen zehn Uhr morgens und gegen drei Uhr nachmittags.

Die Antwort für die Geschäftsführung ist fertig: Spitzen um 10 und um 15 Uhr, und genau zu diesen
Stunden ist es sinnvoll, eine zweite Person an den Eingang zu stellen.

Wenn Sie schon dabei sind, sehen Sie sich das Abfrageprotokoll an — ClickHouse zeichnet dort jede
Abfrage auf:

```bash
ch <<'SQL'
-- ClickHouse zeichnet jede ausgeführte Abfrage in der Systemtabelle system.query_log auf.
SELECT
    event_time,                                       -- wann die Abfrage endete
    query_duration_ms,                                -- wie viele Millisekunden sie dauerte
    formatReadableQuantity(read_rows) AS rows_read,   -- wie viele Zeilen sie las
    formatReadableSize(read_bytes)    AS bytes_read,  -- wie viele Byte sie dabei hochholte
    -- Der Abfragetext: wir fassen die Zeilenumbrüche darin zusammen und nehmen die ersten 50 Zeichen,
    -- sonst passt die Ausgabe nicht auf den Bildschirm
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 50) AS query
FROM system.query_log
WHERE type = 'QueryFinish'  -- nur die abgeschlossenen: für den Start gibt es einen separaten Eintrag
  AND user = 'analyst'      -- nur Ihre, ohne die eigenen Dienstabfragen des Servers
ORDER BY event_time DESC    -- die jüngsten oben
LIMIT 10                    -- und zehn genügen
SQL
```

Die ganze Historie Ihrer Abfragen, mit Dauer und gelesenem Volumen. Es ist eine gewöhnliche Tabelle,
und sie liegt im Datenvolume, nicht im Log-Volume: `Log storage size` aus dem Bestellformular betrifft
die Textlogs des Servers, nicht dieses Protokoll. Die Aufbewahrungsdauer des Protokolls wird durch
`Log TTL` festgelegt. In der Produktion ist es genau diese Tabelle, die die Frage beantwortet „warum
war gestern um sieben Uhr abends alles langsam“.

⚠️ Das Protokoll wird alle paar Sekunden auf die Festplatte geschrieben, daher ist die allerletzte
Abfrage vielleicht noch nicht darin. Wiederholen Sie den Befehl.

## Ein vorhersehbares Scheitern · Einen einzelnen Pass nach Nummer finden

Die Berichte sind fertig. Der Sicherheitsdienst kommt mit einer alltäglichen Bitte: **finde den
Zutritt mit Nummer 424242.**

Die Abfrage drängt sich auf:

```bash
ch <<'SQL'
-- Wir suchen eine einzige Zeile nach Pass-Nummer. SELECT * bedeutet "alle Spalten zurückgeben".
SELECT * FROM passes WHERE pass_id = 424242 FORMAT JSON
SQL
```

Die Zeile wird gefunden. Aber sehen Sie nicht auf sie, sondern auf die Statistik am Ende der Ausgabe —
auf `rows_read`.

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Wie viele Zeilen las die Datenbank, um eine zurückzugeben? Wie viele würde PostgreSQL mit einem Index
> auf `pass_id` lesen? Und warum ist der Unterschied genau so groß?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

`rows_read` wird etwa **1 000 000** betragen. Um eine einzige Zeile zurückzugeben, las ClickHouse die
gesamte `pass_id`-Spalte.

Der Grund ist derselbe, den wir etwas früher im Lab durchgearbeitet haben: **der einzige echte Index
in ClickHouse ist der Sortierschlüssel**, und unserer ist `(created_at, entrance)`. Die Daten sind
nicht nach `pass_id` geordnet, es gibt nichts, wonach man Parts überspringen könnte, und übrig bleibt
nur ein vollständiger Scan.

PostgreSQL mit einem Index auf `pass_id` würde ein paar Baumseiten und eine Zeile lesen. Ein
Unterschied von fünf Größenordnungen — und nicht zugunsten von ClickHouse.

Nun dasselbe, aber richtig gemacht. Der Sicherheitsdienst kennt meist nicht nur die Nummer, sondern
auch, **wann es passierte**:

```sql
-- Dieselbe Suche, aber mit einem Zeitrahmen. Die Bedingung auf created_at landet
-- im Sortierschlüssel, und ClickHouse verwirft alles außerhalb dieses Tages.
SELECT * FROM passes
WHERE created_at >= '2026-03-01' AND created_at < '2026-03-02'
  AND pass_id = 424242
FORMAT JSON
```

Sehen Sie sich `rows_read` jetzt an — ein paar tausend statt einer Million. Die Bedingung auf
`created_at` landete im Sortierschlüssel, und ClickHouse verwarf jeden Part außer dem benötigten
Abschnitt. Der Pass wird vielleicht nicht gefunden, falls er an einem anderen Tag war — worauf es
ankommt, ist nicht der Fund, sondern die Zahl der gelesenen Zeilen.

**Die Lehre reicht über diesen Fehler hinaus.** ClickHouse ist keine „schnelle Datenbank“. Es
ist eine Datenbank, die für eine Art von Arbeit gebaut ist: viele Zeilen über wenige Spalten lesen und
etwas berechnen. Bei dieser Arbeit hängt es zeilenorientierte Datenbanken um Größenordnungen ab. Beim
Gegenteil — eine Zeile finden, ein Feld ändern, eine Transaktion zurückrollen — fällt es um ebenso
viele Größenordnungen hinter sie zurück.

Daher eine praktische Regel, die es mitzunehmen lohnt:

| Aufgabe | Wo |
|---|---|
| Einen Pass bestellen, ändern, stornieren | Eine gewöhnliche Datenbank neben dem Dienst |
| Einen bestimmten Pass nach Nummer finden | Am selben Ort |
| Ein Jahresbericht, Funnels, Spitzen, Trends | ClickHouse |
| Ein Ereignisprotokoll, Metriken, Logs | ClickHouse |

Beide Datenbanken in einem Tenant, beide aus dem Katalog, beide in Minuten hochgezogen. Es besteht
keine Notwendigkeit mehr, „eine für alles“ zu wählen — und das ist vielleicht die wichtigste
Veränderung gegenüber einer Welt, in der jede neue Datenbank eine neue VM und ein neues Ticket
bedeutete.

</details>

## Schritt 8. Ehrlich über das, was hier unbequem ist

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Ein Gast hat seinen Nachnamen geändert; ein Datensatz muss korrigiert werden. In einer gewöhnlichen
Datenbank ist das ein `UPDATE` und Mikrosekunden.

Beachten Sie die Syntax vorab: nicht `UPDATE passes SET …`, sondern `ALTER TABLE … UPDATE`. Das ist
keine Laune der Autoren, sondern eine ehrliche Warnung: **was Sie ausführen, ist keine
Zeilenaktualisierung, sondern eine Änderung an der Tabelle.**

```bash
ch <<'SQL'
-- Wir ändern den Namen eines Gastes in einer Zeile. Der Befehl gibt die Kontrolle sofort zurück, aber die Arbeit
-- endet damit nicht: ClickHouse stellt sie in eine Warteschlange und führt sie im Hintergrund aus.
ALTER TABLE passes UPDATE guest_name = 'Иванов И. И.' WHERE pass_id = 424242
SQL
```

Sehen wir, was passiert:

```bash
ch <<'SQL'
-- Die Warteschlange der aufgeschobenen Änderungen an der Tabelle — eine weitere ClickHouse-Systemtabelle.
SELECT
    command,       -- was genau ihr aufgetragen wurde
    is_done,       -- 1, wenn die Arbeit abgeschlossen ist
    parts_to_do,   -- wie viele Parts noch neu zu schreiben sind
    create_time    -- wann die Aufgabe in die Warteschlange gestellt wurde
FROM system.mutations
WHERE table = 'passes'
ORDER BY create_time DESC
SQL
```

<details>
<summary><b>Was eine Mutation ist und warum sie teuer ist</b></summary>

Der Befehl gab die Kontrolle sofort zurück, während die Arbeit in die Warteschlange gestellt wurde.
Solche aufgeschobene Arbeit heißt **Mutation**, und sie ist in `system.mutations` sichtbar: `is_done`
zeigt, ob sie abgeschlossen ist, `parts_to_do` — wie viele Parts noch neu zu schreiben sind.

Warum neu geschrieben. Die Daten liegen in Spalten in komprimierten Parts. Sie können einen einzelnen
Wert innerhalb eines komprimierten Blocks nicht ändern — der Block muss dekomprimiert, geändert,
komprimiert und neu geschrieben werden. In der Praxis schreibt ClickHouse **den gesamten Part** neu,
mit allen seinen Spalten.

Bei unseren einer Million Zeilen sind das Sekundenbruchteile, und `is_done` ist höchstwahrscheinlich
schon `1`. Bei einer Tabelle mit einer Milliarde Zeilen ist dieselbe Operation stundenlange
Festplattenarbeit und doppelter Platzverbrauch für die Dauer des Neuschreibens.

Daher die Regeln, die in der ClickHouse-Welt als selbstverständlich gelten:

- **Man ändert keine Daten.** Man hängt an. Das Zutrittsprotokoll sollte sich ohnehin nicht ändern:
  ein Zutritt hat entweder stattgefunden oder nicht
- Muss ein Datensatz doch korrigiert werden, schreibt man eine neue Version der Zeile und nimmt beim
  Lesen die frische. Dafür gibt es eine eigene Art von Tabelle (`ReplacingMergeTree`)
- Das Löschen alter Daten geschieht nicht mit einer Abfrage, sondern mit einer Aufbewahrungsdauer
  (`TTL`): „Zeilen verwerfen, die älter als drei Jahre sind“. Dann werden ganze Parts gelöscht, nicht
  einzelne Zeilen
- Massenänderungen werden zu einer einzigen seltenen Operation gebündelt statt zu hundert kleinen

**Und was hier gänzlich fehlt: Transaktionen im üblichen Sinn.** Geld von einem Konto auf ein anderes
so zu übertragen, dass beide Operationen greifen oder keine, lässt sich in ClickHouse nicht machen.
Das ist keine Lücke in der Implementierung — es ist ein bewusster Verzicht zugunsten der
Lesegeschwindigkeit. Genau deshalb wird ClickHouse nicht unter den Pass-Dienst gestellt, sondern neben
ihn.

</details>

## Überprüfung

📍 **Wo:** auf dem Laptop, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

```bash
cd labs/09-clickhouse
# Das Skript liest diese drei Umgebungsvariablen, Sie müssen sie also vor dem Ausführen setzen
# und im selben Terminalfenster.
export KUBECONFIG=~/lab.kubeconfig       # welchen Cluster prüfen
export COZY_TENANT=workshop03            # Ihre Tenant-Nummer
export CH_PASSWORD='ihr-analyst-passwort'  # das, das Sie beim Bestellen von ClickHouse gesetzt haben
./check.sh
```

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man es installiert,
ist am Anfang von Lab 0 beschrieben. Sie können das Lab ohne WSL abschließen, aber es wird keinen
Artefakt-Bericht geben.

Das Skript prüft nicht die Tatsache, dass der Dienst erstellt wurde, sondern die Arbeit in der Sache:
die Tabelle existiert, es gibt nicht weniger als eine Million Zeilen, die Daten haben ausgeprägte
Spitzen, der Monatsbericht wird in Millisekunden berechnet, und eine Abfrage über eine einzige Spalte
liest einen kleinen Bruchteil der Tabelle.

Das Passwort gelangt nicht in den Bericht.

## Aufräumen

```bash
# Der Arbeits-Pod speichert nichts: die gesamte Arbeit geschah innerhalb von ClickHouse, und der Pod
# reichte nur Abfragen weiter. Löschen Sie ihn ohne Bedauern.
kubectl delete pod ch-workbench
```

ClickHouse selbst wird im Dashboard gelöscht: Anwendung `analytics` → löschen.

Warum das billig ist. Eine Analytik-Datenbank in klassischer Infrastruktur ist eine VM (eher drei),
Festplatten, Installation, Konfiguration, Monitoring und eine Person, die für all das verantwortlich
ist. Zurückgeben können Sie sie nicht: der Platz ist bereits zugewiesen, die Lizenz gekauft, und „was,
wenn wir sie brauchen“. Hier haben Sie einen Dienst für eine Stunde genommen und ihn in zehn Sekunden
zurückgegeben, und der Platz, den er belegte, wurde freigegeben.

⚠️ **Beim Löschen verschwindet auch die Tabelle.** Eine Million Zeilen werden in Sekunden neu erzeugt,
im Lab ist das also kein Verlust. Wenn Sie etwas Echtes hineinlegen, schalten Sie zuerst Backups ein —
sie sind ein eigener Abschnitt im Bestellformular.

## Was wir jetzt können

- Den Unterschied zwischen einer zeilenorientierten und einer spaltenorientierten Datenbank nicht in
  Worten, sondern in Zahlen von Kompression und gelesenen Byte erklären
- ClickHouse aus dem Katalog hochziehen und verstehen, warum das Formular Shards, Repliken und Keeper
  hat
- Einen Sortierschlüssel bewusst wählen und vorhersagen, welche Abfragen schnell sein werden
- Plausible Testdaten innerhalb der Datenbank erzeugen, ohne Skripte oder Exporte
- Die Frage „wann sind die Spitzen“ mit einer Abfrage beantworten statt mit einem Export nach Excel
- Verstehen, wo ClickHouse verliert, und es nicht dort einsetzen, wo eine gewöhnliche Datenbank
  gebraucht wird

## Und in vSphere wäre das

Eine separate Maschine für die Analytik-Datenbank — und es stellt sich fast sofort heraus, dass eine
nicht genügt: Sie brauchen eine zweite für die Replik und Platz für die täglichen Exporte. Der Bericht
„wie viele Gäste pro Monat“ wird zu einem Infrastrukturprojekt mit eigener Hardware, eigenem Monitoring
und eigenem Verantwortlichen.

Hier — ein Katalogeintrag und zehn Minuten, samt Erzeugung einer Million Zeilen.

**Wo vSphere bequemer ist, ehrlich gesagt.** Eine VM mit einer Datenbank ist eine Maschine, an die Sie
herantreten können. Sich über SSH anmelden, top ansehen, eine Konfiguration anpassen, ein Skript
daneben ablegen, vor einer riskanten Operation einen Snapshot nehmen und zurückrollen, falls es nicht
klappte. Ein Managed Service gibt Ihnen das **mit Absicht** nicht: im Tenant wird Ihnen weder ein
`exec` in einen Pod noch in die Logs erlaubt. Sie verwalten den Dienst über das Bestellformular, nicht
über die Maschine darunter.

Solange alles funktioniert, ist das ein Vorteil — weniger Möglichkeiten, etwas kaputtzumachen. Wenn
sich etwas seltsam verhält, wird diese Einschränkung deutlich spürbar: der gewohnte Handlungssatz des
Administrators ist nicht verfügbar, und es bleibt nur, sich an denjenigen zu wenden, der die Plattform
betreibt. Das Abfrageprotokoll und die Metriken decken einen Teil dieses Schmerzes ab, aber nicht
alles, und so zu tun, als deckten sie alles ab, wäre unehrlich.

Und eine zweite Sache, an die man sich später erinnert. Ein Managed Service bedeutet fremde
Standardeinstellungen. Die ClickHouse-Version, die Parameter für das Zusammenführen der Parts, die
Speichereinstellungen sind für Sie gewählt. Meist sinnvoll, manchmal nicht für Ihre Last, und Sie
werden sie nicht so frei ändern können wie auf Ihrer eigenen Maschine.
