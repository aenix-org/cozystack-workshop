# Lab 2 · Selbstheilung: eine Kopie töten und sehen, was passiert

| | |
|---|---|
| **Zeit** | 25 Minuten |
| **Was es zeigt** | Eine Kopie kommt innerhalb von Sekunden von selbst zurück, aber das allein ist keine Fehlertoleranz |
| **Was Sie brauchen** | Der Cluster aus Lab 0, `rickroll` aus Lab 1, `kubectl`, zwei Terminalfenster |

## Warum das wichtig ist

Bald werden Sie für den Dienst „Gate Pass“ geradestehen müssen: Die Sicherheit sieht sich die Gästeliste um sieben
Uhr morgens an, und „wir starten gerade neu, einen Moment“ zählt dort nicht. Bevor Sie ein solches Versprechen
eingehen, lohnt es sich herauszufinden — dort, wo nichts auf dem Spiel steht —, was genau der Cluster von selbst erledigt und was Sie selbst tun müssen.

Nehmen wir uns das lauteste Versprechen von Kubernetes vor — die Selbstheilung. Wir löschen eine laufende Kopie der
Anwendung und messen mit der Uhr, wie lange sie verschwunden bleibt. Danach löschen wir etwas anderes —
und sehen, dass die Kopie nicht zurückkommt. Der Unterschied zwischen diesen beiden Fällen ist der Inhalt dieses Labs.

## Mini-Glossar

| Begriff | Was es ist | Ähnlich wie … aber |
|---|---|---|
| **Gewünschter Zustand** | Ein Eintrag im Cluster: „so soll es aussehen“ | **Cluster-Einstellungen in vCenter**, aber der Cluster wendet ihn nicht einmalig an — er gleicht die Realität endlos daran an |
| **Controller** | Ein Prozess im Control Plane des Clusters, der „wie bestellt“ mit „wie es ist“ abgleicht | **vSphere HA**, aber er läuft ständig und über alle Objekte, statt beim Ausfall eines Hosts aufzuwachen |
| **ReplicaSet** | Ein Objekt, das dafür sorgt, dass es genau so viele Kopien gibt, wie bestellt wurden | **Eine Regel „N Instanzen halten“**, aber es repariert nichts Kaputtes — es erstellt eine neue als Ersatz für die verschwundene |
| **ownerReferences** | Eine Markierung im Objekt: „dieses hier hat mich erstellt“ | dadurch nimmt das Löschen eines Elternobjekts automatisch alle seine Kinder mit |
| **Termination** | Die Pause zwischen „löschen“ und „Prozess beendet“ | **Guest Shutdown statt Power Off**, aber standardmäßig 30 Sekunden, danach wird hart beendet |
| **EndpointSlice** | Eine Liste der aktiven Adressen hinter einem Service | **Die Mitgliederliste eines Pools auf einem Load Balancer**, aber sie wird automatisch aus Labels und Bereitschaft aufgebaut — man trägt nicht von Hand hinein |

## Was im Lab-Ordner liegt

Sie haben bereits alle Dateien — Sie haben sie zusammen mit dem Repository erhalten. Es gibt nichts neu zu erstellen
oder abzutippen: Wo unten `kubectl apply -f name.yaml` steht, wird die Datei von hier genommen.

```bash
# Alle Befehle des Labs werden aus diesem Ordner ausgeführt — sonst stimmen die relativen Pfade darin nicht überein.
cd labs/02-selfheal
```

| Datei | Was es ist | Wann es nützlich ist |
|---|---|---|
| `check.sh` | Prüft, ob der Cluster die gelöschten Kopien von selbst wiederhergestellt hat | führen Sie am Ende des Labs aus |
| — | Das Lab hat keine eigenen Manifeste: Wir arbeiten mit der Anwendung aus Lab 1, und die Datei wird von dort genommen — `../01-deploy/rickroll.yaml` | |

## Schritt 1. Ansehen, was wir haben

📍 **Wo:** auf dem Laptop.

Die Anwendung `rickroll` läuft bereits. Bevor wir etwas kaputt machen, sehen wir uns an, aus welchen Objekten
sie besteht: Mit einem einzigen Befehl fragen wir den Cluster gleichzeitig nach drei Arten von Entitäten.

