# Lab 4 · Rollout einer neuen Version und Rollback

| | |
|---|---|
| **Zeit** | 30 Minuten |
| **Was es beweist** | Eine Version lässt sich unter laufendem Datenverkehr ändern und zurücknehmen, ohne Wartungsfenster |
| **Was Sie brauchen** | Das Cluster aus Lab 0, `rickroll` aus Lab 1, Fortio aus Lab 3, drei Terminalfenster, ein Browser |

## Warum das wichtig ist

Den Dienst „Pass“ rollen Sie einmal aus, aber aktualisieren werden Sie ihn Dutzende Male. Im üblichen Schema bedeutet jede Aktualisierung: ein Fenster abstimmen, eine Samstagnacht, einen Snapshot vor dem Start und einen Menschen, der dabeisitzt und zusieht. Wenn eine Änderung so viel kostet, stauen sich Änderungen: Statt zehn kleiner Rollouts machen Sie einen großen, und der große geht bereitwilliger kaputt.

Was es kostet, klären wir hier an den Versuchskaninchen — also am Übungs-`rickroll`, nicht an „Pass“. Wir tauschen die Version der Anwendung **mitten unter Last** aus — nicht in einer ruhigen Stunde, sondern inmitten Tausender Anfragen pro Minute — und beobachten den Fehlerzähler. Danach rollen wir zurück, ebenfalls unter Last.

## Kleines Glossar

| Begriff | Was es ist | Ähnlich wie … aber |
|---|---|---|
| **RollingUpdate** | Kopien nacheinander ersetzen, nicht alle auf einmal | **VMs einzeln von Hand aktualisieren**, aber das Cluster macht es selbst und stoppt, wenn eine neue Kopie nicht hochkommt |
| **Revision** | Ein gespeicherter Schnappschuss der Anwendungsbeschreibung | **Ein VM-Snapshot**, aber er behält nur die Beschreibung — es stecken keine Daten darin |
| **maxSurge** | Wie viele Kopien über die angeforderte Zahl hinaus während des Rollouts hochgefahren werden dürfen | kein direktes Analogon; wird als Prozentsatz von `replicas` gerechnet und aufgerundet |
| **maxUnavailable** | Wie viele Kopien abgeschaltet werden dürfen, ohne auf einen Ersatz zu warten | **Wie viele VMs Sie auf einmal abschalten**, aber abgerundet, sodass es bei drei Kopien null ergibt |
| **readinessProbe** | Eine Prüfung „bereit, Datenverkehr anzunehmen“ | **Ein Health Check im Pool des Load Balancers**, aber sie bremst zugleich den Rollout, statt nur ein Mitglied aus dem Balancing zu nehmen |
| **ReplicaSet** | Ein Satz identischer Kopien, der für eine Version der Beschreibung zuständig ist | **Ein Pool identischer VMs aus einer Vorlage**, aber für jede Version wird ein eigener Satz angelegt, und der vorherige bleibt mit null Kopien daneben bestehen |
| **EndpointSlice** | Eine Liste der Adressen von Kopien, die bereit sind, Datenverkehr anzunehmen | **Eine Liste der Mitglieder des Load-Balancer-Pools**, aber das Cluster führt sie anhand von Labels, nicht der Administrator von Hand |
| **JSON Patch** | Eine punktgenaue Änderung eines einzelnen Feldes über seinen Pfad innerhalb eines Objekts | kein direktes Analogon; der Pfad zeigt auf den **Index** eines Elements in einer Liste, nicht auf seinen Namen |

## Was im Lab-Ordner liegt

Alle Dateien haben Sie bereits — Sie haben sie zusammen mit dem Repository erhalten. Es gibt nichts zu erstellen oder abzutippen: Wo unten `kubectl apply -f name.yaml` steht, wird die Datei von hier genommen.

```bash
# From here on, all commands are run from this folder: paths in `kubectl apply -f` are counted from it.
cd labs/04-rollout
```

| Datei | Was es ist | Wann es nützlich wird |
|---|---|---|
| `rickroll-page-v2.yaml` | Die zweite Version der Seite — das, was wir unter Last ausrollen | Sie wenden sie auf Ihrem Cluster `lab` an |
| `check.sh` | Eine Prüfung, dass der Rollout ohne Verlust von Anfragen durchlief | Sie führen sie am Ende des Labs aus |
| — | Den Lastgenerator nehmen wir aus dem Nachbar-Lab: `../03-scale/fortio.yaml` | |

## Schritt 1. Den Boden bereiten

📍 **Wo:** auf dem Bastion (im Bastion-Terminal).

