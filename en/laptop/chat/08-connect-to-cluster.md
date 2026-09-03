## 8. Logging into the cluster

**Connecting to your tenant**

📍 **Where:** open the dashboard in the browser; run the commands on your laptop.

**Your credentials:**
```
dashboard: https://dashboard.workshop.aenix.io
login:     workshopXX      ← your number, I'll tell you in person
password:  ...             ← I'll tell you in person
```

1. Open the dashboard at the link above.
2. Log in with your login.
3. In the dashboard: **Info → Secrets tab → `kubeconfig-tenant-workshopXX`**. Click *Reveal*
   and copy the contents.
4. Save it to a file and point the variable at it:

**macOS and Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # paste what you copied, then save
export KUBECONFIG=~/.kube/workshop
```

**Windows** (PowerShell)
```powershell
notepad $HOME\.kube\workshop   # paste, then save
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**Let's check:**
```
kubectl get vminstance -n tenant-workshopXX
```
A browser will open — log in as `workshopXX`. After that the command should answer
`No resources found`. That's the right answer: there are no machines yet, but the cluster recognizes you.

⚠️ Two things people trip over most often:
• `KUBECONFIG` must point at exactly the file where you pasted the config.
• `kubectl get vm` and `kubectl get vmi` won't work — under your account the `vminstance` type
  is what's available. That's by design.

⚠️ **`x509: certificate signed by unknown authority`** — the second common error, almost
always on Windows. It doesn't mean there's a problem with the certificate; it means `kubectl` picked up
**the wrong access file**: the trust for the cluster's internal certificate authority lives in your
kubeconfig, in the `certificate-authority-data` field, and the default file doesn't have it.

Let's work through it step by step, in PowerShell:
```powershell
$env:KUBECONFIG
# empty — means it's using the default file, not the one you were given

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — the file was saved incompletely; download the secret from the dashboard again

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# should start with apiVersion; little squares or emptiness mean the file is in UTF-16
```

The third point is Windows's nastiest trap. Notepad and the `>` redirection save the
file in **UTF-16**, which `kubectl` won't read. Save only in UTF-8: in Notepad choose the
"All Files" file type, and from the command line use `Out-File -Encoding utf8`, not `>`.
