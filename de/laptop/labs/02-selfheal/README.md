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
# All the lab's commands are run from this folder — otherwise the relative paths in them won't line up.
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
# KUBECONFIG — the path to the file with the cluster's address and your login credentials.
# Until the variable is set, kubectl looks for a cluster on the laptop itself and doesn't find one.
export KUBECONFIG=~/lab.kubeconfig

# get = "show me what's there". Three kinds of object are listed at once, separated by commas.
#   -l app=rickroll   show only those labelled app=rickroll — that is, our
#                     application, not the entire contents of the cluster
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
# The default kubectl table doesn't show the ownerReferences field — you have to ask for it explicitly.
#   -o jsonpath=...   "pull these fields out of the server's response and print them like this"
# Inside the expression: range .items[*] — walk through every Pod found, .metadata.name —
# the Pod's name, ownerReferences[0].kind and .name — the kind and name of whatever created it.
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
# items[0].metadata.name — the name of the first Pod in the list. We save it in the POD variable:
# without that we won't be able to tell the old copy from the new one later.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')
echo "killing: $POD"

# date +%s — the current time in seconds. This is our stopwatch: we note it before the delete,
# and subtract it from a fresh reading right at the end.
START=$(date +%s)

# delete pod — delete the copy for good.
#   --wait=false   don't wait for the Pod to fully disappear, return control immediately:
#                  we need to start counting seconds from this moment, not afterwards
kubectl delete pod "$POD" --wait=false

# Once a second we re-read the Pod list and look for a line where all of these hold at once:
#   $1!=old        the name doesn't match the old one — so this is a different copy
#   $2=="1/1"      one container out of one is ready
#   $3=="Running"  the pod is running
#   --no-headers   don't print the table header, so awk sees only data
#   2>/dev/null    hide error messages during the seconds when there are no Pods at all
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

# run = create a single Pod straight from the command line, without a manifest.
#   --rm             delete the Pod as soon as you interrupt the command
#   -it              the Pod's output comes to your screen, Ctrl+C stops it
#   --restart=Never  there's a single copy and no need to recreate it: this is a tool, not a service
#   --image          busybox — an image a few megabytes in size that has wget
# Everything after -- runs inside the Pod. The address http://rickroll is the name of the Service;
# inside the cluster it turns into the application's address on its own.
#   -q               don't print download statistics
#   -T 2             wait no longer than two seconds for a reply, otherwise we count it as a failure
#   -O /dev/null     throw the response body away, all we care about is the fact of a reply
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

# No pod name is given, a label instead: delete every copy with the label app=rickroll.
# Right now there's only one, so the one the pinger is polling is exactly the one that goes.
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
# scale changes exactly one field in the application's record — the number of copies.
kubectl scale deployment rickroll --replicas=3

# rollout status holds the terminal and prints progress until all the copies you asked for
# are ready. The command finishes on its own — no need to poll get pods by hand.
kubectl rollout status deployment/rickroll
```

Wir haben genau eine Zahl im gewünschten Zustand geändert. Von da an erledigt dasselbe ReplicaSet alles:
Es sieht „bestellt 3, vorhanden 1“ und erstellt die zwei fehlenden Kopien. Das dauert die gleichen Sekunden wie zuvor.

Vergewissern Sie sich, dass es jetzt drei Kopien gibt und dass sie alle hinter dem Service gelandet sind:

```bash
# EndpointSlice — that very list of live addresses the Service keeps for you.
#   -l kubernetes.io/service-name=rickroll   take the list belonging to the Service rickroll
#   -o jsonpath=...                          from each entry print only the address itself,
#                                            one per line
kubectl get endpointslices -l kubernetes.io/service-name=rickroll \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

Drei Adressen. Niemand hat sie dort eingetragen — der Service hat die Liste selbst zusammengestellt, aus dem Label
`app=rickroll` und der Bereitschaft jeder Kopie. Genau das ist der Unterschied zum Pool auf einem Load Balancer, von
dem in Lab 1 die Rede war: Dort trägt man die Adressen ein, hier beschreibt man eine Bedingung.

Jetzt töten wir eine der drei Kopien:

```bash
# We take the name of the first of the three copies — which one exactly doesn't matter.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')

# And delete it. No --wait=false here: the command returns once the Pod is already gone.
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
# We delete not a copy but the application's record itself. There will be no confirmation,
# the object won't go to any recycle bin — there'll be nowhere to restore it from but the file.
kubectl delete deployment rickroll
```

Wir warten ein paar Sekunden und sehen nach, ob die Kopien zurückgekommen sind:

```bash
# We look for pods by the application's label. An empty response here is an answer too.
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
# rs — short for replicaset; kubectl understands both spellings.
# We delete the middle link, leaving the Deployment in place.
kubectl delete rs -l app=rickroll

# And immediately look at what's left: compare the set's name with what it was before the delete.
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
# apply = "bring the cluster to what's described in the file". The object doesn't exist — it will be created.
#   -f ../01-deploy/rickroll.yaml   the file lives in the lab 1 folder, hence the path via ../
kubectl apply -f ../01-deploy/rickroll.yaml

# We wait for the copy to come up and become ready to take requests.
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
# ./ means "a file from the current folder", not a command from the system PATH.
# The script changes nothing in the cluster: it only reads and prints a report.
./check.sh
```

## Aufräumen

Die Anwendung `rickroll` wird in Lab 3 und Lab 4 gebraucht — wir löschen sie nicht.

Hier gibt es nichts aufzuräumen, und das ist für sich genommen bemerkenswert. Sie haben die Anwendung aus der Datei
wiederhergestellt, und die Datei bestellt eine Kopie — die überzähligen zwei hat der Cluster selbst heruntergefahren,
schon im vorherigen Schritt, ohne zu fragen und ohne auf Ihren Befehl zu warten. Zur Bestätigung:

```bash
# The READY column should read 1/1.
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
