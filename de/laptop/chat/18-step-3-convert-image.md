## 18. Schritt 3: Image konvertieren

**Ein VMware-Image in ein KVM-Image umwandeln**

📍 **Wo:** im Konvertierungsrechner, auf dem Sie sich gerade über die Konsole angemeldet haben. Nicht auf Ihrem Laptop.

📄 Wir arbeiten mit `scripts/convert.sh`. Dieser Rechner hat Netzwerkzugang, deshalb lädt er die
Datei selbst herunter — Sie müssen nichts über die Zwischenablage kopieren.

Holen Sie das Skript direkt von GitHub auf den Rechner:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/convert.sh
```

Öffnen Sie es:
```bash
nano convert.sh
```

**Jetzt kommen die drei Werte ins Spiel, die Sie sich in Schritt 1 notiert haben.** Am Anfang der
Datei gibt es einen Block „FÜGEN SIE IHRE WERTE EIN" (im Skript «FÜGEN SIE IHRE WERTE EIN») — ersetzen Sie die dortigen
Platzhalter durch Ihre eigenen und lassen Sie die Anführungszeichen stehen:

```
BUCKET="ihr-bucket-name"
ACCESS_KEY="ihr-accessKey"
SECRET_KEY="ihr-secretKey"
```

Die Zeile `S3_ENDPOINT` und den Link zum Quell-Image lassen Sie unangetastet — sie sind bereits
korrekt und für alle gleich.

Speichern in nano: `Ctrl+O`, dann `Enter`, dann `Ctrl+X` zum Beenden. Prüfen Sie, dass keine
Platzhalter übrig sind:
```bash
grep ВСТАВЬТЕ convert.sh || echo "all filled in, ready to run"
```

Führen Sie es aus — immer über `sudo`, das Skript braucht root-Rechte:
```bash
sudo bash convert.sh
```

Was dabei intern passiert: Das Skript lädt das Quell-Image herunter, führt `virt-v2v` aus,
komprimiert das Ergebnis und lädt es in Ihren Bucket hoch.

Die wichtigste Arbeit erledigt `virt-v2v`. Es ändert mehr als nur das Dateiformat: Es schleust
virtio-Treiber in das Gastsystem ein und korrigiert den Bootloader. Ohne das startet die Maschine
auf dem neuen Hypervisor überhaupt nicht.

⏳ **Das dauert etwa fünf Minuten.** Unsere Testumgebung hat keine verschachtelte Virtualisierung,
deshalb läuft die Konvertierung im Emulationsmodus. Der Fortschritt ist in der Konsole zu sehen — schließen Sie sie nicht.

Am Ende gibt das Skript einen **presigned Link** zu Ihrem Image aus — suchen Sie in der Ausgabe die Zeile,
die mit dem Wort `Share:` beginnt, der Link steht direkt dahinter.

**Was Sie damit tun:** Kopieren Sie ihn in denselben Notizzettel. Im nächsten Schritt kehren Sie zu Ihrem Laptop zurück, öffnen `manifests/03-app-vm.yaml` und fügen ihn in das Feld `url` ein — dorthin, wo
aktuell der Platzhalter `ВСТАВЬТЕ_PRESIGNED_URL` steht. Genau der, vor dem ich Sie gewarnt habe,
als wir die Nummern eingetragen haben.

Das ist ein temporärer signierter Link: Der Speicher ist nach außen nicht offen, und den Link haben Sie
mit Ihren eigenen Schlüsseln erstellt. Er lebt eine Woche — für den Workshop und zum Experimentieren danach
reichlich.
