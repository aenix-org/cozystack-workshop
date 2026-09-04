# Lab 6 · Ihre eigene private Image-Registry

| | |
|---|---|
| **Zeit** | 45 Minuten, davon 10 mit Warten |
| **Was es beweist** | Eine Image-Registry steht in zehn Minuten, und der Cluster kann nur aus ihr ziehen |
| **Was Sie brauchen** | Der Cluster aus Lab 0, `kubectl`, `docker` (oder `podman`) auf dem Bastion, Zugang zum Dashboard |

## Warum das wichtig ist

Der Dienst „Passes“ hat es bis zur Informationssicherheit geschafft, und von dort kam eine E-Mail zurück.

> Container-Images werden aus öffentlichen Registries im Internet gezogen. Das ist inakzeptabel:
> niemand hat geprüft, was in einem Image steckt, sein Inhalt kann sich unter demselben Namen ändern,
> und wenn die externe Ressource nicht verfügbar ist, startet ein Produktivdienst nicht. Alle Images
> müssen im internen Registry der Organisation gespeichert werden.

Dagegen lässt sich nichts einwenden — jeder Punkt ist berechtigt. Ein öffentliches Image mit dem Tag `latest`
kann heute das eine und morgen etwas anderes sein. Der Autor des Images kann es löschen. Eine externe
Registry kann Ihnen die Download-Geschwindigkeit im ungünstigsten Moment drosseln — und das ist keine
Hypothese, jede große öffentliche Registry macht das.

Also brauchen Sie eine eigene Registry. Normalerweise ist das ein Projekt für sich: ein Antrag auf eine VM,
Installation, Zertifikate, Speicher, Backups, jemandes Quartal. Heute ist es ein Posten im Katalog.

Und da die Registry Ihnen gehört und geschlossen ist, muss dem Cluster Zugang dazu erteilt werden. Daran
stolpern alle, und wir werden auch stolpern, absichtlich.

## Kleines Glossar

| Begriff | Was es ist | Ähnlich wie … aber |
|---|---|---|
| **Image** | Ein Abbild einer Anwendung mit allem, was zum Ausführen nötig ist | **Ein VM-Template**, aber unveränderlich: Sie können nicht hineingehen und etwas korrigieren, Sie bauen ein neues |
| **Layer** | Ein Teil eines Images. Ein Image wird aus Layern gebaut, und Layer werden wiederverwendet | identische Layer verschiedener Images werden in der Registry nur einmal gespeichert |
| **Tag** | Eine Versionsbezeichnung für ein Image: `passes-api:v1` | **Ein Versionsname eines Templates**, aber ein Tag kann auf ein anderes Image umgehängt werden, und das ist die Hauptquelle von Ärger |
| **Registry** | Ein Image-Speicher, der über HTTP bereitgestellt wird | **Eine Content Library**, aber sie gibt Layer bei jedem Start über das Netzwerk heraus, statt das ganze Template zu kopieren |
| **Harbor** | Eine Registry mit Oberfläche, Projekten, Berechtigungen und einem Schwachstellen-Scanner | **Content Library + Berechtigungen + Berichte**, aber sie kann Image-Inhalte prüfen und signieren |
| **Ein Projekt in Harbor** | Ein Bereich innerhalb der Registry mit eigenen Berechtigungen | **Ein Ordner in einer Content Library**, aber es kann öffentlich oder privat sein, und davon hängt ab, ob Zugangsdaten nötig sind |
| **`imagePullSecret`** | Ein Secret mit Login und Passwort für die Registry, das vom Node gelesen wird | **Der Account zum Verbinden einer Content Library**, aber ihn braucht der **Node**, nicht Sie; Ihr `docker login` nützt dem Cluster nichts |
| **Dockerfile** | Die Anleitung zum Bauen eines Images | **Die Anleitung zum Vorbereiten eines Templates**, aber sie läuft bei jedem Build vollständig und von vorn |
| **Downward API** | Eine Möglichkeit, einem Pod Informationen über sich selbst über Umgebungsvariablen zu geben | **Gastvariablen aus VMware Tools**, aber die Werte werden vom Cluster beim Start eingespeist; die Anwendung fragt nicht danach |

## Zwei Kubeconfigs: nicht verwechseln

Ab hier geht es im Lab um zwei verschiedene Cluster, und es lohnt sich, sie vor dem ersten Befehl
auseinanderzuhalten.

| Kubeconfig | Was es ist | Was wir damit machen |
|---|---|---|
| `~/.kube/config` | Der Cozystack-Management-Cluster, Ihr Tenant | Managed Services ansehen: Harbor, Datenbanken, Queues |
| `~/lab.kubeconfig` | **Ihr** `lab`-Cluster aus Lab 0 | die Anwendung deployen |

Beide bekommen Sie im Dashboard. Der Tenant-Kubeconfig liegt im Secret `kubeconfig-tenant-workshopXX`
(Reiter Secrets), der Cluster-Kubeconfig im Zugangsbereich Ihres `lab`-Clusters.

⚠️ **Die häufigste Ursache für „bei mir geht nichts“ in diesem Lab ist ein Befehl, der an den falschen
Cluster ging.** Vor jedem Befehlsblock steht, für welchen Cluster er gedacht ist. Wenn Sie unsicher sind:

```bash
# echo gibt den Wert der Variablen aus: welche Zugangsdatei kubectl gerade verwendet.
# Leer bedeutet, kubectl nimmt die Standarddatei ~/.kube/config, nicht die, die Sie meinen.
echo $KUBECONFIG

# get nodes = „zeige die Nodes des Clusters". Hier ist es ein Lackmustest:
# die Antwort verrät, an welchen der beiden Cluster der Befehl ging.
kubectl get nodes
```

Der `lab`-Cluster hat einen einzigen Node mit einem Namen wie `kubernetes-lab-md0-...`. Im
Management-Cluster wird dieser Befehl höchstwahrscheinlich eine Ablehnung zurückgeben — ein Tenant hat
keine Berechtigung, Nodes zu sehen.

## Was im Lab-Ordner liegt

Alle Dateien gehören bereits Ihnen — Sie haben sie zusammen mit dem Repository bekommen. Es gibt nichts
neu zu erstellen oder abzutippen: Wo unten `kubectl apply -f name.yaml` steht, wird die Datei von hier
genommen.

```bash
# jeder Befehl in diesem Lab wird aus dem Lab-Ordner ausgeführt — wechseln Sie hinein
cd labs/06-harbor
```

| Datei | Was es ist | Wann es nützlich ist |
|---|---|---|
| `app/` | Die Quellen des „Passes“-Dienstes in Go und ein `Dockerfile` — daraus bauen Sie das Image | Sie bauen lokal, `docker build` |
| `passes-broken.yaml` | Eine **absichtlich unvollständige** Datei: keine Zugangsdaten zur Registry | Sie wenden sie an, um die Ablehnung mit eigenen Augen zu sehen |
| `passes.yaml` | Dieselbe Datei, aber mit Registry-Zugang | Sie wenden sie an, nachdem Sie es verstanden haben |
| `check.sh` | Eine Prüfung, dass das Image aus Ihrem Harbor kam, nicht aus dem Internet | Sie führen sie am Ende des Labs aus |

## Schritt 1. Harbor erstellen

📍 **Wo:** im Browser, im Cozystack-Dashboard. Die Registry ist eine gemeinsame Tenant-Ressource, nicht
Teil Ihres Lab-Clusters, daher wird sie an derselben Stelle erstellt, an der auch der Cluster selbst
erstellt wurde.

Tenant → **Create application** → `Harbor`.

| Feld | Wert | Warum |
|---|---|---|
| Name | `harbor` | wird Teil der Registry-Adresse; was dabei herauskommt, sehen Sie nach dem Erstellen |
| Host | leer lassen | dann setzt sich die Adresse von selbst aus dem Namen und der Tenant-Domain zusammen |
| Storage class | `replicated` | die Daten werden in drei Kopien auf verschiedenen Nodes gehalten |
| Trivy → enabled | **ausschalten** | der Schwachstellen-Scanner lädt eine mehrere Gigabyte große Datenbank herunter; auf einer Schulungs-Testumgebung sind das zusätzliche zwanzig Minuten Warten |
| Database → replicas | `1` | die Ausfallsicherheit der Registry-Datenbank testen wir heute nicht |
| Database → size | `5Gi` | |
| Redis → replicas | `1` | |
| Redis → size | `1Gi` | |
| Core / Registry preset | wie vorgeschlagen lassen | |

⚠️ **Das Redis in diesem Formular ist Harbors eigener interner Cache; mit dem nächsten Lab hat es nichts
zu tun.** Im Lab über Caching stellen Sie ein separates Redis für Ihre eigene Anwendung auf. Der Name ist
derselbe, die Rollen sind verschieden.

Klicken Sie auf Erstellen und warten Sie. Harbor kommt in fünf bis zehn Minuten hoch: Es ist nicht eine
einzelne Anwendung, sondern mehrere Dienste plus eine Datenbank plus Object Storage für die Image-Layer
selbst.

⚠️ **Wenn Harbor länger als fünfzehn Minuten in einem Zustand „nicht bereit“ verharrt** — schauen Sie,
was passiert: `kubectl -n tenant-workshopXX get pods | grep harbor`. Meist ist es die
Installationswarteschlange, die für die ganze Plattform gemeinsam ist: Ihre Anwendung steht darin hinter
denen anderer und wartet.

Harbor speichert Image-Layer in S3-kompatiblem Storage, und der Bucket dafür wird von selbst erstellt —
Sie müssen dafür keinen eigenen Storage im Tenant aktivieren, der übergeordnete genügt. Wenn die Pods
nach mehr als einer halben Stunde immer noch nicht erscheinen, schreiben Sie in den Workshop-Chat mit der
Ausgabe dieses Befehls.

## Schritt 2. Zugangsdaten holen und sich an der Registry anmelden

📍 **Wo:** im Dashboard, dann in einem Terminal auf dem Bastion.

Öffnen Sie die erstellte Anwendung `harbor` und finden Sie den Reiter mit den Secrets. Dort liegt ein
Secret mit den Registry-Zugangsdaten, und darin drei Schlüssel, die Sie brauchen:

| Schlüssel | Was darin steht |
|---|---|
| `url` | die Adresse Ihrer Registry, in der Form `https://harbor-....<Testumgebungs-Domain>` |
| `admin-password` | das Passwort des Administrators |
| `redis-password` | Harbors internes Passwort, das Sie nicht brauchen |

Der Login ist `admin`.

⚠️ **Raten Sie die Registry-Adresse nicht, nehmen Sie sie aus dem Schlüssel `url`.** Die Plattform stellt
dem Anwendungsnamen den Diensttyp voran, daher kann die Adresse anders ausfallen, als Sie es nach dem
Namen erwartet haben. Dieselbe Adresse ist in der Ingress-Liste der Anwendung zu sehen.

