## 17. Genauer betrachtet: was in convert.sh steckt

Das Skript besteht aus fünf Schritten, und jeder gibt aus, womit er gerade beschäftigt ist.

**Schritt 1 — Prüfung der Hardware-Beschleunigung.** Es sucht nach dem Gerät `/dev/kvm`.
Intern startet `virt-v2v` eine winzige virtuelle Maschine, um in das Image hineinzukommen — und wenn der
Prozessor in unsere Maschine durchgereicht wird, läuft diese verschachtelte Virtualisierung schnell. Andernfalls
springt ein Software-Modus ein: langsamer, aber er funktioniert. Die Zeile
`LIBGUESTFS_BACKEND=direct` ist genau dieses Umschalten in einen solchen Modus.

**Schritt 2 — Herunterladen des Quell-Images.**

```bash
wget -O source.ova "$OVA_URL"
```

Es holt `app-1.ova` aus dem gemeinsamen Speicher des Workshops — genau dem aus der Karte weiter oben. Die
Lehrkraft hat die Datei dort vorab hochgeladen. **In Ihrem eigenen Projekt stünde an dieser Stelle ein
Export aus vSphere:** `Export OVF Template` oder `ovftool`, und danach dasselbe Umpacken.

**Schritt 3 — das Umpacken selbst.**

```bash
virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app
```

`-i ova` — was hineingeht: eine Datei im OVA-Format. `-o local -os /root/out` — wohin das Ergebnis
kommt: in den lokalen Ordner `/root/out`. `-of qcow2` — ein **Pflichtflag**: ohne es wählt
`virt-v2v` ein Standardformat, und die Plattform nimmt einen solchen Datenträger nicht an. `-on app` —
wie das Ergebnis heißen soll, und daher stammt der Dateiname `app.qcow2`.

Das dauert einige Minuten — auf dem Bildschirm laufen Zeilen wie `Copying disk 1/1` durch. Genau
hier passiert jene zweite, unsichtbare Arbeit an den Treibern, von der oben die Rede war.

**Schritt 4 — Hochladen in Ihren Bucket.**

```bash
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app.qcow2 "mybucket/$BUCKET/app.qcow2"
```

`mc alias set` merkt sich die Speicheradresse und die Schlüssel unter dem Kurznamen `mybucket`, damit Sie
sie danach nicht in jedem Befehl wiederholen müssen. `mc cp` kopiert die Datei — die Syntax ist bewusst
dieselbe wie beim gewöhnlichen `cp`.

**Schritt 5 — ein Link für die Plattform.**

```bash
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"
```

Es erzeugt einen temporären signierten Link, sieben Tage lang gültig (168 Stunden). Signiert — das heißt,
in die Adresse ist eine kryptografische Signatur eingebettet, und mit diesem Link kann jeder die Datei
herunterladen, aber nur mit ihm und nur, solange er lebt. Man muss den Bucket nicht für die ganze Welt
öffnen, und man muss der Plattform auch nicht die Zugriffsschlüssel übergeben.

Den Link finden Sie in der Ausgabe hinter dem Wort `Share:` — Sie brauchen ihn in der nächsten Phase.