```bash
# KUBECONFIG — der Pfad zur Datei mit der Adresse des Clusters und Ihren Anmeldedaten.
# Solange die Variable nicht gesetzt ist, sucht kubectl einen Cluster auf dem Laptop selbst und findet keinen.
export KUBECONFIG=~/lab.kubeconfig

# get = "zeig mir, was da ist". Durch Kommas getrennt sind gleich drei Arten von Objekten aufgeführt.
#   -l app=rickroll   nur die mit dem Label app=rickroll anzeigen — also unsere
#                     Anwendung, nicht den gesamten Inhalt des Clusters
kubectl get deployment,replicaset,pods -l app=rickroll
```

**Was Sie sehen sollten** — je eine Zeile für jedes der drei Objekte:

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/rickroll   1/1     1            1           14m

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/rickroll-6f4b9c8d57   1         1         1       14m

NAME                             READY   STATUS    AGE
pod/rickroll-6f4b9c8d57-xk2mp    1/1     Running   14m
```

⚠️ **Es kann mehr als eine `replicaset`-Zeile geben.** Jeder Rollout einer neuen Version hinterlässt den
vorherigen Satz in der Historie — mit Nullen in den Spalten. Der aktive ist der mit den Einsen; die
übrigen bleiben erhalten, damit es etwas gibt, wohin man zurückrollen kann.

Es sind drei Objekte, obwohl Sie im Manifest von Lab 1 einen einzigen Deployment beschrieben haben. Die
anderen beiden hat der Cluster selbst erstellt, und das ist keine Formsache — alles Weitere hängt von dieser Kette ab.

<details>
<summary><b>Die Kette entschlüsseln: wer wen erstellt hat und warum</b></summary>

Sehen Sie sich die Namen an. Der Name eines Pods ist der Name des ReplicaSet plus fünf zufällige Zeichen, und der
Name des ReplicaSet ist der Name des Deployment plus ein Hash. So ist die Kette aufgebaut.

**Deployment** hält Ihre Absicht vollständig fest: welches Image, wie viele Kopien, wie zu aktualisieren ist. Es
überwacht die Pods nicht direkt — es überwacht das ReplicaSet.

**ReplicaSet** hält einen einzigen Gedanken fest: „es soll genau so viele Pods mit dem Label
`app=rickroll` geben". Das ist alles. Es weiß nichts über Images oder Versionen.

**Ein Pod** ist eine laufende Kopie.

Dass das keine Vermutung ist, können Sie so bestätigen:

```bash
# Die normale kubectl-Tabelle zeigt das Feld ownerReferences nicht — man muss es explizit anfordern.
#   -o jsonpath=...   "hol diese Felder aus der Antwort des Servers und gib sie so aus"
# Innerhalb des Ausdrucks: range .items[*] — jeden gefundenen Pod durchlaufen, .metadata.name —
# der Name des Pods, ownerReferences[0].kind und .name — Art und Name dessen, was ihn erstellt hat.
kubectl get pods -l app=rickroll -o jsonpath='{range .items[*]}{.metadata.name}{"  <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}'
```

Ausgabe:

```
rickroll-6f4b9c8d57-xk2mp  <- ReplicaSet/rickroll-6f4b9c8d57
```

Das Feld `ownerReferences` ist der Eintrag „dieses Objekt hat mich erstellt“. Das ReplicaSet hat denselben
Eintrag, nur zeigt er dort auf das Deployment.

Warum drei Ebenen statt einem Objekt: Die Ebenen sind für Verschiedenes zuständig. Wenn wir in Lab 4 eine neue
Version ausrollen, erstellt das Deployment ein **zweites** ReplicaSet für die neue Version und beginnt, die Kopien
einzeln vom alten Satz in den neuen zu verschieben. Das alte ReplicaSet verschwindet währenddessen nicht — genau es
ermöglicht das Zurückrollen mit einem einzigen Befehl.

Eine Randtatsache, die man sich merken sollte: Das Löschen eines Elternobjekts nimmt seine Kinder mit. Löschen Sie
das ReplicaSet von Hand — das Deployment erstellt innerhalb einer Sekunde ein neues. Löschen Sie das Deployment —
alles verschwindet. Den zweiten Fall testen wir am Ende des Labs.

</details>

## Schritt 2. Eine Kopie töten und die Zeit messen

Jetzt löschen wir einen Pod. Nicht ausschalten, nicht neu starten — vollständig löschen, als hätte jemand bei einer
virtuellen Maschine auf Delete from Disk geklickt.

**Was jetzt passiert:** Der Befehl unten merkt sich den Namen der aktuellen Kopie, löscht sie und fragt dann
einmal pro Sekunde den Cluster, ob eine Kopie mit einem **anderen** Namen im Zustand Running aufgetaucht ist. Sobald
eine auftaucht, gibt er aus, wie lange das gedauert hat.

```bash
# items[0].metadata.name — der Name des ersten Pods in der Liste. Wir speichern ihn in der Variable POD:
# ohne das könnten wir später die alte Kopie nicht von der neuen unterscheiden.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')
echo "killing: $POD"