Dasselbe Passwort ist auch per Befehl verfügbar. Einem Tenant ist es nicht erlaubt, **alle** Secrets
pauschal zu lesen — prüfen Sie selbst, `kubectl auth can-i get secrets` antwortet `no`. Aber für jede
Anwendung, die Sie erstellen, richtet die Plattform eine separate Regel ein, die genau deren Zugangsdaten
erlaubt:

```bash
# get secret = „zeige das Secret-Objekt". Der Name des Secrets setzt sich aus dem Präfix
# für den Anwendungstyp und seinem Namen zusammen: harbor- + harbor.
#   -n tenant-workshopXX  in welchem Namespace zu suchen ist — in Ihrem Tenant
#   -o jsonpath='...'     ein einzelnes Feld aus dem Objekt herausziehen, statt es ganz auszugeben
#   base64 -d             dekodieren: Werte in Secrets liegen in base64
#   ; echo                einen Zeilenumbruch anhängen, sonst klebt das Passwort am Prompt
kubectl -n tenant-workshopXX get secret harbor-harbor-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Das Dashboard ist insofern bequemer, als Sie sich nicht mit base64 herumärgern müssen. Der Befehl ist
insofern bequemer, als Sie ihn in ein Skript packen können.

Öffnen Sie die Adresse in einem Browser und melden Sie sich an. Sie sehen die Harbor-Oberfläche mit
einem einzigen Projekt, `library`.

Jetzt dasselbe vom Terminal aus. `docker login` fragt nach Benutzername und Passwort und speichert die
Zugangsdaten auf Ihrem Bastion, in der Datei `~/.docker/config.json`. Danach gehen `docker push` und
`docker pull` zu dieser Registry, ohne nach irgendetwas zu fragen.

```bash
# login = „merke dir die Zugangsdaten für diese Registry".
# Das Argument ist die Registry-Adresse aus dem Schlüssel url; harbor-harbor.workshop03.example.org ist hier ein Beispiel.
# Der Befehl fragt nach einem Benutzernamen (admin) und einem Passwort; das Passwort wird beim Tippen nicht angezeigt.
docker login harbor-harbor.workshop03.example.org
```

Ab hier im Text ist `harbor-harbor.workshop03.example.org` **Ihre** Adresse — setzen Sie Ihre eigene ein.

**Was Sie sehen sollten:**

```
Login Succeeded
```

⚠️ **Dieser `docker login` hat Ihrem Bastion beigebracht, sich an der Registry anzumelden — und nur ihm.**
Für den Cluster hat er nichts getan. Merken Sie sich das; Sie brauchen es etwas später im Lab.

## Schritt 3. Ein privates Projekt anlegen

📍 **Wo:** im Browser, in Harbor.

**Projects** → **New Project**.

| Feld | Wert | Warum |
|---|---|---|
| Project Name | `passes` | ein Projekt pro Dienst — so lassen sich Berechtigungen leichter vergeben |
| Access Level | **Public nicht ankreuzen** | die Sicherheit hat eine geschlossene Registry verlangt, nicht „Ihre, aber offen für das ganze Internet“ |
| Storage quota | `-1` (keine Grenze) | auf der Testumgebung würde eine Quota nur stören |

Das Projekt `library`, das von Anfang an da war, ist öffentlich. Aus ihm werden Images ganz ohne
Zugangsdaten gezogen. Genau deshalb verwenden wir es nicht: Es erzeugt nicht jenen Zugriffsfehler, um den
herum das Lab gebaut ist.

## Schritt 4. Das Image bauen

📍 **Wo:** auf dem Bastion (im Terminal des Bastion).

Im Ordner dieses Labs liegt `app/` — die Quelle des „Passes“-Dienstes und die Build-Anleitung. Bevor wir
bauen, sehen wir uns an, was darin steckt.

<details>
<summary><b>Genauer betrachtet: was in der Anwendung steckt</b></summary>

Die Datei `app/main.go`, etwa siebzig Zeilen Go. Sie tut genau zwei Dinge.

**Sie antwortet auf `/healthz` mit dem Wort `ok`.** Das ist die Adresse für die Bereitschaftsprüfung: Der
Cluster klopft hier an und schickt keinen Traffic an eine Replica, bis er eine Antwort bekommt.

**Sie antwortet auf `/` mit einem kleinen JSON**, in dem sie über sich selbst berichtet:

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

Woher kennt die Anwendung ihren eigenen Namen, Node und Namespace? Sie **ermittelt sie nicht**. Der
Cluster legt sie beim Start dort ab, in Umgebungsvariablen:

```go
Pod:  env("POD_NAME", "unknown"),
Node: env("NODE_NAME", "unknown"),
```

Und im Manifest steht, was dort hineingelegt werden soll:

```yaml
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
```

Das nennt sich Downward API — „von oben herabgereichte Informationen“. Das nächste Analogon in vSphere
sind die Gastvariablen, die VMware Tools in die Maschine hineinreicht. Der Unterschied ist, dass hier die
Anwendung nichts fragt und nirgendwohin geht: Die Werte liegen bereits in der Umgebung, wenn der Prozess
startet. Kein Client zur Cluster-API, keine Berechtigungen auf diese API nötig.

**In der Anwendung gibt es keine einzige externe Bibliothek, nur die Go-Standardbibliothek.** Das ist
keine Koketterie: Ein Build mit Abhängigkeiten würde für Pakete ins Internet gehen, und das ganze Lab
begann damit, dass die Sicherheit Gänge ins Internet verboten hat.

Die Datei `app/Dockerfile` ist die Build-Anleitung. Sie hat zwei Stufen:

```dockerfile
FROM golang:1.23-alpine AS build
...
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

