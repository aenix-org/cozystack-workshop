# Lab 6 · Tu propio registro de imágenes privado

| | |
|---|---|
| **Tiempo** | 45 minutos, 10 de ellos esperando |
| **Qué demuestra** | Un registro de imágenes se levanta en diez minutos, y el clúster puede descargar imágenes solo desde él |
| **Qué vas a necesitar** | El clúster del Lab 0, `kubectl`, `docker` (o `podman`) en la laptop, acceso al panel |

## Por qué esto importa

El servicio de "Pases" llegó hasta el área de seguridad de la información, y volvió un correo.

> Las imágenes de contenedor se descargan de registros públicos en internet. Esto es inaceptable:
> nadie ha verificado qué hay dentro de una imagen, su contenido puede cambiar bajo el mismo nombre,
> y si el recurso externo no está disponible, un servicio en producción no arrancará. Todas las imágenes
> deben almacenarse en el registro interno de la organización.

No hay nada que discutir: cada punto es justo. Una imagen pública etiquetada como `latest` puede ser una cosa
hoy y otra mañana. El autor de la imagen puede borrarla. Un registro externo puede limitarte la velocidad
de descarga en el peor momento posible, y eso no es hipotético: todo registro público grande lo hace.

Así que necesitas un registro propio. Normalmente eso es un proyecto en sí mismo: una solicitud de una VM,
instalación, certificados, almacenamiento, respaldos, el trimestre de alguien. Hoy es una línea en el
catálogo.

Y como el registro es tuyo y cerrado, habrá que concederle acceso al clúster. Aquí es donde todo el mundo
tropieza, y nosotros también vamos a tropezar, a propósito.

## Pequeño glosario

| Término | Qué es | Como… pero |
|---|---|---|
| **Imagen** | Una instantánea de una aplicación con todo lo necesario para ejecutarla | **Una plantilla de VM**, pero inmutable: no puedes entrar y arreglarla, construyes una nueva |
| **Capa** | Una parte de una imagen. Una imagen se construye a partir de capas, y las capas se reutilizan | las capas idénticas de distintas imágenes se almacenan en el registro una sola vez |
| **Tag** | Una etiqueta de versión de una imagen: `passes-api:v1` | **El nombre de una versión de plantilla**, pero un tag puede reasignarse a otra imagen, y esa es la principal fuente de problemas |
| **Registro** | Un almacén de imágenes servido por HTTP | **Una Content Library**, pero entrega capas por la red en cada lanzamiento en lugar de copiar la plantilla entera |
| **Harbor** | Un registro con interfaz, proyectos, permisos y un escáner de vulnerabilidades | **Content Library + permisos + reportes**, pero puede inspeccionar el contenido de las imágenes y firmarlas |
| **Un proyecto en Harbor** | Un área dentro del registro con sus propios permisos | **Una carpeta en una Content Library**, pero puede ser pública o privada, y eso determina si hacen falta credenciales |
| **`imagePullSecret`** | Un Secret que guarda un login y una contraseña del registro, leído por el nodo | **La cuenta para conectar una Content Library**, pero la necesita el **nodo**, no tú; tu `docker login` no le sirve de nada al clúster |
| **Dockerfile** | Las instrucciones para construir una imagen | **Las instrucciones para preparar una plantilla**, pero se ejecutan por completo y desde cero en cada construcción |
| **Downward API** | Una forma de darle a un Pod información sobre sí mismo a través de variables de entorno | **Las variables de invitado de VMware Tools**, pero los valores los inyecta el clúster al arrancar; la aplicación no los pide |

## Dos kubeconfigs: no los mezcles

De aquí en adelante el lab involucra dos clústeres distintos, y conviene mantenerlos separados antes del
primer comando.

| Kubeconfig | Qué es | Qué hacemos con él |
|---|---|---|
| `~/.kube/workshop` | El clúster de gestión de Cozystack, tu tenant | mirar los servicios gestionados: Harbor, bases de datos, colas |
| `~/lab.kubeconfig` | **Tu** clúster `lab` del Lab 0 | desplegar la aplicación |

Ambos vienen del panel. El del tenant vive en el Secret `kubeconfig-tenant-workshopXX`
(la pestaña Secrets), el del clúster en la sección de acceso de tu clúster `lab`.

⚠️ **La causa más común de "a mí no me funciona nada" en este lab es un comando que fue al clúster
equivocado.** Antes de cada bloque de comandos está escrito para qué clúster está pensado. Si no estás
seguro:

```bash
# echo imprime el valor de la variable: qué archivo de acceso está usando kubectl ahora mismo.
# Vacío significa que kubectl usará el archivo por defecto ~/.kube/config, no el que crees.
echo $KUBECONFIG

# get nodes = "muestra los nodos del clúster". Aquí es una prueba de tornasol:
# la respuesta te dice a cuál de los dos clústeres fue el comando.
kubectl get nodes
```

El clúster `lab` tendrá un único nodo llamado algo así como `kubernetes-lab-md0-...`. En el clúster de
gestión este comando lo más probable es que devuelva un rechazo: un tenant no tiene permiso para ver los
nodos.

## Qué hay en la carpeta del lab

Todos los archivos ya son tuyos: los recibiste junto con el repositorio. No hay nada que crear ni volver a
escribir: allí donde más abajo dice `kubectl apply -f name.yaml`, el archivo se toma de aquí.

```bash
# cada comando de este lab se ejecuta desde la carpeta del lab — entra en ella
cd labs/06-harbor
```

| Archivo | Qué es | Cuándo resulta útil |
|---|---|---|
| `app/` | Los fuentes del servicio "Pases" en Go y un `Dockerfile` — construyes la imagen a partir de ellos | construyes localmente, `docker build` |
| `passes-broken.yaml` | Un archivo **deliberadamente incompleto**: sin credenciales de acceso al registro | lo aplicas para ver el rechazo con tus propios ojos |
| `passes.yaml` | El mismo archivo, pero con acceso al registro | lo aplicas una vez que has entendido las cosas |
| `check.sh` | Una comprobación de que la imagen vino de tu Harbor, no de internet | lo ejecutas al final del lab |

## Paso 1. Crear Harbor

📍 **Dónde:** en el navegador, en el panel de Cozystack. El registro es un recurso compartido del tenant,
no parte de tu clúster lab, así que se crea en el mismo lugar donde se creó el propio clúster.

Tenant → **Create application** → `Harbor`.

| Campo | Valor | Por qué |
|---|---|---|
| Name | `harbor` | pasa a formar parte de la dirección del registro; verás qué resulta después de crearlo |
| Host | dejar vacío | entonces la dirección se arma sola a partir del nombre y el dominio del tenant |
| Storage class | `replicated` | los datos se guardarán en tres copias en distintos nodos |
| Trivy → enabled | **desactivar** | el escáner de vulnerabilidades descarga una base de datos de varios gigabytes; en un entorno de pruebas de entrenamiento eso son veinte minutos extra de espera |
| Database → replicas | `1` | hoy no estamos probando la tolerancia a fallos de la base de datos del registro |
| Database → size | `5Gi` | |
| Redis → replicas | `1` | |
| Redis → size | `1Gi` | |
| Core / Registry preset | dejar como se sugiere | |

⚠️ **El Redis de este formulario es la caché interna propia de Harbor; no tiene nada que ver con el
siguiente lab.** En el lab sobre caché levantarás un Redis aparte para tu propia aplicación. El nombre es el
mismo, los roles son distintos.

Haz clic en crear y espera. Harbor se levanta en cinco a diez minutos: no es una sola aplicación sino varios
servicios más una base de datos más almacenamiento de objetos para las propias capas de las imágenes.

⚠️ **Si Harbor se queda en estado "not ready" más de quince minutos** — mira qué está pasando:
`kubectl -n tenant-workshopXX get pods | grep harbor`. Lo más frecuente es la cola de instalación,
compartida por toda la plataforma: tu aplicación está detrás de las de otras personas en ella y está
esperando.

Harbor almacena las capas de las imágenes en almacenamiento compatible con S3, y el bucket para ellas se
crea solo: no necesitas activar tu propio almacenamiento en el tenant para esto, el del padre servirá. Si
los Pods siguen sin aparecer después de más de media hora, escribe al chat del taller con la salida de
este comando.

## Paso 2. Obtén las credenciales e inicia sesión en el registro

📍 **Dónde:** en el panel, luego en una terminal en la laptop.

Abre la aplicación `harbor` que creaste y busca la pestaña con los secretos. Allí encontrarás un secreto con
las credenciales del registro, y dentro de él tres claves que necesitas:

| Clave | Qué contiene |
|---|---|
| `url` | la dirección de tu registro, de la forma `https://harbor-....<dominio del entorno de pruebas>` |
| `admin-password` | la contraseña del administrador |
| `redis-password` | la contraseña interna de Harbor, que no necesitas |

El login es `admin`.

