## 8. Am Cluster anmelden

**Verbindung zu Ihrem Tenant**

📍 **Wo:** Das Dashboard öffnen Sie im Browser; die Befehle führen Sie auf Ihrem Laptop aus.

**Ihre Zugangsdaten:**
```
dashboard: https://dashboard.workshop.aenix.io
login:     workshopXX      ← your number, I'll tell you in person
password:  ...             ← I'll tell you in person
```

1. Öffnen Sie das Dashboard über den Link oben.
2. Melden Sie sich mit Ihrem Login an.
3. Im Dashboard: **Info → Tab Secrets → `kubeconfig-tenant-workshopXX`**. Klicken Sie auf *Reveal*
   und kopieren Sie den Inhalt.
4. Speichern Sie ihn in einer Datei und richten Sie die Variable darauf aus:

**macOS und Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # das Kopierte einfügen, dann speichern
export KUBECONFIG=~/.kube/workshop
```

**Windows** (PowerShell)
```powershell
notepad $HOME\.kube\workshop   # einfügen, dann speichern
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**Prüfen wir das:**
```
kubectl get vminstance -n tenant-workshopXX
```
Es öffnet sich ein Browser — melden Sie sich als `workshopXX` an. Danach sollte der Befehl mit
`No resources found` antworten. Das ist die richtige Antwort: Es gibt noch keine Maschinen, aber der Cluster hat Sie erkannt.

⚠️ Zwei Dinge, über die man am häufigsten stolpert:
• `KUBECONFIG` muss genau auf die Datei zeigen, in die Sie die Konfiguration eingefügt haben.
• `kubectl get vm` und `kubectl get vmi` funktionieren nicht — unter Ihrem Konto steht der Typ `vminstance`
  zur Verfügung. Das ist so gewollt.

⚠️ **`x509: certificate signed by unknown authority`** — der zweite häufige Fehler, fast
immer unter Windows. Er bedeutet nicht, dass etwas mit dem Zertifikat nicht stimmt; er bedeutet, dass `kubectl`
**die falsche Zugangsdatei** erwischt hat: Das Vertrauen in die interne Zertifizierungsstelle des Clusters steht in Ihrer
kubeconfig, im Feld `certificate-authority-data`, und die Standarddatei enthält es nicht.

Gehen wir das Schritt für Schritt durch, in PowerShell:
```powershell
$env:KUBECONFIG
# leer — bedeutet, es wird die Standarddatei verwendet, nicht die, die Sie erhalten haben

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — die Datei wurde unvollständig gespeichert; laden Sie das Secret erneut aus dem Dashboard herunter

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# sollte mit apiVersion beginnen; kleine Quadrate oder Leere bedeuten, die Datei ist in UTF-16
```

Der dritte Punkt ist Windows' übelste Falle. Notepad und die Umleitung `>` speichern die
Datei in **UTF-16**, das `kubectl` nicht lesen kann. Speichern Sie nur in UTF-8: Wählen Sie in Notepad den
Dateityp „Alle Dateien“ und verwenden Sie auf der Kommandozeile `Out-File -Encoding utf8`, nicht `>`.
