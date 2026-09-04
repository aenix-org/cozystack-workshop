# Lab 6 · Ihre eigene private Image-Registry

| | |
|---|---|
| **Zeit** | 45 Minuten, davon 10 Minuten Wartezeit |
| **Was es beweist** | Eine Image-Registry steht in zehn Minuten, und der Cluster kann nur aus ihr ziehen |
| **Was Sie brauchen** | Der Cluster aus Lab 0, `kubectl`, `docker` (oder `podman`) auf dem Laptop, Zugang zum Dashboard |

## Warum das wichtig ist

Der Dienst „Passes“ hat es bis zur Informationssicherheit geschafft, und von dort kam eine E-Mail zurück.

> Container-Images werden aus öffentlichen Registries im Internet gezogen. Das ist inakzeptabel:
> niemand hat geprüft, was in einem Image steckt, sein Inhalt kann sich unter demselben Namen ändern,
> und wenn die externe Ressource nicht verfügbar ist, startet ein Produktivdienst nicht. Alle Images
> müssen in der internen Registry der Organisation gespeichert werden.

Dagegen lässt sich nichts einwenden — jeder Punkt ist berechtigt. Ein öffentliches Image mit dem Tag `latest`
kann heute das eine und morgen etwas anderes sein. Der Autor des Images kann es löschen. Eine externe Registry
kann Ihnen die Download-Geschwindigkeit im ungünstigsten Moment drosseln — und das ist keine Hypothese, alle
großen öffentlichen Registries tun das.

Sie brauchen also eine eigene Registry. Normalerweise ist das ein Projekt für sich: ein Antrag auf eine VM,
Installation, Zertifikate, Speicher, Backups, jemandes Quartal. Heute ist es ein Posten im Katalog.

Und da die Registry Ihnen gehört und geschlossen ist, muss dem Cluster Zugang zu ihr gewährt werden. Daran
stolpern alle, und wir stolpern auch — mit Absicht.

## Kleines Glossar

| Begriff | Was es ist | Ähnlich wie… aber |
|---|---|---|
| **Image** | Ein Abbild einer Anwendung mit allem, was zum Ausführen nötig ist | **Eine VM-Vorlage**, aber unveränderlich: Sie können nicht hineingehen und etwas reparieren, Sie bauen ein neues |
| **Layer** | Ein Teil eines Images. Ein Image besteht aus Layern, und Layer werden wiederverwendet | identische Layer verschiedener Images werden in der Registry nur einmal gespeichert |
| **Tag** | Ein Versionsetikett für ein Image: `passes-api:v1` | **Ein Versionsname einer Vorlage**, aber ein Tag kann einem anderen Image neu zugewiesen werden, und das ist die Hauptquelle für Ärger |
| **Registry** | Ein Image-Speicher, der über HTTP bereitgestellt wird | **Eine Content Library**, aber sie gibt bei jedem Start Layer über das Netzwerk aus, statt die ganze Vorlage zu kopieren |
| **Harbor** | Eine Registry mit Oberfläche, Projekten, Berechtigungen und einem Schwachstellen-Scanner | **Content Library + Berechtigungen + Berichte**, aber sie kann Image-Inhalte prüfen und signieren |
| **Ein Projekt in Harbor** | Ein Bereich innerhalb der Registry mit eigenen Berechtigungen | **Ein Ordner in einer Content Library**, aber es kann öffentlich oder privat sein, und davon hängt ab, ob Zugangsdaten nötig sind |
| **`imagePullSecret`** | Ein Secret mit Login und Passwort für die Registry, das der Node liest | **Das Konto zum Anbinden einer Content Library**, aber es wird vom **Node** gebraucht, nicht von Ihnen; Ihr `docker login` nützt dem Cluster nichts |
| **Dockerfile** | Die Anleitung zum Bauen eines Images | **Die Anleitung zum Vorbereiten einer Vorlage**, aber sie läuft bei jedem Build vollständig und von Grund auf neu |
| **Downward API** | Eine Möglichkeit, einem Pod über Umgebungsvariablen Informationen über sich selbst zu geben | **Gastvariablen aus VMware Tools**, aber die Werte werden vom Cluster beim Start eingespeist; die Anwendung fragt sie nicht ab |

## Zwei kubeconfigs: nicht verwechseln

Ab hier geht es im Lab um zwei verschiedene Cluster, und es lohnt sich, sie vor dem ersten Befehl
auseinanderzuhalten.

| Kubeconfig | Was es ist | Was wir damit tun |
|---|---|---|
| `~/.kube/workshop` | Der Cozystack-Management-Cluster, Ihr Tenant | Managed-Services ansehen: Harbor, Datenbanken, Queues |
| `~/lab.kubeconfig` | **Ihr** `lab`-Cluster aus Lab 0 | die Anwendung ausrollen |

Beide erhalten Sie im Dashboard. Der Tenant-kubeconfig liegt im Secret `kubeconfig-tenant-workshopXX`
(Tab Secrets), der Cluster-kubeconfig im Zugangsbereich Ihres `lab`-Clusters.

⚠️ **Die häufigste Ursache für „bei mir funktioniert nichts“ in diesem Lab ist ein Befehl, der an den
falschen Cluster ging.** Vor jedem Befehlsblock steht, für welchen Cluster er gedacht ist. Wenn Sie unsicher sind:

```bash
# echo gibt den Wert der Variablen aus: welche Zugangsdatei kubectl gerade verwendet.
# Leer bedeutet, kubectl nimmt die Standarddatei ~/.kube/config, nicht die, die Sie meinen.
echo $KUBECONFIG

# get nodes = "zeige die Nodes des Clusters". Hier ist es ein Lackmustest:
# an der Antwort erkennen Sie, an welchen der beiden Cluster der Befehl ging.
kubectl get nodes
```

Der `lab`-Cluster hat einen einzigen Node mit einem Namen wie `kubernetes-lab-md0-...`. Im Management-Cluster
gibt dieser Befehl höchstwahrscheinlich eine Ablehnung zurück — ein Tenant hat keine Berechtigung, Nodes
anzusehen.

## Was im Lab-Ordner liegt

Alle Dateien gehören bereits Ihnen — Sie haben sie zusammen mit dem Repository erhalten. Es gibt nichts neu zu
erstellen oder abzutippen: Wo unten `kubectl apply -f name.yaml` steht, wird die Datei von hier genommen.

```bash
# jeder Befehl in diesem Lab wird aus dem Lab-Ordner ausgeführt — wechseln Sie hinein
cd labs/06-harbor
```

| Datei | Was es ist | Wann es nützlich ist |
|---|---|---|
| `app/` | Die Quellen des Dienstes „Passes“ in Go und ein `Dockerfile` — daraus bauen Sie das Image | Sie bauen lokal, `docker build` |
| `passes-broken.yaml` | Eine **absichtlich unvollständige** Datei: ohne Zugangsdaten für die Registry | Sie wenden sie an, um die Ablehnung mit eigenen Augen zu sehen |
| `passes.yaml` | Dieselbe Datei, aber mit Registry-Zugang | Sie wenden sie an, nachdem Sie es verstanden haben |
| `check.sh` | Eine Prüfung, dass das Image aus Ihrem Harbor kam und nicht aus dem Internet | Sie führen sie am Ende des Labs aus |

## Schritt 1. Harbor erstellen

📍 **Wo:** im Browser, im Cozystack-Dashboard. Die Registry ist eine gemeinsame Tenant-Ressource, kein Teil
Ihres Lab-Clusters, deshalb wird sie an derselben Stelle erstellt wie der Cluster selbst.

Tenant → **Create application** → `Harbor`.

| Feld | Wert | Warum |
|---|---|---|
| Name | `harbor` | wird Teil der Registry-Adresse; was herauskommt, sehen Sie nach dem Erstellen |
| Host | leer lassen | dann wird die Adresse selbst aus dem Namen und der Tenant-Domain zusammengesetzt |
| Storage class | `replicated` | die Daten werden in drei Kopien auf verschiedenen Nodes gehalten |
| Trivy → enabled | **ausschalten** | der Schwachstellen-Scanner lädt eine mehrere Gigabyte große Datenbank herunter; auf einer Schulungs-Testumgebung sind das zusätzliche zwanzig Minuten Wartezeit |
| Database → replicas | `1` | die Ausfallsicherheit der Registry-Datenbank testen wir heute nicht |
| Database → size | `5Gi` | |
| Redis → replicas | `1` | |
| Redis → size | `1Gi` | |
| Core / Registry preset | wie vorgeschlagen lassen | |

⚠️ **Das Redis in diesem Formular ist Harbors eigener interner Cache; es hat nichts mit dem nächsten Lab zu
tun.** Im Lab über Caching richten Sie ein eigenes Redis für Ihre eigene Anwendung ein. Der Name ist gleich,
die Rollen sind verschieden.

Klicken Sie auf Erstellen und warten Sie. Harbor kommt in fünf bis zehn Minuten hoch: Es ist keine einzelne
Anwendung, sondern mehrere Dienste plus eine Datenbank plus Objektspeicher für die Image-Layer selbst.

⚠️ **Wenn Harbor länger als fünfzehn Minuten im Zustand „not ready“ verharrt** — sehen Sie nach, was passiert:
`kubectl -n tenant-workshopXX get pods | grep harbor`. Meist ist es die Installationswarteschlange, die für die
ganze Plattform gemeinsam ist: Ihre Anwendung steht darin hinter denen anderer und wartet.

Harbor speichert Image-Layer in S3-kompatiblem Speicher, und der Bucket dafür wird von selbst erstellt — Sie
müssen dafür keinen eigenen Speicher im Tenant aktivieren, der übergeordnete genügt. Wenn die Pods auch nach
mehr als einer halben Stunde nicht erscheinen, schreiben Sie in den Workshop-Chat mit der Ausgabe dieses Befehls.

## Schritt 2. Zugangsdaten holen und sich an der Registry anmelden

📍 **Wo:** im Dashboard, dann in einem Terminal auf dem Laptop.

Öffnen Sie die von Ihnen erstellte Anwendung `harbor` und suchen Sie den Tab mit den Secrets. Dort finden Sie
ein Secret mit den Zugangsdaten der Registry und darin drei Schlüssel, die Sie brauchen:

| Schlüssel | Was darin steht |
|---|---|
| `url` | die Adresse Ihrer Registry, in der Form `https://harbor-....<Testumgebungs-Domain>` |
| `admin-password` | das Passwort des Administrators |
| `redis-password` | Harbors internes Passwort, das Sie nicht brauchen |

Der Login ist `admin`.

