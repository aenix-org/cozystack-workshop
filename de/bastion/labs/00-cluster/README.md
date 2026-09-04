# Lab 0 · Ihr eigener Kubernetes-Cluster

| | |
|---|---|
| **Zeit** | 15 Minuten, davon 10 Warten |
| **Was es beweist** | Ein Cluster ist ein Posten im Katalog, kein Projekt über ein ganzes Quartal |
| **Was Sie brauchen** | Zugang zum Tenant-Dashboard; `kubectl` auf dem Bastion (bereits installiert) |

## Warum das wichtig ist

Später werden Sie Anwendungen bereitstellen, sie kaputt machen, sie reparieren und sie skalieren. Für all das brauchen Sie einen Ort, an dem Sie der uneingeschränkte Eigentümer sind und an dem ein Fehler nichts kostet.

In vSphere würde Ihnen ein solcher Ort zugeteilt. Hier nehmen Sie ihn sich selbst, in zehn Minuten, und löschen ihn genauso mühelos selbst, wenn Sie fertig sind.

## Mini-Glossar

Sieben Wörter, die Ihnen von hier an in jedem Lab begegnen. Die dritte Spalte nennt das Ding aus vSphere, dem der Begriff ähnelt — und gleich darauf, worin er sich unterscheidet: Die Analogien helfen hier beim Verständnis, aber keine einzige passt vollständig, und genau zu wissen, wo eine Analogie bricht, ist wichtiger als die Analogie selbst.

| Begriff | Was es ist | Ähnlich wie… aber |
|---|---|---|
| **Kubernetes-Cluster** | Mehrere Maschinen plus ein Verwaltungsprogramm, das Anwendungen über sie verteilt. Sie übergeben ihm eine Anwendung und sagen ihm nicht, auf welcher Maschine sie laufen soll — es entscheidet selbst | **Ein ESXi-Cluster**, aber DRS platziert virtuelle Maschinen und rebalanciert sie danach fortlaufend, indem es sie zwischen Hosts verschiebt. Hier ist die Einheit ein Container, und sein Platz wird einmal gewählt, beim Start, und erneut beim Ausfall eines Nodes; der Cluster schichtet das bereits Laufende nicht von selbst um |
| **Control Plane** | Die Verwaltungsschicht des Clusters: Sie nimmt Ihre Befehle entgegen, speichert den gewünschten Zustand und verteilt die Arbeit an die Nodes | **vCenter**, aber es ist kein separater Server mit Web-Oberfläche — es ist eine Handvoll Prozesse; in Cozystack leben sie in der Plattform, nicht auf Ihren Nodes |
| **Node** | Die Maschine, auf der Ihre Anwendungen letztlich laufen | **Ein ESXi-Host**, aber hier ist es eine VM, keine Hardware, und sie ist in Minuten erstellt |
| **Node group** | Eine Beschreibung einer Gruppe identischer Nodes: wie viele und welche Größe | **Ein Cluster aus Hosts**, aber die Gruppe kann selbst Nodes je nach Last hinzufügen und entfernen |
| **Kubeconfig** | Eine Datei mit der Adresse des Clusters und Ihrem Zugang zu ihm. Ohne sie weiß `kubectl` nicht, wohin es sich wenden soll | **Die vCenter-Adresse zusammen mit einem Konto**, aber dies ist eine reine Textdatei auf Ihrer Festplatte, keine Einstellung in einem Client |
| **Tenant** | Ihr Ausschnitt der Plattform: eigene Quota, eigene Berechtigungen, eigene Objekte | **Ein Ressourcen-Pool plus Berechtigungen auf einem Ordner**, aber es ist zugleich eine Sichtbarkeitsgrenze — ein Nachbar schaut nicht in Ihren Tenant hinein |
| **Namespace** | Ein Bereich innerhalb des Clusters, in den Objekte abgelegt werden | **Ein Ordner im vCenter-Inventar**, aber die Trennung ist strikter: Objekte in verschiedenen Namespaces finden einander nicht über Kurznamen |

