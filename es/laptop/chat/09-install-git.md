## 9. Instalar git

**La última herramienta — con ella descargaremos los materiales**

📍 **Dónde:** en tu laptop.

Primero comprueba si ya lo tienes: en macOS y en la mayoría de las compilaciones de Linux
git viene preinstalado.
```
git --version
```
Si te mostró una versión — salta este mensaje.

**macOS.** Lo más fácil es dejar que el cuadro de diálogo del sistema haga el trabajo: escribe `git --version`, y si
git no está instalado, macOS te ofrecerá por sí sola instalar las herramientas de desarrollo. Acéptalo.
O bien de forma explícita:
```bash
xcode-select --install
```
Con Homebrew:
```bash
brew install git
```

**Linux** — depende de la familia de la distribución:
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian, Ubuntu
sudo dnf install -y git                               # Fedora, RHEL, CentOS Stream
```

**Windows** (PowerShell):
```powershell
winget install -e --id Git.Git
```
Luego cierra PowerShell y ábrelo de nuevo, de lo contrario no se encontrará el comando.

⚠️ **Si no se encuentra `winget`** — git se instala con un instalador común: abre
https://git-scm.com/download/win, descarga el archivo, ejecútalo y haz clic en «Siguiente» en cada
paso, no hay que cambiar nada. Después de la instalación — una nueva ventana de PowerShell.
O prescinde de git — usa la opción Download ZIP de más abajo.

**Comprobamos:**
```
git --version
```

🖱 **Si prefieres no instalar git** — se necesita exactamente una vez, para descargar la carpeta
de archivos. Puedes arreglártelas con un navegador: abre
https://github.com/aenix-org/cozystack-migration-workshop, haz clic en el botón verde
**Code → Download ZIP** y descomprime el archivo. Todo lo demás es igual,
solo que en lugar de `cd cozystack-migration-workshop` entras en la carpeta descomprimida.
