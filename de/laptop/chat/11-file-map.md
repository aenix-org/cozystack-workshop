## 11. Dateiübersicht: Was wo liegt und wo es läuft

**Lesen Sie das einmal — danach müssen Sie nicht mehr raten**

Im Repository gibt es zwei Arten von Dateien, und sie liegen an unterschiedlichen Orten. Das ist das
Wichtigste, was Sie verstehen sollten, bevor Sie mit dem praktischen Teil beginnen.

**Manifeste — `manifests/*.yaml`. Werden von Ihrem Laptop aus angewendet.**
Sie beschreiben, was im Cluster erstellt werden soll. Der Befehl ist immer derselbe: `kubectl apply -f <datei>`.

• `01-bucket.yaml` — Speicher für das Image · Schritt 1
• `02-conversion-vm.yaml` — die Konverter-Maschine · Schritt 2
• `03-app-vm.yaml` — Ihre app-VM · Schritt 4 (hier fügen Sie den presigned-Link von Hand ein)
• `04-managed.yaml` — Postgres und Kafka aus dem Katalog · Schritt 5

**Skripte — `scripts/*`. Sie laufen nicht auf Ihrer Maschine, sondern innerhalb der VMs.**
Auf Ihrem Laptop brauchen Sie sie überhaupt nicht.

• `convert.sh` — innerhalb der Konverter-Maschine · Schritt 3
• `netfix-dhcp.sh` — innerhalb Ihrer app-VM · Schritt 6
• `connect-managed.sh` — innerhalb Ihrer app-VM · Schritt 7
• `orders-schema.sql` — eine Tabelle für die Datenbank, von innerhalb der app-VM · Schritt 8 (wir geben
  sie als Abfrage ein; die Datei ist da, damit Sie genau sehen, was erstellt wird)

**Wie ein Skript in eine Maschine gelangt — und warum das unterschiedlich ist.**

Die **Konverter-Maschine** hat ein Netzwerk, also lädt sie die Datei selbst herunter. Das Repository
ist öffentlich, es werden keine Schlüssel benötigt:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/convert.sh
```

**Ihre app-VM hat anfangs überhaupt kein Netzwerk** — genau dieser kaputte Zustand ist es, den wir
in Schritt 6 beheben. Es gibt nichts, womit man herunterladen könnte, und nichts, wohin, und Dateien
lassen sich nicht über die Konsole übergeben. Deshalb laden Sie `netfix-dhcp.sh` und `connect-managed.sh`
nicht herunter, sondern **tippen sie von Hand ein**: es sind jeweils nur zwei oder drei Befehle, und
ich gebe sie Ihnen fertig im Chat. Die Dateien selbst im Repository sind dasselbe, nur ausführlich
ausgeschrieben und mit Kommentaren: praktisch zum späteren Nachlesen, wenn Sie das bei sich allein
wiederholen.

⚠️ **Die Feinheit, an der alles scheitert.** Das Ersetzen von `tenant-workshopXX` durch Ihre eigene
Nummer haben Sie auf Ihrem Laptop vorgenommen. Die innerhalb der Konverter-Maschine heruntergeladene
Datei kommt frisch an, mit Platzhaltern — die Werte werden dort erneut von Hand eingetragen.