FROM alpine:3.21
COPY --from=build /out/passes-api /usr/local/bin/passes-api
```

Die erste Stufe ist die Build-Stufe. Sie braucht den gesamten Go-Compiler, ungefähr 350 MB. Die zweite
Stufe ist das, was tatsächlich in den Cluster geht: Aus der ersten Stufe wird **nur die fertige
Binärdatei** übernommen, alles andere wird weggeworfen.

Das Ergebnis ist ein Image von etwa zehn Megabyte statt dreihundertfünfzig. Es geht nicht nur um die
Größe: Darin gibt es keinen Compiler, keine Quellen, keinen Paketmanager. Wer es doch in den Container
geschafft hat, hat nichts, womit er arbeiten könnte.

Vergleichen Sie das damit, wie es bei Templates virtueller Maschinen funktioniert. Ein Template trägt das
ganze Betriebssystem in sich, samt Compiler, falls dieser jemals dort gelandet ist. Es nachträglich zu
verkleinern ist nahezu unmöglich.

Die letzten Zeilen:

```dockerfile
RUN adduser -D -u 10001 app
USER 10001
```

Die Anwendung läuft nicht als root. In einem richtig konfigurierten Cluster wird ein Pod nicht als root
laufen dürfen, und das ist nicht unsere Pingeligkeit, sondern eine Anforderung, auf die Sie in jedem
modernen Cluster stoßen werden.

</details>

Der Befehl `docker build` baut das Image: Er liest das `Dockerfile`, führt die dort beschriebenen Schritte
aus und legt das Ergebnis in den Image-Speicher auf Ihrem Bastion. Der Name, unter dem das Ergebnis dort
abgelegt wird, wird mit dem Flag `-t` festgelegt und besteht aus drei Teilen:

| Teil | Was es bedeutet |
|---|---|
| `harbor-harbor.workshop03.example.org` | die Registry-Adresse — wohin man für das Image geht |
| `passes/passes-api` | das Projekt und der Name innerhalb der Registry |
| `v1` | der Versions-Tag |

Die Registry-Adresse ist Teil des Image-Namens. Genau deshalb ändert der Umzug auf die eigene Registry
jedes Manifest: Der Image-Name wird ein anderer.

Bauen wir. Ersetzen Sie die Adresse durch Ihre eigene:

```bash
cd labs/06-harbor

# build = „baue das Image nach dem Dockerfile".
#   --platform linux/amd64  für welchen Prozessor bauen; die Cluster-Nodes laufen auf x86,
#                           und der Bastion kann auf ARM laufen — dann kommt ohne das Flag das Falsche heraus
#   -t <Adresse>/<Projekt>/<Name>:<Tag>  wie das Ergebnis heißen soll. Die Registry-Adresse am Anfang des Namens
#                           ist der Ort, wohin docker push es später schickt
#   app/                    das letzte Argument — der Ordner mit Dockerfile und Quellen;
#                           sein gesamter Inhalt wird dem Builder übergeben
docker build --platform linux/amd64 -t harbor-harbor.workshop03.example.org/passes/passes-api:v1 app/
```

⚠️ **`--platform linux/amd64` ist keine Verzierung.** Wenn Sie einen Mac mit Apple Silicon (M1–M4) oder
einen ARM-Bastion haben, bauen Sie ohne dieses Flag ein ARM-Image. Es baut ohne Fehler, wird ohne Fehler
gepusht, und im Cluster — die Nodes dort laufen auf gewöhnlichem x86 — landet der Pod in
`CrashLoopBackOff`, und in den Logs steht `exec format error`. Das ist langwierig zu diagnostizieren,
weil nichts drumherum darauf hindeutet, dass es an der Prozessorarchitektur liegt.

**Was Sie sehen sollten** — Zeilen über die Build-Schritte und am Ende:

```
Successfully tagged harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

## Schritt 5. Das Image an Ihre Registry senden

📍 **Wo:** auf dem Bastion (im Terminal des Bastion).

Das gebaute Image liegt bisher nur auf Ihrer Festplatte. `docker push` schickt es Layer für Layer an die
Registry; Layer, die in der Registry bereits vorhanden sind, werden nicht erneut übertragen.

