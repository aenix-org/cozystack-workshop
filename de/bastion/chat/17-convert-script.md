## 17. Ein genauerer Blick: was in convert.sh steckt

Das Skript besteht aus fünf Schritten, und jeder gibt aus, womit er gerade beschäftigt ist.

**Schritt 1 — Prüfung auf Hardware-Beschleunigung.** Es sucht nach dem Gerät `/dev/kvm`.
Intern startet `virt-v2v` eine winzige virtuelle Maschine, um in das Image hineinzukommen — und
wenn der Prozessor in unsere Maschine durchgereicht wird, läuft diese verschachtelte
Virtualisierung schnell. Ist das nicht der Fall, springt ein Software-Modus ein: langsamer, aber
er funktioniert. Die Zeile `LIBGUESTFS_BACKEND=direct` ist genau dieser Umschalter in einen
solchen Modus.

**Schritt 2 — Herunterladen des Quell-Image.**

```bash
wget -O source.ova "$OVA_URL"
```

Es holt `app-1.ova` aus dem gemeinsamen Speicher des Workshops — genau dem aus der Karte oben. Die
Lehrkraft hat die Datei dort vorab hochgeladen. **In Ihrem eigenen Projekt stünde an dieser Stelle
ein Export aus vSphere:** `Export OVF Template` oder `ovftool`, und danach dieselbe Neuverpackung.

**Schritt 3 — die Neuverpackung selbst.**

```bash
virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app
```

`-i ova` — was hineingeht: eine Datei im OVA-Format. `-o local -os /root/out` — wohin das Ergebnis
soll: in den lokalen Ordner `/root/out`. `-of qcow2` — ein **zwingend erforderliches** Flag: ohne
es wählt `virt-v2v` ein Standardformat, und die Plattform nimmt eine solche Festplatte nicht an.
`-on app` — wie das Ergebnis benannt wird, und daher kommt der Dateiname `app.qcow2`.

Das dauert einige Minuten — Zeilen wie `Copying disk 1/1` laufen über den Bildschirm. Genau hier
geschieht jene zweite, unsichtbare Arbeit an den Treibern, die oben erwähnt wurde.

**Schritt 4 — Hochladen in Ihren Bucket.**

```bash
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app.qcow2 "mybucket/$BUCKET/app.qcow2"
```

`mc alias set` merkt sich die Speicheradresse und die Schlüssel unter dem kurzen Namen `mybucket`,
damit Sie sie danach nicht in jedem Befehl wiederholen müssen. `mc cp` kopiert die Datei — die
Syntax ist bewusst dieselbe wie beim gewöhnlichen `cp`.

**Schritt 5 — ein Link für die Plattform.**

```bash
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"
```

Er erzeugt einen temporären, signierten Link mit einer Gültigkeit von sieben Tagen (168 Stunden).
Signiert — das heißt, eine kryptografische Signatur ist in die Adresse eingebacken, und mit diesem
Link kann jeder die Datei herunterladen, aber nur mit ihm und nur solange er gültig ist. Es ist
nicht nötig, den Bucket für die ganze Welt zu öffnen, und ebenso wenig, der Plattform Ihre
Zugriffsschlüssel zu übergeben.

Suchen Sie den Link in der Ausgabe nach dem Wort `Share:` — Sie brauchen ihn in der nächsten Phase.
