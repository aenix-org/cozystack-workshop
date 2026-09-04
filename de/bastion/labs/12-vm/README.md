# Lab 12 · Eine VM neben den Containern

| | |
|---|---|
| **Zeit** | 30 Minuten, davon 5–10 für das Warten auf den Start der Maschine |
| **Was es zeigt** | Legacy muss nicht containerisiert werden, um umzuziehen: eine migrierte VM wird nach außen über denselben Ingress und dieselbe Domain veröffentlicht wie eine containerisierte Anwendung |
| **Was Sie brauchen** | Zugang zum Tenant-Dashboard, die Tenant-`~/.kube/config`, `kubectl`, `virtctl` |

## Warum das wichtig ist

Das Mitarbeiterverzeichnis ist der älteste Teil von „Propusk“. Eine Anwendung aus dem Jahr 2011, geschrieben von einem Auftragnehmer, den es nicht mehr gibt. Sie läuft auf Windows Server und auf einer Version von .NET, die nie aktualisiert wurde, weil „sie funktioniert“. Es gibt keine Quellen, keine Dokumentation — nur einen vierseitigen Wiederherstellungsleitfaden mit einem Schritt, der lautet „Sergei anrufen“.

Im Inneren ist es eine kleine Webanwendung: Sie liefert über HTTP eine Seite mit einer Liste der Mitarbeiter und ihrer Telefonnummern aus. Menschen öffnen sie im Browser; andere Dienste fragen sie nach Daten ab.

Dieses Verzeichnis zieht nicht in einen Container um. Nicht „noch nicht“ — niemals: Man kann eine Anwendung, die niemand neu bauen kann, physisch nicht containerisieren. Und das ist kein Grund, auf den Umzug zu verzichten. Die Antwort auf die Frage „Was tun wir mit den Dingen, die sich nicht portieren lassen?“ lautet: Bringen Sie sie so, wie sie sind, als virtuelle Maschine herüber.

Aber umzuziehen reicht nicht: Das Verzeichnis muss von außen sichtbar sein, genau wie zuvor. In diesem Lab stellen wir eine virtuelle Maschine neben den Containern auf und veröffentlichen sie nach außen **auf dieselbe Weise wie eine containerisierte Anwendung** — über den Ingress und den Domainnamen der Plattform. Für die Plattform ist die VM nur eine weitere Workload hinter einer Domain, und es ist ihr gleichgültig, ob dahinter ein Container steckt oder ein ganzes Betriebssystem.

## Mini-Glossar

| Begriff | Was es ist | Wie… aber |
|---|---|---|
| **VMInstance** | Eine virtuelle Maschine als Cluster-Objekt | **Eine virtuelle Maschine**, aber als Text beschrieben und mit demselben `kubectl` erstellt wie die Anwendungen |
| **VMDisk** | Ein Datenträger, der getrennt von der Maschine existiert | **Eine vmdk**, aber ein eigenes Objekt: Er überlebt die Maschine und lässt sich an eine andere anhängen |
| **Instance type** | Eine fertige Maschinengröße aus der Liste der Plattform: so viele vCPU, so viel Arbeitsspeicher | näher an Cloud-Instance-Typen als an manuellem Feintuning von vCPU/RAM |
| **Instance profile** | Ein Satz von Geräten und Treibern für das Gast-Betriebssystem | **Guest OS type**, aber es beeinflusst, welche Controller der Gast sieht |
| **cloud-init** | Ein Provisionierungsskript, das beim ersten Einschalten der Maschine ausgeführt wird | **Customization Specification**, aber einfaches YAML im Manifest statt eines Assistenten in der Oberfläche |
| **Service** | Eine stabile Adresse für eine Gruppe von Pods innerhalb des Clusters | **Ein Load-Balancer-Pool**, aber die Plattform hält die Mitgliederliste selbst aktuell, anhand von Labels |
| **Ingress** | Eine Regel: welche Domain zu welchem Service führt, zusammen mit HTTPS | **Ein Reverse-Proxy vor einer Farm** (nginx, HAProxy), aber als Objekt beschrieben, wobei Domain und Zertifikat von der Plattform ausgestellt werden |
| **Domain** | Ein dauerhafter Name, unter dem der Dienst von außen über HTTP sichtbar ist | **Ein DNS-Name hinter einem Unternehmens-Load-Balancer**, aber es muss kein Ticket bei DNS oder für ein Zertifikat eingereicht werden |
| **KubeVirt** | Der Mechanismus, mit dem Kubernetes VMs betreibt | **Ein Hypervisor**, aber es ist kein zweiter Hypervisor: darunter liegt dasselbe QEMU/KVM, das jedes Linux nutzt |

