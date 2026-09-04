# Lab 14 · Observability: den eigenen Ausschlag in den Graphen finden

| | |
|---|---|
| **Zeit** | 30 Minuten |
| **Was es zeigt** | Metriken sammeln sich selbst, kontinuierlich und rückwirkend. Ein separates Monitoring-System muss man nicht kaufen |
| **Was Sie brauchen** | Den Cluster aus Lab 0, die App aus Lab 1, abgeschlossenes Lab 3 (Last und HPA), Zugang zum Dashboard des Tenants |

## Warum das wichtig ist

Gestern um 16:40 hat „Propusk“ fünfzehn Minuten lang langsam geantwortet. Die Beschwerde kam heute um 11:00,
wie immer. Die Frage vom Management: Was war das, und wird es wieder passieren.

Der Ansatz „reproduzieren wir es jetzt und schauen es uns an“ funktioniert nicht: fremde Last von gestern
lässt sich nicht reproduzieren. Die einzige Möglichkeit zu antworten, sind **Aufzeichnungen von gestern**,
erstellt bevor überhaupt jemand gefragt hat.

In diesem Lab finden wir in den Graphen die Spuren unserer eigenen Last aus Lab 3: den CPU-Ausschlag, als der
Traffic einsetzte, und die Stufe, als die Autoskalierung Kopien hinzufügte. Besondere Vorbereitungen haben wir
dafür nicht getroffen — die Aufzeichnungen sind bereits vorhanden.

## Mini-Glossar

| Begriff | Was es ist | Ähnlich wie… aber |
|---|---|---|
| **Metrik** | Eine Zahl, die regelmäßig erhoben wird: wie viel CPU, Speicher, wie viele Requests | **ein Zähler in den vCenter-Graphen**, aber als Verlauf gespeichert statt als letzter Wert |
| **Label** | Ein Paar „name=wert“ auf einer Metrik: Pod, namespace, Cluster | **das Objekt, an das ein Zähler gebunden ist**, aber es gibt viele Labels, und nach jedem von ihnen kann man schneiden und gruppieren |
| **Zeitreihe** | Eine einzelne Metrik mit einem einzelnen Satz an Labels, über die Zeit | **ein einzelner Graph in vCenter**, aber jede Kombination von Labels ist eine eigene Reihe, und davon gibt es Tausende |
| **Scrape** | Erfassung: ein Agent fragt die Quellen alle N Sekunden ab | **die Zählererfassung in vCenter**, aber ein Agent zieht die Daten, statt dass die Anwendung sie pusht |
| **PromQL** | Die Abfragesprache für Metriken | es gibt kein direktes Analogon: in vCenter wählen Sie einen Zähler, hier schreiben Sie einen Ausdruck |
| **VictoriaMetrics** | Der Speicher, in dem die gesammelten Metriken abgelegt werden | **die Statistikdatenbank von vCenter**, aber sie versteht die Abfragesprache von Prometheus, obwohl sie selbst nicht Prometheus ist |
| **Grafana** | Die Oberfläche zu Metriken und Logs | **der Performance-Tab**, aber ein eigenes Produkt; Dashboards werden von Hand geschrieben oder fertig übernommen |
| **Retention** | Wie lange der Verlauf aufbewahrt wird | **die Statistikstufen in vCenter**, aber über einen Parameter festgelegt; standardmäßig 3 Tage und 14 Tage in zwei getrennten Speichern |
| **Logs** | Die Zeilen, die eine Anwendung schreibt | **Logs im Gast-Betriebssystem**, aber zentral gesammelt, mit eigener Abfragesprache, nicht PromQL |
| **Pod** | Die kleinste Ausführungseinheit: ein Container oder mehrere, immer auf einem einzigen Node | **eine virtuelle Maschine**, aber wegwerfbar: statt sie neu zu starten, wird sie unter einem neuen Namen neu erstellt |
| **Namespace** | Eine Unterteilung innerhalb des Clusters: gleiche Namen in verschiedenen namespaces kollidieren nicht | **ein Ordner im vCenter-Inventar**, aber er teilt außerdem Rechte, Quotas und Netzwerkrichtlinien auf |
| **Tenant** | Ihr Ausschnitt der Plattform: dort steht Grafana, und dorthin fließen die Metriken des Clusters | **ein Resource Pool mit eigenen Rechten**, aber er vergibt außerdem fertige Services, nicht nur Ressourcen |

### Metriken und Logs — warum das verschiedene Dinge sind

Ständig werden sie in einen Topf geworfen, und dann sucht man in den Logs nach etwas, das es nur in den Metriken gibt.

| | Metriken | Logs |
|---|---|---|
| Was sie sind | Zahlen in regelmäßigen Abständen | Zeilen im Moment eines Ereignisses |
| Beispiel | „um 16:41:30 verbrauchte der Pod 240 Millicores“ | „16:41:31 ERROR connection refused“ |
| Wie viel Platz | wenig, und das Volumen ist vorhersehbar | viel, und das Volumen hängt davon ab, wie gesprächig die Anwendung ist |
| Wie lange sie aufbewahrt werden | Wochen und Monate | Tage |
| Welche Frage sie beantworten | „wie viel und wann“ | „was genau passiert ist“ |
| Abfragesprache | PromQL | LogsQL (in Grafana ist das eine separate Datenquelle) |