⚠️ **No adivines la dirección del registro, tómala de la clave `url`.** La plataforma antepone al nombre de
la aplicación el tipo de servicio, así que la dirección puede resultar distinta de lo que esperabas por el
nombre. La misma dirección se ve en la lista de ingresses de la aplicación.

La misma contraseña también está disponible mediante un comando. A un tenant no se le permite leer **todos**
los secretos sin distinción: compruébalo tú mismo, `kubectl auth can-i get secrets` responde `no`. Pero para
cada aplicación que creas, la plataforma configura una regla aparte que permite exactamente sus credenciales:

```bash
# get secret = "muestra el objeto Secret". El nombre del secreto se arma a partir del prefijo
# del tipo de aplicación y su nombre: harbor- + harbor.
#   -n tenant-workshopXX  en qué namespace buscar — tu tenant
#   -o jsonpath='...'     extrae un solo campo del objeto en vez de imprimirlo entero
#   base64 -d             decodifica: los valores dentro de los secretos se guardan en base64
#   ; echo                agrega un salto de línea, si no la contraseña se pega al prompt
kubectl -n tenant-workshopXX get secret harbor-harbor-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

El panel es más cómodo en que no tienes que lidiar con base64. El comando es más cómodo en que puedes
meterlo en un script.

Abre la dirección en un navegador e inicia sesión. Verás la interfaz de Harbor con un único proyecto,
`library`.

Ahora lo mismo desde la terminal. `docker login` pide un nombre de usuario y una contraseña y guarda las
credenciales en tu laptop, en el archivo `~/.docker/config.json`. Después de eso `docker push` y
`docker pull` van a este registro sin preguntar nada.

```bash
# login = "recuerda las credenciales de este registro".
# El argumento es la dirección del registro de la clave url; harbor-harbor.workshop03.example.org aquí es un ejemplo.
# El comando pedirá un nombre de usuario (admin) y una contraseña; la contraseña no se muestra mientras la escribes.
docker login harbor-harbor.workshop03.example.org
```

De aquí en adelante en el texto `harbor-harbor.workshop03.example.org` es **tu** dirección — sustitúyela por la tuya.

**Lo que deberías ver:**

```
Login Succeeded
```

⚠️ **Este `docker login` le enseñó a tu laptop a iniciar sesión en el registro, y solo a él.** No hizo
nada por el clúster. Recuérdalo; lo vas a necesitar un poco más adelante en el lab.

## Paso 3. Configura un proyecto privado

📍 **Dónde:** en el navegador, en Harbor.

**Projects** → **New Project**.

| Campo | Valor | Por qué |
|---|---|---|
| Project Name | `passes` | un proyecto por servicio — eso facilita repartir permisos |
| Access Level | **no marcar Public** | seguridad pidió un registro cerrado, no "tuyo, pero abierto a todo internet" |
| Storage quota | `-1` (sin límite) | en el entorno de pruebas una cuota solo estorbaría |

El proyecto `library`, que estaba ahí desde el principio, es público. Las imágenes se descargan de él sin
ninguna credencial. Precisamente por eso no lo usaremos: no produce justamente el error de acceso alrededor
del cual se construyó el lab.

## Paso 4. Construye la imagen

📍 **Dónde:** en la laptop.

En la carpeta de este lab está `app/` — el fuente del servicio "Pases" y las instrucciones de construcción.
Antes de construir, repasemos qué hay ahí dentro.

<details>
<summary><b>Una mirada más de cerca: qué hay dentro de la app</b></summary>

El archivo `app/main.go`, unas setenta líneas de Go. Hace exactamente dos cosas.

**Responde a `/healthz` con la palabra `ok`.** Esta es la dirección de la comprobación de disponibilidad: el
clúster llama aquí y no envía tráfico a una réplica hasta que recibe una respuesta.

**Responde a `/` con un pequeño JSON** en el que informa sobre sí misma:

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

¿Cómo sabe la aplicación su propio nombre, nodo y namespace? **No los averigua.** El clúster los pone ahí al
arrancar, en variables de entorno:

```go
Pod:  env("POD_NAME", "desconocido"),
Node: env("NODE_NAME", "desconocido"),
```

Y el manifiesto dice qué poner ahí:

```yaml
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
```

Esto se llama la downward API — "información entregada desde arriba". El análogo más cercano en vSphere son
las variables de invitado que VMware Tools entrega a la máquina. La diferencia es que aquí la aplicación no
pide nada ni va a ninguna parte: los valores ya están en el entorno para cuando el proceso arranca. No hace
falta ningún cliente a la API del clúster, ni permisos sobre esa API.

**No hay una sola biblioteca externa en la aplicación, solo la biblioteca estándar de Go.** Esto no es una pose:
una construcción con dependencias iría a internet a por paquetes, y todo el lab empezó con seguridad
prohibiendo salir a internet.

El archivo `app/Dockerfile` son las instrucciones de construcción. Tiene dos etapas:

```dockerfile
FROM golang:1.23-alpine AS build
...
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

