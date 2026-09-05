# Lab 11 · Compilando una aplicación móvil en el clúster

| | |
|---|---|
| **Tiempo** | 40 minutos, de los cuales hasta 15 se pasan esperando la primera compilación |
| **Qué demuestra** | Un servidor de compilación no es un servidor: es una tarea que ocupa un nodo mientras dura la compilación y luego lo libera |
| **Qué necesitarás** | El clúster del Lab 0, `kubectl`, `~/lab.kubeconfig`, acceso al panel del tenant |

## Por qué esto importa

El equipo móvil está escribiendo un cliente para Propusk — la mismísima pantalla desde la que
un empleado solicita un pase de invitado. Por ahora la compilan en la VM de uno de los
desarrolladores. Cuando él está de vacaciones, no sale ninguna versión.

No tienen un servidor de compilación propio, y no lo tendrán: su solicitud de una máquina
dedicada para el Android SDK fue rechazada dos veces — «la carga es irregular, la máquina va a
estar ociosa». Lo cual, francamente, es cierto. La compilación corre veinte minutos al día,
pero la máquina que necesita tiene cuatro núcleos y dieciséis gigabytes.

Aquí haremos exactamente lo que nos piden: tomaremos esos cuatro núcleos **por veinte
minutos**, compilaremos el APK y los devolveremos. Y pondremos el archivo terminado donde
cualquiera pueda recogerlo, incluido un tester con un teléfono — en un bucket.

Es la primera vez en todos los labs que una carga de trabajo **termina**. Todo lo que hemos
desplegado hasta ahora estaba pensado para correr para siempre.

## Mini-glosario

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Job** | Una tarea: ejecutar algo y esperar a que termine con éxito | **Una tarea programada en el SO invitado**, pero un job crea su propia máquina donde ejecutarse y la limpia él mismo |
| **Deployment** | La descripción de una aplicación que corre para siempre | **Una vApp**, pero nunca «termina con éxito» — una copia que desaparece se vuelve a crear |
| **Almacenamiento de objetos** | Almacenamiento sin archivos ni directorios — solo una clave y su contenido | **Un datastore**, pero no se monta. Pones y recuperas objetos enteros, por HTTP |
| **Bucket** | Un área con nombre dentro del almacenamiento de objetos | **Una carpeta en un datastore**, pero no anidada: un bucket es el nivel superior, y las «carpetas» dentro de él son parte del nombre del objeto |
| **S3** | Un protocolo para acceder al almacenamiento de objetos por HTTP | sin análogo directo; más cercano a una API REST que a NFS |
| **Claves de acceso** | Un par «access key / secret key» en lugar de un login y una contraseña | **Una cuenta de servicio**, pero las claves se emiten por bucket, no por persona |
| **Secret** | Un objeto del clúster donde pones contraseñas y claves | **Una entrada en un credential store**, pero dentro del clúster es base64, no cifrado. Oculta las cosas de la vista, no de un administrador |
| **emptyDir** | Un disco temporal que vive exactamente lo mismo que el Pod | **Un vmdk temporal**, pero desaparece junto con el Pod, sin forma de recuperarlo |

### Job frente a Deployment — en una tabla

Es la distinción clave del lab, y conviene fijarla antes de aplicar nada.

La palabra **Pod** aparece en ambas filas de abajo. Un Pod es la unidad mínima de ejecución en
un clúster: un contenedor (o varios) levantado en un nodo concreto. El análogo más cercano es
una máquina virtual dedicada a una sola tarea, solo que se crea en segundos y no sobrevive a su
nodo. Ni un Job ni un Deployment ejecutan nada por sí mismos: crean Pods y deciden qué hacer
cuando un Pod desaparece.

| | Deployment | Job |
|---|---|---|
| Qué significa «todo bien» | las copias están corriendo ahora mismo | el proceso terminó con código 0 |
| Un Pod terminó con éxito | el clúster lo trata como un fallo y crea uno nuevo | el clúster considera que el trabajo está hecho |
| Cuánto vive | hasta que lo borras | hasta que se completa |
| Cuántas veces se ejecuta | ninguna — no «se ejecuta», corre | una vez (o tantas como se indique) |
| Qué queda después | una aplicación en ejecución | los resultados del trabajo y los registros |

De ahí una consecuencia práctica con la que todos tropiezan: **si ejecutas una compilación como
un Deployment, el clúster la ejecutará una y otra vez**. La compilación terminó con éxito — así
que la copia desapareció — así que hay que crear una nueva. Un bucle infinito, y no es culpa del
clúster: es lo que se le indicó.

## Qué hay en la carpeta del lab

Todos los archivos ya son tuyos — los recibiste con el repositorio. No hay nada que crear ni
volver a escribir: allí donde más abajo diga `kubectl apply -f nombre.yaml`, el archivo viene de aquí.

```bash
cd labs/11-android
```

