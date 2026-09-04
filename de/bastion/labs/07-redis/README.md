# Lab 7 · Ein Cache vor einem langsamen Backend

| | |
|---|---|
| **Zeit** | 50 Minuten, davon 10 mit Warten |
| **Was es beweist** | Der Gewinn durch einen Cache wird gemessen, nicht behauptet: vorher 800 ms, jetzt einstellig |
| **Was Sie brauchen** | Der Cluster aus Lab 0, Harbor und das Image aus Lab 6, `kubectl`, `docker`, Zugang zum Dashboard |

> ⚠️ **`workshopXX` ist ein Platzhalter, kein Name.** Setzen Sie Ihre eigene Tenant-Nummer ein, sonst
> geht der Befehl in einen fremden Tenant und Sie erhalten eine Zugriffsverweigerung — oder, schlimmer,
> fremde Daten. Ihre Nummer haben Sie zusammen mit Ihrem Passwort erhalten.

## Warum das wichtig ist

Der Dienst „Passierschein“ funktioniert, die Informationssicherheit ist zufrieden, die Registry gehört Ihnen. Und dann kommt der Werkschutz.

> Am Kontrollpunkt öffnet sich die Gästeliste zehn Sekunden lang. Die Leute stehen Schlange, wir
> starren auf den Bildschirm und warten. Früher war das in Ordnung.

Sehen Sie, was passiert. Jede Zeile der Liste ist ein Gast, jeder Gast hat einen Mitarbeiter, der
ihn eingeladen hat, und die Mitarbeiterdaten liegen nicht bei Ihnen. Sie liegen in einem HR-System,
das 2011 installiert wurde, und es braucht **800 Millisekunden**, um auf eine Anfrage zu antworten.
Zwölf Zeilen auf dem Bildschirm — fast zehn Sekunden.

Das HR-System können Sie nicht umschreiben: Es gehört nicht Ihnen, es gehört jemand anderem, und
seine Änderungswarteschlange ist bis nächstes Jahr ausgebucht. Beschleunigen können Sie es aus
demselben Grund ebenfalls nicht.

Was Sie tun können: es nicht so oft fragen. Nachname und Abteilung eines Mitarbeiters ändern sich
etwa alle paar Jahre. Sie beim langsamen System **jedes Mal** abzufragen, wenn die Liste geöffnet
wird, ist Verschwendung: Es genügt, einmal zu fragen und die Antwort zu merken.

Der Ort, an dem Antworten gemerkt werden, heißt Cache. Heute setzen wir einen ein — und, was
wichtiger ist, **messen den Unterschied vorher und nachher**. Nicht „es wurde schneller“, sondern eine konkrete Zahl.

## Mini-Glossar

| Begriff | Was es ist | Ähnlich wie … aber |
|---|---|---|
| **Cache** | Schneller Speicher fertiger Antworten auf wiederkehrende Fragen | **Ein Lese-Cache auf einem Storage-Array**, aber hier entscheidet die Anwendung, was gecacht wird, nicht das Gerät |
| **Redis** | Ein Key-Value-Store, der vollständig im Arbeitsspeicher (RAM) gehalten wird | es gibt kein direktes Gegenstück; am nächsten kommt memcached, falls Sie ihm begegnet sind |
| **Schlüssel** | Die Zeichenkette, mit der ein Wert im Cache nachgeschlagen wird | **Ein Dateiname**, aber Sie erfinden ihn, und alles hängt davon ab, wie Sie das tun |
| **TTL (time to live)** | Wie lange ein Eintrag lebt, bevor er von selbst verschwindet | **Eine Aufbewahrungsfrist für Snapshots**, aber das Löschen geschieht ohne jemandes Zutun und ohne geplanten Job |
| **Miss (cache miss)** | Die Antwort ist nicht im Cache, Sie müssen zur langsamen Quelle gehen | **Ein Lese-Cache-Miss auf einem Storage-Array**, aber ein Miss kostet hier nicht Millisekunden, sondern einen Gang in ein fremdes System |
| **Hit (cache hit)** | Die Antwort wurde im Cache gefunden | **Ein Lese-Cache-Hit**, aber den Hit zählt die Anwendung, und auch er ist in der Antwort im Feld `cached` sichtbar |
| **Sentinel** | Ein Dienst, der Redis überwacht und bei einem Ausfall die Leader-Rolle neu vergibt | **Ein HA-Agent**, aber er läuft in Redis selbst, ein separater Cluster ist dafür nicht nötig |
| **Managed Service** | Ein Dienst, den die Plattform für Sie installiert, aktualisiert und sichert | Sie bekommen kein root auf der Maschine, auf der er läuft — und das ist der Sinn der Sache |
| **Fortio** | Ein Lastgenerator mit Weboberfläche und einem Latenz-Histogramm | in vSphere gibt es kein Gegenstück: Es ist kein Werkzeug, um Infrastruktur zu messen, sondern um einen Dienst zu messen |
| **p50 / p99** | Der Median und die „schlimmsten Prozente“: 99 % der Anfragen haben eine Latenz nicht höher als diese | die durchschnittliche Latenz führt in die Irre, diese beiden Zahlen nicht |

## Zwei Kubeconfigs: nicht verwechseln

In diesem Lab gibt es wieder zwei Cluster.

| Kubeconfig | Was es ist | Was wir darin tun |
|---|---|---|
| `~/.kube/config` | Der Cozystack-Management-Cluster, Ihr Tenant | Redis ansehen: Adresse, Zustand |
| `~/lab.kubeconfig` | **Ihr** `lab`-Cluster aus Lab 0 | die Anwendung ausrollen und messen |

Beide bekommen Sie im Dashboard: den des Tenants aus dem Secret `kubeconfig-tenant-workshopXX` auf dem
Reiter Secrets, den des Clusters im Zugangsbereich Ihres `lab`-Clusters.

⚠️ **Vor jedem Befehlsblock steht, wohin er gerichtet ist.** Wenn sich etwas seltsam
verhält, ist das Erste `echo $KUBECONFIG`.

## Was im Lab-Ordner liegt

Alle Dateien haben Sie bereits — Sie haben sie zusammen mit dem Repository geholt. Es gibt nichts
neu zu erstellen oder abzutippen: Wo unten `kubectl apply -f name.yaml` steht, stammt die Datei von hier.

```bash
# alle Befehle dieses Labs laufen aus dem Lab-Ordner — wechseln Sie hinein
cd labs/07-redis
```

