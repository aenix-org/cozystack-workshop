# Lab 13 · Ihre eigene Anwendung im Cozystack-Katalog

| | |
|---|---|
| **Zeit** | 40 Minuten |
| **Was es zeigt** | Der Plattform-Katalog ist offen: Ihre eigene Anwendung nimmt darin ihren Platz ein, direkt neben Redis und den VMs |
| **Was Sie brauchen** | `helm` auf dem Bastion, `kubectl`, Tenant-Zugang. Der `lab`-Cluster wird hier nicht benötigt |

## Warum das wichtig ist

„Guest Pass“ ist eingerichtet und läuft. Eine Woche später erfährt die Tochtergesellschaft davon – sie hat
denselben Empfang und dasselbe Problem. Eine Woche danach meldet sich die zweite
Tochtergesellschaft.

Den ersten beiden haben Sie es mündlich erklärt: welche Images, welche Konfiguration, welche
Parameter, was zuerst hochzufahren ist. Beim dritten Mal war klar, dass das so nicht weitergehen kann.
Die Erklärung steckt in einem einzigen Kopf, es gibt nur diesen einen Kopf, und es werden
fünf Unternehmen sein.

Was Sie brauchen, ist, dass „Guest Pass“ bei ihnen genauso auftaucht wie Redis: ein Eintrag im
Katalog, ein Formular mit Parametern, ein Button. Ohne Sie.

Das ist das Finale des Workshops. Wir sind den Weg gegangen von „stell mir einen Pod bereit“ bis zu
„hier ist eine Plattform mit unserem Dienst darin“.

## Das Wichtigste zuerst: wo Ihre Berechtigungen enden

Dieses Lab wird die Anwendung **nicht** in den Katalog ausrollen. Und das nicht, weil uns
die Zeit gefehlt hätte, den entsprechenden Teil zu schreiben.

Das Objekt `ApplicationDefinition`, das eine Anwendung im Katalog registriert,
ist **cluster-scoped**: Es gibt eines pro Cluster, es hat keinen namespace, und es ändert den
Katalog für alle Tenants auf einmal. Ein Tenant kann ein solches Objekt nicht erstellen. Überzeugen Sie sich
selbst, gleich jetzt: Sie können den Cluster nach Ihren Berechtigungen fragen, ohne etwas
zu erstellen.

```bash
# KUBECONFIG — die Variable, die kubectl liest, um Adresse des Clusters und Ihre Zugangsdaten zu finden.
# Hier ist es der Tenant-Zugang, dieselbe Datei wie in jedem anderen Lab.
export KUBECONFIG=~/.kube/config
# auth can-i = „darf ich das?“. Der Cluster antwortet mit ja oder nein und ändert nichts:
#   create                   welche Aktion wir prüfen
#   applicationdefinitions   auf welchem Objekttyp
kubectl auth can-i create applicationdefinitions
```

**Was Sie sehen werden:**

```
no
```

Es gibt hier keinen Workaround, und es ist auch keiner vorgesehen. Deshalb ist das Lab ehrlich aufgebaut: **Sie
schreiben den Chart und die Application-Definition, prüfen sie lokal und übergeben sie der
Plattform-Administration.** Genau so funktioniert es im echten Leben: den Katalog aufzubauen und
ihn zu betreiben sind verschiedene Rollen.

Eine Analogie aus der vertrauten Welt: Sie bereiten den Inhalt der OVF-Vorlage vor, aber in die
gemeinsame Content Library legt sie derjenige ab, der die Rechte an dieser Library besitzt.

## Kleines Glossar