## Was im Lab-Ordner liegt

Sie haben bereits alle Dateien — Sie haben sie zusammen mit dem Repository erhalten. Es gibt nichts zu erstellen oder abzutippen: Wo unten `kubectl apply -f name.yaml` steht, stammt die Datei von hier.

```bash
cd labs/12-vm
```

| Datei | Was es ist | Wann Sie sie brauchen |
|---|---|---|
| `staff-directory-vm.yaml` | Die virtuelle Maschine für das Legacy-Mitarbeiterverzeichnis | Sie wenden sie **im Tenant** an |
| `check.sh` | Eine Prüfung, dass das Verzeichnis veröffentlicht ist und unter seiner Domain antwortet | Sie führen sie am Ende des Labs aus |

📍 **Der Ingress wird von der Lehrkraft erstellt, nicht vom Teilnehmer, und im Voraus.** Jeder Tenant enthält bereits einen `Service spravochnik-http` (er leitet Port 80 auf 8080 weiter und wählt die Pods Ihrer Maschine aus) und einen `Ingress spravochnik` mit dem Host `spravochnik.workshopXX.workshop.aenix.io`. Sie müssen sie nicht einrichten und ihre Dateien nicht selbst aufbewahren — alles, was Sie brauchen, ist, eine virtuelle Maschine namens `spravochnik` hochzufahren, und die Veröffentlichung greift sie von selbst auf.

## Schritt 1. Die VM hochfahren

📍 **Wo:** im Browser, im Tenant-Dashboard.

Die VM ist ein von Cozystack verwalteter Dienst; sie lebt in Ihrem Tenant. Sie wird in zwei Zügen erstellt, und das lohnt sich, gleich zu verstehen.

### Zuerst der Datenträger

Tenant → **Anwendung erstellen** → `VM Disk`.

| Feld | Wert | Warum so |
|---|---|---|
| Name | `spravochnik` | so wird auch die Maschine heißen |
| Source | `Image` → `ubuntu-22.04` | aus der fertigen Image-Sammlung der Plattform genommen |
| Storage | `20Gi` | das Image `ubuntu-22.04` entpackt sich auf 20Gi, weniger lässt sich nicht angeben |
| Storage class | `replicated` | drei Kopien der Daten auf verschiedenen Nodes |

**Warum der Datenträger ein eigenes Objekt ist und kein Feld innerhalb der Maschine.** Weil der Datenträger die Maschine überlebt. Sie können die ganze Maschine löschen, sie mit einem anderen Typ, einem anderen Netzwerk, einem anderen Namen neu erstellen — und denselben Datenträger anhängen. In vSphere tun Sie dasselbe, wenn Sie eine vmdk von einer VM lösen und an eine andere anhängen; hier ist das im Modell ausdrücklich ausformuliert.

⚠️ **Der Datenträger kann nicht kleiner sein als das Quell-Image.** Das `ubuntu-22.04` der Plattform entpackt sich auf 20Gi, und die Plattform lehnt eine Anforderung für einen 10Gi-Datenträger ab: Es gibt keinen Ort, an den das Image in ein kleineres Volume geklont werden könnte. Zu klein zu dimensionieren kostet hier mehr als zu groß: Einen Datenträger können Sie später vergrößern, aber nicht verkleinern.

Warten Sie, bis sich der Datenträger füllt: Die Plattform lädt das Image herunter und entpackt es, das dauert ein bis zwei Minuten.

### Dann die Maschine

Tenant → **Anwendung erstellen** → `VM Instance`.