| Datei | Was es ist | Wann es nützlich ist |
|---|---|---|
| `app/` | Die Quellen des Dienstes „Passierschein“, die Version mit Cache | Sie bauen sie lokal, `docker build` |
| `hr-legacy.yaml` | Ein Stub des Legacy-Verzeichnisses: antwortet langsam, wie das echte | Sie wenden es auf Ihrem `lab`-Cluster an |
| `passes-api.yaml` | Der Dienst „Passierschein“ ohne Cache — zuerst messen wir, wie schlimm es ist | Sie wenden es an dieselbe Stelle an |
| `cache-patch-broken.yaml` | Ein **absichtlich unvollständiger** Patch, der den Cache einschaltet | Sie wenden es an, um den Fehler zu sehen |
| `cache-patch.yaml` | Der funktionierende Patch. Ein Patch, kein vollständiges Manifest: Sie sehen genau, was sich ändert | Sie wenden es nach der Erläuterung an |
| `fortio.yaml` | Der Lastgenerator für die Vorher-Nachher-Messungen | Sie wenden es an dieselbe Stelle an |
| `check.sh` | Eine Prüfung, dass die zweite Anfrage um eine Größenordnung schneller ist als die erste | Sie führen es am Ende des Labs aus |

## Schritt 1. Version v2 bauen und in die eigene Registry pushen

📍 **Wo:** auf dem Bastion (im Bastion-Terminal).

Im Ordner `app/` liegt der Quelltext. Von der Version des vorigen Labs unterscheidet er sich in zwei
Dingen: einem Modus „langsames Verzeichnis“ und der Arbeit mit dem Cache.

<details>
<summary><b>Genauer betrachtet: was in app/ steckt</b></summary>

**Ein Image, zwei Rollen.** Die Variable `MODE` bestimmt, als was der Prozess startet:

| `MODE` | Was es ist | Was es tut |
|---|---|---|
| `hr` | ein Stub des Legacy-Verzeichnisses | schläft `HR_DELAY` (standardmäßig 800 ms) und gibt die Mitarbeiterdaten zurück |
| `api` | der Dienst „Passierschein“ selbst | geht ins Verzeichnis, und wenn `REDIS_ADDR` gesetzt ist — zuerst in den Cache |

Zwei Images statt einem würden zwei Stellen bedeuten, an denen man vergessen kann, die Version zu aktualisieren.

**Wie der Gang nach den Daten abläuft.** Die gesamte Caching-Logik umfasst etwa zwanzig Zeilen:

```go
if cache != nil {
    raw, found, err := cache.Get(key)
    switch {
    case err != nil:
        log.Printf("cache unavailable (%v), going to the directory", err)
    case found:
        if json.Unmarshal([]byte(raw), &emp) == nil {
            fromCache = true
        }
    }
}

if !fromCache {
    emp, err = fetchEmployee(hrClient, hrURL, id)
    ...
    cache.SetTTL(key, string(b), ttl)
}
```

Beachten Sie den ersten Zweig: **Ist der Cache nicht erreichbar, stürzt die Anwendung nicht ab.** Sie
schreibt ins Log und geht ins Verzeichnis — langsam, aber korrekt. Das ist keine Zierde, sondern eine
zwingende Eigenschaft jedes Caches: Ein Cache beschleunigt, darf aber keine Voraussetzung für die
Funktionsfähigkeit sein. Wenn der Dienst zusammen mit dem Cache ausfällt, haben Sie keinen Cache gebaut, sondern einen weiteren Ausfallpunkt.

Aus dieser Eigenschaft erwächst übrigens etwas weiter im Lab ein vorhersehbarer Fehlschlag.
Eine Anwendung, die stillschweigend weiterarbeitet, ist im Betrieb angenehm und beim Debuggen tückisch.

**Der Schlüssel.** `employee:42` — ein Entitätsname, ein Doppelpunkt, ein Bezeichner. Der Doppelpunkt
ist hier keine Redis-Syntax, sondern eine weit verbreitete Gewohnheit: Er erlaubt Ihnen, später nach
dem Muster `employee:*` zu suchen und die eigenen Schlüssel nicht mit fremden zu verwechseln, wenn zwei Anwendungen in einem Redis leben.

**Die Lebensdauer wird mit demselben Befehl gesetzt wie das Schreiben:**

```go
r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
```

Nicht `SET` und dann `EXPIRE` als zwei Befehle. Zwischen zwei Befehlen kann die Verbindung abreißen — und
der Schlüssel bleibt für immer im Cache. Nach solchen Schlüsseln fahndet man danach monatelang.

**Der Redis-Client hier ist ein eigener, fünfzig Zeilen.** Das Redis-Protokoll ist textbasiert, und für `GET`
und `SET` passt es in eine einzige Funktion. In einem echten Projekt würden Sie eine fertige Bibliothek
nehmen — sie beherrscht Connection-Pooling, Wiederholungen und Sentinel. Hier braucht es einen eigenen
genau deshalb, damit der Build keine externen Abhängigkeiten hat: Erinnern Sie sich, womit das vorige Lab begann.

**Ein separater HTTP-Client mit vergrößertem Verbindungspool:**

```go
tr := http.DefaultTransport.(*http.Transport).Clone()
tr.MaxIdleConnsPerHost = 64
```

Ohne diese Zeile würde unter Last die halbe Zeit für den Aufbau von TCP-Verbindungen zum
Verzeichnis draufgehen, und die Messung zeigte nicht die Latenz des Verzeichnisses, sondern unsere
eigene Nachlässigkeit. Die erste Regel des Messens: Vergewissern Sie sich, dass Sie das messen, was Sie zu messen glauben.

</details>

Bauen Sie es und pushen Sie es in Ihr eigenes Harbor. `build` baut das Image aus dem `Dockerfile` und
lässt es auf dem Bastion, `push` schickt es in die Registry. Der Image-Name ist derselbe wie im vorigen
Lab, aber der Tag ist anders — `v2`: Die Registry hält nun beide Versionen, und die alte verschwindet nicht.

Setzen Sie Ihre eigene Adresse ein:

```bash
cd labs/07-redis

# build = „baue das Image aus dem Dockerfile".
#   --platform linux/amd64  für welchen Prozessor bauen; die Cluster-Nodes sind x86
#   -t <host>/<projekt>/<name>:<tag>  wie das Ergebnis heißen soll; der Registry-Host am
#                           Anfang des Namens ist das Ziel, wohin push es später schickt
#   app/                    der Ordner mit Dockerfile und Quellen, aus denen gebaut wird
docker build --platform linux/amd64 -t harbor.workshop03.example.org/passes/passes-api:v2 app/

# push = „schicke das Image in die Registry". Die Adresse stammt aus dem ersten Teil des
# Image-Namens, die Zugangsdaten — aus dem docker login, das Sie im vorigen Lab gemacht haben.
docker push harbor.workshop03.example.org/passes/passes-api:v2
```