| Begriff | Was es ist | Wie … aber |
|---|---|---|
| **Helm** | Ein Werkzeug zum Templating von Manifesten mit Parametern und Versionen | am ehesten eine OVF-Vorlage mit Eingabefeldern, aber als Text und in Git |
| **Chart (chart)** | Ein Helm-Paket: Templates, Standardwerte, Schema | eine **OVF-Vorlage**, aber vielfach mit unterschiedlichen Parametern an einem Ort ausgerollt |
| **Release (release)** | Ein konkretes Deployment eines Charts unter eigenem Namen | eine **aus einer Vorlage ausgerollte VM**, aber sie merkt sich ihre Versionshistorie und kann zurückrollen |
| **values** | Die Parameter, mit denen ein Chart ausgerollt wird | die **Felder des OVF-Deployment-Assistenten**, aber schlichtes YAML, zusammen mit allem anderen in Git abgelegt |
| **values.schema.json** | Eine Beschreibung der zulässigen Werte | die **Feldvalidierung im Assistenten**, aber sie prüft vor dem Anwenden, nicht währenddessen |
| **ApplicationDefinition** | Ein Eintrag im Plattform-Katalog: was anzuzeigen und was auszurollen ist | ein **Eintrag in der Content Library**, aber einer pro Cluster und für alle Tenants sichtbar |
| **Namespace** | Ein Bereich des Clusters, in dem die Objekte eines Eigentümers liegen | ein **Ordner oder Resource Pool**, aber entlang seiner verläuft die Berechtigungsgrenze: Ihr Tenant ist ein namespace |
| **Cluster-scoped** | Ein Objekt ohne namespace, das über den gesamten Cluster hinweg geteilt wird | eine **Einstellung auf vCenter-Ebene**, aber die Rechte daran gehören dem Plattform-Team, nicht dem Tenant |
| **CRD** | Die Art und Weise, Kubernetes einen neuen Objekttyp hinzuzufügen | einmal registriert, ist Ihr Typ von den eingebauten nicht mehr zu unterscheiden |

## Was im Lab-Ordner liegt

Jede Datei ist bereits vorhanden – Sie haben sie zusammen mit dem Repository erhalten. Es gibt nichts zu
erstellen oder neu abzutippen: Wo unten `kubectl apply -f name.yaml` steht, wird die Datei
von hier genommen.

```bash
cd labs/13-catalog
```

| Datei | Was es ist | Wann es nützlich ist |
|---|---|---|
| `chart/` | Ihre Anwendung, verpackt für den Katalog: Templates, values, Schema der Formularfelder | Sie lesen und prüfen es lokal |
| `applicationdefinition.yaml` | Die Beschreibung des Katalog-Eintrags: wie er heißt und was im Dashboard anzuzeigen ist | Sie versuchen, es anzuwenden, um die Verweigerung der Berechtigung zu sehen |
| `guestpass-example.yaml` | Wie das Bestellen Ihrer Anwendung aussehen wird, sobald sie veröffentlicht ist | Sie lesen es; anwenden können Sie es erst nach der Veröffentlichung |
| `icon.svg`, `icon.b64` | Das Icon des Eintrags – die Quelle und dasselbe als Zeichenkette; bereits in die Definition eingebettet | nützlich, falls Sie das Icon je ändern |
| `check.sh` | Eine Prüfung, dass der Chart rendert und der Cluster ihn akzeptiert | Sie führen es am Ende des Labs aus |

## Schritt 1. Schauen Sie sich an, was wir verpacken

Der Ordner `chart/` enthält einen fertigen „Guest Pass“-Chart. Die Anwendung darin ist
bewusst einfach gehalten – nginx mit einer Seite –, denn im Lab geht es nicht um die Anwendung, es
geht um die Verpackung.

```
chart/
├── Chart.yaml            Name, Version, Beschreibung
├── values.yaml           Parameter und Standardwerte
├── values.schema.json    welche Werte als gültig gelten
└── templates/
    ├── configmap.yaml    die Seite und die nginx-Konfiguration
    ├── deployment.yaml   die Anwendung selbst
    └── service.yaml      die Adresse
```

<details>
<summary><b>Genauer betrachtet: was im Chart steckt</b></summary>

### `Chart.yaml` — der Ausweis

```yaml
name: guest-pass
version: 0.1.0
appVersion: "1.0"
```

Zwei verschiedene Versionsnummern, und sie werden ständig verwechselt.

`version` ist die Version des **Charts**, also der Verpackung. Ein Template angepasst,
einen Parameter ergänzt, einen Tippfehler in der Beschreibung korrigiert – erhöhen Sie sie.

`appVersion` ist die Version der **Anwendung** darin. Sie ändert sich, wenn eine neue Version von
„Guest Pass“ selbst erscheint, und hat keinen Zusammenhang mit der Version der Verpackung.

Der praktische Nutzen: An `version` erkennt der Admin, ob der Deployment-Mechanismus
selbst aktualisiert wird, und an `appVersion`, ob das aktualisiert wird, was die Leute tatsächlich benutzen.

### `values.yaml` — die Parameter

```yaml
## @param {int} replicas=2 - Number of application replicas.
replicas: 2

## @param {string} greeting=Order a pass for your guest - Text shown on the main page.
greeting: "Order a pass for your guest"

## @param {bool} external=false - Enable external access from outside the cluster.
external: false
```

