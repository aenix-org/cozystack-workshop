# Mensajes para el chat del taller — la ruta a través del bastion

Un archivo, un mensaje. Publícalos a medida que avanza la práctica, no todos de golpe.

Este conjunto es para quienes trabajan **a través del bastion compartido (VM)**:
las herramientas y el acceso al clúster ya están en el bastion, el número de tenant está rellenado en los archivos
de antemano, y la aplicación se comprueba por su nombre de dominio. El conjunto para trabajar desde tu propio portátil está
en [`../../laptop/chat/`](../../laptop/chat/).

La numeración de los mensajes es continua con el conjunto del portátil (por eso tiene huecos: aquí no hacen falta las
publicaciones sobre la instalación de herramientas).

| # | Mensaje | Archivo |
|---|---|---|
| 1 | Qué es lo que estamos haciendo en realidad | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | Un pequeño glosario: cómo se llama de tu lado y cómo se llama aquí | [`02-glossary.md`](02-glossary.md) |
| 3 | Antes de empezar: qué vas a necesitar | [`03-prerequisites.md`](03-prerequisites.md) |
| 8 | Iniciar sesión en el bastion | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 10 | Los materiales ya están en el bastion | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | Mapa de archivos: qué está dónde y dónde se ejecuta | [`11-file-map.md`](11-file-map.md) |
| 12 | Fase 1. Sacar la imagen de vSphere | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | Una mirada más de cerca: qué hay dentro de 01-bucket.yaml | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | Paso 1: tu propio almacenamiento | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | Una mirada más de cerca: qué hay dentro de 02-conversion-vm.yaml | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | Paso 2: la máquina conversora | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | Una mirada más de cerca: qué hace convert.sh | [`17-convert-script.md`](17-convert-script.md) |
| 18 | Paso 3: convertir la imagen | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | Fase 2. Levantar la máquina en su nuevo hogar | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | Una mirada más de cerca: qué hay dentro de 03-app-vm.yaml | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | Paso 4: tu máquina virtual | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | Fase 3. Tirar el zoológico | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | Una mirada más de cerca: qué hay dentro de 04-managed.yaml | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | Paso 5: una base de datos y una cola desde el catálogo | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | Paso 6: arreglar la red dentro de la máquina | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | Primera comprobación: intentamos arrancar y nos topamos con un error | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | Paso 7: apuntar la aplicación a los servicios gestionados | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | Paso 8: por qué la aplicación sigue cayéndose | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | Paso 8: instalar el cliente y aplicar el esquema | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | Paso 9: verificar toda la cadena | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | Si algo no funciona | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | Después del taller | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
