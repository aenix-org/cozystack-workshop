# Lab 7 · Un caché frente a un backend lento

| | |
|---|---|
| **Tiempo** | 50 minutos, 10 de ellos de espera |
| **Qué demuestra** | La ganancia de un caché se mide, no se declara: eran 800 ms, ahora son de un solo dígito |
| **Qué necesitarás** | El clúster del lab 0, Harbor y la imagen del lab 6, `kubectl`, `docker`, acceso al panel |

> ⚠️ **`workshopXX` es un marcador, no un nombre.** Sustitúyelo por tu propio número de tenant, o
> el comando irá al tenant de otra persona y obtendrás un acceso denegado — o, peor,
> los datos de otra persona. Recibiste tu número junto con tu contraseña.

## Por qué esto importa

El servicio «Pases» funciona, seguridad de la información está contenta, el registro es propio. Y entonces aparecen los guardias.

> En el control de acceso la lista de invitados tarda diez segundos en abrir. La gente hace fila, nosotros
> miramos la pantalla y esperamos. Antes iba bien.

Esto es lo que ocurre. Cada fila de la lista es un invitado, cada invitado tiene un empleado que
lo invitó, y los registros de los empleados no están en tu poder. Están en un sistema de RR. HH.
instalado allá por 2011, y tarda **800 milisegundos** en responder una petición. Doce filas
en pantalla — casi diez segundos.

No puedes reescribir el sistema de RR. HH.: no es tuyo, es de otra persona, y su cola
de cambios está copada hasta el año que viene. Tampoco puedes acelerarlo, por la misma razón.

Lo que sí puedes hacer es dejar de preguntarle tan seguido. El apellido y el departamento de un empleado cambian
más o menos una vez cada varios años. Preguntárselos al sistema lento **cada vez** que se abre la lista
es un derroche: basta con preguntar una vez y recordar la respuesta.

El lugar donde se recuerdan las respuestas se llama caché. Hoy vamos a poner uno — y, lo que
más importa, **medir la diferencia antes y después**. No «se volvió más rápido», sino un número concreto.

## Miniglosario

| Término | Qué es | Como… pero |
|---|---|---|
| **Caché** | Almacenamiento rápido de respuestas ya listas a preguntas repetidas | **Un caché de lectura en una cabina de almacenamiento**, pero aquí decide qué cachear la aplicación, no el dispositivo |
| **Redis** | Un almacén clave-valor mantenido enteramente en RAM | no hay un análogo directo; lo más cercano es memcached, si te lo has cruzado |
| **Clave (key)** | La cadena por la que se busca un valor en el caché | **Un nombre de archivo**, pero te lo inventas tú, y todo depende de cómo lo hagas |
| **TTL (time to live)** | Cuánto vive una entrada antes de desaparecer por sí sola | **Un periodo de retención de instantáneas**, pero el borrado ocurre sin que intervenga nadie y sin ninguna tarea programada |
| **Fallo (cache miss)** | La respuesta no está en el caché, hay que ir a la fuente lenta | **Un fallo de caché de lectura en una cabina de almacenamiento**, pero un fallo aquí no cuesta milisegundos sino un viaje al sistema de otra persona |
| **Acierto (cache hit)** | La respuesta se encontró en el caché | **Un acierto de caché de lectura**, pero aquí el acierto lo cuenta la aplicación, y también se ve en la respuesta en el campo `cached` |
| **Sentinel** | Un servicio que vigila a Redis y reasigna el rol de líder ante un fallo | **Un agente de HA**, pero corre dentro del propio Redis, no hace falta un clúster aparte para él |
| **Servicio gestionado** | Un servicio que la plataforma instala, actualiza y respalda por ti | no obtienes root en la máquina donde corre — y ese es el punto |
| **Fortio** | Un generador de carga con interfaz web y un histograma de latencia | no tiene contraparte en vSphere: no es una herramienta para medir infraestructura sino para medir un servicio |
| **p50 / p99** | La mediana y los «peores porcentajes»: el 99% de las peticiones tiene una latencia no mayor a esta | la latencia promedio engaña, estos dos números no |

## Dos kubeconfigs: no los mezcles

En este lab hay dos clústeres de nuevo.

| Kubeconfig | Qué es | Qué hacemos en él |
|---|---|---|
| `~/.kube/workshop` | El clúster de gestión de Cozystack, tu tenant | mirar Redis: dirección, estado |
| `~/lab.kubeconfig` | **Tu** clúster `lab` del lab 0 | desplegar la aplicación y medir |

Ambos se obtienen del panel: el del tenant desde el Secret `kubeconfig-tenant-workshopXX` en la pestaña
Secrets, el del clúster desde la sección de acceso de tu clúster `lab`.

⚠️ **Antes de cada bloque de comandos se indica a dónde está dirigido.** Si algo se comporta
de forma extraña, lo primero que hay que hacer es `echo $KUBECONFIG`.

## Qué hay en la carpeta del lab

Ya tienes todos los archivos — los tomaste junto con el repositorio. No hay nada que
crear ni volver a teclear: donde abajo diga `kubectl apply -f name.yaml`, el archivo sale de aquí.

```bash
# todos los comandos de este lab se ejecutan desde la carpeta del lab — entra en ella
cd labs/07-redis
```