| Archivo | Qué es | Cuándo lo necesitarás |
|---|---|---|
| `bucket.yaml` | Almacenamiento para los APK compilados | lo aplicas **en el tenant** |
| `propusk-src.yaml` | El código fuente de la aplicación móvil Propusk | lo aplicas en tu clúster `lab` |
| `android-build.yaml` | La compilación en sí. El script está extraído a un ConfigMap en lugar de incrustado en el job | lo aplicas ahí también |
| `check.sh` | Una verificación de que la compilación tuvo éxito y el APK aterrizó en el almacenamiento | lo ejecutas al final del lab |

## Paso 1. Crear el bucket

📍 **Dónde:** en el navegador, en el panel del tenant.

**Un tenant** es tu porción de la plataforma: lo que ves en el panel y lo que controlas. El
clúster `lab` del Lab 0 lo pediste dentro de él, y el bucket lo pedirás ahí también.

Un bucket es un **servicio gestionado** — un elemento listo del catálogo:
dices lo que necesitas, y la plataforma lo levanta, lo actualiza y lo arregla. Vive **no en el
clúster `lab`** sino junto a él, en el tenant. Y así debe ser: los artefactos de compilación
sobreviven al clúster en el que se compilaron.

El archivo de acceso al tenant (el kubeconfig) se obtiene del panel: **Info → la pestaña
Secrets → `kubeconfig-tenant-workshopXX`**, y se guarda en `~/.kube/workshop`. Es la misma ruta
que en todos los demás labs.

Tenant → **Create application** → `Bucket`.

| Campo | Valor | Por qué |
|---|---|---|
| Name | `builds` | corto y queda claro qué hay dentro |
| Users | añade el usuario `ci` | la compilación escribirá usando estas claves |
| Locking | desactivado | protección contra el borrado de objetos; excesivo para compilaciones |
| Storage pool | déjalo vacío | el pool por defecto está bien |

**El mismo bucket como texto**, si lo prefieres. Ojo: el `namespace` (una partición dentro del
clúster; tu tenant es un namespace aparte) aquí es el del tenant, y necesitas el archivo de
acceso del tenant, no el del clúster `lab`.

```bash
# KUBECONFIG — qué archivo de acceso usa kubectl. Aquí es el del tenant: el bucket
# se pide en el clúster de gestión, no en el clúster lab
export KUBECONFIG=~/.kube/workshop

# apply = «lleva el clúster a lo que está descrito en el archivo». El comando no crea el
# almacenamiento en sí — le pasa el pedido a la plataforma.
#   -f bucket.yaml   qué archivo aplicar. Antes de esto, reemplaza
#                    tenant-workshopXX en él por tu namespace, o el pedido se irá a otra parte
kubectl apply -f bucket.yaml
```

**Lo que deberías ver** — `bucket.apps.cozystack.io/builds created`.

<details>
<summary><b>Un vistazo más de cerca: qué hay dentro de bucket.yaml</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
```

`apps.cozystack.io` es el grupo de API donde viven los servicios gestionados de la plataforma.
Las máquinas virtuales, las bases de datos y las colas tendrán el mismo prefijo. Esto no es un
«complemento sobre Kubernetes» — son objetos Kubernetes corrientes, descritos por la plataforma.

```yaml
spec:
  users:
    ci: {}
```

Un mapa de usuarios. Cada clave es un usuario S3 aparte, y para cada uno la plataforma emitirá
**su propio** par de claves de acceso. Un objeto vacío `{}` significa acceso completo.

Por qué varios usuarios en un mismo bucket: la compilación necesita acceso de escritura,
mientras que el equipo móvil y los testers necesitan solo lectura. Claves distintas, permisos
distintos, se revocan por separado:

```yaml
  users:
    ci: {}
    mobile:
      readonly: true
```

Nos arreglaremos con uno para ahorrar tiempo del lab, pero conviene saberlo.

</details>

El bucket tarda unos segundos en aprovisionarse. Espera hasta que aparezca como listo en el panel.

## Paso 2. Obtener las claves

📍 **Dónde:** en el panel, en la tarjeta del bucket, la pestaña **Secrets**.

Busca el secret `bucket-builds-ci-credentials`. Contiene cuatro valores:

| Campo | Qué es |
|---|---|
| `endpoint` | la dirección del almacenamiento, **sin** `https://` — tendrás que añadir el prefijo tú mismo |
| `bucketName` | el nombre real del bucket: largo, con un identificador, no `builds` |
| `accessKey` | el «login» |
| `secretKey` | la «contraseña» |

⚠️ **`bucketName` no es el nombre que escribiste.** El nombre `builds` es el nombre del objeto
Cozystack. El nombre real del bucket en el almacenamiento lo emite la propia plataforma, y se ve
como `bucket-a9209f83-...`. Es exactamente eso lo que debes sustituir, si no obtendrás un acceso
denegado a un bucket inexistente y pasarás diez minutos buscando una errata.

