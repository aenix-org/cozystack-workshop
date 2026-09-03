## 5. Instalar virtctl

**virtctl — gestionar las VM**

⚠️ **Atención: instala la versión que coincide con el clúster, no la más reciente.** Un cliente más nuevo que el servidor cambia la sintaxis de los comandos, y la mitad de las preguntas en talleres anteriores venían justo de esto. Nuestro clúster corre la **v1.8.4** — esa es la versión fijada en todos los bloques de abajo. No la cambies a latest.

**macOS**
```bash
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
Si macOS se queja de que «no puede verificar al desarrollador»:
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

**Windows** (PowerShell, ejecutar como usuario normal)
```powershell
$ver = "v1.8.4"
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
Después de esto, **cierra la ventana de PowerShell y abre una nueva** — de lo contrario el PATH actualizado no se aplicará.

**Verificar (igual en todas partes):**
```
virtctl version
```
Debería aparecer una línea `Client Version:` con un número. Una queja por no poder alcanzar el servidor es normal en este paso — todavía no nos hemos conectado a él.

**Sobre el nombre de la máquina en los comandos.** Con el cliente v1.8.4 la máquina se indica por su nombre pelado, sin prefijo: `vm-instance-app-1`. Si de todos modos te quedó instalado un cliente más nuevo y responde `target must contain type and name separated by '/'` — añade el prefijo **`vmi/`**: `vmi/vm-instance-app-1`.

⚠️ El prefijo es `vmi/`, no `vm/`. Con `vm/` obtendrás un error de permisos (`cannot get resource "virtualmachines/portforward"`): al participante se le otorgan permisos sobre las instancias de máquinas en ejecución, no sobre sus definiciones.
