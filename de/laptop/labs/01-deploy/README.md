# Lab 1 · Ihre erste Anwendung

| | |
|---|---|
| **Zeit** | 25 Minuten |
| **Was es beweist** | Eine Anwendung wird als Text beschrieben, ist in Sekunden ausgerollt, und Sie fragen niemanden um Erlaubnis |
| **Was Sie brauchen** | Der Cluster aus Lab 0, `kubectl`, die Datei `~/lab.kubeconfig` |

## Warum das wichtig ist

Bevor wir uns an eine echte Aufgabe machen, üben wir an etwas Harmlosem. Wir rollen eine winzige
Anwendung aus, die nichts weiter tut als eines: Sie zeigt **den Namen ihrer eigenen Kopie**.

Klingt sinnlos, aber genau dieser Name ist die Hauptfigur der nächsten drei Labs. An ihm werden Sie
sehen, wie eine Kopie stirbt und neu geboren wird, wie sie sich auf sechs vermehren, und wie eine
alte Version einer neuen weicht.

Ausrollen werden wir sie als Text: eine Datei und ein Befehl. In diesem Lab gibt es keine Maus, und
das hat einen Grund — damit fangen wir an.

## Kleines Glossar

| Begriff | Was es ist | Ähnlich wie… aber |
|---|---|---|
| **Pod** | Eine laufende Kopie einer Anwendung | Eine **virtuelle Maschine**, aber der Pod ist wegwerfbar. Er wird nicht repariert und nicht gesichert — Sie löschen ihn, und ein neuer wird erstellt |
| **Image** | Ein Abbild der Anwendung mit allem, was sie zum Laufen braucht | Eine **VM-Vorlage**, aber unveränderlich. Sie können nicht hineingehen und es korrigieren — Sie bauen ein neues |
| **Deployment** | Eine Beschreibung: welches Image, wie viele Kopien, wie sie aktualisiert werden | Eine **vApp**, aber es hält eine gewünschte Anzahl an Kopien statt Verweisen auf konkrete VMs |
| **Service** | Eine dauerhafte Adresse, hinter der die Kopien stehen | Ein **Load-Balancer-Pool**, aber der Name ändert sich nicht, selbst wenn jede Kopie dahinter neu erstellt wurde |
| **ConfigMap** | Eine Einstellungsdatei, die im Cluster liegt | Eine **Datei auf der Festplatte einer VM**, aber sie lebt getrennt von der Anwendung und wird beim Start hineingeschoben |
| **Manifest** | Eine Datei, die den gewünschten Zustand beschreibt | Ein direktes Gegenstück gibt es nicht, und genau darum geht es |

## Was im Lab-Ordner liegt

Alle Dateien haben Sie bereits — Sie haben sie zusammen mit dem Repository geholt. Es gibt nichts
zu erstellen oder abzutippen: Wo unten `kubectl apply -f name.yaml` steht, wird die Datei von hier
genommen.

```bash
# Der Pfad wird relativ zur Wurzel des Repositorys angegeben, das Sie in Lab 0 geholt haben
cd labs/01-deploy
```

| Datei | Was es ist | Wann Sie es brauchen |
|---|---|---|
| `rickroll.yaml` | Die Anwendung als Ganzes: nginx-Einstellungen, das Deployment selbst und der Einstiegspunkt dazu | Sie wenden es auf Ihrem eigenen Cluster `lab` an |
| `check.sh` | Eine Prüfung, dass die Anwendung antwortet und den Pod-Namen zurückgibt | Sie führen es am Ende des Labs aus |

## Schritt 1. Wo das Dashboard endet und Ihr Cluster beginnt

📍 **Wo:** auf dem Laptop.

Das Cozystack-Dashboard zeigt, was Sie **bei der Plattform bestellen**: Kubernetes-Cluster,
Datenbanken, Warteschlangen, virtuelle Maschinen — Katalogpositionen. Der Cluster `lab` erscheint
dort als eine einzige Position: bestellt und in Betrieb.

In sein Inneres schaut das Dashboard nicht, und es kann es auch nicht. Ihr Cluster ist ein eigener
API-Server mit eigener Adresse und eigener Zugangsdatei — eben jener `~/lab.kubeconfig`; das
Management-Dashboard spricht nicht mit ihm. Auch eine eigene grafische Konsole hat der Cluster `lab`
nicht: Unter den Add-ons, die Sie an ihn anhängen können, ist keine solche aufgeführt.