Container verdienen ein eigenes Wort, denn hier liegt die wichtigste Abweichung von der Welt, die Sie gewohnt sind. Ein Container ist eine laufende Anwendung samt allem, was sie zum Arbeiten braucht, verpackt in eine einzige Image-Datei. Von einer virtuellen Maschine unterscheidet er sich dadurch, dass er innen kein eigenes Betriebssystem hat: Ein Container nutzt den Kernel der Maschine, auf der er läuft. Daher der Unterschied im Maßstab — eine VM braucht eine Minute zum Starten und wiegt Gigabyte, ein Container startet in einer Sekunde und wiegt Dutzende Megabyte. Genau deshalb macht es dem Cluster nichts aus, sie stapelweise neu zu starten, womit Sie sich in den kommenden Labs beschäftigen werden.

## Wenn Sie unter Windows arbeiten — lesen Sie zuerst dies

Die Befehle in den Labs sind für die Kommandozeile von Linux und macOS geschrieben. In reinem PowerShell funktioniert ein Teil davon nicht: PowerShell hat eine andere Syntax und einen anderen Befehlssatz.

Die Lösung ist **WSL** — ein Linux-Subsystem innerhalb von Windows. Es installiert sich mit einem einzigen Befehl in einem als Administrator gestarteten PowerShell:

```powershell
# installiert das Linux-Subsystem in Windows: den Kernel, den Dienst und die
# standardmäßige Ubuntu-Distribution. Nach der Installation fordert Windows Sie zum Neustart auf.
wsl --install
```

Nach dem Neustart haben Sie eine Ubuntu-Konsole — und von da an arbeiten Sie darin wie alle anderen. Innerhalb von WSL brauchen Sie ein eigenes `kubectl` — den Befehl, mit dem Sie sich an den Cluster wenden:

```bash
# snap ist der Paketmanager von Ubuntu. --classic installiert das Paket ohne Isolierung:
# im isolierten Modus sieht kubectl die Zugangsdatei in Ihrem Home-Verzeichnis nicht.
sudo snap install kubectl --classic
```

Windows-Laufwerke sind aus WSL unter dem Pfad `/mnt/c/...` sichtbar, sodass mit einem gewöhnlichen Browser heruntergeladene Dateien auch innen verfügbar sind — man muss sie nirgendwohin kopieren. Das ist etwas später nützlich, wenn Sie die Zugangsdatei des Clusters erhalten: Speichern Sie sie unter Windows, liegt sie aus WSL unter einem Pfad wie `/mnt/c/Users/Ivan/Downloads/filename`.

⚠️ **Wenn WSL durch die Sicherheitsrichtlinie gesperrt ist** — auf einem Firmen-Bastion durchaus üblich — lassen sich die Labs trotzdem durchführen: Alles, was im Dashboard geschieht, ist vom Betriebssystem unabhängig. Nicht ausführen lassen sich lediglich die Prüfskripte und einige wenige Schritte, die ganz aus Befehlen bestehen. Solche Stellen sind gesondert gekennzeichnet.

## Was im Lab-Ordner liegt

Alle Dateien gehören Ihnen bereits — Sie haben sie zusammen mit dem Repository geholt. Es gibt nichts neu zu erstellen oder abzutippen: Überall, wo unten `kubectl apply -f name.yaml` steht, wird die Datei von hier genommen.

```bash
# der Pfad wird vom Repository-Wurzelverzeichnis gezählt — es holen Sie im nächsten Schritt
cd labs/00-cluster
```

| Datei | Was es ist | Wann Sie es brauchen |
|---|---|---|
| `cluster.yaml` | Beschreibung des Lab-Clusters: Version, Nodes, Monitoring | Sie wenden sie im ersten Schritt auf dem Management-Cluster an |
| `check.sh` | Eine Prüfung, dass der Cluster hochgekommen ist und Sie sich verbunden haben | Sie führen es am Ende des Labs aus |

