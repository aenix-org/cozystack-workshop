# Lab 10 · Dokumentenspeicher

| | |
|---|---|
| **Zeit** | 45 Minuten |
| **Was es zeigt** | Daten unterschiedlicher Form lassen sich ohne leere Spalten und ohne eine eigene Tabelle für jeden Fall speichern — und Sie bezahlen dafür mit Disziplin |
| **Was Sie brauchen** | Den Cluster aus Lab 0 und `~/lab.kubeconfig`; Zugriff auf das Dashboard Ihres Tenants; eine Tenant-Nummer der Form `workshopXX`; die Bereitschaft, JavaScript-Code zu lesen |

> ⚠️ **Dieses Lab ist dicht, und es verlangt von Ihnen, JavaScript-Code zu lesen.** Gehen Sie es mit
> frischem Kopf an, nicht direkt nach einem anderen langen Lab. Der Code wird überall Zeile für Zeile
> durchgegangen — Sie müssen die Sprache nicht im Voraus beherrschen.

## Warum das wichtig ist

Der Dienst „Ausweise“ wurde mit einem einzigen Ausweistyp ausgerollt — einem Einmalausweis für ein
bestimmtes Datum. Einen Monat später kam der Kunde mit Ergänzungen zurück, alle davon nachvollziehbar:

| Ausweistyp | Was zusätzlich gebraucht wird |
|---|---|
| Einmalig | Datum, Eingang |
| Wöchentlich | ein Von-/Bis-Zeitraum, eine Liste von Eingängen, eine Markierung, ob der Ausweis zurückgegeben wurde |
| Fahrzeug | Kennzeichen, Modell, ob ein Anhänger vorhanden ist, Gewicht, Parkplatznummer |
| Gruppe | Organisation, Ansprechpartner, Begleitperson, eine Liste der Teilnehmer mit ihrem Alter |

In einer Tabelle mit festen Spalten hat dieses Problem zwei Lösungen, und beide sind schlecht.

**Lösung eins: eine einzige Tabelle mit allen Spalten.** Sie fügen `car_plate`, `car_model`,
`trailer`, `weight_kg`, `parking`, `valid_from`, `valid_to`, `badge_returned`,
`organization`, `contact`, `escort` hinzu — und ein Einmalausweis hat elf leere Felder von
fünfzehn. Ein halbes Jahr später gibt es dreißig Spalten, niemand erinnert sich, welche davon
für welchen Typ Pflicht sind, und das allererste `NOT NULL`-Feld bricht die Hälfte der Szenarien.

**Lösung zwei: eine Tabelle pro Typ.** Vier Tabellen statt einer, plus eine fünfte, die sie
zusammenbindet, damit der Sicherheitsdienst am Tor eine kombinierte Liste anzeigen kann. Jeder neue
Ausweistyp bedeutet eine Schema-Migration, ein Release und eine Abnahme. Und die Abfrage „zeig mir
alle Ausweise für heute“ wird zu einer `UNION` aus vier Teilen, die bearbeitet werden muss, sobald
Sie einen fünften hinzufügen.

**Die Teilnehmerliste eines Gruppenausweises passt in keine von beiden.** Sie ist in ihrer Länge
variabel und braucht daher noch eine weitere Tabelle mit einem Verweis zurück auf den Ausweis.

Es gibt einen dritten Weg: einen Speicher, der nicht verlangt, dass jeder Datensatz dieselbe Form hat.
In diesem Lab stellen wir MongoDB auf, legen vier Ausweise mit vier verschiedenen Formen hinein und
suchen quer über sie hinweg. Und dann sehen wir uns ehrlich an, was wir dafür bezahlen — denn wir
bezahlen, und nicht wenig.

Kubernetes- und MongoDB-Begriffe werden in diesem Lab erklärt, wenn sie zum ersten Mal auftauchen,
und einige sind im kleinen Glossar unten gesammelt.

## Mini-Glossar

| Begriff | Was es ist | Wie … nur |
|---|---|---|
| **Dokument** | Ein einzelner Datensatz. Eine Menge von Feldern, verschachtelten Objekten und Listen | **Eine Tabellenzeile**, aber der Nachbardatensatz kann eine andere Feldmenge haben, und das ist kein Fehler |
| **Collection** | Eine Menge von Dokumenten | **Eine Tabelle**, aber standardmäßig ohne Schema. Sie können ein Schema hinzufügen, aber das ist eine eigene Entscheidung |
| **BSON** | Das Binärformat, in dem die Dokumente gespeichert werden | Wie JSON, aber mit Typen: ein Datum ist ein Datum, kein String |
| **Replica Set** | Mehrere Kopien, eine primäre, die übrigen übernehmen | **Ein HA-Cluster**, aber die Kopien stimmen untereinander ab, deshalb brauchen Sie eine ungerade Zahl davon |
| **`mongosh`** | Die MongoDB-Kommandoshell | **PowerCLI**, aber es ist vollwertiges JavaScript, keine Abfragesprache |

Die übrigen Wörter in diesem Lab — _id, Sharding, Dotted Field Notation, Sparse Index,
Schema-Validator, $lookup — werden unterwegs eingeführt, in dem Schritt, in dem sie zuerst gebraucht
werden. Sie müssen sie sich jetzt nicht einprägen: losgelöst vom Handeln bleiben sie nicht hängen.

<details>
<summary><b>Falls Sie die ganze Liste auf einmal sehen möchten</b></summary>

| Begriff | Was es ist | Wie … nur |
|---|---|---|
| **`_id`** | Der eindeutige Schlüssel des Dokuments | **Ein Primärschlüssel**, aber er wird für Sie erzeugt, wenn Sie ihn nicht setzen |
| **Sharding** | Aufteilen der Daten über Replica Sets | Es geht um Volumen, nicht um Zuverlässigkeit |
| **Dotted Field Notation** | Ein verschachteltes Feld über einen Punkt erreichen: `car.plate` | **Ein Dateipfad in einem Ordner**, aber es reicht auch in Listen hinein: `members.age` |
| **Sparse Index** | Ein Index, der nur die Dokumente enthält, in denen das Feld vorhanden ist | Eine schlichte Notwendigkeit dort, wo das Feld nur in einer Minderheit der Datensätze vorkommt |
| **Schema-Validator** | Eine Regel, die ein Dokument erfüllen muss | **Formularvalidierung vor dem Speichern**, aber sie wird manuell und nachträglich eingeschaltet — standardmäßig gibt es kein Schema |
| **`$lookup`** | Eine Möglichkeit, Daten aus einer anderen Collection heranzuziehen | **Ein JOIN**, aber einseitig und merklich teurer: die Verknüpfung wird nicht von einem Optimizer gewählt, sondern per Brute Force ausgeführt |

</details>

## Was im Lab-Ordner liegt

Sie haben alle Dateien bereits — Sie haben sie zusammen mit dem Repository bekommen. Es gibt nichts zu
erstellen oder abzutippen: wo unten `kubectl apply -f name.yaml` steht, wird die Datei von hier genommen.

```bash
cd labs/10-mongodb
```

| Datei | Was es ist | Wann Sie sie brauchen |
|---|---|---|
| `mongodb.yaml` | Die Bestellung einer Dokumentendatenbank — dasselbe wie der Knopf im Dashboard | Sie wenden sie **im Tenant** an, nicht im `lab`-Cluster |
| `passes.js` | Füllen der Datenbank mit Ausweisen verschiedener Typen: einmalig, wöchentlich, Fahrzeug | Sie führen es in der Datenbank aus |
| `validator.js` | Regeln zum Validieren von Dokumenten — damit kein Müll in die Datenbank gerät | Sie führen es als Nächstes aus |
| `check.sh` | Eine Prüfung, dass Dokumente verschiedener Form nebeneinander liegen und ungeeignete abgewiesen werden | Sie führen es am Ende des Labs aus |

## Schritt 1. MongoDB bestellen

📍 **Wo:** im Browser, im Cozystack-Dashboard, in Ihrem Tenant.

Tenant → **Create application** → `MongoDB`.