Estos mismos cuatro valores están disponibles por línea de comandos — la plataforma otorga
acceso a las credenciales de cada aplicación que has creado. El comando de abajo extrae uno de
los cuatro valores, `accessKey`; el resto se obtienen igual, solo cambia el nombre del campo.

```bash
# Trabajamos con el mismo acceso al tenant que en el paso anterior: el secret vive en el tenant.
# get secret = «muestra el objeto con contraseñas y claves». Los valores dentro del secret están
# codificados en base64 — esto no es cifrado, solo una forma de escribir datos binarios como texto.
#   -n tenant-workshopXX   en qué namespace buscar
#   -o jsonpath='...'      devolver no el objeto entero, sino un único campo de él:
#                          .data.accessKey — el campo accessKey dentro de la sección data
#   base64 -d              decodificarlo de vuelta a una forma legible (d = decode)
#   ; echo                 añadir un salto de línea: sin él el valor se pegaría
#                          al siguiente prompt de la terminal
kubectl -n tenant-workshopXX get secret bucket-builds-ci-credentials \
  -o jsonpath='{.data.accessKey}' | base64 -d; echo
```

Leer todos los secrets al por mayor no le está permitido al tenant, eso sí: `kubectl auth can-i
get secrets` responderá `no`. Los permisos se otorgan de forma acotada, a nombres concretos — y
al kubeconfig de tu clúster del Lab 0 también.

## Paso 3. Poner las claves en tu propio clúster

La compilación correrá en el clúster `lab`, pero las claves viven en el tenant. Los clústeres
son distintos; nada se traslada automáticamente. Las transferiremos a mano.

📍 **Dónde:** en la laptop.

Montaremos nuestro propio secret en el clúster `lab` con los cuatro valores del paso anterior.
No cambies los nombres de los campos: el script de compilación busca variables con exactamente
estos nombres.

```bash
# De aquí al final del lab trabajamos con el clúster lab, no con el tenant
export KUBECONFIG=~/lab.kubeconfig

# create secret generic = «crea un secret a partir de los valores que voy a enumerar».
# generic significa «un conjunto arbitrario de pares nombre-valor», no un tipo ya hecho
# para una contraseña de registro de imágenes o un certificado TLS.
#   bucket-creds        el nombre del secret. El Job lo referenciará por este nombre
#   --from-literal=nombre='valor'   un par. En lugar de ВСТАВЬТЕ_..., sustituye
#                       los valores de la tarjeta del bucket en el panel
kubectl create secret generic bucket-creds \
  --from-literal=endpoint='ВСТАВЬТЕ_endpoint' \
  --from-literal=bucketName='ВСТАВЬТЕ_bucketName' \
  --from-literal=accessKey='ВСТАВЬТЕ_accessKey' \
  --from-literal=secretKey='ВСТАВЬТЕ_secretKey'
```

**Lo que deberías ver:**

```
secret/bucket-creds created
```

⚠️ **Usa comillas simples.** Las claves secretas contienen con frecuencia `$`, `!` y `&`. Dentro
de comillas dobles el shell las interpretaría a su manera, y obtendrías una clave distinta de la
que copiaste.

**Por qué este comando se escribe a mano en lugar de vivir en el repositorio como un archivo.**
Todo lo demás en estos labs es texto que puede ir a Git. Un secret no. El objeto `Secret` dentro
del clúster guarda sus valores en base64, y base64 no es cifrado sino una forma de escribir:
cualquiera que llegue al archivo lee las claves. Un archivo de secret en Git significa claves en
Git para siempre, incluyendo todo el historial. Este es exactamente el tipo de hallazgo de
auditoría que trae OpenBao al escenario de Propusk.

## Paso 4. Mirar qué vamos a compilar

La carpeta contiene `propusk-src.yaml` — el código fuente de la app como un ConfigMap. **Un
ConfigMap** es un objeto del clúster que guarda archivos de texto dentro de sí: el clúster luego
los coloca dentro del contenedor como archivos corrientes en disco. El análogo más cercano es
una carpeta compartida de configuraciones, solo que se almacena en el propio clúster y llega
junto con la descripción de la tarea.

El código fuente vive ahí por la misma razón: la compilación necesita archivos, y no tiene
sentido montar un disco de red para seis archivos de texto.

La app hace una sola cosa: muestra la línea «Solicitar un pase de invitado». Con eso basta, porque
el lab no va sobre Android sino sobre dónde se compila.

**Un APK** es lo que sale al final. Es un archivo comprimido que contiene la aplicación
compilada, imágenes, textos y una descripción de qué pantalla lanzar; esto es exactamente lo que
instala el teléfono. Por su papel es lo mismo que un `.msi` para Windows: un único archivo que
le entregas al usuario.

<details>
<summary><b>Un vistazo más de cerca: qué hay dentro del código fuente</b></summary>