Vor dem Rollout müssen Sie zwei Dinge tun, und keines davon ist kosmetisch.

**Die Autoskalierung schalten wir ab**, weil sie ebenfalls das Feld `replicas` steuert. Einen Rollout zu beobachten, während gleichzeitig jemand die Anzahl der Kopien ändert, ist ein garantierter Weg, nicht zu verstehen, was passiert ist. Ein Mechanismus pro Feld.

**Drei Kopien legen wir an**, damit der Austausch Stück für Stück sichtbar ist. Eine Kopie ist hier ein Pod: die kleinste Ausführungseinheit im Cluster, der Anwendungscontainer samt seiner Umgebung, das nächste Analogon zu einer einzelnen VM. Auch mit einer Kopie liefe der Rollout ohne Ausfallzeit durch, aber Sie sähen nur „es gab einen Pod, jetzt gibt es einen anderen“ und nicht die Reihenfolge, in der das Cluster sie ersetzt.

```bash
# KUBECONFIG — the file with the cluster's address and the credentials to log into it. While the
# variable is set, every kubectl command goes to the `lab` cluster, not the one it was issued from.
export KUBECONFIG=~/lab.kubeconfig

# hpa — the autoscaler set up in the scaling lab. We delete it
# so the number of copies changes only on our command.
#   --ignore-not-found  don't treat it as an error if it's no longer in the cluster
kubectl delete hpa rickroll --ignore-not-found

# scale = "keep this many copies". The number goes into the application's description,
# and the cluster then brings up the missing ones itself.
kubectl scale deployment rickroll --replicas=3

# rollout status = "wait until the requested becomes actual". The command keeps the window
# busy until all three copies are ready, and only then returns the prompt.
kubectl rollout status deployment/rickroll
```

Prüfen Sie, dass der Lastgenerator Fortio vorhanden ist:

```bash
# get = "show what's there". The reply `Error from server (NotFound)` means it isn't there.
kubectl get deployment fortio
```

Wenn es nicht da ist, fahren Sie es aus dem Nachbarordner hoch: `kubectl apply -f ../03-scale/fortio.yaml`.

## Schritt 2. Die zweite Version ins Cluster legen

📍 **Wo:** auf dem Bastion (im Bastion-Terminal).

Im Ordner liegt `rickroll-page-v2.yaml` — die Beschreibung eines Objekts vom Typ ConfigMap. Ein ConfigMap hält eine Textdatei im Cluster getrennt von der Anwendung, und das Cluster legt diese Datei dann in den Container. Hier enthält sie die Seite, die nginx ausliefert.

<details>
<summary><b>Genauer betrachtet: was in rickroll-page-v2.yaml steckt</b></summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rickroll-page-v2
data:
  index.html: |
    ...
    <div class="tag">VERSION 2</div>
    <h1>We're No Strangers To Love</h1>
    ...
    <div class="pod">served by pod<b>__POD__</b></div>