Sie arbeiten als Paar: **die Metriken finden Ihnen den Moment, die Logs finden Ihnen die Ursache.** Der Graph
zeigte einen Ausschlag um 16:41 — Sie gehen für diese Minute in die Logs. Umgekehrt funktioniert es nicht: in
den Logs nach „wann es schlecht wurde“ zu suchen, kann ewig dauern.

### Warum Metriken kontinuierlich erhoben werden und nicht auf Abruf

Das ist der wichtigste Unterschied zwischen Monitoring und Diagnose, und es lohnt sich, ihn klar auszusprechen.

Auf Abruf zu sammeln ist **physikalisch** unmöglich: bis die Frage gestellt wird, ist das Ereignis bereits vorbei.
Kein System zeigt Ihnen die Last von gestern Abend, wenn sie gestern Abend niemand aufgezeichnet hat.

Deshalb fragt der Agent alles ohne Unterschied alle 30 Sekunden ab und legt es in den Speicher. Ja,
99 % dieser Zahlen wird sich nie jemand ansehen. Der Preis für diese 99 % sind ein paar Gigabyte Festplatte.
Der Preis für das fehlende eine Prozent ist „wir wissen nicht, was war, und wir werden es nie erfahren“.

⚠️ **Die Kehrseite, die man vorab kennen sollte.** Kontinuierliche Erfassung bedeutet kontinuierliche
Kosten: der Agent belegt CPU und Speicher, und der Speicher wächst. Auf einem großen Cluster werden Metriken
zu einem spürbaren Posten im Verbrauch, und man muss sie ausdünnen: die Retention verkürzen,
überflüssige Labels wegwerfen, die Erfassung selten genutzter Metriken abschalten. Das ist reguläre
Betriebsarbeit, und sie tritt nicht im ersten Monat auf, aber sie tritt auf.

## Was im Lab-Ordner liegt

Alle Dateien haben Sie bereits — Sie haben sie zusammen mit dem Repository erhalten. Es gibt nichts neu zu
erstellen oder erneut abzutippen: wo unten `kubectl apply -f name.yaml` steht, wird die Datei von hier genommen.

```bash
# in den Ordner dieses Labs wechseln: alle relativen Pfade unten werden von hier aus gezählt
cd labs/14-observability
```

| Datei | Was es ist | Wann es nützlich ist |
|---|---|---|
| `check.sh` | Prüft, dass Metriken gesammelt werden und die Graphen antworten | Sie führen es am Ende des Labs aus |
| — | Dieses Lab hat keine eigenen Manifeste: Last und Autoskalierung nehmen wir aus Lab 3 — `../03-scale/` | |

## Schritt 1. Sicherstellen, dass überhaupt Metriken gesammelt werden

📍 **Wo:** auf dem Bastion (im Bastion-Terminal).

Der `lab`-Cluster gibt seine Metriken nicht von selbst nach außen, sondern über das Add-on
`Monitoring agents`. Prüfen Sie, ob es aktiviert ist:

```bash
# KUBECONFIG — die Variable, aus der kubectl die Adresse des Clusters erfährt und unter
# wem es sich anmeldet. Die Datei ~/lab.kubeconfig haben Sie gespeichert, als Sie den `lab`-Cluster erstellt haben.
# Sie muss in jedem neuen Terminalfenster erneut gesetzt werden.
export KUBECONFIG=~/lab.kubeconfig

# get pods = „zeig mir, welche Pods es gibt".
#   -n cozy-monitoring   nicht im ganzen Cluster suchen, sondern in diesem namespace: genau
#                        dorthin legt das Add-on seine Collectors.
kubectl get pods -n cozy-monitoring
```

**Wenn Sie `vmagent` und `fluent-bit` in der Liste sehen** — alles ist vorhanden, machen Sie weiter.

⚠️ **Achten Sie auf die Namen, nicht darauf, ob die Liste leer ist.** Der namespace `cozy-monitoring`
existiert immer: dorthin legt die Plattform auch `metrics-server`, und der wird auf jedem
Cluster mit eigenem etcd installiert und hängt nicht vom Add-on ab. Mit anderen Worten: eine
`metrics-server`-Zeile zu sehen und daraus zu schließen, dass die Metrikerfassung eingeschaltet ist, ist ein
klassischer Fehler, und er zeigt sich erst in Grafana, wo alles leer sein wird.

**Wenn die Liste `metrics-server`, aber weder `vmagent` noch `fluent-bit` enthält:**

```
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-7d4b8c9f5-x2klm    1/1     Running   0          3d
```

Das bedeutet, das Add-on ist aus, und Sie haben keine Aufzeichnungen der Vergangenheit. Das ist übrigens eine
genaue Illustration des vorigen Abschnitts: die Erfassung lässt sich nicht rückwirkend einschalten.

Aktiviert wird es im Dashboard: `Kubernetes` → `lab` → bearbeiten → im Abschnitt Addons `Monitoring agents`
anhaken. Das Add-on ist in ein paar Minuten oben, aber **Metriken beginnen sich erst ab diesem Moment
anzusammeln** — den Ausschlag aus Lab 3 finden Sie nicht mehr.

Also müssen Sie den Ausschlag erneut erzeugen. Beachten Sie, dass die Aufräumarbeiten in Lab 3 die
Autoskalierung entfernt haben und die in Lab 4 den Lastgenerator, deshalb müssen Sie beide zurückbringen:

```bash
export KUBECONFIG=~/lab.kubeconfig          # dieselbe Zugangsdatei wie oben

# apply = „bring den Cluster in den Zustand, der in der Datei beschrieben ist". Beide Dateien liegen im
# Ordner des Nachbar-Labs, deshalb beginnt der Pfad mit `../` — sie erneut abzutippen ist nicht nötig.
kubectl apply -f ../03-scale/hpa.yaml       # die Autoskalierungsregel für rickroll
kubectl apply -f ../03-scale/fortio.yaml    # der Lastgenerator

# rollout status = „halt das Terminal und sag mir, wann der Rollout fertig ist".
# deployment/fortio — der Objekttyp und sein Name. Der Befehl gibt die Eingabeaufforderung
# mit der Zeile `successfully rolled out` zurück, sobald der Generator oben ist.
kubectl rollout status deployment/fortio
```

Warten Sie, bis `kubectl get hpa rickroll` statt `<unknown>` einen Prozentwert anzeigt; `hpa` ist
die Kurzform von `HorizontalPodAutoscaler`, dem Autoskalierungsobjekt. Das dauert ein paar
Minuten. Leiten Sie dann den Port des Generators weiter und geben Sie dieselbe Last wie in Lab 3, sonst
erscheint die Autoskalierungsstufe nicht:

```bash
# port-forward = einen Tunnel vom Bastion in den Cluster graben. Während der Befehl läuft,
# landet eine Anfrage an localhost:8081 im Lastgenerator.
#   svc/fortio    das Ziel: der Service (nicht der Pod) namens fortio
#   8081:8080     links der Port auf Ihrem Bastion, rechts der Port innerhalb des Service
# Schließen Sie das Fenster nicht: der Tunnel lebt genau so lange, wie der Befehl läuft.
kubectl port-forward svc/fortio 8081:8080
```

Unter <http://localhost:8081/fortio/>: **URL** `http://rickroll/`, **QPS** `1200`,
**Duration** `90s`, **Connections** `80`. Kommen Sie ein paar Minuten nach dem Ende hierher zurück — die
Daten werden da sein.

⚠️ Um nicht in diese Situation zu geraten, aktivieren Sie `Monitoring agents` gleich beim Erstellen des
Clusters — in Lab 0 ist das eine eigene Zeile in der Parametertabelle.

<details>
<summary><b>Was genau dort läuft und wohin das Gesammelte geht</b></summary>

Im namespace `cozy-monitoring` Ihres Clusters laufen:

| Wer | Was es tut |
|---|---|
| `vmagent` | fragt die Metrikquellen alle 30 Sekunden ab und schickt das Gesammelte an den Tenant |
| `kube-state-metrics` | verwandelt den Zustand von Cluster-Objekten in Metriken: wie viele Replikas, in welchem Zustand die Pods sind |
| `node-exporter` | Metriken des Nodes selbst: CPU, Speicher, Disk, Netzwerk |
| `fluent-bit` | sammelt Container-Logs und schickt sie an den Tenant |
| `metrics-server` | **nicht Teil des Monitorings**: wird zusammen mit dem Cluster installiert und liefert die aktuellen Zahlen für `kubectl top` und die Autoskalierung. Er speichert nichts und ist an der Metrikerfassung nicht beteiligt |

Beachten Sie: **hier gibt es keinen Speicher**. Alles Gesammelte wird sofort über das Netzwerk an den
Tenant geschickt, in den gemeinsamen Metrikspeicher neben Grafana. Das ist Absicht: der `lab`-Cluster ist eine
wegwerfbare Sache — Sie werden ihn löschen, aber die Aufzeichnungen darüber, wie er sich verhalten hat, müssen
diese Löschung überleben.

Um die Adresse zu sehen, an die der Collector seine Daten schickt:

```bash
# get vmagent = „zeig mir das Collector-Objekt". Statt der üblichen Tabelle fragen wir ein einzelnes
# Feld aus seiner Beschreibung ab — die Syntax -o jsonpath funktioniert mit jedem Cluster-Objekt:
#   .items[0]                  der erste (und hier einzige) gefundene Collector
#   .spec.remoteWrite[0].url   die Adresse, an die er die Metriken übergibt
#   {"\n"}                     ein Zeilenumbruch, sonst klebt die Ausgabe an der Eingabeaufforderung
kubectl get vmagent -n cozy-monitoring \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}{"\n"}'
```

```
http://vminsert-shortterm.tenant-workshopXX.svc.cozy.local:8480/insert/0/prometheus
```

Die Adresse zeigt in Ihren Tenant. Es ist derselbe Mechanismus, mit dem die virtuelle Maschine aus Lab 12
mit der Anwendung sprach: ein gewöhnliches Netzwerk zwischen gewöhnlichen Adressen.

</details>

## Schritt 2. Grafana des Tenants öffnen

📍 **Wo:** im Browser.

Die Adresse ist die Subdomain `grafana` Ihres Tenant-Hosts:

```
https://grafana.<Ihr Tenant-Host>
```

Die genaue Adresse ist im Dashboard notiert: Ihr Tenant → die App `Monitoring` → der Tab
`Ingress`. Ein Ingress ist eine Regel zur Veröffentlichung eines Service nach außen unter einem Domainnamen; das
nächste Analogon ist ein Eintrag auf einem Load Balancer, nur innerhalb desselben Clusters beschrieben. Dort liegt
die Adresse vollständig, samt Hostname.

Ein zweiter Ort ist die Ausgabe von `check.sh` aus genau diesem Lab: die Zeile „Grafana für Ihre Metriken“.
Das Skript zieht die Adresse aus demselben Ingress, sodass Sie sie nicht von Hand eintippen müssen.