| Feld | Wert | Warum so |
|---|---|---|
| Name | `spravochnik` | |
| Instance type | `u1.medium` | 1 CPU, 4 GB — dieselbe Größenliste, die auch die Cluster-Nodes verwenden |
| Instance profile | `ubuntu` | der Satz von Geräten für das Gast-Betriebssystem |
| Run strategy | `Always` | am Laufen halten; wenn sie sich selbst herunterfährt, wird sie wieder gestartet |
| Disks | `spravochnik` | der Datenträger, den Sie erstellt haben |
| Cloud init | siehe unten | bringt das Verzeichnis auf Port 8080 zum Laufen |

Im cloud-init-Feld:

```yaml
#cloud-config
password: ubuntu
chpasswd: { expire: false }
ssh_pwauth: true
write_files:
  - path: /opt/directory/index.html
    content: |
      <!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Справочник</title></head><body><h1>Справочник сотрудников</h1><ul><li>Иванов И. — 101</li><li>Петров П. — 102</li></ul></body></html>
  - path: /etc/systemd/system/directory.service
    content: |
      [Unit]
      Description=Staff directory
      After=network.target
      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/directory
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd: [ "systemctl daemon-reload", "systemctl enable --now directory" ]
```

Dieses cloud-init macht aus dem Verzeichnis einen Server: Es legt eine HTML-Seite mit der Mitarbeiterliste ab und richtet einen Dienst ein, der sie über HTTP auf Port 8080 ausliefert. `python3` ist im Ubuntu-Image bereits vorhanden, es muss also nichts installiert werden und kein Internet ist nötig. Port 8080 wurde nicht zufällig gewählt: Genau auf ihn schaut der `Service spravochnik-http`, den die Lehrkraft im Voraus erstellt hat.

⚠️ **Ein Passwort im Klartext — nur für das Lab.** Auf einer echten Maschine stünden hier `sshKeys` und gar kein Passwort. Wir nehmen den kurzen Weg, um keine Workshop-Zeit mit dem Austausch von Schlüsseln zu verbringen.

**Dasselbe als Text.** Beide Objekte, der Datenträger und die Maschine, liegen in einer Datei, `staff-directory-vm.yaml`, und werden mit einem einzigen Befehl erstellt: zuerst der Datenträger, dann die Maschine. Öffnen Sie die Datei vor dem Anwenden und ersetzen Sie darin den Platzhalter `tenant-workshopXX` durch den Namen Ihres eigenen Tenants — sonst landen die Objekte am falschen Ort.

```bash
# KUBECONFIG ist die Variable, aus der kubectl die Cluster-Adresse und die Anmeldedaten liest.
# Hier brauchen Sie die TENANT-Zugangsdatei: Die VM lebt im Tenant auf dem Management-Cluster.
export KUBECONFIG=~/.kube/config
# apply = „bringe den Cluster in den Zustand, der in der Datei steht". Keine Objekte — es erstellt sie,
# Objekte vorhanden — es bringt sie in den beschriebenen Zustand.
#   -f   die Beschreibung aus einer Datei lesen
kubectl apply -f staff-directory-vm.yaml
```

**Was Sie sehen sollten:** zwei Zeilen mit `created` — eine für den Datenträger und eine für die Maschine.

<details>
<summary><b>Genauer betrachtet: was in staff-directory-vm.yaml steckt</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
```

Dieselbe API-Gruppe, in der Buckets, Datenbanken und Queues leben. Die virtuelle Maschine ist hier kein eigenes Subsystem mit eigener Oberfläche, sondern ein Katalog-Objekt genau wie Redis. Das ist der inhaltliche Kern des Satzes „in einer Oberfläche und über eine API“.

```yaml
spec:
  source:
    image:
      name: ubuntu-22.04
  storage: 20Gi
```

Ein Image-Name aus der gemeinsamen Sammlung der Plattform, keine URL: Die Sammlung ist über den gesamten Cluster gemeinsam, und das Image wird einmal heruntergeladen. `storage` kann nicht kleiner sein als das Image selbst — `ubuntu-22.04` entpackt sich auf 20Gi. Wenn Sie ein eigenes Image brauchen, gibt es an derselben Stelle `source.http` mit einem Link und `source.disk` zum Klonen eines bestehenden Datenträgers.

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
```