⚠️ **`--platform linux/amd64` ist erforderlich, wenn Sie einen Mac mit Apple Silicon oder eine VM auf
ARM haben.** Ohne es baut das Image für ARM, pusht ohne Fehler und liefert im Cluster
`CrashLoopBackOff` mit `exec format error` in den Logs.

## Schritt 2. Verzeichnis und Dienst ausrollen

📍 **Wo:** auf dem Bastion, der `lab`-Cluster.

In beiden Manifesten steht statt der Registry-Adresse ein Platzhalter `HARBOR-HOST`: `sed` ersetzt ihn
und bearbeitet die Dateien an Ort und Stelle. Dann übergibt `apply` dem Cluster, was in den Dateien
beschrieben ist, und `rollout status` wartet, bis die Kopien hochkommen.

```bash
# KUBECONFIG sagt kubectl, welche Zugangsdatei zu verwenden ist. Wir wechseln zu
# Ihrem `lab`-Cluster; das gilt, bis Sie das Terminalfenster schließen.
export KUBECONFIG=~/lab.kubeconfig

# sed -i = „bearbeite die Datei an Ort und Stelle".
#   's|alt|neu|g'  jedes Vorkommen ersetzen; als Trenner wird | statt / verwendet, weil
#                  die Adresse Schrägstriche enthält
#   Die macOS-Version von sed verlangt nach -i ein zwingendes Argument; leere Anführungszeichen
#   bedeuten „keine Sicherungskopie anlegen". Unter Linux darf dieses Argument nicht dastehen.
#   Am Zeilenende stehen zwei Dateien: sed nimmt mehrere auf einmal und bearbeitet sie in einem Durchgang.

# Linux
sed -i    's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml

# apply = „bringe den Cluster in den in den Dateien beschriebenen Zustand". Das Flag -f wird für jede Datei wiederholt.
kubectl apply -f hr-legacy.yaml -f passes-api.yaml

# rollout status wartet auf die Bereitschaft der Kopien und beendet sich von selbst; andernfalls gibt es einen Fehler zurück
kubectl rollout status deployment/hr-legacy
kubectl rollout status deployment/passes-api
```

⚠️ Beide Manifeste verweisen auf das Secret `harbor` — genau das `imagePullSecret` aus dem vorigen
Lab. Wenn Sie es nicht gemacht haben, landen die Pods in `ImagePullBackOff`. Das Secret erstellen:

```bash
# create secret docker-registry = „erstelle ein Secret mit Registry-Zugangsdaten";
# ein solches Secret kann der kubelet selbst lesen, wenn er das Image auf einen Node zieht.
#   harbor             der Name des Secrets im Cluster — beide Manifeste verweisen darauf
#   --docker-server    für welche Registry diese Zugangsdaten gelten
#   --docker-username  wer sich anmeldet; --docker-password — das Passwort des Harbor-Administrators
kubectl create secret docker-registry harbor \
  --docker-server=harbor.workshop03.example.org \
  --docker-username=admin --docker-password='IHR-PASSWORT'
```

Prüfen wir, dass die Kette funktioniert. Der Dienst ist nur von innerhalb des Clusters sichtbar, deshalb
stellen wir die Anfrage auch von dort: Wir starten einen Einweg-Pod mit `curl`, er fragt den Dienst
`passes-api`, gibt die Antwort aus und verschwindet.

```bash
# run probe = „starte einen Pod namens probe".
#   --rm              den Pod löschen, sobald er fertig ist
#   -i                uns seine Ausgabe zeigen
#   --restart=Never   nicht neu starten: dies ist ein einmaliger Befehl, kein dauerhafter Dienst
#   --image=...       welches Image verwenden; die Version ist fixiert, damit nichts Neues ankommt
#   --quiet           keine Dienstzeilen ausgeben, nur die Antwort
#   --                alles nach diesen zwei Strichen ist der Befehl im Pod
# Eine Adresse der Form <service>.<namespace>.svc.cluster.local ist der interne Name des Dienstes;
# darüber finden sich die Pods, ohne Adressen zu kennen.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Was Sie sehen sollten:**

```json
{"cache":"off","cached":false,"dept":"Logistics","id":"42","name":"Popova E. K.",
 "pod":"passes-api-6f8b9c7d5-x2ktm","took_ms":803,"ttl_s":60}
```

Die entscheidenden Felder: `cache: off` — kein Cache, `took_ms: 803` — da sind sie, Ihre achthundert
Millisekunden. Genau diese Zahl werden wir verkleinern.

## Schritt 3. Messen, wie schlimm es jetzt ist

📍 **Wo:** auf dem Bastion, der `lab`-Cluster.

Eine Anfrage ist keine Messung. Sie brauchen eine Last, die der echten ähnelt, und eine Verteilung der Latenzen.

Rollen Sie den Generator aus. Er kommt hoch wie eine gewöhnliche Anwendung und lebt im Cluster neben
dem Dienst — so hängt die Messung nicht von Ihrem Internet oder dem Tunnel ab:

```bash
# die Datei enthält zwei Objekte: den Generator selbst und einen Service dafür
kubectl apply -f fortio.yaml
kubectl rollout status deployment/fortio
```

Jetzt starten wir die Last. Der Befehl `kubectl exec` führt etwas innerhalb eines bereits laufenden
Pods aus — hier, innerhalb des Generators, wird der Generator selbst gestartet, im Beschuss-Modus:

```bash
# exec deploy/fortio = einen Befehl im Pod dieser Anwendung ausführen
#   --            die Grenze: links kubectl, rechts der Befehl, der in den Pod geht
#   fortio load   Beschuss-Modus: Anfragen senden und die Antwortzeit messen
#   -qps 20       zwanzig Anfragen pro Sekunde — wir geben ein Tempo vor, nicht „so fest wie möglich"
#   -t 20s        wie lange die Messung dauert
#   -c 16         sechzehn parallele Verbindungen. Die Zahl ist nicht willkürlich:
#                 das Verzeichnis antwortet in 800 ms, also schafft eine Verbindung
#                 etwas mehr als eine Anfrage pro Sekunde. Um die gesetzten 20 pro
#                 Sekunde zu halten, brauchen Sie mindestens sechzehn Verbindungen — sonst
#                 stößt Fortio an die Latenzwand und liefert das gewünschte Tempo nicht.
#   das letzte Argument ist die Adresse, die wir beschießen
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Was Sie sehen sollten** — am Ende der Ausgabe ein Histogramm und Zeilen mit Perzentilen:

```
# target 50% 0.801
# target 90% 0.806
# target 99% 0.812
Code 200 : 400 (100.0 %)
```