| Archivo | Qué es | Cuándo viene bien |
|---|---|---|
| `app/` | Las fuentes del servicio «Pases», la versión con caché | lo compilas localmente, `docker build` |
| `hr-legacy.yaml` | Un stub del directorio legado: responde lento, como el real | lo aplicas en tu clúster `lab` |
| `passes-api.yaml` | El servicio «Pases» sin caché — primero medimos qué tan malo es | lo aplicas en el mismo lugar |
| `cache-patch-broken.yaml` | Un patch **deliberadamente incompleto** que enciende el caché | lo aplicas para ver el error |
| `cache-patch.yaml` | El patch que funciona. Un patch, no un manifiesto completo: ves exactamente qué cambia | lo aplicas después del recorrido |
| `fortio.yaml` | El generador de carga para las mediciones de antes y después | lo aplicas en el mismo lugar |
| `check.sh` | Una comprobación de que la segunda petición es un orden de magnitud más rápida que la primera | lo ejecutas al final del lab |

## Paso 1. Compila la versión v2 y súbela a tu propio registro

📍 **Dónde:** en tu laptop.

La carpeta `app/` contiene el código fuente. Se diferencia de la versión del lab anterior en dos cosas:
un modo «directorio lento» y el manejo del caché.

<details>
<summary><b>Una mirada más de cerca: qué hay dentro de app/</b></summary>

**Una imagen, dos roles.** La variable `MODE` determina como qué arranca el proceso:

| `MODE` | Qué es | Qué hace |
|---|---|---|
| `hr` | un stub del directorio legado | duerme `HR_DELAY` (800 ms por defecto) y devuelve los datos del empleado |
| `api` | el propio servicio «Pases» | va al directorio, y si `REDIS_ADDR` está definido — primero al caché |

Dos imágenes en lugar de una significarían dos lugares donde puedes olvidar actualizar la versión.

**Cómo funciona el viaje por los datos.** Toda la lógica de cacheo son unas veinte líneas:

```go
if cache != nil {
    raw, found, err := cache.Get(key)
    switch {
    case err != nil:
        log.Printf("кеш недоступен (%v), иду в справочник", err)
    case found:
        if json.Unmarshal([]byte(raw), &emp) == nil {
            fromCache = true
        }
    }
}

if !fromCache {
    emp, err = fetchEmployee(hrClient, hrURL, id)
    ...
    cache.SetTTL(key, string(b), ttl)
}
```

Fíjate en la primera rama: **si el caché no está disponible, la aplicación no se cae.** Escribe
en el registro y va al directorio — lento, pero correcto. Esto no es adorno, es una
propiedad obligatoria de cualquier caché: un caché acelera pero no puede ser condición para seguir
operativo. Si el servicio se cae junto con el caché, no construiste un caché sino un
punto de fallo más.

De esta propiedad, por cierto, crecerá un fallo predecible un poco más adelante en el lab.
Una aplicación que sigue funcionando en silencio es agradable en producción y traicionera al depurar.

**La clave.** `employee:42` — un nombre de entidad, dos puntos, un identificador. Los dos puntos aquí no son
sintaxis de Redis sino un hábito ampliamente adoptado: te permite luego buscar por el patrón `employee:*` y no
confundir tus propias claves con las de otro cuando dos aplicaciones viven en un mismo Redis.

**El tiempo de vida lo fija el mismo comando que la escritura:**

```go
r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
```

No `SET` y luego `EXPIRE` como dos comandos. Entre dos comandos la conexión puede caerse — y
la clave se queda en el caché para siempre. A claves así se las anda cazando meses después.

**El cliente de Redis aquí es propio, cincuenta líneas.** El protocolo de Redis es basado en texto, y para `GET`
y `SET` cabe en una sola función. En un proyecto real tomarías una biblioteca ya hecha —
se ocupa del pooling de conexiones, los reintentos y el sentinel. Aquí uno propio hace falta precisamente para que la
compilación no tenga dependencias externas: recuerda cómo empezó el lab anterior.

**Un cliente HTTP aparte con un pool de conexiones ampliado:**

```go
tr := http.DefaultTransport.(*http.Transport).Clone()
tr.MaxIdleConnsPerHost = 64
```

Sin esta línea, bajo carga la mitad del tiempo se iría en establecer conexiones TCP al
directorio, y la medición mostraría no la latencia del directorio sino nuestra propia
chapucería. La primera regla de las mediciones: asegúrate de que mides lo que crees que mides.

</details>

Compílala y súbela a tu propio Harbor. `build` compila la imagen desde el `Dockerfile` y la deja
en tu laptop, `push` la envía al registro. El nombre de la imagen es el mismo que en el lab
anterior, pero el tag es distinto — `v2`: el registro tendrá ahora ambas versiones, y la vieja
no irá a ningún lado.

Sustituye tu propia dirección:

```bash
cd labs/07-redis

# build = «compila la imagen desde el Dockerfile».
#   --platform linux/amd64  para qué procesador compilar; los nodos del clúster son x86
#   -t <host>/<project>/<name>:<tag>  cómo nombrar el resultado; el host del registro al
#                           inicio del nombre es a donde push lo enviará después
#   app/                    la carpeta con el Dockerfile y las fuentes desde donde compilar
docker build --platform linux/amd64 -t harbor.workshop03.example.org/passes/passes-api:v2 app/

# push = «envía la imagen al registro». La dirección se toma de la primera parte del
# nombre de la imagen, las credenciales — del docker login que hiciste en el lab anterior.
docker push harbor.workshop03.example.org/passes/passes-api:v2
```

⚠️ **`--platform linux/amd64` es obligatorio si tienes un Mac con Apple Silicon o un laptop con
ARM.** Sin él la imagen se compilará para ARM, se subirá sin errores, y en el clúster dará
`CrashLoopBackOff` con `exec format error` en los registros.