Die Maschinengröße wird aus einer fertigen Liste genommen, nicht über vCPU- und RAM-Felder eingestellt. `u1.medium` sind 1 CPU und 4 GB. Dieselbe Liste wird verwendet, wenn Sie einen Node für einen Kubernetes-Cluster bestellen, und das ist kein Zufall: Ein Cluster-Node ist genauso eine VMInstance.

```yaml
  instanceProfile: ubuntu
```

Das Profil des Gast-Betriebssystems: welche Controller, Treiber und Geräte der Maschine gereicht werden, damit der Gast sie erkennt. Die nächste Entsprechung ist „Guest OS type“ beim Erstellen einer VM in vSphere, und die Folgen sind dieselben: Das falsche Profil beschert Ihnen eine Maschine, die bootet, aber ihren Datenträger nicht sieht.

```yaml
  runStrategy: Always
```

Der gewünschte Energiezustand. `Always` — am Laufen halten: Wenn der Gast von innen herunterfährt, wird die Maschine wieder gestartet. `Halted` — ausgeschaltet. `Manual` — so belassen, wie es ist, niemand greift ein. Achten Sie auf die Formulierung, sie ist dieselbe wie `replicas` in einem Deployment: nicht „schalte sie ein“, sondern „halte sie eingeschaltet“.

```yaml
  disks:
    - name: spravochnik
```

Eine Liste von Datenträgern nach VMDisk-Objektnamen. Ein zweiter Datenträger für Daten wird genau hier als zweite Zeile hinzugefügt.

```yaml
  cloudInit: |
    #cloud-config
    write_files:
      - path: /opt/directory/index.html
      - path: /etc/systemd/system/directory.service
    runcmd: [ "systemctl daemon-reload", "systemctl enable --now directory" ]
```

cloud-init ist der Standardmechanismus zur Erstprovisionierung, den jedes Cloud-Linux-Image versteht. Er läuft einmal, beim ersten Einschalten. Hier tut er drei Dinge: legt die HTML-Seite des Verzeichnisses ab, richtet einen systemd-Dienst ein, der diese Seite über HTTP auf Port 8080 ausliefert, und startet den Dienst. Er ist das Gegenstück zu einer Customization Specification in vSphere, nur ist es Text im Manifest statt eines Assistenten in der Oberfläche — was bedeutet, dass er in Git liegt und zusammen mit allem anderen reviewt wird.

Gerade wegen dieses Blocks wird das Verzeichnis von außen sichtbar: Der `Ingress`, den die Lehrkraft im Voraus erstellt hat, leitet die Domain zum `Service spravochnik-http` und dieser wiederum zu Port 8080 innerhalb der Maschine. Sobald der Dienst auf 8080 hochkommt, greift die Veröffentlichung ihn von selbst auf.

### Was dieses Manifest nicht hat und nicht haben wird

**Ein `replicas`-Feld.** `VMInstance` hat keines. Eine virtuelle Maschine ist ein einzelnes Objekt; wenn Sie zwei Maschinen brauchen, erstellen Sie zwei Objekte mit unterschiedlichen Namen.

Das ist ein grundlegender Unterschied zu einem `Deployment`, und es ist kein Mangel. Kopien in einem Deployment sind austauschbar: Jede von ihnen bedient jede Anfrage, und eine zu verlieren ist kein Drama. Virtuelle Maschinen sind nicht austauschbar — jede hat ihren eigenen Zustand auf ihrem eigenen Datenträger, und „mach noch eine genau solche“ bedeutet etwas völlig anderes als bei einem Container.

Die praktische Folge: **Die Selbstheilung, die Sie im Lab zum Löschen von Pods gesehen haben, gibt es für eine VM nicht.** Löschen Sie einen Pod, und der Cluster erstellt in Sekunden einen neuen. Löschen Sie eine VMInstance, und die Maschine ist weg, und der einzige Weg, sie zurückzuholen, ist von Hand, indem Sie den überlebenden Datenträger anhängen. Hier sind Sie genau an derselben Stelle wie in vSphere, und das sollte man vorab wissen, statt es unterwegs herauszufinden.