Seis archivos, repartidos por las claves del ConfigMap.

### `settings.gradle.kts` — dónde busca Gradle las dependencias

```kotlin
pluginManagement {
  repositories { google(); mavenCentral(); gradlePluginPortal() }
}
```

Tres repositorios públicos desde los que se descargarán el plugin de compilación de Android, el
plugin de Kotlin y todo lo que ellos arrastran. Esta lista es justamente lo que explica por qué
la primera compilación es lenta: desde un contenedor vacío hay que descargarlo todo.

⚠️ Este mismo lugar es lo primero que cambiarás cuando el equipo de seguridad prohíba salir a
internet a por dependencias. Entonces aquí se escribe tu repositorio proxy, exactamente igual
que Harbor se convirtió en el reemplazo de Docker Hub.

### `build.gradle.kts` — versiones de las herramientas

```kotlin
plugins {
  id("com.android.application") version "8.5.2" apply false
  id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
```

`apply false` significa «declara la versión pero no la actives en el proyecto raíz» — las
activará el módulo `app`. Las versiones están fijadas a propósito: una compilación que tira de
«lo último» dentro de un mes compilará distinto que hoy, y serás tú quien tenga que averiguar
por qué.

### `app-build.gradle.kts` — el módulo en sí

```kotlin
android {
  namespace = "io.aenix.propusk"
  compileSdk = 34
  defaultConfig { minSdk = 24; targetSdk = 34 }
}
```

`compileSdk 34` es la versión del Android SDK contra la que compilamos. También determina qué
exactamente hay que descargar en el paso de instalación del SDK, y eso es alrededor de un
gigabyte y medio.

`minSdk 24` es el Android más antiguo en el que la app funcionará. Aquí es Android 7.

```kotlin
  kotlinOptions { jvmTarget = "17" }
```

Kotlin compila a bytecode de la JVM, de ahí el requisito sobre la versión de Java. La imagen que
usamos trae JDK 17, y estos dos números deben coincidir.

### `MainActivity.kt` — la aplicación

```kotlin
class MainActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    ...
    view.text = getString(R.string.greeting)
```

Una activity, un `TextView`, texto de los recursos. Usa `android.app.Activity` a secas en lugar
de una biblioteca de compatibilidad: la app tiene cero dependencias externas, y eso ahorra un
par de minutos de descarga en cada compilación.

`R.string.greeting` es una referencia a una cadena de `strings.xml`. La clase `R` se genera en
tiempo de compilación; no está en el código fuente. Si ves el error «unresolved reference: R»,
significa que falló el paso de generación de recursos, no tu código.

### `AndroidManifest.xml` y `strings.xml`

El manifiesto declara qué activity se lanza desde el icono. `strings.xml` mantiene los textos
separados del código — así se pueden traducir sin involucrar al programador.

</details>

Ponemos el código fuente en el clúster. Todavía no corre nada: son solo archivos que la
compilación necesitará en el siguiente paso.

```bash
# Crea un ConfigMap con seis archivos dentro. Para comprobar que está en su sitio:
# kubectl get configmap propusk-src
kubectl apply -f propusk-src.yaml
```

**Lo que deberías ver** — `configmap/propusk-src created`.

## Paso 5. Desglosar el Job

Antes de ejecutarlo, lee qué es exactamente lo que estás ejecutando. La compilación ocupará el
nodo entero, y conviene entender para qué.

<details>
<summary><b>Un vistazo más de cerca: qué hay dentro de android-build.yaml</b></summary>

El archivo tiene dos objetos: un ConfigMap con el script de compilación y el Job en sí.

### El script de compilación

Está en un ConfigMap por la misma razón por la que la página de nginx vivía aparte del
Deployment: cuarenta líneas de shell dentro de un campo `command` son imposibles de leer.

Cinco pasos, y los cinco son comandos corrientes que escribirías a mano en un servidor de
compilación. El contenedor arranca vacío: tiene Java y Gradle de la imagen, pero ni Android SDK,
ni claves, ni código fuente — el SDK y las claves los traen los comandos de compilación, y el
código fuente lo aporta el ConfigMap montado en el contenedor.

| Paso | Qué hace | Cuánto tarda |
|---|---|---|
| 1 | descarga las Android command-line tools — el conjunto de utilidades con el que se instala el SDK en sí | 1–2 minutos |
| 2 | acepta las licencias e instala el SDK, la plataforma 34, las build-tools | 5–15 minutos |
| 3 | `gradle :app:assembleDebug` — compilar el código fuente en un APK | 3–8 minutos |
| 4 | instala `mc`, un cliente de línea de comandos para el almacenamiento S3 | segundos |
| 5 | pone el APK en el bucket con dos nombres | segundos |

Tres líneas merecen una mirada más de cerca.

