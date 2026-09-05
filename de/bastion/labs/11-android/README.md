# Lab 11 · Eine mobile App im Cluster bauen

| | |
|---|---|
| **Zeit** | 40 Minuten, davon bis zu 15 Warten auf den ersten Build |
| **Was es beweist** | Ein Build-Server ist kein Server — er ist eine Aufgabe, die einen Node für die Dauer des Builds belegt und ihn danach wieder freigibt |
| **Was Sie brauchen** | Der Cluster aus Lab 0, `kubectl`, `~/lab.kubeconfig`, Zugang zum Tenant-Dashboard |

## Warum das wichtig ist

Das Mobile-Team schreibt einen Client für Propusk — genau der Bildschirm, über den ein
Mitarbeiter einen Gästeausweis anfordert. Vorerst bauen sie ihn auf der VM eines einzelnen
Entwicklers. Wenn der im Urlaub ist, gibt es kein Release.

Einen eigenen Build-Server haben sie nicht, und sie werden auch keinen bekommen: Ihr Antrag
auf eine dedizierte Maschine für das Android SDK wurde zweimal abgelehnt — „die Last ist
ungleichmäßig, die Maschine steht nur herum". Was, ehrlich gesagt, stimmt. Der Build läuft
zwanzig Minuten am Tag, aber die Maschine, die er braucht, hat vier Kerne und sechzehn
Gigabyte.

Hier tun wir genau das, was von uns verlangt wird: Wir nehmen diese vier Kerne **für zwanzig
Minuten**, bauen das APK und geben sie zurück. Und die fertige Datei legen wir dorthin, wo
jeder sie abholen kann, auch ein Tester mit einem Telefon — in einen Bucket.

Zum ersten Mal in allen Labs **endet** hier ein Workload. Alles, was wir bisher ausgerollt
haben, war dafür gedacht, ewig zu laufen.

## Mini-Glossar

| Begriff | Was es ist | Ähnlich wie … aber |
|---|---|---|
| **Job** | Eine Aufgabe: etwas ausführen und warten, bis es erfolgreich abgeschlossen ist | **Eine geplante Aufgabe im Gast-Betriebssystem**, aber ein Job erstellt sich seine eigene Maschine für den Ablauf und räumt sie selbst wieder weg |
| **Deployment** | Die Beschreibung einer Anwendung, die ewig läuft | **Eine vApp**, aber sie „schließt sich nie erfolgreich ab“ — eine verschwundene Kopie wird neu erstellt |
| **Objektspeicher** | Speicher ohne Dateien und Verzeichnisse — nur ein Schlüssel und sein Inhalt | **Ein Datastore**, aber er wird nicht gemountet. Man legt ganze Objekte ab und holt sie ab, über HTTP |
| **Bucket** | Ein benannter Bereich innerhalb des Objektspeichers | **Ein Ordner auf einem Datastore**, aber nicht verschachtelt: Ein Bucket ist die oberste Ebene, und die „Ordner“ darin sind Teil des Objektnamens |
| **S3** | Ein Protokoll für den Zugriff auf Objektspeicher über HTTP | kein direktes Pendant; näher an einer REST-API als an NFS |
| **Zugriffsschlüssel** | Ein Paar aus „access key / secret key“ statt Login und Passwort | **Ein Dienstkonto**, aber die Schlüssel werden pro Bucket ausgestellt, nicht pro Person |
| **Secret** | Ein Cluster-Objekt, in das man Passwörter und Schlüssel legt | **Ein Eintrag in einem Credential Store**, aber im Cluster ist es base64, keine Verschlüsselung. Es verbirgt Dinge vor den Augen, nicht vor einem Admin |
| **emptyDir** | Eine temporäre Festplatte, die genau so lange lebt wie der Pod | **Eine temporäre vmdk**, aber sie verschwindet zusammen mit dem Pod, ohne Möglichkeit zur Wiederherstellung |

### Job gegen Deployment — in einer Tabelle

Das ist die zentrale Unterscheidung dieses Labs, und es lohnt sich, sie festzuzurren, bevor
wir irgendetwas anwenden.

In beiden Zeilen unten taucht das Wort **Pod** auf. Ein Pod ist die kleinste
Ausführungseinheit in einem Cluster: ein Container (oder mehrere), hochgefahren auf einem
bestimmten Node. Das nächste Pendant ist eine virtuelle Maschine für eine einzige Aufgabe,
nur dass sie in Sekunden erstellt wird und ihren Node nicht überlebt. Weder ein Job noch ein
Deployment führt selbst etwas aus: Sie erstellen Pods und entscheiden, was zu tun ist, wenn
ein Pod verschwindet.

| | Deployment | Job |
|---|---|---|
| Was „alles gut“ bedeutet | die Kopien laufen genau jetzt | der Prozess wurde mit Code 0 beendet |
| Ein Pod wurde erfolgreich beendet | der Cluster wertet das als Fehlschlag und erstellt einen neuen | der Cluster betrachtet die Arbeit als erledigt |
| Wie lange es lebt | bis Sie es löschen | bis er vollständig durchläuft |
| Wie oft es ausgeführt wird | nie — es wird nicht „ausgeführt“, es läuft | einmal (oder so oft wie angegeben) |
| Was danach übrig bleibt | eine laufende Anwendung | die Ergebnisse der Arbeit und Logs |

Daraus folgt eine praktische Konsequenz, über die alle stolpern: **Wenn Sie einen Build als
Deployment ausführen, führt der Cluster ihn wieder und wieder aus**. Der Build wurde
erfolgreich abgeschlossen — also ist die Kopie weg — also muss eine neue erstellt werden.
Eine Endlosschleife, und der Cluster ist nicht schuld: Man hat es ihm so gesagt.

## Was im Lab-Ordner liegt

