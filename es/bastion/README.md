# Workshop: migración de una VM de VMware a Cozystack (a través del bastion)

Tomamos una aplicación que lleva años corriendo en una máquina virtual en VMware y la
trasladamos a Cozystack. Todo lo haces con tus propias manos.

**Esta es la ruta a través de la VM compartida (el bastion).** No necesitas instalar
nada en tu propia laptop: `kubectl`, `virtctl` y `git` ya están en el bastion, y tu
acceso al clúster desde allí ya está configurado. Entras por SSH y trabajas justo ahí,
y luego abres la aplicación terminada en un navegador por su nombre de dominio.

> Si trabajas desde tu propia laptop (instalando las herramientas tú mismo, llegando a la
> aplicación mediante `port-forward`) — necesitas el otro conjunto, [`../laptop/`](../laptop/).

Este archivo es la ruta: qué va después de qué, qué comandos escribir y qué debes obtener
al final. Las explicaciones de por qué las cosas están construidas así, y los recorridos
línea por línea de los manifiestos y scripts, viven en la carpeta [`chat/`](chat/) — un
archivo por mensaje. Los enlaces están al final de cada paso.

## La ruta

La aplicación vive en tres máquinas: la aplicación en sí, la base de datos y la cola de
mensajes. Movemos solo la primera — la base de datos y la cola se quedan atrás, y en su
lugar tomamos unas ya listas del catálogo de Cozystack.

| Fase | Qué hacemos | Dónde |
|---|---|---|
| 1 | Preparamos el almacenamiento para la imagen | en el bastion |
| 2 | Reempaquetamos el disco del formato VMware al formato KVM | en una máquina temporal |
| 3 | Levantamos la máquina en su nuevo hogar | en el bastion |
| 4 | Pedimos la base de datos y la cola del catálogo | en el bastion |
| 5 | Arreglamos la red y cambiamos la aplicación a las nuevas direcciones | en tu máquina |

Después viene la verificación final: un pedido creado en la aplicación llega hasta la base
de datos y la cola.

## Lo que te dio el instructor

Un usuario y una contraseña — los mismos en los tres lugares:

* **el panel** https://dashboard.workshop.aenix.io — inicia sesión en el navegador, namespace `tenant-workshopXX`
* **el bastion** — inicia sesión por SSH: `ssh workshopXX@<bastion-address>`
* dentro del bastion, el acceso al clúster ya está configurado, y el kubeconfig está en `~/.kube/config`

En todo lo que sigue, reemplaza `workshopXX` por tu propio número (el instructor te lo dio).

## Iniciando sesión en el bastion

```bash
ssh workshopXX@<bastion-address>
```

La contraseña es la misma que la del panel. No hace falta una clave SSH: el inicio de
sesión es por contraseña. Comprobemos que el acceso al clúster está en su sitio (aquí no se
abre ningún navegador — el bastion está configurado para el acceso directo por token, sin
Keycloak):

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Deberías ver:** el nombre de contexto `tenant-workshopXX` y una lista (todavía vacía) de máquinas.

## Los materiales ya están en el bastion

No hay nada que clonar — la carpeta de materiales está en tu directorio home, y tu número de
tenant en los manifiestos y scripts **ya está rellenado**: los marcadores `tenant-workshopXX`
fueron reemplazados por tu `tenant-workshopNN` cuando se preparó el bastion. No hay nada que
buscar y reemplazar — simplemente aplica los archivos tal como están.

```bash
cd ~/workshop
ls manifests scripts
grep -rl tenant-workshop manifests | head -1 | xargs grep -m1 namespace   # verás tu número
```

Un punto se deja como marcador a propósito: en `manifests/03-app-vm.yaml` la línea
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` — ese enlace lo obtendrás después de la segunda fase y lo rellenarás tú mismo.

En detalle: [chat/10](chat/10-clone-and-set-number.md) ·
mapa de archivos [chat/11](chat/11-file-map.md)

---

## Fase 1. Almacenamiento para la imagen

📍 En el bastion.

El disco reempaquetado necesita ir a algún lugar del que la plataforma pueda descargarlo por
la red. Preparamos un bucket — almacenamiento de objetos con interfaz S3.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**Deberías ver:** `bucket.apps.cozystack.io/my-images created`, luego `READY: True`.

⚠️ **Escribe el nombre del tipo completo, no `bucket`.** La palabra está tomada tres veces en el
clúster: nuestro tipo del catálogo, el tipo de Flux y el tipo del estándar de almacenamiento de
objetos. Cuál de los tres sustituirá `kubectl` por el nombre corto no se sabe de antemano, y si es
el equivocado, obtendrás una denegación de permisos sobre un recurso que nunca pediste:
`buckets.source.toolkit.fluxcd.io is forbidden`. Esto no es un problema de acceso, y no hay nada
que arreglar.

⚠️ **Si `apply` falla con `SchemaError … unknown model in reference`** — es la validación del lado
del cliente la que tropieza, no el clúster; el manifiesto es correcto. Para sortearlo:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`. La bandera desactiva solo la
comprobación local; el servidor igualmente validará el objeto por su lado.