</details>

Das erste Einschalten dauert 3–5 Minuten: cloud-init dehnt das Dateisystem über den ganzen Datenträger aus und bringt den Verzeichnisdienst zum Laufen. Wir warten nicht untätig darauf — im nächsten Schritt prüfen wir genau, was mit der Veröffentlichung geschieht, während die Maschine noch bootet.

## Schritt 2. An die Domain klopfen, während die Maschine bootet

📍 **Wo:** auf dem Bastion (im Bastion-Terminal), in einem separaten Fenster. Oder direkt im Browser auf Ihrem eigenen Laptop.

Die Lehrkraft hat das Verzeichnis im Voraus veröffentlicht: Ihr Tenant hat bereits einen `Ingress spravochnik` mit dem Host `spravochnik.workshopXX.workshop.aenix.io` und einen `Service spravochnik-http`, der zu Port 8080 innerhalb der Maschine führt. Die Veröffentlichung ist bereit, das Verzeichnis in dem Moment aufzunehmen, in dem es zu antworten beginnt. Prüfen wir sie gleich jetzt, ohne zu warten, bis die Maschine fertig geladen hat.

```bash
# curl — „geh zur Adresse und zeig die Antwort". XX durch Ihre eigene Tenant-Nummer ersetzen.
#   --max-time 5   nach 5 Sekunden aufgeben, statt lange zu warten
curl --max-time 5 http://spravochnik.workshopXX.workshop.aenix.io
```

**Was Sie sehen werden:**

```
<html><head><title>503 Service Temporarily Unavailable</title></head>
<body><center><h1>503 Service Temporarily Unavailable</h1></center></body></html>
```

> **Halten Sie inne und denken Sie nach, bevor Sie weiterlesen.**
>
> Die Lehrkraft hat den Ingress erstellt, die Domain ist konfiguriert, und die Maschine haben Sie hochgefahren.
> Warum antwortet die Domain mit `503` statt mit der Seite des Verzeichnisses?

<details>
<summary><b>Die Antwort und eine Lehre, die über diesen Fehler hinausgeht</b></summary>

Weil das Verzeichnis innerhalb der Maschine noch nicht lauscht.

`503` bedeutet nicht „der Ingress ist kaputt“. Der Ingress ist vorhanden und weiß, wohin er den Verkehr leiten soll: zum `Service spravochnik-http`, der die Pods Ihrer Maschine auswählt und die Anfrage an Port 8080 weiterleitet. Aber während cloud-init das Dateisystem ausdehnt und den Dienst einrichtet, antwortet auf 8080 innerhalb der Maschine noch niemand — der Service hat kein einziges bereites Backend. Und genau das meldet der Ingress: Die Route existiert, aber es ist noch niemand da, der auf ihr antwortet.

Der Antwortcode ist hier die Diagnose selbst:

| Was Sie sehen | Was es bedeutet |
|---|---|
| `503` | der Ingress ist vorhanden, aber dahinter gibt es kein bereites Backend |
| `404` | der Ingress existiert, aber die Regel führt zum falschen Service |
| keine Antwort, Timeout | es wurde überhaupt kein Ingress mit diesem Host erstellt |

**Die Lehre reicht über diesen Fehler hinaus.** Ein `503` von einem Ingress betrifft die Bereitschaft des Backends, nicht den Ingress selbst. Denselben `503` bekommen Sie, wenn die Anwendung hinter der Domain abstürzt oder ihr Pod seine Readiness-Prüfung noch nicht bestanden hat. Veröffentlichung nach außen und Bereitschaft der Workload sind zwei verschiedene Dinge: Die Domain wird im Voraus eingerichtet und ist eine Weile leer, und sie füllt sich genau dann, wenn dahinter jemand erscheint, der bereit ist zu antworten. Für eine VM ist das „wenn der Dienst auf 8080 hochkam“; für einen Container ist es „wenn der Pod die Readiness bestanden hat“. Der Mechanismus ist derselbe, und das ist die Bedeutung des Satzes „eine VM wird auf dieselbe Weise veröffentlicht wie eine containerisierte Anwendung“.