| Feld | Wert | Warum |
|---|---|---|
| Name | `passes` | kurz — Sie werden ihn später in Adressen eintippen müssen |
| Version | `v8` | der aktuelle Zweig |
| Replicas | **1** | eine Trainings-Testumgebung. Warum es in Produktion drei sind, steht gleich darunter |
| Size | `5Gi` | vier Dokumente belegen Bytes, der Rest ist Reserve |
| Storage class | `replicated` | die Daten werden in drei Kopien auf verschiedenen Nodes abgelegt |
| Resources preset | `s1.small` | 1 Prozessor, 2 GB |
| Sharding | aus | Sie sharden, wenn die Daten nicht auf einen einzelnen Server passen |
| Users | den Benutzer `passapp`, das Passwort **explizit** setzen | unter ihm werden wir arbeiten |
| Databases | die Datenbank `passes`, mit `passapp` in der Admin-Rolle | ohne Rolle wird der Benutzer nicht akzeptiert |
| External | aus | wir stellen sie nicht nach außen bereit |

⚠️ **Setzen Sie das Passwort unbedingt von Hand und notieren Sie es.** Wenn Sie das Feld leer lassen,
erzeugt der Chart selbst ein Passwort — und legt es in ein Secret, das im Dashboard nicht sichtbar ist.
Sie bleiben mit einer funktionierenden Datenbank zurück, zu der Sie sich nicht verbinden können.

Zwei Wörter, die Ihnen von hier an mehr als einmal begegnen. **Ein Chart** ist die Vorlage, die die
Plattform verwendet, um einen Dienst bereitzustellen: eine Menge von Templates plus die Werte, die Sie
im Formular ausgefüllt haben. Am nächsten kommt eine Vorlage einer virtuellen Maschine mit einem
Einrichtungsassistenten. **Ein Secret** ist ein Cluster-Objekt, das Passwörter und Schlüssel enthält;
im Dashboard wird es als eigener Reiter auf der Anwendungskarte angezeigt.

⚠️ **Ein Benutzer ohne Rolle bedeutet einen Fehlschlag beim Deployment.** Wenn Sie `passapp` im
Abschnitt Users anlegen, ihm aber im Abschnitt Databases in keiner Datenbank eine Rolle zuweisen, hält
der Chart mit dem Fehler „user is not assigned to any database role“ an. Das ist keine Störung, sondern
ein Schutz vor einem nutzlosen Benutzer, auch wenn die Meldung nicht sofort zu finden ist.

⚠️ **Eine einzige Kopie ist nicht MongoDB in seiner normalen Form, und es lohnt sich zu verstehen,
warum.** MongoDB ist auf eine Menge von drei Replicas ausgelegt: sie wählen per Abstimmung eine primäre,
und der Verlust einer davon hält die Arbeit nicht an. Eine Abstimmung braucht eine Mehrheit, deshalb wird
die Zahl der Kopien ungerade gemacht. Bei einer einzigen Kopie gibt es niemanden zum Abstimmen, und
dafür schaltet der Chart einen speziellen `unsafeFlags`-Modus ein. Im Lab spart das
Testumgebungs-Ressourcen; in Produktion dürfen Sie es so nicht machen.

### Genauer betrachtet: was in mongodb.yaml steckt

Der Lab-Ordner enthält `mongodb.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: MongoDB
metadata:
  name: passes
  namespace: tenant-workshopXX
spec:
  replicas: 1
  size: 5Gi
  storageClass: replicated
  resourcesPreset: s1.small
  version: v8
  external: false
  sharding: false
  users:
    passapp:
      password: YourPasswordHere
  databases:
    passes:
      roles:
        admin:
          - passapp
  backup:
    enabled: false
```

`namespace: tenant-workshopXX` — **Managed Services leben in Ihrem Tenant auf dem
Management-Cluster, nicht im Lab-Cluster aus Lab 0.** Das sind zwei verschiedene Cluster.

`users` und `databases` sind zwei verknüpfte Maps, und die Verknüpfung zwischen ihnen ist
verpflichtend. `users` listet die Konten, `databases` listet die Datenbanken und wer in ihnen was tun
darf. `roles.admin` gewährt das Recht, innerhalb einer einzelnen Datenbank zu lesen, zu schreiben und
die Struktur zu ändern; `roles.readonly` — nur zu lesen.

⚠️ Benutzer werden in der Systemdatenbank `admin` angelegt, die Rechte aber in Ihrer gewährt. Deshalb
wird die Connection-String `authSource=admin` brauchen — mehr dazu gesondert im nächsten Schritt.

`sharding: false` — ein gewöhnliches Replica Set. Sharding einzuschalten fügt Config-Server und Router
hinzu: drei oder vier zusätzliche Pods für eine Datenaufteilung, die wir nicht brauchen.

Diese Datei wird **nicht auf den Lab-Cluster** angewendet, sondern auf den Tenant — was bedeutet, dass
auch die Zugangsdatei die des Tenants sein muss. Der kubeconfig (die Datei mit der Adresse des Clusters
und den Anmeldedaten) wird im Dashboard geholt: **Info → der Reiter Secrets →
`kubeconfig-tenant-workshopXX`**. Speichern Sie ihn unter `~/.kube/workshop` — dieser Pfad wird in jedem
Lab verwendet.

Jetzt bestellen wir die Datenbank als Text. Der Befehl installiert selbst nichts: er übergibt die
Bestellung an die Plattform, und die Plattform bringt auf ihrer Seite alles Nötige hoch.

```bash
# apply = "den Cluster in den Zustand bringen, der in der Datei beschrieben ist".
#   --kubeconfig ~/.kube/workshop  welche Zugangsdatei verwendet wird. Ohne sie nimmt kubectl
#                                  den Standardzugang und verirrt sich in den falschen Cluster
#   -f mongodb.yaml                welche Datei angewendet wird (-f = file)
kubectl --kubeconfig ~/.kube/workshop apply -f mongodb.yaml
```

**Was Sie sehen sollten** — `mongodb.apps.cozystack.io/passes created`. Das Wort `created`
bedeutet, dass die Bestellung angenommen wurde, nicht dass die Datenbank bereit ist.

Die Bereitschaft dauert drei bis fünf Minuten: der Server kommt hoch, das Replica Set wird
initialisiert, die Benutzer werden angelegt. Sie können so beobachten, wie es vorangeht:

```bash
# get = "zeig mir, was da ist". Die Spalte READY sagt Ihnen, ob die Bestellung einen funktionierenden Zustand erreicht hat.
#   -n tenant-workshopXX  in welchem namespace geschaut wird (ein namespace ist eine Partition innerhalb
#                         des Clusters; Ihr Tenant ist genau ein solcher separater namespace)
kubectl --kubeconfig ~/.kube/workshop get mongodb passes -n tenant-workshopXX
```

⚠️ **Das Secret `mongodb-passes-credentials` im Dashboard wird in den ersten Minuten ein leeres
Passwort haben.** Es enthält die Zugangsdaten des Dienstkontos `databaseAdmin`, und der Chart füllt
sie erst aus, nachdem der Operator (das Programm der Plattform, das die Bestellung in einen
funktionierenden Zustand treibt und dann darüber wacht) die Benutzer angelegt hat — das heißt bei der
nächsten Runde des Abgleichs des Zustands. Warten Sie ein paar Minuten und aktualisieren Sie die Seite.
Dieses Konto brauchen wir nicht: wir arbeiten unter `passapp`, dessen Passwort Sie selbst gesetzt haben.

## Schritt 2. Einen Arbeits-Pod erstellen

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Die Aufteilung ist dieselbe wie in den anderen Labs über Managed Services.

**MongoDB lebt in Ihrem Tenant auf dem Management-Cluster.** Ihre Rolle im Tenant erlaubt Ihnen,
Dienste zu bestellen und zu löschen, aber nicht, dort eigene Pods laufen zu lassen oder Ports
weiterzuleiten.

**Ihr Arbeitsboden ist der Lab-Cluster aus Lab 0.** Von dort gehen wir los, über die interne Adresse:

```
mongodb-passes-rs0.tenant-workshopXX.svc.cozy.local:27017
```