Die `## @param`-Kommentare sind keine Verzierung und keine Dokumentation für Menschen. Aus ihnen baut der
Generator von Cozystack (`cozyvalues-gen`) die `values.schema.json` und die Parametertabelle
im README des Charts. Eine einzige Quelle der Wahrheit: ändern Sie den Kommentar, generieren Sie das Schema neu, und
das Formular im Dashboard ändert sich mit.

Das Format ist streng: `## @param {Typ} name=Standardwert - Beschreibung.`

Es gibt bewusst wenige Parameter. Jeder neue Parameter ist ein weiteres Feld im Formular, eine
weitere Möglichkeit, die Anwendung falsch auszurollen, und ein weiterer Zweig, den Sie pflegen müssen. Ein
guter Chart lässt Sie das konfigurieren, was sich zwischen Installationen wirklich unterscheidet, und
nichts darüber hinaus.

### `values.schema.json` — was als gültig gilt

Das Schema wird von Helm geprüft, **bevor** irgendetwas in den Cluster wandert. Prüfen Sie es direkt vor Ort:
schmuggeln Sie eine Zeichenkette in einen numerischen Parameter.

```bash
# template = „baue die Manifeste aus dem Chart zusammen und gib sie aus“, der Cluster wird dabei nicht angefasst:
#   gp                    der Release-Name, unter dem der Chart sozusagen ausgerollt wird
#   chart                 der Ordner mit dem Chart
#   --set replicas=abc    einen einzelnen Parameter direkt auf der Kommandozeile überschreiben
helm template gp chart --set replicas=abc
```

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
guest-pass:
- at '/replicas': got string, want integer
```

Der Fehler wird auf dem Bastion in einer halben Sekunde abgefangen. Ohne das Schema wäre er in den Cluster gewandert
und hätte sich in ein Deployment verwandelt, das nie erstellt wird, mit einer Meldung über drei
Bildschirme.

Genau dieses Schema wandert, Wort für Wort, in die `ApplicationDefinition` – und dort wächst daraus die
Erstellungsform im Dashboard.

### `templates/configmap.yaml` — die Seite

```yaml
    <h1>{{ .Values.greeting }}</h1>
```

Das ist überhaupt der ganze Grund, warum es ein Templating-Werkzeug gibt: ein Wert aus `values`
landet beim Rendern im Manifest. Ohne Helm müssten Sie pro Tochtergesellschaft eine Kopie
des Manifests vorhalten und sie von Hand bearbeiten.

### `templates/deployment.yaml` — die Anwendung

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Die Zeile, die alle vergessen und die später eine Stunde Fehlersuche kostet.

Kubernetes **startet Pods nicht neu, wenn sich eine ConfigMap ändert**. Sie bearbeiten den Text, führen ein
Update aus, das Dashboard zeigt „aktualisiert“, und die Seite zeigt weiterhin die alte Begrüßung. Die
Annotation mit dem Hash der Konfiguration ändert sich zusammen mit der Konfiguration, und eine Änderung an einer
Annotation im Template eines Pods ist bereits eine Änderung am Pod selbst, also erstellt der Cluster
ihn neu.

```yaml
            requests:
              cpu: {{ .Values.resources.cpu | quote }}
```

`quote` ist hier zwingend. Ohne Anführungszeichen liest YAML den Wert `100m` als Zeichenkette, aber `1`
als Zahl, und in einem von zwei Fällen erhalten Sie einen Typfehler. Anführungszeichen beseitigen diese ganze
Klasse von Problemen auf einen Schlag.

### `templates/service.yaml` — die Adresse

```yaml
  type: {{ if .Values.external }}LoadBalancer{{ else }}ClusterIP{{ end }}
```

Ein einzelner boolescher Parameter entscheidet, ob die Anwendung eine Adresse außerhalb des
Clusters erhält oder nicht. Genau so sind die eingebauten Cozystack-Anwendungen gebaut – die meisten von
ihnen haben ein Feld `external` mit genau dieser Bedeutung. Es lohnt sich, im Katalog den
Konventionen der anderen zu folgen: Wer vor Ihnen drei Managed Services ausgerollt hat, wird
dieses Feld an derselben Stelle und unter demselben Namen suchen.

</details>

## Schritt 2. Prüfen Sie den Chart lokal

📍 **Wo:** auf dem Bastion (in seinem Terminal). Dafür wird kein Cluster benötigt.

Zuerst der Linter. Er liest den Chart als Menge von Dateien und fängt strukturelle Fehler ab: die
falsche Einrückung, ein verloren gegangenes Pflichtfeld, ein Template, das sich nicht parsen lässt.

```bash
cd labs/13-catalog
# lint = „prüfe das Paket auf Formatfehler und Pflichtfelder“
#   chart   Pfad zum Chart-Ordner; darin erwartet Helm Chart.yaml, values.yaml
#           und den Ordner templates/
helm lint chart
```

**Was Sie sehen sollten:**

```
==> Linting chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