⚠️ **Wenn es in Ihrem Tenant keine App `Monitoring` gibt** — dann haben Sie auch keine eigene Grafana, und
die Metriken gehen in das Monitoring des übergeordneten Tenants. Der zuverlässige Weg ist, `Monitoring`
aus dem Katalog zu deployen (Abschnitt `Administration`): die Adresse erscheint dann auf dem Tab `Ingress` Ihrer
eigenen App, und alle Abfragen unten funktionieren. `check.sh` findet auch fremdes Monitoring und
nennt den namespace, in dem es läuft, aber öffnen können Sie es nur, wenn Sie Zugang zu diesem namespace haben.

**Womit Sie sich anmelden.** Der Login ist `admin`. Das Passwort liegt im Secret `grafana-admin-password`:
Dashboard → die App `Monitoring` → der Tab `Secrets` → der Schlüssel `password` → `Reveal`.

Als Tenant gibt Ihnen `kubectl` keinen Zugriff auf dieses Secret (Core-Secrets sind für Sie nicht sichtbar), gehen Sie also über das Dashboard.

Wenn Ihr Monitoring das des übergeordneten Tenants ist, ist dieses Secret für Sie unerreichbar — dann deployen
Sie entweder Ihre eigene App `Monitoring` wie oben beschrieben, oder bitten Sie denjenigen um Zugang, der die
Testumgebung betreibt.

Sobald Sie drin sind, öffnen Sie **Explore** — das ist der Bereich für einmalige Abfragen, ohne Dashboards zu speichern.
Wählen Sie im Dropdown der Datenquellen **`vm-shortterm`** (die auch die Voreinstellung ist).

⚠️ **Schalten Sie das Abfragefeld in den Modus `Code`.** Grafana öffnet Explore im Builder
(`Builder`) — ein Formular mit Dropdowns, in das sich der Abfragetext nirgends eintippen lässt.
Der Umschalter `Builder | Code` befindet sich rechts über dem Eingabefeld. Alle Abfragen unten
werden in `Code` eingegeben.

<details>
<summary><b>Was die Datenquellen in der Liste sind</b></summary>

| Quelle | Was drin ist | Behält |
|---|---|---|
| `vm-shortterm` | hochaufgelöste Metriken | 3 Tage |
| `vm-longterm` | dieselben Metriken, ausgedünnt | 14 Tage |
| `vlogs-generic` | Container-Logs | 1 Tag |

Zwei Metrikspeicher statt einem sind ein Kompromiss zwischen Auflösung und Volumen.
Einen Vorfall untersuchen Sie mit `shortterm`, wo Sie alle 30 Sekunden sehen können. Die Frage
„wie hat es sich vor zwei Wochen verhalten“ beantworten Sie mit `longterm`, wo die Auflösung
gröber, dafür die Tiefe größer ist.

Genau dieselbe Logik wie bei den Statistikstufen in vCenter, wo Daten im 20-Sekunden-Intervall
einen Tag und stündliche Daten ein Jahr leben.

⚠️ **`vlogs-generic` sind Logs, und die Abfragesprache ist dort eine andere.** PromQL funktioniert darin nicht,
und das ist kein Fehler: Logs haben ihre eigene Grammatik. Verschwenden Sie keine Zeit damit, die Quelle
umzuschalten und dieselbe Abfrage einzufügen.

</details>

⚠️ **Fertige Pod-Dashboards gibt es in der Tenant-Grafana nicht.** In der Liste finden Sie Dashboards für
Datenbanken, Ingress und Queues — die Dinge, die zu Managed Services gehören. Dashboards auf der Ebene
„Pods und Nodes“ gehören nicht zum Tenant-Satz. Deshalb arbeiten wir von hier an in Explore und schreiben
Abfragen von Hand. Das ist weniger bequem als der fertige Performance-Tab in vCenter, und es hat keinen
Sinn, so zu tun, als wäre es anders.

## Schritt 3. Ihre Pods finden

📍 **Wo:** in Grafana, Explore, Quelle `vm-shortterm`.

Beginnen wir mit der gröbsten Frage: welche Pods überhaupt im Cluster sichtbar sind. Die Abfrage ist kurz, aber
sie hat drei unbekannte Teile — klappen Sie die Aufschlüsselung auf, bevor Sie sie eingeben.

<details>
<summary><b>Die Abfrage Teil für Teil aufschlüsseln</b></summary>

```promql
container_cpu_usage_seconds_total
```

Der Name der Metrik. Es ist ein Zähler: wie viele Sekunden CPU-Zeit der Container
seit seinem Start verbraucht hat. Er steigt nur — bis der Container neu startet, danach
beginnt er bei null.

Für sich genommen ist er nutzlos: „der Pod hat 4718 Sekunden CPU verbraucht“ sagt nichts aus.
Nützlich wird diese Metrik nach `rate()`, zu dem wir im nächsten Schritt kommen.

```promql
{cluster="kubernetes-lab", namespace="default"}
```

Ein Filter nach Labels. Beide Labels sind hier wichtig.

`cluster` — der Name Ihres Clusters, wie die Plattform ihn kennt. Er ist **nicht gleich** `lab`:
die Anwendung heißt `lab`, aber das Release, mit dem sie deployt ist, heißt `kubernetes-lab`, und in
die Labels gelangt der Name des Release. Das ist die erste Falle, über die alle stolpern. Um zu prüfen, wie
Ihrer heißt: löschen Sie den Wert und sehen Sie, was die Autovervollständigung von Grafana vorschlägt.