| Teil | Was er bedeutet |
|---|---|
| `mongodb-` | das Präfix, das der Cozystack-Katalog dem Anwendungsnamen voranstellt |
| `passes` | der Name, den Sie im Dashboard gesetzt haben |
| `-rs0` | der Name des Replica Sets. Der Operator benennt den Service des ersten Sets so |
| `tenant-workshopXX` | Ihr Tenant. Setzen Sie Ihre eigene Nummer ein |
| `svc.cozy.local` | die Zone der internen Namen des Management-Clusters |
| `27017` | der Standardport von MongoDB |

**Ein Pod** ist die kleinste Ausführungseinheit in Kubernetes: einer oder mehrere Container, die immer
auf demselben Node leben und sich eine einzige Adresse teilen. Das nächste Analogon ist eine virtuelle
Maschine, die für eine einzige Aufgabe hochgebracht wird, nur dass er in Sekunden erstellt und ohne
Bedauern heruntergefahren wird. Wir bringen einen solchen Pod mit dem Image `mongo:8.0` hoch: darin
sitzt `mongosh` — die MongoDB-Kommandoshell — und Sie müssen sie nicht auf Ihrem Laptop installieren.

Die Datenbankadresse zusammen mit Benutzername und Passwort wird als eine einzige Zeile geschrieben —
sie heißt Connection-String. Gehen wir sie durch, bevor wir den Befehl eintippen.

<details>
<summary><b>Die Connection-String durchgehen</b></summary>

```
mongodb://passapp:password@host:27017/passes?authSource=admin&directConnection=true
```

`mongodb://` — das Schema. Dann Benutzername, Passwort, Adresse, Port.

`/passes` nach dem Port — **die Standarddatenbank**. Sie verbinden sich und sind sofort in ihr, ohne
einen gesonderten Befehl.

`authSource=admin` — **in welcher Datenbank nach dem Konto selbst gesucht wird.** Der Benutzer `passapp`
wird in der Systemdatenbank `admin` angelegt, während seine Rechte in `passes` gewährt werden. Ohne
diesen Parameter geht der Treiber das Konto in `passes` suchen, findet es nicht und liefert
„Authentication failed“ zurück — eine Meldung, die wie „falsches Passwort“ aussieht und die Suche in
die falsche Richtung schickt. Das ist der häufigste Fehler bei einer ersten Verbindung zu einem
Managed MongoDB.

`directConnection=true` — „verbinde dich direkt zu diesem Server, versuch nicht, die Zusammensetzung
des Replica Sets herauszufinden“. Ohne diesen Parameter fragt der Treiber den Server, wer sonst noch im
Set ist, und bekommt die internen Namen der Mitglieder zurück, die sich von außen nicht immer auflösen
lassen. Bei einer einzigen Kopie gibt es nichts herauszufinden, also ist es einfacher, das direkt zu
sagen. In Produktion mit drei Kopien ist es umgekehrt: Sie setzen den Parameter nicht, denn was Sie
dort wollen, ist genau der automatische Wechsel zu einer neuen primären, wenn die alte ausfällt.

**Warum Adresse und Passwort in eine Pod-Variable gehen und nicht direkt in den Befehl.** Alles, was
Sie in `kubectl exec` schreiben, landet in Ihrer Shell-History und in der Prozessliste auf dem Node.
Die Pod-Variable wird einmal gesetzt, und danach taucht das Passwort in keinem Befehl mehr auf.

Das löst das Problem nicht vollständig, und es ist ehrlicher, das vorab zu sagen: ein über `--env`
übergebener Wert bleibt in der Spec des Pods — sichtbar für jeden mit dem Recht, Pods in Ihrem
namespace zu lesen, er liegt in der Cluster-Datenbank und landet im Audit-Log. Für eine
Trainings-Testumgebung ist das vertretbar, für eine Produktions-nicht: dort legen Sie das Passwort in
ein Secret und binden es über `envFrom` ein. Genau darum geht es im Lab über Secrets.

</details>

Bringen Sie den Pod hoch. Setzen Sie Ihre Tenant-Nummer für `workshopXX` und Ihr Passwort für
`YourPasswordHere` ein:

```bash
# KUBECONFIG — welche Zugangsdatei kubectl verwendet. Hier ist es der Lab-Cluster
# aus Lab 0: nur in ihm starten Sie Ihre eigenen Pods, der Tenant lässt Sie damit nicht hinein.
export KUBECONFIG=~/lab.kubeconfig

# run = "einen einzelnen Pod erstellen und dieses Image darin ausführen". Die Flags, die zählen:
#   --image=mongo:8.0        was auszuführen ist. Das Image enthält die mongosh-Shell
#   --restart=Never          genau einen einzelnen Pod erstellen, kein Deployment. Sonst würde
#                            der Cluster ihn jedes Mal wieder hochbringen, wenn er fertig ist
#   --env=MONGO_URI=...      eine Umgebungsvariable im Pod. Das Passwort bleibt in ihr,
#                            statt in jedem folgenden Befehl wiederholt zu werden
#   --command -- sleep 86400 womit der Container beschäftigt gehalten wird. Das mongo-Image würde standardmäßig den
#                            Datenbankserver starten — den brauchen wir nicht, wir brauchen einen lebenden Container,
#                            in den man hineinsteigen kann. 86400 Sekunden sind ein Tag
kubectl run mongo-workbench \
  --image=mongo:8.0 \
  --restart=Never \
  --env=MONGO_URI="mongodb://passapp:YourPasswordHere@mongodb-passes-rs0.tenant-workshopXX.svc.cozy.local:27017/passes?authSource=admin&directConnection=true" \
  --command -- sleep 86400

# wait = "gib die Kontrolle nicht zurück, bis die Bedingung erfüllt ist"
#   --for=condition=Ready  wir warten, bis der Pod selbst Bereitschaft meldet
#   --timeout=180s         wie lange zu warten ist, bevor ein Fehler zurückgegeben wird, statt ewig zu hängen
kubectl wait --for=condition=Ready pod/mongo-workbench --timeout=180s
```

**Was Sie sehen sollten** — `pod/mongo-workbench created`, gefolgt von
`pod/mongo-workbench condition met`.

Jetzt richten wir einen kurzen Befehl ein, damit wir das nicht jedes Mal komplett eintippen müssen, und
prüfen die Verbindung zur Datenbank:

```bash
# mo — eine Abkürzung, die lebt, bis Sie das Terminalfenster schließen: so
# deklarieren Sie Ihren eigenen Befehl in der Shell.
#   exec        etwas in einem bereits laufenden Pod ausführen
#   -i          die Standardeingabe nach innen weiterleiten: ohne sie können Sie kein Programm hineingeben
#   sh -c '...' wir starten eine Shell im Pod, damit sie $MONGO_URI selbst einsetzt.
#               Die Anführungszeichen sind mit Absicht einfach: der Pod soll die Variable einsetzen, nicht
#               Ihr Terminal — sonst landet das Passwort in der Befehls-History
#   --quiet     die mongosh-Begrüßung nicht ausgeben, nur die Antwort lassen
mo() { kubectl exec -i mongo-workbench -- sh -c 'mongosh --quiet "$MONGO_URI"'; }

# ping — eine Dienstanfrage, "lebst du?". Sie liest und schreibt nichts, sie prüft die Verbindung
# und dass die Zugangsdaten akzeptiert wurden. Das Zeichen | sendet diese Zeile an die Eingabe von mongosh
echo 'db.runCommand({ ping: 1 })' | mo
```

**Was Sie sehen sollten** — `{ ok: 1 }`.

`mongosh` liest das Programm von der Standardeingabe, sodass genau dieser Befehl ganze Dateien
verschlucken kann: `mo < passes.js`.

⚠️ **Wenn die Antwort `Authentication failed` lautet** — die Verbindung ist da, aber die Zugangsdaten
sind falsch. Prüfen Sie der Reihe nach: `authSource=admin` in der Connection-String; das Passwort stimmt
mit dem überein, das Sie im Dashboard gesetzt haben; der Benutzername ist `passapp`. Um den Pod mit einer
korrigierten String neu zu erstellen: `kubectl delete pod mongo-workbench` und von vorn beginnen.

⚠️ **Wenn die Antwort `getaddrinfo ENOTFOUND` lautet oder die Verbindung hängt** — der Name löst sich
nicht auf. Höchstwahrscheinlich haben Sie Ihre eigene Nummer nicht für `workshopXX` eingesetzt, oder die
Anwendung im Dashboard ist noch nicht bereit.