**Schreiben Sie diese Zahlen auf.** In zehn Minuten brauchen Sie sie zum Vergleich, und das Gedächtnis
ist so gebaut, dass aus „na, es waren so um die achthundert“ ein „na, es war so um die halbe Sekunde“ wird.

### Dasselbe mit der Maus

Mit der Maus — das ist nicht das Cozystack-Dashboard: Es arbeitet mit dem Management-Cluster und zeigt
die Katalogeinträge des Tenants, aber in Ihren `lab`-Cluster schaut es nicht hinein. Der Generator selbst
hat eine eigene Weboberfläche, und die müssen Sie über einen Tunnel erreichen.

```bash
# port-forward svc/fortio = ein Tunnel vom Bastion zum Service des Generators im Cluster
#   8081:8080 — die linke Zahl ist der Port auf Ihrem Bastion, die rechte der Service-Port im Cluster
# Port 8081 wird verwendet, weil 8080 auf Ihrer Maschine von etwas anderem belegt sein könnte.
# Fenster nicht schließen: Der Tunnel lebt, solange der Befehl läuft. Zum Abbrechen — Ctrl+C.
kubectl port-forward svc/fortio 8081:8080
```

Öffnen Sie <http://localhost:8081/fortio>. Füllen Sie aus:

| Feld | Wert |
|---|---|
| URL | `http://passes-api.default.svc.cluster.local/employee?id=42` |
| QPS | `20` |
| Duration | `20s` |
| Connections | `16` |

Klicken Sie auf **Start**. Unten wird ein Latenz-Histogramm gezeichnet. Es ist anschaulicher als die
Zahlen: Sie sehen, wie sich alle Anfragen in einem schmalen Band um 800 ms sammeln — das heißt, es ist
langsam nicht „manchmal“, sondern immer und um denselben Betrag.


<details>
<summary><b>Warum p50 und p99, nicht die durchschnittliche Latenz</b></summary>

Die durchschnittliche Latenz ist die trügerischste Metrik im Betrieb.

Stellen Sie sich vor: neunzig Anfragen zu 10 ms und zehn Anfragen zu 2000 ms. Der Durchschnitt beträgt
209 ms, und laut Bericht sieht alles ordentlich aus. In Wirklichkeit aber wartete jeder zehnte Nutzer zwei Sekunden und ging.

**p50 (der Median)** — die Hälfte der Anfragen ist schneller als diese Zahl, die Hälfte langsamer. Er
beantwortet die Frage „wie lange wartet ein gewöhnlicher Nutzer“.

**p99** — 99 % der Anfragen sind schneller als diese Zahl. Er beantwortet die Frage „wie schlimm wird es“.
Es ist p99, der bestimmt, ob der Werkschutz am Kontrollpunkt sich beschwert: Menschen beschweren sich nicht
über den Durchschnitt, sondern über das eine Mal, als sie warten mussten.

In unserer Messung fielen p50 und p99 fast zusammen — 801 und 812 ms. Das ist ein Zeichen, dass die
Langsamkeit nicht zufällig, sondern systemisch ist: langsam genau immer. Das heilt ein Cache. Wären p50
10 ms und p99 2000 ms, wäre die Ursache eine andere, und ein Cache würde nicht helfen.

</details>

## Schritt 4. Redis erstellen

📍 **Wo:** im Browser, im Cozystack-Dashboard. Redis ist eine gemeinsame Tenant-Ressource, wie Harbor.

Tenant → **Create application** → `Redis`.

| Feld | Wert | Warum so |
|---|---|---|
| Name | `cache` | kommt in Service-Namen vor, kürzer ist praktischer |
| Replicas | `2` | eine Leader-Kopie und eine Follower-Kopie: wir sehen, was das bringt |
| Size | `1Gi` | das Mitarbeiterverzeichnis passt mit großem Spielraum in den Speicher |
| Storage class | `replicated` | |
| Resources preset | den vorgeschlagenen belassen | |
| Version | `v8` | |
| Auth enabled | **ein** (Standard) | die Plattform generiert das Passwort selbst |
| External | **aus** | es gibt keinen Grund, diesen Cache nach außen freizugeben |

Rechnen Sie mit drei bis fünf Minuten Wartezeit bis zur Bereitschaft.

⚠️ **Dieses Redis hat nichts mit dem Redis zu tun, das Sie im Formular zum Erstellen von Harbor gesehen
haben könnten.** Dort ist es der interne Cache der Registry selbst. Dieses hier ist Ihr eigenes, für Ihre Anwendung.

<details>
<summary><b>Wie sich managed Redis von Redis auf einer VM unterscheidet</b></summary>

Redis auf einer virtuellen Maschine zu installieren ist eine halbe Stunde Arbeit: `apt install redis`,
`bind` und `requirepass` anpassen, beim Systemstart aktivieren. Genau deshalb wirkt ein Managed Service
übertrieben. Der Unterschied liegt nicht in der Installation, sondern in dem, was danach passiert.

**Replikation.** Sie setzen `replicas: 2` — und bekamen zwei Kopien der Daten auf verschiedenen Nodes
plus drei Sentinels, die über sie wachen. Stirbt der Node mit der Leader-Kopie, halten die Sentinels eine
Wahl ab und machen die zweite Kopie zum Leader. Die Anwendung übersteht das mit einer Pause von wenigen
Sekunden. Dasselbe von Hand zusammenzubauen ist ein Tag Arbeit und dann noch ein Tag, um zu prüfen, dass
es wirklich umschaltet und nicht nur konfiguriert aussieht.

**Updates.** Eine Schwachstelle in Redis ist keine Seltenheit. Auf einer VM bedeutet ein Update
`apt upgrade`, einen Neustart und die Hoffnung, dass die Konfiguration einen Wechsel der Major-Version
übersteht. Hier kommt das Image-Update zusammen mit einem Plattform-Update, und die Reihenfolge, in der
die Kopien neu starten, ist so eingerichtet, dass der Dienst nicht verschwindet.

**Observability.** Metriken werden bereits gesammelt: Neben jeder Kopie läuft ein Exporter, die Graphen
sind ohne Ihr Zutun da. Auf einer VM ist das ein weiteres Paket, eine weitere Konfiguration und eine
weitere Sache, die vergessen wurde.

**Worauf Sie verzichten.** Ehrlich: root auf der Maschine mit Redis. Sie können sich nicht per SSH
anmelden, die Konfiguration nicht von Hand bearbeiten, kein eigenes Skript daneben ablegen. Alles, was
nicht als Anwendungsparameter herausgeführt ist, ist für Sie unerreichbar — und herausgeführt ist längst
nicht alles. Wenn Sie eine nicht standardmäßige `maxmemory-policy` oder ein Redis-Modul brauchen, gibt ein
Managed Service es Ihnen nicht, und Sie müssen Ihr eigenes auf einer VM installieren. Das ist eine echte Einschränkung, keine Kleinigkeit.