# date +%s — die aktuelle Zeit in Sekunden. Das ist unsere Stoppuhr: vor dem Löschen notiert
# und ganz am Ende von einem frischen Messwert abgezogen.
START=$(date +%s)

# delete pod — die Kopie endgültig löschen.
#   --wait=false   nicht warten, bis der Pod vollständig verschwunden ist, sondern sofort die Kontrolle zurückgeben:
#                  die Sekunden müssen ab diesem Moment gezählt werden, nicht danach
kubectl delete pod "$POD" --wait=false

# Einmal pro Sekunde lesen wir die Pod-Liste neu und suchen eine Zeile, in der all das gleichzeitig zutrifft:
#   $1!=old        der Name stimmt nicht mit dem alten überein — also ist dies eine andere Kopie
#   $2=="1/1"      ein Container von einem ist bereit
#   $3=="Running"  der Pod läuft
#   --no-headers   die Tabellenüberschrift nicht ausgeben, damit awk nur Daten sieht
#   2>/dev/null    Fehlermeldungen in den Sekunden verbergen, in denen es überhaupt keine Pods gibt
while true; do
  NEW=$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null \
        | awk -v old="$POD" '$1!=old && $2=="1/1" && $3=="Running" {print $1; exit}')
  [ -n "$NEW" ] && break
  sleep 1
done
echo "new copy $NEW ready in $(( $(date +%s) - START ))s"
```

**Was Sie sehen sollten:**

```
killing: rickroll-6f4b9c8d57-xk2mp
pod "rickroll-6f4b9c8d57-xk2mp" deleted
new copy rickroll-6f4b9c8d57-p9wqt ready in 4s
```

Vier Sekunden. Auf der Testumgebung liegt die Streuung zwischen zwei und fünfzehn, je nachdem, wie ausgelastet der
Node ist. Das Image liegt bereits auf dem Node, es gibt nichts herunterzuladen, deshalb hängt alles am Starten des
Prozesses und an der Bereitschaftsprüfung.

**Achten Sie auf den Namen.** Das Ende hat sich geändert: `xk2mp` wurde zu `p9wqt`. Das ist nicht derselbe Pod, der
neu gestartet wurde — es ist ein anderer Pod. Den alten gibt es nirgends mehr; man kann ihn nicht reparieren, aus
einem Papierkorb wiederherstellen oder ansehen, was auf seiner Disk war.

Niemand hat irgendetwas „wiederhergestellt“. Mehrmals pro Sekunde gleicht das ReplicaSet „bestellt: 1“ mit
„vorhanden: 0“ ab und erstellt bei einer Abweichung das Fehlende. Die Kopie verschwand — eine Abweichung entstand —
eine Kopie wurde erstellt. Derselbe Mechanismus hätte gegriffen, wenn der Pod zugunsten einer wichtigeren Last vom
Node verdrängt worden wäre, wenn der Node selbst ausgefallen wäre oder wenn die Anwendung im Pod an Speichermangel gestorben wäre.

## Schritt 3. Prüfen, ob dabei Fehlertoleranz bestand

Die Kopie kam in vier Sekunden zurück. Bedeutet das, dass der Dienst nicht unterbrochen wurde?

Prüfen wir das. Wir brauchen **zwei Terminalfenster**.

📍 **Fenster 1** — innerhalb des Clusters starten wir einen winzigen Pod, der unsere Anwendung einmal pro Sekunde
über den Service anstößt und bei Erfolg einen Punkt, bei einem Fehler ein `X` zeichnet:

```bash
export KUBECONFIG=~/lab.kubeconfig