Es ist bequemer, die Daten nicht Befehl für Befehl zu untersuchen, sondern in einer lebenden Shell — sie
bleibt offen, und Sie tippen Abfragen darin eine nach der anderen ein:

```bash
# -it statt -i: ein t kommt hinzu — "gib mir ein Terminal". Daher der Eingabeprompt,
# die Befehls-History auf der Pfeil-nach-oben-Taste und die Hervorhebung. Ohne t würde die Shell stumm auf Eingabe warten.
kubectl exec -it mongo-workbench -- sh -c 'mongosh "$MONGO_URI"'
```

**Was Sie sehen sollten** — einen Prompt der Form `passes>`: den Namen der Datenbank, in der Sie
gelandet sind.

Von hier an werden die Befehle im Text so gezeigt, wie Sie sie in dieser Shell eintippen. Zum Verlassen
— `exit`.

## Schritt 3. Vier Ausweise mit vier verschiedenen Formen einlegen

📍 **Wo:** auf dem Laptop, im Lab-Cluster.

Die Datei `passes.js` ist ein Programm für `mongosh`: es fügt der Datenbank vier Ausweise hinzu und gibt
aus, wie viele Dokumente es geworden sind. Man muss keine einzige Tabelle im Voraus erstellen, und gleich
darunter steht die Erklärung, warum.

```bash
cd labs/10-mongodb
# Das Zeichen < speist den Inhalt der Datei in die Eingabe des Befehls ein — dasselbe, als ob Sie
# den gesamten Text der Datei von Hand in der mongosh-Shell eintippten.
mo < passes.js
```

**Was Sie sehen sollten** — `документов в коллекции: 4`.

<details>
<summary><b>Durchgehen, was wir eingelegt haben</b></summary>

Das Erste, was auffällt: **es gab kein `CREATE TABLE`**. Die Collection `passes` entstand im Moment des
ersten Inserts. Sie hat kein Schema — das heißt, standardmäßig hat MongoDB keine Meinung dazu, welche
Felder ein Dokument haben darf.

Nun zu den Dokumenten.

**Der Einmalausweis** — die kürzeste Form:

```js
  {
    type: "разовый",
    guest: "Иванов Иван Иванович",
    host: "petrov@corp.ru",
    entrance: "Северная",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "собеседование"
  }
```

Sechs Felder, alle skalar. In einer Tabelle wäre das eine gewöhnliche Zeile.

`ISODate(...)` ist kein String, sondern genau ein Datum. MongoDB speichert Dokumente im binären
BSON-Format, in dem ein Wert einen Typ hat: Datum, Ganzzahl, Gleitkommazahl, Boolean, Binärdaten. Das
ist ein wichtiger Unterschied zu reinem JSON: Sie können nach einem Datum vergleichen und sortieren, nach
dem String `"2026-09-01"` aber nur, wenn Sie Glück mit der Schreibweise haben.

**Der Wochenausweis** — statt `valid_on` gibt es jetzt `valid_from` und `valid_to`, und statt eines
einzelnen Eingangs ist `entrances` jetzt **eine Liste**:

```js
    entrances: ["Северная", "Южная"],
    badge_returned: false
```

Eine Liste direkt im Feld. In einer Tabelle hätte das entweder eine eigene Tabelle „Ausweis — Eingang“
oder einen kommagetrennten String gebraucht, in dem später niemand mehr ordentlich suchen konnte.

Der Einmalausweis hat überhaupt kein Feld `badge_returned`. Nicht `NULL`, nicht leer — **es gibt kein
solches Feld in diesem Dokument.** Das sind verschiedene Dinge, und sie werden verschieden gesucht.

**Der Fahrzeugausweis** — ein **verschachteltes Objekt** ist aufgetaucht:

```js
    car: {
      plate: "А123ВС174",
      model: "ГАЗель Next",
      trailer: false,
      weight_kg: 3500
    },
```

Alles, was mit dem Fahrzeug zu tun hat, sitzt innerhalb eines einzelnen Feldes `car`. Das ist kein String
mit JSON darin, sondern eine vollwertige Struktur: Sie können nach `car.plate` suchen und einen Index
darauf aufbauen.

**Der Gruppenausweis** — **eine Liste von Objekten**:

```js
    members: [
      { name: "Орлов Пётр", age: 16 },
      { name: "Волкова Мария", age: 15 },
      { name: "Зайцев Илья", age: 17 }
    ]
```

Eine Teilnehmerliste variabler Länge, jeder mit eigenen Feldern. Und — beachten Sie — dieses Dokument
**hat kein Feld `guest`**: an der Stelle eines Gastes steht eine Organisation und ein Ansprechpartner.
Die Form des Dokuments unterscheidet sich von den anderen nicht um ein Feld, sondern im Wesen.

Genau dafür ist das Dokumentenmodell da. Keine leeren Spalten, keine vier Tabellen, keine fünfte, die sie
zusammenbindet.

</details>

## Schritt 4. Quer über Dokumente verschiedener Form suchen

📍 **Wo:** in der `mongosh`-Shell im Arbeits-Pod.

Alles, was der Sicherheitsdienst und die Leitung brauchen, sind gewöhnliche Abfragen. Sie lesen sich alle
gleich: `db` ist die Datenbank, mit der Sie verbunden sind, `passes` ist die Collection darin, dann kommt
nach einem Punkt die Aktion, und in den Klammern steht die Auswahlbedingung. Die Bedingung wird immer als
Objekt geschrieben: „Feld — welchen Wert es haben soll“.

**Alle Ausweise für ein bestimmtes Datum:**

```js
// find = "zeig die Dokumente, die der Bedingung entsprechen"
// { valid_on: ISODate(...) } — das Feld valid_on des Dokuments muss genau diesem
// Datum gleichen. ISODate ist ein Datum, kein String: der Vergleich erfolgt nach Zeit, nicht nach Schreibweise
db.passes.find({ valid_on: ISODate("2026-09-02T07:30:00Z") })
```

**Was Sie sehen sollten** — ein einzelnes Dokument, Kusnezows Fahrzeugausweis.

**Nur Fahrzeugausweise:**

```js
// Eine Bedingung auf ein gewöhnliches String-Feld: eine vollständige Übereinstimmung, hier gibt es keine Groß-/Kleinschreibungs-Toleranz
db.passes.find({ type: "автомобильный" })
```

**Suche nach Kennzeichen — durch einen Punkt in ein verschachteltes Objekt hineinreichen:**

```js
// "car.plate" — ein Pfad in das Dokument: das Feld plate innerhalb des Objekts car.
// Die Anführungszeichen um den Pfad sind verpflichtend, sonst liest JavaScript den Punkt auf seine eigene Weise
db.passes.find({ "car.plate": "А123ВС174" })
```

<details>
<summary><b>Warum das funktioniert und wie es sich von „einem String mit JSON darin“ unterscheidet</b></summary>

`"car.plate"` ist Dotted Notation für einen Pfad zu einem Feld. MongoDB versteht die Struktur des
Dokuments und kann hineinreichen, statt das verschachtelte Objekt als einen Brocken Text zu speichern.

Der Unterschied ist praktisch. Läge `car` in einer relationalen Tabelle als `TEXT`-Spalte mit JSON darin,
würde die Suche nach dem Kennzeichen `LIKE '%А123ВС174%'` bedeuten — ein Full Scan ohne Index, mit
Fehltreffern. Hier ist es eine gewöhnliche Bedingung, auf die man einen Index aufbauen kann, und das
werden wir.

⚠️ Die Anführungszeichen um `"car.plate"` sind verpflichtend: ohne sie liest JavaScript den Punkt als
Zugriff auf eine Objekteigenschaft und versteht nicht, was von ihm verlangt wird.

</details>

**Ausweise, die an mehreren Eingängen gültig sind:**

```js
// entrances ist kein String, sondern eine Liste: ["Северная", "Южная"]. Die Bedingung wird trotzdem
// wie für ein gewöhnliches Feld geschrieben, MongoDB prüft sie selbst gegen jedes Element der Liste
db.passes.find({ entrances: "Южная" })
```