Das Label wird gebraucht, weil ein einziger Speicher die Metriken **aller** Ihrer Cluster und
Managed Services enthält. Ohne den Filter bekommen Sie eine Mischung aus allem im Tenant.

`namespace` — der namespace **innerhalb** des `lab`-Clusters. Die App aus dem ersten Lab wurde nach
`default` deployt, deshalb hier `default`. Verwechseln Sie ihn nicht mit dem namespace des Tenants
(`tenant-workshopXX`) — das sind verschiedene Dinge in verschiedenen Clustern. Der namespace des Tenants liegt im
Label `tenant`.

```promql
count by (pod) ( ... )
```

Nach dem Label `pod` gruppieren und zählen, wie viele Reihen in jede Gruppe gefallen sind. Uns
interessieren nicht die Zahlen selbst, sondern die Liste der sich ergebenden `pod`-Werte.

</details>

```promql
# count by (pod) — die gefundenen Reihen nach dem Label pod aufteilen und zählen, wie viele Reihen
# in jeder Gruppe sind. Die Zahlen selbst sind egal: gewollt ist die Liste der Pod-Namen, die sich ergibt.
count by (pod) (
  # der Name der Metrik — der Zähler der Container-CPU-Zeit
  container_cpu_usage_seconds_total{
    cluster="kubernetes-lab",   # Ihr Cluster: hier der Name des Release, nicht der App-Name lab
    namespace="default"         # der namespace innerhalb des lab-Clusters, in dem rickroll deployt ist
  }
)
```

**Was Sie sehen sollten:** schalten Sie die Ansicht von Graph auf **Table** um — so liest sich die Liste
besser. In der Tabelle stehen `rickroll-...`, `fortio-...` und, falls Sie Lab 11 gemacht haben,
`propusk-build-...`.

## Schritt 4. Den CPU-Ausschlag finden

Der Zähler aus dem vorigen Schritt lässt sich in seiner rohen Form nicht lesen. Verwandeln wir ihn in eine Größe,
die Sie mit dem request des Pods und mit dem, was `kubectl top` anzeigt, vergleichen können — in verbrauchte Cores.
Was `rate()` dabei tut und woher die zwei zusätzlichen Bedingungen in der Abfrage kommen, steht in der Aufschlüsselung unten;
klappen Sie sie auf, bevor Sie tippen.

<details>
<summary><b>Die Abfrage Teil für Teil aufschlüsseln</b></summary>

```promql
rate( ... [2m])
```

`rate` nimmt einen Zähler und berechnet **seine Wachstumsrate pro Sekunde**, gemittelt über ein Fenster von zwei
Minuten. Für eine CPU-Zeit-Metrik ergibt das eine sehr praktische Größe: „wie viele
Sekunden CPU pro Sekunde", also wie viele Cores verbraucht wurden. `0.24` bedeutet 24 % eines Cores,
also `240m` in Millicores.

Das Fenster `[2m]` ist ein Kompromiss. Ein kleineres Fenster (`[30s]`) — der Graph ist zappelig und reißt bei
spärlichen Daten ab. Ein größeres (`[5m]`) — der Ausschlag verschmiert und ein niedriger Peak kann ganz verschwinden.
Beginnen Sie mit `[2m]` und passen Sie von dort an.

⚠️ **Das Fenster muss mindestens doppelt so groß sein wie das Erfassungsintervall.** Erfasst wird alle 30 Sekunden,
also lässt sich nichts unter `[1m]` setzen — nur ein Punkt fiele in das Fenster, und aus einem einzelnen Punkt lässt
sich keine Rate berechnen, sodass der Graph leer wird. Das ist die häufigste Ursache für „bei mir zeichnet
sich nichts".

```promql
pod=~"rickroll-.*"
```

`=~` — ein Vergleich per regulärem Ausdruck statt einer exakten Übereinstimmung. Eine exakte taugt hier nicht:
Pod-Namen enthalten einen zufälligen Anhang und ändern sich bei jeder Neuerstellung.

```promql
container!=""
```

Reihen ohne Container-Namen verwerfen. Solche Reihen gibt es: sie sind ein Aggregat über den ganzen Pod,
und wenn Sie sie nicht verwerfen, wird jeder Pod doppelt gezählt und der Graph zeigt genau das Doppelte
der Wahrheit. Noch eine klassische Falle.

```promql
sum by (pod) ( ... )
```

Alles, was übrig ist, nach Pod summieren. Ein Pod kann mehrere Container haben; uns
interessiert der Pod als Ganzes.

</details>

```promql
# rate(...[2m]) — die Wachstumsrate des Zählers pro Sekunde, gemittelt über ein 2-Minuten-Fenster.
# Für CPU-Zeit liest es sich als „wie viele Cores verbraucht wurden":
# 0.24 — vierundzwanzig Prozent eines Cores, also 240m.
sum by (pod) (     # die Container des Pods summieren: eine Linie pro Pod, nicht pro Container
  rate(container_cpu_usage_seconds_total{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*",  # =~ Vergleich per regulärem Ausdruck: der Anhang des Pod-Namens ist zufällig
    container!=""        # die Gesamtreihen über den ganzen Pod verwerfen, sonst verdoppelt sich alles
  }[2m])
)
```

Setzen Sie den Zeitbereich auf die Zeit, in der Sie Lab 3 gemacht haben — zum Beispiel die letzten 3 Stunden.