</details>

## Schritt 5. Die Redis-Adresse finden und die Verbindung prüfen

📍 **Wo:** auf dem Bastion, der **Management**-Cluster.

Redis lebt in Ihrem Tenant auf dem Management-Cluster, und die Anwendung in Ihrem `lab`-Cluster. Das sind
zwei verschiedene Cluster, und als Erstes muss man sich vergewissern, dass der zweite den ersten erreicht.

Sehen wir uns an, welche Services aufgetaucht sind:

```bash
# --kubeconfig setzt die Zugangsdatei direkt im Befehl — nur dieses eine Mal, ohne KUBECONFIG anzurühren.
# So kann man zwei Befehle hintereinander an verschiedene Cluster richten, ohne durcheinanderzukommen.
#   -n tenant-workshopXX  der Namespace Ihres Tenants
#   get svc               „zeige die Services" — dauerhafte Adressen, hinter denen Pods stehen
#   | grep redis          nur die Zeilen mit dem Wort redis in der Ausgabe behalten
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX get svc | grep redis
```

**Was Sie sehen sollten** — mehrere Services mit sprechenden Präfixen:

| Name | Was dahintersteht |
|---|---|
| `rfrm-redis-cache` | die Leader-Kopie (master) — hierhin wird geschrieben und von hier gelesen |
| `rfrs-redis-cache` | die Follower-Kopien (replicas) — nur Lesen |
| `rfs-redis-cache` | sentinel — der Dienst, der überwacht und Rollen umschaltet |

⚠️ **Woher das zusätzliche `redis-` in den Namen kommt.** Die Plattform hängt dem Anwendungsnamen ein
Präfix mit dem Service-Typ an: Die Anwendung `cache` vom Typ Redis heißt intern `redis-cache`.
Daher `rfrm-redis-cache`, nicht `rfrm-cache`. Raten Sie Namen nicht — schauen Sie auf die Ausgabe
des obigen Befehls, das ist die Quelle der Wahrheit.

Wir brauchen `rfrm-redis-cache`: Der Cache schreibt und liest, und schreiben kann man nur in die Leader-Kopie.

Der vollständige Name, unter dem er von Ihrem Cluster aus sichtbar ist, wird so zusammengesetzt:

```
rfrm-redis-cache.tenant-workshopXX.svc.cozy.local
```

Holen Sie das Passwort. 📍 **Wo:** im Dashboard, die Anwendung `cache`, der Reiter mit den Secrets. Sie
brauchen das Secret `redis-cache-auth`, den Schlüssel `password`.

Jetzt — eine Verbindungsprüfung. 📍 **Wo:** auf dem Bastion, der **`lab`**-Cluster.

In Ihrem Cluster starten wir einen Einweg-Pod mit einem Redis-Client und bitten ihn, Redis das Wort
`ping` zu sagen. Kommt eine Antwort zurück, dann ist der Cache im Tenant vom `lab`-Cluster aus sichtbar —
und das ist das eine und einzige, was wir gerade prüfen.

⚠️ **Das Passwort übergeben wir über die Variable `REDISCLI_AUTH`, nicht über das Flag `-a`.** Alles, was
in die Argumente eines Befehls gerät, ist in der Prozessliste auf dem Node sichtbar und bleibt in der
Beschreibung des Pods — die jeder lesen kann, der Zugang zu Ihrem Namespace hat. `redis-cli` selbst warnt
davor, und die Warnung stummzuschalten, statt die Ursache zu beseitigen, ist eine schlechte Angewohnheit.

```bash
export KUBECONFIG=~/lab.kubeconfig

# run redis-probe = ein Einweg-Pod mit dem redis-cli-Client:
#   --rm --restart=Never  hat seine Arbeit getan und sich gelöscht, kein Neustart nötig
#   -i --quiet            uns die Ausgabe zeigen und keine Dienstzeilen ausgeben
#   --env=REDISCLI_AUTH   das Passwort geht als Umgebungsvariable in den Pod, nicht als Argument
#   --                    rechts von diesen Strichen steht der Befehl, der in den Pod geht
#   redis-cli -h <name>   mit welchem Server verbinden; der Name ist genau jener vollständige
#   ping                  ein kurzes „lebst du"; die Antwort darauf ist PONG
kubectl run redis-probe --rm -i --restart=Never --image=redis:7-alpine --quiet \
  --env=REDISCLI_AUTH='IHR-PASSWORT' -- \
  redis-cli -h rfrm-redis-cache.tenant-workshopXX.svc.cozy.local ping
```

**Was Sie sehen sollten:**

```
PONG
```

⚠️ **Wenn Sie statt `PONG` einen Fehler bei der Namensauflösung erhalten haben** — dann sind die internen
Namen des Management-Clusters von Ihrem Cluster aus nicht sichtbar. Das behebt man, indem man ihn über die IP anspricht:

```bash
# -o jsonpath='{.spec.clusterIP}' — ein Feld des Objekts ausgeben: die interne Adresse,
# die die Plattform diesem Service zugewiesen hat. {"\n"} fügt einen Zeilenumbruch hinzu.
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX get svc rfrm-redis-cache \
  -o jsonpath='{.spec.clusterIP}{"\n"}'
```

Von hier an setzen Sie überall die erhaltene Adresse anstelle des Namens ein. Es funktioniert genauso;
der einzige Nachteil ist, dass sich beim Neuerstellen von Redis die Adresse ändert, der Name aber nicht.
Antwortet es auch über die Adresse nicht — schreiben Sie in den Workshop-Chat, das ist ein
Konfigurationsproblem der Testumgebung, nicht Ihr Fehler.

## Schritt 6. Den Cache einschalten

📍 **Wo:** auf dem Bastion, der `lab`-Cluster.

Wir ändern die Anwendung nicht mit einem ganzen Manifest, sondern mit einem Patch — so sehen Sie genau,
was sich ändert. Zuerst setzen wir die Adresse Ihres Redis in den Patch ein, dann übergeben wir den Patch
dem Cluster: `kubectl patch` fügt Änderungen an ein bereits vorhandenes Objekt an, statt es komplett zu ersetzen.

```bash
# dieselbe Adress-Ersetzung wie zuvor, nur der Platzhalter ist ein anderer — REDIS-ADDR

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml

# patch deployment passes-api = „bessere dieses Objekt mit dem aus, was in der Datei steht"
#   --patch-file  woher die Änderungen genommen werden
# Änderung von Umgebungsvariablen bedeutet neue Pods: die alten werden ersetzt.
kubectl patch deployment passes-api --patch-file cache-patch-broken.yaml

# warten, bis die neuen Kopien bereit sind — sonst messen wir noch die alten
kubectl rollout status deployment/passes-api
```