## Paso 2. Despliega el directorio y el servicio

📍 **Dónde:** en tu laptop, el clúster `lab`.

En ambos manifiestos, en lugar de la dirección del registro hay un marcador `HARBOR-HOST`: `sed`
lo reemplaza, editando los archivos en el sitio. Luego `apply` entrega al clúster lo descrito en los
archivos, y `rollout status` espera a que las copias se levanten.

```bash
# KUBECONFIG le dice a kubectl qué archivo de acceso usar. Cambiamos a
# tu clúster `lab`; se mantiene hasta que cierres la ventana de la terminal.
export KUBECONFIG=~/lab.kubeconfig

# sed -i = «edita el archivo en el sitio».
#   's|viejo|nuevo|g'  reemplaza cada aparición; el separador | se usa en lugar de / porque
#                      la dirección contiene barras
#   La versión de sed de macOS exige un argumento obligatorio después de -i; las comillas vacías
#   significan «no hacer copia de respaldo». En Linux ese argumento no debe estar.
#   Hay dos archivos al final de la línea: sed acepta varios a la vez y los edita en una sola pasada.

# Linux
sed -i    's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml

# apply = «lleva el clúster a lo descrito en los archivos». El flag -f se repite por cada archivo.
kubectl apply -f hr-legacy.yaml -f passes-api.yaml

# rollout status espera a que las copias estén listas y termina por sí solo; si no lo están, devuelve un error
kubectl rollout status deployment/hr-legacy
kubectl rollout status deployment/passes-api
```

⚠️ Ambos manifiestos referencian el Secret `harbor` — el mismísimo `imagePullSecret` del lab
anterior. Si no lo hiciste, los Pods caerán en `ImagePullBackOff`. Para crear el Secret:

```bash
# create secret docker-registry = «crea un Secret con credenciales del registro»;
# tal Secret lo puede leer el propio kubelet cuando descarga la imagen a un nodo.
#   harbor             el nombre del Secret en el clúster — ambos manifiestos lo referencian
#   --docker-server    para qué registro son estas credenciales
#   --docker-username  quién inicia sesión; --docker-password — la contraseña del administrador de Harbor
kubectl create secret docker-registry harbor \
  --docker-server=harbor.workshop03.example.org \
  --docker-username=admin --docker-password='tu-contraseña-admin'
```

Comprobemos que la cadena funciona. El servicio solo se ve desde dentro del clúster, así que la
petición la hacemos también desde allí: levantamos un Pod de un solo uso con `curl`, le pregunta al
servicio `passes-api`, imprime la respuesta y desaparece.

```bash
# run probe = «ejecuta un Pod llamado probe».
#   --rm              elimina el Pod en cuanto termina
#   -i                muéstranos su salida
#   --restart=Never   no reiniciar: es un comando de una sola vez, no un servicio permanente
#   --image=...       qué imagen usar; la versión está fijada para que no llegue nada nuevo
#   --quiet           no imprimir líneas de servicio, solo la respuesta
#   --                todo lo que va después de estos dos guiones es el comando dentro del Pod
# Una dirección de la forma <service>.<namespace>.svc.cluster.local es el nombre interno del servicio;
# por él los Pods se encuentran entre sí sin conocer direcciones.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Lo que deberías ver:**

```json
{"cache":"off","cached":false,"dept":"Логистика","id":"42","name":"Попова Е. К.",
 "pod":"passes-api-6f8b9c7d5-x2ktm","took_ms":803,"ttl_s":60}
```

Los campos clave: `cache: off` — sin caché, `took_ms: 803` — ahí están, tus ochocientos
milisegundos. Este es justo el número que vamos a reducir.

## Paso 3. Mide qué tan malo es ahora

📍 **Dónde:** en tu laptop, el clúster `lab`.

Una petición no es una medición. Necesitas una carga parecida a la real y una distribución de latencias.

Despliega el generador. Se levanta como una aplicación cualquiera y vive en el clúster junto al
servicio — así la medición no depende de tu internet ni del túnel:

```bash
# el archivo tiene dos objetos: el propio generador y un servicio para él
kubectl apply -f fortio.yaml
kubectl rollout status deployment/fortio
```

Ahora arrancamos la carga. El comando `kubectl exec` ejecuta algo dentro de un Pod que ya está corriendo —
aquí, dentro del generador, se lanza el propio generador, en modo bombardeo:

```bash
# exec deploy/fortio = ejecuta un comando dentro del Pod de esta aplicación
#   --            el límite: kubectl a la izquierda, a la derecha el comando que entra al Pod
#   fortio load   modo bombardeo: enviar peticiones y medir el tiempo de respuesta
#   -qps 20       veinte peticiones por segundo — marcamos un ritmo, no «apretar todo lo posible»
#   -t 20s        cuánto dura la medición
#   -c 16         dieciséis conexiones en paralelo. El número no es arbitrario:
#                 el directorio responde en 800 ms, así que una conexión alcanza
#                 poco más de una petición por segundo. Para mantener las 20 por
#                 segundo fijadas, hacen falta no menos de dieciséis conexiones — si no, Fortio
#                 chocará contra el muro de la latencia y no entregará el ritmo pedido.
#   el último argumento es la dirección que bombardeamos
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Lo que deberías ver** — al final de la salida, un histograma y líneas con percentiles:

```
# target 50% 0.801
# target 90% 0.806
# target 99% 0.812
Code 200 : 400 (100.0 %)
```

