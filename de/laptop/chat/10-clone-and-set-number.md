## 10. Die Materialien holen und Ihre Nummer eintragen

**Das Repository mit den Manifesten**

📍 **Wo:** auf Ihrem Laptop, im Terminal. Wir legen es in Ihr Home-Verzeichnis — so ist der Pfad bei allen gleich, und ich kann Ihnen leichter helfen.

**Wo Sie das Terminal öffnen:**
• macOS — Spotlight (`Cmd+Leertaste`), „Terminal“ eingeben
• Linux — `Ctrl+Alt+T` in den meisten Umgebungen
• Windows — das Menü „Start“, „PowerShell“ eingeben

**Holen Sie den Ordner mit den Dateien** (drei Befehle, einer nach dem anderen):
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
Der erste Befehl bringt Sie in Ihr Home-Verzeichnis, der zweite lädt den Materialordner dorthin herunter, und der dritte wechselt hinein. Ab hier wird jeder Befehl **von hier aus** ausgeführt — die Pfade darin sind relativ zu diesem Ordner geschrieben.

**Sehen Sie sich an, was heruntergeladen wurde:**
```bash
ls manifests scripts
```
Sie sollten vier Manifeste und vier Skripte sehen — genau die aus der Dateiübersicht.

**Falls Sie das Terminal geschlossen haben oder sich verlaufen** — der Weg zurück ist immer gleich:
```bash
cd ~/cozystack-migration-workshop/workshop
```
Unter Windows ist der Pfad derselbe: `cd $HOME\cozystack-migration-workshop\workshop`.
So prüfen Sie, wo Sie gerade sind: `pwd` (funktioniert auch in PowerShell).

⚠️ Das Anhängsel `/workshop` ist zwingend. Im Repository liegt neben den Workshop-Materialien ein Ordner `labs`
mit eigenständigen Labs — bleiben Sie eine Ebene höher stehen, finden die Befehle weder
`manifests` noch `scripts`.

**Womit Sie Dateien zum Bearbeiten öffnen.** Manifeste sind ganz gewöhnliche Textdateien, es taugt also
alles:
• im Terminal — `nano manifests/03-app-vm.yaml` (speichern: `Ctrl+O`, `Enter`, beenden: `Ctrl+X`)
• mit der Maus auf macOS — `open -a TextEdit manifests/03-app-vm.yaml`
• mit der Maus auf Windows — `notepad manifests\03-app-vm.yaml`
• falls VS Code installiert ist — `code .` öffnet den ganzen Ordner auf einmal, das ist am bequemsten

⚠️ Öffnen Sie `.yaml`-Dateien nicht in Word oder Google Docs: sie ersetzen Anführungszeichen und Bindestriche,
danach lässt sich die Datei nicht mehr anwenden, und der Fehler sieht unerklärlich aus.

In jeder Datei steht der Platzhalter `tenant-workshopXX`. Tragen Sie Ihre Nummer auf einen Schlag überall ein,
sonst landet das Manifest am falschen Ort. Angenommen, Ihr Login ist `workshop03`:

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS** (hier hat `sed` eine andere Syntax — achten Sie auf die leeren Anführungszeichen)
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows** (PowerShell)
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**Prüfen Sie, dass kein einziger Platzhalter übrig ist:**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "clean, you can continue"
```

Eine Stelle rührt der Befehl nicht an: in `manifests/03-app-vm.yaml` die Zeile
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. Diese URL erhalten Sie später, sobald Sie das Image konvertiert haben.
Für den Moment sollten Sie nur wissen, dass sie dort auf Sie wartet.