`[INFO]` ist ein Hinweis, kein Fehler: Der Chart hat kein Feld `icon`. Für den Cozystack-Katalog
wird es ohnehin nicht benötigt, das Icon wird aus der `ApplicationDefinition` genommen, zu der
wir noch kommen.

Nun das Rendern. Ein Template ist ein Manifest, in dem ein Teil der Werte durch Platzhalter der
Form `{{ .Values.replicas }}` ersetzt ist. Rendern heißt, die Templates in fertige Manifeste zu
verwandeln: Helm nimmt die Werte aus `values.yaml`, setzt sie in den Text ein und gibt das
Ergebnis aus.

```bash
# main — der Release-Name, also dieses konkreten Deployments des Charts. Er geht
# in die Namen der erzeugten Objekte ein, damit zwei Installationen nebeneinander nicht kollidieren.
helm template main chart
```

Die Ausgabe sind gewöhnliche Manifeste, dieselben, die Sie in den ersten Labs von Hand geschrieben haben. An
Helm ist nichts Magisches: es setzt Werte in Text ein.

Prüfen Sie, dass die Parameter wirklich in den Manifesten ankommen. Wir rendern zweimal mit unterschiedlichen Werten
und behalten nur die Zeile der Ausgabe, die sich ändern sollte.

```bash
# --set replicas=5 überschreibt den Wert aus values.yaml für die Dauer eines Laufs.
# | grep 'replicas:' — behalte aus der gesamten Ausgabe nur die Zeilen mit diesem Wort.
helm template main chart --set replicas=5 | grep 'replicas:'
# dasselbe für den booleschen Parameter: external entscheidet, welcher Service-Typ im Manifest landet
helm template main chart --set external=true | grep 'type:'
```

```
  replicas: 5
  type: LoadBalancer
          type: RuntimeDefault
```

Die dritte Zeile ist kein Fehler und kein Tippfehler von Ihnen. `grep` sucht das Wort im
gesamten Text, und `type:` taucht auch in den Sicherheitsanforderungen (`seccompProfile`) auf.
Eine nützliche Erinnerung daran, dass `grep` die YAML-Struktur nicht versteht: es sucht nach Zeilen,
nicht nach Feldern.

⚠️ **`helm template` sendet nichts an den Cluster und prüft nichts auf dessen Seite.** Es
rendert Text. Ein Manifest, das `helm template` bestanden hat, kann vom Cluster dennoch abgelehnt werden –
zum Beispiel wegen eines fehlenden CRD. Es ist eine billige Prüfung, keine vollständige.

## Schritt 3. Zerlegen Sie die ApplicationDefinition

Der Chart weiß, wie die Anwendung auszurollen ist. Aber der Katalog weiß noch nichts von ihr:
Damit „Guest Pass“ als Eintrag im Dashboard erscheint und zu einem Objekttyp in der
API wird, braucht es noch eine Datei.

Sie liegt gleich dort – `applicationdefinition.yaml`.

<details>
<summary><b>Genauer betrachtet: was in applicationdefinition.yaml steckt</b></summary>

```yaml
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: guest-pass
```

Beachten Sie, was hier **nicht** steht: das Feld `namespace`. Das ist genau die cluster-scoped Natur
des Objekts. Es gibt eines pro Cluster, und der Katalog-Eintrag, den es erzeugt, wird von
allen Tenants auf einmal gesehen.

### Der Block `application` — wie das in der API aussieht

```yaml
  application:
    kind: GuestPass
    plural: guestpasses
    singular: guestpass
```

Nachdem diese Datei angewendet wurde, erscheint ein neuer Objekttyp im Cluster. Keine
„Integration“ und kein „Plugin“ – ein vollwertiger Typ, mit dem Sie mit dem gewöhnlichen
`kubectl` arbeiten. Diese beiden Befehle funktionieren für jeden Tenant, sobald der Admin die
Definition anwendet:

```bash
# get = „zeig mir, was da ist“. guestpasses ist genau der Name aus dem Feld plural unten:
#   -n tenant-workshopXX   in welchem namespace nachzusehen ist; ersetzen Sie XX durch Ihre eigene Nummer
kubectl get guestpasses -n tenant-workshopXX
# describe = „zeig mir alles über ein Objekt“: Parameter, Zustand, jüngste Events.
# main ist hier der Name einer konkret bestellten Anwendung, nicht der Name des Typs.
kubectl describe guestpass main -n tenant-workshopXX
```

`plural` ist das, was in Befehle und in die API-URL eingesetzt wird. `singular` ist das, was
Sie in `kubectl describe` schreiben. Beide werden kleingeschrieben und ohne Leerzeichen – eine
Anforderung von Kubernetes, keine Stilfrage.

```yaml
    openAPISchema: |-
      {"title":"Chart Values","type":"object","properties":{...}}
```

Dasselbe Schema, das im Chart als Datei `values.schema.json` liegt, nur als eine
einzige Zeile JSON geschrieben. Es wirkt an zwei Stellen: die API weist ungültige Werte zurück, und das
Dashboard zeichnet daraus das Erstellungsformular – Feldtypen, Standardwerte, Hinweise.

⚠️ **Das Schema hier und das Schema im Chart müssen übereinstimmen.** Es gibt keine automatische Verbindung
zwischen ihnen: das sind zwei Dateien, und sie synchron zu halten ist Ihre Aufgabe. Lassen Sie sie
auseinanderlaufen, dann zeigt das Formular im Dashboard den einen Satz Felder, während der Chart einen
anderen erwartet. `check.sh` gleicht sie für Sie ab, aber es lohnt sich, diese Prüfung zur Gewohnheit zu machen.

### Der Block `release` — was auszurollen ist

```yaml
  release:
    prefix: guest-pass-
```

Der Release-Name setzt sich aus dem Präfix und dem Namen des Objekts zusammen: ein `GuestPass` namens `main`
wird als Release `guest-pass-main` ausgerollt. Das Feld ist erforderlich. Es wird gebraucht, damit
Releases verschiedener Anwendungen sich in einem namespace nicht in den Namen ins Gehege kommen: vieles ist
`main` benannt, aber `guest-pass-main` ist nur Ihres.

```yaml
    labels:
      sharding.fluxcd.io/key: tenants
```

Ein Service-Label von Cozystack: anhand seiner werden die Releases der Tenants auf die Handler von Flux verteilt.
Ohne es gibt es niemanden, der das Release bedient, und es bleibt wartend hängen. Hier ist
nicht der Ort für Eigeninitiative – übernehmen Sie es unverändert.

```yaml
    chartRef:
      kind: HelmChart
      name: cozystack-guest-pass
      namespace: cozy-public
```

Woher der Chart zu beziehen ist. Es gibt drei gültige Werte für `kind`: `OCIRepository`,
`HelmChart`, `ExternalArtifact`.

Externe Kataloge kommen üblicherweise über die Kette `GitRepository` → `HelmChart`: der Admin
fügt Ihr Repository als Quelle im namespace `cozy-public` hinzu, Flux zieht den Chart daraus, und die
`ApplicationDefinition` verweist auf diesen Chart. Genau dieser Weg wird in
`cozystack/external-apps-example` gezeigt, und er ist ein sinnvoller Ausgangspunkt.

⚠️ **Die Namen in `chartRef` sind nicht allein Ihre Sache zu erfinden.** Sie müssen damit übereinstimmen, wie der Admin
die Quelle registriert. Stimmen Sie sie ab, bevor Sie die Datei versenden – sonst lässt sich die Definition
zwar anwenden, aber es gibt nichts auszurollen, und der Fehler zeigt sich erst bei der
ersten Person, die auf „erstellen“ klickt.

### Der Block `dashboard` — wie das in der Oberfläche aussieht

```yaml
  dashboard:
    category: PaaS
    singular: Guest Pass
    plural: Guest Passes
    description: Internal guest pass service for employees and reception
    tags: [internal, web]
```

`category` ist der Abschnitt des Katalogs. Cozystack verwendet fünf davon: `PaaS`, `IaaS`, `NaaS`,
`Administration`, `Networking`. Nehmen Sie einen vorhandenen. Ein eigener Abschnitt bedeutet einen Abschnitt
mit einem einzigen Eintrag, in dem niemand Ihre Anwendung findet.

`singular` und `plural` sind hier die **menschlichen** Namen, mit Leerzeichen und Großbuchstaben.
Verwechseln Sie sie nicht mit denen im Block `application`: jene sind für die API, diese sind
für das Auge.