```bash
# yes — un comando que imprime «y» sin fin: así una tanda de preguntas «¿aceptar la
# licencia? [y/n]» se responde sin un humano.
#   >/dev/null 2>&1   descarta tanto la salida normal como la de errores: aquí no hace falta
#   || true           «aunque el comando devuelva un error, trátalo como correcto»
yes | sdkmanager --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null 2>&1 || true
```

`|| true` aquí no es una chapuza sino una necesidad: `yes` recibe un SIGPIPE cuando `sdkmanager`
cierra su entrada, y devuelve un código distinto de cero. Con `set -o pipefail` esto tumbaría la
compilación sin motivo. Si las licencias de verdad no se aceptaron, el comando siguiente se
negará a instalar el SDK, así que no estamos ocultando el error.

```bash
# alias set = «recuerda la dirección del almacenamiento y las claves bajo el nombre corto builds»,
# para no repetirlas en cada comando de copia que sigue.
#   "https://${endpoint}"   la dirección: el prefijo https:// lo añadimos nosotros, no está en el secret
#   ${accessKey} ${secretKey}   el login y la contraseña en términos de S3, vienen del secret
#   >/dev/null              silenciar la salida
mc alias set builds "https://${endpoint}" "${accessKey}" "${secretKey}" >/dev/null
```

La salida se silencia a propósito, y por la misma razón el script no tiene `set -x`: los registros
del Job son visibles para todo el que tenga acceso al clúster, y las claves no deben acabar ahí.

```bash
# echo imprime una línea en el registro de la tarea. No hace ningún trabajo — es una marca
# de que el comando de copia anterior llegó hasta el final
echo "APK-UPLOADED ${bucketName}/propusk/propusk-${STAMP}.apk"
```

Una línea marcadora. Por ella `check.sh` distingue «el Job se ejecutó» de «el APK realmente
llegó al bucket» — son afirmaciones distintas, y la segunda es más fuerte.

### El Job

```yaml
kind: Job
spec:
  backoffLimit: 1
```

Cuántas veces recrear el Pod si la compilación falla. Cero sería más honesto, pero la red a
veces se cae mientras se descarga el gigabyte y medio de SDK, y un segundo intento es más barato
que investigar «por qué falló el mío».

```yaml
  activeDeadlineSeconds: 7200
```

Un techo para toda la tarea, dos horas. Sin él, una compilación colgada retendría el nodo hasta
la noche, y te enterarías por un vecino al que no se le despliega nada.

La cuenta atrás empieza desde la creación del Job, no desde el arranque del contenedor: el
tiempo en `Pending` y la recreación del nodo un poco más adelante en el lab consumen el mismo
límite. Una hora no bastaba para esto — la compilación moría con `DeadlineExceeded` justo
después de que una persona ya se la hubiera esperado.

```yaml
      restartPolicy: Never
```

Para un Job este campo es obligatorio, y solo hay dos valores válidos. `Never` significa: no
reiniciar un proceso caído dentro del mismo Pod, sino ceder la decisión al Job — él creará uno
nuevo. Así cada intento tiene sus propios registros, y puedes ver cuál falló.

El valor `Always`, familiar de Deployment, no está disponible aquí: «reiniciar siempre» y
«esperar hasta que termine» se contradicen.

```yaml
          envFrom:
            - secretRef:
                name: bucket-creds
```

Las cuatro claves del secret se convierten en variables de entorno con los mismos nombres. La
alternativa es enumerar cada variable por separado; para cuatro claves del mismo tipo, eso es
ruido de más.

⚠️ Un efecto secundario que conviene conocer: `envFrom` arrastrará **todas** las claves del
secret al entorno, incluidas las que se añadan después. Para un secret que creaste tú mismo y
para una sola tarea, es aceptable. Para un secret compartido que abarca todo el namespace, no.

```yaml
          resources:
            requests: {cpu: "1", memory: 4Gi}
            limits:   {cpu: "2", memory: 6Gi}
```

Aquí está ese precio honesto de una compilación de Android. `requests` es lo que reservar: un
núcleo y cuatro gigabytes. Menos no tiene sentido — el compilador de Kotlin se los comerá y
pedirá más. `limits` es el techo: dos núcleos y seis gigabytes.

Compáralo con la app del primer lab: `20m` de CPU y `32Mi` de memoria. Una diferencia de
cincuenta veces en CPU y de ciento treinta en memoria. Esto viene al hilo de la pregunta «para
qué especificar `requests` siquiera»: sin ellos el scheduler consideraría la compilación tan
ingrávida como nginx y la colocaría en un nodo donde no cabe.

```yaml
        - name: work
          emptyDir:
            sizeLimit: 12Gi
```

Un disco temporal en el nodo. Aquí aterrizarán el SDK, la caché de Gradle y el resultado de la
compilación — seis a ocho gigabytes en total. Vive exactamente lo mismo que el Pod: el Job
terminó, el disco desapareció.

