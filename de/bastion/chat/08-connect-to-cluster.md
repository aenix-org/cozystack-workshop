## 8. Am Bastion anmelden

**Eine Anmeldung, und Sie sind bereits im Cluster**

📍 **Wo:** Das Dashboard öffnen Sie im Browser; alles andere läuft per SSH auf dem Bastion.

**Ihre Zugangsdaten** (Login und Passwort sind an allen drei Stellen gleich):
```
dashboard: https://dashboard.workshop.aenix.io
bastion:   ssh workshopXX@<bastion-address>
login:     workshopXX      ← Ihre Nummer, sage ich Ihnen persönlich
password:  ...             ← sage ich Ihnen persönlich
```

Melden Sie sich am Bastion an — das Passwort ist dasselbe wie für das Dashboard, **kein SSH-Schlüssel nötig**:

```bash
ssh workshopXX@<bastion-address>
```

Sobald Sie drin sind, ist der Zugriff auf den Cluster bereits eingerichtet: Die kubeconfig liegt in `~/.kube/config`, und `kubectl`
sieht sofort Ihren Tenant. **Dabei öffnet sich kein Browser** — die Anmeldung am Cluster läuft über einen
Token, ohne Keycloak. Prüfen wir das:

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

Der erste Befehl zeigt `tenant-workshopXX`, der zweite antwortet mit `No resources found`. Das ist die
richtige Antwort: Es gibt noch keine Maschinen, aber der Cluster hat Sie erkannt.

⚠️ `kubectl get vm` und `kubectl get vmi` funktionieren nicht — unter Ihrem Konto steht der Typ `vminstance`
zur Verfügung. Das ist so gewollt.

⚠️ Das Dashboard im Browser (für die anschaulichen Schritte per Mausklick) nutzt denselben Login und dasselbe
Passwort. Die kubeconfig aus dem Dashboard (`Info → Secrets → kubeconfig-tenant-workshopXX`) muss jedoch auf dem
Bastion **nicht** heruntergeladen werden: Dort ist sie für die Anmeldung über den Browser gedacht, während auf dem
Bastion bereits eine fertige liegt, die ohne sie funktioniert.