Daher die Verantwortungsgrenze, und die sollte man sich merken: **Die Plattform ist verantwortlich
für das, was Sie bestellt haben, und für das, was innerhalb des Bestellten liegt, sind Sie
verantwortlich.** Innerhalb des Clusters läuft die Arbeit über `kubectl` — den Befehl, der
Objektbeschreibungen an seinen API-Server sendet und Ihnen zeigt, was dort gerade vorhanden ist.

Verbinden wir uns:

```bash
# KUBECONFIG — die Variable, aus der kubectl abliest, welche Zugangsdatei zu verwenden ist.
# Hier ist das der Zugang zum lab-Cluster, nicht zum Tenant: unterschiedliche Dateien, unterschiedliche Cluster.
export KUBECONFIG=~/lab.kubeconfig
# get nodes = "zeige die Nodes". Die Antwort bestätigt, dass kubectl mit dem richtigen Ort spricht.
kubectl get nodes
```

**Was Sie sehen sollten:** eine Zeile mit Ihrem Node und dem Status `Ready`. Erhalten Sie
stattdessen einen Verbindungsfehler — prüfen Sie `echo $KUBECONFIG`: Die Variable muss in jedem
neuen Terminalfenster gesetzt werden.

## Schritt 2. Die Anwendung ausrollen

📍 **Wo:** auf dem Laptop.

Wechseln Sie in den Ordner dieses Labs — das Repository haben Sie in Lab 0 geholt:

```bash
# Der Pfad wird relativ zum Ordner angegeben, in den Sie das Repository geklont haben
cd labs/01-deploy
```

Falls Sie das Repository noch nicht haben:

```bash
# clone = das gesamte Repository herunterladen; ein Ordner mit demselben Namen erscheint neben Ihnen
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd labs/01-deploy
```

Im Ordner liegt `rickroll.yaml`. Bevor wir es anwenden — sehen wir uns an, was darin steht.

<details>
<summary><b>Genauer betrachtet: Was in rickroll.yaml steckt</b></summary>

In der Datei stehen vier Objekte, getrennt durch eine `---`-Zeile. Gehen wir sie der Reihe nach durch.

### Erstes: die Webserver-Einstellungen

```yaml
kind: ConfigMap
metadata:
  name: rickroll-conf
data:
  default.conf: |
    server {
      listen 8080;
      root /usr/share/nginx/html;
      location / {
        sub_filter '__POD__' '$hostname';
        sub_filter_once off;
      }
    }
```

`ConfigMap` ist eine Möglichkeit, eine Einstellungsdatei getrennt von der Anwendung in den Cluster
zu legen. Darin steckt eine gewöhnliche nginx-Konfiguration (nginx ist ein Webserver, und er ist es,
der unsere Seite ausliefert), dieselbe, wie sie auf einer VM in `/etc/nginx/conf.d/` läge.

Die entscheidende Zeile ist `sub_filter '__POD__' '$hostname'`. Sie sagt nginx: Ersetze in der
ausgelieferten Seite den Text `__POD__` durch den Namen der Maschine, auf der du läufst. Innerhalb
eines Pods ist der Maschinenname der Name des Pods selbst. So erfährt die Seite, wer sie ausgeliefert
hat.

Warum die Einstellungen ein eigenes Objekt sind und nicht ins Image eingebacken: damit Sie sie
ändern können, ohne das Image neu zu bauen. Das nutzen wir im Lab über das Ausrollen von Versionen.

### Zweites: die Seite selbst

```yaml
kind: ConfigMap
metadata:
  name: rickroll-page-v1
data:
  index.html: |
    ...<div class="pod">вас обслужил под<b>__POD__</b></div>...
```

Eben jenes `__POD__`, das nginx ersetzen wird. Das `-v1` im Namen ist kein Zufall: Im Lab über das
Ausrollen von Versionen taucht ein `-v2` auf, und das Umschalten zwischen ihnen wird ein Rollout der
neuen Version sein.

### Drittes: die Anwendung

```yaml
kind: Deployment
spec:
  replicas: 1
```

`Deployment` ist die Beschreibung der Anwendung als Ganzes. `replicas: 1` gibt an, wie viele Kopien
am Laufen gehalten werden. Achten Sie auf die Formulierung: nicht **„eine starten“**, sondern
**„eine halten“**. Der Unterschied zeigt sich im nächsten Lab, wenn wir die Kopie löschen.