FROM alpine:3.21
COPY --from=build /out/passes-api /usr/local/bin/passes-api
```

La primera etapa es la etapa de construcción. Necesita el compilador de Go completo, unos 350 MB. La segunda
etapa es lo que realmente se envía al clúster: de la primera etapa se lleva **solo el binario terminado**,
todo lo demás se descarta.

El resultado es una imagen de unos diez megabytes en lugar de trescientos cincuenta. No es solo cuestión de
tamaño: dentro no hay compilador, ni fuentes, ni gestor de paquetes. Quien sí lograra entrar en el
contenedor no tiene con qué trabajar.

Compara esto con cómo funciona con las plantillas de máquina virtual. Una plantilla lleva dentro todo el
sistema operativo, junto con el compilador si alguna vez acabó ahí. Reducirla después es casi imposible.

Las últimas líneas:

```dockerfile
RUN adduser -D -u 10001 app
USER 10001
```

La aplicación no se ejecuta como root. En un clúster bien configurado a un Pod no se le permitirá ejecutarse
como root, y eso no es que seamos quisquillosos sino un requisito con el que te toparás en cualquier clúster
moderno.

</details>

El comando `docker build` construye la imagen: lee el `Dockerfile`, ejecuta los pasos descritos ahí, y
coloca el resultado en el almacén de imágenes de tu laptop. El nombre con el que se guarda el resultado lo
fija el flag `-t` y consta de tres partes:

| Parte | Qué significa |
|---|---|
| `harbor-harbor.workshop03.example.org` | la dirección del registro — a dónde irán a por la imagen |
| `passes/passes-api` | el proyecto y el nombre dentro del registro |
| `v1` | el tag de versión |

La dirección del registro es parte del nombre de la imagen. Precisamente por eso mudarse a tu propio registro
cambia todos los manifiestos: el nombre de la imagen pasa a ser otro.

Construyamos. Reemplaza la dirección por la tuya:

```bash
cd labs/06-harbor

# build = "construye la imagen a partir del Dockerfile".
#   --platform linux/amd64  para qué procesador construir; los nodos del clúster son x86,
#                           y la laptop puede ser ARM — entonces sin el flag obtienes lo que no es
#   -t <dirección>/<proyecto>/<nombre>:<tag>  cómo nombrar el resultado. La dirección del registro al inicio del nombre
#                           es a donde docker push lo enviará después
#   app/                    el último argumento — la carpeta con el Dockerfile y los fuentes;
#                           todo su contenido se le entrega al constructor
docker build --platform linux/amd64 -t harbor-harbor.workshop03.example.org/passes/passes-api:v1 app/
```

⚠️ **`--platform linux/amd64` no es decoración.** Si tienes un Mac con Apple Silicon (M1–M4) o una laptop
ARM, sin este flag construirás una imagen ARM. Se construirá sin errores, se subirá sin errores, y en el
clúster — donde los nodos son x86 corrientes — el Pod caerá en `CrashLoopBackOff`, y los registros dirán
`exec format error`. Esto tarda mucho en diagnosticarse, porque nada alrededor sugiere que el problema es la
arquitectura del procesador.

**Lo que deberías ver** — líneas sobre los pasos de la construcción y, al final:

```
Successfully tagged harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

## Paso 5. Envía la imagen a tu registro

📍 **Dónde:** en la laptop.

La imagen construida hasta ahora vive solo en tu disco. `docker push` la envía al registro capa por capa;
las capas que ya están en el registro no se envían de nuevo.