```yaml
    icon: PHN2ZyB3aWR0aD0iMTQ0IiBoZWlnaHQ9IjE0NCIgdmlld0JveD0iMCAwIDE0NCAxNDQi...
```

Das Icon ist ein SVG, in base64 kodiert. Kodiert, kein Pfad und kein Link: das Dashboard geht
nirgendwohin, um es herunterzuladen, das Bild lebt im Objekt selbst.

Die Quelle liegt gleich dort, in `icon.svg`, und die fertige Zeichenkette in `icon.b64`. Wenn Sie
die Quelle bearbeitet haben, muss die Zeichenkette neu gebaut werden. Der Encoder bricht die Ausgabe standardmäßig
in Zeilen um, aber das Feld `icon` braucht eine einzige durchgehende Zeichenkette – deshalb werden die
Zeilenumbrüche in einem separaten Schritt entfernt.

```bash
# base64 = eine Binärdatei in eine Zeichenkette aus Buchstaben, Ziffern und den Zeichen + / = verwandeln
#   -i icon.svg   was zu kodieren ist (die Flag-Schreibweise für macOS und BSD)
# tr -d '\n' = jeden Zeilenumbruch aus der Ausgabe entfernen und sie zu einer zusammenkleben
base64 -i icon.svg | tr -d '\n'
```

Unter Linux hat derselbe Befehl andere Flags: `base64 -w0 icon.svg`, wobei `-w0` „die Ausgabe
überhaupt nicht umbrechen“ bedeutet. Die Flag-Schreibweisen von GNU und BSD stimmen hier nicht überein.

Die Leinwandgröße 144×144 entspricht den eingebauten Icons der Plattform. Mehr wird nicht gebraucht: im
Katalog wird es klein dargestellt.

```yaml
    keysOrder: [["apiVersion"], ["kind"], ["metadata"], ..., ["spec", "replicas"], ...]
```

Die Reihenfolge der Felder in der YAML-Darstellung des Objekts. Kosmetisch, aber ohne sie ordnen sich die Felder
beliebig an – das selten genutzte `resources` zuerst, das wichtige `replicas` danach – und
das Formular liest sich schlechter, als es könnte.

</details>

## Schritt 4. Versuchen Sie anzuwenden — und werden abgewiesen

📍 **Wo:** auf dem Bastion, mit Tenant-Zugang.

Die Datei ist fertig und syntaktisch einwandfrei – versuchen wir, sie anzuwenden, als hätten wir die
Rechte. Die Verweigerung kommt vom Cluster, nicht von `kubectl`, und der Text der Verweigerung sagt
genau, was gefehlt hat.

```bash
# Tenant-Zugang — derselbe, mit dem Sie den ganzen Workshop über gearbeitet haben
export KUBECONFIG=~/.kube/config
# apply = „bringe den Cluster in Einklang mit dem, was in der Datei steht“; -f — aus einer Datei lesen
kubectl apply -f applicationdefinition.yaml
```

**Was Sie sehen werden:**

```
Error from server (Forbidden): error when creating "applicationdefinition.yaml":
applicationdefinitions.cozystack.io is forbidden: User "workshopXX" cannot create
resource "applicationdefinitions" in API group "cozystack.io" at the cluster scope
```

Die Verweigerung ist erwartet: sie wurde zu Beginn des Labs angekündigt. Worauf es hier ankommt, sind die
letzten vier Worte – **at the cluster scope**.

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Ihre Rechte im Tenant sind Rechte innerhalb eines namespace. Sie sind der vollständige Herr über Ihr
eigenes Stück: Sie starten Cluster, Datenbanken, VMs, löschen sie, zerbrechen sie, reparieren sie. Keines
Ihrer Objekte ist für einen Nachbarn sichtbar oder stört ihn.

`ApplicationDefinition` ist anders gebaut. Es ändert den Katalog **für alle Tenants auf
einmal**. Eine Anwendung mit einem Fehler im Schema, von Ihnen angewendet, wird von Leuten aus anderen
Abteilungen gesehen und ausprobiert. Eine Anwendung mit demselben Namen wie eine bestehende
zerstört die bestehende.

Deshalb verläuft die Grenze genau hier, und es geht nicht um Misstrauen. In vSphere war es
genauso: Ihre eigenen VMs in Ihrem eigenen Pool haben Sie selbst erstellt, aber den Inhalt der gemeinsamen
Content Library und die Rechte daran – nicht.