Beachten Sie: die Bedingung wird geschrieben, als wäre `entrances` ein gewöhnliches Feld mit dem Wert
`"Южная"`, obwohl es in Wirklichkeit eine Liste ist. **MongoDB versteht von selbst, dass die Bedingung,
wenn ein Feld eine Liste ist, gegen jedes Element geprüft werden muss.** Es ist keine gesonderte Syntax
für „enthält“ nötig.

**Gruppenausweise, die Minderjährige enthalten:**

```js
// Der Pfad members.age führt in eine Liste von Objekten — zum Feld age jedes Teilnehmers.
// $lt = less than (kleiner als). Eine Bedingung mit $ ist kein Wert, sondern eine Art des Vergleichs:
// "das Feld muss kleiner als 16 sein", nicht "das Feld muss gleich 16 sein"
db.passes.find({ "members.age": { $lt: 16 } })
```

Der Dotted Path funktioniert auch in eine Liste von Objekten hinein: die Bedingung wird gegen jeden
Teilnehmer geprüft. `$lt` — „kleiner als“. Es gibt etwa zwanzig Bedingungen dieser Art: `$gt`, `$gte`,
`$in`, `$ne`, `$exists`, `$regex` und so weiter.

**Alle Ausweise, bei denen überhaupt ein Fahrzeug angegeben ist:**

```js
// $exists fragt nicht nach dem Wert, sondern nach dem bloßen Vorhandensein des Feldes im Dokument:
// "hat dieses Dokument überhaupt ein Feld car?"
db.passes.find({ car: { $exists: true } })
```

`$exists` ist genau jene Unterscheidung zwischen „das Feld fehlt“ und „das Feld ist leer“. In einer
Tabelle stellt sich diese Frage nicht: die Spalte ist immer da, die einzige Frage ist `NULL`.

**Eine Übersicht für die Leitung — wie viele Ausweise es von jedem Typ gibt.** Hier wählt die Abfrage
keine Dokumente aus, sondern berechnet eine Summe über sie, deshalb ist der Befehl ein anderer —
`aggregate`. Gehen wir ihn durch, bevor wir tippen.

<details>
<summary><b>Die Aggregations-Pipeline durchgehen</b></summary>

Aggregation in MongoDB ist eine **Pipeline**: eine Liste von Stufen, deren jede das Ergebnis der
vorherigen als Eingabe nimmt. Es ist wie eine Pipeline von Befehlen in einer Shell, wo die Ausgabe der
einen an die Eingabe der nächsten geht.

`$group` — gruppieren. `_id: "$type"` bedeutet „der Gruppierungsschlüssel ist der Wert des Feldes
`type`“; das Dollarzeichen vor dem Namen sagt „das ist ein Verweis auf ein Feld, kein String“. `$sum: 1`
— eins für jedes Dokument addieren, das heißt, sie zählen.

`$sort: { count: -1 }` — in absteigender Reihenfolge ordnen; `-1` ist „absteigend“, `1` ist „aufsteigend“.

Dasselbe Ergebnis in SQL — `SELECT type, count(*) FROM passes GROUP BY type ORDER BY 2 DESC`. Kürzer,
vertrauter, und hier fällt ein ehrlicher Vergleich gegen MongoDB aus: seine Abfragesprache ist
wortreicher und braucht länger, um sie zu beherrschen.

</details>

```js
// aggregate = "die Dokumente durch eine Kette von Stufen laufen lassen". Die Stufen gehen der Reihe nach,
// jede erhält, was die vorherige erzeugt hat:
//   $group — die Dokumente nach dem Wert des Feldes type in Gruppen einsortieren und jede zählen
//   $sort  — die Gruppen nach count ordnen, -1 bedeutet "absteigend"
db.passes.aggregate([
  { $group: { _id: "$type", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
])
```

**Was Sie sehen sollten** — vier Zeilen der Form `{ _id: 'разовый', count: 1 }`.

## Schritt 5. Ein Index auf einem Feld, das die meisten nicht haben

📍 **Wo:** in der `mongosh`-Shell im Arbeits-Pod.

Der Sicherheitsdienst sucht jeden Tag nach dem Kennzeichen. Sehen wir uns an, was diese Suche gerade
kostet: die Abfrage ist dieselbe wie zuvor, aber statt der Dokumente fragen wir einen Bericht darüber ab,
wie die Datenbank nach ihnen gesucht hat.

```js
// explain = "gib mir nicht die Dokumente, sag mir, wie du nach ihnen gesucht hast"
//   "executionStats"     Berichtsmodus: nicht nur der Plan, sondern was tatsächlich passiert ist
//   .executionStats      wir nehmen genau diesen Abschnitt aus der Antwort, um nicht alles zu lesen
// Im Bericht schauen wir auf totalDocsExamined — wie viele Dokumente die Datenbank gelesen hat,
// um eines zurückzugeben
db.passes.find({ "car.plate": "А123ВС174" }).explain("executionStats").executionStats
```

**Was Sie sehen sollten** — `totalDocsExamined` ist gleich der Anzahl der Dokumente in der Collection.
Die Datenbank hat alle durchgesehen, um eines zu finden. Bei vier Dokumenten fällt das nicht auf, bei
vierhunderttausend fällt es sehr wohl auf.

Wir bauen einen Index — eine separate Struktur, die die Datenbank verwendet, um die benötigten Dokumente
zu finden, ohne alle der Reihe nach zu lesen:

```js
// createIndex = "einen Index auf diesem Feld aufbauen und ihn von nun an selbst weiterpflegen"
//   { "car.plate": 1 }   auf welchem Feld. 1 ist die Reihenfolge "aufsteigend"
//   name: "car_plate"    wie der Index heißen soll, damit man ihn später erkennen und löschen kann
//   sparse: true         nur Dokumente, die das Feld haben, kommen in den Index
db.passes.createIndex({ "car.plate": 1 }, { name: "car_plate", sparse: true })

// Wir wiederholen denselben Bericht und vergleichen ihn mit dem vorherigen
db.passes.find({ "car.plate": "А123ВС174" }).explain("executionStats").executionStats
```

**Was Sie sehen sollten** — `totalDocsExamined` ist gleich eins, und im Plan ist `IXSCAN` statt
`COLLSCAN` aufgetaucht. Das sind die Namen der Suchmethoden: `COLLSCAN` ist ein Scan der gesamten
Collection, `IXSCAN` ist eine Suche per Index.

<details>
<summary><b>Was ein Sparse Index ist und warum er hier steht</b></summary>

`{ "car.plate": 1 }` — auf welchem Feld aufzubauen ist; `1` bedeutet „aufsteigend“, `-1` — absteigend.
Für eine Suche nach exakter Übereinstimmung spielt die Richtung keine Rolle; für die Sortierung schon.

`sparse: true` — **nur jene Dokumente, die das Feld haben, kommen in den Index.**

Ohne dieses Flag hätte MongoDB auch für die drei Dokumente ohne Fahrzeug einen Indexeintrag erstellt, mit
dem Wert „Feld fehlt“. Der Index würde fast doppelt so groß, und jene Einträge wären zu überhaupt nichts
nütze: niemand sucht nach Ausweisen nach dem Kriterium „kein Fahrzeug angegeben“.

In einem echten Ausweisprotokoll sind etwa zehn Prozent Fahrzeugausweise. Ein Sparse Index wird zehnmal
kleiner sein als ein gewöhnlicher und zehnmal billiger in der Pflege.

⚠️ **Ein Sparse Index hat einen Preis, und Sie müssen ihn kennen.** Das Sortieren nach diesem Feld über
einen solchen Index verliert die Dokumente ohne das Feld — sie sind nicht darin. In solchen Fällen gibt
MongoDB den Index selbst auf und fällt auf einen Scan zurück; das Unangenehme ist, dass das stumm geschieht.

**Und jetzt der Sinn dieses Schritts.** In einer relationalen Datenbank mit einer einzigen Tabelle für
alle Ausweistypen müsste ein Index auf `car_plate` auf einer Spalte aufgebaut werden, in der neunzig
Prozent der Zeilen `NULL` sind. Manche DBMS legen solche Zeilen trotzdem in den Index, und er bläht auf.
Das umgeht man mit Partial Indexes — einem Mechanismus derselben Art wie `sparse`, nur nicht überall
verfügbar und nicht sofort naheliegend.