**Anota estos números.** En diez minutos los necesitarás para comparar, y la memoria está hecha
de forma que «bueno, andaba por los ochocientos» se convierte en «bueno, andaba por medio segundo».

### Lo mismo con el ratón

Con el ratón — esto no es el panel de Cozystack: trabaja con el clúster de gestión y muestra
las entradas del catálogo del tenant, pero no se asoma dentro de tu clúster `lab`. El propio generador tiene
su propia interfaz web, y hay que alcanzarla a través de un túnel.

```bash
# port-forward svc/fortio = un túnel desde tu laptop hasta el servicio del generador en el clúster
#   8081:8080 — el número de la izquierda es el puerto en tu laptop, el de la derecha el puerto del servicio en el clúster
# Se usa el puerto 8081 porque el 8080 podría estar ocupado por otra cosa en tu máquina.
# No cierres la ventana: el túnel vive mientras el comando corre. Para detenerlo — Ctrl+C.
kubectl port-forward svc/fortio 8081:8080
```

Abre <http://localhost:8081/fortio>. Rellena:

| Campo | Valor |
|---|---|
| URL | `http://passes-api.default.svc.cluster.local/employee?id=42` |
| QPS | `20` |
| Duration | `20s` |
| Connections | `16` |

Haz clic en **Start**. Abajo se dibujará un histograma de latencia. Es más claro que los números:
puedes ver todas las peticiones agrupadas en una banda estrecha alrededor de los 800 ms — o sea que va lento no
«a veces» sino siempre y por la misma cantidad.


<details>
<summary><b>Por qué p50 y p99, no la latencia promedio</b></summary>

La latencia promedio es la métrica más engañosa en operaciones.

Imagina: noventa peticiones a 10 ms y diez peticiones a 2000 ms. El promedio es 209 ms, y por el
informe todo se ve decente. Pero en realidad uno de cada diez usuarios esperó dos segundos y se fue.

**p50 (la mediana)** — la mitad de las peticiones son más rápidas que este número, la mitad más lentas. Responde a la
pregunta «cuánto espera un usuario común».

**p99** — el 99% de las peticiones son más rápidas que este número. Responde a la pregunta «qué tan mal se pone».
Es p99 lo que determina si los guardias en el control de acceso se quejarán: la gente no se queja
del promedio, sino de esa vez que le tocó esperar.

En nuestra medición p50 y p99 casi coincidieron — 801 y 812 ms. Es señal de que la lentitud no es
aleatoria sino sistémica: lento exactamente siempre. Esto se cura con un caché. Si p50 fuera 10 ms y p99 fuera
2000 ms, la causa sería otra, y un caché no ayudaría.

</details>

## Paso 4. Crea Redis

📍 **Dónde:** en el navegador, en el panel de Cozystack. Redis es un recurso compartido del tenant, como Harbor.

Tenant → **Create application** → `Redis`.

| Campo | Valor | Por qué así |
|---|---|---|
| Name | `cache` | va dentro de los nombres de los servicios, más corto es más manejable |
| Replicas | `2` | una copia líder y una seguidora: veremos qué nos da eso |
| Size | `1Gi` | el directorio de empleados cabrá en memoria de sobra |
| Storage class | `replicated` | |
| Resources preset | deja el sugerido | |
| Version | `v8` | |
| Auth enabled | **encendido** (por defecto) | la plataforma genera la contraseña ella misma |
| External | **apagado** | no hay razón para exponer este caché hacia afuera |

Cuenta con esperar de tres a cinco minutos a que esté listo.

⚠️ **Este Redis no tiene nada que ver con el Redis que quizás viste en el formulario de creación de Harbor.**
Allí es el propio caché interno del registro. Este es el tuyo, para tu aplicación.

<details>
<summary><b>En qué se diferencia un Redis gestionado de un Redis instalado en una VM</b></summary>

Instalar Redis en una máquina virtual es media hora de trabajo: `apt install redis`, ajustar `bind`
y `requirepass`, habilitarlo al arranque. Precisamente por eso un servicio gestionado parece excesivo.
La diferencia no está en la instalación sino en lo que ocurre después.

**Replicación.** Pusiste `replicas: 2` — y obtuviste dos copias de los datos en nodos distintos más
tres sentinels que las vigilan. Si el nodo con la copia líder muere, los sentinels celebran una
elección y hacen líder a la segunda copia. La aplicación sobrevivirá esto con una pausa de unos
segundos. Ensamblar lo mismo a mano es un día de trabajo y luego otro día para verificar que
realmente hace conmutación por error (failover), en vez de solo verse configurado.

**Actualizaciones.** Una vulnerabilidad en Redis no es rara. En una VM una actualización significa `apt upgrade`, un reinicio,
y la esperanza de que la configuración sobreviva a un cambio de versión mayor. Aquí la actualización de la imagen llega junto
con una actualización de la plataforma, y el orden en que se reinician las copias está dispuesto de modo que el servicio
no desaparezca.

**Observabilidad.** Las métricas ya se están recopilando: un exporter corre junto a cada
copia, las gráficas están ahí sin ningún esfuerzo de tu parte. En una VM eso es un paquete más, una
configuración más, y una cosa más que quedó en el olvido.

**A qué renuncias.** Con honestidad: root en la máquina con Redis. No puedes entrar por SSH, no puedes editar
la configuración a mano, no puedes dejar tu propio script al lado. Cualquier cosa que no esté expuesta como
parámetro de la aplicación queda fuera de tu alcance — y ni de lejos todo está expuesto. Si necesitas un
`maxmemory-policy` no estándar o un módulo de Redis, un servicio gestionado no te lo dará, y
tendrás que instalar el tuyo propio en una VM. Esto es una limitación real, no una nimiedad.

