## 7. Über krew — und warum wir es nicht verwenden

**Kurze Antwort: Installieren Sie es heute nicht**

krew ist ein Plugin-Manager für kubectl, und damit lassen sich dieselben virtctl und kubelogin installieren.
Aber bei früheren Workshops war es genau krew, das die meiste Zeit gefressen hat, besonders unter Windows.
Wenn Sie die Schritte 3 und 4 erledigt haben — **haben Sie bereits alles, überspringen Sie diesen Beitrag**.

Lesen Sie nur weiter, wenn Sie krew bereits installiert haben oder es unbedingt möchten.

⚠️ **Drei Windows-Stolperfallen, alle in freier Wildbahn gesehen:**
• **PATH wurde im aktuellen Fenster nicht aktualisiert.** Die häufigste. Direkt in derselben Sitzung behebbar:
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe wurde nicht fertig installiert** — SmartScreen oder das Antivirenprogramm hat es abgeschossen. Prüfen:
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **Ein Administrator-PowerShell-Fenster und ein normales sind verschiedene Welten.** Sie haben unterschiedliche `$HOME`
  und einen unterschiedlichen Benutzer-PATH. Als Administrator installiert, als normaler Benutzer ausgeführt —
  und das Plugin wird nie gefunden. Installieren und ausführen Sie in ein und demselben normalen Fenster.

**macOS und Linux** — kopieren Sie den ganzen Block, er erkennt das System selbst:
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
Fügen Sie krew dann Ihrem PATH hinzu — die Zeile muss in Ihr Profil geschrieben werden, sonst geht sie
beim nächsten Start des Terminals verloren:
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # für zsh, unter macOS der Standard
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # für bash, meist Linux
source ~/.zshrc    # oder source ~/.bashrc
```

**Windows** (PowerShell)
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
Schließen und öffnen Sie PowerShell erneut.

**Plugins installieren:**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ Ein wichtiger Unterschied: Bei der Installation über krew heißt der Befehl anders —
`kubectl virt console …` statt `virtctl console …`. Weiter unten in der Anleitung schreibe ich
`virtctl` — wenn Sie über krew installiert haben, ersetzen Sie es gedanklich durch `kubectl virt`.
Um Verwirrung zu vermeiden, können Sie einen kurzen Alias einrichten:
```bash
alias virtctl="kubectl virt"
```
