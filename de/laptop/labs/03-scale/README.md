# Lab 3 · Last und Autoskalierung

| | |
|---|---|
| **Zeit** | 30 Minuten |
| **Was es beweist** | Die Anzahl der Repliken kann durch Last bestimmt werden, nicht durch ein Service-Desk-Ticket |
| **Was Sie brauchen** | Der Cluster aus Lab 0, `rickroll` aus Lab 1, drei Terminalfenster, ein Browser |

## Warum das wichtig ist

Der Dienst „Zutrittsausweis“, um den sich das Ganze dreht, wird sich ungleichmäßig verhalten. Um acht Uhr morgens öffnen ihn die Wachleute und das halbe Büro gleichzeitig; um drei Uhr nachmittags rührt ihn niemand an. Die Kapazität nach der Spitze zu bemessen heißt, neun Stunden am Tag die Luft zu heizen; sie nach dem Durchschnitt zu bemessen heißt, eine Schlange am Eingang zu bekommen.

Probieren wir die dritte Variante aus: Die Anzahl der Repliken bestimmt nicht ein Mensch, sondern die Last selbst. Wir geben der Anwendung echten Traffic und sehen zu, wie sie auf sechs Repliken anwächst und dann wieder auf eine schrumpft.

Unterwegs klären wir das, worüber hier die meisten stolpern — den Unterschied zwischen „wie viel wir anfordern“ und „wie viel wir erlauben“.

## Mini-Glossar

| Begriff | Was es ist | Ähnlich wie… aber |
|---|---|---|
| **HPA** | Ein Objekt, das die Replikenzahl anhand einer Metrik ändert | **DRS plus manuelles Hinzufügen von VMs**, ändert aber die Anzahl der Instanzen, statt sie über Hosts zu verteilen |
| **metrics-server** | Ein Dienst, der den aktuellen Verbrauch der Pods erfasst | **Statistikerfassung von vCenter**, behält aber nur die letzten Minuten — gar keine Historie |
| **requests** | Wie viel einer Ressource wir garantiert reservieren | **Reservation**, aber daraus wird die Auslastung in Prozent berechnet, und sie entscheidet auch, wo ein Pod hineinpasst |
| **limits** | Die Obergrenze, über die ein Pod nicht hinaus kann | **Limit**, aber an der Obergrenze wird die CPU gedrosselt, während Speicher den Pod tötet |
| **Utilization** | Verbrauch in Prozent von `requests` | **„CPU Usage %“ im Diagramm**, kann aber 600% betragen, und das ist kein Fehler |
| **Fortio** | Ein Lastgenerator mit Weboberfläche | **HCIBench**, lebt aber innerhalb des Clusters als gewöhnliche Anwendung |

## Was im Lab-Ordner liegt

Sie haben bereits alle Dateien — Sie haben sie zusammen mit dem Repository erhalten. Es gibt nichts zu erstellen oder neu einzutippen: Wo unten `kubectl apply -f name.yaml` steht, stammt die Datei von hier.

```bash
# Jeder Befehl in diesem Lab wird aus diesem Ordner ausgeführt — sonst werden die darin genannten Dateinamen nicht gefunden.
cd labs/03-scale
```

| Datei | Was es ist | Wann es nützlich ist |
|---|---|---|
| `hpa.yaml` | Die Autoskalierungs-Regel: Repliken anhand der CPU-Last wachsen lassen | Sie wenden sie auf Ihrem eigenen Cluster `lab` an |
| `fortio.yaml` | Ein Lastgenerator mit Weboberfläche — damit erzeugen wir die Last | Sie wenden ihn am selben Ort an |
| `check.sh` | Prüft, dass die Repliken unter Last gewachsen und danach geschrumpft sind | Sie führen es am Ende des Labs aus |

## Schritt 1. Bestätigen, dass wir mit einer einzigen Replik starten

📍 **Wo:** auf dem Laptop.

Das ganze Lab beruht darauf, dass die Replikenzahl merklich wächst. Also müssen wir bei eins beginnen — sonst gibt es nichts, womit sich das Wachstum vergleichen ließe. Sehen wir nach, wie viele Repliken gerade laufen.

```bash
# KUBECONFIG ist der Pfad zur Datei mit der Adresse des Clusters und den Anmeldedaten.
# Solange die Variable nicht gesetzt ist, sucht kubectl den Cluster auf dem Laptop selbst und findet ihn nicht.
export KUBECONFIG=~/lab.kubeconfig

# Die Spalte READY liest sich als "bereit / angefordert": 1/1 bedeutet eine Replik angefordert und laufend.
kubectl get deployment rickroll
```