Alle Dateien gehören bereits Ihnen — Sie haben sie zusammen mit dem Repository bekommen. Es
gibt nichts zu erstellen oder abzutippen: Wo unten `kubectl apply -f name.yaml` steht, stammt
die Datei von hier.

```bash
cd labs/11-android
```

| Datei | Was es ist | Wann Sie sie brauchen |
|---|---|---|
| `bucket.yaml` | Speicher für die gebauten APKs | Sie wenden es **im Tenant** an |
| `propusk-src.yaml` | Der Quellcode der mobilen App Propusk | Sie wenden es auf Ihrem `lab`-Cluster an |
| `android-build.yaml` | Der Build selbst. Das Skript ist in eine ConfigMap ausgelagert, statt in den Job eingebettet zu sein | Sie wenden es ebenfalls dort an |
| `check.sh` | Eine Prüfung, ob der Build erfolgreich war und das APK im Speicher gelandet ist | Sie führen es am Ende des Labs aus |

## Schritt 1. Den Bucket anlegen

📍 **Wo:** im Browser, im Tenant-Dashboard.

**Ein Tenant** ist Ihr Ausschnitt der Plattform: das, was Sie im Dashboard sehen und worüber
Sie verfügen. Den `lab`-Cluster aus Lab 0 haben Sie darin bestellt, und den Bucket bestellen
Sie ebenfalls dort.

Ein Bucket ist ein **Managed Service** — eine fertige Katalogposition: Sie sagen, was Sie
brauchen, und die Plattform bringt es hoch, aktualisiert es und repariert es. Er lebt **nicht
im `lab`-Cluster**, sondern daneben, im Tenant. Und so soll es sein: Build-Artefakte
überleben den Cluster, in dem sie gebaut wurden.

Die Tenant-Zugangsdatei auf diesem Bastion ist bereits eingerichtet — `~/.kube/config`,
derselbe Pfad wie in allen Labs (tokenbasierter Zugang, es öffnet sich kein Browser).

Tenant → **Anwendung erstellen** → `Bucket`.

| Feld | Wert | Warum so |
|---|---|---|
| Name | `builds` | kurz und es ist klar, was drin ist |
| Users | den Benutzer `ci` hinzufügen | der Build schreibt mit diesen Schlüsseln |
| Locking | aus | Schutz vor dem Löschen von Objekten; für Builds übertrieben |
| Storage pool | leer lassen | der Standard-Pool passt |

**Derselbe Bucket als Text**, falls Ihnen das lieber ist. Beachten Sie: Der `namespace` (eine
Trennwand innerhalb des Clusters; Ihr Tenant ist ein eigener namespace) ist hier der des
Tenants, und Sie brauchen die Tenant-Zugangsdatei, nicht die für den `lab`-Cluster.

```bash
# KUBECONFIG — welche Zugangsdatei kubectl verwendet. Hier die des Tenants: Der Bucket
# wird auf dem Management-Cluster bestellt, nicht im lab-Cluster
export KUBECONFIG=~/.kube/config

# apply = „bring den Cluster in den Zustand, der in der Datei beschrieben ist". Der Befehl legt
# den Speicher nicht selbst an — er übergibt die Bestellung an die Plattform.
#   -f bucket.yaml   welche Datei angewendet wird. Ersetzen Sie davor darin
#                    tenant-workshopXX durch Ihren namespace, sonst geht die Bestellung woanders hin
kubectl apply -f bucket.yaml
```

**Was Sie sehen sollten** — `bucket.apps.cozystack.io/builds created`.

<details>
<summary><b>Genauer betrachtet: was in bucket.yaml steckt</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
```

`apps.cozystack.io` ist die API-Gruppe, in der die Managed Services der Plattform leben.
Virtuelle Maschinen, Datenbanken und Queues haben denselben Präfix. Das ist kein „Add-on über
Kubernetes" — das sind gewöhnliche Kubernetes-Objekte, von der Plattform beschrieben.

```yaml
spec:
  users:
    ci: {}
```

Eine Map von Benutzern. Jeder Schlüssel ist ein eigener S3-Benutzer, und für jeden stellt die
Plattform **ein eigenes** Paar Zugriffsschlüssel aus. Ein leeres Objekt `{}` bedeutet
Vollzugriff.

Warum mehrere Benutzer auf einem Bucket: Der Build braucht Schreibzugriff, während das
Mobile-Team und die Tester nur Lesezugriff brauchen. Verschiedene Schlüssel, verschiedene
Rechte, einzeln widerrufbar:

```yaml
  users:
    ci: {}
    mobile:
      readonly: true
```

Wir kommen mit einem aus, um Lab-Zeit zu sparen, aber es lohnt sich, das zu wissen.

</details>

Der Bucket wird in wenigen Sekunden bereitgestellt. Warten Sie, bis er im Dashboard als
bereit angezeigt wird.

## Schritt 2. Die Schlüssel abholen

📍 **Wo:** im Dashboard, auf der Karte des Buckets, im Reiter **Secrets**.

Suchen Sie das Secret `bucket-builds-ci-credentials`. Es enthält vier Werte:

| Feld | Was es ist |
|---|---|
| `endpoint` | die Speicheradresse, **ohne** `https://` — den Präfix müssen Sie selbst ergänzen |
| `bucketName` | der echte Bucket-Name: lang, mit einem Bezeichner, nicht `builds` |
| `accessKey` | der „Login“ |
| `secretKey` | das „Passwort“ |

⚠️ **`bucketName` ist nicht der Name, den Sie eingegeben haben.** Der Name `builds` ist der
Name des Cozystack-Objekts. Den echten Bucket-Namen im Speicher vergibt die Plattform selbst,
und er sieht aus wie `bucket-a9209f83-...`. Genau den müssen Sie einsetzen, sonst wird Ihnen
der Zugriff auf einen nicht existierenden Bucket verweigert und Sie verbringen zehn Minuten
mit der Suche nach einem Tippfehler.