</details>

## Paso 5. Encuentra la dirección de Redis y comprueba la conectividad

📍 **Dónde:** en tu laptop, el clúster **de gestión**.

Redis vive en tu tenant en el clúster de gestión, y la aplicación en tu clúster `lab`.
Son dos clústeres distintos, y lo primero que hay que hacer es asegurarse de que el segundo llega
al primero.

Miremos qué servicios han aparecido:

```bash
# --kubeconfig fija el archivo de acceso justo en el comando — por una sola vez, sin tocar KUBECONFIG.
# Así dos comandos seguidos pueden dirigirse a clústeres distintos sin confundirse.
#   -n tenant-workshopXX  el namespace de tu tenant
#   get svc               «muestra los servicios» — direcciones permanentes respaldadas por Pods
#   | grep redis          conserva solo las líneas con la palabra redis en la salida
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX get svc | grep redis
```

**Lo que deberías ver** — varios servicios con prefijos elocuentes:

| Nombre | Qué hay detrás |
|---|---|
| `rfrm-redis-cache` | la copia líder (master) — aquí se escribe y se lee |
| `rfrs-redis-cache` | las copias seguidoras (replicas) — solo lectura |
| `rfs-redis-cache` | sentinel — el servicio que vigila y cambia los roles |

⚠️ **De dónde sale el `redis-` de más en los nombres.** La plataforma agrega al nombre de la aplicación un
prefijo con el tipo de servicio: la aplicación `cache` de tipo Redis se llama internamente `redis-cache`.
De ahí `rfrm-redis-cache`, no `rfrm-cache`. No adivines los nombres — mira la salida
del comando de arriba, esa es la fuente de la verdad.

Necesitamos `rfrm-redis-cache`: el caché tanto escribe como lee, y solo puedes escribir en la copia líder.

El nombre completo por el que se ve desde tu clúster se arma así:

```
rfrm-redis-cache.tenant-workshopXX.svc.cozy.local
```

Toma la contraseña. 📍 **Dónde:** en el panel, la aplicación `cache`, la pestaña de secretos. Necesitas
el Secret `redis-cache-auth`, la clave `password`.

Ahora — una comprobación de conectividad. 📍 **Dónde:** en tu laptop, el clúster **`lab`**.

En tu clúster levantamos un Pod de un solo uso con un cliente de Redis y le pedimos que le diga la palabra `ping` a
Redis. Si vuelve una respuesta, entonces el caché del tenant se ve desde el clúster `lab` —
y eso es la única cosa que estamos comprobando ahora mismo.

⚠️ **Pasamos la contraseña por la variable `REDISCLI_AUTH`, no por el flag `-a`.** Todo lo que
acaba en los argumentos de un comando es visible en la lista de procesos del nodo y se queda en la
descripción del Pod — que puede leer cualquiera con acceso a tu namespace. El propio `redis-cli` advierte
sobre esto, y silenciar la advertencia en vez de quitar la causa es un mal hábito.

```bash
export KUBECONFIG=~/lab.kubeconfig

# run redis-probe = un Pod de un solo uso con el cliente redis-cli:
#   --rm --restart=Never  hizo su trabajo y se eliminó a sí mismo, no hace falta reiniciar
#   -i --quiet            muéstranos la salida y no imprimas líneas de servicio
#   --env=REDISCLI_AUTH   la contraseña entra al Pod como variable de entorno, no como argumento
#   --                    a la derecha de estos guiones va el comando que entra al Pod
#   redis-cli -h <name>   a qué servidor conectarse; el nombre es ese mismo completo
#   ping                  un breve «¿estás vivo?»; la respuesta a eso es PONG
kubectl run redis-probe --rm -i --restart=Never --image=redis:7-alpine --quiet \
  --env=REDISCLI_AUTH='tu-contraseña-redis' -- \
  redis-cli -h rfrm-redis-cache.tenant-workshopXX.svc.cozy.local ping
```

**Lo que deberías ver:**

```
PONG
```

⚠️ **Si en lugar de `PONG` obtuviste un error de resolución de nombre** — entonces los nombres internos del
clúster de gestión no se ven desde tu clúster. Esto se arregla dirigiéndose a él por IP:

```bash
# -o jsonpath='{.spec.clusterIP}' — imprime un solo campo del objeto: la dirección interna
# que la plataforma asignó a este servicio. {"\n"} agrega un salto de línea.
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX get svc rfrm-redis-cache \
  -o jsonpath='{.spec.clusterIP}{"\n"}'
```

De aquí en adelante, sustituye en todos lados la dirección que obtuviste en lugar del nombre. Funcionará igual;
lo único malo es que si Redis se recrea la dirección cambia, mientras que el nombre no. Si
tampoco responde por dirección — escribe en el chat del taller, es un problema de configuración del entorno de pruebas,
no un error tuyo.

## Paso 6. Enciende el caché

📍 **Dónde:** en tu laptop, el clúster `lab`.

Cambiamos la aplicación no con un manifiesto entero sino con un patch — así ves exactamente
qué cambia. Primero sustituimos la dirección de tu Redis en el patch, luego entregamos el patch al
clúster: `kubectl patch` añade cambios a un objeto ya existente en vez de reemplazarlo
por completo.