**Was in der Praxis zu tun ist.** Übergeben Sie dem Plattform-Admin zwei Dateien und eine Absprache:

| Was zu übergeben ist | Warum |
|---|---|
| `applicationdefinition.yaml` | das Objekt selbst, das er anwenden wird |
| ein Link zum Repository mit dem Chart | daraus baut der Admin die Quelle in `cozy-public` |
| die abgestimmten Namen in `chartRef` | damit die Definition den Chart findet |

Und prüfen Sie vor dem Versand, dass beide Dateien in Ordnung sind – denn die Rückkopplungsschleife ist hier
lang: der Admin wendet es an, und eine dritte Person sieht den Fehler.

</details>

Die Verweigerung könnte auch von einem Fehler in der Datei selbst kommen. Trennen wir die beiden:
fragen Sie zuerst nach den Berechtigungen, lassen Sie dann `kubectl` die ganze Datei parsen, ohne sie irgendwohin zu senden.

```bash
# auth can-i = „darf ich das?“. Die Antwort ist ja oder nein, und der Cluster wird nicht verändert.
kubectl auth can-i create applicationdefinitions
# --dry-run=client = „parse die Datei und zeige, was herauskäme, aber geh nicht zum Cluster“.
# client bedeutet, dass die gesamte Prüfung auf dem Bastion läuft und der Cluster nie etwas davon erfährt.
kubectl apply -f applicationdefinition.yaml --dry-run=client
```

**Was Sie sehen sollten.** Der erste Befehl – `no`. Der zweite –
`applicationdefinition.cozystack.io/guest-pass created (dry run)`: die Datei ist geparst, die
Syntax ist in Ordnung, das Problem sind wirklich die Berechtigungen.

⚠️ **`--dry-run=client` prüft nur die Syntax.** Es fragt den Cluster überhaupt nichts.
`--dry-run=server` würde fragen, aber das erfordert genau die Rechte, die fehlen.

## Schritt 5. Was die Tochtergesellschaften sehen werden

Wenn der Admin die Definition anwendet, erhält der Katalog einen Eintrag. Von diesem Moment an rollt jeder
Tenant „Guest Pass“ genauso aus, wie er Redis ausgerollt hat: **Create application** →
`Guest Pass` → ein Formular aus Ihren vier Parametern → ein Button.

Oder als Text – die Datei `guestpass-example.yaml` aus diesem Ordner:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: GuestPass
metadata:
  name: main
  namespace: tenant-workshopXX
spec:
  replicas: 2
  greeting: "Order a pass for your guest"
  external: false