# run = einen einzelnen Pod direkt von der Kommandozeile erstellen, ohne Manifest.
#   --rm             den Pod löschen, sobald Sie den Befehl abbrechen
#   -it              die Ausgabe des Pods kommt auf Ihren Bildschirm, Ctrl+C stoppt ihn
#   --restart=Never  es gibt eine einzige Kopie und keinen Grund, sie neu zu erstellen: das ist ein Werkzeug, kein Dienst
#   --image          busybox — ein Image von wenigen Megabyte, das wget enthält
# Alles nach -- läuft im Pod. Die Adresse http://rickroll ist der Name des Service;
# innerhalb des Clusters wird sie von selbst zur Adresse der Anwendung.
#   -q               keine Download-Statistik ausgeben
#   -T 2             nicht länger als zwei Sekunden auf eine Antwort warten, sonst zählen wir es als Ausfall
#   -O /dev/null     den Antwortkörper verwerfen, uns interessiert nur die Tatsache einer Antwort
kubectl run pinger --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'while true; do wget -q -T 2 -O /dev/null http://rickroll/healthz \
         && echo "$(date +%T) ." || echo "$(date +%T) X"; sleep 1; done'
```

Jede Zeile trägt einen Zeitstempel: So sehen Sie nicht nur den Ausfall selbst, sondern auch **wie viele Sekunden**
er dauerte — und das ist die Zahl, um die es in diesem ganzen Lab geht.

⚠️ **Sie brauchen ein zweites Terminal, keinen Hintergrundlauf.** Der Sinn der Übung ist es, den
Ausfall **in dem Moment** zu sehen, in dem Sie im anderen Fenster die Kopie löschen: Die Zeile mit dem Kreuz soll
vor Ihren Augen erscheinen. Sie können das später in `kubectl logs` nachlesen, aber dann geht das Wichtigste
verloren — die Verbindung zwischen Ihrer Handlung und ihrer Folge.

Warum von innerhalb des Clusters und nicht vom Laptop: `port-forward` klammert sich an einen bestimmten Pod und
stirbt mit ihm, sodass es in jedem Fall einen Ausfall zeigen würde — selbst dort, wo es keinen gibt. `wget` aus
einem benachbarten Pod dagegen geht über den Service, also genau so, wie es ein echter Client täte.

Warten Sie, bis die Punkte zu laufen beginnen.

📍 **Fenster 2** — die Kopie töten:

```bash
export KUBECONFIG=~/lab.kubeconfig

# Es wird kein Pod-Name angegeben, stattdessen ein Label: jede Kopie mit dem Label app=rickroll löschen.
# Im Moment gibt es nur eine, also geht genau die, die der pinger abfragt.
kubectl delete pod -l app=rickroll
```

📍 **Sehen Sie in Fenster 1.** Sie werden etwa Folgendes sehen:

```
.........XXXXX.........
```

Ein paar Sekunden lang antwortete der Dienst mit einem Fehler — bei uns waren es fünf, auf einem ausgelasteten Node
können es fünfzehn sein. Die Kopie kam schnell zurück, aber solange sie fehlte, war niemand da, der antworten konnte.

**So lautet die ehrliche Formulierung dessen, was wir beobachtet haben.** Selbstheilung ist keine Fehlertoleranz.
Selbstheilung bringt das System ohne Menschen wieder in den Normalzustand. Fehlertoleranz bedeutet, dass der Client
überhaupt nichts bemerkt hat. Eine einzige Kopie gibt Ihnen das Erste und nicht das Zweite.

Stoppen Sie den pinger nicht, Sie brauchen ihn gleich.

## Schritt 4. Dasselbe tun, aber mit drei Kopien

📍 **Fenster 2.** Wir bestellen drei Kopien statt einer und warten, bis alle drei bereit sind.

```bash
# scale ändert genau ein Feld im Eintrag der Anwendung — die Anzahl der Kopien.
kubectl scale deployment rickroll --replicas=3