**Las claves te harán falta a continuación:** el panel → `Bucket` → `my-images` → la pestaña `Secrets` →
el secreto `bucket-my-images-app-credentials`. De ahí tomas `bucketName`, `accessKey`
y `secretKey` — los pondrás en el script en la siguiente fase.

Recorrido del manifiesto: [chat/13](chat/13-bucket-manifest.md) ·
el paso completo: [chat/14](chat/14-step-1-bucket.md)

---

## Fase 2. Reempaquetado del disco

📍 Primero en el bastion, luego dentro de la máquina temporal.

El disco de VMware está escrito en el formato VMDK, mientras que KVM lee QCOW2. `virt-v2v` se
encarga del reempaquetado; no tiene sentido instalarlo en el bastion para un solo uso, así que
levantamos una máquina temporal con las herramientas ya listas.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**Deberías ver:** dos líneas con `created`, luego `Running`.

⚠️ `Running` significa "encendida", no "lista": dentro, `cloudInit` sigue trabajando unos minutos
más — instalando paquetes y descargando `mc`. Si entras demasiado pronto no encontrarás `virt-v2v`.

Inicia sesión (usuario `ubuntu`, contraseña `ubuntu`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

Dentro: `nano convert.sh`, pega el texto de `scripts/convert.sh`, y pon tus propios
`bucketName`, `accessKey` y `secretKey` en lugar de `ВСТАВЬТЕ_...`.

⚠️ **Ejecuta la conversión dentro de `screen`** — tarda unos cinco minutos, y si tu sesión SSH al
bastion se cae, una ejecución normal quedaría cortada a la mitad. `screen` mantiene el proceso vivo,
incluso cuando la conexión se pierde:

```bash
screen -S convert          # abre una sesión aparte
sudo bash convert.sh       # ejecútalo dentro de esa sesión
#  ¿se cayó la conexión? vuelve a entrar por ssh al bastion, luego:  screen -r convert
```

**Deberías ver:** al final de la salida, después de la palabra `Share:` — un enlace firmado a la imagen.
Lo necesitarás en la siguiente fase.

Recorrido del manifiesto: [chat/15](chat/15-conversion-vm-manifest.md) ·
recorrido del script: [chat/17](chat/17-convert-script.md) ·
ambos pasos completos: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## Fase 3. La máquina en su nuevo hogar

📍 En el bastion.

⚠️ Primero apaga la máquina conversora — ya hizo su trabajo y está reteniendo 8Gi de tu cuota.
Si no la eliminas, la nueva máquina quedará colgada en `Pending`:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

Pon el enlace que obtuviste en `manifests/03-app-vm.yaml` en lugar de
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`, luego:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**Deberías ver:** dos líneas con `created`, luego `Running`. Aquí la espera es más larga —
la plataforma está descargando la imagen desde tu enlace.

Inicia sesión (usuario `root`, contraseña `cozydemo`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **Dentro no habrá red.** Esto no es un laboratorio roto — es como debe ser. Lo arreglamos
en la fase cinco.

Recorrido del manifiesto: [chat/20](chat/20-app-vm-manifest.md) ·
el paso completo: [chat/21](chat/21-step-4-your-vm.md)

---

## Fase 4. La base de datos y la cola del catálogo

📍 En el bastion.

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**Deberías ver:** `postgres.apps.cozystack.io/db created` y
`kafka.apps.cozystack.io/kafka created`. Kafka tarda notablemente más en levantar que Postgres.

Recorrido del manifiesto: [chat/23](chat/23-managed-manifest.md) ·
el paso completo: [chat/24](chat/24-step-5-database-and-queue.md)

---

## Fase 5. Conectando la aplicación

📍 Dentro de tu máquina virtual.

Tres acciones en orden estricto: sin red el script no puede alcanzar la base de datos, y
sin la base de datos no aceptará el esquema.

| Paso | Qué arreglamos | Con qué |
|---|---|---|
| 5.1 | la máquina no tiene red | `scripts/netfix-dhcp.sh` |
| 5.2 | la aplicación busca las direcciones viejas | `scripts/connect-managed.sh` |
| 5.3 | la nueva base de datos no tiene tablas | `scripts/orders-schema.sql` |

**5.1.** El script cambia `BOOTPROTO=static` por `dhcp` y elimina la dirección de la red de VMware.
Lo escribes a mano — la máquina todavía no tiene red, así que no puedes descargar el archivo.
Después la máquina necesita un **reinicio**: CentOS 7 aplica la configuración de red al arrancar.

**5.2.** El script reemplaza las direcciones fijas `192.168.10.30` y `192.168.10.40` en
`/etc/orders/application.properties` por nombres de servicios y reinicia la aplicación.

**5.3.** Instalamos el cliente `psql` y aplicamos el esquema — los comandos están abajo, en la
verificación final.

En detalle: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## La verificación final: tres pasos en orden

### Paso 1. Apagar firewalld

📍 Dentro de tu máquina. Las reglas quedaron de la red vieja y están cortando las peticiones a la aplicación.

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**Deberías ver:** `200`. Si es `503` — algo de la base de datos o de la cola no se conectó.
Aquí `localhost` es la propia máquina en la que estás sentado: la aplicación se comprueba desde dentro.

### Paso 2. El esquema de la base de datos

📍 Dentro de tu máquina. El psql de fábrica de CentOS 7 es la versión 9.2; no sabe hacer SCRAM y
responde `SCRAM authentication requires libpq version 10 or above`. Instalamos uno nuevo:

```bash
# 1. El repositorio PGDG — la fuente de los paquetes de PostgreSQL
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: no está en los repositorios de CentOS 7, así que la tomamos del archivo de EPEL
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. El cliente en sí — solo desde el repositorio activo pgdg15
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ El segundo y el tercer comando no son redundantes. Sin `libzstd` la instalación falla en
`Requires: libzstd >= 1.4.0`. Sin `--disablerepo`/`--enablerepo` — en
`HTTPS Error 410 - Gone`: el paquete del repositorio activa todas las versiones de PostgreSQL de
golpe, incluidas las descontinuadas 12 y 13, y antes de instalar, `yum` recorre cada repositorio
activado y falla en el primero muerto.

```bash
psql --version
```

Si aparece `command not found` — el cliente quedó fuera de `PATH`: mira
`ls /usr/pgsql-*/bin/psql`, luego `export PATH="$PATH:/usr/pgsql-15/bin"`.

Descargamos el esquema y lo aplicamos (esta app-VM sí llega a internet, así que el archivo se descargará):

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**Deberías ver:** en el último comando — la tabla `orders`.

La dirección de la base de datos no es una IP sino un nombre: `postgres-db-rw` (el servicio `db`,
lectura-escritura), `tenant-workshopXX` (tu namespace), `svc.cozy.local` (el sufijo de los nombres
internos del clúster). La contraseña está definida en `manifests/04-managed.yaml`, así que no
tienes que buscarla en ningún lado.

En detalle: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### Paso 3. Comprobación desde fuera — por nombre de dominio

📍 En un navegador en tu propia laptop, o mediante `curl` en el bastion.

Aquí es donde se muestra la diferencia principal de esta ruta: **no hace falta reenvío de puertos.**
El instructor ya creó un `Ingress` en tu tenant, y en cuanto la aplicación dentro de la máquina esté
escuchando en `8080`, la tienda se publica en `https://app.workshopXX.workshop.aenix.io`
(`XX` es tu número). Compruébalo justo desde allí:

```bash
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

**Deberías ver:** el pedido en la lista. El recorrido completo está terminado.

⚠️ Mientras la app-VM todavía no esté levantada o siga arrancando, el dominio responde `503` — eso
es normal: el `Ingress` está esperando un backend. Una vez que la máquina ha arrancado (con `8080`
escuchando dentro) pasa a `200`.

En detalle: [chat/30](chat/30-step-9-verify-chain.md)

---

## Chuleta

> **El prefijo `vmi/` no lo necesitan todos los comandos, y eso no es un error tipográfico.** Bajo los
> permisos de tenant, `virtctl console` acepta solo el nombre **desnudo** (`vm-instance-app-1`); con
> `vmi/` responde `forbidden`, tomando la palabra `vmi` por el nombre de la máquina. `virtctl ssh`
> y `virtctl port-forward`, por el contrario, exigen la forma `vmi/<name>`.

```bash
# iniciar sesión en la app-VM (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# iniciar sesión en la conversion-VM (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# una shell dentro de la app-VM por SSH (una vez que la red de la máquina esté arriba)
virtctl ssh ubuntu@vmi/vm-instance-app-1 --namespace=tenant-workshopXX
```

La aplicación la compruebas por dominio, `https://app.workshopXX.workshop.aenix.io`; `port-forward`
no hace falta en esta ruta. Para salir de la consola — `Ctrl+]`. Si la pantalla queda en blanco
después de conectarte, pulsa Enter. Lo mismo está disponible con el ratón: el botón **VNC** en la
página de la máquina en el panel.

## Dónde es fácil atascarse

* Para la conversion-VM, usa solo `ubuntu-20.04`. En 24.04 el kernel entra en panic; en 22.04
  `virt-v2v` no puede analizar la vieja base de datos RPM de CentOS 7.
* El VMDisk para una imagen del catálogo debe ser más grande que la propia imagen, de lo contrario
  el clon no pasará y el disco quedará colgado en `Terminating`. Para `ubuntu-20.04`, 25Gi es suficiente.
* En una app-VM recién creada, primero `netfix`, luego `connect` — de lo contrario la aplicación no
  verá los servicios gestionados.
* Ejecuta la conversión larga dentro de `screen` — de lo contrario una caída de SSH la cortará a la mitad.

El resto de los escollos — [chat/31](chat/31-troubleshooting.md).

## Para quienes montan el laboratorio

Las cuotas, el orden para crear tenants y la versión de la plataforma — en [REQUIREMENTS.md](../REQUIREMENTS.md).

## Todos los mensajes en orden

La lista de 27 mensajes — [chat/README.md](chat/README.md).