## Schritt 0. Die Materialien liegen bereits auf dem Bastion

📍 **Wo:** auf dem Bastion (im Terminal des Bastion).

Die Manifeste — Dateien, die beschreiben, was im Cluster zu erstellen ist — und die Prüfskripte liegen bereits in Ihrem Home-Verzeichnis, im Verzeichnis `~/workshop`, und Ihre Tenant-Nummer ist darin schon eingesetzt. Es gibt nichts zu klonen — wir gehen hinein und sehen, was darin ist:

```bash
cd ~/workshop
ls manifests scripts labs
```

Von hier an wird jeder Pfad in den Labs von diesem Ordner (`~/workshop`) aus gezählt.

## Zugang zur Plattform holen

📍 **Wo:** im Browser, dann auf dem Bastion.

Alles, was Sie bei der Plattform bestellen, lebt auf dem **Management-Cluster** — am selben Ort wie Ihr Tenant. Um sich mit Befehlen an ihn zu wenden, brauchen Sie eine Zugangsdatei. Auf diesem Bastion ist sie **bereits eingerichtet** — `~/.kube/config`. Der Zugang ist token-basiert, deshalb öffnet sich beim Arbeiten mit dem Cluster kein Browser und Keycloak fragt Sie nichts.

Dieser Pfad wird in jedem Lab verwendet. Prüfen wir, dass der Zugang funktioniert:

```bash
# Den Management-Cluster nach der Liste Ihrer Kubernetes-Cluster fragen.
# --kubeconfig verweist explizit auf die Zugangsdatei (hier ist es zugleich die Standarddatei).
kubectl --kubeconfig ~/.kube/config get kubernetes.apps.cozystack.io -n tenant-workshopXX
```

**Was Sie sehen sollten:** entweder eine leere Liste oder die Zeile `No resources found` — Sie haben noch keine Cluster erstellt. Wichtig ist etwas anderes: Der Cluster selbst hat geantwortet, keine Fehlermeldung.

⚠️ **Ihre Tenant-Nummer ist der Login, mit dem Sie sich am Dashboard anmelden:** `workshop03`, `workshop07` und so weiter. Der Namespace Ihres Tenants setzt sich aus dem Wort `tenant-` und dieser Nummer zusammen: `tenant-workshop03`. Überall unten, wo `workshopXX` steht, setzen Sie Ihre eigene ein.

## Schritt 1. Den Cluster erstellen

📍 **Wo:** im Browser, im Cozystack-Dashboard.

Tenant → **Anwendung erstellen** → `Kubernetes`.

Ausfüllen:

| Feld | Wert | Warum so |
|---|---|---|
| Name | `lab` | kurz — Sie müssen ihn in Befehlen eintippen |
| Version | die vorgeschlagene belassen | es ist die neueste stabile |
| Control plane replicas | **1** | der Standard ist zwei; für eine Lab-Testumgebung genügt einer |
| Node group: name | `md0` | dieser Name landet im Node-Namen — Sie sehen ihn später in der Ausgabe von `kubectl get nodes` |
| Node group: min replicas | **1** | wir beginnen mit einem Node |
| Node group: max replicas | **3** | die Obergrenze, bis zu der die Gruppe von selbst wachsen darf; der Standard ist 10, und das Skalierungs-Lab baut auf dieser Obergrenze auf |
| Node group: instance type | `u1.medium` | 1 Prozessor, 4 GB |
| Node group: disk | `20Gi` | |
| Storage class | `replicated` | die Daten landen in drei Kopien auf verschiedenen Nodes |
| Addons → **Monitoring agents** | **aktivieren** | andernfalls sammeln sich keine Metriken an, und im Diagramm-Lab gibt es nichts zu sehen |

Auf Erstellen klicken.

⚠️ **Aktivieren Sie `Monitoring agents` sofort.** Die Metrikerfassung lässt sich nicht nachträglich einschalten: Setzen Sie das Häkchen eine Woche später, ist alles, was vorher geschah, für immer verloren. Das Diagramm-Lab stützt sich auf Daten, die ab heute anfallen.