# rollout status hält das Terminal und gibt den Fortschritt aus, bis alle bestellten Kopien
# bereit sind. Der Befehl endet von selbst — man muss get pods nicht von Hand abfragen.
kubectl rollout status deployment/rickroll
```

Wir haben genau eine Zahl im gewünschten Zustand geändert. Von da an erledigt dasselbe ReplicaSet alles:
Es sieht „bestellt 3, vorhanden 1“ und erstellt die zwei fehlenden Kopien. Das dauert die gleichen Sekunden wie zuvor.

Vergewissern Sie sich, dass es jetzt drei Kopien gibt und dass sie alle hinter dem Service gelandet sind:

```bash
# EndpointSlice — genau jene Liste aktiver Adressen, die der Service für Sie führt.
#   -l kubernetes.io/service-name=rickroll   die Liste nehmen, die zum Service rickroll gehört
#   -o jsonpath=...                          aus jedem Eintrag nur die Adresse selbst ausgeben,
#                                            eine pro Zeile
kubectl get endpointslices -l kubernetes.io/service-name=rickroll \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

Drei Adressen. Niemand hat sie dort eingetragen — der Service hat die Liste selbst zusammengestellt, aus dem Label
`app=rickroll` und der Bereitschaft jeder Kopie. Genau das ist der Unterschied zum Pool auf einem Load Balancer, von
dem in Lab 1 die Rede war: Dort trägt man die Adressen ein, hier beschreibt man eine Bedingung.

Jetzt töten wir eine der drei Kopien:

```bash
# Wir nehmen den Namen der ersten der drei Kopien — welche genau, spielt keine Rolle.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')

# Und löschen sie. Hier ohne --wait=false: der Befehl kehrt zurück, wenn der Pod bereits weg ist.
kubectl delete pod "$POD"
```

📍 **Sehen Sie in Fenster 1:**

```
...........................
```

Kein einziges `X`. Die Kopie wurde getötet, sie wurde neu erstellt, der Client hat es nicht bemerkt.

Der Unterschied zwischen dem Test mit einer Kopie und dem mit drei Kopien ist eine einzige Zahl im Manifest. **Fehlertoleranz ist hier keine
Funktion, die man einschaltet, sondern eine Folge davon, dass es mehr als eine Kopie gibt.** Genau deshalb gibt es in
Kubernetes kein Kästchen „HA aktivieren“: Es gibt nichts zu aktivieren, es gibt nur `replicas`.

Stoppen Sie den pinger in Fenster 1 mit `Ctrl+C`. Falls der Pod hängen bleibt, entfernen Sie ihn:
`kubectl delete pod pinger`.

## Schritt 5. Ein Test, der nicht bestehen wird

Der Mechanismus ist klar: Kopie löschen, sie kommt zurück. Testen wir ihn noch einmal, aber diesmal löschen wir
nicht eine Kopie, sondern die Anwendung selbst:

```bash
# Wir löschen nicht eine Kopie, sondern den Eintrag der Anwendung selbst. Es gibt keine Bestätigung,
# das Objekt landet in keinem Papierkorb — es gibt nichts, woraus man es wiederherstellen könnte, außer der Datei.
kubectl delete deployment rickroll
```

Wir warten ein paar Sekunden und sehen nach, ob die Kopien zurückgekommen sind:

```bash
# Wir suchen die Pods über das Label der Anwendung. Eine leere Antwort ist hier auch eine Antwort.
kubectl get pods -l app=rickroll
```

**Was Sie sehen werden:**

```
No resources found in default namespace.
```

Die Kopien kamen nicht zurück. Nicht nach fünf Sekunden, nicht nach einer Minute.

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Warum tauchte die Kopie früher wieder auf, als Sie sie getötet haben, jetzt aber nicht? Wir haben doch nichts abgeschaltet.

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Früher haben Sie eine **Kopie** gelöscht — also eine Tatsache. Der Eintrag „es soll drei Kopien geben“ blieb
bestehen, die Realität wich davon ab, und der Controller beseitigte die Abweichung.

Diesmal haben Sie den **Eintrag selbst** gelöscht. Es gibt nichts mehr, wovon abgewichen werden könnte: Der
gewünschte Zustand ist „diese Anwendung existiert nicht“, der tatsächliche Zustand ist „diese Anwendung existiert
nicht". Sie stimmen überein, und der Controller hat nichts zu tun. Nebenbei sind entlang der `ownerReferences`-Kette
das ReplicaSet und alle drei Pods zusammen mit dem Deployment verschwunden.

**Die Lehre reicht über diesen Fehler hinaus.** Die Regel, die man aus dem Lab als Ganzes mitnehmen sollte:

> Kubernetes schützt Sie vor dem Verlust einer **Tatsache**, tut aber nichts, um Sie vor dem Verlust der **Absicht** zu schützen.

Die gesamte Selbstheilung funktioniert genau so lange, wie der Eintrag darüber, wie es sein soll, intakt ist. Wird
der Eintrag geändert oder gelöscht, gleicht der Cluster die Realität gewissenhaft und sehr schnell an den neuen
gewünschten Zustand an, welcher auch immer das sein mag. Er fragt nicht „sind Sie sicher?“ und hinterlässt keinen Papierkorb.

Es gibt zwei praktische Folgen, und beide sind genau einmal unangenehm.

**Erstens: Das Löschen ist hier leiser als in vSphere.** Ein Deployment abzureißen ist eine Zeile — keine
Bestätigung, kein „Delete from Disk?“ mit rotem Symbol. Aus dem Cluster kann man es nicht wiederherstellen: Ein
gelöschtes Objekt wird nirgends gespeichert.

**Zweitens: Der einzige echte Schutz besteht darin, die Absicht außerhalb des Clusters zu halten.** Wenn das
Manifest in Git liegt und die Automatik es in den Cluster bringt, dann heilt sich ein versehentliches Löschen
dadurch, dass die Automatik das Objekt eine Minute später aus dem Repository zurückbringt. Das ist GitOps, und in Lab 5
schalten wir es ein. Vorerst ist Ihre `rickroll.yaml` die einzige Kopie der Absicht. Gut, dass sie in einer Datei
liegt: Sie können sie durchsehen, in Git ablegen und erneut anwenden.

Übrigens lohnt es sich, das mittlere Glied getrennt zu testen, und es verhält sich anders. Stellen Sie die Anwendung
wieder her (der nächste Schritt) und versuchen Sie dann, nicht das Deployment, sondern das ReplicaSet zu löschen:

```bash
# rs — Kurzform für replicaset; kubectl versteht beide Schreibweisen.
# Wir löschen das mittlere Glied und lassen das Deployment an seinem Platz.
kubectl delete rs -l app=rickroll

# Und sehen sofort nach, was übrig ist: Vergleichen Sie den Namen des Satzes mit dem vor dem Löschen.
kubectl get rs -l app=rickroll
```

Der Satz taucht innerhalb einer Sekunde wieder auf — und **mit demselben Namen**. Der Hash im Namen wird aus dem
Pod-Template berechnet, und das Template haben wir nicht angetastet: Derselbe Name bedeutet, dass der Cluster genau
dasselbe wiederhergestellt hat, statt etwas Neues zu erstellen. Der Eintrag „es soll diese Anwendung geben“ blieb
intakt — dafür ist das Deployment zuständig, und es hat das Löschen des Satzes überlebt.

</details>

## Schritt 6. Die Anwendung zurückbringen

Sie haben die Absicht, sie liegt in einer Datei. Das Wiederherstellen ist ein einziger Befehl:

```bash
# apply = "bring den Cluster in den in der Datei beschriebenen Zustand". Das Objekt existiert nicht — es wird erstellt.
#   -f ../01-deploy/rickroll.yaml   die Datei liegt im Ordner von Lab 1, daher der Pfad über ../
kubectl apply -f ../01-deploy/rickroll.yaml

# Wir warten, bis die Kopie hochgekommen und bereit ist, Anfragen anzunehmen.
kubectl rollout status deployment/rickroll
```

Beachten Sie, was es hier **nicht** gab: kein Backup, keinen Snapshot, keinen Export aus vCenter. Sie haben die
Anwendung aus einer zehn Kilobyte großen Textdatei wiederhergestellt, und heraus kam buchstäblich dasselbe wie
zuvor. Bei einer virtuellen Maschine funktioniert dieser Trick nicht: Ihre Beschreibung und ihr Inhalt sind untrennbar.

## Überprüfung

📍 **Wo:** auf dem Laptop, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

Das Skript prüft nicht, dass Sie die Befehle ausgeführt haben, sondern was im Cluster übrig ist: dass die Anwendung
wieder Anfragen über den Service bedient, den Namen ihrer Kopie in die Seite einsetzt und dieser Name zu einem
tatsächlich laufenden Pod gehört. Gesondert sucht es nach Spuren des Neuerstellens von Kopien — anhand des Alters
der Pods und anhand der Events des Clusters.

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man es installiert, steht am
Anfang von Lab 0. Ohne WSL können Sie das Lab absolvieren, aber es gibt keinen Artefakt-Bericht.