Es sollte `1/1` anzeigen. Ist es mehr, setzen Sie es auf eins zurück, sonst ist das Wachstum nicht so gut sichtbar:

```bash
# scale ändert genau ein Feld im Datensatz der Anwendung — die Replikenzahl.
# Die überzähligen Repliken entfernt der Cluster von selbst, innerhalb von Sekunden.
kubectl scale deployment rickroll --replicas=1
```

## Schritt 2. Lesen, was die Anwendung anfordert

Bevor Sie die Autoskalierung konfigurieren, müssen Sie verstehen, wovon sie die Prozente berechnet.

```bash
# Ein Objekt im Cluster hat Hunderte von Feldern; die Tabelle zeigt sie nicht. jsonpath holt
# genau eine Stelle aus der Antwort heraus. Lesen Sie den Pfad von oben nach unten: spec.template ist die Vorlage,
# aus der die Repliken erzeugt werden, containers[0] ist der erste Container darin, resources ist seine
# Anforderung und Obergrenze für CPU und Speicher. Das Anhängsel {"\n"} ist ein Zeilenumbruch, damit die Antwort
# nicht mit der nächsten Eingabeaufforderung verschmilzt.
kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

```json
{"limits":{"cpu":"300m","memory":"128Mi"},"requests":{"cpu":"20m","memory":"32Mi"}}
```

Zwei Zahlenpaare, und sie werden ständig verwechselt. Gehen wir es an der CPU durch.

**`requests: cpu: 20m`** — „zwanzig Millicpu“, also zwei Hundertstel eines Kerns. Das ist die Anforderung: die Menge, die der Cluster jederzeit für den Pod bereitzuhalten verspricht. Anhand dieser Zahl entscheidet der Scheduler, ob der Pod auf einen Node passt: Die Summe der Anforderungen aller Pods auf einem Node darf dessen Kapazität nicht überschreiten. Das nächste Pendant ist eine Reservation in vSphere.

**`limits: cpu: 300m`** — die Obergrenze. Dem Pod werden nicht mehr als drei Zehntel eines Kerns gegeben, selbst wenn der Node im Leerlauf ist. Das Pendant ist ein Limit in vSphere.

Zwischen ihnen liegt ein fünfzehnfacher Abstand, und das ist Absicht: Ein Pod kann viel nehmen, wenn die CPU frei ist, garantiert ist ihm aber nur wenig.

⚠️ **CPU und Speicher verhalten sich beim Anschlag an ihr Limit unterschiedlich, und das ist wichtiger, als es scheint.** Stößt es an das CPU-Limit, läuft die Anwendung einfach langsamer (Throttling). Stößt es an das Speicher-Limit, tötet der Kernel den Container: Sie sehen den Status `OOMKilled`, und der Pod wird neu erstellt. Das Erste ist unangenehm, das Zweite ein Ausfall. In vSphere lässt sich Speicher auch nicht überschreiten, aber dort erhält der Gast Swap und wird langsamer, statt zu sterben.

**Und nun das Wichtigste für dieses Lab.** HPA berechnet die Last nicht vom Limit, nicht von der Kapazität des Nodes und nicht davon, wie viele Kerne die Anwendung in sich selbst sieht. Er berechnet sie **aus `requests`**. Ein Schwellwert von 50% bei `requests: 20m` bedeutet 10 Millicpu pro Replik.

Daraus folgt das, woran die Autoskalierung am häufigsten scheitert, wenn man sie zum ersten Mal einrichtet: **Ist bei einem Container kein `requests.cpu` angegeben, gibt es nichts, wovon gerechnet werden könnte, und HPA funktioniert überhaupt nicht.** Er wirft keinen Fehler — er zeigt stillschweigend weiter `<unknown>` an.

## Schritt 3. Autoskalierung einschalten

Die Datei `hpa.yaml` liegt im Ordner. Gehen wir sie durch und wenden sie dann an.

<details>
<summary><b>Genauer betrachtet: was in hpa.yaml steckt</b></summary>

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rickroll
```

`autoscaling/v2` ist keine Dekoration. In der alten Version `v1` konnte man nur ein CPU-Ziel setzen und nicht die Wachstumsgeschwindigkeit steuern. Alles unterhalb des `metrics`-Blocks ist in `v1` nicht verfügbar. Wenn Sie im Internet ein Beispiel auf `autoscaling/v1` sehen — es ist nicht tödlich veraltet, deckt aber die Hälfte dessen nicht ab, was Sie brauchen.

```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rickroll
```