```yaml
      image: nginxinc/nginx-unprivileged:1.27-alpine
```

Das Image. Wir haben die unprivilegierte Variante von nginx genommen — sie lauscht auf Port 8080 und
läuft nicht als root. Gewöhnliches nginx verlangt Privilegien, die ein korrekt konfigurierter Cluster
nicht gewährt. Das ist keine Pingeligkeit unsererseits — es ist eine Sicherheitsanforderung, der Sie
in jedem modernen Cluster begegnen.

```yaml
      resources:
        requests: {cpu: 20m, memory: 32Mi}
        limits:   {cpu: 300m, memory: 128Mi}
```

Zwei verschiedene Dinge, und sie werden ständig verwechselt.

`requests` ist, wie viel **als Garantie reserviert** wird. Der Scheduler nutzt diese Zahl, um zu
entscheiden, auf welchen Node der Pod passt. Das nächste Gegenstück ist eine Reservierung in vSphere.

`limits` ist die Obergrenze, über die er **nicht hinaus darf**. Das Gegenstück ist ein Limit in
vSphere.

`20m` liest sich als „20 Milli-CPUs“, also zwei Hundertstel eines Kerns. Wir fordern absichtlich
wenig an: Die Anwendung ist winzig, und im Skalierungs-Lab lässt Sie eine niedrige request die Kopien
mit eigenen Augen wachsen sehen.

```yaml
      readinessProbe:
        httpGet: {path: /healthz, port: http}
```

Die Bereitschaftsprüfung. Der Cluster klopft an diese Adresse und schickt keinen Traffic an den Pod,
bis er eine Antwort erhält. Genau das ermöglicht im Lab über das Ausrollen von Versionen das Update
ohne Ausfallzeit: Eine neue Kopie beginnt erst dann Anfragen zu empfangen, wenn sie wirklich bereit
ist, sie zu verarbeiten.

### Wie die Einstellungen in den Container gelangen

Wir haben die beiden ConfigMaps beschrieben, aber für sich genommen liegen sie nur im Cluster herum
und erreichen nginx nie. Zwei Blöcke verbinden sie miteinander — und auf ihnen ruht der ganze Kniff
dieses Labs:

```yaml
          volumeMounts:
            - name: page
              mountPath: /usr/share/nginx/html
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: page
          configMap:
            name: rickroll-page-v1
        - name: conf
          configMap:
            name: rickroll-conf
```

Lesen Sie es von unten nach oben. `volumes` erklärt: „Nimm diese ConfigMap und mach daraus einen
Ordner mit Dateien“. `volumeMounts` sagt: „Lege diesen Ordner im Container an diesem Pfad ab“. Das
Ergebnis: `index.html` landet dort, wo nginx nach Seiten sucht, und `default.conf` dort, wo es nach
Einstellungen sucht.

Die nächste Analogie aus Ihrer Welt ist das Anhängen eines freigegebenen Ordners an eine virtuelle
Maschine. Der Unterschied: Der Inhalt liegt als eigenes Objekt im Cluster, und Sie können ihn ändern,
ohne weder das Image noch die Maschine selbst anzufassen.

⚠️ **Die Reihenfolge in `volumes` ist wichtig.** Das Lab über das Ausrollen von Versionen wechselt die
Seite mit einem Befehl, der das Volume **über die Nummer** anspricht — das erste in der Liste.
Vertauschen Sie die Blöcke, dann schiebt der Befehl stillschweigend die Einstellungen anstelle der
Seite unter, und nginx hört auf zu funktionieren. Dazu gibt es einen Kommentar in der Datei selbst.
Der sichere Weg — ein Patch-Merge über den Volume-Namen statt über die Nummer — wird im Lab über das
Ausrollen von Versionen behandelt.

### Viertes: die dauerhafte Adresse

```yaml
kind: Service
spec:
  selector:
    app: rickroll
  ports:
    - port: 80
      targetPort: http
```

`Service` ist ein dauerhafter Name, hinter dem alle Kopien der Anwendung stehen. Sie sprechen
`rickroll` an und erreichen irgendeine von ihnen.