```bash
# la misma sustitución de dirección que antes, solo que el marcador es distinto — REDIS-ADDR

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml

# patch deployment passes-api = «ajusta este objeto con lo que hay en el archivo»
#   --patch-file  de dónde tomar los cambios
# Cambiar variables de entorno significa Pods nuevos: los viejos serán reemplazados.
kubectl patch deployment passes-api --patch-file cache-patch-broken.yaml

# espera a que las copias nuevas estén listas — si no, mediremos aún las viejas
kubectl rollout status deployment/passes-api
```

Mide otra vez — con el mismo comando con el que medimos antes de encender el caché. Las
condiciones del bombardeo deben coincidir hasta el último flag, o no habrá nada que comparar:

```bash
# las mismas veinte peticiones por segundo, los mismos veinte segundos, las mismas dieciséis conexiones
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

> **Detente y piensa antes de seguir leyendo.**
>
> Los números no cambiaron: los mismos ochocientos milisegundos. Y sin embargo ni un solo Pod
> se cayó, no hay errores en las respuestas, cada petición devolvió `200`. Redis está creado,
> la dirección es correcta — acabas de obtener un `PONG` de él.
>
> ¿Dónde mirar?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

Primero mira qué responde la propia aplicación: la respuesta tiene campos que muestran si el
caché está encendido y si la respuesta vino de él.

```bash
# el mismo Pod de un solo uso con curl que antes: le preguntamos al servicio desde dentro del clúster
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

```json
{"cache":"redis","cached":false,"took_ms":802, ...}
```

`cache: redis` — el caché está encendido. `cached: false` — y sin embargo la respuesta no vino de él. Y
es **siempre** false, sin importar cuántas veces lo repitas.

Ahora el registro. La aplicación escribe ahí lo que no pudo hacer — y ese es el único lugar donde
la verdad se ve actualmente:

```bash
# logs = «muestra lo que la aplicación escribió en su salida».
#   -l app=passes-api  a través de todas las copias con esta etiqueta a la vez, no una copia nombrada
#   --tail=20          las últimas veinte líneas de cada copia, no todo el registro
kubectl logs -l app=passes-api --tail=20
```

```
кеш недоступен (redis: NOAUTH Authentication required.), иду в справочник
кеш недоступен (redis: NOAUTH Authentication required.), иду в справочник
```

Ahí está la respuesta. Especificamos la dirección de Redis pero no la contraseña. Redis exige
autenticación — tú mismo encendiste `Auth enabled` al crearlo, y esa es la configuración correcta. La
aplicación intentó honestamente, fue rechazada, lo escribió en el registro y fue al directorio.

**Por qué esto no parecía una avería.** Porque no hubo avería. La aplicación está
diseñada para sobrevivir a que el caché no esté disponible: un caché acelera pero no puede ser una
condición para seguir operativo. En producción esto te salva — la caída de Redis no tumba
el servicio. Al depurar, esa misma propiedad esconde el problema: todo está verde, no hay
errores, pero no más rápido.

**Una lección más amplia que este error.** Un fallo que no estorba el trabajo es el
tipo de fallo más caro. No levanta ninguna alarma y vive en producción durante meses. De ahí una
regla práctica: **todo acelerador debe tener una señal observable de que está funcionando.** Para nosotros esa es
el campo `cached` en la respuesta. Si no estuviera, ahora mismo estarías adivinando.

En un sistema real, en este punto hay una métrica de «cache hit ratio» y una alerta por si cae a cero.

</details>

## Paso 7. Pon la contraseña y mide de nuevo

📍 **Dónde:** en tu laptop, el clúster `lab`.

La contraseña de Redis vive en el clúster de gestión, y la aplicación la necesita en el tuyo. La
trasladamos — a través de una variable de shell, para que la contraseña no acabe en el historial de comandos:

```bash
# read pone lo que se teclea en el teclado en la variable REDIS_PASS:
#   -s  no mostrar en pantalla lo que se teclea
#   -r  no tratar la barra invertida como carácter especial
# Nada aparecerá en pantalla después de esta línea: pega la contraseña del panel y Enter.
read -rs REDIS_PASS

# create secret generic = un Secret cualquiera, un conjunto de pares clave-valor.
#   redis-password              el nombre del Secret en el clúster
#   --from-literal=password=... crea en él una clave password con este valor;
#                               es el par «nombre del Secret + clave» al que el patch referenciará
kubectl create secret generic redis-password --from-literal=password="$REDIS_PASS"

# unset borra la variable para que la contraseña no llegue a los siguientes comandos en esta ventana
unset REDIS_PASS
```

Aplica el patch completo. Tiene la misma dirección de Redis más una referencia al Secret recién creado y
el tiempo de vida de las entradas del caché; el recorrido está en el spoiler justo después del comando.

```bash
# la misma sustitución de dirección, ahora en el archivo del patch que funciona

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml

# ajusta el Deployment existente con el contenido del archivo y espera las copias nuevas
kubectl patch deployment passes-api --patch-file cache-patch.yaml
kubectl rollout status deployment/passes-api
```

<details>
<summary><b>Una mirada más de cerca: qué hay dentro de cache-patch.yaml</b></summary>

```yaml
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: REDIS_ADDR
              value: "rfrm-redis-cache.tenant-workshopXX.svc.cozy.local:6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-password
                  key: password
            - name: CACHE_TTL
              value: "60"
```

**Por qué un patch, no un manifiesto completo.** Un patch es «cambia esto», no «el estado debe ser
así». En el archivo ves exactamente qué cambia, no doscientas líneas entre las que tienes que cazar
con los ojos las tres nuevas.