Wen wir beobachten und wen wir steuern. HPA verwaltet die Pods nicht direkt — er ändert das Feld `replicas` am Deployment, und von dort greift dieselbe Kette wie im Lab zur Selbstheilung: Das Deployment gibt die Zahl an das ReplicaSet weiter, das ReplicaSet erzeugt die fehlenden Repliken.

Daraus ergibt sich eine praktische Regel: **Solange HPA existiert, ist es sinnlos, `replicas` von Hand zu ändern.** Sie setzen drei, und fünfzehn Sekunden später setzt HPA seinen eigenen Wert. Zwei Mechanismen auf einem Feld sind immer ein Streit, und HPA gewinnt ihn.

```yaml
  minReplicas: 1
  maxReplicas: 6
```

Ein Korridor. Die Untergrenze schützt vor „es gibt keine Last, schalten wir alles ab“ — HPA kann nicht auf null herunterskalieren. Die Obergrenze schützt das Budget und den Node: Ohne sie würde ein plötzlicher Ausschlag (oder ein Bug in der Anwendung, der die CPU auffrisst) die Repliken vervielfachen, bis auf den Nodes kein Platz mehr ist.

Sechs wurde für den Schulungs-Node `u1.medium` gewählt. Sechs Repliken mit je 20m Anforderung sind 120m — das bewältigt der Node mühelos.

```yaml
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

Die Regel: die **durchschnittliche** Last über alle Repliken bei 50% ihrer `requests` halten, also 10m pro Replik.

Das Wort „durchschnittlich“ ist hier entscheidend, und die ganze Arithmetik hängt davon ab. HPA rechnet so:

```
benötigte Repliken = ceil( aktuelle Repliken × aktuelle Last ÷ Ziel-Last )
```

Eine Replik bei 645% Last und einem Ziel von 50% ergibt `ceil(1 × 645 / 50) = 13`. Dreizehn ist mehr als sechs, deshalb stößt HPA an `maxReplicas`.

Warum das Ziel 50 ist und nicht 80: Bei 80% beginnt das Wachstum erst, wenn es der Anwendung schon schlecht geht. Die Hälfte lässt einen Puffer für die Zeit, die neue Repliken zum Hochfahren brauchen. Bei echten Diensten wird diese Zahl danach eingestellt, wie viele Sekunden der Start dauert.

```yaml
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 2
          periodSeconds: 15
```

Die Wachstumsgeschwindigkeit. Standardmäßig betrachtet Kubernetes vor dem Hochskalieren die Metrik-Historie über ein gewisses Fenster, um nicht bei einem zufälligen Ausschlag zu zucken. In einem Lab sieht das aus wie „es passiert nichts“, deshalb wird das Fenster auf null gesetzt: Wir reagieren auf die allererste Messung.

`Pods: 2 / 15s` — höchstens zwei Repliken alle fünfzehn Sekunden hinzufügen. Deshalb verläuft der Weg nach oben in Stufen: 1 → 3 → 5 → 6.

⚠️ **Indem Sie `policies` angeben, ersetzen Sie die Standard-Policies, statt sie zu ergänzen.** Die Standard-Wachstums-Policy (Verdopplung alle 15 Sekunden) gilt hier nicht mehr.

```yaml
    scaleDown:
      stabilizationWindowSeconds: 60