⚠️ **Raten Sie die Adresse der Registry nicht, nehmen Sie sie aus dem Schlüssel `url`.** Die Plattform stellt
dem Anwendungsnamen den Diensttyp voran, deshalb kann die Adresse anders ausfallen, als Sie nach dem Namen
erwartet haben. Dieselbe Adresse ist in der Liste der Ingresses der Anwendung sichtbar.

Dasselbe Passwort ist auch per Befehl verfügbar. Einem Tenant ist es nicht erlaubt, **alle** Secrets durchweg zu
lesen — überzeugen Sie sich selbst, `kubectl auth can-i get secrets` antwortet `no`. Aber für jede Anwendung,
die Sie erstellen, richtet die Plattform eine separate Regel ein, die genau ihre Zugangsdaten erlaubt:

```bash
# get secret = "zeige das Secret-Objekt". Der Name des Secrets setzt sich aus dem Präfix
# für den Anwendungstyp und ihrem Namen zusammen: harbor- + harbor.
#   -n tenant-workshopXX  in welchem namespace suchen — in Ihrem Tenant
#   -o jsonpath='...'     ein einzelnes Feld aus dem Objekt herausziehen, statt es ganz auszugeben
#   base64 -d             dekodieren: Werte in Secrets liegen in base64 vor
#   ; echo                einen Zeilenumbruch anhängen, sonst klebt das Passwort am Prompt
kubectl -n tenant-workshopXX get secret harbor-harbor-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Das Dashboard ist praktischer, weil Sie sich nicht mit base64 herumschlagen müssen. Der Befehl ist praktischer,
weil Sie ihn in ein Skript einbauen können.

Öffnen Sie die Adresse im Browser und melden Sie sich an. Sie sehen die Harbor-Oberfläche mit einem einzigen
Projekt, `library`.

Jetzt dasselbe vom Terminal aus. `docker login` fragt nach Benutzername und Passwort und speichert die
Zugangsdaten auf Ihrem Laptop, in der Datei `~/.docker/config.json`. Danach gehen `docker push` und
`docker pull` zu dieser Registry, ohne etwas zu fragen.

```bash
# login = "merke dir die Zugangsdaten für diese Registry".
# Das Argument ist die Registry-Adresse aus dem Schlüssel url; harbor-harbor.workshop03.example.org ist hier ein Beispiel.
# Der Befehl fragt nach einem Benutzernamen (admin) und einem Passwort; das Passwort wird bei der Eingabe nicht angezeigt.
docker login harbor-harbor.workshop03.example.org
```

Ab hier im Text ist `harbor-harbor.workshop03.example.org` **Ihre** Adresse — setzen Sie Ihre eigene ein.

**Was Sie sehen sollten:**

```
Login Succeeded
```

⚠️ **Dieser `docker login` hat Ihrem Laptop beigebracht, sich an der Registry anzumelden — und nur ihm.** Für
den Cluster hat er nichts getan. Merken Sie sich das; Sie brauchen es etwas später im Lab.

## Schritt 3. Ein privates Projekt einrichten

📍 **Wo:** im Browser, in Harbor.

**Projects** → **New Project**.

| Feld | Wert | Warum |
|---|---|---|
| Project Name | `passes` | ein Projekt pro Dienst — so lassen sich Berechtigungen leichter vergeben |
| Access Level | **Public nicht anhaken** | die Sicherheit hat eine geschlossene Registry verlangt, nicht „Ihre, aber offen für das ganze Internet“ |
| Storage quota | `-1` (kein Limit) | auf der Testumgebung wäre eine Quota nur hinderlich |

Das Projekt `library`, das von Anfang an da war, ist öffentlich. Aus ihm werden Images ganz ohne Zugangsdaten
gezogen. Genau deshalb verwenden wir es nicht: Es erzeugt nicht den Zugriffsfehler, um den herum das Lab gebaut
ist.

## Schritt 4. Das Image bauen

📍 **Wo:** auf dem Laptop.

Im Ordner dieses Labs liegt `app/` — die Quelle des Dienstes „Passes“ und die Bauanleitung. Bevor wir bauen,
gehen wir durch, was darin steckt.

<details>
<summary><b>Genauer betrachtet: was in der Anwendung steckt</b></summary>

Die Datei `app/main.go`, etwa siebzig Zeilen Go. Sie tut genau zwei Dinge.

**Sie antwortet auf `/healthz` mit dem Wort `ok`.** Das ist die Adresse für die Bereitschaftsprüfung: Der Cluster
klopft hier an und schickt keinen Traffic an eine Replik, bis er eine Antwort bekommt.

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

Woher kennt die Anwendung ihren eigenen Namen, Node und namespace? Sie **findet sie nicht heraus**. Der Cluster
legt sie beim Start hinein, in Umgebungsvariablen:

```go
Pod:  env("POD_NAME", "неизвестно"),
Node: env("NODE_NAME", "неизвестно"),
```

Und das Manifest gibt an, was dort hineinzulegen ist:

```yaml
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
```

Das nennt man die Downward API — „von oben herabgereichte Informationen“. Das nächste Analogon in vSphere sind
die Gastvariablen, die VMware Tools in die Maschine hineinreicht. Der Unterschied ist, dass die Anwendung hier
nichts fragt und nirgendwohin geht: Die Werte liegen bereits in der Umgebung, wenn der Prozess startet. Kein
Client zur Cluster-API, keine Berechtigungen auf dieser API nötig.

**Es gibt keine einzige externe Bibliothek in der Anwendung, nur die Standardbibliothek von Go.** Das ist keine
Koketterie: Ein Build mit Abhängigkeiten würde ins Internet gehen, um Pakete zu holen, und das ganze Lab begann
damit, dass die Sicherheit Ausflüge ins Internet verboten hat.

Die Datei `app/Dockerfile` ist die Bauanleitung. Sie hat zwei Stufen:

```dockerfile
FROM golang:1.23-alpine AS build
...
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