⚠️ **Wenn jemand neben Ihnen dasselbe tut — versetzen Sie sich um ein paar Minuten.** Mehrere gleichzeitige Erstellungen belasten den internen Installationsmechanismus, und beide Cluster kommen dreimal so langsam hoch. Die Labs laufen in ihrem eigenen Tempo; es besteht kein Grund zur Eile.

### Genauer betrachtet: was in cluster.yaml steckt

Das ist kein Ausweichweg für den Fall, dass das Dashboard ausfällt. Der Knopf im Dashboard baut genau dieselbe Datei zusammen und schickt sie an den Cluster — das heißt, der Text ist hier das Primäre und die Maus ein Aufsatz darüber. Zur Arbeit mit Text führen wir hin: Eine Beschreibung, die in einer Datei liegt, lässt sich reviewen, in Git ablegen und zurückrollen, ein Knopfdruck nicht.

Die Datei liegt im Ordner dieses Labs: **`labs/00-cluster/cluster.yaml`**. Es gibt nichts zu öffnen oder abzutippen — sie gehört Ihnen bereits, wenn Sie das Repository zu Beginn des Labs geholt haben. Hier ist sie vollständig, damit wir sie Feld für Feld durchgehen können.

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Kubernetes
metadata:
  name: lab
  namespace: tenant-workshopXX
spec:
  version: v1.35
  storageClass: replicated
  controlPlane:
    replicas: 1
  addons:
    monitoringAgents:
      enabled: true
  nodeGroups:
    md0:
      minReplicas: 1
      maxReplicas: 3
      instanceType: u1.medium
      diskSize: 20Gi
      storageClass: replicated
```

⚠️ Die Befehle unten laufen **auf dem Management-Cluster** — mit dem Zugang, den Sie zusammen mit dem Tenant erhalten haben. Eine Zugangsdatei für den `lab`-Cluster selbst gibt es noch nicht: Sie erscheint erst, nachdem der Cluster hochgekommen ist.

```bash
# in den Lab-Ordner wechseln — von hier an werden alle Dateien von hier genommen
cd labs/00-cluster
# vor dem Anwenden setzen Sie in der Datei Ihre eigene Tenant-Nummer anstelle von XX ein.
# apply = „bring den Cluster auf das, was in der Datei beschrieben ist“. Den Cluster bringt der Befehl
# nicht selbst hoch — er übergibt den Auftrag an die Plattform, die entscheidet, was in
# welcher Reihenfolge erstellt wird.
#   -f   die Beschreibung aus der Datei nehmen
kubectl apply -f cluster.yaml
# get = „zeig, was da ist“. kubernetes.apps.cozystack.io ist der vollständige Name des Objekt-
# typs, genau der, der in der Datei beschrieben ist (kind: Kubernetes), lab ist der Name Ihres Auftrags.
#   -n   in welchem Namespace gesucht wird; ohne das Flag schaut kubectl im Standard-Namespace nach
#   -w   Änderungen beobachten und ausgeben. Zum Beenden — Ctrl+C, die Installation wird dadurch nicht unterbrochen
# Warten, bis in der Spalte READY True erscheint.
kubectl -n tenant-workshopXX get kubernetes.apps.cozystack.io lab -w
```

## Schritt 2. Warten und beobachten, woraus er sich zusammensetzt

📍 **Wo:** im Browser, im Dashboard.

Der Status wechselt zu `Ready`, meist innerhalb von fünf bis zehn Minuten.

⚠️ **Wenn mehr als zwanzig Minuten vergangen sind und sich der Status nicht ändert — die Ursache muss nicht Ihr Cluster sein.** Die Installation aller Anwendungen auf der Plattform wird von einer gemeinsamen Warteschlange gesteuert, und steht darin die lange Operation von jemandem, wartet Ihr Cluster, bis er an der Reihe ist. Um zu sehen, ob er in Arbeit genommen wurde:

```bash
# Den Auftrag selbst ansehen und das, was die Plattform darüber schreibt.
# Der Abschnitt status.conditions am Ende der Ausgabe ist ihr Bericht: ob er in
# Arbeit genommen wurde, was blockiert, worauf er wartet.
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX \
  get kubernetes.apps.cozystack.io lab -o yaml