```bash
# push = „schicke das Image an die Registry". Wohin, entnimmt docker dem Image-Namen:
# der erste Teil des Namens ist die Registry-Adresse, dorthin geht es, mit den Zugangsdaten von docker login.
docker push harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

**Was Sie sehen sollten** — wie die Layer hinausgehen, und am Ende eine Zeile mit einem langen Hash, dem
`digest`.

Schauen Sie in Harbor im Browser nach: **Projects** → `passes` → dort ist ein Repository
`passes/passes-api` erschienen, und darin der Tag `v1`. Sie sehen die Größe, das Datum und denselben
`digest`.

Dieser `digest` ist der exakte Inhalt des Images. Der Tag `v1` kann morgen auf ein anderes Image
umgehängt werden, und niemand merkt es; der `digest` lässt sich nicht fälschen. Daher die Regel, die
früher oder später jeder lernt: **In die Produktion rollt man per Digest aus, nicht per Tag.**

## Schritt 6. In den Cluster deployen

📍 **Wo:** auf dem Bastion, der `lab`-Cluster.

```bash
# KUBECONFIG sagt kubectl, welche Zugangsdatei zu verwenden ist. Wir wechseln zu Ihrem `lab`-Cluster:
# ab hier gehen alle kubectl-Befehle dorthin.
# Gilt, bis das Terminalfenster geschlossen wird.
export KUBECONFIG=~/lab.kubeconfig
```

Im Lab-Ordner liegt `passes-broken.yaml`. Statt der Registry-Adresse steht darin ein Platzhalter,
`HARBOR-HOST` — er muss durch Ihre Adresse ersetzt werden. Das erledigt `sed`: Es bearbeitet die Datei an
Ort und Stelle, ohne etwas zu fragen oder zu zeigen. Nehmen Sie die Zeile für Ihr System:

```bash
# sed -i = „bearbeite die Datei an Ort und Stelle"
#   's|was|wodurch|g'  alle Vorkommen ersetzen; das Trennzeichen | wird statt / verwendet, weil
#                     die Adresse Schrägstriche enthält und diese sonst maskiert werden müssten
#   Die sed-Version in macOS verlangt nach -i ein zwingendes Argument; die leeren Anführungszeichen
#   bedeuten „keine Sicherungskopie anlegen". Unter Linux darf es ein solches Argument nicht geben.

# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
```

Wenden Sie sie an:

```bash
# apply = „bringe den Cluster in den in der Datei beschriebenen Zustand"
kubectl apply -f passes-broken.yaml

# get pods = „zeige die Pods".
#   -l app=passes-api  nur die mit diesem Label, nicht alles
#   -w                 nicht beenden, sondern Änderungen ausgeben, sobald sie auftreten;
#                      Beobachtung abbrechen — Ctrl+C
kubectl get pods -l app=passes-api -w
```

**Was Sie sehen werden** — und es ist nicht das, was Sie erwartet haben:

```
NAME                          READY   STATUS             RESTARTS   AGE
passes-api-6c9d4f7b8-2xk4n    0/1     ErrImagePull       0          8s
passes-api-6c9d4f7b8-2xk4n    0/1     ImagePullBackOff   0          22s
```

Brechen Sie die Beobachtung mit `Ctrl+C` ab und sehen Sie, was der Cluster sagt:

```bash
# describe = „erzähle ausführlich über das Objekt". Ganz am Ende der Ausgabe kommt das Ereignisprotokoll:
# was der Cluster mit dem Pod versucht hat und wie es endete.
# tail -12 behält die letzten zwölf Zeilen — die Ereignisse stehen genau dort.
kubectl describe pod -l app=passes-api | tail -12
```

```
  Warning  Failed   kubelet  Failed to pull image
    "harbor-harbor.workshop03.example.org/passes/passes-api:v1":
    failed to resolve reference: unexpected status from HEAD request: 401 Unauthorized
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Sie haben sich soeben erfolgreich mit `docker login` an der Registry angemeldet und das Image
> erfolgreich dorthin geschickt. Die Registry kennt Sie. Warum wird der Cluster abgewiesen?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

**Nicht Sie laden das Image herunter.** `kubelet` lädt es herunter — ein Dienst auf dem Cluster-Node. Das
ist eine andere Maschine, ein anderer Prozess und ein anderer Benutzer.

Ihr `docker login` hat die Zugangsdaten in die Datei `~/.docker/config.json` auf **Ihrem Bastion**
geschrieben. Der Cluster-Node weiß nichts von dieser Datei und kann es auch nicht: Zwischen ihm und Ihrem
Bastion gibt es überhaupt nichts Gemeinsames, außer dass Sie dorthin Befehle schicken.

Gehen Sie zurück zur Warnung nach `docker login` etwas weiter oben im Lab. Genau das stand dort, aber die
Folgen waren noch nicht sichtbar.

**Wie man es richtig macht.** Die Zugangsdaten müssen in den Cluster selbst gelegt werden — in ein
Secret-Objekt besonderer Art —, und dann muss im Manifest der Anwendung stehen, welches Secret beim
Herunterladen zu verwenden ist. Ein solches Secret heißt `imagePullSecret`.

**Warum der Cluster eigene Zugangsdaten braucht und nicht Ihre.** Drei Gründe, und alle drei sind
praktisch.

Erstens: Sie sind vielleicht nicht da. Ein Node startet um drei Uhr nachts neu und geht das Image erneut
herunterladen. Ginge er unter Ihrem Account, hinge alles daran, dass Sie noch in dieser Firma arbeiten
und Ihr Passwort nicht abgelaufen ist.

Zweitens: Die Berechtigungen sind verschieden. Sie brauchen die Berechtigung, in die Registry zu
**schreiben**, um Builds dorthin zu schicken. Der Cluster braucht nur zu **lesen**. Dem Cluster die
Berechtigung zu geben, Images aus der Registry zu löschen, ist eine schlechte Idee, und mit Ihrem Account
hätten Sie ihm genau diese gegeben.

Drittens: Die Spuren sind verschieden. Wenn das Registry-Log zeigt, dass das Image von
`robot$passes-puller` und nicht von `admin` heruntergeladen wurde, wird eine Untersuchung des Vorfalls
möglich.