**De esto se sigue directamente por qué cada compilación es lenta.** Descargamos el SDK y las
dependencias desde cero cada vez. En un servidor de compilación real, en lugar de `emptyDir`
habría un volumen persistente, y sobreviviría a la tarea: la primera compilación más lenta, la
segunda notablemente más rápida. A propósito no lo hacemos así en el lab, para no introducir una
entidad de más, pero en la vida real es lo primero que añadirías.

```yaml
            items:
              - key: app-build.gradle.kts
                path: app/build.gradle.kts
```

Una clave de ConfigMap no puede contener una barra, pero una ruta de montaje sí. Así es como un
mapa plano de seis claves se despliega en el árbol de directorios que Gradle espera.

</details>

## Paso 6. Ejecutarlo — y chocar contra un muro

📍 **Dónde:** en la laptop, en el clúster `lab`.

Aplicamos el job e inmediatamente miramos el Pod que creó.

```bash
# Crea dos objetos a partir del archivo: un ConfigMap con el script y el Job en sí.
# Desde este momento el clúster está obligado a encontrar un nodo para la compilación y arrancarla
kubectl apply -f android-build.yaml

# get pods = «muestra los Pods». El Pod de la tarea no tiene nombre propio — el Job se lo inventa
# él mismo, añadiendo una cola aleatoria a su propio nombre. Así que buscamos no por nombre sino por etiqueta:
#   -l job-name=propusk-build   selecciona los Pods con la etiqueta job-name igual al nombre del job.
#                               El Job pone esta etiqueta en sus Pods él mismo
kubectl get pods -l job-name=propusk-build
```

**Lo que muy probablemente verás:**

```
NAME                   READY   STATUS    RESTARTS   AGE
propusk-build-x7k2p    0/1     Pending   0          40s
```

`Pending` no significa «arrancando». Significa «no arrancó y no arrancará». El clúster escribe el
motivo en los eventos del Pod — su registro de quién intentó hacer qué con él.

```bash
# describe = «muestra todo lo que se sabe sobre el objeto»: configuración, estado, eventos.
# La salida es larga, así que nos quedamos solo con su cola:
#   sed -n '/Events:/,$p'   imprime las líneas desde aquella donde aparece «Events:»,
#                           hasta el final de la salida ($ — el final)
kubectl describe pod -l job-name=propusk-build | sed -n '/Events:/,$p'
```

**Lo que deberías ver** — la línea con el motivo por el que el Pod no se colocó:

```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory.
```

> **Detente y piensa antes de seguir leyendo.**
>
> ¿Qué exactamente no cuadró? Recuerda qué nodo pediste en el Lab 0 y cuánta memoria solicitó
> el Job.

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

En el Lab 0 tomamos el nodo `u1.medium` — un núcleo y cuatro gigabytes. El Job pide `requests:
memory 4Gi` y `cpu 1`. Es exactamente lo que tiene el nodo, pero parte ya está ocupada: kubelet
reserva memoria para sí mismo, además el nodo corre Pods de sistema para la red y la
monitorización, más la app del primer lab.

Fíjate en que faltan **las dos** — la CPU también. El nodo `u1.medium` da un núcleo, la
compilación pide uno entero, y parte del núcleo ya está ocupada por Pods de sistema. Por eso el
mensaje tiene dos motivos, no uno: al scheduler le basta cualquiera de ellos.

El scheduler suma los `requests` de todos los Pods del nodo y lo compara con lo que el nodo está
realmente dispuesto a dar. No hay sitio libre suficiente, y el Pod se queda esperando para
siempre.

**Una lección más amplia que este error.** El scheduler de Kubernetes cuenta no el consumo real
sino lo **declarado**. Un nodo donde todos los Pods dormitan y el uso de CPU es del tres por
ciento puede estar totalmente ocupado a ojos del scheduler — si la suma de los `requests` ya
iguala la capacidad. Y al revés: un nodo ahogándose bajo la carga seguirá aceptando Pods nuevos
hasta que la suma de los `requests` tope el techo.

Esto también explica la pareja `Insufficient cpu, Insufficient memory`, extraña a primera vista,
en un clúster aparentemente vacío — te la encontrarás más de una vez.

En vSphere te resultan familiares ambas cosas: la reservation que DRS tiene en cuenta durante la
colocación, y la carga real, que mira por separado. Aquí la colocación se calcula **solo** a
partir de la reservation, sin la segunda mitad.

</details>

## Paso 7. Agrandar el nodo

📍 **Dónde:** en el panel, en la aplicación `lab`.

Abre `Kubernetes` → `lab` → editar. En el grupo de nodos, cambia:

| Campo | Antes | Después | Por qué |
|---|---|---|---|
| Instance type | `u1.medium` (1 núcleo, 4 GB) | `u1.large` (2 núcleos, 8 GB) | el mínimo en el que cabe la compilación |
| Disk | `20Gi` | `40Gi` | el SDK, la caché de Gradle y las capas de la imagen no caben en veinte |