Die Verbindung zwischen dem Service und den Pods ist keine Liste von Adressen, sondern eine
**Bedingung**: `selector: app: rickroll` bedeutet „alle Pods mit dem Label `app: rickroll`“. Ein
Label ist ein beliebiges „Schlüssel: Wert“-Paar, das Sie an ein Objekt hängen, um es später über
dieses Paar zu finden; am nächsten kommen dem die Tags in vSphere, nur dienen Labels hier nicht dem
Absuchen mit dem Auge, sondern dem Aufbau funktionierender Verbindungen. Ein neuer Pod erscheint mit
diesem Label — er tritt automatisch dem Load Balancing bei. Er verschwindet — er fällt heraus.
Niemand bearbeitet die Liste von Hand.

Genau das ist der entscheidende Unterschied zu einem Load-Balancer-Pool, in den Sie die Adressen
eintragen.

</details>

Jetzt wenden wir es an:

```bash
# apply = "bringe den Cluster in den in der Datei beschriebenen Zustand". Alle vier Objekte werden
# mit einem einzigen Befehl erstellt; die Reihenfolge innerhalb der Datei ermittelt der Cluster selbst.
#   -f   nimm die Beschreibung aus einer Datei
kubectl apply -f rickroll.yaml
```

**Was Sie sehen sollten** — vier Zeilen über erstellte Objekte:

```
configmap/rickroll-conf created
configmap/rickroll-page-v1 created
deployment.apps/rickroll created
service/rickroll created
```

Warten Sie, bis die Kopie hochgefahren ist:

```bash
# rollout status wartet, bis das Deployment die Sache durchgezogen hat: die geforderte Anzahl Kopien
# läuft und ist bereit, Anfragen anzunehmen. Der Befehl endet von selbst, sobald das eintritt.
kubectl rollout status deployment/rickroll
```

Das Warten war eine Sache von Sekunden. Gestartet ist kein Betriebssystem, sondern ein einzelner
Prozess innerhalb eines bereits laufenden: Der Kernel auf dem Node wurde vor Langem hochgefahren und
wird von allen Containern geteilt. Eine virtuelle Maschine an derselben Stelle bräuchte ein, zwei
Minuten zum Booten — sie muss ihren eigenen Kernel, ihre Dienste und ihr Netzwerk hochbringen.

## Schritt 3. Sehen, was der Cluster aus der Datei gemacht hat

📍 **Wo:** auf dem Laptop.

Der Cluster speichert nicht die Datei selbst, sondern die Objekte, die er daraus erstellt hat. Fragen
wir, wie das, was wir angewendet haben, jetzt aussieht:

```bash
# get deployment rickroll = zeige ein einzelnes Objekt nach Typ und Name.
#   -o yaml   gib es vollständig aus, in derselben Form, in der Sie es von Hand schreiben könnten
kubectl get deployment rickroll -o yaml
```

Die Ausgabe ist lang: Das meiste hat der Cluster selbst ergänzt — Standardwerte, interne Felder, den
aktuellen Zustand. Finden Sie diese Zeilen mit dem Auge:

```yaml
spec:
  replicas: 1
  template:
    spec:
      containers:
      - image: nginxinc/nginx-unprivileged:1.27-alpine
```

Das ist, was Sie in die Datei geschrieben haben. **Innerhalb des Clusters wird alles als Text
beschrieben** — sowohl das, was Sie anwenden, als auch das, was der Cluster zurückgibt. Als Sie den
Cluster in Lab 0 über das Cozystack-Dashboard bestellt haben, hat es genau denselben Text
zusammengesetzt und an die Plattform geschickt: Die Schaltfläche ist eine Schicht über dem Text,
keine Alternative dazu.

Der Unterschied liegt darin, was danach übrig bleibt. Eine Datei können Sie in Git legen, vor dem
Anwenden durchsehen, nachschlagen, wer sie wann geändert hat, mit einem einzigen Befehl zurückrollen,
dasselbe in einem zweiten Cluster ausrollen, ohne sich zu erinnern zu versuchen, welche Kästchen Sie
im ersten angehakt haben. Ein Mausklick hinterlässt keine Spur: Einen Monat später erinnert sich
niemand, Sie eingeschlossen, warum genau dieser Wert gesetzt wurde.

## Schritt 4. Im Browser öffnen

📍 **Wo:** auf dem Laptop.

**Was gleich passiert:** Die Anwendung lebt innerhalb des Clusters und ist von außen nicht sichtbar.
Der Befehl unten legt einen Tunnel von Ihrem Laptop nach innen.