</details>

## Schritt 3. In die Maschine gelangen

📍 **Wo:** im Dashboard, auf der Karte der Maschine `spravochnik`.

Die Karte hat eine Konsole — es ist derselbe Bildschirm wie „Open Console“ in vSphere. Öffnen Sie sie. Login `ubuntu`, Passwort `ubuntu`.

⚠️ **Wenn die Konsole einen schwarzen Bildschirm und einen blinkenden Cursor zeigt — warten Sie.** cloud-init ist noch nicht fertig, und die Eingabeaufforderung erscheint von selbst. Starten Sie die Maschine nicht neu: Ein Neustart mitten in cloud-init lässt sie halb konfiguriert zurück.

**Derselbe Login vom Terminal aus.** `virtctl` ist ein separater Befehl für die Arbeit mit virtuellen Maschinen: Konsole, Port-Forwarding, Ein- und Ausschalten. Er wird als einzelne Datei installiert; wie genau, steht in `workshop/README.md`.

Eine Eigenheit ihrer Syntax lohnt sich, vorab durchzugehen, sonst kommt Ihr allererster Befehl mit einer Ablehnung zurück. Das Ziel für `virtctl` wird nicht als bloßer Name angegeben, sondern mit einem Typ-Präfix: `vmi/<name>`. `vmi` ist virtual machine instance, die **laufende Instanz** der Maschine; das `VMInstance`-Objekt, das Sie erstellt haben, und die laufende Instanz sind zwei verschiedene Objekte in der API. Unter Tenant-Zugang sind die Rechte auf die **Subresource** `virtualmachineinstances` (`console` und `portforward`) vergeben, nicht auf die gesamten `virtualmachines`-Objekte — ein bloßer Name trifft das vm-Objekt und kommt mit `forbidden` zurück. Die Plattform bildet den Instanznamen aus dem Präfix `vm-instance-` plus dem Namen Ihrer Maschine: `spravochnik` ist die Instanz `vm-instance-spravochnik`.

```bash
# Tenant-Zugang: die Maschine lebt im Tenant
export KUBECONFIG=~/.kube/config
# console = mit der seriellen Konsole der Maschine verbinden. Es ist derselbe Bildschirm, den
# „Open Console" in vSphere gibt, nur textbasiert:
#   --namespace  in welchem Abschnitt des Clusters zu suchen ist; bei Ihrem Tenant heißt er
#                tenant- plus Ihr Login, XX durch Ihre eigene Nummer ersetzen
#   vmi/...      das Ziel: die laufende Instanz der Maschine, nicht die VMInstance-Beschreibung
virtctl console --namespace=tenant-workshopXX vmi/vm-instance-spravochnik
```

Wenn der Bildschirm nach dem Verbinden leer ist — drücken Sie Enter, und die Login-Aufforderung erscheint. Zum Verlassen der Konsole — `Ctrl+]`. Die Namen aller laufenden Instanzen in Ihrem Tenant zeigt `kubectl --kubeconfig ~/.kube/config get vminstance -n tenant-workshopXX`.

Von innen ist es ein gewöhnliches Ubuntu. Vergewissern Sie sich, dass das Verzeichnis hochgekommen ist:

```bash
uname -a                       # Kernel und Architektur: dieselbe Zeile wie auf einem Bare-Metal-Server
systemctl status directory     # der Verzeichnisdienst: sollte active (running) sein
curl -s localhost:8080 | head  # dieselbe Seite, aber von innerhalb der Maschine selbst angefragt
```

Wenn `systemctl status directory` `active (running)` zeigt und `curl` auf `localhost:8080` das HTML mit der Mitarbeiterliste zurückgab — ist der Server bereit, und die Veröffentlichung nach außen tauscht gleich den `503` gegen die Seite. Von Kubernetes ist innen keine Spur, und das soll auch so sein: Der Gast weiß nicht, dass er in einem Cluster ist — genau wie eine VM in vSphere nichts über vCenter wissen muss.