```

Darin steckt eine einzige Seite: eine andere Überschrift, ein anderes Farbschema, eine auffällige Plakette „VERSION 2“. Die Unterschiede sind bewusst ins Auge fallend gemacht — Sie werden in den Browser schauen, nicht in ein Diff.

Beachten Sie zwei Dinge.

**`__POD__` ist noch da.** Das Einsetzen des Kopiennamens erledigen die nginx-Einstellungen aus dem ConfigMap `rickroll-conf`, das beiden Versionen gemeinsam ist. Wir ändern die Seite, nicht das Verhalten des Servers.

**Der Name des Objekts ist `rickroll-page-v2`, nicht `rickroll-page`.** Das ist die zentrale Entscheidung des ganzen Labs, und es lohnt sich, auszubuchstabieren, warum.

Naheliegend wäre etwas anderes: den vorhandenen `rickroll-page-v1` nehmen und seinen Inhalt überschreiben. Ein Befehl, keine neuen Objekte. Tun Sie es nicht, und hier ist, warum.

Erstens würden Sie das Alte verlieren. Es gäbe keinen Rollback: Die vorherige Seite existiert dann nirgends mehr außer in Ihrer Datei — und wenn Sie die Änderung über `kubectl edit` gemacht haben, nicht einmal in der Datei.

Zweitens wäre die Aktualisierung unkontrolliert. Die Anwendungsbeschreibung ändert sich nicht, wenn Sie ein ConfigMap bearbeiten, das heißt das Deployment — das Objekt, das diese Beschreibung speichert (welches Image, wie viele Kopien, woher die Dateien zu nehmen sind) und über ihre Ausführung wacht — würde nichts bemerken und keinen Rollout starten. Die Dateien in den laufenden Pods würde das Cluster dennoch austauschen — von selbst, zu seinem eigenen Zeitpunkt, über etwa eine Minute und in beliebiger Reihenfolge über die Kopien hinweg. Sie bekämen eine Änderung, die nicht in der Historie steht, die sich nicht per Befehl zurückrollen lässt und die die Kopien ungleichmäßig erreicht hat.

Daher die Regel: **Versionen sind verschiedene Objekte, und eine Version umzuschalten ist eine Änderung der Anwendungsbeschreibung.** Genau so sieht es das Deployment, so landet es in der Revisionshistorie, und so lässt es sich rückgängig machen.

</details>

Wenden Sie sie an. Im Cluster erscheint ein zweites ConfigMap; die laufende Anwendung rührt es nicht an, weil noch nichts darauf verweist:

```bash
# apply = "bring the cluster to what's described in the file".
#   -f name.yaml   where to take the description from; the file is in this same folder
kubectl apply -f rickroll-page-v2.yaml
```

**Was Sie sehen sollten:** `configmap/rickroll-page-v2 created`.

Öffnen Sie nun die Anwendung und vergewissern Sie sich, dass sich **nichts geändert hat**:

```bash
# port-forward = a temporary tunnel from the bastion into the cluster.
#   svc/rickroll  where it leads: into the Service, that is, with requests spread across the copies
#   8080:80       on the left the port on the bastion, on the right the service's port inside the cluster
# While the tunnel is open the window is busy; it closes on Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> — dieselbe erste Version. Wir haben die neue Seite ins Cluster gelegt, aber die Anwendung weiß nichts davon: Ihr Volume zeigt weiterhin auf `rickroll-page-v1`. Schließen Sie den Tunnel (`Ctrl+C`), das ist noch nicht der Rollout.

## Schritt 3. Verstehen, wie das Cluster die Kopien ersetzen wird

📍 **Wo:** auf dem Bastion (im Bastion-Terminal).

Bevor wir die Version umschalten, schauen wir uns die Regeln an, nach denen der Austausch abläuft. Sie stecken in der Anwendungsbeschreibung selbst:

```bash
# -o jsonpath=... — instead of a table, print a single field of the object by giving the path to it.
#   {.spec.strategy}  the block of rules by which the cluster replaces copies
#   {"\n"}            a newline at the end, otherwise the output runs into the prompt
kubectl get deployment rickroll -o jsonpath='{.spec.strategy}{"\n"}'
```

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

Diesen Block gibt es in `rickroll.yaml` nicht — das Cluster hat die Standardwerte eingesetzt.

<details>
<summary><b>Was diese Prozente bei unseren drei Kopien bedeuten</b></summary>

Beide Zahlen werden von `replicas` gerechnet, also von drei. Und sie runden in entgegengesetzte Richtungen.

**`maxSurge: 25%`** — wie viele Kopien **über** die angeforderte Zahl hinaus hochgefahren werden dürfen, während der Austausch läuft. 25% von drei sind 0,75, und **Aufrunden** ergibt 1. Also darf das Cluster während des Rollouts vorübergehend vier Kopien haben.

**`maxUnavailable: 25%`** — wie viele Kopien gleichzeitig **nicht verfügbar** gehalten werden dürfen. 25% von drei sind dieselben 0,75, aber **Abrunden** ergibt **0**.

Null ist eine harte Einschränkung. Das Cluster darf keine einzige arbeitende Kopie abschalten, bevor ein bereiter Ersatz erschienen ist. Nicht „wird versuchen“ — darf nicht: Das ist eine Einschränkung, keine Absicht.

Daher die Reihenfolge der Schritte bei jedem Austauschschritt:

1. eine neue Kopie hochfahren (durch `maxSurge` erlaubt);
2. warten, bis ihre `readinessProbe` mit Erfolg antwortet;
3. sie zum EndpointSlice hinzufügen, also Datenverkehr auf sie schicken;
4. **erst jetzt** eine alte Kopie aus dem Balancing nehmen und abschalten;
5. wiederholen, bis keine alten Kopien mehr übrig sind.

Alles hängt am dritten und vierten Punkt, und die hängen an der `readinessProbe`. Entfernen Sie die Bereitschaftsprüfung aus dem Manifest, und das Cluster beginnt, eine Kopie im Moment des Prozessstarts als brauchbar zu behandeln. Datenverkehr geht an ein nginx, das seine Konfiguration noch nicht gelesen hat, und Sie bekommen eine Ladung 500er. Die Bereitschaftsprüfung ist hier kein Monitoring, sie ist eine **Bremse für den Rollout**, und das ist ihre Hauptaufgabe.