Dieselben vier Werte sind auch über die Kommandozeile verfügbar — die Plattform gewährt
Zugriff auf die Zugangsdaten jeder von Ihnen erstellten Anwendung. Der Befehl unten holt einen
der vier Werte heraus, `accessKey`; die übrigen holt man genauso, nur der Feldname ändert
sich.

```bash
# Wir arbeiten mit demselben Tenant-Zugang wie im vorigen Schritt: Das Secret liegt im Tenant.
# get secret = „zeig das Objekt mit Passwörtern und Schlüsseln". Die Werte im Secret sind
# base64-kodiert — das ist keine Verschlüsselung, nur eine Art, Binärdaten als Text zu schreiben.
#   -n tenant-workshopXX   in welchem namespace gesucht wird
#   -o jsonpath='...'      nicht das ganze Objekt zurückgeben, sondern ein einzelnes Feld daraus:
#                          .data.accessKey — das Feld accessKey im Abschnitt data
#   base64 -d              zurück in lesbare Form dekodieren (d = decode)
#   ; echo                 einen Zeilenumbruch anhängen: ohne ihn liefe der Wert in
#                          die nächste Eingabeaufforderung des Terminals
kubectl -n tenant-workshopXX get secret bucket-builds-ci-credentials \
  -o jsonpath='{.data.accessKey}' | base64 -d; echo
```

Alle Secrets pauschal auszulesen ist dem Tenant allerdings nicht erlaubt: `kubectl auth can-i
get secrets` antwortet mit `no`. Rechte werden eng vergeben, auf bestimmte Namen — und ebenso
an das kubeconfig Ihres Clusters aus Lab 0.

## Schritt 3. Die Schlüssel in den eigenen Cluster legen

Der Build läuft im `lab`-Cluster, aber die Schlüssel liegen im Tenant. Die Cluster sind
verschieden; automatisch wandert nichts hinüber. Wir übertragen sie von Hand.

📍 **Wo:** auf dem Bastion (im Bastion-Terminal).

Wir bauen im `lab`-Cluster ein eigenes Secret mit den vier Werten aus dem vorigen Schritt
zusammen. Ändern Sie die Feldnamen nicht: Das Build-Skript sucht nach Variablen mit genau
diesen Namen.

```bash
# Von hier bis zum Ende des Labs arbeiten wir mit dem lab-Cluster, nicht mit dem Tenant
export KUBECONFIG=~/lab.kubeconfig

# create secret generic = „erstelle ein Secret aus den Werten, die ich gleich aufzähle".
# generic bedeutet „ein beliebiger Satz von Name-Wert-Paaren", kein fertiger Typ
# für ein Image-Registry-Passwort oder ein TLS-Zertifikat.
#   bucket-creds        der Name des Secrets. Der Job verweist über diesen Namen darauf
#   --from-literal=name='value'   ein Paar. Anstelle von ВСТАВЬТЕ_... setzen Sie
#                       die Werte von der Karte des Buckets im Dashboard ein
kubectl create secret generic bucket-creds \
  --from-literal=endpoint='ВСТАВЬТЕ_endpoint' \
  --from-literal=bucketName='ВСТАВЬТЕ_bucketName' \
  --from-literal=accessKey='ВСТАВЬТЕ_accessKey' \
  --from-literal=secretKey='ВСТАВЬТЕ_secretKey'
```

**Was Sie sehen sollten:**

```
secret/bucket-creds created
```

⚠️ **Verwenden Sie einfache Anführungszeichen.** In geheimen Schlüsseln kommen regelmäßig
`$`, `!` und `&` vor. In doppelten Anführungszeichen würde die Shell sie auf ihre eigene Weise
interpretieren, und Sie bekämen einen anderen Schlüssel als den, den Sie kopiert haben.

**Warum dieser Befehl von Hand eingegeben wird, statt als Datei im Repository zu liegen.**
Alles andere in diesen Labs ist Text, der in Git gehen kann. Ein Secret nicht. Das
`Secret`-Objekt im Cluster speichert seine Werte in base64, und base64 ist keine
Verschlüsselung, sondern eine Art zu schreiben: Jeder, der an die Datei kommt, liest die
Schlüssel. Eine Secret-Datei in Git bedeutet Schlüssel in Git für immer, samt der gesamten
Historie. Genau das ist die Art von Audit-Befund, wegen der OpenBao im Propusk-Szenario
auftaucht.

## Schritt 4. Ansehen, was wir bauen werden

Im Ordner liegt `propusk-src.yaml` — der Quellcode der App als ConfigMap. **Eine ConfigMap**
ist ein Cluster-Objekt, das Textdateien in sich enthält: Der Cluster legt sie dann als
gewöhnliche Dateien auf der Festplatte in den Container. Das nächste Pendant ist ein
gemeinsamer Ordner mit Konfigurationen, nur dass er im Cluster selbst gespeichert ist und
zusammen mit der Beschreibung der Aufgabe ankommt.

Der Quellcode liegt aus demselben Grund dort: Der Build braucht Dateien, und für sechs
Textdateien eine Netzwerkfestplatte einzurichten hat keinen Sinn.

Die App tut eine Sache: Sie zeigt die Zeile «Gästeausweis anfordern» an. Das genügt, denn
im Lab geht es nicht um Android, sondern darum, wo es gebaut wird.

**Ein APK** ist das, was am Ende herauskommt. Es ist ein Archiv, das die kompilierte
Anwendung, Bilder, Texte und eine Beschreibung enthält, welcher Bildschirm zu starten ist;
genau das installiert das Telefon. In seiner Rolle ist es dasselbe wie eine `.msi` für
Windows: eine einzige Datei, die man dem Benutzer übergibt.

<details>
<summary><b>Genauer betrachtet: was im Quellcode steckt</b></summary>

