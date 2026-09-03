## 8. Iniciar sesión en el clúster

**Conéctate a tu tenant**

📍 **Dónde:** abre el panel (dashboard) en el navegador; los comandos se ejecutan en tu laptop.

**Tus credenciales:**
```
dashboard: https://dashboard.workshop.aenix.io
login:     workshopXX      ← tu número, te lo diré en persona
password:  ...             ← te lo diré en persona
```

1. Abre el panel en el enlace de arriba.
2. Inicia sesión con tu login.
3. En el panel: **Info → pestaña Secrets → `kubeconfig-tenant-workshopXX`**. Haz clic en *Reveal*
   y copia el contenido.
4. Guárdalo en un archivo y apunta la variable hacia él:

**macOS y Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # pega lo que copiaste, luego guarda
export KUBECONFIG=~/.kube/workshop
```

**Windows** (PowerShell)
```powershell
notepad $HOME\.kube\workshop   # pega, luego guarda
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**Verifiquémoslo:**
```
kubectl get vminstance -n tenant-workshopXX
```
Se abrirá un navegador — inicia sesión como `workshopXX`. Después de eso, el comando debería responder
`No resources found`. Esa es la respuesta correcta: todavía no hay máquinas, pero el clúster ya te reconoce.

⚠️ Dos cosas con las que la gente tropieza más a menudo:
• `KUBECONFIG` debe apuntar exactamente al archivo donde pegaste el config.
• `kubectl get vm` y `kubectl get vmi` no funcionarán — bajo tu cuenta el tipo disponible es
  `vminstance`. Así está diseñado.

⚠️ **`x509: certificate signed by unknown authority`** — el segundo error frecuente, casi
siempre en Windows. No significa que haya un problema con el certificado; significa que `kubectl` tomó
**el archivo de acceso equivocado**: la confianza en la autoridad de certificación interna del clúster vive en tu
kubeconfig, en el campo `certificate-authority-data`, y el archivo por defecto no la tiene.

Resolvámoslo paso a paso, en PowerShell:
```powershell
$env:KUBECONFIG
# vacío — significa que se está usando el archivo por defecto, no el que te dieron

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — el archivo se guardó incompleto; descarga de nuevo el Secret desde el panel

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# debería empezar con apiVersion; cuadraditos o vacío significan que el archivo está en UTF-16
```

El tercer punto es la trampa más traicionera de Windows. El Bloc de notas y la redirección `>` guardan el
archivo en **UTF-16**, que `kubectl` no lee. Guarda solo en UTF-8: en el Bloc de notas elige el
tipo de archivo "Todos los archivos", y desde la línea de comandos usa `Out-File -Encoding utf8`, no `>`.