```

Beachten Sie die Gruppe: `apps.cozystack.io` – dieselbe wie für `Bucket` und `VMInstance`. Ihre
Anwendung hat ihren Platz **in derselben Reihe** wie die eingebauten eingenommen, nicht abseits.
Sie erscheint auf dieselbe Weise in der Anwendungsliste des Tenants, ihre Ressourcen zählen auf dieselbe
Weise, Berechtigungen funktionieren auf dieselbe Weise.

⚠️ Sie können diese Datei nicht anwenden, bevor der Admin die Definition registriert hat: `kubectl`
antwortet mit `no matches for kind "GuestPass"` – einen solchen Objekttyp gibt es im Cluster noch nicht.

## Schritt 6. Wie man all das nicht von Hand schreibt

Alles, was Sie in diesem Lab auseinandergenommen haben, ist ein Grundgerüst: `Chart.yaml`, `values.yaml`, das
Schema, die Templates, die `ApplicationDefinition` mit den richtigen Namen und Labels. Die Hälfte der
Datei sind Pflichtfelder, die überall gleich sind, und man macht sie leichter falsch, als man sie
schreibt.

Dafür gibt es ein fertiges Werkzeug.

| Was | Wo | Warum |
|---|---|---|
| Das Repository `cozystack/ccp` | github.com/cozystack/ccp | eine Sammlung von Plugins und Skills für Claude Code |
| Das Plugin `cozystack` | von dort | bringt Claude Code die Struktur von Cozystack-Paketen bei |
| Der Skill `external-app-create` | im Plugin | erzeugt das gesamte Grundgerüst einer externen Anwendung |
| Das Beispiel-Repository | github.com/cozystack/external-apps-example | ein funktionierendes Beispiel mit Bau und Veröffentlichung des Charts |

Der Skill fragt nach dem Namen der Anwendung, dem kind, der Kategorie und den Parametern – und
legt einen fertigen Dateibaum an: den Chart mit seinem Schema, die `ApplicationDefinition` mit den
richtigen Präfixen und Labels, ein Makefile zum Bauen.

All das von Hand auseinanderzunehmen verliert seinen Sinn nicht. Das erzeugte Grundgerüst muss trotzdem
gelesen und bearbeitet werden, und zu bearbeiten, was man nicht versteht, ist die schlechteste bekannte Art zu
arbeiten.

## Die Prüfung

📍 **Wo:** auf dem Bastion, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

Das Skript läuft **lokal** und rührt den Cluster nicht an: es prüft, dass der Chart den
Linter besteht, dass er rendert, dass die Parameter wirklich in den Manifesten ankommen, dass die
`ApplicationDefinition` parst und alle erforderlichen Felder enthält, dass das Icon in SVG
dekodiert – und, am wichtigsten, dass das Schema in der Definition mit dem Schema im
Chart übereinstimmt.

```bash
# ./ vor dem Namen bedeutet „die Datei aus dem aktuellen Ordner“, also aus labs/13-catalog
./check.sh
```

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell – wie man es einrichtet, ist
am Anfang von Lab 0 beschrieben. Ohne WSL können Sie das Lab abschließen, aber es wird keinen
Artefakt-Bericht geben.

Wenn `KUBECONFIG` gesetzt ist, fragt das Skript außerdem den Cluster nach den Berechtigungen und bestätigt,
dass Sie nicht berechtigt sind, die Definition anzuwenden. Das Skript wertet das Fehlen der Rechte
als erwartetes Ergebnis, nicht als Fehler.

## Aufräumen

Es gibt nichts aufzuräumen: Sie haben nichts im Cluster erstellt. Das ist das einzige Lab im
Workshop, das keine Spur hinterlässt, und das ist sein besonderes Merkmal – die Arbeit des
Plattform-Teams sieht meistens genau so aus: Text, Review, fremde Hände beim Anwenden.

Nehmen Sie die Dateien `chart/` und `applicationdefinition.yaml` mit. Das ist ein funktionierender
Ausgangspunkt; daraus kann eine echte Anwendung für Ihren Katalog wachsen.

## Was wir jetzt können

- Eine Anwendung in einen Helm-Chart mit Parameterschema verpacken und lokal prüfen
- Eine `ApplicationDefinition` schreiben und den Zweck jedes ihrer Blöcke erklären
- Verstehen, warum der Katalog geteilt ist und warum ein Tenant keine Rechte daran hat
- Die Übergabe an den Admin so vorbereiten, dass er die Datei beim ersten Versuch anwendet
- Wissen, womit man das Grundgerüst generiert und welches Beispiel man ansehen sollte

## Und in vSphere wäre das

Die Content Library und eine OVF-Vorlage mit Eingabefeldern. Die Mechanik ist ähnlicher, als sie
scheint: ein Team bereitet die Vorlage vor, ein anderes legt sie in die gemeinsame Library, und
wieder andere rollen sie aus.

Der Unterschied liegt darin, was am Ende dabei herauskommt. Eine OVF-Vorlage ist eine Maschine mit einer Festplatte: Sie rollen
sie aus, und von da an lebt sie für sich, und Sie werden sie auf jeder Kopie von Hand aktualisieren. Eine
`ApplicationDefinition` ist eine Beschreibung, hinter der ein Chart steht: aktualisieren Sie den Chart, erhöhen Sie die
Version, und alle Installationen aktualisieren sich über einen einzigen Mechanismus.

**Wo vSphere ehrlich gesagt bequemer ist.** Die Content Library ist eine fertige
Oberfläche: Datei hineinlegen, Rechte vergeben, fertig. Hier müssen Sie ein Repository einrichten,
Bau und Veröffentlichung des Charts konfigurieren, mit dem Admin Namen für die Quelle abstimmen – und
all das, bevor überhaupt etwas im Katalog erscheint. Die Einstiegshürde ist höher, und die
erste Anwendung dauert einen Tag, keine Stunde.

Es zahlt sich bei der zweiten und dritten Anwendung aus, und besonders beim ersten Update.
Eine Anwendung, die sich über fünf Tochtergesellschaften verteilt hat, aus einem Chart zu aktualisieren, gegenüber
der Aktualisierung derselben Anwendung auf fünf auseinandergelaufenen OVF-Kopien – das ist ein anderer
Arbeitsaufwand. Eine andere Größenordnung.