Sechs Dateien, verteilt auf die Schlüssel der ConfigMap.

### `settings.gradle.kts` — wo Gradle nach Abhängigkeiten sucht

```kotlin
pluginManagement {
  repositories { google(); mavenCentral(); gradlePluginPortal() }
}
```

Drei öffentliche Repositories, aus denen das Android-Build-Plugin, das Kotlin-Plugin und
alles, was sie nachziehen, heruntergeladen werden. Genau diese Liste erklärt, warum der erste
Build langsam ist: Aus einem leeren Container muss alles heruntergeladen werden.

⚠️ Genau diese Stelle ist das Erste, was Sie ändern werden, wenn die Sicherheitsabteilung
verbietet, für Abhängigkeiten ins Internet zu gehen. Dann wird hier Ihr Proxy-Repository
eingetragen, genauso wie Harbor zum Ersatz für Docker Hub wurde.

### `build.gradle.kts` — Werkzeugversionen

```kotlin
plugins {
  id("com.android.application") version "8.5.2" apply false
  id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
```

`apply false` bedeutet „deklariere die Version, aber aktiviere sie nicht im Wurzelprojekt“ —
das Modul `app` wird sie aktivieren. Die Versionen sind bewusst festgepinnt: Ein Build, der
„das Neueste“ zieht, baut in einem Monat anders als heute, und herausfinden, warum, werden
Sie.

### `app-build.gradle.kts` — das Modul selbst

```kotlin
android {
  namespace = "io.aenix.propusk"
  compileSdk = 34
  defaultConfig { minSdk = 24; targetSdk = 34 }
}
```

`compileSdk 34` ist die Version des Android SDK, gegen die wir kompilieren. Sie bestimmt auch
genau, was im SDK-Installationsschritt heruntergeladen werden muss, und das sind etwa
anderthalb Gigabyte.

`minSdk 24` ist das älteste Android, auf dem die App läuft. Hier ist das Android 7.

```kotlin
  kotlinOptions { jvmTarget = "17" }
```

Kotlin kompiliert zu JVM-Bytecode, daher die Anforderung an die Java-Version. Das Image, das
wir verwenden, bringt JDK 17 mit, und diese beiden Zahlen müssen übereinstimmen.

### `MainActivity.kt` — die Anwendung

```kotlin
class MainActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    ...
    view.text = getString(R.string.greeting)
```

Eine Activity, ein `TextView`, Text aus Ressourcen. Es verwendet das nackte
`android.app.Activity` statt einer Kompatibilitätsbibliothek: Die App hat null externe
Abhängigkeiten, und das spart bei jedem Build ein paar Minuten Download.

`R.string.greeting` ist eine Referenz auf einen String aus `strings.xml`. Die Klasse `R` wird
zur Build-Zeit generiert; im Quellcode ist sie nicht enthalten. Wenn Sie den Fehler
„unresolved reference: R“ sehen, bedeutet das, dass der Schritt zur Ressourcen-Generierung
fehlgeschlagen ist, nicht Ihr Code.

### `AndroidManifest.xml` und `strings.xml`

Das Manifest deklariert, welche Activity vom Icon aus startet. `strings.xml` hält Texte
getrennt vom Code — so können sie übersetzt werden, ohne den Programmierer einzubeziehen.

</details>

Wir legen den Quellcode in den Cluster. Es läuft noch nichts: Das sind nur Dateien, die der
Build im nächsten Schritt brauchen wird.

```bash
# Erstellt eine ConfigMap mit sechs Dateien darin. Zum Prüfen, ob sie vorhanden ist:
# kubectl get configmap propusk-src
kubectl apply -f propusk-src.yaml
```

**Was Sie sehen sollten** — `configmap/propusk-src created`.

## Schritt 5. Den Job zerlegen

Bevor Sie ihn ausführen, lesen Sie, was genau Sie ausführen. Der Build belegt den ganzen
Node, und es lohnt sich zu verstehen, wofür.

<details>
<summary><b>Genauer betrachtet: was in android-build.yaml steckt</b></summary>

Die Datei hat zwei Objekte: eine ConfigMap mit dem Build-Skript und den Job selbst.

### Das Build-Skript

Es liegt aus demselben Grund in einer ConfigMap, aus dem die nginx-Seite getrennt vom
Deployment lag: Vierzig Zeilen Shell in einem `command`-Feld sind unmöglich zu lesen.

Fünf Schritte, und alle fünf sind gewöhnliche Befehle, die Sie von Hand auf einem Build-Server
eingeben würden. Der Container startet leer: Er hat Java und Gradle aus dem Image, aber kein
Android SDK, keine Schlüssel, keinen Quellcode — das SDK und die Schlüssel ziehen die
Build-Befehle nach, und den Quellcode bringt die in den Container gemountete ConfigMap mit.

| Schritt | Was er tut | Wie lange er dauert |
|---|---|---|
| 1 | lädt die Android command-line tools herunter — die Sammlung von Werkzeugen, mit denen das SDK selbst installiert wird | 1–2 Minuten |
| 2 | akzeptiert die Lizenzen und installiert das SDK, Plattform 34, build-tools | 5–15 Minuten |
| 3 | `gradle :app:assembleDebug` — Kompilieren des Quellcodes zu einem APK | 3–8 Minuten |
| 4 | installiert `mc`, einen Kommandozeilen-Client für S3-Speicher | Sekunden |
| 5 | legt das APK unter zwei Namen in den Bucket | Sekunden |

Drei Zeilen verdienen einen genaueren Blick.

```bash
# yes — ein Befehl, der endlos „y" ausgibt: So wird ein Schwung von Fragen „Lizenz
# akzeptieren? [y/n]" ohne einen Menschen beantwortet.
#   >/dev/null 2>&1   sowohl normale Ausgabe als auch Fehlerausgabe verwerfen: sie wird hier nicht gebraucht
#   || true           „auch wenn der Befehl einen Fehler zurückgegeben hat, behandle es als in Ordnung"
yes | sdkmanager --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null 2>&1 || true
```