```

Wenn auch dort nichts Klares steht — sehen Sie sich die Events des Tenants an. Das ist ein Protokoll dessen, was die Plattform mit Ihren Objekten getan hat:

```bash
# events = ein Protokoll der Vorfälle. Wir sortieren nach Zeit, damit das Frischeste unten steht.
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX \
  get events --sort-by=.lastTimestamp | tail -20
```

Der häufigste Fund hier ist die Zeile `exceeded quota: tenant-quota`. Sie bedeutet, dass dem Cluster der Ihrem Tenant zugeteilte Ressourcenanteil fehlt, und aus diesem Zustand kommt er nicht von selbst heraus: Sie müssen Platz freigeben oder die Quota erweitern.

Während die Installation läuft, sehen Sie im Dashboard nach, was genau in Ihrem Tenant erscheint.

**Die Control Plane** wurde als mehrere gewöhnliche Anwendungen ausgerollt. Es gibt keine separate Maschine, die „das vCenter dieses Clusters“ spielt: Die Verwaltungsschicht sind Prozesse, die neben allem anderen laufen.

**Ein Node** — das nun ist eine virtuelle Maschine. Eine ganz gewöhnliche, genau wie die, die Sie migrieren: mit eigener Disk, eigenem Speicher und eigener Adresse, und sie lebt in Ihrem Tenant.

Daraus folgt etwas Wichtiges: **Kubernetes ersetzt hier die Virtualisierung nicht — es lebt auf ihr.** Sie müssen nicht zwischen „wir betreiben VMs“ und „wir betreiben Container“ wählen — beides funktioniert, auf derselben Hardware und in derselben Oberfläche.

## Schritt 3. Zugang zum neuen Cluster holen

📍 **Wo:** auf dem Bastion; die Datei selbst holen Sie per Befehl oder aus dem Dashboard.

**Was wir holen.** Die kubeconfig des `lab`-Clusters — eine Textdatei, in der die Adresse seines API-Servers und Ihre Zugangsdaten dafür festgehalten sind. Ohne eine solche Datei weiß `kubectl` nicht, wohin es sich wenden und als wer es sich ausweisen soll. Die Datei erstellen Sie auf Ihrem Bastion selbst, unter dem Namen `~/lab.kubeconfig`; `~` in Pfaden ist Ihr Home-Verzeichnis: `/Users/name` auf macOS, `/home/name` auf Linux und WSL.

⚠️ **Das ist eine zweite Zugangsdatei, kein Ersatz für die erste.** Die, die Sie zusammen mit dem Tenant erhalten haben (in den Labs liegt sie unter dem Pfad `~/.kube/config`), führt zum Management-Cluster — dorthin, wo Sie Anwendungen bestellen und wo Sie gerade `lab` erstellt haben. Die neue Datei führt in den `lab`-Cluster selbst hinein. Das sind zwei verschiedene Cluster mit verschiedenen Adressen, und von hier an brauchen Sie beide: Aufträge an die Plattform gehen über die erste Datei, die Arbeit im eigenen Cluster über die zweite.

**Wo sie liegt.** Die Plattform hat sie in den Secret `kubernetes-lab-admin-kubeconfig` in Ihrem Tenant gelegt. Ein Secret ist ein Cluster-Objekt, in dem Passwörter, Schlüssel und Zugangsdateien aufbewahrt werden. Der Schlüssel, den Sie im Secret brauchen, ist `admin.conf`.

⚠️ **Im Secret liegen vier Schlüssel, und Sie brauchen genau `admin.conf`.** Daneben liegt `admin.svc` — dasselbe, aber mit einer internen Adresse, die nur von innerhalb des Clusters sichtbar ist; vom Bastion aus können Sie sich darüber nicht verbinden. Das Paar `super-admin.*` gewährt Rechte, die die konfigurierten Einschränkungen umgehen, und ist für die Aufarbeitung von Störfällen gedacht, nicht für den Alltag.

**Der Hauptweg — per Befehl.** Cozystack richtet auf Ihrem Cluster eine separate Zugriffsregel ein, die erlaubt, genau diesen Secret zu lesen und nichts weiter. Der Befehl läuft **auf dem Management-Cluster**, mit dem Zugang, den Sie zusammen mit dem Tenant erhalten haben, und das Ergebnis wird in eine Datei auf dem Bastion gelegt:

```bash
# get secret = den Secret anzeigen; -o go-template — ihn nicht ganz ausgeben,
# sondern ein Feld herausziehen und als Text ausgeben:
#   index .data "admin.conf"   den Schlüssel admin.conf aus dem Secret nehmen
#   base64decode               der Inhalt von Secrets wird base64-kodiert gespeichert,
#                              diese Funktion gibt den ursprünglichen Text zurück
#   > ~/lab.kubeconfig         die Ausgabe in eine Datei statt auf den Bildschirm schreiben
kubectl -n tenant-workshopXX get secret kubernetes-lab-admin-kubeconfig \
  -o go-template='{{ printf "%s\n" (index .data "admin.conf" | base64decode) }}' > ~/lab.kubeconfig