```bash
# push = "envía la imagen al registro". A dónde enviarla, docker lo toma del nombre de la imagen:
# la primera parte del nombre es la dirección del registro, y ahí va, con las credenciales de docker login.
docker push harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

**Lo que deberías ver** — las capas saliendo, y al final una línea con un hash largo, el `digest`.

Echa un vistazo en Harbor en el navegador: **Projects** → `passes` → ha aparecido ahí un repositorio
`passes/passes-api`, y en él el tag `v1`. Puedes ver el tamaño, la fecha y ese mismo `digest`.

Ese `digest` es el contenido exacto de la imagen. El tag `v1` puede reasignarse mañana a otra imagen y nadie
lo notará; el `digest` no se puede falsificar. De ahí la regla que todos aprenden tarde o temprano:
**a producción se envía por digest, no por tag.**

## Paso 6. Despliega al clúster

📍 **Dónde:** en la laptop, el clúster `lab`.

```bash
# KUBECONFIG le dice a kubectl qué archivo de acceso usar. Cambiamos a tu clúster `lab`:
# de aquí en adelante todos los comandos kubectl van a él.
# Sigue vigente hasta que se cierre la ventana de terminal.
export KUBECONFIG=~/lab.kubeconfig
```

En la carpeta del lab está `passes-broken.yaml`. En lugar de la dirección del registro tiene un marcador,
`HARBOR-HOST` — hay que reemplazarlo por tu dirección. `sed` hace esto: edita el archivo en el sitio, sin
preguntar ni mostrar nada. Toma la línea para tu sistema:

```bash
# sed -i = "edita el archivo en el sitio"
#   's|qué|por qué|g'  reemplaza todas las apariciones; el separador | se usa en vez de / porque
#                     la dirección tiene barras y habría que escaparlas
#   El sed de macOS exige un argumento obligatorio después de -i; las comillas vacías
#   significan "no hagas copia de respaldo". En Linux no debe haber tal argumento.

# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
```

Aplícalo:

```bash
# apply = "lleva el clúster a lo que está descrito en el archivo"
kubectl apply -f passes-broken.yaml

# get pods = "muestra los Pods".
#   -l app=passes-api  solo los que tienen esta etiqueta, no todo
#   -w                 no salgas, imprime los cambios a medida que aparecen;
#                      para dejar de observar — Ctrl+C
kubectl get pods -l app=passes-api -w
```

**Lo que verás** — y no es lo que esperabas:

```
NAME                          READY   STATUS             RESTARTS   AGE
passes-api-6c9d4f7b8-2xk4n    0/1     ErrImagePull       0          8s
passes-api-6c9d4f7b8-2xk4n    0/1     ImagePullBackOff   0          22s
```

Deja de observar con `Ctrl+C` y mira qué dice el clúster:

```bash
# describe = "cuéntame sobre el objeto en detalle". Al final de la salida viene el registro de eventos:
# qué intentó hacer el clúster con el Pod y cómo terminó.
# tail -12 conserva las últimas doce líneas — los eventos están justo ahí.
kubectl describe pod -l app=passes-api | tail -12
```

```
  Warning  Failed   kubelet  Failed to pull image
    "harbor-harbor.workshop03.example.org/passes/passes-api:v1":
    failed to resolve reference: unexpected status from HEAD request: 401 Unauthorized
