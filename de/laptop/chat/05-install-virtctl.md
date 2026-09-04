## 5. virtctl installieren

**virtctl — VMs verwalten**

⚠️ **Achtung: Installieren Sie nicht die neueste Version, sondern die, die im Cluster läuft.** Ein Client, der neuer ist als der Server, ändert die Befehlssyntax, und die Hälfte der Fragen bei früheren Workshops kam genau daher. Unser Cluster läuft mit **v1.8.4** — das ist die Version, die in allen Blöcken unten festgelegt ist. Stellen Sie sie nicht auf latest um.

**macOS**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
Wenn macOS meldet, es könne „den Entwickler nicht überprüfen“:
```bash
sudo xattr -d com.apple.quarantine /usr/local/bin/virtctl
```

**Linux**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-linux-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```

**Windows** (PowerShell, als normaler Benutzer ausführen)
```powershell
$ver = "v1.8.4"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
Danach **schließen Sie das PowerShell-Fenster und öffnen ein neues** — sonst wird der aktualisierte PATH nicht übernommen.

**Überprüfen (überall gleich):**
```
virtctl version
```
Es sollte eine Zeile `Client Version:` mit einer Nummer erscheinen. Eine Beschwerde, dass der Server nicht erreichbar ist, ist an dieser Stelle normal — wir haben uns noch nicht mit ihm verbunden.

**Zum Namen der Maschine in Befehlen.** Mit dem Client v1.8.4 wird die Maschine über ihren bloßen Namen angegeben, ohne Präfix: `vm-instance-app-1`. Falls doch ein neuerer Client installiert wurde und er mit `target must contain type and name separated by '/'` antwortet — fügen Sie das Präfix **`vmi/`** hinzu: `vmi/vm-instance-app-1`.

⚠️ Das Präfix ist `vmi/`, nicht `vm/`. Mit `vm/` erhalten Sie einen Berechtigungsfehler (`cannot get resource "virtualmachines/portforward"`): Der Teilnehmer hat Rechte an den laufenden Maschineninstanzen, nicht an ihren Definitionen.