```bash
# port-forward = ein Tunnel vom Laptop in den Cluster, lebt so lange, wie der Befehl läuft.
#   svc/rickroll   führe den Tunnel zum Service namens rickroll, der die Anfrage seinerseits
#                  an eine lebende Kopie der Anwendung weiterleitet
#   8080:80        die linke Zahl ist der Port auf dem Laptop, die rechte der Service-Port im Cluster
kubectl port-forward svc/rickroll 8080:80
```

Der Befehl endet nicht: Er hält den Tunnel offen, bis Sie ihn stoppen. Öffnen Sie
<http://localhost:8080>.

**Was Sie sehen sollten:** eine schimmernde Überschrift, eine Zeile des Songs und unten — den
Pod-Namen. Vergleichen Sie ihn mit dem, was der Cluster anzeigt.

📍 **Wo:** in einem zweiten Terminalfenster. Das erste ist mit dem Tunnel belegt — solange der Befehl
läuft, können Sie darin nichts eingeben. Öffnen Sie ein neues Fenster und setzen Sie dort erneut die
Zugangsdatei: Umgebungsvariablen werden nicht in ein neues Fenster übernommen.

```bash
export KUBECONFIG=~/lab.kubeconfig
```

```bash
# get pods = "zeige die laufenden Kopien".
#   -l app=rickroll   zeige nicht alle Pods, sondern nur die mit dem Label app=rickroll —
#                     eben jenem, über das der Service sie findet
kubectl get pods -l app=rickroll
```

Die Namen stimmen überein. Genau diese Kopie hat die Seite ausgeliefert.

Zum Schließen des Tunnels — `Ctrl+C`.

## Die Prüfung

📍 **Wo:** auf dem Laptop, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

```bash
# Führen Sie es aus dem Lab-Ordner aus: Das Skript sucht seine Dateien neben sich selbst.
# Das ./ vor dem Namen bedeutet "führe die Datei genau von hier aus", nicht sie in Systemordnern zu suchen
./check.sh
```

⚠️ **Unter Windows läuft das Skript aus WSL**, nicht aus PowerShell — wie man das einrichtet, steht am
Anfang von Lab 0. Ohne WSL können Sie das Lab trotzdem abschließen, aber es gibt keinen
Artefaktbericht.

Das Skript prüft nicht die Tatsache, dass das Manifest angewendet wurde, sondern die Arbeit im Kern:
Die Anwendung antwortet über HTTP, die Antwort enthält einen Pod-Namen, und dieser Name stimmt mit
einer tatsächlich laufenden Kopie überein.

## Aufräumen

Sie brauchen die Anwendung in den Labs 2, 3 und 4 — löschen Sie sie jetzt nicht. Sie zu behalten ist
billig: Eine Kopie von nginx fordert zwei Hundertstel eines Kerns und 32 Megabyte an, und wenn es ans
Löschen geht — das ist ein einziger Befehl, und die Ressourcen kehren in derselben Sekunde in den
gemeinsamen Pool des Nodes zurück.

## Was wir jetzt können

- Sagen, wo das Plattform-Dashboard endet und Ihr eigener Cluster beginnt
- Eine Anwendung mit einer einzigen Datei und einem einzigen Befehl ausrollen
- Ein Manifest lesen und erklären, wofür jeder Block da ist
- `requests` von `limits` unterscheiden
- Verstehen, dass ein Service Kopien über ein Label findet, nicht über eine Liste von Adressen
- Mit einem Browser über `port-forward` ins Innere des Clusters gelangen

## Und in vSphere wäre das

Ein Antrag auf eine VM, ein Antrag an das Netzwerkteam auf eine Adresse, ein Antrag an die Sicherheit
auf ein Zertifikat. Tage im besten Fall. Hier — eine Datei und ein Befehl.

**Wo vSphere ehrlicherweise bequemer ist.** Wenn Sie eine VM ausrollen, bekommen Sie eine vollwertige
Maschine: Sie können hineingehen, alles installieren, an Ort und Stelle reparieren und sie so
weiterlaufen lassen. Ein Pod ist anders gebaut — er ist unveränderlich, und „hineingehen und
reparieren“ ergibt dort keinen Sinn, weil beim nächsten Neustart die Änderung verschwindet. Das
diszipliniert, aber anfangs ist es lästig, und es wäre töricht, so zu tun, als wäre es anders.
