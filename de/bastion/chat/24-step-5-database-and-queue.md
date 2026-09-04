## 24. Schritt 5: Datenbank und Warteschlange aus dem Katalog

**Wir bringen ein verwaltetes Postgres und Kafka zum Laufen**

📍 **Wo:** auf dem Bastion.

Im ursprünglichen System lebten die Datenbank und die Warteschlange auf getrennten CentOS-7-VMs — eben jenen
`192.168.10.30` und `192.168.10.40` aus der Konfiguration. Diese **übernehmen wir nicht**: statt ihrer nehmen wir
die Dienste der Plattform. Ein veraltetes Betriebssystem zu patchen ist nicht mehr Ihre Aufgabe.

<details>
<summary><b>Wozu die Anwendung eine Warteschlange braucht und was diese überhaupt tut</b></summary>

Die Frage ist berechtigt: dass eine Datenbank gebraucht wird, ist offensichtlich, aber was tut die Warteschlange hier.

**Wie die Anwendung funktioniert.** Ein Nutzer legt eine Bestellung an. Würde die Anwendung die gesamte
Arbeit auf einmal erledigen — die Bestellung erfassen, die Berechnungen ausführen, die E-Mail versenden, das
Nachbarsystem anstoßen —, dann würde der Nutzer warten, bis all das fertig ist. Und wäre das Nachbarsystem
ausgefallen, würde er bis zum Timeout warten und einen Fehler bekommen, obwohl die Bestellung bereits angelegt war.

Deshalb wird die Arbeit in zwei Teile zerrissen. Die Anwendung schreibt die Bestellung mit dem Status `NEW` in die
Datenbank, legt eine Nachricht „Bestellung Nr. 123 ist aufgetaucht“ in die Warteschlange und **antwortet dem Nutzer
sofort**. Von dort holt sich ein Handler die Nachricht in seinem eigenen Tempo aus der Warteschlange, erledigt den
schweren Teil und setzt den Status der Bestellung auf `PROCESSED`.

Genau deshalb hat die Tabelle ein Feld `processed_by`. In Schritt 9 werden Sie dort den Wert
`kafka` sehen — und das wird der Beweis dafür sein, dass die Kette „Anwendung → Warteschlange → Handler“
an ihrem neuen Ort wieder zusammengefunden hat.

**Wie es in vSphere war.** Eine eigene VM, auf der Kafka und ZooKeeper von Hand installiert wurden.
Wer sie installiert hat, ist unbekannt, die Version ist die, die damals gerade aktuell war, Updates gab es
kein einziges Mal, und ein Monitoring gibt es nicht. Die klassische Maschine, die alle zu rebooten fürchten.

**Warum die Warteschlange nicht umgezogen werden muss, die Datenbank aber schon.** Der Unterschied liegt darin, was sie speichern.
Die Datenbank hält jede Bestellung der gesamten Geschichte — verlieren Sie sie, verliert das Unternehmen Daten. Die Warteschlange
hält nur die Nachrichten, die gerade jetzt unterwegs sind — Sekunden an Lebensdauer. Eine ordentliche Migration der
Warteschlange besteht darin, den Handler den Rest aufessen zu lassen und auf die neue umzuschalten.
Es gibt nichts zu kopieren.

Das ist eine allgemeine Regel, die es sich vom Workshop mitzunehmen lohnt: **bei einem Umzug quält man sich mit dem,
was Zustand hält.** Alles andere wird von Grund auf neu erzeugt.

</details>

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

Sie kommen nicht sofort hoch — werfen Sie, während Sie warten, im Dashboard einen Blick darauf, was genau erstellt wurde.

**Was erstellt wurde:** ein **Postgres**-Objekt namens `db` — mit einer Datenbank `orders`
und einem Nutzer `orders` darin — und ein **Kafka**-Objekt namens `kafka` mit einem Topic `orders`.
Ändern Sie die Namen nicht: die Adressen weiter unten und die Befehle der nächsten Schritte rechnen mit ihnen.

🖱 **Über das Dashboard:** das ist der anschaulichste Schritt für die Maus. Der Plattformkatalog —
**Postgres → Deploy new**: Name `db`, eine Replik, im Abschnitt users ein Nutzer
`orders`, im Abschnitt databases eine Datenbank `orders`. Dann **Kafka → Deploy new**: Name `kafka`,
eine Replik, Topic `orders`.

**Sie müssen nichts aufschreiben, aber hier sind die Adressen — sie werden in Schritt 7 nützlich sein.** Von innerhalb
des Clusters sind die Datenbank und die Warteschlange über den Namen erreichbar:

• Postgres — `postgres-db-rw.tenant-workshopXX.svc.cozy.local:5432`
• Kafka — `kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local:9092`

Genau diese beiden Zeilen werden zwei Schritte später die festverdrahteten Adressen `192.168.10.30`
und `192.168.10.40` in der Konfiguration der Anwendung ersetzen. Ich schicke sie Ihnen als fertige Befehle; Sie
setzen Ihre eigene Nummer anstelle von `XX` ein.

Merken Sie sich den Unterschied selbst: früher ging die Anwendung an eine festverdrahtete Adresse, jetzt geht sie über den Namen.
Eine Adresse kann sich ändern, ein Name bleibt.