Messen Sie erneut — mit demselben Befehl, mit dem wir vor dem Einschalten des Caches gemessen haben. Die
Beschuss-Bedingungen müssen bis zum letzten Flag übereinstimmen, sonst gibt es nichts zu vergleichen:

```bash
# dieselben zwanzig Anfragen pro Sekunde, dieselben zwanzig Sekunden, dieselben sechzehn Verbindungen
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Die Zahlen haben sich nicht verändert: dieselben achthundert Millisekunden. Und doch ist kein einziger
> Pod abgestürzt, in den Antworten gibt es keine Fehler, jede Anfrage lieferte `200`. Redis ist erstellt,
> die Adresse stimmt — Sie haben gerade ein `PONG` von ihm bekommen.
>
> Wo soll man schauen?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Schauen Sie zuerst, was die Anwendung selbst antwortet: Die Antwort hat Felder, die zeigen, ob der Cache
eingeschaltet ist und ob die Antwort aus ihm kam.

```bash
# derselbe Einweg-Pod mit curl wie zuvor: wir fragen den Dienst von innerhalb des Clusters
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

```json
{"cache":"redis","cached":false,"took_ms":802, ...}
```

`cache: redis` — der Cache ist eingeschaltet. `cached: false` — und trotzdem kam die Antwort nicht aus ihm.
Und zwar **immer** false, so oft Sie es auch wiederholen.

Jetzt das Log. Die Anwendung schreibt dorthin, was ihr nicht gelungen ist — und das ist der einzige Ort,
an dem die Wahrheit derzeit sichtbar ist:

```bash
# logs = „zeige, was die Anwendung in ihre Ausgabe geschrieben hat".
#   -l app=passes-api  über alle Kopien mit diesem Label auf einmal, nicht über eine benannte
#   --tail=20          die letzten zwanzig Zeilen jeder Kopie, nicht das ganze Log
kubectl logs -l app=passes-api --tail=20
```

```
cache unavailable (redis: NOAUTH Authentication required.), going to the directory
cache unavailable (redis: NOAUTH Authentication required.), going to the directory
```

Da ist die Antwort. Wir haben die Redis-Adresse angegeben, aber nicht das Passwort. Redis verlangt
Authentifizierung — Sie haben `Auth enabled` beim Erstellen selbst eingeschaltet, und das ist die richtige
Einstellung. Die Anwendung hat ehrlich versucht, wurde abgewiesen, hat es ins Log geschrieben und ist ins Verzeichnis gegangen.

**Warum das nicht wie ein Defekt aussah.** Weil es keinen Defekt gab. Die Anwendung ist so entworfen, dass
sie die Nichterreichbarkeit des Caches übersteht: Ein Cache beschleunigt, darf aber keine Voraussetzung für
die Funktionsfähigkeit sein. Im Betrieb rettet Sie das — ein Ausfall von Redis reißt den Dienst nicht mit.
Beim Debuggen verbirgt genau diese Eigenschaft das Problem: Alles ist grün, keine Fehler, aber nicht schneller.

**Die Lehre reicht über diesen Fehler hinaus.** Ein Ausfall, der die Arbeit nicht behindert, ist die
teuerste Art von Ausfall. Er schlägt keinen Alarm und lebt monatelang im Produktivbetrieb. Daher eine
praktische Regel: **Jeder Beschleuniger muss ein beobachtbares Zeichen dafür haben, dass er funktioniert.**
Bei uns ist das das Feld `cached` in der Antwort. Gäbe es das nicht, würden Sie jetzt raten.

In einem echten System steht an dieser Stelle eine Metrik „Cache-Hit-Ratio“ und ein Alert für den Fall, dass sie auf null fällt.

</details>

## Schritt 7. Das Passwort eintragen und erneut messen

📍 **Wo:** auf dem Bastion, der `lab`-Cluster.

Das Redis-Passwort lebt im Management-Cluster, und die Anwendung braucht es in Ihrem. Wir tragen es
hinüber — über eine Shell-Variable, damit das Passwort nicht in der Befehlshistorie landet:

```bash
# read legt das über die Tastatur Eingegebene in die Variable REDIS_PASS:
#   -s  das Eingegebene nicht auf dem Bildschirm anzeigen
#   -r  einen Backslash nicht als Sonderzeichen behandeln
# Nach dieser Zeile erscheint nichts auf dem Bildschirm: fügen Sie das Passwort aus dem Dashboard ein und Enter.
read -rs REDIS_PASS

# create secret generic = ein gewöhnliches Secret, eine Menge von Schlüssel-Wert-Paaren.
#   redis-password              der Name des Secrets im Cluster
#   --from-literal=password=... darin einen Schlüssel password mit diesem Wert anlegen;
#                               genau auf das Paar „Secret-Name + Schlüssel" verweist der Patch
kubectl create secret generic redis-password --from-literal=password="$REDIS_PASS"

# unset löscht die Variable, damit das Passwort nicht an die nächsten Befehle in diesem Fenster gelangt
unset REDIS_PASS
```

Wenden Sie den vollständigen Patch an. Er enthält dieselbe Redis-Adresse plus einen Verweis auf das gerade
erstellte Secret und die Lebensdauer der Cache-Einträge; die Erläuterung steht im Spoiler direkt nach dem Befehl.

```bash
# dieselbe Adress-Ersetzung, jetzt in der funktionierenden Patch-Datei

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml

# das vorhandene Deployment mit dem Inhalt der Datei ausbessern und auf die neuen Kopien warten
kubectl patch deployment passes-api --patch-file cache-patch.yaml
kubectl rollout status deployment/passes-api
```

<details>
<summary><b>Genauer betrachtet: was in cache-patch.yaml steckt</b></summary>

```yaml
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: REDIS_ADDR
              value: "rfrm-redis-cache.tenant-workshopXX.svc.cozy.local:6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-password
                  key: password
            - name: CACHE_TTL
              value: "60"
```

**Warum ein Patch, kein vollständiges Manifest.** Ein Patch heißt „ändere dies“, nicht „der Zustand soll
so sein". In der Datei sehen Sie genau, was sich ändert, nicht zweihundert Zeilen, unter denen Sie die drei neuen mit den Augen suchen müssen.