FROM alpine:3.21
COPY --from=build /out/passes-api /usr/local/bin/passes-api
```

Die erste Stufe ist die Bau-Stufe. Sie braucht den ganzen Go-Compiler, ungefähr 350 MB. Die zweite Stufe ist
das, was tatsächlich in den Cluster geht: Aus der ersten Stufe wird **nur das fertige Binary** übernommen, alles
andere wird weggeworfen.

Das Ergebnis ist ein Image von etwa zehn Megabyte statt dreihundertfünfzig. Es geht nicht nur um die Größe:
Darin gibt es keinen Compiler, keine Quellen, keinen Paketmanager. Wer es doch in den Container geschafft hat,
hat nichts, womit er arbeiten könnte.

Vergleichen Sie das damit, wie es bei Vorlagen für virtuelle Maschinen funktioniert. Eine Vorlage trägt das
gesamte Betriebssystem in sich, zusammen mit dem Compiler, falls er jemals dort gelandet ist. Sie nachträglich
zu verkleinern, ist nahezu unmöglich.

Die letzten Zeilen:

```dockerfile
RUN adduser -D -u 10001 app
USER 10001
```

Die Anwendung läuft nicht als root. In einem richtig konfigurierten Cluster wird ein Pod nicht als root laufen
dürfen, und das ist keine Pingeligkeit von uns, sondern eine Anforderung, auf die Sie in jedem modernen Cluster
stoßen werden.

</details>

Der Befehl `docker build` baut das Image: Er liest das `Dockerfile`, führt die dort beschriebenen Schritte aus
und legt das Ergebnis in den Image-Speicher auf Ihrem Laptop. Der Name, unter dem das Ergebnis dort abgelegt
wird, wird mit dem Flag `-t` festgelegt und besteht aus drei Teilen:

| Teil | Was er bedeutet |
|---|---|
| `harbor-harbor.workshop03.example.org` | die Registry-Adresse — wohin man für das Image geht |
| `passes/passes-api` | das Projekt und der Name innerhalb der Registry |
| `v1` | der Versions-Tag |

Die Registry-Adresse ist Teil des Image-Namens. Genau deshalb ändert der Umzug auf Ihre eigene Registry jedes
Manifest: Der Image-Name wird ein anderer.

Bauen wir. Ersetzen Sie die Adresse durch Ihre eigene:

```bash
cd labs/06-harbor

# build = "baue das Image nach dem Dockerfile".
#   --platform linux/amd64  für welchen Prozessor bauen; die Cluster-Nodes laufen auf x86,
#                           und der Laptop kann auf ARM laufen — dann kommt ohne das Flag das Falsche heraus
#   -t <Adresse>/<Projekt>/<Name>:<Tag>  wie das Ergebnis heißen soll. Die Registry-Adresse am Anfang des Namens
#                           ist der Ort, wohin docker push es später schickt
#   app/                    das letzte Argument — der Ordner mit dem Dockerfile und den Quellen;
#                           sein gesamter Inhalt wird dem Builder übergeben
docker build --platform linux/amd64 -t harbor-harbor.workshop03.example.org/passes/passes-api:v1 app/
```

⚠️ **`--platform linux/amd64` ist keine Zierde.** Wenn Sie einen Mac auf Apple Silicon (M1–M4) oder einen
ARM-Laptop haben, bauen Sie ohne dieses Flag ein ARM-Image. Es baut ohne Fehler, pusht ohne Fehler, und im
Cluster — die Nodes dort laufen auf gewöhnlichem x86 — landet der Pod in `CrashLoopBackOff`, und in den Logs
steht `exec format error`. Das ist lange zu diagnostizieren, weil nichts drumherum darauf hinweist, dass es an
der Prozessorarchitektur liegt.

**Was Sie sehen sollten** — Zeilen über die Bauschritte und am Ende:

```
Successfully tagged harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

## Schritt 5. Das Image an Ihre Registry senden

📍 **Wo:** auf dem Laptop.

Das gebaute Image liegt bisher nur auf Ihrer Festplatte. `docker push` sendet es Layer für Layer an die
Registry; Layer, die bereits in der Registry sind, werden nicht erneut gesendet.