Si la cuota de tu tenant lo permite, toma `u1.xlarge` (4 núcleos, 16 GB). La compilación irá
notablemente más rápido, y devolverás los recursos de más justo después del lab. Si no lo
permite, el formulario se negará al guardar, y entonces lo que queda es `u1.large`.

⚠️ **Cambiar el tipo de nodo recrea la máquina virtual del nodo.** El nodo viejo se va, uno nuevo
se levanta, los Pods se mudan. Esto tarda unos minutos, y todo lo que vivía en el disco local
del nodo desaparece. Para nuestros labs esto es indoloro — los datos viven en servicios
gestionados, no en los nodos — pero en un clúster de producción esta es una operación que se
planifica.

Espera al nodo nuevo. El clúster `lab` no tiene consola gráfica, así que observamos con un comando:

```bash
# get nodes = «muestra los nodos del clúster» — esas mismas máquinas virtuales en las que
# corren los Pods.
#   -w   watch, «no salgas; añade líneas en cada cambio». El nodo viejo
#        desaparecerá de la lista, uno nuevo aparecerá y llegará a STATUS=Ready.
#        Para salir del seguimiento — Ctrl+C, que no afecta en nada al clúster
kubectl get nodes -w
```

En cuanto el nodo esté `Ready`, el Pod atascado de la compilación se moverá por sí solo — el
scheduler revisa los Pods en `Pending` constantemente, no hay que pedírselo. Comprobamos que se
está moviendo:

```bash
# La misma consulta que antes de editar el nodo. Ahora la columna STATUS debería mostrar
# ContainerCreating, y en un minuto o dos Running
kubectl get pods -l job-name=propusk-build
```

## Paso 8. Esperar la compilación

📍 **Dónde:** en la laptop, en el clúster `lab`.

Observaremos la compilación en su registro — es decir, en lo que el script imprime en pantalla dentro
del contenedor.

```bash
# logs = «muestra lo que imprimió la tarea».
#   -f                  follow: no salgas, sino añade líneas a medida que aparecen.
#                       Salir — Ctrl+C, la compilación sigue igualmente
#   job/propusk-build   puedes apuntar al Job en sí, no al Pod: kubectl encontrará su Pod por su cuenta
kubectl logs -f job/propusk-build
```

**Lo que deberías ver** — los cinco pasos del script en secuencia. Orientaciones de tiempo:

| Marca en el registro | Cuándo aproximadamente |
|---|---|
| `== 1/5 instalando las herramientas de línea de comandos de Android ==` | de inmediato |
| `== 2/5 aceptando las licencias y descargando el SDK (el paso más largo) ==` | +1–2 minutos, y se queda colgado lo que más |
| `== 3/5 compilando el APK ==` | +5–15 minutos desde el inicio |
| `BUILD SUCCESSFUL in ...` | +10–25 minutos desde el inicio |
| `APK-UPLOADED bucket-.../propusk/propusk-...apk` | justo después |

⚠️ **Veinte minutos de silencio en la marca `2/5` son normales, no un cuelgue.** `sdkmanager` no
muestra el progreso de descarga en modo no interactivo: se queda callado y luego imprime `done`.
Puedes confirmar que el proceso está vivo en otra ventana de terminal — comprueba si el Pod está
consumiendo CPU y memoria:

```bash
# top = «cuánto está consumiendo ahora mismo». No la reserva de requests, sino el uso real
# en este preciso segundo. Una CPU distinta de cero significa que dentro se está trabajando
kubectl top pod -l job-name=propusk-build
```

El Job se considera completado cuando el Pod terminó con código 0 (un código de retorno cero es
el ampliamente aceptado «se ejecutó sin errores»):

```bash
# Miramos no el Pod sino el job en sí: tiene columnas que el Pod no tiene
kubectl get job propusk-build
```

```
NAME             STATUS     COMPLETIONS   DURATION   AGE
propusk-build    Complete   1/1           18m32s     19m
```

La columna `DURATION` es precisamente la respuesta a la pregunta del equipo móvil «cuánto tarda
la compilación». Ejecuta el mismo Job una segunda vez, borrándolo y volviéndolo a crear, y
tardará lo mismo: no tenemos caché, y sabemos por qué.

## Paso 9. Recuperar el APK

📍 **Dónde:** en el panel del tenant, en la tarjeta del bucket.

El bucket tiene una interfaz web — ábrela desde la tarjeta del bucket e inicia sesión con los
mismos `accessKey` y `secretKey`. Dentro verás:

```
propusk/propusk-20260821-141207.apk
propusk/propusk-latest.apk
```

Dos nombres para un solo archivo es una práctica común: el nombre con fecha muestra el historial
de compilaciones, y por `latest` un tester siempre coge la más reciente sin preguntar qué fecha
es hoy.