Eine nützliche Folgerung: Ist die neue Version so kaputt, dass sie die Bereitschaftsprüfung nicht besteht, **stoppt** der Rollout. Die alten Kopien arbeiten weiter. Das sehen wir gegen Ende des Labs, nur brechen wir es anders.

</details>

## Schritt 4. Die Last einschalten

In der Stille auszurollen macht keinen Spaß — so wurde es auch in vSphere gemacht. Schicken wir Datenverkehr und ändern die Version darunter.

📍 **Fenster 1** — ein Tunnel zu Fortio:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
# A tunnel to the load generator: port 8081 on the bastion → port 8080 of the fortio service.
# 8081 was chosen on the left so as not to collide with the tunnel to the application itself on 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **Im Browser** — <http://localhost:8081/fortio/>. Füllen Sie aus:

| Feld | Wert | Warum so |
|---|---|---|
| URL | `http://rickroll/` | der Name des Service — die stabile Adresse, hinter der alle Kopien stehen; der Datenverkehr geht durch das Balancing, nicht an einen bestimmten Pod |
| QPS | `300` | ein gleichmäßiger Hintergrund; das Maximum herauszupressen ist jetzt nicht nötig |
| Duration | `180s` | drei Minuten — das Fenster, in dem wir es schaffen, sowohl auszurollen als auch zurückzurollen |
| Connections | `20` | |

Drücken Sie **Start** und **berühren Sie den Browser bis zum Ende des Labs nicht**.

Dieselbe Last lässt sich per Befehl erzeugen, falls es mit dem Formular nicht geklappt hat:

```bash
# exec = run a command inside an already-running Pod. The load is generated not by your bastion,
# but by Fortio itself from inside the cluster, so no tunnel is needed for this.
#   deploy/fortio  in any copy of the fortio application
#   --             everything to the right is a command for the container, not for kubectl
#   -qps 300       three hundred requests per second
#   -c 20          twenty simultaneous connections
#   -t 180s        hold the load for three minutes
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **Fenster 2** — den Kopien zusehen:

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — show only Pods with this label; others won't get into the output.
# -w = "watch and append": the window stays busy and prints a new line every time
# the state of some copy changes. Exit — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## Schritt 5. Die Version umschalten

📍 **Fenster 3** — ein freies Fenster. Das erste hält den Tunnel zu Fortio, das zweite ist mit dem Beobachten der Pods belegt, daher führen wir den Patch im dritten aus. Der Zugang muss darin erneut eingerichtet werden:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
```

Jetzt ändern wir genau ein Feld in der Anwendungsbeschreibung: Das Volume namens `page` — der Ordner, der in den Container gelegt wird — muss seinen Inhalt aus dem ConfigMap `rickroll-page-v2` nehmen. Einen Befehl „aktualisiere die Anwendung“ gibt es nicht und wird es nie geben: Es gibt nur eine neue Aufzeichnung darüber, wie es sein soll. Die Abweichung vom tatsächlichen Zustand bemerkt das Cluster selbst und beginnt, die Kopien zu ersetzen.

```bash
# patch = change a field in an object pinpoint-style, without rewriting the whole object.
#   --type=json  the edit format: "operation + path + value"
#   op: replace  replace what sits at this path
#   path         the address of the field inside the object; volumes/0 — the first volume in the list (see below)
#   value        the new ConfigMap name from which the volume will take the page
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v2"}]'
```

**Was Sie sehen sollten:**

```
deployment.apps/rickroll patched
```

⚠️ **Dieser Patch ist fragil, und das muss offen gesagt werden.** Der Pfad `/spec/template/spec/volumes/0/...` adressiert das Volume **über seinen Index in der Liste**. In `rickroll.yaml` kommt das Volume `page` zuerst und `conf` als zweites — es gibt dort sogar einen Kommentar dazu. Aber wenn jemand sie vertauscht (und YAML verbietet das in keiner Weise), überschreibt derselbe Befehl ohne einen einzigen Fehler den Namen der nginx-Konfiguration, und die Anwendung geht auf rätselhafte Weise kaputt.

<details>
<summary><b>Warum wir es trotzdem so machen und wie es richtig geht</b></summary>

Wir haben JSON Patch genommen, weil er die Mechanik in Reinform zeigt: ein Befehl, ein Feld, eine sichtbare Folge. Für ein Lab ist das wertvoll.