```bash
# push = "sende das Image an die Registry". Wohin es zu senden ist, nimmt docker aus dem Image-Namen:
# der erste Teil des Namens ist die Registry-Adresse, dorthin geht es, mit den Zugangsdaten von docker login.
docker push harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

**Was Sie sehen sollten** — wie die Layer hinausgehen, und am Ende eine Zeile mit einem langen Hash, dem
`digest`.

Schauen Sie in Harbor im Browser nach: **Projects** → `passes` → dort ist ein Repository `passes/passes-api`
erschienen und darin der Tag `v1`. Sie sehen die Größe, das Datum und denselben `digest`.

Dieser `digest` ist der genaue Inhalt des Images. Der Tag `v1` kann morgen einem anderen Image neu zugewiesen
werden, und niemand merkt es; der `digest` lässt sich nicht fälschen. Daher die Regel, die früher oder später
jeder lernt: **in die Produktion rollt man per digest aus, nicht per Tag.**

## Schritt 6. In den Cluster ausrollen

📍 **Wo:** auf dem Laptop, der `lab`-Cluster.

```bash
# KUBECONFIG sagt kubectl, welche Zugangsdatei zu verwenden ist. Wir wechseln zu Ihrem `lab`-Cluster:
# ab hier gehen alle kubectl-Befehle an ihn.
# Es gilt, bis das Terminalfenster geschlossen wird.
export KUBECONFIG=~/lab.kubeconfig
```

Im Lab-Ordner liegt `passes-broken.yaml`. Statt der Registry-Adresse steht darin ein Platzhalter,
`HARBOR-HOST` — er muss durch Ihre Adresse ersetzt werden. Das erledigt `sed`: Es bearbeitet die Datei an Ort
und Stelle, ohne etwas zu fragen oder anzuzeigen. Nehmen Sie die Zeile für Ihr System:

```bash
# sed -i = "bearbeite die Datei an Ort und Stelle"
#   's|was|wodurch|g'  alle Vorkommen ersetzen; der Trenner | wird statt / verwendet, weil
#                     die Adresse Schrägstriche enthält und man sie sonst maskieren müsste
#   Das sed in macOS verlangt nach -i ein zwingendes Argument; die leeren Anführungszeichen
#   bedeuten "keine Sicherungskopie anlegen". Unter Linux darf es ein solches Argument nicht geben.

# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
```

Wenden Sie sie an:

```bash
# apply = "bringe den Cluster in den in der Datei beschriebenen Zustand"
kubectl apply -f passes-broken.yaml

# get pods = "zeige die Pods".
#   -l app=passes-api  nur die mit diesem Label, nicht alle
#   -w                 nicht beenden, sondern Änderungen ausgeben, sobald sie auftreten;
#                      Beobachtung abbrechen — Ctrl+C
kubectl get pods -l app=passes-api -w
```

**Was Sie sehen** — und es ist nicht das, was Sie erwartet haben:

```
NAME                          READY   STATUS             RESTARTS   AGE
passes-api-6c9d4f7b8-2xk4n    0/1     ErrImagePull       0          8s
passes-api-6c9d4f7b8-2xk4n    0/1     ImagePullBackOff   0          22s
```

Brechen Sie die Beobachtung mit `Ctrl+C` ab und sehen Sie, was der Cluster sagt:

```bash
# describe = "erzähle mir ausführlich über das Objekt". Ganz am Ende der Ausgabe kommt das Ereignisprotokoll:
# was der Cluster mit dem Pod versucht hat und wie es endete.
# tail -12 behält die letzten zwölf Zeilen — die Ereignisse sind genau dort.
kubectl describe pod -l app=passes-api | tail -12
```

```
  Warning  Failed   kubelet  Failed to pull image
    "harbor-harbor.workshop03.example.org/passes/passes-api:v1":
    failed to resolve reference: unexpected status from HEAD request: 401 Unauthorized
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Sie haben sich gerade erfolgreich mit `docker login` an der Registry angemeldet und das Image erfolgreich
> dorthin gesendet. Die Registry kennt Sie. Warum wird der Cluster abgewiesen?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

**Nicht Sie laden das Image herunter.** `kubelet` lädt es herunter — ein Dienst auf dem Cluster-Node. Das ist
eine andere Maschine, ein anderer Prozess und ein anderer Benutzer.

Ihr `docker login` hat die Zugangsdaten in die Datei `~/.docker/config.json` auf **Ihrem Laptop** geschrieben.
Der Cluster-Node weiß von dieser Datei nichts und kann es auch nicht: Zwischen ihm und Ihrem Laptop gibt es
überhaupt nichts Gemeinsames, außer dass Sie Befehle dorthin senden.

Gehen Sie zurück zur Warnung nach `docker login` etwas früher im Lab. Genau das stand dort, aber die Folgen
waren noch nicht sichtbar.

**Wie man es richtig macht.** Die Zugangsdaten müssen in den Cluster selbst gelegt werden — in ein
Secret-Objekt besonderer Art —, und dann muss das Manifest der Anwendung angeben, welches Secret beim
Herunterladen zu verwenden ist. Ein solches Secret nennt man `imagePullSecret`.

**Warum der Cluster eigene Zugangsdaten braucht und nicht Ihre.** Drei Gründe, und alle drei sind praktisch.

Erstens: Sie sind vielleicht nicht da. Ein Node startet um drei Uhr nachts neu und geht das Image erneut
herunterladen. Ginge er unter Ihrem Konto, hinge alles daran, dass Sie noch in dieser Firma arbeiten und Ihr
Passwort nicht abgelaufen ist.

Zweitens: Die Berechtigungen sind verschieden. Sie brauchen die Berechtigung, in die Registry zu **schreiben**,
um Builds dorthin zu senden. Der Cluster muss nur **lesen**. Dem Cluster die Berechtigung zu geben, Images aus
der Registry zu löschen, ist eine schlechte Idee, und mit Ihrem Konto hätten Sie ihm genau die gegeben.

Drittens: Die Spuren sind verschieden. Wenn im Protokoll der Registry zu sehen ist, dass das Image von
`robot$passes-puller` heruntergeladen wurde und nicht von `admin`, wird eine Untersuchung des Vorfalls möglich.