**Por qué esto no borra las demás variables.** Las listas en Kubernetes pueden fusionarse por clave. Para `env`
la clave es el campo `name`: las tres entradas del patch se agregan a las que ya están, y
la entrada `REDIS_ADDR` reemplaza a la del mismo nombre que quedó del patch roto. Las listas de
contenedores se fusionan igual, por nombre — por eso `- name: api` es obligatorio; sin él Kubernetes
no entenderá qué contenedor estás editando.

**Por qué la contraseña por `secretKeyRef`, no como texto.** El valor llega del Secret
`redis-password` en el momento en que el Pod arranca. En el manifiesto en sí no hay contraseña —
y eso importa, porque el manifiesto irá a Git, donde se quedaría para siempre. El Secret
no llegará a Git.

Con honestidad: el Secret en el clúster sigue estando en claro, solo que en otro lugar. Cualquiera que
pueda leer Secrets en este namespace verá la contraseña. La solución de verdad es un almacén de secretos
externo, y eso es un lab aparte.

**`CACHE_TTL: 60`.** Sesenta segundos es un compromiso. Abajo — lee el siguiente spoiler.

</details>

Comprobemos una por una antes de aplicar carga. Dos peticiones idénticas seguidas para un identificador
que no se ha pedido aún: la primera será por fuerza lenta, la segunda — rápida.

```bash
# el mismo Pod de un solo uso con curl, pero dentro se lanza una shell sh:
#   sh -c '...'  ejecuta varios comandos pasados como una sola cadena
#   ; echo       inserta un salto de línea entre las respuestas para que no se peguen
# se usa id=777 porque a este empleado aún no se lo ha pedido: seguro no está en el caché.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  sh -c 'curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"; echo;
         curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"'
```

**Lo que deberías ver** — dos respuestas, y son distintas:

```json
{"cached":false,"took_ms":804, ...}
{"cached":true,"took_ms":1, ...}
```

La primera petición es un fallo: el caché estaba vacío, hubo que ir al directorio, 804 ms. La
segunda es un acierto: la respuesta ya estaba ahí, 1 ms.

Ahora una medición bajo carga, el mismo comando con los mismos flags, por tercera vez:

```bash
# no cambiamos nada en las condiciones del bombardeo: solo cambia lo que hay dentro del servicio
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**Lo que deberías ver:**

```
# target 50% 0.0012
# target 90% 0.0021
# target 99% 0.0043
Code 200 : 400 (100.0 %)
```

## Paso 8. Suma la ganancia

📍 **Dónde:** en un papelito.

Reúne tres números en una tabla. Los tuyos diferirán — el entorno de pruebas, la red, los vecinos
en el nodo:

| | p50 | p99 | Qué significa para los guardias |
|---|---|---|---|
| Sin caché | 801 ms | 812 ms | una lista de 12 filas abre en ~9,6 s |
| Caché encendido, sin contraseña | 802 ms | 815 ms | nada cambió |
| Caché funcionando | 1,2 ms | 4,3 ms | la misma lista — ~0,05 s |

La diferencia es de **varios cientos de veces**, y no es una figura retórica sino el cociente de
dos números medidos.

Fíjate en lo que **no** hicimos. No reescribimos el sistema de RR. HH. No agregamos nodos. No
cambiamos ni una sola línea en la lógica del servicio «Pases» — solo le enseñamos a no preguntar lo
mismo dos veces. El cambio cupo en tres variables de entorno.

<details>
<summary><b>Cuándo un caché no ayuda, y cómo verlo de antemano</b></summary>

Un caché no es una aceleración universal. Ayuda bajo una condición: **la misma pregunta se hace muchas
veces.** Ponte a prueba con tres casos.

**Cada petición es única.** Si la lista de invitados pidiera información sobre un empleado nuevo cada
vez, no habría aciertos en absoluto, y un viaje a Redis se agregaría a cada petición. Iría
más lento. Puedes confirmarlo así — ejecuta dos series cortas sobre identificadores distintos y mira
las primeras peticiones de cada una:

```bash
# dos bombardeos seguidos sobre empleados distintos, diez segundos cada uno.
# Al inicio de cada serie el caché está vacío para esa clave — y la primera petición va al directorio.
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=1"
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=2"
```

Las primeras peticiones de cada serie son fallos. Sobre un conjunto grande de claves que rara vez se repiten el caché
degenera en sobrecarga.

**Los datos cambian más seguido que el TTL.** Si la información de un empleado cambiara cada diez
segundos mientras el TTL estuviera puesto en 60, los guardias verían datos rancios hasta por un minuto. Un caché
siempre canjea frescura por velocidad, y decidir cuánta frescura puedes sacrificar no es una decisión
técnica sino una pregunta para el cliente.

**Lento no siempre, sino a veces.** ¿Recuerdas la diferencia entre p50 y p99 de la primera
medición? Si p50 es pequeño y p99 es enorme, no es la fuente de datos la que va lenta sino algo
intermitente: recolección de basura, vecinos en el nodo, bloqueos en la base de datos. Un caché enmascarará
esto pero no lo curará, y un día estarás desenredando exactamente lo mismo, solo que un año después y
con un caché encima.

</details>

<details>
<summary><b>Cómo se elige el TTL</b></summary>

El TTL es el único parámetro real de un caché, y se elige no por razones técnicas.

La pregunta va así: **¿por cuánto tiempo estás dispuesto a mostrar datos rancios?**

Para un directorio de empleados: un apellido se cambia una vez cada varios años, un departamento una vez al año.
El departamento de ayer en el control de acceso no molestará a nadie. El TTL bien podría ser una
hora, o un día.

Pusimos sesenta segundos para que el lab fuera observable: espera un minuto, repite la petición — verás
`cached: false` de nuevo, porque la entrada expiró y fue al directorio. Con un TTL de un día
tendrías que tomártelo por fe.

Casos límite:

| TTL | Qué obtienes |
|---|---|
| Demasiado pequeño | pocos aciertos, el caché apenas funciona, la carga sobre la fuente se mantiene |
| Demasiado grande | rápido, pero los usuarios ven datos de ayer y se quejan de otra cosa |
| Sin poner en absoluto | las claves se acumulan, la memoria se acaba, Redis empieza a expulsar lo que sea |

La última fila es la más traicionera. Un caché sin TTL se convierte con el tiempo en una base de datos que nadie
respalda.

</details>

## Verificación

📍 **Dónde:** en tu laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

El script va a ambos clústeres a la vez y los toma de variables de entorno. Las primeras dos
son obligatorias, la tercera es la ruta al kubeconfig del tenant.

```bash
cd labs/07-redis