**Was Sie sehen sollten:** eine flache Linie direkt bei null, dann ein steiler Anstieg für die Dauer der
Last, dann ein Rückgang nach unten. Wenn mehrere Replikas entstanden sind, gibt es mehrere Linien, und
sie erscheinen nicht alle auf einmal, sondern nach und nach, während die Pods erstellt werden.

## Schritt 5. Die Autoskalierungsstufe finden

Den Ausschlag haben wir gefunden. Jetzt sehen wir uns an, wie der Cluster darauf reagiert hat: wie viele Kopien der
Anwendung er zu jedem Zeitpunkt laufen ließ und wie viele er laufen lassen wollte. Das sind zwei verschiedene Zahlen, und
der Unterschied zwischen ihnen ist das Interessanteste an diesem Schritt. Woher sie kommen, steht in der Aufschlüsselung unten.

<details>
<summary><b>Woher diese Metriken kommen und wie sich desired von current unterscheidet</b></summary>

Diese Metriken kommen nicht von der Anwendung, sondern von `kube-state-metrics` — es liest Cluster-Objekte
über die API und verwandelt ihre Felder in Zahlen. Das Label `horizontalpodautoscaler` ist der Name des
HPA-Objekts (`HorizontalPodAutoscaler`, jene Autoskalierungsregel aus Lab 3), das
Label `deployment` ist der Name des Deployment, also der Beschreibung „halte so und so viele
Kopien der Anwendung", und so weiter für jeden Objekttyp.

`desired` — wie viele Kopien die Autoskalierung gerade **will**, berechnet aus der
Last. `current` — wie viele **tatsächlich** laufen. Zwischen ihnen gibt es immer eine Lücke:
Pods werden nicht sofort erstellt.

Wenn `desired` lange über `current` bleibt, heißt das, die Kopien werden nicht erstellt. Die Ursache ist
fast immer dieselbe: auf den Nodes ist nicht genug Platz, und die neuen Pods hängen in `Pending`. Genau die Situation,
in die Sie in Lab 11 geraten sind.

Nützlich daneben:

```promql
# wie viele rickroll-Kopien insgesamt erstellt wurden
kube_deployment_status_replicas{cluster="kubernetes-lab", deployment="rickroll"}
# wie viele davon die Bereitschaftsprüfung bestanden haben und bereits Traffic annehmen
kube_deployment_status_replicas_available{cluster="kubernetes-lab", deployment="rickroll"}
```

Die Divergenz zwischen ihnen während eines Rollouts einer neuen Version ist genau jene Pause, während die
neue Kopie ihre Bereitschaftsprüfung durchläuft.

</details>

```promql
# ..._status_current_replicas — wie viele rickroll-Kopien gerade jetzt laufen.
# Die Zahl kommt nicht von der Anwendung, sondern vom HPA-Objekt, gelesen von kube-state-metrics.
kube_horizontalpodautoscaler_status_current_replicas{
  cluster="kubernetes-lab",             # nur Ihr lab-Cluster
  horizontalpodautoscaler="rickroll"    # der Name des Autoskalierungsobjekts aus Lab 3
}
```

und daneben, als zweite Abfrage:

```promql
# ..._status_desired_replicas — wie viele Kopien die Autoskalierung jetzt haben will,
# ausgehend von der Last. Dass current hinter desired zurückbleibt, ist genau die Erstellungszeit der Pods.
kube_horizontalpodautoscaler_status_desired_replicas{
  cluster="kubernetes-lab",
  horizontalpodautoscaler="rickroll"
}
```

**Was Sie sehen sollten:** eine gestufte Linie. Erst eins, dann drei, dann fünf oder
sechs, dann — mit einer Verzögerung von etwa einer Minute nach dem Abklingen der Last — wieder hinunter.

Legen Sie sie über den Graphen des CPU-Verbrauchs aus dem vorigen Schritt: in Explore wird eine zweite
Abfrage mit der Schaltfläche `+ Add query` hinzugefügt. Sie sehen, dass die Stufe **hinter** dem Ausschlag herläuft, mit
einem Verzug von mehreren Dutzend Sekunden: erst stieg die CPU, dann bemerkte die
Autoskalierung es und reagierte. Das ist die Antwort auf die Frage „warum die Benutzer die Verlangsamung
doch bemerken konnten".

## Schritt 6. Dasselbe mit den Augen der Autoskalierung betrachten

Die Autoskalierung schaut nicht auf den absoluten Verbrauch, sondern auf den **Anteil an `requests`**.
`requests` ist die Ressourcenanforderung eines Pods: wie viel CPU und Speicher der Scheduler für ihn auf einem Node
reserviert, unabhängig davon, ob der Pod diese Ressourcen nutzt oder nicht.
Das nächste Analogon ist eine reservation in vSphere.

Sehen wir uns genau die Größe an, auf deren Basis die Entscheidung getroffen wird. Die Abfrage besteht aus zwei
durch ein Divisionszeichen getrennten Teilen: oben der tatsächliche Verbrauch, unten die Anforderung.

```promql
# Der obere Teil — der tatsächliche CPU-Verbrauch des Pods. Dieselbe Abfrage wie oben.
sum by (pod) (
  rate(container_cpu_usage_seconds_total{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*", container!=""
  }[2m])
)
/
# Der untere Teil — wie viel der Pod angefordert hat. Das Ergebnis der Division ist der Anteil an der Anforderung: 1 bedeutet
# „verbraucht genau so viel, wie es angefordert hat", 0.5 — die Hälfte des Angeforderten.
sum by (pod) (
  kube_pod_container_resource_requests{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*",
    resource="cpu"     # die Metrik hat auch Reihen für Speicher — wir behalten nur CPU
  }
)
```