Fíjate en que la «carpeta» `propusk` en realidad no existe. En el almacenamiento de objetos no
hay directorios: `propusk/propusk-latest.apk` es el nombre completo del objeto, y la barra
dentro de él la dibuja como un árbol la interfaz para nuestra comodidad.

**En qué se diferencia esto del recurso compartido de archivos** al que estás
acostumbrado:

| | Recurso compartido (NFS, SMB) | Almacenamiento de objetos (S3) |
|---|---|---|
| Cómo se conecta | se monta como un disco | no se monta, peticiones por HTTP |
| Escrituras parciales | puedes escribir en medio de un archivo | no se permite, un objeto se pone entero |
| Directorios | reales | no hay, la barra es parte del nombre |
| Bloqueos | sí | no |
| Quién puede llegar | quien esté en la misma red | cualquiera con una clave y HTTPS |
| Cuánto cabe | lo que aguante el volumen | prácticamente sin techo |

De ahí la regla para elegir: **una base de datos o una carpeta compartida de documentos — un
recurso compartido de archivos; artefactos y copias de seguridad — almacenamiento de objetos**. Intentar
poner una base de datos en S3 es tan doloroso como repartir APK por SMB a través de internet.

## La verificación

📍 **Dónde:** en la laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

```bash
# El script llega al clúster lab con el mismo archivo de acceso que tú. Las credenciales del bucket
# las toma del secret bucket-creds — no necesitas introducir nada por separado
export KUBECONFIG=~/lab.kubeconfig
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo instalarlo se
describe al inicio del Lab 0. Puedes completar el lab sin WSL, pero no habrá informe de
artefacto.

El script no comprueba que aplicaste el manifiesto, sino que la compilación llegó hasta el
final: el Job terminó con éxito, los registros contienen `BUILD SUCCESSFUL`, el APK llegó al bucket,
y el almacenamiento del secret realmente responde desde dentro del clúster.

## Limpieza

Una vez terminado, el Job no consume nada: el Pod terminó, y sus núcleos y gigabytes volvieron a
la capacidad libre del nodo en el momento de `Complete` — otro puede tomarlos de inmediato. Todo
lo que queda es una entrada en el clúster y los registros — unos pocos kilobytes.

No hace falta borrarlo enseguida; los registros todavía serán útiles. Cuando termines:

```bash
# delete -f = «quita del clúster lo que está descrito en este archivo». Junto con el Job
# desaparecerán también sus registros, así que este comando va el último en el tiempo, no el primero
kubectl delete -f android-build.yaml
kubectl delete -f propusk-src.yaml
# El secret lo borramos por separado: no hay archivo para él, lo creaste con un comando
kubectl delete secret bucket-creds
```

⚠️ **Devuelve el nodo a `u1.medium` si ya no lo necesitas** — si no, ocupará cuatro núcleos hasta
el final del workshop. Deja el bucket y su contenido: es pequeño y vendrá bien si quieres volver
a compilar.

Es precisamente esta baratura de la limpieza el argumento en contra de un servidor de
compilación dedicado. Tomamos un nodo más grande mientras duraba la compilación y devolvimos el
anterior con la edición de un solo campo.

## Qué sabemos hacer ahora

- Distinguir un Job de un Deployment y entender por qué una compilación no debe ejecutarse como lo segundo
- Ejecutar una tarea pesada de una sola vez en el clúster sin montar una máquina para ella
- Poner artefactos en el almacenamiento de objetos y explicar por qué no es un recurso compartido de archivos
- Leer `Pending` como «no cupo por los `requests`», no como «cargando»
- Nombrar el precio real de una compilación de Android en núcleos, gigabytes y minutos

## Y en vSphere esto habría sido

Una solicitud de una VM para hacer de agente de compilación. Una justificación de por qué
necesita dieciséis gigabytes si trabaja veinte minutos al día. Un rechazo. Un segundo intento un
trimestre después. Luego una máquina que está ociosa el 98% del tiempo y que, un año más tarde,
tiene instaladas tres generaciones del SDK porque da miedo borrarlas.

Aquí los recursos se toman mientras dura la tarea y se devuelven solos.

**Dónde vSphere es más cómodo, honestamente.** Una máquina de compilación que vive de forma
permanente tiene una ventaja innegable: en ella ya está todo descargado. Nuestro tiempo de
compilación es sobre todo la descarga del SDK y las dependencias, que un agente permanente no
tendría. Esto se cura con un volumen persistente para la caché, pero el volumen hay que montarlo,
vigilar su tamaño y limpiarlo — es decir, recuperar parte del mismísimo trabajo del que huíamos.
La diferencia es que un volumen cuesta céntimos y no requiere ninguna solicitud, mientras que una
máquina sí la requería.

Y segundo: una máquina viva a la que puedes entrar por SSH para ver por qué una compilación se
comporta de forma extraña es cómoda. Con el Pod de un Job solo puedes mirar los registros, y tras la
finalización aún menos. Depurar una compilación en el clúster es más lento al principio.