`|| true` ist hier keine Nachlässigkeit, sondern eine Notwendigkeit: `yes` bekommt ein
SIGPIPE, wenn `sdkmanager` seine Eingabe schließt, und gibt einen von null verschiedenen Code
zurück. Unter `set -o pipefail` würde das den Build grundlos scheitern lassen. Falls die
Lizenzen wirklich nicht akzeptiert wurden, wird der nächste Befehl sich weigern, das SDK zu
installieren, wir verstecken den Fehler also nicht.

```bash
# alias set = „merk dir die Speicheradresse und die Schlüssel unter dem kurzen Namen builds", damit
# wir sie nicht in jedem folgenden Kopierbefehl wiederholen.
#   "https://${endpoint}"   die Adresse: den Präfix https:// ergänzen wir selbst, im Secret steht er nicht
#   ${accessKey} ${secretKey}   Login und Passwort in S3-Begriffen, sie kommen aus dem Secret
#   >/dev/null              die Ausgabe unterdrücken
mc alias set builds "https://${endpoint}" "${accessKey}" "${secretKey}" >/dev/null
```

Die Ausgabe wird bewusst unterdrückt, und aus demselben Grund hat das Skript kein `set -x`:
Die Logs des Jobs sind für jeden mit Zugang zum Cluster sichtbar, und Schlüssel dürfen dort
nicht landen.

```bash
# echo gibt eine Zeile in das Log der Aufgabe aus. Es tut keine Arbeit — es ist eine Markierung
# dafür, dass der vorherige Kopierbefehl bis zum Ende durchgelaufen ist
echo "APK-UPLOADED ${bucketName}/propusk/propusk-${STAMP}.apk"
```

Eine Markierungszeile. An ihr unterscheidet `check.sh` „der Job ist gelaufen“ von „das APK ist
tatsächlich im Bucket angekommen" — das sind verschiedene Aussagen, und die zweite ist
stärker.

### Der Job

```yaml
kind: Job
spec:
  backoffLimit: 1
```

Wie oft der Pod neu erstellt wird, falls der Build fehlschlägt. Null wäre ehrlicher, aber das
Netzwerk fällt beim Herunterladen der anderthalb Gigabyte SDK manchmal aus, und ein zweiter
Versuch ist billiger als die Untersuchung „warum ist meiner fehlgeschlagen“.

```yaml
  activeDeadlineSeconds: 7200
```

Eine Obergrenze für die gesamte Aufgabe, zwei Stunden. Ohne sie würde ein hängender Build den
Node bis zum Abend halten, und Sie würden davon von einem Nachbarn erfahren, bei dem sich
nichts ausrollen lässt.

Der Countdown beginnt mit der Erstellung des Jobs, nicht mit dem Start des Containers: Die Zeit
im Zustand `Pending` und die Neuerstellung des Nodes etwas später im Lab zehren am selben
Limit. Eine Stunde reichte dafür nicht — der Build starb mit `DeadlineExceeded`, kurz nachdem
ein Mensch ihn bereits abgewartet hatte.

```yaml
      restartPolicy: Never
```

Für einen Job ist dieses Feld erforderlich, und es gibt nur zwei gültige Werte. `Never`
bedeutet: einen fehlgeschlagenen Prozess nicht innerhalb desselben Pods neu starten, sondern
die Entscheidung dem Job überlassen — er erstellt einen neuen. So hat jeder Versuch seine
eigenen Logs, und man sieht, welcher fehlgeschlagen ist.

Der Wert `Always`, vom Deployment her vertraut, ist hier nicht verfügbar: „immer neu starten“
und „warten, bis es fertig ist“ widersprechen einander.

```yaml
          envFrom:
            - secretRef:
                name: bucket-creds
```

Alle vier Schlüssel des Secrets werden zu Umgebungsvariablen mit denselben Namen. Die
Alternative wäre, jede Variable einzeln aufzuzählen; für vier gleichartige Schlüssel ist das
unnötiges Rauschen.

⚠️ Ein Nebeneffekt, den man kennen sollte: `envFrom` zieht **alle** Schlüssel des Secrets in
die Umgebung, auch die, die später hinzugefügt werden. Für ein Secret, das Sie selbst angelegt
haben und für eine einzige Aufgabe, ist das akzeptabel. Für ein gemeinsames Secret über den
ganzen namespace nicht.

```yaml
          resources:
            requests: {cpu: "1", memory: 4Gi}
            limits:   {cpu: "2", memory: 6Gi}
```

Hier ist der ehrliche Preis eines Android-Builds. `requests` ist das, was zu reservieren ist:
ein Kern und vier Gigabyte. Weniger hat keinen Sinn — der Kotlin-Compiler frisst sie auf und
verlangt mehr. `limits` ist die Obergrenze: zwei Kerne und sechs Gigabyte.

Vergleichen Sie das mit der App aus dem ersten Lab: `20m` CPU und `32Mi` Speicher. Ein
fünfzigfacher Unterschied bei der CPU und ein hundertdreißigfacher beim Speicher. Das betrifft
die Frage „warum überhaupt `requests` angeben": Ohne sie würde der Scheduler den Build für so
gewichtslos wie nginx halten und ihn auf einen Node setzen, auf den er nicht passt.

```yaml
        - name: work
          emptyDir:
            sizeLimit: 12Gi
```

Eine temporäre Festplatte auf dem Node. Das SDK, der Gradle-Cache und das Build-Ergebnis
landen hier — insgesamt sechs bis acht Gigabyte. Sie lebt genau so lange wie der Pod: Der Job
ist fertig, die Festplatte ist weg.