**Was Sie sehen sollten:** eine Linie, die fast die ganze Zeit niedrig verläuft und für die Dauer der
Last ansteigt. Ein Wert von eins auf diesem Graphen bedeutet „der Pod verbraucht genau so viel, wie er
angefordert hat".

In `hpa.yaml` aus Lab 3 steht `averageUtilization: 50`, und in `rickroll.yaml` —
`requests.cpu: 20m`. Das heißt, die Auslöseschwelle liegt bei 10 Millicores pro Pod, was auf dem Graphen die
Marke `0.5` ist. Finden Sie den Moment, in dem die Linie sie überschritten hat, und gleichen Sie ihn mit der Stufe aus dem
vorigen Schritt ab: dazwischen liegen genau jene Dutzend Sekunden.

⚠️ Die Division zweier Ausdrücke in PromQL funktioniert über die Übereinstimmung **aller** Labels. Hier passt es,
weil beide Teile `by (pod)` gruppiert sind und nach der Gruppierung keine anderen Labels übrig bleiben.
Wären die Label-Sätze unterschiedlich, käme das Ergebnis leer heraus — ohne Fehler und ohne Warnung, ein leerer
Graph. Das ist die tückischste Eigenschaft der Sprache.

## Schritt 7. Drei Abfragen für den täglichen Gebrauch

Diese sollten Sie sich speichern — sie decken den Großteil der alltäglichen Fragen ab.

**Wer im Cluster am meisten CPU verbraucht, Top 10:**

```promql
# topk(10, ...) — nur die zehn Reihen mit den größten Werten behalten.
# Die Gruppierung by (namespace, pod) fügt der Antwort den namespace hinzu: man sieht, wessen Pod es ist.
# Das Fenster [5m] ist breiter als in den vorigen Schritten: wir wollen nicht die Form des Ausschlags, sondern das Durchschnittsniveau.
topk(10,
  sum by (namespace, pod) (
    rate(container_cpu_usage_seconds_total{cluster="kubernetes-lab", container!=""}[5m])
  )
)
```

**Speicher pro Pod (kein Zähler, deshalb ohne `rate`):**

```promql
# container_memory_working_set_bytes — kein Zähler, sondern ein Momentanwert: so viele Bytes
# sind in diesem Moment belegt. rate() ergäbe hier Unsinn — „Bytes pro Sekunde".
sum by (pod) (
  container_memory_working_set_bytes{
    cluster="kubernetes-lab", namespace="default", container!=""
  }
)
```

⚠️ Und zwar `working_set`, nicht `container_memory_usage_bytes`. Letzteres schließt den Datei-Cache
ein, den der Kernel unter Druck hergibt, und erschreckt deshalb regelmäßig Leute mit Zahlen, die nichts
mit dem realen Bedarf der Anwendung zu tun haben. Die Entscheidung, einen Pod wegen Speicher
zu killen, wird ebenfalls auf Basis von `working_set` getroffen.

**Wie viel Ressourcen reserviert sind gegenüber dem, was tatsächlich genutzt wird:**

```promql
# sum ohne by — alles zu einer einzigen Zahl addieren: wie viel CPU für alle
# Pods des Clusters reserviert ist. Das ist die Anforderung, nicht der Verbrauch: was reserviert ist und ungenutzt bleibt,
# geht ebenfalls in die Summe ein.
sum(kube_pod_container_resource_requests{cluster="kubernetes-lab", resource="cpu"})
```

Vergleichen Sie diese Zahl mit der Summe aus der ersten Abfrage. Der Unterschied zwischen „reserviert“ und
„genutzt“ ist das, wofür Sie zahlen, ohne etwas dafür zu bekommen. Dasselbe Gespräch wie über
reservations in vSphere, nur sieht man es hier auf einem Graphen.

Falls Sie Lab 11 gemacht haben, sehen Sie sich bei der Gelegenheit den Android-Build an — er ist gut zu sehen:

```promql
# Dasselbe rate, aber ein Filter auf die Build-Pods. sum ohne by (pod) — eine Linie für den ganzen Build,
# wie viele Pods er auch hochfährt.
sum(rate(container_cpu_usage_seconds_total{
  cluster="kubernetes-lab", pod=~"propusk-build-.*", container!=""
}[2m]))
```

Zwanzig Minuten flaches Plateau bei anderthalb bis zwei Cores, dann ein Abfall auf null. So sieht ein
Job auf einem Graphen aus — eine einmalige Aufgabe, die die Arbeit bis zum Ende durchzieht und dann fertig ist. Anders als
eine Anwendung, die man dauerhaft laufen lässt, hat seine Linie ein Ende.

## Schritt 8. Einen Blick in die Logs werfen

Schalten Sie die Datenquelle auf **`vlogs-generic`**. Die Abfragesprache ist hier eine andere: in PromQL
haben Sie numerische Reihen beschrieben, in LogsQL wählen Sie Zeilen nach den Werten ihrer Felder aus.

Die Abfrage unten liest sich so: „zeige die Zeilen, deren Feld `kubernetes_namespace_name` gleich
`default` ist und deren Feld `kubernetes_pod_name` mit `rickroll` beginnt".
Das Sternchen am Ende ist jener gleiche zufällige Anhang im Pod-Namen, der Sie in PromQL zwang,
`=~` zu schreiben.

