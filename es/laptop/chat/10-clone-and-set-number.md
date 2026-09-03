## 10. Conseguir los materiales y rellenar tu número

**El repositorio con los manifiestos**

📍 **Dónde:** en tu laptop, en la terminal. Lo pondremos en tu directorio de inicio — así la ruta es la misma para todos y me resulta más fácil ayudarte.

**Dónde abrir la terminal:**
• macOS — Spotlight (`Cmd+Espacio`), escribe «Terminal»
• Linux — `Ctrl+Alt+T` en la mayoría de los entornos
• Windows — el menú «Inicio», escribe «PowerShell»

**Consigue la carpeta con los archivos** (tres comandos, uno a uno):
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
El primer comando te lleva a tu directorio de inicio, el segundo descarga ahí la carpeta
con los materiales y el tercero te mete dentro de ella. A partir de aquí, todos los comandos se ejecutan **desde aquí** —
las rutas en ellos están escritas de forma relativa a esta carpeta.

**Mira qué se descargó:**
```bash
ls manifests scripts
```
Deberías ver cuatro manifiestos y cuatro scripts — justo los del mapa de archivos.

**Si cerraste la terminal o te perdiste** — la forma de volver es siempre la misma:
```bash
cd ~/cozystack-migration-workshop/workshop
```
En Windows la ruta es la misma: `cd $HOME\cozystack-migration-workshop\workshop`.
Para comprobar dónde estás: `pwd` (también funciona en PowerShell).

⚠️ El sufijo `/workshop` es obligatorio. Junto a los materiales del taller, el repositorio tiene una carpeta `labs`
con laboratorios independientes — si te detienes un nivel más arriba, los comandos no encontrarán
ni `manifests` ni `scripts`.

**Con qué abrir los archivos para editarlos.** Los manifiestos son archivos de texto plano, así que sirve
cualquier cosa:
• en la terminal — `nano manifests/03-app-vm.yaml` (guardar: `Ctrl+O`, `Enter`, salir: `Ctrl+X`)
• con el ratón en macOS — `open -a TextEdit manifests/03-app-vm.yaml`
• con el ratón en Windows — `notepad manifests\03-app-vm.yaml`
• si tienes VS Code instalado — `code .` abre la carpeta entera de una vez, que es lo más cómodo

⚠️ No abras los archivos `.yaml` en Word ni en Google Docs: cambian las comillas y los guiones,
y después el archivo deja de aplicarse, y el error parece inexplicable.

Cada archivo lleva el marcador `tenant-workshopXX`. Rellena tu número de una vez en todos,
de lo contrario el manifiesto irá a parar al lugar equivocado. Supongamos que tu usuario es `workshop03`:

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS** (aquí `sed` tiene una sintaxis distinta — fíjate en las comillas vacías)
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows** (PowerShell)
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**Comprueba que no queda ni un solo marcador:**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "clean, you can continue"
```

Hay un sitio que el comando no tocará: en `manifests/03-app-vm.yaml`, la línea
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. Esa URL la obtendrás más tarde, cuando conviertas la imagen.
Por ahora, solo debes saber que ahí te está esperando.