```

> **Detente y piensa antes de seguir leyendo.**
>
> Acabas de iniciar sesión con éxito en el registro con `docker login` y de enviar con éxito la imagen ahí.
> El registro te conoce. ¿Por qué al clúster se le rechaza?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

**No eres tú quien descarga la imagen.** La descarga `kubelet` — un servicio en el nodo del clúster. Esa es
una máquina distinta, un proceso distinto y un usuario distinto.

Tu `docker login` escribió las credenciales en el archivo `~/.docker/config.json` en **tu laptop**. El nodo
del clúster no sabe nada de ese archivo ni puede: entre él y tu laptop no hay absolutamente nada en común,
salvo el hecho de que tú le envías comandos.

Vuelve a la advertencia después de `docker login` un poco antes en el lab. Eso es exactamente lo que decía,
pero las consecuencias todavía no se veían.

**Cómo hacerlo bien.** Las credenciales hay que colocarlas en el propio clúster — en un objeto Secret de un
tipo especial — y luego el manifiesto de la aplicación tiene que decir qué secreto usar al descargar. Tal
secreto se llama `imagePullSecret`.

**Por qué el clúster necesita credenciales propias en vez de las tuyas.** Tres razones, y las tres son
prácticas.

Primera: puede que no estés cerca. Un nodo se reiniciará a las tres de la madrugada y volverá a descargar la
imagen. Si fuera con tu cuenta, todo dependería de que siguieras trabajando en esta empresa y de que tu
contraseña no hubiera caducado.

Segunda: los permisos difieren. Tú necesitas permiso para **escribir** en el registro, para enviar
construcciones ahí. El clúster solo necesita **leer**. Darle al clúster permiso para borrar imágenes del
registro es mala idea, y con tu cuenta le habrías dado exactamente eso.

Tercera: el rastro difiere. Cuando el registro de actividad del registro muestra que la imagen la descargó
`robot$passes-puller` en lugar de `admin`, la investigación de un incidente se vuelve posible.

**Por qué no configurar el nodo directamente.** Puedes poner las credenciales directamente en el nodo, en la
configuración del runtime de contenedores — entonces no hace falta ningún `imagePullSecret`. A veces la
gente hace eso. Pero los nodos en un clúster son desechables: se recrean al actualizar, se agregan a medida
que crece la carga, se eliminan ante un fallo. Un ajuste hecho a mano en un nodo vive hasta que el nodo se
reemplaza por primera vez. Un secreto en el clúster sobrevive a cualquier reemplazo.

**Una lección más amplia que este error.** `ImagePullBackOff` es casi siempre una de tres cosas: una errata
en el nombre de la imagen, la falta de credenciales, o que la imagen existe pero no para la arquitectura de
procesador correcta. Mira no el estado del Pod sino `kubectl describe pod` — ahí es donde está escrita la
causa real.

</details>

## Paso 7. Concede al clúster acceso al registro

📍 **Dónde:** en la laptop, el clúster `lab`.

Creamos un secreto con las credenciales del registro. Una variante aparte del comando `create secret` hace
un secreto del tipo que `kubelet` puede leer por su cuenta al descargar imágenes:

```bash
# create secret docker-registry = "crea un secreto con credenciales del registro"
#   harbor             el nombre del secreto dentro del clúster; el manifiesto de la aplicación se referirá a él
#   --docker-server    para qué registro son estas credenciales — la misma dirección que en el nombre de la imagen
#   --docker-username  quién inicia sesión
#   --docker-password  la contraseña; hacen falta comillas simples si tiene un $, ! o espacio
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password='TU-CONTRASEÑA'
```

⚠️ **Una contraseña en la línea de comandos queda en el historial del shell.** En el entorno de pruebas esto no
importa, en un entorno de trabajo sí. Una forma sin el historial:

```bash
# read pone lo que se teclea en el teclado en la variable HARBOR_PASS:
#   -s  no muestres lo que se teclea en la pantalla
#   -r  no trates la barra invertida como un carácter especial
# No aparecerá nada en la pantalla después de esta línea: pega la contraseña y presiona Enter.
read -rs HARBOR_PASS

# De aquí en adelante la contraseña se sustituye desde la variable, así que solo el nombre de la variable
# va al historial del shell. Las comillas dobles son obligatorias: sin ellas los espacios romperían el valor.
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password="$HARBOR_PASS"

# unset borra la variable para que la contraseña no llegue a los siguientes comandos en esta ventana
unset HARBOR_PASS
```

<details>
<summary><b>Qué hay dentro de este secreto y por qué tiene un tipo aparte</b></summary>

Preguntémosle al clúster qué tipo de secreto resultó:

```bash
#   -o jsonpath='{.type}'  imprime un solo campo del objeto — el tipo del secreto
#   {"\n"}                 agrega un salto de línea, si no la salida se pega al prompt
kubectl get secret harbor -o jsonpath='{.type}{"\n"}'
```

```
kubernetes.io/dockerconfigjson
```

El secreto tiene un **tipo**, y no es decorativo. Un secreto corriente es un conjunto de pares clave-valor, y
qué hacer con ellos depende de la aplicación. Un secreto de tipo `kubernetes.io/dockerconfigjson` lo entiende
el propio `kubelet`: sabe que dentro hay un archivo del mismo formato que `~/.docker/config.json`, y puede
usarlo al descargar imágenes.

Para mirar el contenido (la contraseña ahí está en base64 — eso **no es cifrado**, sino una forma de escribir
datos binarios como texto, y cualquiera puede decodificarlo):

```bash
# .data.\.dockerconfigjson — la clave dentro del secreto. El nombre de la clave empieza con un punto,
# así que se escapa: si no jsonpath lo tomaría por un separador de ruta.
# base64 -d decodifica el valor de vuelta a texto — verás el mismo formato
# que en el archivo ~/.docker/config.json de tu laptop.
kubectl get secret harbor -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

De ahí algo importante: **un Secret en Kubernetes no está cifrado por defecto**, simplemente está aislado por
permisos de acceso. Quien pueda leer secretos en el namespace ve las contraseñas. Cómo manejar esto como una
persona decente es un lab aparte sobre un almacén de secretos.

**Cómo se hace en la práctica.** No con la cuenta `admin`. Harbor tiene robots: **Projects** → `passes` →
**Robot Accounts** → crea un robot con solo permiso `pull`. Las credenciales del robot van al
`imagePullSecret`, y entonces un secreto filtrado del clúster significa que alguien puede descargar tus
imágenes — desagradable, pero no fatal. Un `admin` filtrado significa que alguien puede sustituirlas.