Das Problem ist also ein und dasselbe. Der Unterschied ist, dass es hier nicht als Nebeneffekt von „lass
uns alle Typen in eine Tabelle stecken“ entsteht: wir haben keine Spalte, die um einer Minderheit von
Datensätzen willen erstellt werden musste.

</details>

## Ein vorhersehbarer Fehlschlag · Der Ausweis, der nicht auf der Liste steht

Arbeiten wir weiter. Der Beamte am Tor hat noch einen Einmalausweis ausgestellt — über ein hastig
geschriebenes Skript:

```js
// insertOne = "ein Dokument hinzufügen". Welche Felder darin sind, fragt die Datenbank nicht
db.passes.insertOne({
  tipe: "разовый",
  guest: "Николаев Сергей Игоревич",
  host: "petrov@corp.ru",
  data: ISODate("2026-09-04T09:00:00Z")
})
```

Das Insert gelang: zurück kam `acknowledged: true` („angenommen“) und eine neue `_id` — der eindeutige
Schlüssel des Dokuments, den sich die Datenbank selbst ausgedacht hat. Prüfen wir, dass es jetzt fünf
Dokumente sind:

```js
// countDocuments = "die Dokumente zählen, die der Bedingung entsprechen".
// Leere geschweifte Klammern sind eine Bedingung ohne Einschränkungen, also "alle"
db.passes.countDocuments({})
```

Fünf. Nun das, was der Sicherheitsdienst jeden Morgen tut — er öffnet die Liste der Einmalausweise:

```js
// Dieselbe Auswahl nach type wie im Suchschritt: zeig die Ausweise, deren
// Feld type gleich "разовый" ist
db.passes.find({ type: "разовый" })
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Wie viele Ausweise kamen zurück? Wo ist der fünfte? Was würde bei demselben Fehler in einer relationalen
> Datenbank passieren — und warum ist das besser?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Ein Ausweis kam zurück, nicht zwei. Der Gast Nikolajew wird ankommen, der Sicherheitsdienst wird ihn
nicht finden, und das aufzuklären wird eine Weile dauern — denn das Dokument **existiert**, es **wurde
erfolgreich eingefügt**, und nirgends wurde ein Fehler festgehalten.

Die Ursache sind zwei Tippfehler: `tipe` statt `type` und `data` statt `valid_on`. MongoDB hat sie nicht
bemerkt, denn **die Collection hat kein Schema und deshalb keine Meinung dazu, welche Felder richtig
sind.** Für sie ist `tipe` ein ebenso legitimes Feld wie jedes andere.

Finden wir die Opfer — Dokumente, die überhaupt kein Feld `type` haben:

```js
// $exists: false — das Gegenteil des vorherigen Schritts: "das Feld ist nicht im Dokument".
// Es lohnt sich, eine solche Abfrage griffbereit zu halten: sie zeigt, was sich am Schema vorbei angesammelt hat
db.passes.find({ type: { $exists: false } })
```

In einer relationalen Datenbank würde ein `INSERT` mit einer Spalte `tipe` sofort fehlschlagen:
`column "tipe" does not exist`. Der Fehler käme in den Tests ans Licht, nicht eine Woche später am Tor.
**Das ist der Hauptpreis der Schemaflexibilität: die Prüfung, die früher die Datenbank machte, muss jetzt
jemand anderes machen.**

**Die Lehre reicht über diesen Fehler hinaus.** Und hier ist es wichtig, nicht den falschen Schluss zu
ziehen. Der richtige Schluss ist nicht „Dokumentendatenbanken sind schlecht“, sondern „kein Schema
standardmäßig heißt nicht gar kein Schema“. Ihre Daten haben immer ein Schema: es ist entweder explizit
beschrieben, oder es lebt in den Köpfen der Menschen und im Code, wo niemand es prüft.

Entfernen wir das beschädigte Dokument und schalten die Validierung ein.

</details>

Wir löschen die Dokumente ohne type:

```js
// deleteMany = "alle Dokumente löschen, die der Bedingung entsprechen". Die Bedingung ist dieselbe
// wie in der Suche oben — was bedeutet, dass genau das gelöscht wird, was Sie gerade gesehen haben
db.passes.deleteMany({ type: { $exists: false } })
```

**Was Sie sehen sollten** — `deletedCount: 1`.

Jetzt schalten wir die Validierung ein — eine Regel, die jedes Dokument erfüllen muss. Sie steht in der
Datei `validator.js`; gehen wir sie durch, bevor wir sie anwenden.

<details>
<summary><b>Die Regel durchgehen</b></summary>

```js
db.runCommand({
  collMod: "passes",
  validator: { $jsonSchema: { … } },
  validationLevel: "strict",
  validationAction: "error"
});
```

`collMod` — die Einstellungen einer bestehenden Collection ändern. Der Validator wird nachträglich an eine
lebende Collection gehängt, es muss nichts gestoppt werden.

```js
      required: ["type", "host"],
```

Die Pflichtfelder. **Beachten Sie, was nicht auf der Liste steht: `guest`.** Der Gruppenausweis hat keinen
Gast, an seiner Stelle eine Organisation. Die Regel muss breit genug sein, damit eine legitime
Dokumentenform durch sie hindurchkommt — und diese Einschränkung spürt man sofort: je vielfältiger Ihre
Dokumente sind, desto weniger können Sie von allen gemeinsam verlangen.

```js
        type: {
          enum: ["разовый", "недельный", "автомобильный", "групповой"],
        },
```

Nur ein Wert aus der Liste. Ein fünfter Ausweistyp wird eine Änderung der Regel verlangen — und das ist
gut: die Änderung wird bewusst.

```js
        car: {
          bsonType: "object",
          required: ["plate"],
          …
        },
```

Die Regeln wirken auch auf verschachtelte Objekte. Ist das Feld `car` vorhanden, muss es ein `plate`
haben. Fehlt das Feld — keine Anforderungen, das Dokument ist legitim.

```js
  validationLevel: "strict",
  validationAction: "error"