**Warum nicht den Node direkt konfigurieren.** Sie können die Zugangsdaten direkt auf den Node legen, in die
Konfiguration der Container-Runtime — dann ist kein `imagePullSecret` nötig. Manche tun das manchmal. Aber Nodes
in einem Cluster sind Wegwerfware: Sie werden beim Upgrade neu erstellt, bei wachsender Last hinzugefügt, bei
Ausfall getötet. Eine von Hand auf einem Node vorgenommene Einstellung lebt bis zur ersten Ersetzung des Nodes.
Ein Secret im Cluster überlebt jede Ersetzung.

**Die Lehre reicht über diesen Fehler hinaus.** `ImagePullBackOff` ist fast immer eines von drei Dingen: ein
Tippfehler im Image-Namen, keine Zugangsdaten, oder das Image existiert, aber nicht für die richtige
Prozessorarchitektur. Schauen Sie nicht auf den Status des Pods, sondern auf `kubectl describe pod` — dort steht
die wahre Ursache.

</details>

## Schritt 7. Dem Cluster Zugang zur Registry gewähren

📍 **Wo:** auf dem Laptop, der `lab`-Cluster.

Wir erstellen ein Secret mit den Zugangsdaten der Registry. Eine separate Variante des Befehls `create secret`
erzeugt ein Secret der Art, die `kubelet` beim Herunterladen von Images selbst lesen kann:

```bash
# create secret docker-registry = "erstelle ein Secret mit Registry-Zugangsdaten"
#   harbor             der Name des Secrets im Cluster; das Anwendungsmanifest verweist darauf
#   --docker-server    für welche Registry diese Zugangsdaten sind — dieselbe Adresse wie im Image-Namen
#   --docker-username  wer sich anmeldet
#   --docker-password  das Passwort; einfache Anführungszeichen sind nötig, wenn es ein $, ! oder Leerzeichen enthält
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password='IHR-PASSWORT'
```

⚠️ **Ein Passwort auf der Kommandozeile bleibt in der Shell-History.** Auf der Testumgebung spielt das keine
Rolle, in einer Arbeitsumgebung schon. Ein Weg ohne die History:

```bash
# read legt das mit der Tastatur Eingetippte in die Variable HARBOR_PASS:
#   -s  das Eingetippte nicht auf dem Bildschirm anzeigen
#   -r  einen Backslash nicht als Sonderzeichen behandeln
# Nach dieser Zeile erscheint nichts auf dem Bildschirm: Fügen Sie das Passwort ein und drücken Sie Enter.
read -rs HARBOR_PASS

# Ab hier wird das Passwort aus der Variablen eingesetzt, sodass nur der Variablenname
# in die Shell-History gelangt. Die doppelten Anführungszeichen sind zwingend: ohne sie würden Leerzeichen den Wert zerreißen.
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password="$HARBOR_PASS"

# unset löscht die Variable, damit das Passwort nicht an die nächsten Befehle in diesem Fenster gelangt
unset HARBOR_PASS
```

<details>
<summary><b>Was in diesem Secret steckt und warum es einen eigenen Typ hat</b></summary>

Fragen wir den Cluster, welche Art Secret herausgekommen ist:

```bash
#   -o jsonpath='{.type}'  ein einzelnes Feld des Objekts ausgeben — den Typ des Secrets
#   {"\n"}                 einen Zeilenumbruch anhängen, sonst klebt die Ausgabe am Prompt
kubectl get secret harbor -o jsonpath='{.type}{"\n"}'
```

```
kubernetes.io/dockerconfigjson
```

Das Secret hat einen **Typ**, und der ist nicht dekorativ. Ein gewöhnliches Secret ist eine Menge von
Schlüssel-Wert-Paaren, und was damit zu tun ist, entscheidet die Anwendung. Ein Secret vom Typ
`kubernetes.io/dockerconfigjson` versteht `kubelet` selbst: Es weiß, dass darin eine Datei im selben Format wie
`~/.docker/config.json` liegt, und kann sie beim Herunterladen von Images verwenden.

Um den Inhalt anzusehen (das Passwort darin ist in base64 — das ist **keine Verschlüsselung**, sondern eine
Möglichkeit, Binärdaten als Text zu schreiben, und jeder kann es dekodieren):

```bash
# .data.\.dockerconfigjson — der Schlüssel im Secret. Der Schlüsselname selbst beginnt mit einem Punkt,
# deshalb wird er maskiert: sonst hielte jsonpath ihn für einen Pfadtrenner.
# base64 -d dekodiert den Wert zurück in Text — Sie sehen dasselbe Format
# wie in der Datei ~/.docker/config.json auf Ihrem Laptop.
kubectl get secret harbor -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Daraus etwas Wichtiges: **ein Secret in Kubernetes ist standardmäßig nicht verschlüsselt**, es ist lediglich
durch Zugriffsberechtigungen abgeschottet. Wer Secrets im namespace lesen kann, sieht die Passwörter. Wie man
damit menschenwürdig umgeht, ist ein eigenes Lab über einen Secrets-Speicher.

**Wie man es in der Praxis macht.** Nicht mit dem Konto `admin`. Harbor hat Roboter: **Projects** → `passes` →
**Robot Accounts** → einen Roboter mit nur `pull`-Berechtigung erstellen. Die Zugangsdaten des Roboters kommen
in das `imagePullSecret`, und dann bedeutet ein aus dem Cluster durchgesickertes Secret, dass jemand Ihre Images
herunterladen kann — unangenehm, aber nicht fatal. Ein durchgesickertes `admin` bedeutet, dass jemand sie
ersetzen kann.

Wir nehmen `admin`, um das Lab nicht in die Länge zu ziehen. Wissen Sie, dass das eine Vereinfachung ist.

</details>

Wenden Sie nun das korrekte Manifest an. Zuerst dieselbe Adressersetzung wie zuvor, nur in einer anderen Datei;
dann entfernen Sie die kaputte Anwendung und stellen die funktionierende auf:

```bash
# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml

# delete -f = entferne aus dem Cluster genau die in der Datei beschriebenen Objekte
kubectl delete -f passes-broken.yaml
kubectl apply -f passes.yaml

# rollout status wartet, bis die neuen Repliken bereit sind, und beendet sich dann von selbst.
# Kommt es nicht dorthin, gibt es einen Fehler zurück, weshalb eine solche Zeile in Skripten praktisch ist.
kubectl rollout status deployment/passes-api
```

**Was Sie sehen sollten:**

```
deployment "passes-api" successfully rolled out
```

Der Unterschied zwischen dem funktionierenden Manifest und dem kaputten ist genau zwei Zeilen:

```yaml
      imagePullSecrets:
        - name: harbor
```

## Schritt 8. Sehen, was dabei herauskam

📍 **Wo:** auf dem Laptop, der `lab`-Cluster.

Die Anwendung ist nicht nach außen exponiert, aber Sie müssen sie ansehen. `port-forward` gräbt einen Tunnel vom
Laptop in den Cluster: Solange der Befehl läuft, geht eine Anfrage an `localhost:8080` an den Dienst
`passes-api`. Das nächste Analogon ist eine temporäre Portweiterleitung auf einem NAT-Gateway, nur ohne Eingriff
ins Netzwerk.

```bash
# port-forward svc/passes-api = ein Tunnel zum Service, nicht zu einem bestimmten Pod
#   8080:80 — die linke Zahl ist der Port auf Ihrem Laptop, die rechte der Service-Port im Cluster
# Schließen Sie das Fenster nicht: Der Tunnel lebt, solange der Befehl läuft.
kubectl port-forward svc/passes-api 8080:80
```

In einem anderen Terminalfenster:

```bash
# curl — "geh zur Adresse und zeige die Antwort".
#   -s     die Fortschrittsanzeige nicht zeigen
#   ; echo einen Zeilenumbruch anhängen: die Antwort kommt als eine einzige Zeile, und ohne ihn
#          klebt sie am Shell-Prompt
curl -s http://localhost:8080/; echo
```

**Was Sie sehen sollten** — ein JSON, in dem die Anwendung berichtet, welche Replik geantwortet hat, auf welchem
Node sie läuft und aus welcher Registry sie kam:

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

Das Feld `pod` in der Antwort ist der Name der Replik, die geantwortet hat. Vergleichen Sie ihn mit der Liste
der Repliken:

```bash
# ein neues Terminalfenster weiß nichts von der Variablen KUBECONFIG — setzen Sie sie auch hier,
# sonst geht kubectl an den falschen Cluster
export KUBECONFIG=~/lab.kubeconfig

# dieselbe Auswahl per Label: die Liste sollte den Namen enthalten, den Sie in der Antwort gesehen haben
kubectl get pods -l app=passes-api
```

Wiederholen Sie die Anfrage mehrmals — der Name bleibt **derselbe**, und das ist keine Störung. `port-forward`
wählt im Moment des Starts eine einzige Replik und hält den Tunnel genau zu dieser bis `Ctrl+C`; auf diesem Weg
gibt es überhaupt keine Lastverteilung. Auf dem `Service` gibt es sie, aber sehen können Sie sie nur von
innerhalb des Clusters — von außen sprechen Sie mit einem bestimmten Pod.

Die Lastverteilung können Sie so richtig prüfen — acht Anfragen aus einem temporären Pod, der innerhalb des
Clusters lebt:

```bash
# run bringt einen einmaligen Pod hoch, --rm räumt ihn danach auf.
# Alles nach -- läuft innerhalb des Pods: achtmal rufen wir den Service über seinen internen Namen auf
# und geben die Zeile mit dem Namen der antwortenden Replik aus.
kubectl run probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
  -- sh -c 'for i in $(seq 1 8); do curl -s http://passes-api/ | grep -o "passes-api-[a-z0-9-]*"; done'
```

**Was Sie sehen sollten:** zwei verschiedene Namen vermischt — das ist der `Service`, der die Anfragen auf die
Repliken verteilt.

Den Tunnel schließen — `Ctrl+C` im ersten Fenster.

Schließen Sie den Kreis: Gehen Sie in Harbor im Browser, in das Projekt `passes`. Beim Repository
`passes/passes-api` ist der Download-Zähler (**Pulls**) ungleich null geworden. Ihr Cluster ist tatsächlich
genau hierher gegangen.

## Prüfung

📍 **Wo:** auf dem Laptop, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

Das Skript geht gleichzeitig an beide Cluster und nimmt sie aus Umgebungsvariablen. Die ersten beiden sind
zwingend, die dritte ist der Pfad zum Tenant-kubeconfig.

```bash
cd labs/06-harbor

# in welchem Cluster die Anwendung zu prüfen ist — in Ihrem `lab`
export KUBECONFIG=~/lab.kubeconfig
# Ihre Tenant-Nummer: daraus setzt das Skript den namespace-Namen tenant-workshop03 zusammen
export COZY_TENANT=workshop03
# wo der Zugang zum Management-Cluster liegt — dort schaut das Skript auf Harbor selbst.
# Sie können es unbelegt lassen: dann sucht das Skript nach ~/.kube/workshop, und findet es das nicht — überspringt es
# die Prüfungen am Management-Cluster und sagt es.
export COZY_KUBECONFIG=~/.kube/workshop