```logsql
kubernetes_namespace_name:default AND kubernetes_pod_name:rickroll*
```

Gleichen Sie die Zeit ab: nehmen Sie die Minute des Ausschlags, den Sie auf dem Graphen des CPU-Verbrauchs
gefunden haben, und sehen Sie sich die Logs dafür an. In dieser Minute wird nginx einen Ausschlag an Request-Einträgen haben.

**Dafür haben wir Metriken und Logs getrennt.** Mit dem Graphen haben Sie den Moment unter drei
Stunden in einer Sekunde gefunden. Mit den Logs für diese Minute — was genau geschah. Umgekehrt funktioniert
es nicht: nach „wann es schlecht wurde“ zu suchen, indem man durch Logs scrollt, kann sehr lange dauern.

## Prüfung

📍 **Wo:** auf dem Bastion, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

```bash
export KUBECONFIG=~/lab.kubeconfig          # Zugang zum lab-Cluster `lab`

# Die beiden Variablen unten geben dem Skript auch Zugang zum Tenant. Mit ihnen prüft es
# zusätzlich, dass die Metriken dort angekommen sind, und gibt die Adresse Ihrer Grafana aus. Ohne sie
# läuft die Prüfung durch, aber der Bericht wird kürzer.
export COZY_TENANT=workshopXX               # Ihre Nummer statt XX
export COZY_KUBECONFIG=~/.kube/config     # die Zugangsdatei des Tenants

./check.sh                                  # ./ = „führ die Datei aus dem aktuellen Ordner aus"
```

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man es einrichtet, steht
am Anfang von Lab 0. Ohne WSL lässt sich das Lab absolvieren, aber es gibt keinen Artefakt-Bericht.

Das Skript prüft nicht „Sie haben sich den Graphen angesehen“ — das lässt sich nicht prüfen —, sondern das, was
sich prüfen lässt und sollte: dass die Metrikerfassung wirklich funktioniert, dass das Senden zu Ihrem
Tenant konfiguriert ist, dass die Log-Erfassung funktioniert, und dass der Cluster eine Spur der Last aus Lab 3 hat, die sich in diesen
Graphen finden lässt.

## Aufräumen

Es gibt nichts aufzuräumen. Das Add-on `Monitoring agents` verbraucht wenig und ist bis zum Ende des
Workshops nützlich — lassen Sie es aktiviert.

Die Metriken löschen sich von selbst: standardmäßig behält `shortterm` 3 Tage, `longterm` 14, Logs
einen Tag. Das ist jener seltene Fall, in dem das Aufräumen für Sie erledigt ist und nicht vergessen werden kann.

## Was wir jetzt können

- Erklären, warum Metriken kontinuierlich gesammelt werden und wie sie sich von Logs unterscheiden
- Prüfen, dass die Erfassung im Cluster aktiviert ist und wohin genau sie sendet
- Abfragen schreiben, die Ihre Pods und deren Verbrauch finden, und nicht auf `container!=""` hereinfallen
- Den Lastausschlag in den Graphen finden und die Reaktion der Autoskalierung darauf
- Die Divergenz von `desired` und `current` als Zeichen für unzureichenden Platz lesen

## Und in vSphere wäre das

vCenter zeigt Zähler für Hosts und virtuelle Maschinen — das reicht, solange die Fragen
zu virtuellen Maschinen gestellt werden. In dem Moment, in dem die Frage „was war mit dem Service“ lautet, brauchen Sie
vRealize Operations: ein separates Produkt, eine separate Lizenz, eine separate Installation,
separate virtuelle Maschinen, auf denen es läuft, und eine separate Person, die es zu konfigurieren weiß.

Hier ist die Metrik- und Log-Erfassung ein Add-on, das Sie mit einem Häkchen in der Anwendung aktivieren, und
Grafana samt Speicher kommt als Katalogeintrag hoch. Keine Lizenz, kein Einführungsprojekt.

**Wo vSphere ehrlicherweise bequemer ist.** Was das angeht, was gleich nach der Installation funktioniert,
gewinnt vCenter haushoch, und wir haben es genau hier im Lab gesehen:

| | vSphere | Cozystack |
|---|---|---|
| Graphen gleich nach der Installation | der Performance-Tab an jedem Objekt | Sie müssen das Add-on aktivieren und Grafana öffnen |
| Fertige Ansichten | für jede VM und jeden Host vorhanden | im Tenant — nur für Managed Services |
| Den benötigten Zähler finden | mit der Maus aus einer Liste wählen | eine Abfrage in PromQL schreiben |
| Einstiegshürde | eine Stunde | mehrere Tage, PromQL muss man lernen |
| Tiefe, wenn man den Dreh raus hat | begrenzt durch die Menge der Zähler | begrenzt dadurch, welche Metriken und Labels gesammelt werden |

PromQL ist eine Sprache, und man muss sie tatsächlich lernen. In den ersten zwei Wochen kopieren Sie
fremde Abfragen und verstehen nicht, warum der Graph leer ist. Dafür bekommen Sie das,
was vCenter gar nicht hat: die Möglichkeit, eine beliebige Frage zu stellen — „zeige den Verbrauch
der Pods dieser Anwendung relativ zu ihrer Reservierung, gruppiert nach Node, für letzten
Dienstag" — und eine Antwort zu erhalten, statt „einen solchen Zähler gibt es nicht“.