**Sicherer** — dasselbe mit einem gewöhnlichen Merge-Patch. Listen in Kubernetes können sich über einen Schlüssel zusammenführen, und für `volumes` ist dieser Schlüssel `name`:

```bash
# Without --type=json this is a merge patch: you describe a piece of the object in the same form
# it has in the manifest, and the cluster merges it with what's already there. The volumes list merges
# by the `name` key, so here the `page` volume is addressed, not "the volume at such-and-such index".
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

Hier läuft die Adressierung über den Namen des Volumes, die Reihenfolge in der Liste spielt keine Rolle, und es gibt nichts zu verwechseln.

**Richtig** — überhaupt nicht patchen. Ein Patch ändert, wie `kubectl edit`, das Objekt im Cluster, aber nicht Ihre Datei. Eine Woche später wendet jemand `rickroll.yaml` aus dem Repository an, und die Anwendung driftet stillschweigend zurück auf die erste Version. Niemand wird verstehen, warum.

In der normalen Arbeit wird die Version so geändert: Sie ändern eine Zeile in der Datei, schicken die Änderung ins Review, und nach dem Merge wendet die Automatik sie an. Dann stimmen der Zustand des Clusters und der Inhalt des Repositorys immer überein. Genau das machen wir in Lab 5.

</details>

Sehen Sie zu, wie der Austausch läuft:

```bash
# rollout status prints the progress of the replacement line by line and finishes when all copies are updated.
# If the rollout doesn't converge, the command returns a non-zero exit code — convenient for
# stopping it in scripts.
kubectl rollout status deployment/rickroll
```

```
Waiting for deployment "rickroll" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "rickroll" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "rickroll" successfully rolled out
```

📍 **In Fenster 2** sehen Sie inzwischen, wie die Kopien Stück für Stück ausgetauscht werden: Zuerst erscheint eine neue und erreicht `1/1 Running`, und erst danach geht eine der alten in `Terminating`.

Achten Sie auf das Ende der Namen: Bei den neuen Kopien hat sich auch der mittlere Teil geändert — das ist ein anderes ReplicaSet. Das Deployment hat das alte nicht umgebaut, es hat ein zweites daneben erstellt und schüttet Kopien vom einen ins andere. Das alte ist nirgends hin verschwunden; es hat null Kopien und wartet in den Kulissen:

```bash
# rs — shorthand for ReplicaSet, a set of copies of one version of the description.
# DESIRED — how many copies are requested in this set, READY — how many of them are ready to answer.
kubectl get rs -l app=rickroll
```

```
NAME                  DESIRED   CURRENT   READY   AGE
rickroll-6f4b9c8d57   0         0         0       48m
rickroll-7c5d4f9b21   3         3         3       40s
```

## Schritt 6. Die Fehler zählen

📍 **Wo:** auf dem Bastion, in Fenster 3 — es ist nach dem vorherigen Befehl frei geworden.

Öffnen Sie einen Tunnel zur Anwendung:

```bash
# The same tunnel as at the start of the lab: port 8080 on the bastion → port 80 of the rickroll service.
kubectl port-forward svc/rickroll 8080:80
```

📍 **Im Browser** <http://localhost:8080> — die grüne Seite mit der Plakette „VERSION 2“. Aktualisieren Sie sie ein paar Mal: Der Kopienname unten ändert sich, weil der Service die Anfragen über die drei Kopien verteilt.

Schließen Sie den Tunnel (`Ctrl+C`).

📍 **Jetzt die Hauptsache — der Fortio-Tab.** Warten Sie das Ende des Durchlaufs ab und suchen Sie die Zeilen mit den Antwortcodes:

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**Null Fehler.** Die Anwendung hat ihre Version vollständig gewechselt, unter ununterbrochenem Datenverkehr, und keine einzige der vierundfünfzigtausend Anfragen kam zu Schaden.

Bezahlt haben wir das mit einem einzigen Block im Manifest — jener `readinessProbe` aus Lab 1. Ohne sie hätte das Cluster die alte Kopie aus dem Balancing genommen, bevor es sich vergewissert hätte, dass die neue bereit ist zu antworten, und diese Zeile hätte anders ausgesehen.

⚠️ **Ein paar Dutzend Fehler auf Zehntausende Anfragen statt null** ist keine kaputte Testumgebung. Das Entfernen einer Kopie aus dem Balancing und das Stoppen des Prozesses in ihr laufen parallel, und bei schnellem Datenverkehr schafft es eine Handvoll Verbindungen, in diese Lücke zu rutschen. Geheilt wird das durch eine Pause vor dem Abschalten (`preStop`) und ein sauberes Beenden der Verbindungen in der Anwendung selbst. Wir tun das im Lab bewusst nicht: Es ist nützlicher zu wissen, dass die Lücke existiert, als anzunehmen, sie schließe sich von selbst.

## Schritt 7. Zurückrollen

Starten Sie die Last in Fortio erneut (dieselben Parameter) und schauen Sie sich, während sie läuft, die Änderungshistorie an:

```bash
# history = the list of saved revisions of the description. Each line is a state you can
# return to with a single command. CHANGE-CAUSE — an optional note on why it was changed.
kubectl rollout history deployment/rickroll
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