```

Nach unten hingegen mit Verzögerung. HPA betrachtet das Maximum der angeforderten Anzahlen über die letzte Minute und verringert die Replikenzahl nur, wenn die Last dieses gesamte Intervall über niedrig war. Sonst würden bei jeder Pause zwischen den Ausschlägen Repliken zu verschwinden und wieder aufzutauchen beginnen.

Der Standardwert hier ist **300 Sekunden**, fünf Minuten. Wir haben ihn auf eine Minute gekürzt, damit Sie den Rückgang innerhalb des Labs noch sehen. Im Produktivbetrieb sind fünf Minuten sinnvoller.

</details>

Wenden Sie sie an:

```bash
# apply = "bringe den Cluster in den in der Datei beschriebenen Zustand". Das HPA-Objekt erscheint sofort,
# zu rechnen beginnt es aber nicht sofort — darüber stolpern wir im nächsten Schritt.
kubectl apply -f hpa.yaml
```

## Schritt 4. Die Prüfung, die nicht durchgeht

Sehen wir, was dabei herausgekommen ist:

```bash
# hpa ist die Kurzform für horizontalpodautoscaler; kubectl versteht beide Schreibweisen.
# Die Spalte TARGETS liest sich als "aktuelle Last / Ziel", REPLICAS ist, wie viele
# Repliken gerade angefordert sind.
kubectl get hpa rickroll
```

**Was Sie sehen werden:**

```
NAME       REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: <unknown>/50%   1         6         1          10s
```

In der Spalte `TARGETS` steht statt der Last `<unknown>`. Die Autoskalierung weiß nicht, wie viel CPU die Anwendung verbraucht, und hat somit nichts, worauf sie eine Entscheidung stützen könnte.

⚠️ **Vielleicht sehen Sie aber auch sofort einen Prozentwert** — zum Beispiel `cpu: 5%/50%`. Das bedeutet nicht, dass bei Ihnen etwas anders ist: Der Metrik-Sammler in Ihrem Cluster läuft bereits eine Weile und hatte Zeit, die Pods abzufragen. `<unknown>` erscheint auf einem gerade erst hochgefahrenen Cluster. Wenn bei Ihnen sofort eine Zahl steht — lesen Sie die Erläuterung unten trotzdem, denn der Ursache von `<unknown>` begegnen Sie eines Tages, und es ist besser, sie im Voraus zu lernen als in dem Moment, in dem sie Ihnen in die Quere kommt.

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Das Manifest wurde ohne Fehler angewendet, das Objekt ist erstellt, der Container hat `requests` — wir haben eben nachgesehen. Es liegt also nicht daran, dass in der Beschreibung etwas fehlt.
>
> Hinweis: Woher erfährt die Autoskalierung die aktuelle Last überhaupt? Jemand muss ihr diese Zahl melden — und dieser Jemand fragt die Pods nicht kontinuierlich ab, sondern einmal alle paar Dutzend Sekunden.

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Es fehlt an Zeit. Warten Sie anderthalb bis zwei Minuten und sehen Sie erneut nach:

```bash
# Derselbe Befehl wie oben. Wir betrachten dieselbe Spalte TARGETS.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 0%/50%     1         6         1          2m
```

**Das ist kein Defekt, und hier gibt es nichts zu reparieren.** Die Last der Pods erfasst ein separater Dienst, `metrics-server`. Er fragt die Nodes etwa alle fünfzehn Sekunden ab und mittelt das Ergebnis über ein kurzes Fenster. Solange er nicht zwei Messungen hintereinander hat, hat er nichts weiterzugeben, und HPA schreibt ehrlich „ich weiß es nicht“.

Dass die Metriken fließen, können Sie direkt prüfen:

```bash
# top = "wie viele Ressourcen diese Pods gerade verbrauchen". Die Zahlen stammen von
# demselben metrics-server, der auch die Autoskalierung speist: Antwortet top, dann ist die
# Datenquelle am Leben, und es ist nur eine Frage der Zeit.
kubectl top pods -l app=rickroll
```

```
NAME                        CPU(cores)   MEMORY(bytes)
rickroll-6f4b9c8d57-p9wqt   1m           4Mi
```

Ist es nach fünf Minuten immer noch `<unknown>` und `kubectl top` antwortet `error: Metrics API not available` — dann ist es wirklich ein Defekt, und die Ursache ist eine von zweien: `metrics-server` ist nicht im Cluster installiert, oder beim Container ist kein `requests.cpu` gesetzt (dann funktioniert `kubectl top`, HPA kann aber trotzdem nicht rechnen — es gibt nichts, wovon der Prozentwert genommen werden könnte).

`metrics-server` installiert sich zusammen mit dem Cluster von selbst — Sie müssen ihn nicht separat aktivieren. Er lebt im namespace `cozy-monitoring`, prüfen können Sie so:

```bash
# -n = in welchem namespace gesucht wird. Ein namespace ist ein Abschnitt des Clusters;
# standardmäßig sucht kubectl in default und sieht die System-Pods dort nicht.
# deploy ist die Kurzform für deployment.
kubectl -n cozy-monitoring get deploy metrics-server
```

Verwechseln Sie ihn nicht mit dem Kontrollkästchen **Monitoring agents** aus Lab 0: Dieses ist für das Sammeln von Metriken in den Speicher und für die Diagramme zuständig (das Lab zur Beobachtbarkeit), während `metrics-server` für die aktuellen Zahlen für `kubectl top` und die Autoskalierung zuständig ist. Unterschiedliche Mechanismen, und sie leben unabhängig voneinander.

Die genaue Ursache verrät:

```bash
# describe = die vollständige Karte des Objekts: alle Felder, Ereignisse und Conditions,
# anders als get, das nur ein paar Tabellenspalten ausgibt.
kubectl describe hpa rickroll
```

Ganz unten, unter `Conditions`, steht eine Zeile `ScalingActive` mit einer menschenlesbaren Erklärung.

**Die Lehre reicht über diesen Fehler hinaus.** In Kubernetes sind „angewendet“ und „funktioniert“ zeitlich getrennt. Der Befehl `apply` schreibt nur Ihre Absicht in den Cluster. Von dort greifen die Controller sie auf, und jeder hat sein eigenes Tempo: HPA rechnet alle fünfzehn Sekunden neu, die Metriken hinken eine Minute hinterher, der Garbage Collector kommt alle paar Minuten vorbei. Die Gewohnheit aus vCenter — „der Dialog ist zu, also ist es erledigt“ — lässt Sie hier im Stich. Beobachten sollten Sie nicht den Rückgabewert des Befehls, sondern den `status` des Objekts.

</details>

## Schritt 5. Den Lastgenerator hochfahren

Die Anwendung vom Laptop aus über `port-forward` zu belasten ist sinnlos: Zum Engpass werden Ihr Heim-Internet und der Tunnel selbst, nicht die Anwendung. Der Generator muss innerhalb des Clusters stehen, direkt neben dem Ziel.

Die Datei `fortio.yaml` liegt im Ordner.

<details>
<summary><b>Genauer betrachtet: was in fortio.yaml steckt</b></summary>

```yaml
kind: Deployment
metadata:
  name: fortio