**Daraus folgt direkt, warum jeder Build langsam ist.** Wir laden das SDK und die
Abhängigkeiten jedes Mal von Grund auf herunter. Auf einem echten Build-Server gäbe es statt
`emptyDir` ein persistentes Volume, und es würde die Aufgabe überleben: der erste Build
langsamer, der zweite merklich schneller. Wir tun das im Lab bewusst nicht, um keine
zusätzliche Entität einzuführen, aber im echten Leben ist es das Erste, was Sie hinzufügen
würden.

```yaml
            items:
              - key: app-build.gradle.kts
                path: app/build.gradle.kts
```

Ein ConfigMap-Schlüssel darf keinen Schrägstrich enthalten, ein Mount-Pfad aber schon. So
entfaltet sich eine flache Map aus sechs Schlüsseln in den Verzeichnisbaum, den Gradle
erwartet.

</details>

## Schritt 6. Ausführen — und gegen eine Wand laufen

📍 **Wo:** auf dem Bastion, im `lab`-Cluster.

Wir wenden den Job an und schauen sofort auf den Pod, den er erstellt hat.

```bash
# Erstellt aus der Datei zwei Objekte: eine ConfigMap mit dem Skript und den Job selbst.
# Ab diesem Moment ist der Cluster verpflichtet, einen Node für den Build zu finden und ihn zu starten
kubectl apply -f android-build.yaml

# get pods = „zeig die Pods". Der Pod der Aufgabe hat keinen eigenen Namen — der Job erfindet ihn
# selbst und hängt an seinen eigenen Namen einen zufälligen Anhang an. Daher suchen wir nicht nach Namen, sondern nach Label:
#   -l job-name=propusk-build   Pods mit dem Label job-name gleich dem Namen des Jobs auswählen.
#                               Dieses Label hängt der Job selbst an seine Pods
kubectl get pods -l job-name=propusk-build
```

**Was Sie höchstwahrscheinlich sehen werden:**

```
NAME                   READY   STATUS    RESTARTS   AGE
propusk-build-x7k2p    0/1     Pending   0          40s
```

`Pending` bedeutet nicht „startet gerade“. Es bedeutet „ist nicht gestartet und wird es auch
nicht". Den Grund schreibt der Cluster in die Events des Pods — sein Journal darüber, wer was
mit ihm zu tun versucht hat.

```bash
# describe = „zeig alles, was über das Objekt bekannt ist": Einstellungen, Zustand, Events.
# Die Ausgabe ist lang, deshalb behalten wir nur ihr Ende:
#   sed -n '/Events:/,$p'   die Zeilen ab der ausgeben, in der „Events:" vorkommt,
#                           bis zum Ende der Ausgabe ($ — Ende)
kubectl describe pod -l job-name=propusk-build | sed -n '/Events:/,$p'
```

**Was Sie sehen sollten** — die Zeile mit dem Grund, warum der Pod nicht platziert wurde:

```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory.
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Was genau ging nicht auf? Erinnern Sie sich, welchen Node Sie in Lab 0 bestellt haben und
> wie viel Speicher der Job angefordert hat.

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

In Lab 0 haben wir den Node `u1.medium` genommen — ein Kern und vier Gigabyte. Der Job
verlangt `requests: memory 4Gi` und `cpu 1`. Genau so viel hat der Node, aber ein Teil davon
ist bereits belegt: kubelet reserviert Speicher für sich selbst, dazu laufen auf dem Node
System-Pods für Netzwerk und Monitoring, dazu die App aus dem ersten Lab.

Beachten Sie, dass **beides** knapp wird — die CPU auch. Der Node `u1.medium` gibt einen Kern,
der Build verlangt einen ganzen, und ein Teil des Kerns ist bereits von System-Pods belegt.
Deshalb hat die Meldung zwei Gründe, nicht einen: Dem Scheduler genügt jeder einzelne davon.

Der Scheduler addiert die `requests` aller Pods auf dem Node und vergleicht das mit dem, was
der Node tatsächlich zu geben bereit ist. Es kommt nicht genug freier Platz zusammen, und der
Pod bleibt für immer wartend.

**Die Lehre reicht über diesen Fehler hinaus.** Der Kubernetes-Scheduler zählt nicht den
tatsächlichen Verbrauch, sondern das **Deklarierte**. Ein Node, auf dem alle Pods dösen und
die CPU-Auslastung drei Prozent beträgt, kann aus Sicht des Schedulers voll belegt sein — wenn
die Summe der `requests` bereits der Kapazität entspricht. Und umgekehrt: Ein Node, der unter
Last nach Luft ringt, nimmt weiter neue Pods an, bis die Summe der `requests` an die Decke
stößt.

Das erklärt auch das auf den ersten Blick seltsame Paar `Insufficient cpu, Insufficient
memory` auf einem scheinbar leeren Cluster — Sie werden ihm mehr als einmal begegnen.

In vSphere sind Ihnen beide vertraut: die Reservierung, die DRS bei der Platzierung
berücksichtigt, und die tatsächliche Last, die es separat betrachtet. Hier wird die
Platzierung **ausschließlich** aus der Reservierung berechnet, ohne die zweite Hälfte.

</details>

## Schritt 7. Den Node vergrößern

📍 **Wo:** im Dashboard, in der Anwendung `lab`.

Öffnen Sie `Kubernetes` → `lab` → bearbeiten. Ändern Sie in der node group:

| Feld | Vorher | Nachher | Warum |
|---|---|---|---|
| Instance type | `u1.medium` (1 Kern, 4 GB) | `u1.large` (2 Kerne, 8 GB) | das Minimum, in das der Build passt |
| Disk | `20Gi` | `40Gi` | das SDK, der Gradle-Cache und die Image-Layer passen nicht in zwanzig |

Wenn die Quota Ihres Tenants es zulässt, nehmen Sie `u1.xlarge` (4 Kerne, 16 GB). Der Build
läuft merklich schneller, und die zusätzlichen Ressourcen geben Sie gleich nach dem Lab
zurück. Lässt sie es nicht zu, verweigert das Formular das Speichern, und dann bleibt
`u1.large`.

⚠️ **Das Ändern des Node-Typs erstellt die virtuelle Maschine des Nodes neu.** Der alte Node
geht, ein neuer kommt hoch, die Pods ziehen um. Das dauert ein paar Minuten, und alles, was
auf der lokalen Festplatte des Nodes lag, verschwindet. Für unsere Labs ist das schmerzlos —
die Daten liegen in Managed Services, nicht auf den Nodes —, aber auf einem Produktions-Cluster
ist das eine Operation, die man plant.

Warten Sie auf den neuen Node. Der `lab`-Cluster hat keine grafische Konsole, deshalb
beobachten wir mit einem Befehl:

```bash
# get nodes = „zeig die Nodes des Clusters" — eben jene virtuellen Maschinen, auf denen
# die Pods laufen.
#   -w   watch, „nicht beenden; bei jeder Änderung Zeilen anhängen". Der alte Node
#        fällt aus der Liste, ein neuer erscheint und erreicht STATUS=Ready.
#        Die Beobachtung verlassen — Ctrl+C, was keine Auswirkung auf den Cluster hat
kubectl get nodes -w
```

Sobald der Node `Ready` ist, bewegt sich der feststeckende Build-Pod von selbst — der
Scheduler überprüft `Pending`-Pods ständig, man muss ihn nicht darum bitten. Wir prüfen, dass
er sich bewegt:

```bash
# Dieselbe Abfrage wie vor der Änderung des Nodes. Jetzt sollte die Spalte STATUS
# ContainerCreating zeigen und in ein, zwei Minuten Running
kubectl get pods -l job-name=propusk-build
```

## Schritt 8. Auf den Build warten

📍 **Wo:** auf dem Bastion, im `lab`-Cluster.

Wir beobachten den Build in seinem Log — also in dem, was das Skript im Container auf den
Bildschirm ausgibt.

```bash
# logs = „zeig, was die Aufgabe ausgegeben hat".
#   -f                  follow: nicht beenden, sondern Zeilen anhängen, sobald sie erscheinen.
#                       Beenden — Ctrl+C, der Build läuft trotzdem weiter
#   job/propusk-build   Sie können auf den Job selbst zeigen, nicht auf den Pod: kubectl findet dessen Pod von allein
kubectl logs -f job/propusk-build
```

**Was Sie sehen sollten** — die fünf Schritte des Skripts nacheinander. Zeitliche
Orientierungspunkte:

| Log-Markierung | Ungefähr wann |
|---|---|
| `== 1/5 installiere Android command-line tools ==` | sofort |
| `== 2/5 akzeptiere Lizenzen und lade das SDK herunter (der längste Schritt) ==` | +1–2 Minuten, und hängt am längsten |
| `== 3/5 baue das APK ==` | +5–15 Minuten ab dem Start |
| `BUILD SUCCESSFUL in ...` | +10–25 Minuten ab dem Start |
| `APK-UPLOADED bucket-.../propusk/propusk-...apk` | direkt danach |

⚠️ **Zwanzig Minuten Stille bei der Markierung `2/5` sind normal, kein Einfrieren.**
`sdkmanager` zeigt im nicht-interaktiven Modus keinen Download-Fortschritt: Er schweigt und
gibt dann `done` aus. Dass der Prozess lebt, können Sie in einem anderen Terminalfenster
bestätigen — prüfen Sie, ob der Pod CPU und Speicher frisst:

```bash
# top = „wie viel er gerade verbraucht". Nicht die requests-Anforderung, sondern die tatsächliche Nutzung
# in genau dieser Sekunde. Eine von null verschiedene CPU bedeutet, dass drinnen gearbeitet wird
kubectl top pod -l job-name=propusk-build
```

Der Job gilt als abgeschlossen, wenn der Pod mit Code 0 beendet wurde (ein Rückgabecode von
null ist das weithin akzeptierte „lief ohne Fehler“):

```bash
# Wir schauen nicht auf den Pod, sondern auf den Job selbst: Er hat Spalten, die der Pod nicht hat
kubectl get job propusk-build
```

```
NAME             STATUS     COMPLETIONS   DURATION   AGE
propusk-build    Complete   1/1           18m32s     19m
```

Die Spalte `DURATION` ist genau die Antwort auf die Frage des Mobile-Teams „wie lange dauert
der Build". Führen Sie denselben Job ein zweites Mal aus, indem Sie ihn löschen und neu
erstellen, und er dauert genauso lange: Wir haben keinen Cache, und wir wissen, warum.

## Schritt 9. Das APK abholen

📍 **Wo:** im Tenant-Dashboard, auf der Karte des Buckets.

Der Bucket hat eine Weboberfläche — öffnen Sie sie von der Karte des Buckets aus und melden
Sie sich mit demselben `accessKey` und `secretKey` an. Darin sehen Sie:

```
propusk/propusk-20260821-141207.apk
propusk/propusk-latest.apk
```

Zwei Namen für eine Datei sind gängige Praxis: Der datierte Name zeigt die Build-Historie, und
über `latest` greift ein Tester immer die frischeste, ohne zu fragen, welches Datum heute ist.

Beachten Sie, dass der „Ordner“ `propusk` in Wirklichkeit nicht existiert. Im Objektspeicher
gibt es keine Verzeichnisse: `propusk/propusk-latest.apk` ist der vollständige Name des
Objekts, und den Schrägstrich darin zeichnet die Oberfläche zu unserer Bequemlichkeit als
Baum.

**Wie sich das von der Dateifreigabe unterscheidet**, die Sie gewohnt sind:

| | Dateifreigabe (NFS, SMB) | Objektspeicher (S3) |
|---|---|---|
| Wie es angebunden wird | als Festplatte gemountet | nicht gemountet, Anfragen über HTTP |
| Teilweises Schreiben | man kann in die Mitte einer Datei schreiben | nicht erlaubt, ein Objekt wird als Ganzes abgelegt |
| Verzeichnisse | echt | keine, der Schrägstrich ist Teil des Namens |
| Sperren | ja | nein |
| Wer es erreicht | wer im selben Netzwerk ist | jeder mit einem Schlüssel und HTTPS |
| Wie viel hineinpasst | so viel wie das Volume fasst | praktisch ohne Obergrenze |

Daher die Regel für die Wahl: **eine Datenbank oder ein gemeinsamer Ordner mit Dokumenten —
eine Dateifreigabe; Artefakte und Backups — Objektspeicher**. Zu versuchen, eine Datenbank auf
S3 zu legen, ist so schmerzhaft, wie APKs über SMB durchs Internet zu verteilen.

## Die Prüfung

📍 **Wo:** auf dem Bastion, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet
haben.

```bash
# Das Skript erreicht den lab-Cluster mit derselben Zugangsdatei wie Sie. Die Zugangsdaten
# des Buckets nimmt es aus dem Secret bucket-creds — Sie müssen nichts separat eingeben
export KUBECONFIG=~/lab.kubeconfig
./check.sh
```

⚠️ **Unter Windows läuft das Skript aus WSL**, nicht aus PowerShell — wie man es installiert,
steht am Anfang von Lab 0. Sie können das Lab ohne WSL abschließen, aber dann gibt es keinen
Artefakt-Bericht.

Das Skript prüft nicht, dass Sie das Manifest angewendet haben, sondern dass der Build bis zum
Ende gelaufen ist: Der Job wurde erfolgreich abgeschlossen, die Logs enthalten `BUILD
SUCCESSFUL`, das APK ist im Bucket angekommen, und der Speicher aus dem Secret antwortet
tatsächlich von innerhalb des Clusters.

## Aufräumen

Nach dem Abschluss verbraucht der Job nichts: Der Pod wurde beendet, und seine Kerne und
Gigabyte kehrten im Moment von `Complete` in die freie Kapazität des Nodes zurück — jemand
anderes kann sie sofort nehmen. Übrig bleiben nur ein Eintrag im Cluster und die Logs — ein
paar Kilobyte.

Es besteht keine Notwendigkeit, ihn sofort zu löschen; die Logs sind noch nützlich. Wenn Sie
fertig sind:

```bash
# delete -f = „entferne aus dem Cluster, was in dieser Datei beschrieben ist". Zusammen mit dem Job
# verschwinden auch seine Logs, daher kommt dieser Befehl zeitlich zuletzt, nicht zuerst
kubectl delete -f android-build.yaml
kubectl delete -f propusk-src.yaml
# Das Secret löschen wir separat: Für es gibt es keine Datei, Sie haben es mit einem Befehl erstellt
kubectl delete secret bucket-creds
```

⚠️ **Setzen Sie den Node zurück auf `u1.medium`, wenn Sie ihn nicht mehr brauchen** — sonst
belegt er bis zum Ende des Workshops vier Kerne. Lassen Sie den Bucket und seinen Inhalt
bestehen: Er ist klein und kommt gelegen, falls Sie neu bauen möchten.

Genau diese Billigkeit des Aufräumens ist das Argument gegen einen dedizierten Build-Server.
Wir haben für die Dauer des Builds einen größeren Node genommen und den vorherigen mit einer
einzigen Feldänderung zurückgegeben.

## Was wir jetzt können

- Einen Job von einem Deployment unterscheiden und verstehen, warum ein Build nicht als
  Letzteres ausgeführt werden darf
- Eine schwere einmalige Aufgabe im Cluster ausführen, ohne eine Maschine dafür einzurichten
- Artefakte in Objektspeicher legen und erklären, warum er keine Dateifreigabe ist
- `Pending` als „passte nicht gemäß `requests`" lesen, nicht als „lädt“
- Den echten Preis eines Android-Builds in Kernen, Gigabyte und Minuten benennen

## Und in vSphere wäre das gewesen

Ein Antrag auf eine VM als Build-Agent. Eine Begründung, warum sie sechzehn Gigabyte braucht,
wenn sie zwanzig Minuten am Tag arbeitet. Eine Ablehnung. Ein zweiter Anlauf ein Quartal
später. Dann eine Maschine, die zu 98 % der Zeit ungenutzt herumsteht und auf der ein Jahr
später drei Generationen des SDK installiert sind, weil das Löschen Angst macht.

Hier werden Ressourcen für die Dauer der Aufgabe genommen und geben sich von selbst zurück.

**Wo vSphere ehrlicherweise bequemer ist.** Eine Build-Maschine, die dauerhaft lebt, hat einen
unbestreitbaren Vorteil: Auf ihr ist bereits alles heruntergeladen. Unsere Build-Zeit besteht
hauptsächlich aus dem Herunterladen des SDK und der Abhängigkeiten, das ein dauerhafter Agent
nicht hätte. Das kuriert ein persistentes Volume für den Cache, aber das Volume muss
eingerichtet, seine Größe überwacht und es gereinigt werden — also einen Teil genau der
Arbeit zurücknehmen, der wir entkommen wollten. Der Unterschied ist, dass ein Volume Pfennige
kostet und keinen Antrag braucht, eine Maschine dagegen schon.

Und zweitens: Eine lebende Maschine, auf die man sich per SSH einloggen kann, um zu sehen,
warum sich ein Build seltsam verhält, ist bequem. Beim Pod eines Jobs können Sie nur die Logs
ansehen, und nach dem Abschluss noch weniger. Das Debuggen eines Builds im Cluster ist anfangs
langsamer.
