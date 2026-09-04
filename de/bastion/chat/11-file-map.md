## 11. Dateiübersicht: Was wo liegt und wo es läuft

**Lesen Sie das einmal — danach müssen Sie nicht mehr raten**

Behalten Sie drei Orte im Kopf, an denen etwas passiert: den **Bastion** (die Maschine, auf die
Sie sich per SSH verbunden haben), die **Konverter-Maschine** und **Ihre app-VM** — die beiden
letzteren werden innerhalb des Clusters erstellt. Im Repository gibt es zwei Arten von Dateien,
und sie laufen an unterschiedlichen Orten.

**Manifeste — `manifests/*.yaml`. Werden vom Bastion aus angewendet.**
Sie beschreiben, was im Cluster erstellt werden soll. Der Befehl ist immer derselbe: `kubectl apply -f <datei>`.

• `01-bucket.yaml` — Speicher für das Image · Schritt 1
• `02-conversion-vm.yaml` — die Konverter-Maschine · Schritt 2
• `03-app-vm.yaml` — Ihre app-VM · Schritt 4 (hier fügen Sie den presigned-Link von Hand ein)
• `04-managed.yaml` — Postgres und Kafka aus dem Katalog · Schritt 5

**Skripte — `scripts/*`. Sie laufen nicht auf dem Bastion, sondern innerhalb der Maschinen im Cluster.**
Auf dem Bastion selbst führen Sie sie nicht aus — Sie wenden dort nur die Manifeste mit `kubectl` an.

• `convert.sh` — innerhalb der Konverter-Maschine · Schritt 3
• `netfix-dhcp.sh` — innerhalb Ihrer app-VM · Schritt 6
• `connect-managed.sh` — innerhalb Ihrer app-VM · Schritt 7
• `orders-schema.sql` — eine Tabelle für die Datenbank, von innerhalb der app-VM · Schritt 8 (wir geben
  sie als Abfrage ein; die Datei ist da, damit Sie genau sehen, was erstellt wird)

**Wie ein Skript in eine Maschine gelangt — und warum das unterschiedlich ist.**

Die **Konverter-Maschine** hat ein Netzwerk, also lädt sie die Datei selbst herunter. Das Repository
ist öffentlich, es werden keine Schlüssel benötigt:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/convert.sh
```

**Ihre app-VM hat anfangs überhaupt kein Netzwerk** — genau dieser kaputte Zustand ist es, den wir
in Schritt 6 beheben. Es gibt nichts, womit man herunterladen könnte, und nichts, wohin, und Dateien
lassen sich nicht über die Konsole übergeben. Deshalb laden Sie `netfix-dhcp.sh` und `connect-managed.sh`
nicht herunter, sondern **tippen sie von Hand ein**: es sind jeweils nur zwei oder drei Befehle, und
ich gebe sie Ihnen fertig im Chat. Die Dateien selbst im Repository sind dasselbe, nur ausführlich
ausgeschrieben und mit Kommentaren: praktisch zum späteren Nachlesen, wenn Sie das bei sich allein
wiederholen.

⚠️ **Die Tenant-Nummer in den Manifesten ist bereits eingetragen** — bei der Vorbereitung des Bastion
wurden die Platzhalter `tenant-workshopXX` durch Ihre Nummer ersetzt. Sie müssen nichts von Hand
eingeben. Das Einzige, was Sie selbst ausfüllen, sind `bucketName`, `accessKey` und `secretKey` in
`convert.sh` (es wird frisch in den Konverter heruntergeladen, mit den Platzhaltern `ВСТАВЬТЕ_...`),
sowie der presigned-Link in `manifests/03-app-vm.yaml` im vierten Schritt.