## Schritt 4. Die Domain antwortet — das Verzeichnis ist veröffentlicht

📍 **Wo:** auf dem Bastion (im Bastion-Terminal). Oder im Browser auf Ihrem eigenen Laptop.

Dieselbe Anfrage, die `503` zurückgab, aber jetzt ist der Dienst auf 8080 hochgekommen. Setzen Sie Ihre eigene Nummer ein.

```bash
curl http://spravochnik.workshopXX.workshop.aenix.io
```

**Was Sie sehen sollten** — das HTML der Seite des Verzeichnisses:

```html
<h1>Справочник сотрудников</h1><ul><li>Иванов И. — 101</li><li>Петров П. — 102</li></ul>
```

Öffnen Sie diese Adresse in einem Browser, und Sie sehen dieselbe Liste. Das Verzeichnis ist von außen unter einem menschenfreundlichen Domainnamen sichtbar, mit HTTPS von der Plattform, ohne ein einziges Ticket an das Netzwerk oder für ein Zertifikat.

**Sehen wir uns an, was gerade passiert ist.**

Eine virtuelle Maschine mit Ubuntu, die nichts über Kubernetes weiß, lauscht auf gewöhnlichem HTTP auf einem gewöhnlichen Port. Von außen erreicht man sie über die Domain `spravochnik.workshopXX.workshop.aenix.io`, und die Anfrage gelangt zu ihr über denselben Ingress, der containerisierte Anwendungen veröffentlicht. Keine Agenten innerhalb des Gasts, keine Gateways, keine „Integration“. Für die Veröffentlichung macht es keinen Unterschied, wer hinter der Domain steht — ein nginx-Pod oder eine ganze virtuelle Maschine: Sie sieht einen `Service`, hinter dem `Service` steht ein bereites Backend, und das genügt.

Genau das bedeutet „Legacy muss nicht containerisiert werden“. Das Verzeichnis von 2011 wird weiter so funktionieren, wie es immer funktioniert hat — und von außen sieht es aus wie jeder neue „Propusk“-Dienst: ein Name, eine Domain, HTTPS.

## Überprüfung

📍 **Wo:** auf dem Bastion (im Bastion-Terminal), im selben Fenster, in dem Sie mit `kubectl` gearbeitet haben.

Das Skript prüft nicht das Vorhandensein von Objekten, sondern die Funktion im Kern: Der Domainname liefert ein `200` und es ist die Seite des Verzeichnisses, die Maschine selbst läuft, und der `Ingress`, der sie veröffentlicht, ist vorhanden. Die Prüfung über die Domain funktioniert auch ohne Tenant-Zugang — dafür genügt `curl`; der Tenant-Zugang fügt die Prüfungen des Maschinenzustands hinzu.

```bash
# Tenant-Zugang: von hier nimmt das Skript die VM selbst und den Ingress
export KUBECONFIG=~/.kube/config
# Ihr Login ohne das Wort tenant-: daraus baut das Skript sowohl den Abschnittsnamen tenant-workshopXX
# als auch den Domainnamen spravochnik.workshopXX.workshop.aenix.io
export COZY_TENANT=workshopXX
# das ./ vor dem Namen bedeutet „die Datei aus dem aktuellen Ordner", also aus labs/12-vm
./check.sh
```

⚠️ **Unter Windows wird das Skript aus WSL ausgeführt**, nicht aus PowerShell — wie man es installiert, steht am Anfang von Lab 0. Ohne WSL können Sie das Lab dennoch abschließen, aber es gibt keinen Artefakt-Bericht.

`COZY_TENANT` ist zwingend — ohne ihn stoppt das Skript sofort: Die Domain wird daraus gebaut. Ist der Tenant-Zugang nicht gesetzt, werden die Prüfungen des Maschinenzustands mit einer Warnung übersprungen, während die Hauptprüfung — die Antwort über die Domain — trotzdem läuft.

## Aufräumen