# en qué clúster comprobar la aplicación — en tu `lab`
export KUBECONFIG=~/lab.kubeconfig
# tu número de tenant: con él el script arma el nombre del namespace tenant-workshop03
export COZY_TENANT=workshop03
# dónde vive el acceso al clúster de gestión — ahí el script mira el propio Redis.
# Puedes dejarla sin definir: entonces el script busca ~/.kube/workshop, y al no encontrarlo — omite
# las comprobaciones en el clúster de gestión y lo dice.
export COZY_KUBECONFIG=~/.kube/workshop

./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo instalarlo está escrito al
inicio del lab 0. Sin WSL puedes igualmente completar el lab, pero no habrá informe-artefacto.

El script no le cree la palabra a ningún manifiesto. Hace él mismo dos peticiones seguidas para un
identificador aleatorio y observa: la primera debe ser un fallo y tardar cientos de milisegundos, la
segunda un acierto y tardar de un solo dígito. Registra la diferencia en el informe como números. De
paso comprueba que el directorio lento realmente sea lento: sin eso la comparación no significaría nada.

## Limpieza

Todo hará falta en los labs siguientes — ahora no borramos nada.

Cuando termines con todos los labs:

```bash
# delete -f = elimina del clúster exactamente los objetos descritos en los archivos
kubectl delete -f passes-api.yaml -f hr-legacy.yaml -f fortio.yaml
# el Secret se creó con un comando, no con un archivo — lo eliminamos por nombre
kubectl delete secret redis-password
```

El propio Redis se elimina a través del panel, como una aplicación cualquiera.

Eliminar el caché es una operación barata y casi segura, y esa es una propiedad distintiva de los cachés:
**un caché no guarda datos que no existan en ningún otro lado.** Todo lo que hay en él puede recuperarse con un viaje
a la fuente. Perder Redis significa perder velocidad por unos minutos, mientras se vuelve a llenar — pero no
perder información. Con una base de datos no funcionará así, y en el lab sobre la base de datos volverás
a esto.

## Qué sabemos hacer ahora

- Provisionar un Redis gestionado y explicar qué te da la replicación que no configuraste
- Medir la latencia antes y después de un cambio, en vez de hablar de ella
- Leer p50 y p99 y entender por qué la latencia promedio engaña
- Elegir un TTL según cuánta obsolescencia tolera el cliente
- Encontrar el fallo que no estorba el trabajo — el tipo de fallo más caro

## Y en vSphere esto sería

No hay contraparte de esta tarea en vSphere, y vale la pena decirlo con claridad. Un caché no es un
objeto de infraestructura sino parte de la arquitectura de la aplicación. El hipervisor no puede cachear las respuestas del sistema
de RR. HH. y no debería poder.

Lo que harías en el mundo de las máquinas virtuales: una solicitud de una VM para Redis, la instalación,
la configuración de `requirepass`, la configuración del autoarranque, luego — si te da el tiempo — una segunda VM para
la réplica, sentinel, verificar la conmutación por error. Días de trabajo, de los cuales el caché propiamente dicho toma media
hora y el resto es andamiaje. De ahí viene un hábito conocido por cualquier administrador:
«vamos sin réplica por ahora, la agregamos después». Después, no la agregan.

La diferencia no es que Redis se instale más rápido aquí. La diferencia es que la réplica, la conmutación por error,
las métricas y las actualizaciones llegan por defecto, y «sin réplica por ahora» nunca surge como opción.

**Dónde vSphere es más cómodo, con honestidad.** Tres cosas.

**Control total.** En tu propia VM puedes instalar cualquier versión de Redis, cualquier módulo, cualquier
`maxmemory-policy`, y tu propio script de monitoreo al lado. Aquí tienes acceso solo a lo que está
expuesto como parámetros de la aplicación — y ni de lejos todo está expuesto.

**Diagnóstico.** Cuando Redis en una VM se comporta de forma extraña, entras por SSH y miras `redis-cli INFO`,
`SLOWLOG`, los contadores del sistema. Aquí no hay SSH, y llegar a la misma información tiene que pasar
por `kubectl exec` y las métricas — más lento y con menor resolución.

**Predecibilidad de los vecinos.** Una VM con Redis significa núcleos y memoria garantizados que ves en
vCenter. Un servicio gestionado vive en nodos compartidos junto a la carga de otro; los límites lo protegen,
pero «por qué hoy va dos milisegundos más lento» te llevará más tiempo averiguarlo que lo que te llevaría
en una máquina dedicada.
</content>
</invoke>