**Warum den Node nicht direkt konfigurieren.** Sie können die Zugangsdaten direkt auf den Node legen, in
die Konfiguration der Container-Runtime — dann ist kein `imagePullSecret` nötig. Manche machen das
gelegentlich. Aber Nodes in einem Cluster sind Wegwerfware: Sie werden beim Upgrade neu erstellt, bei
wachsender Last hinzugefügt, bei Ausfall getötet. Eine von Hand auf einem Node vorgenommene Einstellung
lebt, bis der Node zum ersten Mal ersetzt wird. Ein Secret im Cluster überlebt jeden Austausch.

**Die Lehre reicht über diesen Fehler hinaus.** `ImagePullBackOff` ist fast immer eines von drei
Dingen: ein Tippfehler im Image-Namen, keine Zugangsdaten, oder das Image existiert, aber nicht für die
richtige Prozessorarchitektur. Schauen Sie nicht auf den Status des Pods, sondern auf
`kubectl describe pod` — dort steht die wahre Ursache.

</details>

## Schritt 7. Dem Cluster Zugang zur Registry erteilen

📍 **Wo:** auf dem Bastion, der `lab`-Cluster.

Wir erstellen ein Secret mit den Registry-Zugangsdaten. Eine gesonderte Variante des Befehls
`create secret` erzeugt ein Secret der Art, die `kubelet` beim Herunterladen von Images selbst lesen kann:

```bash
# create secret docker-registry = „erstelle ein Secret mit Registry-Zugangsdaten"
#   harbor             der Name des Secrets im Cluster; das Anwendungs-Manifest verweist darauf
#   --docker-server    für welche Registry diese Zugangsdaten sind — dieselbe Adresse wie im Image-Namen
#   --docker-username  wer sich anmeldet
#   --docker-password  das Passwort; einfache Anführungszeichen sind nötig, wenn es $, ! oder Leerzeichen enthält
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password='IHR-PASSWORT'
```

⚠️ **Ein Passwort in der Befehlszeile bleibt in der Shell-History.** Auf der Testumgebung spielt das keine
Rolle, in einer Arbeitsumgebung schon. Ein Weg ohne die History:

```bash
# read legt das über die Tastatur Eingegebene in die Variable HARBOR_PASS:
#   -s  das Eingegebene nicht am Bildschirm zeigen
#   -r  einen Backslash nicht als Sonderzeichen behandeln
# Nach dieser Zeile erscheint nichts am Bildschirm: fügen Sie das Passwort ein und drücken Sie Enter.
read -rs HARBOR_PASS

# Ab hier wird das Passwort aus der Variablen eingesetzt, sodass nur der Variablenname
# in die Shell-History gelangt. Die doppelten Anführungszeichen sind zwingend: ohne sie würden Leerzeichen den Wert zerreißen.
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password="$HARBOR_PASS"

# unset löscht die Variable, damit das Passwort nicht an die nächsten Befehle in diesem Fenster gerät
unset HARBOR_PASS
```

<details>
<summary><b>Was in diesem Secret steckt und warum es einen eigenen Typ hat</b></summary>

Fragen wir den Cluster, welche Art von Secret dabei herausgekommen ist:

```bash
#   -o jsonpath='{.type}'  ein einzelnes Feld des Objekts ausgeben — den Typ des Secrets
#   {"\n"}                 einen Zeilenumbruch anhängen, sonst klebt die Ausgabe am Prompt
kubectl get secret harbor -o jsonpath='{.type}{"\n"}'
```

```
kubernetes.io/dockerconfigjson
```

Das Secret hat einen **Typ**, und der ist nicht dekorativ. Ein gewöhnliches Secret ist ein Satz von
Schlüssel-Wert-Paaren, und was damit zu tun ist, entscheidet die Anwendung. Ein Secret vom Typ
`kubernetes.io/dockerconfigjson` versteht `kubelet` selbst: Es weiß, dass darin eine Datei desselben
Formats wie `~/.docker/config.json` liegt, und kann sie beim Herunterladen von Images verwenden.

Um sich den Inhalt anzusehen (das Passwort liegt dort in base64 — das ist **keine Verschlüsselung**,
sondern eine Art, Binärdaten als Text zu schreiben, und jeder kann es dekodieren):

```bash
# .data.\.dockerconfigjson — der Schlüssel im Secret. Der Schlüsselname selbst beginnt mit einem Punkt,
# deshalb wird er maskiert: sonst hielte jsonpath ihn für einen Pfadtrenner.
# base64 -d dekodiert den Wert zurück in Text — Sie sehen dasselbe Format
# wie in der Datei ~/.docker/config.json auf Ihrem Bastion.
kubectl get secret harbor -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Daraus etwas Wichtiges: **Ein Secret in Kubernetes ist standardmäßig nicht verschlüsselt**, es ist
lediglich durch Zugriffsberechtigungen abgeschottet. Wer Secrets im Namespace lesen kann, sieht die
Passwörter. Wie man damit menschenwürdig umgeht, ist ein eigenes Lab über einen Secret-Speicher.

**Wie es in der Praxis gemacht wird.** Nicht mit dem `admin`-Account. Harbor hat Roboter: **Projects** →
`passes` → **Robot Accounts** → einen Roboter mit nur `pull`-Berechtigung erstellen. Die Zugangsdaten des
Roboters kommen in das `imagePullSecret`, und dann bedeutet ein aus dem Cluster durchgesickertes Secret,
dass jemand Ihre Images herunterladen kann — unangenehm, aber nicht fatal. Ein durchgesickerter `admin`
bedeutet, dass jemand sie austauschen kann.

Wir verwenden `admin`, um das Lab nicht in die Länge zu ziehen. Wissen Sie, dass dies eine Vereinfachung
ist.

</details>

Jetzt wenden Sie das richtige Manifest an. Zuerst dieselbe Adressersetzung wie zuvor, nur in einer
anderen Datei; dann die kaputte Anwendung entfernen und die funktionierende aufsetzen:

```bash
# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml

# delete -f = genau die in der Datei beschriebenen Objekte aus dem Cluster entfernen
kubectl delete -f passes-broken.yaml
kubectl apply -f passes.yaml

# rollout status wartet, bis die neuen Replicas bereit werden, und beendet sich dann von selbst.
# Kommt es nicht ans Ziel, gibt es einen Fehler zurück, weshalb eine solche Zeile in Skripten praktisch ist.
kubectl rollout status deployment/passes-api
```

**Was Sie sehen sollten:**

```
deployment "passes-api" successfully rolled out
```

Der Unterschied zwischen dem funktionierenden und dem kaputten Manifest sind genau zwei Zeilen:

```yaml
      imagePullSecrets:
        - name: harbor
```

## Schritt 8. Ansehen, was dabei herauskam

📍 **Wo:** auf dem Bastion, der `lab`-Cluster.

Die Anwendung ist nicht nach außen exponiert, aber Sie müssen sie ansehen. `port-forward` gräbt einen
Tunnel vom Bastion in den Cluster: Solange der Befehl läuft, geht eine Anfrage an `localhost:8080` zum
Dienst `passes-api`. Das nächste Analogon ist eine temporäre Portweiterleitung an einem NAT-Gateway, nur
ohne Eingriff ins Netzwerk.

```bash
# port-forward svc/passes-api = ein Tunnel zum Service, nicht zu einem bestimmten Pod
#   8080:80 — die linke Zahl ist der Port auf Ihrem Bastion, die rechte der Service-Port im Cluster
# Schließen Sie das Fenster nicht: der Tunnel lebt, solange der Befehl läuft.
kubectl port-forward svc/passes-api 8080:80
```

In einem anderen Terminalfenster:

```bash
# curl — „gehe zur Adresse und zeige die Antwort".
#   -s     den Fortschrittsindikator nicht anzeigen
#   ; echo einen Zeilenumbruch anhängen: die Antwort kommt als eine einzige Zeile, und ohne ihn
#          klebt sie am Shell-Prompt
curl -s http://localhost:8080/; echo
```

**Was Sie sehen sollten** — ein JSON, in dem die Anwendung berichtet, welche Replica geantwortet hat, auf
welchem Node sie läuft und aus welcher Registry sie kam:

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

Das Feld `pod` in der Antwort ist der Name der Replica, die geantwortet hat. Vergleichen Sie ihn mit der
Liste der Replicas:

```bash
# ein neues Terminalfenster weiß nichts von der Variablen KUBECONFIG — setzen Sie sie auch hier,
# sonst geht kubectl an den falschen Cluster
export KUBECONFIG=~/lab.kubeconfig

# dieselbe Auswahl per Label: die Liste sollte den Namen enthalten, den Sie in der Antwort gesehen haben
kubectl get pods -l app=passes-api
```

Wiederholen Sie die Anfrage mehrmals — der Name bleibt **derselbe**, und das ist keine Störung.
`port-forward` wählt im Moment des Starts eine einzige Replica und hält den Tunnel zu genau dieser bis
`Ctrl+C`; auf diesem Weg gibt es überhaupt keine Lastverteilung. Beim `Service` gibt es sie, aber sehen
können Sie sie nur von innerhalb des Clusters — von außen sprechen Sie mit einem bestimmten Pod.

Die Lastverteilung können Sie wirklich so prüfen — acht Anfragen aus einem temporären Pod, der innerhalb
des Clusters lebt:

```bash
# run bringt einen einmaligen Pod hoch, --rm räumt ihn danach weg.
# Alles nach -- läuft innerhalb des Pods: achtmal rufen wir den Service über seinen internen Namen auf
# und drucken die Zeile mit dem Namen der antwortenden Replica.
kubectl run probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
  -- sh -c 'for i in $(seq 1 8); do curl -s http://passes-api/ | grep -o "passes-api-[a-z0-9-]*"; done'
```

**Was Sie sehen sollten:** zwei verschiedene Namen durcheinander — das ist der `Service`, der die Anfragen
auf die Replicas verteilt.

Den Tunnel schließen — `Ctrl+C` im ersten Fenster.

Schließen Sie den Kreis: Gehen Sie in Harbor im Browser, in das Projekt `passes`. Beim Repository
`passes/passes-api` ist der Download-Zähler (**Pulls**) von null verschieden geworden. Ihr Cluster ist
tatsächlich genau hierher gegangen.

## Überprüfung

📍 **Wo:** auf dem Bastion, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

Das Skript geht zu beiden Clustern zugleich und entnimmt sie den Umgebungsvariablen. Die ersten beiden
sind zwingend, die dritte ist der Pfad zum Tenant-Kubeconfig.

```bash
cd labs/06-harbor

# in welchem Cluster die Anwendung zu prüfen ist — in Ihrem `lab`
export KUBECONFIG=~/lab.kubeconfig
# Ihre Tenant-Nummer: daraus setzt das Skript den Namespace-Namen tenant-workshop03 zusammen
export COZY_TENANT=workshop03
# wo der Zugang zum Management-Cluster liegt — dort schaut das Skript auf Harbor selbst.
# Sie können es ungesetzt lassen: dann sucht das Skript ~/.kube/config, und findet es das nicht — überspringt
# es die Prüfungen am Management-Cluster und sagt es.
export COZY_KUBECONFIG=~/.kube/config

