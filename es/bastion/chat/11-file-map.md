## 11. Mapa de archivos: qué vive dónde y dónde se ejecuta

**Léelo una vez — después no tendrás que adivinar**

Ten presentes tres lugares donde ocurren las cosas: el **bastion** (la máquina a la que entraste por SSH),
la **máquina conversora** y **tu app-VM** — estas dos últimas se crean dentro del clúster.
En el repositorio hay dos tipos de archivos, y se ejecutan en lugares distintos.

**Manifiestos — `manifests/*.yaml`. Se aplican desde el bastion.**
Describen qué crear en el clúster. El comando es siempre el mismo: `kubectl apply -f <file>`.

• `01-bucket.yaml` — almacenamiento para la imagen · paso 1
• `02-conversion-vm.yaml` — la máquina conversora · paso 2
• `03-app-vm.yaml` — tu app-VM · paso 4 (aquí es donde pegas a mano el enlace presignado)
• `04-managed.yaml` — Postgres y Kafka del catálogo · paso 5

**Scripts — `scripts/*`. No se ejecutan en el bastion, sino dentro de las máquinas del clúster.**
En el bastion mismo no los ejecutas — solo aplicas los manifiestos con `kubectl`.

• `convert.sh` — dentro de la máquina conversora · paso 3
• `netfix-dhcp.sh` — dentro de tu app-VM · paso 6
• `connect-managed.sh` — dentro de tu app-VM · paso 7
• `orders-schema.sql` — una tabla para la base de datos, desde dentro de la app-VM · paso 8 (la escribiremos
  como una consulta; el archivo está ahí para que veas exactamente qué se crea)

**Cómo llega un script dentro de una máquina — y por qué es distinto.**

La **máquina conversora** tiene red, así que descarga el archivo ella misma. El repositorio es
público, no hacen falta claves:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/convert.sh
```

**Tu app-VM al principio no tiene red en absoluto** — ese estado roto es justo lo que arreglamos
en el paso 6. No hay con qué descargar ni a dónde descargar, y los archivos no se pueden
pasar por la consola. Por eso `netfix-dhcp.sh` y `connect-managed.sh` no los descargas —
los **escribes a mano**: son solo dos o tres comandos cada uno, y te los daré ya listos en el chat.
Los archivos mismos en el repositorio son lo mismo, pero escritos por extenso y con comentarios:
prácticos para releer después, cuando repitas esto por tu cuenta.

⚠️ **El número de tenant en los manifiestos ya está rellenado** — mientras se preparaba el bastion,
los marcadores `tenant-workshopXX` fueron reemplazados por tu número. No necesitas
introducir nada a mano. Lo único que rellenas tú mismo son `bucketName`, `accessKey`
y `secretKey` en `convert.sh` (que se descarga fresco en el conversor, con marcadores
`ВСТАВЬТЕ_...`), y el enlace presignado en `manifests/03-app-vm.yaml` en el cuarto paso.