Lassen Sie die virtuelle Maschine stehen, wenn Sie das Monitoring-Lab planen: Ihr Verbrauch taucht auch in den Graphen auf und gibt eine gute Illustration ab. Wenn nicht — löschen Sie die Maschine und den Datenträger über das Dashboard.

⚠️ **Löschen Sie in der richtigen Reihenfolge: zuerst die Maschine, dann den Datenträger.** Ein Datenträger, der an eine laufende Maschine angehängt ist, lässt sich nicht löschen, und Sie erhalten ein Objekt, das im Löschzustand hängen bleibt.

Der `Ingress` und der `Service`, die das Verzeichnis veröffentlichen, wurden von der Lehrkraft erstellt — fassen Sie sie nicht an, sie werden vom nächsten Teilnehmer auf dieser Testumgebung gebraucht.

Die Kosten des Aufräumens sind hier ehrlich gesagt höher als in den anderen Labs: Ein Datenträger mit Daten ist ein Datenträger mit Daten, und er verschwindet nicht augenblicklich. Andererseits erforderte seine Erstellung weder ein Ticket für Speicherplatz noch eine Freigabe.

## Was wir jetzt können

- Eine virtuelle Maschine in einem Tenant hochfahren — mit der Maus und als Text
- Erklären, warum der Datenträger und die Maschine zwei Objekte sind und was das bringt
- Eine Workload nach außen über Ingress und eine Domain veröffentlichen — auf dieselbe Weise wie einen Container
- Ein `503` von einem Ingress als „hinter der Domain ist noch niemand da, der antwortet“ lesen, nicht als Störung
- An einem lebendigen Beispiel zeigen, dass der Umzug von Legacy dessen Umschreiben nicht erfordert

## Und in vSphere wäre das

Eine VM in vSphere ist Heimspiel, und sie wird dort auf die vertraute Weise erstellt. Der Unterschied ist nicht die Maschine selbst, sondern sie nach außen unter einem menschenfreundlichen Namen verfügbar zu machen.

Um diese Maschine in vSphere über eine Domain zu veröffentlichen, bräuchten Sie einen Reverse-Proxy oder Load-Balancer als eigenes Produkt, ein Netzwerk-Ticket für eine externe Adresse, ein DNS-Ticket für den Namen und ein Security-Ticket für das Zertifikat. Drei oder vier Befehle, drei oder vier Systeme, und die allgemeine Frage „wer betreibt das alles“. Hier ist die Veröffentlichung ein `Ingress`-Objekt, das die Lehrkraft im Voraus eingerichtet hat, und eine Domain, die sich in der Sekunde füllt, in der die Maschine zu antworten beginnt.

**Wo vSphere ehrlicherweise bequemer ist.** Was das Verwalten der virtuellen Maschinen selbst angeht, ist vCenter noch reichhaltiger, und es hat keinen Sinn, so zu tun, als wäre es anders:

| Was | vSphere | Cozystack |
|---|---|---|
| Vorlagen und Klonen | ausgereift, mit Gast-Anpassung | Datenträger-Klonen gibt es, einen Anpassungsassistenten nicht |
| Snapshots | vertraut, mit Baum | vorhanden, aber das Ökosystem darum herum ist jünger |
| Live-Migration | vMotion, über Jahre verfeinert | vorhanden, aber seltener genutzt und weniger erprobt |
| Rechte auf einen VM-Ordner | granular | Rechte auf Tenant-Ebene, keine Ordner |
| Konsole und Gast-Tools | VMware Tools mit voller Telemetrie | qemu-guest-agent, weniger Daten |

Wenn Sie **nur** virtuelle Maschinen brauchen — die ehrliche Antwort ist, dass ein Umzug um des Umzugs willen keinen Sinn ergibt. Der Gewinn zeigt sich dort, wo Sie neben den VMs noch etwas anderes brauchen: Cluster, Datenbanken, Queues, Registries, Objektspeicher, Veröffentlichung über eine Domain. Dann haben Sie statt fünf Produkten mit fünf Berechtigungsmodellen einen Katalog, und das Verzeichnis von 2011 steht darin neben allem anderen.