Zwei Revisionen. Jede ist ein gespeicherter Schnappschuss der Anwendungsbeschreibung zum Zeitpunkt der Änderung. Die erste mit `rickroll-page-v1`, die zweite mit `v2`. Aufbewahrt werden sie genau deshalb, weil die alten ReplicaSets nicht gelöscht werden: standardmäßig behält das Cluster die zehn jüngsten.

Der Rollback:

```bash
# undo with no extra parameters = return to the previous revision. This isn't "rewinding
# time", it's an ordinary rollout of the old description: copies are replaced one at a time, by the same
# maxSurge and maxUnavailable rules.
kubectl rollout undo deployment/rickroll
# We wait until the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

📍 **In Fenster 2** — dieselbe Prozedur rückwärts: Drei neue Kopien kommen Stück für Stück hoch, drei aktuelle gehen. `kubectl get rs -l app=rickroll` wird zeigen, dass die Kopien ins erste ReplicaSet zurückgekehrt sind — jenes, das mit null Kopien herumhing.

📍 **Im Browser** ist die Anwendung wieder die erste Version.

📍 **In Fortio** — wieder `Code 200 ... (100.0 %)`.

**Vergleichen Sie das mit einem Rollback in vSphere.** Dort bedeutet ein Rollback die Wiederherstellung aus einem Snapshot: Die Maschine fährt herunter, die Dateien werden zurückgespielt, die Maschine bootet. Minuten der Nichtverfügbarkeit plus der Verlust von allem, was nach dem Anlegen des Snapshots geschah. Hier bedeutet ein Rollback die Rückkehr der Beschreibung zur vorherigen Revision, und er unterscheidet sich in nichts von einem gewöhnlichen Rollout: dieselben Kopien Stück für Stück, dieselbe null Ausfallzeit.

⚠️ **`CHANGE-CAUSE` ist leer, und das ist unbequem.** Die Historie behält, *was* sich geändert hat, aber nicht, *warum*. In einem Monat sagt Ihnen Revision 2 nichts. Die Ursache können Sie mit der Annotation `kubernetes.io/change-cause` eintragen, aber die wahre Antwort auf diese Frage ist keine Annotation, sondern Git, wo jede Änderung einen Autor, ein Datum und eine Commit-Nachricht hat.

## Schritt 8. Eine Prüfung, die nicht durchläuft

Der Mechanismus ist klar. Sehen wir uns nun an, was passiert, wenn ein Rollout schiefgeht — und das passiert öfter, als einem lieb ist.

Stellen Sie sich einen gewöhnlichen Morgen vor: Ein Kollege bereitet die dritte Version der Seite vor, ist in Eile und vertippt sich im Namen. Das Manifest ist dabei gültig — das Cluster ist nicht verpflichtet zu wissen, dass es ein solches Objekt nicht gibt. Reproduzieren wir genau das:

```bash
# The same patch as when switching to the second version, but with a mistake in the ConfigMap name:
# there is no object `rickroll-page-v3` in the cluster. The reference's existence isn't checked on acceptance,
# so the command will finish successfully.
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v3"}]'

# --timeout=90s — don't wait forever: not having gotten ready copies, the command gives up after a
# minute and a half and returns an error. The rollout itself won't go anywhere and will stay hanging.
kubectl rollout status deployment/rickroll --timeout=90s
```

**Was Sie sehen werden:**

```
Waiting for deployment "rickroll" rollout to finish: 0 of 3 updated replicas are available...
error: timed out waiting for the condition
```

Schauen Sie sich die Zusammensetzung der Kopien an: Drei vorherige arbeiten, die neue steckt beim Start fest.

```bash
# The READY column counts the ready containers inside the Pod: 1/1 — ready, 0/1 — not.
# STATUS says exactly where the startup stalled.
kubectl get pods -l app=rickroll
```

```
NAME                        READY   STATUS              RESTARTS   AGE
rickroll-6f4b9c8d57-4kk2p   1/1     Running             0          6m
rickroll-6f4b9c8d57-9dnvt   1/1     Running             0          6m
rickroll-6f4b9c8d57-lm7bq   1/1     Running             0          6m
rickroll-8b6a1e5c39-wr4tz   0/1     ContainerCreating   0          90s
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Hier gibt es zwei Fragen, und die zweite ist wichtiger als die erste. Erstens: Warum startet die neue Kopie nicht? Zweitens: Was passiert gerade mit dem Dienst — liegt er?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