```

Fortio ist eine gewöhnliche Anwendung im Cluster, ausgerollt mit demselben Deployment wie alles andere. Es gibt hier keine besondere „Test-Infrastruktur“, und das allein ist schon bezeichnend.

```yaml
        - name: fortio
          image: fortio/fortio:latest
          args: ["server"]
```

Das Fortio-Image kann in zwei Modi laufen. `fortio load ...` ist ein einmaliger Durchlauf von der Kommandozeile. `fortio server` ist ein dauerhaft laufender Dienst mit Weboberfläche, bei dem man die Last per Knopfdruck startet und das Ergebnis gleich dort als Diagramm sieht. Wir nehmen den zweiten: In einem Workshop ist es anschaulicher, ein Latenz-Histogramm im Browser zu betrachten, als eine Zahlenkolonne im Terminal zu lesen.

⚠️ **Der Tag `latest` in einem Manifest ist etwas, das Sie im Produktivbetrieb nicht tun sollten.** Heute ist es das eine Image, in einem Monat ein anderes, und Sie können Ihren eigenen Test nicht mehr reproduzieren. Für einen Schulungsgenerator ist das vertretbar, für alles andere nicht.

```yaml
          ports:
            - containerPort: 8080
              name: http
```

Die Weboberfläche von Fortio lauscht auf 8080 und liegt unter dem Pfad `/fortio/`. Der Name `http` wird weiter unten im Service gebraucht.

```yaml
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: "1"
              memory: 256Mi
```

Beachten Sie: Dem Generator ist mehr zugeteilt als dem Ziel. Eine Anforderung von 100m gegenüber den 20m von `rickroll`, eine Obergrenze von einem ganzen Kern gegenüber 300m.

Das ist keine Großzügigkeit, sondern eine zwingende Voraussetzung für einen korrekten Test. Geht dem Generator die CPU aus, stößt er an seine eigene Obergrenze, und Sie messen dann Fortio, nicht die Anwendung. Das Symptom dieses Fehlers ist erkennbar: Die Latenzen steigen, während die Last des Ziels unverändert bleibt.

```yaml
kind: Service
metadata:
  name: fortio
spec:
  ports:
    - port: 8080
      targetPort: http
```

Eine stabile Adresse für die Weboberfläche. Von innerhalb des Clusters ist sie jetzt als `http://fortio:8080/` erreichbar, von außen über `port-forward`, was wir als Nächstes tun.

</details>

Anwenden und warten:

```bash
# In der Datei stehen gleich zwei Objekte: das Deployment mit dem Generator und ein Service — eine
# stabile Adresse für seine Weboberfläche.
kubectl apply -f fortio.yaml

# rollout status hält das Terminal und gibt den Fortschritt aus, bis die Replik bereit ist.
# Wir warten hier bewusst: Solange der Generator nicht oben ist, gibt es nichts, womit sich Last erzeugen ließe.
kubectl rollout status deployment/fortio
```

## Schritt 6. Fortio im Browser öffnen

📍 **Fenster 1** — der Tunnel zu Fortio. Der Port `8081` wurde gewählt, um nicht mit `8080` zu kollidieren, falls bei Ihnen noch der Tunnel zu `rickroll` aus Lab 1 offen ist:

```bash
export KUBECONFIG=~/lab.kubeconfig

# port-forward legt einen Tunnel von Ihrem Laptop in den Cluster.
#   svc/fortio    wozu wir uns verbinden: der Service namens fortio
#   8081:8080     liest sich als "Port auf Ihrer Seite : Port im Cluster" — eine Anfrage
#                 an localhost:8081 geht an Port 8080 dieses Service
kubectl port-forward svc/fortio 8081:8080
```