Usamos `admin` para no alargar el lab. Ten en cuenta que esto es una simplificación.

</details>

Ahora aplica el manifiesto correcto. Primero la misma sustitución de dirección que antes, solo que en un
archivo distinto; luego elimina la aplicación rota y levanta la que funciona:

```bash
# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml

# delete -f = elimina del clúster exactamente los objetos descritos en el archivo
kubectl delete -f passes-broken.yaml
kubectl apply -f passes.yaml

# rollout status espera hasta que las nuevas réplicas queden listas, luego termina por su cuenta.
# Si no llega a ese punto, devuelve un error, y por eso tal línea resulta útil en los scripts.
kubectl rollout status deployment/passes-api
```

**Lo que deberías ver:**

```
deployment "passes-api" successfully rolled out
```

La diferencia entre el manifiesto que funciona y el roto es exactamente dos líneas:

```yaml
      imagePullSecrets:
        - name: harbor
```

## Paso 8. Mira qué salió de todo esto

📍 **Dónde:** en la laptop, el clúster `lab`.

La aplicación no está expuesta al exterior, pero necesitas verla. `port-forward` cava un túnel desde la
laptop hacia el clúster: mientras el comando se ejecuta, una petición a `localhost:8080` va al servicio
`passes-api`. El análogo más cercano es un reenvío temporal de puerto en una pasarela NAT, solo que sin tocar
la red.

```bash
# port-forward svc/passes-api = un túnel al servicio, no a un Pod concreto
#   8080:80 — el número de la izquierda es el puerto en tu laptop, el de la derecha el puerto del servicio en el clúster
# No cierres la ventana: el túnel vive mientras el comando se ejecuta.
kubectl port-forward svc/passes-api 8080:80
```

En otra ventana de terminal:

```bash
# curl — "ve a la dirección y muestra la respuesta".
#   -s     no muestres el indicador de progreso
#   ; echo agrega un salto de línea: la respuesta viene como una sola línea, y sin él
#          se pega al prompt del shell
curl -s http://localhost:8080/; echo
```

**Lo que deberías ver** — un JSON en el que la aplicación informa qué réplica respondió, en qué nodo se
ejecuta y de qué registro llegó:

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

El campo `pod` de la respuesta es el nombre de la réplica que respondió. Compáralo con la lista de réplicas:

```bash
# una nueva ventana de terminal no sabe nada de la variable KUBECONFIG — configúrala aquí también,
# si no kubectl irá al clúster equivocado
export KUBECONFIG=~/lab.kubeconfig

# la misma selección por etiqueta: la lista debe contener el nombre que viste en la respuesta
kubectl get pods -l app=passes-api
```

Repite la petición varias veces — el nombre seguirá siendo **el mismo**, y eso no es un mal funcionamiento.
`port-forward` elige una única réplica en el momento en que arranca y mantiene el túnel exactamente a esa
hasta `Ctrl+C`; en este camino no hay ningún balanceo en absoluto. Sí lo hay en el `Service`, pero solo
puedes verlo desde dentro del clúster — desde fuera estás hablando con un Pod concreto.

Puedes comprobar el balanceo de verdad así — ocho peticiones desde un Pod temporal que vive dentro del
clúster:

```bash
# run levanta un Pod de un solo uso, --rm lo limpia después.
# Todo lo que va después de -- se ejecuta dentro del Pod: ocho veces golpeamos el servicio por su nombre interno
# e imprimimos la línea con el nombre de la réplica que respondió.
kubectl run probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
  -- sh -c 'for i in $(seq 1 8); do curl -s http://passes-api/ | grep -o "passes-api-[a-z0-9-]*"; done'
```

**Lo que deberías ver:** dos nombres distintos mezclados — este es el `Service` repartiendo las peticiones
entre las réplicas.

Para cerrar el túnel — `Ctrl+C` en la primera ventana.

Cierra el círculo: entra en Harbor en el navegador, en el proyecto `passes`. En el repositorio
`passes/passes-api` el contador de descargas (**Pulls**) ha pasado a ser distinto de cero. Tu clúster
realmente fue justamente aquí.

## Verificación

📍 **Dónde:** en la laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

El script va a ambos clústeres a la vez y los toma de variables de entorno. Las dos primeras son
obligatorias, la tercera es la ruta al kubeconfig del tenant.