**Warum das die übrigen Variablen nicht auslöscht.** Listen in Kubernetes können sich nach einem Schlüssel
zusammenführen. Für `env` ist der Schlüssel das Feld `name`: Die drei Einträge aus dem Patch werden zu den
bereits vorhandenen hinzugefügt, und der Eintrag `REDIS_ADDR` ersetzt den gleichnamigen, der vom kaputten
Patch übrig geblieben ist. Container-Listen führen sich genauso zusammen, nach Namen — deshalb ist
`- name: api` zwingend; ohne es versteht Kubernetes nicht, welchen Container Sie bearbeiten.

**Warum das Passwort über `secretKeyRef`, nicht als Text.** Der Wert kommt aus dem Secret
`redis-password` im Moment des Pod-Starts. Im Manifest selbst gibt es kein Passwort — und das ist wichtig,
denn das Manifest geht in Git, wo es für immer bliebe. Das Secret gelangt nicht in Git.

Ehrlich: Das Secret im Cluster liegt weiterhin im Klartext, nur an einer anderen Stelle. Jeder, der Secrets
in diesem Namespace lesen kann, sieht das Passwort. Die echte Lösung ist ein externer Secret-Store, und das ist ein eigenes Lab.

**`CACHE_TTL: 60`.** Sechzig Sekunden sind ein Kompromiss. Unten — lesen Sie den nächsten Spoiler.

</details>

Prüfen wir Stück für Stück, bevor wir Last aufbringen. Zwei identische Anfragen hintereinander für einen
Bezeichner, der noch nicht abgefragt wurde: Die erste muss langsam sein, die zweite — schnell.

```bash
# derselbe Einweg-Pod mit curl, aber darin wird eine sh-Shell gestartet:
#   sh -c '...'  mehrere als eine Zeichenkette übergebene Befehle ausführen
#   ; echo       zwischen die Antworten einen Zeilenumbruch einfügen, damit sie nicht zusammenkleben
# id=777 wird verwendet, weil dieser Mitarbeiter noch nicht abgefragt wurde: im Cache ist er definitiv nicht.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  sh -c 'curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"; echo;
         curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"'
```

**Was Sie sehen sollten** — zwei Antworten, und sie sind verschieden:

```json
{"cached":false,"took_ms":804, ...}
{"cached":true,"took_ms":1, ...}
```

Die erste Anfrage ist ein Miss: Der Cache war leer, es musste ins Verzeichnis gegangen werden, 804 ms. Die
zweite ist ein Hit: Die Antwort lag bereits vor, 1 ms.

Jetzt eine Messung unter Last, derselbe Befehl mit denselben Flags, ein drittes Mal:

```bash
# wir ändern nichts an den Beschuss-Bedingungen: es ändert sich nur, was im Dienst steckt
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Was Sie sehen sollten:**

```
# target 50% 0.0012
# target 90% 0.0021
# target 99% 0.0043
Code 200 : 400 (100.0 %)
```

## Schritt 8. Den Gewinn zusammenrechnen

📍 **Wo:** auf einem Zettel.

Sammeln Sie drei Zahlen in einer Tabelle. Ihre werden abweichen — die Testumgebung, das Netzwerk, die Nachbarn auf dem Node:

| | p50 | p99 | Was es für den Werkschutz bedeutet |
|---|---|---|---|
| Ohne Cache | 801 ms | 812 ms | eine Liste mit 12 Zeilen öffnet sich in ~9,6 s |
| Cache ein, kein Passwort | 802 ms | 815 ms | nichts hat sich geändert |
| Cache funktioniert | 1,2 ms | 4,3 ms | dieselbe Liste — ~0,05 s |

Der Unterschied ist **mehrere hundertfach**, und das ist keine Redewendung, sondern der Quotient zweier gemessener Zahlen.

Beachten Sie, was wir **nicht** getan haben. Wir haben das HR-System nicht umgeschrieben. Wir haben keine
Nodes hinzugefügt. Wir haben keine einzige Zeile in der Logik des Dienstes „Passierschein“ geändert — wir
haben ihm nur beigebracht, nicht zweimal dasselbe zu fragen. Die Änderung passte in drei Umgebungsvariablen.

<details>
<summary><b>Wann ein Cache nicht hilft, und wie man es im Voraus erkennt</b></summary>

Ein Cache ist keine universelle Beschleunigung. Er hilft unter einer Bedingung: **dieselbe Frage wird viele
Male gestellt.** Prüfen Sie sich an drei Fällen.

**Jede Anfrage ist einzigartig.** Würde die Gästeliste jedes Mal Informationen über einen neuen Mitarbeiter
anfragen, gäbe es überhaupt keine Hits, und zu jeder Anfrage käme ein Gang zu Redis hinzu. Es würde
langsamer. Bestätigen können Sie das so — führen Sie zwei kurze Serien über verschiedene Bezeichner aus und
schauen Sie auf die jeweils ersten Anfragen:

```bash
# zwei Beschüsse hintereinander über verschiedene Mitarbeiter, je zehn Sekunden.
# Zu Beginn jeder Serie ist der Cache für diesen Schlüssel leer — und die erste Anfrage geht ins Verzeichnis.
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=1"
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=2"
```

Die ersten Anfragen jeder Serie sind Misses. Bei einer großen Menge selten wiederholter Schlüssel entartet der Cache zu Overhead.

**Die Daten ändern sich häufiger als der TTL.** Änderten sich die Informationen über einen Mitarbeiter alle
zehn Sekunden, während der TTL auf 60 stand, sähe der Werkschutz bis zu eine Minute lang veraltete Daten.
Ein Cache tauscht immer Aktualität gegen Geschwindigkeit, und zu entscheiden, wie viel Aktualität entbehrlich
ist, ist keine technische Entscheidung, sondern eine Frage an den Kunden.

**Langsam nicht immer, sondern manchmal.** Erinnern Sie sich an den Unterschied zwischen p50 und p99 aus der
ersten Messung? Ist p50 klein und p99 riesig, dann ist nicht die Datenquelle langsam, sondern etwas
Sporadisches: Garbage Collection, Nachbarn auf dem Node, Sperren in der Datenbank. Ein Cache maskiert das,
heilt es aber nicht, und eines Tages werden Sie genau dasselbe entwirren, nur ein Jahr später und mit einem Cache obendrauf.

</details>

<details>
<summary><b>Wie der TTL gewählt wird</b></summary>

Der TTL ist der einzige echte Parameter eines Caches, und er wird nicht aus technischen Gründen gewählt.

Die Frage lautet: **Wie lange sind Sie bereit, veraltete Daten zu zeigen?**

Für ein Mitarbeiterverzeichnis: Ein Nachname wird alle paar Jahre geändert, eine Abteilung einmal im Jahr.
Die gestrige Abteilung am Kontrollpunkt stört niemanden. Der TTL könnte ebenso gut eine Stunde oder ein Tag sein.

Wir haben sechzig Sekunden gesetzt, damit das Lab beobachtbar ist: Warten Sie eine Minute, wiederholen Sie
die Anfrage — Sie sehen wieder `cached: false`, weil der Eintrag abgelaufen und ins Verzeichnis gegangen ist.
Bei einem TTL von einem Tag müssten Sie das glauben.

Grenzfälle:

| TTL | Was Sie bekommen |
|---|---|
| Zu klein | wenige Hits, der Cache funktioniert kaum, die Last auf die Quelle bleibt |
| Zu groß | schnell, aber die Nutzer sehen die gestrigen Daten und beschweren sich über etwas anderes |
| Gar nicht gesetzt | Schlüssel häufen sich an, der Speicher geht aus, Redis fängt an, willkürlich zu verdrängen |

Die letzte Zeile ist die tückischste. Ein Cache ohne TTL verwandelt sich mit der Zeit in eine Datenbank, die niemand sichert.

</details>

## Prüfung

📍 **Wo:** auf dem Bastion, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

Das Skript geht in beide Cluster auf einmal und nimmt sie aus Umgebungsvariablen. Die ersten beiden sind
zwingend, die dritte ist der Pfad zum Tenant-Kubeconfig.

```bash
cd labs/07-redis