```

`strict` — alle Inserts und alle Updates validieren. Es gibt ein sanfteres `moderate`: es validiert neue
Dokumente und Updates an solchen, die die Regel bereits erfüllen, während es die alten ungültigen in Ruhe
lässt. Mit `moderate` schaltet man die Validierung für eine Collection ein, in der sich bereits
Inkonsistenz angehäuft hat: erst hören wir auf, es schlimmer zu machen, dann bessern wir das Alte aus,
dann schalten wir auf `strict` um.

`error` — abweisen. Es gibt `warn`: es ins Log schreiben und trotzdem annehmen. Gut, um eine Woche lang zu
beobachten, wie viel hereinkommt, bevor man das Abweisen einschaltet.

</details>

Wir wenden die Regel an:

```bash
# Derselbe Kniff wie bei passes.js: der Inhalt der Datei wird in die Eingabe von mongosh gespeist.
# Die Regel wird an eine lebende Collection gehängt — die Datenbank muss nicht gestoppt werden
mo < validator.js
```

**Was Sie sehen sollten** — `правило установлено`.

Wir versuchen, denselben Tippfehler zu wiederholen — jetzt unter der Aufsicht der Regel:

```js
// Das Feld tipe ist der Regel unbekannt, und im Dokument gibt es kein Pflichtfeld type.
// Früher hätte sich ein solches Dokument stumm in die Collection gesetzt
db.passes.insertOne({ tipe: "разовый", guest: "Проверка", host: "x@corp.ru" })
```

**Was Sie sehen sollten** — `MongoServerError: Document failed validation`. Jetzt kommt der Tippfehler
nicht durch.

⚠️ **Die Validierung fängt nicht alles ab, und das muss man deutlich sagen.** Die Regel verlangt, dass
das Feld `type` vorhanden und aus der Liste ist. Einen Tippfehler in einem **optionalen** Feld — `guestt`
statt `guest` — lässt sie durch: das Dokument ist immer noch legitim, nur mit einem zusätzlichen Feld. Sie
können jedes unbekannte Feld verbieten (`additionalProperties: false`), aber dann verlangt jedes neue Feld
eine Bearbeitung der Regel, und Sie kommen genau zu dem zurück, dem Sie entkommen wollten — eine
Schema-Migration für jede Kleinigkeit. Wo die Grenze zu ziehen ist, ist eine Entscheidung, die Sie
treffen, und sie ist immer ein Kompromiss.

## Schritt 6. Ehrlich: wo das Dokumentenmodell verliert

📍 **Wo:** in der `mongosh`-Shell im Arbeits-Pod.

Die Schemaflexibilität ist nicht der einzige Unterschied, und die übrigen sprechen nicht zu MongoDBs
Gunsten.

<details>
<summary><b>Es gibt keine Joins in der üblichen Form</b></summary>

Die Aufgabe: für jeden Ausweis die Telefonnummer und die Position des Mitarbeiters heranziehen, der ihn
bestellt hat. Die Mitarbeiter liegen in einer separaten Collection `staff`, geschlüsselt nach E-Mail.

In SQL ist das eine Zeile: `JOIN staff ON staff.email = passes.host`.

Hier — eine Pipeline-Stufe:

```js
db.passes.aggregate([
  // $lookup = "für jeden Ausweis in eine andere Collection gehen und von dort einen Datensatz zurückholen"
  { $lookup: {
      from: "staff",          // wohin gehen — die Mitarbeiter-Collection
      localField: "host",     // welches Ausweisfeld zu vergleichen ist
      foreignField: "email",  // mit welchem Mitarbeiterfeld
      as: "host_info"         // unter welchem Namen das Gefundene ins Dokument gelegt wird
  } },
  // Das Gefundene wird immer als Liste abgelegt, auch wenn es eine einzige Übereinstimmung gibt.
  // $unwind rollt die Liste zurück in einen einzelnen Wert
  { $unwind: "$host_info" }
])
```

Wir haben keine `staff`-Collection — die Abfrage gibt nichts zurück. Sie steht hier als Beispiel für die
Syntax, nicht als Lab-Schritt.

Es funktioniert. Aber:

- `$lookup` ist **einseitig**: für jedes Dokument links wird rechts eine Suche gefahren. Das ist kein
  Optimizer, der eine Join-Methode wählt, sondern genau eine Brute-Force-Suche
- das Ergebnis kommt **als Liste** zurück, auch wenn es eine einzige Übereinstimmung gibt. Daher `$unwind`,
  um sie aufzurollen
- das Verknüpfen von mehr als zwei Collections wird umständlich und langsam
- in einem gesharderten Deployment funktionierte `$lookup` bis vor Kurzem mit Einschränkungen

Deshalb wird die Aufgabe in der MongoDB-Welt anders gelöst: **Daten, die zusammen gebraucht werden, werden
zusammen gespeichert.** Die Telefonnummer und die Position des Anfordernden werden direkt ins
Ausweisdokument geschrieben.

Und das ist ein echter Kompromiss, keine geringfügige Unannehmlichkeit:

| | Ein Verweis auf `staff` | Eine Kopie der Daten im Dokument |
|---|---|---|
| Lesen | braucht `$lookup` | eine einzige Suche |
| Ein Mitarbeiter hat seine Telefonnummer geändert | an einer Stelle korrigiert | Sie müssen alle Ausweise durchgehen |
| Integrität | die Datenbank wacht darüber | die Anwendung wacht darüber, das heißt Sie |

In einer relationalen Datenbank gibt es keine Wahl — dort sind es Normalisierung und Fremdschlüssel. Hier
gibt es eine Wahl, und mit ihr Verantwortung.

</details>

<details>
<summary><b>Es gibt überhaupt keine Fremdschlüssel</b></summary>

Probieren Sie es:

```js
// Das Feld host verweist seinem Sinn nach auf einen Mitarbeiter. Es gibt keinen solchen Mitarbeiter —
// wird die Datenbank das prüfen? Das Dokument erfüllt die Regel aus dem letzten Schritt: type ist
// vorhanden und aus der Liste, host ist ein String
db.passes.insertOne({ type: "разовый", host: "не-существует@corp.ru", guest: "Тест" })
```

Das Dokument wird eingefügt. Es gibt keinen Mitarbeiter mit einer solchen E-Mail, und die Datenbank wird
nicht darauf schauen.

In einer relationalen Datenbank würde ein Fremdschlüssel eine solche Zeile abweisen. Hier existiert das
Konzept eines Fremdschlüssels überhaupt nicht: **die Stimmigkeit der Daten liegt vollständig bei der
Anwendung.** Der Validator aus dem vorherigen Schritt prüft die Form des Dokuments, kann aber nicht
prüfen, dass der Wert eines Feldes in einer anderen Collection existiert.

In der Praxis heißt das: jede „gibt es einen solchen Mitarbeiter“-Prüfung wird vom Entwickler geschrieben,
und wenn er sie vergessen hat — erfahren Sie das, wenn der Sicherheitsdienst versucht, den Anfordernden
anzurufen.

Vergessen Sie nicht, das Testdokument zu entfernen:

```js
// deleteOne = "ein Dokument löschen, das der Bedingung entspricht", nicht alle auf einmal
db.passes.deleteOne({ host: "не-существует@corp.ru" })
```

</details>

<details>
<summary><b>Es gibt Transaktionen, aber nicht standardmäßig</b></summary>

Hier ist es wichtig, präzise zu sein, denn über MongoDB werden oft in beide Richtungen unwahre Dinge
gesagt.

**Wahr:** Multi-Dokument-Transaktionen gibt es in MongoDB durchaus, ab Version 4.0 für Replica Sets. Sie
können zwei Dokumente so ändern, dass entweder beide angewendet werden oder keines.

**Ebenfalls wahr:** standardmäßig gibt es sie nicht. Eine Operation auf **einem einzelnen Dokument** ist
atomar. Wenn Sie mehr wollen — eröffnen Sie eine Sitzung und beginnen Sie explizit eine Transaktion:

```js
// Eine Sitzung ist ein separates "Gespräch" mit der Datenbank, innerhalb dessen man eine Transaktion deklarieren kann
const s = db.getMongo().startSession();
s.startTransaction();          // ab diesem Punkt sammeln sich Änderungen an, sind aber für niemanden sichtbar
// … Operationen über s.getDatabase("passes") …
s.commitTransaction();         // alles auf einmal anwenden. Um alles auf einmal abzubrechen — abortTransaction()
```

**Und eine dritte Wahrheit, die praktischste:** Transaktionen in MongoDB sind teurer als in einer
relationalen Datenbank, sie haben ein Zeitlimit, und das ganze Datenmodell baut auf der Annahme, dass Sie
sie kaum brauchen. Wenn Ihr Szenario sie oft verlangt, ist das ein Zeichen, dass die Daten anders hätten
angelegt werden sollen — oder dass hier keine Dokumentendatenbank gebraucht wird.

Für einen Ausweisdienst ist das kein Problem: ein Ausweis ist ein einzelnes Dokument, und alle Operationen
darauf sind von selbst atomar. Für die Lohnabrechnung ist es ein Problem, und ein großes.

</details>

<details>
<summary><b>Schema-Inkonsistenz schleicht sich von selbst ein</b></summary>

Das haben wir bereits mit dem Tippfehler gesehen. Aber es gibt eine heimtückischere Spielart: Inkonsistenz,
die sich nicht durch einen Fehler eingeschlichen hat, sondern durch Unachtsamkeit.

Ein Jahr später entdecken Sie in der Collection, dass Daten auf drei Arten gespeichert sind: als
`ISODate`, als String `"2026-09-01"` und als Zahl mit einem Zeitstempel — weil drei verschiedene Teams sie
zu verschiedenen Zeiten geschrieben haben. Eine Bereichssuche über Daten findet ein Drittel der Datensätze,
und niemand versteht, warum.

Sie können so sehen, was tatsächlich in der Collection ist:

```js
db.passes.aggregate([
  // $$ROOT — das ganze Dokument vollständig. $objectToArray zerlegt es in
  // "Feldname — Wert"-Paare, damit man dann mit den Feldern als Daten arbeiten kann
  { $project: { fields: { $objectToArray: "$$ROOT" } } },
  // Wir rollen die Liste der Paare auf: ein Paar — eine Zeile am Eingang der nächsten Stufe
  { $unwind: "$fields" },
  // Wir gruppieren nach zwei Merkmalen zugleich: dem Feldnamen (k) und dem Typ seines Wertes (t),
  // und zählen, wie oft eine solche Kombination vorkam
  { $group: { _id: { k: "$fields.k", t: { $type: "$fields.v" } }, n: { $sum: 1 } } },
  { $sort: { "_id.k": 1 } }   // alphabetisch, damit ein Feld neben seinen eigenen Typen steht
])
```

Die Abfrage zerlegt jedes Dokument in „Feld — Wert“-Paare, ermittelt den Typ des Wertes und zählt, wie oft
jedes Feld mit jedem Typ vorkam. Auf unseren vier Dokumenten zeigt sie ein gleichmäßiges Bild. Auf einer
echten Collection ein Jahr später zeigt sie, was niemand vermutet hätte, und sie ist eine der nützlichsten
Abfragen beim Entwirren einer geerbten Datenbank.

**Die Erkenntnis, die es sich mitzunehmen lohnt:** ein Schema-Validator ist keine Zierde und keine
„Häkchen-Formalität“. In einer Dokumentendatenbank ist er das Einzige, das zwischen Ihnen und der
Inkonsistenz steht. Man sollte ihn sofort einschalten, nicht dann, wenn die Lage verzweifelt wird.

</details>

**Das Fazit eines ehrlichen Vergleichs:**

| Aufgabe | Relational | Dokument |
|---|---|---|
| Datensätze derselben Form | natürlich | auch möglich, aber wozu |
| Datensätze verschiedener Form | leere Spalten oder eine Tabelle pro Typ | natürlich |
| Listen und Verschachtelung | separate Tabellen | ein Feld im Dokument |
| Verknüpfung mit anderen Daten | JOIN, ein Optimizer | `$lookup` oder eine Kopie der Daten |
| Referentielle Integrität | die Datenbank wacht darüber | die Anwendung wacht darüber |
| Transaktionen | standardmäßig | explizit, teurer, seltener |
| Schutz vor Tippfehlern | es gibt immer ein Schema | ein Validator, wenn Sie ihn eingeschaltet haben |
| Änderung des Schemas | eine Migration und ein Release | ein neues Feld entsteht von selbst |

## Überprüfung

📍 **Wo:** auf dem Laptop, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

Das Prüfskript verbindet sich selbst zur Datenbank, deshalb braucht es dieselben Dinge wie Sie: Zugriff
auf den Lab-Cluster, die Tenant-Nummer und das Passwort des Benutzers `passapp`. Sie werden als
Umgebungsvariablen übergeben.

```bash
cd labs/10-mongodb
# Dieselbe Zugangsdatei wie in den Schritten oben: das Skript arbeitet von innerhalb des Lab-Clusters
export KUBECONFIG=~/lab.kubeconfig
# Die Tenant-Nummer: daraus setzt das Skript die Datenbankadresse zusammen. Setzen Sie Ihre eigene ein
export COZY_TENANT=workshop03
# Das Passwort in einfachen Anführungszeichen: darin rührt die Shell $, ! und & innerhalb des Strings nicht an.
# Das Passwort gelangt nicht in den Bericht
export MONGO_PASSWORD='your-passapp-password'
./check.sh
```

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man das einrichtet,
steht am Anfang von Lab 0. Ohne WSL können Sie das Lab trotzdem abschließen, aber es wird kein
Berichts-Artefakt geben.

Das Skript prüft nicht die Tatsache der Erstellung des Dienstes, sondern die Arbeit im Wesentlichen: die
Collection hat Dokumente aller vier Formen, die Suche nach einem verschachtelten Feld und in eine Liste
hinein funktioniert, ein Sparse Index ist auf dem seltenen Feld aufgebaut, der Schema-Validator ist
eingeschaltet, und es bleiben keine Dokumente ohne type übrig.

Das Passwort gelangt nicht in den Bericht.

## Aufräumen

Der Arbeits-Pod wird nicht mehr gebraucht — die ganze Zeit hielt er den Container mit dem Befehl `sleep`
beschäftigt:

```bash
# delete = "aus dem Cluster entfernen". Der Pod verschwindet zusammen mit seiner Variablen MONGO_URI,
# sodass das Passwort nicht im Cluster verbleibt
kubectl delete pod mongo-workbench
```

MongoDB selbst wird im Dashboard gelöscht: die Anwendung `passes` → löschen.

Warum das billig ist. Ein MongoDB-Replica-Set in klassischer Infrastruktur sind drei virtuelle Maschinen,
die Installation, die Konfiguration der Abstimmung, das Überwachen des Replikations-Lags und ein Mensch,
der weiß, wie man all das repariert. Hier haben Sie einen Dienst für eine Stunde genommen und in zehn
Sekunden zurückgegeben, und der Platz, den er belegt hat, ging in die freie Kapazität des Clusters zurück
— jemand anderes kann ihn sofort beanspruchen.

⚠️ **Die Daten verschwinden mit dem Löschen.** Die vier Ausweise werden mit einem einzigen Befehl
wiederhergestellt, im Lab ist das also kein Verlust. Wenn Sie etwas Echtes dort hineingelegt haben —
schalten Sie zuerst Backups ein; sie sind ein eigener Abschnitt auf dem Bestellformular.

## Was wir jetzt können

- Erklären, wann das Dokumentenmodell angebracht ist und wann es ein Weg ist, sich selbst Ärger zu machen
- MongoDB aus dem Katalog bestellen und nicht über `authSource`, Rollen und eine einzige Kopie stolpern
- Dokumente verschiedener Form speichern und nach verschachtelten Feldern und in Listen hinein suchen
- Einen Sparse Index aufbauen und verstehen, womit er seine Ersparnis bezahlt
- Einen Schema-Validator einschalten und sehen, wovor er schützt und wovor nicht
- Laut benennen, was einer Dokumentendatenbank fehlt: Fremdschlüssel, die üblichen Joins, Transaktionen
  standardmäßig

## Und in vSphere wäre das

Drei Maschinen für das Replica Set, und der arbeitsintensivste Teil davon ist nicht die Installation,
sondern das Konfigurieren der Abstimmung unter den Kopien: wer ist primär, was bei Verbindungsverlust zu
tun ist, wie man eine hinterherhinkende zurückholt. Dazu ein separates Gespräch mit dem
Informationssicherheits-Team darüber, wer diese Datenbank in einem Jahr aktualisieren wird.

Hier — ein Eintrag im Katalog und fünf Minuten.

**Wo vSphere bequemer ist, ehrlich gesagt.** Eine virtuelle Maschine mit MongoDB ist eine Maschine, an
die Sie herantreten können: sich über SSH anmelden, `mongotop` ansehen, die Konfiguration anpassen, vor
einer riskanten Operation einen Snapshot nehmen. Ein Managed Service gibt Ihnen das **absichtlich** nicht:
der Tenant lässt Sie nicht in einen Pod oder in die Logs der Datenbank `exec`en. Solange alles
funktioniert, ist das ein Vorteil — weniger Möglichkeiten, es kaputt zu machen. Wenn die Datenbank sich
seltsam verhält, ist der übliche Satz von Handlungen des Administrators nicht verfügbar, und es bleibt nur,
zu demjenigen zu gehen, der die Plattform betreibt.

Und noch ein Zweites, spezifisch für MongoDB im Besonderen. Ein Managed Service fixiert die Version und den
Satz der Parameter. Ein Major-Upgrade von MongoDB ist eine Operation, die Sie in Ihrer eigenen
Installation selbst planen, mit einer Prüfung der Anwendungskompatibilität und der Option, auf einen
Snapshot zurückzurollen. Hier ist ein Versionswechsel ein Feld auf dem Formular und die Upgrade-Prozedur
eines anderen unter der Haube. Meist ist das genau das, was Sie wollen. Aber an dem Tag, an dem das Upgrade
schiefgeht, werden Sie es nicht mit eigenen Händen klären, und das müssen Sie im Voraus verstehen, nicht
unterwegs entdecken.