**Warum die Kopie nicht hochkam.** Ein ConfigMap namens `rickroll-page-v3` haben wir nie erstellt — es ist nicht im Cluster. Fragen Sie das Cluster direkt:

```bash
# events — the cluster's log of occurrences, the nearest analogue of the Tasks & Events tab in vCenter.
#   --field-selector reason=FailedMount  keep only the records about a failed volume mount
#   --sort-by=.lastTimestamp             sort by time, the freshest end up at the bottom
#   | tail -3                            show the last three lines, discard the rest
kubectl get events --field-selector reason=FailedMount --sort-by=.lastTimestamp | tail -3
```

```
Warning  FailedMount  kubelet  MountVolume.SetUp failed for volume "page":
         configmap "rickroll-page-v3" not found
```

Beachten Sie: Der Befehl `kubectl patch` wurde erfolgreich beendet und druckte `patched`. Das Cluster hat eine Beschreibung angenommen, in der die Referenz ins Leere führt, und kein Wort gesagt. Eine Prüfung, ob das ConfigMap existiert, gibt es bei der Annahme des Manifests nicht — sie wäre nur im Moment des Pod-Starts möglich, was genau geschah.

**Und nun die zweite Frage, um deretwillen dieser Schritt gemacht wurde.** Öffnen Sie die Anwendung mitten im festhängenden Rollout:

```bash
# The same tunnel. Traffic will go only to the copies that passed the readiness check,
# that is, to the three old ones: the stuck one didn't make it into balancing.
kubectl port-forward svc/rickroll 8080:80
```

Es funktioniert. Die erste Version, drei Kopien, keine Fehler. Wenn bei Ihnen in diesem Moment Last in Fortio lief — der Bericht zeigt weiterhin hundert Prozent 200er.

**Ein völlig kaputter Rollout hat den Dienst nicht lahmgelegt.** Das ist eine direkte Folge von `maxUnavailable: 0`, das wir zu Beginn des Labs ausgerechnet haben: Das Cluster durfte keine einzige arbeitende Kopie abschalten, bevor es einen bereiten Ersatz bekam. Es bekam keinen Ersatz — also schaltete es auch nichts ab. Der Rollout stoppte genau dort, wo er zu brechen begann, und blieb in diesem Zustand.

**Die Lehre reicht über diesen Fehler hinaus.**

> Ein fehlgeschlagener Rollout in Kubernetes **bleibt** standardmäßig **hängen**, er bricht nicht zusammen.

Das stellt die vertraute Logik des Aktualisierens auf den Kopf. Im Schema „stoppen, aktualisieren, starten“ bedeutet jeder Fehler mittendrin Ausfallzeit, und deshalb werden Aktualisierungen nachts gemacht, mit Leuten am Telefon. Im Schema „das Neue hochfahren, sich vergewissern, umschalten“ bedeutet ein Fehler, dass das Umschalten nicht stattfand — und das Alte arbeitet weiter wie zuvor.

Daher die praktische Erkenntnis für den Bereitschaftsdienst: **Ein festhängender Rollout ist kein Incident.** Er weckt Sie nachts nicht. Man kann ihn am Morgen aufklären — oder mit einem einzigen Befehl zurückrollen und später aufklären.

Genau das machen wir jetzt.

</details>

So kommen wir heraus:

```bash
# We return the previous revision — the one where the ConfigMap name is written correctly.
kubectl rollout undo deployment/rickroll
# We wait until the stuck copy disappears and the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

Die festhängende Kopie verschwindet, und die Beschreibung kehrt zur funktionierenden zurück.

## Überprüfung

📍 **Wo:** auf dem Bastion, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

```bash
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man es installiert, steht am Anfang von Lab 0. Ohne WSL können Sie das Lab durchführen, aber es wird keinen Bericht als Artefakt geben.