# in welchem Cluster die Anwendung geprüft wird — in Ihrem `lab`
export KUBECONFIG=~/lab.kubeconfig
# Ihre Tenant-Nummer: daraus setzt das Skript den Namespace-Namen tenant-workshop03 zusammen
export COZY_TENANT=workshop03
# wo der Zugang zum Management-Cluster liegt — dort schaut das Skript auf Redis selbst.
# Sie können sie nicht setzen: dann sucht das Skript ~/.kube/config, und findet es das nicht — überspringt
# es die Prüfungen auf dem Management-Cluster und sagt das.
export COZY_KUBECONFIG=~/.kube/config

./check.sh
```

⚠️ **Unter Windows läuft das Skript aus WSL**, nicht aus PowerShell — wie man es installiert, steht am
Anfang von Lab 0. Ohne WSL können Sie das Lab dennoch abschließen, aber es gibt keinen Artefakt-Bericht.

Das Skript glaubt keinem Manifest aufs Wort. Es stellt selbst zwei Anfragen hintereinander für einen
zufälligen Bezeichner und beobachtet: Die erste sollte ein Miss sein und Hunderte von Millisekunden dauern,
die zweite ein Hit und einstellig ausfallen. Den Unterschied hält es im Bericht als Zahlen fest. Nebenbei
prüft es, dass das langsame Verzeichnis wirklich langsam ist: Ohne das würde der Vergleich nichts bedeuten.

## Aufräumen

Alles wird in den folgenden Labs gebraucht — jetzt löschen wir nichts.

Wenn Sie mit allen Labs fertig sind:

```bash
# delete -f = genau die in den Dateien beschriebenen Objekte aus dem Cluster entfernen
kubectl delete -f passes-api.yaml -f hr-legacy.yaml -f fortio.yaml
# das Secret wurde durch einen Befehl erstellt, nicht durch eine Datei — wir löschen es nach Namen
kubectl delete secret redis-password
```

Redis selbst wird über das Dashboard gelöscht, wie eine gewöhnliche Anwendung.

Den Cache zu löschen ist eine billige und fast gefahrlose Operation, und das ist eine besondere Eigenschaft
von Caches: **In einem Cache liegen keine Daten, die es nirgends sonst gibt.** Alles darin lässt sich mit
einem Gang zur Quelle wiederherstellen. Redis zu verlieren bedeutet, für ein paar Minuten Geschwindigkeit
zu verlieren, während er sich neu füllt — aber keine Information zu verlieren. Bei einer Datenbank
funktioniert das nicht so, und im Lab über die Datenbank kommen Sie darauf zurück.

## Was wir jetzt können

- Ein managed Redis bereitstellen und erklären, was die Replikation bringt, die Sie nicht konfiguriert haben
- Die Latenz vor und nach einer Änderung messen, statt darüber zu reden
- p50 und p99 lesen und verstehen, warum die durchschnittliche Latenz täuscht
- Einen TTL danach wählen, wie viel Veralterung der Kunde toleriert
- Den Ausfall finden, der die Arbeit nicht behindert — die teuerste Art von Ausfall

## Und in vSphere wäre das

Für diese Aufgabe gibt es in vSphere kein Gegenstück, und das sollte man klar sagen. Ein Cache ist kein
Infrastrukturobjekt, sondern Teil der Architektur der Anwendung. Der Hypervisor kann die Antworten des
HR-Systems nicht cachen und soll es auch nicht können.

Was man in der Welt der virtuellen Maschinen täte: ein Antrag auf eine VM für Redis, Installation,
Konfiguration von `requirepass`, Konfiguration des Autostarts, dann — wenn man dazu kommt — eine zweite VM
für die Replika, Sentinel, Prüfung des Failovers. Tage an Arbeit, von denen der eigentliche Cache eine halbe
Stunde ausmacht und der Rest Beiwerk ist. Daher stammt eine Gewohnheit, die jedem Administrator vertraut
ist: „lass uns vorerst ohne Replika, wir fügen sie später hinzu“. Später fügen sie sie nicht hinzu.

Der Unterschied ist nicht, dass Redis sich hier schneller installiert. Der Unterschied ist, dass Replika,
Failover, Metriken und Updates standardmäßig mitkommen und „vorerst ohne Replika“ nie als Option aufkommt.

**Wo vSphere praktischer ist, ehrlich.** Drei Dinge.

**Volle Kontrolle.** Auf Ihrer eigenen VM installieren Sie jede Version von Redis, jedes Modul, jede
`maxmemory-policy` und Ihr eigenes Monitoring-Skript daneben. Hier haben Sie nur Zugriff auf das, was als
Anwendungsparameter herausgeführt ist — und herausgeführt ist längst nicht alles.

**Diagnose.** Wenn Redis auf einer VM sich seltsam verhält, melden Sie sich per SSH an und schauen auf
`redis-cli INFO`, `SLOWLOG`, die System-Zähler. Hier gibt es kein SSH, und an dieselben Informationen zu
gelangen muss über `kubectl exec` und Metriken laufen — langsamer und mit geringerer Auflösung.

**Vorhersehbarkeit der Nachbarn.** Eine VM mit Redis bedeutet garantierte Kerne und Speicher, die Sie in
vCenter sehen. Ein Managed Service lebt auf gemeinsam genutzten Nodes neben fremder Last; Limits schützen
ihn, aber „warum ist er heute zwei Millisekunden langsamer“ werden Sie länger herausfinden als auf einer dedizierten Maschine.