Der Befehl endet nicht — er hält den Tunnel offen. Während er läuft, öffnen Sie <http://localhost:8081/fortio/>.

⚠️ **Der abschließende Schrägstrich im Pfad ist zwingend.** Unter `http://localhost:8081/fortio` ohne ihn antwortet Fortio mit 404, und es sieht so aus, als wäre er nicht gestartet.

## Schritt 7. Ein zweites Fenster vorbereiten, um das Wachstum zu sehen

Der Sinn des Labs sind nicht die Zahlen im Bericht von Fortio, sondern das, was mit den Repliken geschieht. Das müssen Sie gleichzeitig mit der Last sehen, nicht danach.

📍 **Fenster 2** — lassen Sie es bis zum Ende des Labs offen.

Beobachten werden wir mit dem Flag `-w` (watch). Es bedeutet nicht „den Bildschirm aktualisieren“, sondern „bei jeder Änderung eine neue Zeile ausgeben“. Die Ausgabe ist ein Ereignisprotokoll statt einer Tabelle. Das ist ein wichtiger Unterschied zu `watch kubectl get pods`, wo Sie nur die Momentaufnahme „jetzt“ sehen und die Zwischenzustände leicht verpassen.

```bash
export KUBECONFIG=~/lab.kubeconfig

# Wir beobachten die Repliken von rickroll: Jede neue Zeile ist ein Zustandswechsel einer von ihnen.
# Der Befehl endet nicht; zum Beenden Ctrl+C — auf die Repliken selbst hat das keine Auswirkung.
kubectl get pods -l app=rickroll -w
```

Wenn Sie ein drittes Fenster haben, legen Sie auch dies hinein — so sehen Sie den Entscheidungsprozess selbst:

```bash
# Dieselbe Beobachtung, aber der Autoskalierungs-Entscheidungen: TARGETS zeigt, wie sich die Last
# ändert, REPLICAS zeigt, wie viele Repliken sie daraufhin angefordert hat.
kubectl get hpa rickroll -w
```

## Schritt 8. Die Last aufbringen

📍 **Wo:** im Browser, auf dem Fortio-Tab.

Füllen Sie das Formular aus:

| Feld | Wert | Warum so |
|---|---|---|
| URL | `http://rickroll/` | der Service-Name; Fortio ist im Cluster und sieht ihn direkt |
| QPS | `1200` | zwölfhundert Anfragen pro Sekunde |
| Duration | `90s` | anderthalb Minuten: genug sowohl für das Wachstum als auch, um es zu erkennen |
| Connections | `80` | achtzig parallele Verbindungen |

Drücken Sie **Start**.

⚠️ **Falls die Felder in Ihrer Version von Fortio anders heißen** (zum Beispiel ist die Anzahl der Verbindungen mit `Threads` beschriftet), richten Sie sich nach der Bedeutung: URL, Anfragerate, Dauer, Parallelität. Dieselbe Last können Sie auch per Befehl aufbringen, am Browser vorbei:

```bash
# exec führt einen Befehl innerhalb eines bereits laufenden Pods aus, nicht auf Ihrem Laptop.
#   deploy/fortio   in einem Pod dieser Anwendung; welcher Pod genau — kubectl wählt selbst
#   --              alles nach diesem Trenner ist der Befehl für den Pod
#   -qps 1200       zwölfhundert Anfragen pro Sekunde
#   -c 80           achtzig parallele Verbindungen
#   -t 90s          die Last anderthalb Minuten halten
# Das letzte Argument ist das Ziel: der Service-Name unserer Anwendung.
kubectl exec deploy/fortio -- fortio load -qps 1200 -c 80 -t 90s http://rickroll/
```

## Schritt 9. Beobachten, was geschieht

📍 **Fenster 2**, etwa zwanzig Sekunden nach dem Start:

```
NAME                        READY   STATUS              AGE
rickroll-6f4b9c8d57-p9wqt   1/1     Running             22m
rickroll-6f4b9c8d57-mn4kd   0/1     Pending             0s
rickroll-6f4b9c8d57-mn4kd   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-t8zxc   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-mn4kd   1/1     Running             3s
rickroll-6f4b9c8d57-t8zxc   1/1     Running             3s
```

Dann noch zwei, dann noch eine. Innerhalb einer Minute sind es sechs Repliken.

📍 **Sehen Sie sich den HPA an** — was er sieht und was er entschieden hat:

```bash
# TARGETS ist die aktuelle durchschnittliche Last gegenüber dem Ziel, REPLICAS ist, wie viele Repliken angefordert sind.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 645%/50%   1         6         6          8m
```

**645%.** Auf der Testumgebung, auf der dieses Lab erprobt wurde, kam genau dieser Wert heraus; bei Ihnen wird es eine andere Größenordnung sein, aber ganz sicher Hunderte von Prozent.

Die Zahl wirkt absurd, bis man sich erinnert, wovon sie berechnet wird. Nicht von der Kapazität des Nodes, sondern von der **Anforderung** der Replik, und unsere Anforderung ist 20m — zwei Hundertstel eines Kerns. Eine Replik nimmt ein Mehrfaches des Angeforderten, und das ist erlaubt: `requests` ist ein garantiertes Minimum, keine Obergrenze. Die Obergrenze ist `limits`, und die ist noch weit entfernt.

Der Node ist dabei alles andere als frei: `u1.medium` ist ein Kern, und in dieser Minute laufen darauf sowohl die Repliken der Anwendung als auch der Lastgenerator selbst. Der hohe Prozentwert kommt nicht von einem Überfluss an Kapazität, sondern von einem kleinen Nenner.

**Prozentwerte über hundert sind hier die Norm, kein Alarm.** Das ist das Wichtigste, was die aus vCenter mitgebrachte Intuition zerbricht: Dort würde „CPU Usage 645%“ eine Katastrophe bedeuten, weil der Prozentwert vom Zugeteilten berechnet wurde. Hier wird er vom angeforderten Minimum berechnet, und zwischen Anforderung und Obergrenze liegt ein fünfzehnfacher Abstand.

Prüfen Sie die Arithmetik des HPA selbst nach:

```bash
# Der Verbrauch jeder Replik einzeln. CPU(cores) wird in Millicpu ausgegeben:
# 100m ist ein Hundertstel eines Kerns, 1000m ist ein ganzer Kern.
kubectl top pods -l app=rickroll
```

Der Durchschnitt über die Repliken ist genau die Zahl, die HPA mit dem Schwellwert vergleicht: 50% der Anforderung von 20m, also 10m. Die Summe über alle Repliken stößt an den Kern des Nodes — und dort hört das Wachstum auf, selbst wenn Sie die Last weiter erhöhen.

📍 **Im Browser auf dem Fortio-Tab** wird derweil ein Latenz-Histogramm gezeichnet. Sehen Sie sich den Durchlauf bis zum Ende an: Am Ende erscheint eine Zeile wie `Code 200 : 108000 (100.0 %)`. Null Fehler — die Anwendung hat es bewältigt. Merken Sie sich, wo diese Zeile steht: In Lab 4 wird sie das wichtigste Beweisstück sein.

## Schritt 10. Beobachten, wie die Repliken wieder zurückfahren

Die Last ist vorbei. Tun Sie nichts, beobachten Sie Fenster 2.

In den ersten anderthalb bis zwei Minuten geschieht nichts. Die Pause setzt sich aus drei Verzögerungen zusammen: Die Metriken hinken etwa eine Minute hinterher, `stabilizationWindowSeconds: 60` verlangt, dass die Last die gesamte letzte Minute über niedrig war, und HPA selbst rechnet alle fünfzehn Sekunden neu.

Dann rieseln die Zeilen auf einmal herein:

```
rickroll-6f4b9c8d57-t8zxc   1/1     Terminating   4m
rickroll-6f4b9c8d57-mn4kd   1/1     Terminating   4m
...
```

Fünf Repliken gehen, eine bleibt — `minReplicas`.

**Beachten Sie die Asymmetrie.** Nach oben ging es in Stufen von zwei Repliken; nach unten in einem einzigen Zug. Das ist so gewollt: Ein Fehler in Richtung „zu viele Repliken“ kostet nur den Geldbeutel, ein Fehler in Richtung „zu wenige“ bedeutet, den Dienst lahmzulegen. Deshalb wachsen sie aggressiv und schrumpfen vorsichtig.

## Prüfung

📍 **Wo:** auf dem Laptop, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

Das Skript prüft nicht die Tatsache, dass das Manifest angewendet wurde, sondern dass der Mechanismus wirklich lebendig ist: dass der HPA existiert und auf das richtige Deployment zielt, dass der Container ein `requests.cpu` hat, von dem der Prozentwert berechnet wird, dass `metrics-server` tatsächlich Zahlen liefert (`TARGETS` ist nicht `<unknown>`) und dass der Status des HPA noch eine Markierung trägt, dass die Skalierung bereits ausgelöst hat.

