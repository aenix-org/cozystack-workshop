## 7. Sobre krew — y por qué no lo usamos

**Respuesta corta: no lo instales hoy**

krew es un gestor de complementos para kubectl, y con él puedes instalar esos mismos virtctl y kubelogin.
Pero en talleres anteriores fue precisamente krew lo que más tiempo consumió, sobre todo en Windows.
Si ya hiciste los pasos 3 y 4 — **ya tienes todo, salta este post**.

Sigue leyendo solo si ya tienes krew instalado o de verdad lo quieres.

⚠️ **Tres tropiezos en Windows, todos vistos en la práctica:**
• **El PATH no se actualizó en la ventana actual.** El más común. Se arregla en la misma sesión:
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe no terminó de instalarse** — SmartScreen o el antivirus lo mataron. Comprueba:
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **Una ventana de PowerShell como administrador y una normal son mundos distintos.** Tienen distinto `$HOME`
  y un PATH de usuario distinto. Lo instalas como administrador, lo ejecutas como usuario normal —
  y el complemento no se encontrará nunca. Instálalo y ejecútalo en una misma ventana normal.

**macOS y Linux** — copia el bloque entero, detecta el sistema por sí solo:
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
Luego añade krew a tu PATH — hay que agregar la línea a tu perfil, de lo contrario se olvidará
la próxima vez que inicies la terminal:
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # para zsh, el predeterminado en macOS
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # para bash, normalmente Linux
source ~/.zshrc    # o source ~/.bashrc
```

**Windows** (PowerShell)
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
Cierra y vuelve a abrir PowerShell otra vez.

**Instalamos los complementos:**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ Una diferencia importante: al instalarlo con krew el comando se llama de otra manera —
`kubectl virt console …` en lugar de `virtctl console …`. Más adelante en las instrucciones escribo
`virtctl` — si lo instalaste con krew, sustituye mentalmente por `kubectl virt`.
Para no confundirte, puedes crear un alias corto:
```bash
alias virtctl="kubectl virt"
```