Das Skript schaut auf den Kern der Sache, nicht auf die von Ihnen getippten Befehle: Die Historie der Anwendung hat mehrere Revisionen (also wurde die Version tatsächlich geändert und zurückgenommen), das ConfigMap der zweiten Version liegt im Cluster, die Anwendung antwortet über HTTP, und die von ihr ausgelieferte Seite passt zu dem ConfigMap, auf das die Beschreibung zeigt. Gesondert prüft es die `readinessProbe` — ohne sie lässt sich die null Ausfallzeit nicht reproduzieren.

## Aufräumen

Die Anwendung `rickroll` wird später gebraucht — wir löschen sie nicht. Setzen Sie sie auf eine Kopie zurück:

```bash
# Two extra copies will free up the node's memory — there won't be any load in the labs ahead.
kubectl scale deployment rickroll --replicas=1
```

Der Lastgenerator wird nicht mehr gebraucht:

```bash
# delete -f = delete exactly the objects listed in the file, and nothing besides them.
# The path leads to the neighboring folder, because the file is where the scaling lab is.
kubectl delete -f ../03-scale/fortio.yaml
```

Das ConfigMap `rickroll-page-v2` kann so bleiben, wie es ist: Es belegt ein paar Kilobyte und verbraucht weder CPU noch Speicher. Beschreibungen in Kubernetes werden in der Datenbank des Control Plane gespeichert und kosten nichts, solange nichts auf sie verweist — anders als ein Snapshot einer virtuellen Maschine, der Platz im Speicher belegt und die Maschine umso stärker verlangsamt, je länger er lebt.

## Was wir jetzt können

- Die Version einer Anwendung unter laufendem Datenverkehr ändern und am Zähler bestätigen, dass es keine Fehler gab
- Erklären, woher die null Ausfallzeit kommt: `maxUnavailable`, `readinessProbe` und die Reihenfolge
  „erst bereit, dann umschalten“
- Die Revisionshistorie lesen und mit einem einzigen Befehl zurückrollen
- Verstehen, warum Versionen als eigene Objekte gemacht werden und nicht durch Bearbeiten eines vorhandenen
- Wissen, dass ein kaputter Rollout hängen bleibt, statt den Dienst lahmzulegen, und warum das kein Incident ist

## Und in vSphere wäre das

Ein Wartungsfenster, vorab abgestimmt. Ein Snapshot vor dem Start — Minuten und Speicherplatz. Eine Aktualisierung an Ort und Stelle. Wenn es nicht abhob — eine Wiederherstellung aus dem Snapshot, weitere Minuten der Nichtverfügbarkeit. Alles nachts, weil man es tagsüber nicht darf.

Hier — ein Befehl tagsüber, unter Datenverkehr, und ein zweiter Befehl, wenn Ihnen das Ergebnis nicht gefällt.

**Wo vSphere ehrlich gesagt bequemer ist.** Drei Dinge.

Erstens und vor allem: **Ein Snapshot nimmt den gesamten Zustand, `rollout undo` nur die Beschreibung.** Wenn Ihre Anwendung während der Zeit, in der die neue Version lief, etwas in die Datenbank schreiben oder das Schema ändern konnte, gibt der Rollback den Code zurück und nicht die Daten. Sie bekommen die alte Version auf neuen Daten — manchmal ist das schlimmer, als die Dinge zu lassen, wie sie waren. Ein VM-Snapshot bewahrt Sie davor, `rollout undo` nicht. Genau deshalb werden Schemamigrationen der Datenbank so geschrieben, dass sie in beide Richtungen kompatibel sind, und das ist eine Disziplin, die Kubernetes von Ihnen verlangen wird, wo vSphere es nicht tat.

Zweitens gibt ein Rollback in vSphere absolut alles zurück: von Hand installierte Pakete, eine am Telefon gemachte Änderung an einer Konfiguration. Hier wird nur das zurückgerollt, was im Manifest beschrieben war. Alles, was jemand nebenbei gemacht hat, wird nicht zurückgerollt, weil das Cluster nichts davon weiß.

Drittens verlangt ein Snapshot nicht, dass die Anwendung in zwei Versionen gleichzeitig laufen kann. `RollingUpdate` aber schon: Während des Rollouts bedienen alte und neue Kopien die Anfragen gemeinsam, hinter einer Adresse. Sind sie untereinander inkompatibel — im Sitzungsformat, im Datenschema, im Protokoll — wird es keine null Ausfallzeit geben, es wird ein Durcheinander geben. Für Anwendungen, die dafür nicht bereit sind, gibt es die Strategie `Recreate`: alle abschalten, dann alle hochfahren. Sie verursacht Ausfallzeit, ist aber vorhersehbar, und manchmal ist es ehrlicher, sie zu wählen.