```bash
# ./ bedeutet "eine Datei aus dem aktuellen Ordner", nicht einen Befehl aus dem System-PATH.
# Das Skript ändert nichts im Cluster: es liest nur und gibt einen Bericht aus.
./check.sh
```

## Aufräumen

Die Anwendung `rickroll` wird in Lab 3 und Lab 4 gebraucht — wir löschen sie nicht.

Hier gibt es nichts aufzuräumen, und das ist für sich genommen bemerkenswert. Sie haben die Anwendung aus der Datei
wiederhergestellt, und die Datei bestellt eine Kopie — die überzähligen zwei hat der Cluster selbst heruntergefahren,
schon im vorherigen Schritt, ohne zu fragen und ohne auf Ihren Befehl zu warten. Zur Bestätigung:

```bash
# In der Spalte READY sollte 1/1 stehen.
kubectl get deployment rickroll
```

Die Ressourcen des Nodes wurden in dem Moment freigegeben, in dem die Container endeten. Es gibt hier keine
„Defragmentierung“ und keine planmäßige Rückgewinnung von Platz: Ein Container ist fertig — sein Speicher und seine
CPU-Zeit stehen sofort seinen Nachbarn zur Verfügung.

## Was wir jetzt können

- Die Kette Deployment → ReplicaSet → Pod erklären und verstehen, warum sie drei Ebenen hat
- Selbstheilung (die Kopie kam zurück) von Fehlertoleranz (der Client hat nichts bemerkt) unterscheiden
- Die Anzahl der Kopien mit einer einzigen Zahl ändern und zusehen, wie der Service sie von selbst aufnimmt
- Verstehen, dass der Cluster eine Tatsache schützt, aber nicht die Absicht, und wohin die Absicht gehört

## Und in vSphere wäre das

vSphere HA startet eine VM nach einem Host-Ausfall neu: Zuerst muss der Cluster sicherstellen, dass der Host
wirklich verloren ist (das sind Dutzende Sekunden), dann bootet die Maschine von Grund auf — Kernel, Dienste,
Anwendung. Minuten. VM Monitoring anhand verlorener Heartbeats funktioniert genauso und in derselben Größenordnung der Zeit.

Hier sind es Sekunden, und nicht nur bei einem Host-Ausfall: Derselbe Mechanismus greift, wenn eine Kopie verdrängt
wird, wenn OOM sie tötet, wenn Sie sie selbst löschen.

**Wo vSphere ehrlich gesagt bequemer ist.** Drei Dinge.

Erstens bringt vSphere HA **genau dieselbe Maschine** zurück, mit allem, was auf ihrer Disk war. Ein Pod kommt leer
zurück: Alles, was nicht auf einem persistenten Volume lag, ist endgültig verloren. Für eine zustandslose Anwendung
ist das ein Vorteil; für einen Legacy-Dienst, der jahrelang etwas in sein eigenes `/var` geschrieben hat, ist es
eine Quelle sehr unangenehmer Überraschungen.

Zweitens hat vSphere Fault Tolerance: zwei Maschinen im Gleichschritt und null Ausfallzeit bei einem Host-Ausfall,
ganz ohne Umbau der Anwendung. In Kubernetes gibt es kein direktes Gegenstück, und es kann keines geben — hier wird
null Ausfallzeit dadurch erreicht, dass es mehrere Kopien gibt, was bedeutet, dass die Anwendung in mehreren Kopien
laufen können muss. Kann sie das nicht, löst Kubernetes dieses Problem nicht für Sie — es legt es offen.

Drittens die Fehleranalyse. In vCenter ist der Grund, warum eine Maschine neu gestartet ist, als einzelner Eintrag
in den Events des Clusters sichtbar, und er bleibt dort. In Kubernetes leben Events etwa eine Stunde und verschwinden
dann, und Sie müssen das Bild aus den Logs mehrerer Komponenten rekonstruieren. Solange Sie die Sammlung von Logs
und Events nicht eingerichtet haben (Lab 14), ist „warum ist es über Nacht neu gestartet“ eine Frage ohne Antwort.