```bash
cd labs/06-harbor

# en qué clúster comprobar la aplicación — tu `lab`
export KUBECONFIG=~/lab.kubeconfig
# el número de tu tenant: a partir de él el script arma el nombre del namespace tenant-workshop03
export COZY_TENANT=workshop03
# dónde vive el acceso al clúster de gestión — ahí el script mirará el propio Harbor.
# Puedes dejarla sin definir: entonces el script busca ~/.kube/workshop, y al no encontrarlo — omite
# las comprobaciones en el clúster de gestión y lo indica.
export COZY_KUBECONFIG=~/.kube/workshop

./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo instalarlo está escrito al
inicio del Lab 0. Sin WSL puedes hacer el lab, pero no habrá reporte de artefacto.

El script comprueba no el hecho de que Harbor se creó, sino el trabajo en lo esencial: el registro responde
por su API, la aplicación en el clúster arrancó desde una imagen que está en tu propio registro, el secreto
con las credenciales existe y apunta a la misma dirección, y el propio servicio devuelve un JSON con el
nombre de un Pod que realmente existe.

## Limpieza

La aplicación y Harbor harán falta en el siguiente lab — no los borres ahora.

Cuando termines con todos los labs:

```bash
# elimina los objetos descritos en el archivo: tanto el Deployment como el Service
kubectl delete -f passes.yaml
# el secreto lo creó un comando, no un archivo — elimínalo por nombre
kubectl delete secret harbor
```

Harbor en sí se elimina a través del panel, como cualquier aplicación corriente. Junto con él se va también
el almacén de capas — eso son una docena de segundos, no una solicitud para dar de baja una VM.

Vale la pena entender qué es exactamente lo que estás borrando. Un registro no es solo el lugar donde están
las imágenes, sino también la única respuesta a la pregunta "qué enviamos realmente a producción durante el
último año". Borrarlo en un entorno de trabajo tan fácilmente como aquí no es algo que vayas a querer.

## Qué sabemos hacer ahora

- Montarnos un registro de imágenes y explicar en qué se diferencia de una Content Library
- Construir una imagen con una construcción en dos etapas y entender por qué el resultado sale treinta veces más pequeño
- Distinguir un `docker login` en la laptop del acceso que necesita el clúster
- Leer `ImagePullBackOff` y encontrar la causa real en `describe pod`
- Darle a un Pod información sobre sí mismo a través de la downward API, sin concederle permisos sobre la API del clúster

## En vSphere esto sería

El análogo más cercano de un registro es una Content Library. Hay una similitud: ambos almacenan imágenes y
las entregan a las máquinas, y ambos pueden hacer permisos y sincronización entre sitios.

Más allá de eso divergen, y la diferencia no está en los detalles.

**Una Content Library copia la plantilla entera.** Un registro entrega capas y almacena las capas idénticas
una sola vez. Si tienes veinte servicios sobre la misma base Alpine, la base está en el registro en una sola
copia, y cuando el vigésimo primer servicio arranca el nodo descargará solo su propia capa — un puñado de
megabytes.

**Una plantilla se nombra, una imagen se direcciona.** Una imagen tiene un digest — un hash de su contenido.
Por él puedes verificar que estás ejecutando exactamente el código que construiste y no otro. Una plantilla
no tiene tal cosa: confías en que nadie la haya cambiado.

**Un registro es un servicio HTTP.** De esto se desprende todo el sentido del ejercicio: una construcción en
el pipeline pone ahí una imagen con un comando, el clúster la obtiene con otro, y nadie monta almacenamiento
ni copia archivos entre sitios a mano.

**Dónde vSphere es más cómodo, honestamente.** Tres cosas.

Una Content Library no requiere entender nada sobre credenciales. Conéctala — funciona. Aquí tuviste que
explicarle por separado al clúster cómo llegar al registro, y tropezaste con ello, como todo el mundo.

Los permisos en vCenter están unificados. Una cuenta para todo: las máquinas, la biblioteca y la red. Aquí
los permisos en el panel, los permisos en el clúster y los permisos en Harbor son tres conjuntos distintos
que hay que mantener sincronizados. Ese es el precio de que el registro sea un producto por derecho propio,
no parte de la plataforma.

Una plantilla se puede editar. Despliegas una máquina desde una plantilla, la ajustas más, capturas una
nueva plantilla — y el hecho de que la secuencia exacta de pasos no esté escrita en ninguna parte no estorba
en nada. Las imágenes no se construyen así: si la construcción no se reproduce desde el `Dockerfile`, estás
en problemas. La disciplina es útil, pero acostumbrarse a ella es difícil, y fingir lo contrario es una
tontería.
