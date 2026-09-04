## 9. git installieren

**Das letzte Werkzeug — damit holen wir uns die Materialien**

📍 **Wo:** auf Ihrem Laptop.

Prüfen Sie zuerst, ob Sie es nicht schon haben: auf macOS und in den meisten Linux-Builds ist git
vorinstalliert.
```
git --version
```
Wenn eine Version ausgegeben wurde — überspringen Sie diese Nachricht.

**macOS.** Am einfachsten ist es, den Systemdialog die Arbeit machen zu lassen: Tippen Sie `git --version`, und falls
git nicht installiert ist, bietet macOS von sich aus an, die Entwicklerwerkzeuge zu installieren. Nehmen Sie an.
Oder ausdrücklich:
```bash
xcode-select --install
```
Mit Homebrew:
```bash
brew install git
```

**Linux** — hängt von der Distributionsfamilie ab:
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian, Ubuntu
sudo dnf install -y git                               # Fedora, RHEL, CentOS Stream
```

**Windows** (PowerShell):
```powershell
winget install -e --id Git.Git
```
Schließen Sie danach PowerShell und öffnen Sie es erneut, sonst wird der Befehl nicht gefunden.

⚠️ **Wenn `winget` nicht gefunden wird** — git lässt sich mit einem gewöhnlichen Installationsprogramm installieren: Öffnen Sie
https://git-scm.com/download/win, laden Sie die Datei herunter, führen Sie sie aus und klicken Sie bei jedem
Schritt auf „Weiter“, es muss nichts geändert werden. Nach der Installation — ein neues PowerShell-Fenster.
Oder kommen Sie ohne git aus — mit der Download-ZIP-Variante unten.

**Wir prüfen:**
```
git --version
```

🖱 **Wenn Sie git lieber nicht installieren möchten** — es wird genau einmal gebraucht, um den Ordner
mit den Dateien herunterzuladen. Sie können sich mit einem Browser behelfen: Öffnen Sie
https://github.com/aenix-org/cozystack-migration-workshop, klicken Sie auf den grünen
Button **Code → Download ZIP** und entpacken Sie das Archiv. Alles danach ist genauso,
nur gehen Sie statt `cd cozystack-migration-workshop` in den entpackten Ordner.