./check.sh
```

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man es installiert, steht am
Anfang von Lab 0. Ohne WSL können Sie das Lab machen, aber es wird keinen Artefakt-Bericht geben.

Das Skript prüft nicht die Tatsache, dass Harbor erstellt wurde, sondern die Arbeit im Kern: Die Registry
antwortet über ihre API, die Anwendung im Cluster wurde aus einem Image gestartet, das in Ihrer ganz eigenen
Registry liegt, das Secret mit den Zugangsdaten existiert und zeigt auf dieselbe Adresse, und der Service selbst
gibt ein JSON mit dem Namen eines Pods zurück, der tatsächlich existiert.

## Aufräumen

Die Anwendung und Harbor werden im nächsten Lab gebraucht — löschen Sie sie jetzt nicht.

Wenn Sie mit allen Labs fertig sind:

```bash
# lösche die in der Datei beschriebenen Objekte: sowohl das Deployment als auch den Service
kubectl delete -f passes.yaml
# das Secret wurde per Befehl erstellt, nicht per Datei — lösche es über den Namen
kubectl delete secret harbor
```

Harbor selbst wird über das Dashboard gelöscht, wie jede gewöhnliche Anwendung. Mit ihm geht auch der
Layer-Speicher weg — das ist ein Dutzend Sekunden, kein Antrag auf Abschreibung einer VM.

Es lohnt sich zu verstehen, was genau Sie löschen. Eine Registry ist nicht nur der Ort, an dem die Images
liegen, sondern auch die einzige Antwort auf die Frage „was haben wir im vergangenen Jahr eigentlich in die
Produktion ausgeliefert“. Sie in einer Arbeitsumgebung so leicht zu löschen wie hier, werden Sie nicht wollen.

## Was wir jetzt können

- Uns eine Image-Registry einrichten und erklären, wie sie sich von einer Content Library unterscheidet
- Ein Image mit einem zweistufigen Build bauen und verstehen, warum das Ergebnis dreißigmal kleiner ausfällt
- Einen `docker login` auf dem Laptop vom Zugang unterscheiden, den der Cluster braucht
- `ImagePullBackOff` lesen und die wahre Ursache in `describe pod` finden
- Einem Pod über die Downward API Informationen über sich selbst geben, ohne ihm Berechtigungen auf der
  Cluster-API zu erteilen

## In vSphere wäre das

Das nächste Analogon einer Registry ist eine Content Library. Es gibt eine Ähnlichkeit: Beide speichern Images
und geben sie an Maschinen aus, und beide beherrschen Berechtigungen und Synchronisation zwischen Standorten.

Darüber hinaus gehen sie auseinander, und der Unterschied liegt nicht in den Details.

**Eine Content Library kopiert die ganze Vorlage.** Eine Registry gibt Layer aus und speichert identische Layer
einmal. Wenn Sie zwanzig Dienste auf demselben Basis-Alpine haben, liegt die Basis in der Registry in einem
einzigen Exemplar, und beim Start des einundzwanzigsten Dienstes lädt der Node nur seinen eigenen Layer
herunter — eine Handvoll Megabyte.

**Eine Vorlage wird benannt, ein Image wird adressiert.** Ein Image hat einen digest — einen Hash seines
Inhalts. Damit können Sie überprüfen, dass Sie genau den Code ausführen, den Sie gebaut haben, und keinen
anderen. Eine Vorlage hat so etwas nicht: Sie verlassen sich darauf, dass niemand sie ausgetauscht hat.

**Eine Registry ist ein HTTP-Dienst.** Daraus folgt der ganze Sinn der Übung: Ein Build in der Pipeline legt
dort mit einem Befehl ein Image ab, der Cluster holt es mit einem anderen, und niemand mountet Speicher oder
kopiert Dateien von Hand zwischen Standorten.

**Wo vSphere praktischer ist, ehrlich.** Drei Dinge.

Eine Content Library verlangt nicht, irgendetwas über Zugangsdaten zu verstehen. Anbinden — es funktioniert.
Hier mussten Sie dem Cluster separat erklären, wie er die Registry erreicht, und Sie sind darüber gestolpert,
wie alle stolpern.

Die Berechtigungen in vCenter sind einheitlich. Ein Konto für alles: Maschinen, die Library und das Netzwerk.
Hier sind Berechtigungen im Dashboard, Berechtigungen im Cluster und Berechtigungen in Harbor drei verschiedene
Sätze, die synchron gehalten werden müssen. Das ist der Preis dafür, dass die Registry ein eigenständiges
Produkt ist und kein Teil der Plattform.

Eine Vorlage lässt sich bearbeiten. Sie rollen aus einer Vorlage eine Maschine aus, konfigurieren sie weiter,
erfassen eine neue Vorlage — und dass die genaue Abfolge der Schritte nirgends aufgeschrieben ist, stört nichts.
Images werden nicht so gebaut: Wenn sich der Build nicht aus dem `Dockerfile` reproduzieren lässt, sind Sie in
Schwierigkeiten. Die Disziplin ist nützlich, aber sich an sie zu gewöhnen ist schwer, und so zu tun, als wäre
es nicht so, ist töricht.
