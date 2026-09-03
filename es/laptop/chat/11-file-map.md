## 11. Mapa de archivos: qué vive dónde y dónde se ejecuta

**Léelo una vez — después no tendrás que adivinar**

En el repositorio hay dos tipos de archivos, y viven en lugares distintos. Esto es lo principal que
debes captar antes de empezar la parte práctica.

**Manifiestos — `manifests/*.yaml`. Se aplican desde tu laptop.**
Describen qué crear en el clúster. El comando es siempre el mismo: `kubectl apply -f <file>`.

• `01-bucket.yaml` — almacenamiento para la imagen · paso 1
• `02-conversion-vm.yaml` — la máquina conversora · paso 2
• `03-app-vm.yaml` — tu app-VM · paso 4 (aquí es donde pegas a mano el enlace prefirmado)
• `04-managed.yaml` — Postgres y Kafka del catálogo · paso 5

**Scripts — `scripts/*`. No se ejecutan en tu máquina, sino dentro de las VMs.**
En tu laptop no los necesitas para nada.

• `convert.sh` — dentro de la máquina conversora · paso 3
• `netfix-dhcp.sh` — dentro de tu app-VM · paso 6
• `connect-managed.sh` — dentro de tu app-VM · paso 7
• `orders-schema.sql` — una tabla para la base de datos, desde dentro de la app-VM · paso 8 (la escribiremos
  como una consulta; el archivo está ahí para que veas exactamente qué se crea)

**Cómo llega un script dentro de una máquina — y por qué es distinto.**

La **máquina conversora** tiene red, así que descarga el archivo ella misma. El repositorio es
público, no hacen falta claves:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/convert.sh
```

**Tu app-VM al principio no tiene red en absoluto** — ese estado roto es justo lo que arreglamos
en el paso 6. No hay con qué descargar ni a dónde descargar, y los archivos no se pueden
pasar por la consola. Por eso `netfix-dhcp.sh` y `connect-managed.sh` no los descargas —
los **escribes a mano**: son solo dos o tres comandos cada uno, y te los daré ya listos en el chat.
Los archivos mismos en el repositorio son lo mismo, pero escritos por extenso y con comentarios:
prácticos para releer después, cuando repitas esto por tu cuenta.

⚠️ **La sutileza por la que todo se rompe.** Reemplazaste `tenant-workshopXX` por tu propio número
en tu laptop. El archivo descargado dentro de la máquina conversora llega fresco, con marcadores —
los valores se introducen de nuevo en él, a mano.