```

**Dasselbe mit der Maus.** Derselbe Secret ist im Dashboard auf der Seite der Anwendung `lab` sichtbar, in ihrer Liste der Secrets — suchen Sie nach dem Namen `kubernetes-lab-admin-kubeconfig`. Kopieren Sie den Wert des Schlüssels `admin.conf`, öffnen Sie einen beliebigen Texteditor, fügen Sie das Kopierte ein und speichern Sie die Datei unter dem Namen `lab.kubeconfig` in Ihrem Home-Verzeichnis.

## Schritt 4. Verbinden

📍 **Wo:** auf dem Bastion (im Terminal des Bastion).

**Was jetzt passiert:** Wir sagen `kubectl`, welche Zugangsdatei zu verwenden ist, und fragen den Cluster nach der Liste seiner Nodes.

macOS und Linux:

```bash
# KUBECONFIG ist die Variable, aus der kubectl erfährt, welche Zugangsdatei zu nehmen ist.
# export macht sie für alle Befehle sichtbar, die weiter in diesem Terminalfenster laufen.
export KUBECONFIG=~/lab.kubeconfig
# nodes sind die Nodes des Clusters, genau die virtuellen Maschinen, auf denen Ihre Anwendungen laufen werden.
# Die Antwort beweist zugleich, dass die Zugangsdatei funktioniert.
kubectl get nodes
```

Windows PowerShell — nur falls sich WSL nicht installieren ließ:

```powershell
# in PowerShell werden Umgebungsvariablen über $env: gesetzt und leben, bis das Fenster geschlossen wird
$env:KUBECONFIG="$HOME\lab.kubeconfig"
kubectl get nodes
```

**Was Sie sehen sollten** — eine einzige Zeile mit Ihrem Node und dem Status `Ready`:

```
NAME                        STATUS   ROLES    AGE   VERSION
kubernetes-lab-md0-xxxxx    Ready    <none>   3m    v1.35.6
```

⚠️ **`TLS handshake timeout` und `context deadline exceeded` sind eine Absage auf Seiten des Clusters, kein Fehler im Befehl.** Der Verwaltungsteil Ihres Clusters läuft in einer einzigen Kopie, und wenn die Plattform unter Last steht, antwortet er für einige zehn Sekunden nicht mehr. Der Befehl schlägt fehl, Sie wiederholen ihn eine halbe Minute später — und er geht durch. Ist das mitten in einem `apply` passiert, wiederholen Sie ihn: Der Befehl bringt den Cluster auf den in der Datei beschriebenen Zustand, statt etwas Neues hinzuzufügen, sodass nichts doppelt erstellt wird.

⚠️ **Die Variable `KUBECONFIG` muss in jedem neuen Terminalfenster gesetzt werden.** Vergessen Sie sie, geht `kubectl` zu irgendeinem anderen Cluster oder sagt, es gebe nichts, womit es sich verbinden könne. Das ist die mit Abstand häufigste Ursache für „bei mir ist alles kaputt“ in allen Labs. Wenn sich etwas seltsam verhält — prüfen Sie als Erstes `echo $KUBECONFIG`.

## Die Prüfung

📍 **Wo:** auf dem Bastion, im selben Terminalfenster, in dem Sie mit `kubectl` gearbeitet haben.

```bash
# das Skript läuft aus dem Lab-Ordner: es sucht die Dateien neben sich
cd labs/00-cluster
# ./ vor dem Namen bedeutet „führe die Datei genau von hier aus“; ohne das sucht die Shell
# den Befehl check.sh in den Systemordnern und findet ihn nicht
./check.sh
```

⚠️ **Unter Windows läuft das Skript aus WSL**, nicht aus PowerShell — wie man es installiert, steht am Anfang dieses Labs. Ohne WSL lässt sich das Lab absolvieren, aber es gibt kein Bericht-Artefakt.

Das Skript stellt sicher, dass der Cluster antwortet, die Nodes in Ordnung sind und auf ihnen Platz für künftige Anwendungen ist. Daneben erscheint eine Berichtsdatei — Sie können sie überall als Nachweis anhängen, dass das Lab erledigt ist.

## Aufräumen

Sie brauchen den Cluster in den Labs 1–5 und darüber hinaus. Löschen Sie ihn jetzt nicht.

Wenn Sie mit allen Labs fertig sind — löschen Sie die Anwendung `lab` über das Dashboard.

Das Löschen selbst dauert einige Minuten: Die Plattform fährt die Node-VM herunter, entfernt die Verwaltungskomponenten und gibt die Disks frei. Ist die Installations-Warteschlange in diesem Moment mit der langen Operation von jemandem belegt, kann das Warten länger dauern — dann hilft derselbe Trick mit der Annotation `reconcile.fluxcd.io/requestedAt`, der weiter oben im Lab beschrieben ist.

Wichtig ist etwas anderes: **Was frei wird, kehrt vollständig und von selbst in die Quota zurück.** Sie müssen niemanden fragen und nicht erklären, wozu Sie es genommen haben.

## Was wir jetzt können

- Uns selbst einen Kubernetes-Cluster hochziehen, ohne uns an jemanden zu wenden
- Verstehen, dass die Control Plane Prozesse sind und ein Node eine virtuelle Maschine
- Zugang holen und uns vom Bastion aus verbinden
- Wissen, wo die Ursache zu suchen ist, wenn sich `kubectl` seltsam verhält

## Und in vSphere wäre das

Kubernetes in vSphere ist ein separates Produkt, eine separate Lizenz und ein Einführungsprojekt unter Beteiligung des Herstellers. Hier ist es eine Zeile im Katalog und zehn Minuten.

**Wo vSphere ehrlich gesagt bequemer ist.** Wenn Sie nur virtuelle Maschinen und sonst nichts brauchen, gibt Ihnen vCenter mehr fertige Werkzeuge, um sie zu verwalten: Vorlagen, Klone, Anpassung des Gast-Betriebssystems, Berechtigungen auf Ebene eines einzelnen Ordners. Cozystack kann VMs, aber das Ökosystem um sie herum ist hier jünger. Der Gewinn zeigt sich dort, wo Sie sowohl VMs als auch alles andere zugleich brauchen — Datenbanken, Warteschlangen, Cluster, Registries — an einem Ort und über eine API.