⚠️ **Führen Sie die Prüfung vor dem Aufräumen aus** — sobald der HPA gelöscht ist, gibt es nichts mehr zu prüfen.

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man es installiert, steht am Anfang von Lab 0. Ohne WSL können Sie das Lab abschließen, aber es gibt kein Bericht-Artefakt.

```bash
# ./ bedeutet "eine Datei aus dem aktuellen Ordner", nicht ein Befehl aus dem System-PATH.
# Das Skript ändert nichts im Cluster: Es liest nur und gibt einen Bericht aus.
./check.sh
```

## Aufräumen

**Löschen Sie den HPA.** In Lab 4 rollen wir eine neue Version unter Last aus, und ein zusätzlicher Mechanismus, der gleichzeitig die Replikenzahl ändert, würde das Bild nur trüben:

```bash
# delete -f = "entferne aus dem Cluster, was in dieser Datei beschrieben ist". Die Anwendung bleibt:
# In der Datei ist nur der HPA beschrieben. Nach dem Löschen friert die Replikenzahl beim aktuellen Wert ein.
kubectl delete -f hpa.yaml
```

**Behalten Sie Fortio** — es wird in Lab 4 als Lastquelle gebraucht. Wenn Sie Lab 4 nicht planen, entfernen Sie es ebenfalls:

```bash
# Entfernt beide Objekte aus der Datei — das Deployment des Generators und seinen Service.
kubectl delete -f fortio.yaml
```

Rühren Sie die Anwendung `rickroll` nicht an.

Alles, was Sie freigegeben haben, kehrte in dem Moment in den gemeinsamen Pool des Nodes zurück, als die Container endeten. Es gibt hier kein „zugeteilt und nicht zurückgegeben“ — eine Anforderung lebt genau so lange, wie der Pod lebt.

## Was wir jetzt können

- Den Unterschied zwischen `requests` und `limits` erklären und vorhersagen, was beim Anschlag an jedes von beiden geschieht
- Verstehen, warum HPA die Prozente aus `requests` berechnet und warum er ohne sie nicht funktioniert
- Die HPA-Formel lesen und im Voraus sagen, wie viele Repliken er anfordern wird
- „Das Manifest ist angewendet“ von „der Mechanismus hat zu arbeiten begonnen“ unterscheiden und wissen, wo man den Status ansieht
- Einer Anwendung echte Last von innerhalb des Clusters geben, nicht vom Laptop

## Und in vSphere wäre das

In vSphere skaliert man nach oben: Hot-Add von CPU und Speicher zu einer laufenden Maschine. Ein Mensch tut das nach Zeitplan oder auf einen Alert hin, und das war's — vCenter kann keine Anwendungsinstanzen vervielfachen; dafür braucht man einen Load Balancer, eine Maschinenvorlage und die Handarbeit von jemandem. DRS löst ein anderes Problem: Es verschiebt vorhandene Maschinen zwischen Hosts, ändert aber deren Anzahl nicht.

Hier ist die Anzahl der Repliken eine Folge der Last, beschrieben in zwanzig Zeilen Text.

**Wo vSphere ehrlich gesagt praktischer ist.** Drei Dinge, und alle bedeutsam.

Erstens funktioniert Hot-Add mit jeder Anwendung, auch mit einer, die 2009 geschrieben wurde und strikt als einzelne Instanz existiert. HPA verlangt, dass die Anwendung in mehreren Repliken gleichzeitig laufen kann: ohne gemeinsamen Zustand, ohne Schreiben in eine lokale Datei, ohne an eine Instanz gebundene Sitzung. Kann sie das nicht, ist die Autoskalierung für Sie nicht verfügbar, und Kubernetes löst dieses Problem nicht — es legt es bloß. Genau hier verläuft die wahre Grenze der Migration, nicht in den Manifesten.

Zweitens die Metriken. vCenter bewahrt Statistiken monatelang auf, und die Frage „was war letzten Dienstag“ beantwortet ein Diagramm. `metrics-server` hält die letzten Minuten und nichts weiter — er ist genau dafür ausgelegt, HPA zu speisen. Für die Historie müssen Sie Prometheus aufsetzen, und das ist eine eigene Aufgabe (Lab 14).

Drittens die Kalkulierbarkeit der Kosten. Eine Maschine mit vier Kernen kostet einen bestimmten Betrag, und das ist im Voraus bekannt. Autoskalierung bedeutet, dass Sie an einem schlechten Tag sechsmal mehr Verbrauch bekommen als an einem normalen. `maxReplicas` ist kein feiner Regler zur Leistungsoptimierung, es ist Ihre Sicherung fürs Geld, und entsprechend sollte man damit umgehen.