./check.sh
```

⚠️ **Unter Windows wird das Skript aus WSL** ausgeführt, nicht aus PowerShell — wie man es installiert,
steht am Anfang von Lab 0. Ohne WSL können Sie das Lab durchführen, aber es gibt keinen Artefakt-Bericht.

Das Skript prüft nicht die Tatsache, dass Harbor erstellt wurde, sondern die Arbeit im Kern: Die Registry
antwortet über ihre API, die Anwendung im Cluster wurde aus einem Image gestartet, das in Ihrer
ureigenen Registry liegt, das Secret mit den Zugangsdaten existiert und verweist auf dieselbe Adresse,
und der Service selbst gibt ein JSON mit dem Namen eines Pods zurück, der tatsächlich existiert.

## Aufräumen

Die Anwendung und Harbor werden im nächsten Lab gebraucht — löschen Sie sie jetzt nicht.

Wenn Sie mit allen Labs fertig sind:

```bash
# die in der Datei beschriebenen Objekte löschen: sowohl das Deployment als auch den Service
kubectl delete -f passes.yaml
# das Secret wurde per Befehl erstellt, nicht per Datei — löschen Sie es per Namen
kubectl delete secret harbor
```

Harbor selbst wird über das Dashboard gelöscht, wie jede gewöhnliche Anwendung. Mit ihm geht auch der
Layer-Speicher — das sind ein Dutzend Sekunden, kein Antrag auf Abschreibung einer VM.

Es lohnt sich zu verstehen, was genau Sie löschen. Eine Registry ist nicht nur der Ort, an dem die Images
liegen, sondern auch die einzige Antwort auf die Frage „was haben wir im vergangenen Jahr überhaupt in
die Produktion ausgeliefert". Sie in einer Arbeitsumgebung so leicht zu löschen wie hier, werden Sie
nicht wollen.

## Was wir jetzt können

- Uns eine Image-Registry einrichten und erklären, wie sie sich von einer Content Library unterscheidet
- Ein Image mit einem zweistufigen Build bauen und verstehen, warum das Ergebnis dreißigmal kleiner ausfällt
- Einen `docker login` auf dem Bastion von dem Zugang unterscheiden, den der Cluster braucht
- `ImagePullBackOff` lesen und die wahre Ursache in `describe pod` finden
- Einem Pod über die Downward API Informationen über sich selbst geben, ohne ihm Berechtigungen auf die Cluster-API zu erteilen

## In vSphere wäre das

Das nächste Analogon einer Registry ist eine Content Library. Eine Ähnlichkeit gibt es: Beide speichern
Images und geben sie an Maschinen heraus, und beide beherrschen Berechtigungen und Synchronisation
zwischen Standorten.

Darüber hinaus gehen sie auseinander, und der Unterschied liegt nicht im Detail.

**Eine Content Library kopiert das ganze Template.** Eine Registry gibt Layer heraus und speichert
identische Layer einmal. Wenn Sie zwanzig Dienste auf derselben Alpine-Basis haben, liegt die Basis in
der Registry in einem einzigen Exemplar, und beim Start des einundzwanzigsten Dienstes lädt der Node nur
seinen eigenen Layer herunter — eine Handvoll Megabyte.

**Ein Template wird benannt, ein Image wird adressiert.** Ein Image hat einen Digest — einen Hash seines
Inhalts. Anhand dessen können Sie überprüfen, dass Sie genau den Code ausführen, den Sie gebaut haben,
und keinen anderen. Ein Template hat so etwas nicht: Sie verlassen sich darauf, dass niemand es
ausgetauscht hat.

**Eine Registry ist ein HTTP-Dienst.** Daraus folgt der ganze Sinn der Übung: Ein Build in der Pipeline
legt mit einem Befehl ein Image dorthin, der Cluster holt es mit einem anderen, und niemand mountet
Storage oder kopiert Dateien von Hand zwischen Standorten.

**Wo vSphere bequemer ist, ehrlich gesagt.** Drei Dinge.

Eine Content Library verlangt nicht, irgendetwas über Zugangsdaten zu verstehen. Anschließen — sie
funktioniert. Hier mussten Sie dem Cluster gesondert erklären, wie er zur Registry gelangt, und Sie sind
daran gestolpert, wie alle stolpern.

Die Berechtigungen in vCenter sind einheitlich. Ein Account für alles: Maschinen, die Library und das
Netzwerk. Hier sind die Berechtigungen im Dashboard, die Berechtigungen im Cluster und die Berechtigungen
in Harbor drei verschiedene Sätze, die synchron gehalten werden müssen. Das ist der Preis dafür, dass die
Registry ein eigenständiges Produkt ist und nicht Teil der Plattform.

Ein Template lässt sich bearbeiten. Sie deployen eine Maschine aus einem Template, konfigurieren sie
weiter, nehmen ein neues Template ab — und dass die genaue Abfolge der Schritte nirgends festgehalten ist,
stört überhaupt nicht. Images werden nicht so gebaut: Wenn der Build sich nicht aus dem `Dockerfile`
reproduzieren lässt, sind Sie in Schwierigkeiten. Die Disziplin ist nützlich, aber sich an sie zu
gewöhnen ist schwer, und so zu tun, als sei es anders, ist töricht.
