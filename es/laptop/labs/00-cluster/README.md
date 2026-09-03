# Lab 0 · Tu propio clúster de Kubernetes

| | |
|---|---|
| **Tiempo** | 15 minutos, 10 de ellos de espera |
| **Qué demuestra** | Un clúster es una línea de un catálogo, no un proyecto de un trimestre |
| **Qué necesitarás** | Acceso al panel del tenant; `kubectl`, `kubelogin` y `git` en tu laptop |

## Por qué esto importa

Más adelante vas a desplegar aplicaciones, romperlas, arreglarlas y escalarlas. Para todo eso necesitas un lugar donde seas el dueño pleno y donde un error no cueste nada.

En vSphere un lugar así te lo asignarían. Aquí lo tomas tú mismo, en diez minutos, y lo eliminas tú mismo con la misma facilidad cuando terminas.

## Mini-glosario

Siete palabras que aparecerán en cada lab de aquí en adelante. La tercera columna nombra aquello de vSphere a lo que el término se parece, y enseguida en qué se diferencia: las analogías de aquí ayudan a entender, pero ninguna coincide del todo, y saber exactamente dónde se rompe una analogía importa más que la analogía misma.

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Clúster de Kubernetes** | Varias máquinas más un programa de gestión que reparte las aplicaciones entre ellas. Le entregas una aplicación y no le dices en qué máquina ejecutarla: lo decide él solo | **Un clúster ESXi**, pero DRS tanto coloca como luego reequilibra continuamente las máquinas virtuales, moviéndolas entre hosts. Aquí la unidad es un contenedor, y su ubicación se elige una vez, al arrancar, y de nuevo cuando un nodo falla; el clúster no reordena por sí solo lo que ya está en marcha |
| **Plano de control** | La capa de gestión del clúster: recibe tus órdenes, almacena el estado deseado y reparte trabajo a los nodos | **vCenter**, pero no es un servidor aparte con interfaz web: es un puñado de procesos; en Cozystack viven en la plataforma, no en tus nodos |
| **Nodo** | La máquina en la que finalmente se ejecutan tus aplicaciones | **Un host ESXi**, pero aquí es una VM, no hardware, y se crea en minutos |
| **Node group** | La descripción de un grupo de nodos idénticos: cuántos y de qué tamaño | **Un clúster de hosts**, pero el grupo puede añadir y quitar nodos por sí mismo según la carga |
| **Kubeconfig** | Un archivo que guarda la dirección del clúster y tu acceso a él. Sin él, `kubectl` no sabe a dónde dirigirse | **La dirección de vCenter junto con una cuenta**, pero esto es un archivo de texto plano en tu disco, no un ajuste dentro de un cliente |
| **Tenant** | Tu porción de la plataforma: tu propia cuota, tus propios permisos, tus propios objetos | **Un resource pool más permisos sobre una carpeta**, pero también es una frontera de visibilidad: un vecino no se asomará a tu tenant |
| **Namespace** | Una sección dentro del clúster donde se colocan los objetos | **Una carpeta en el inventario de vCenter**, pero la separación es más estricta: los objetos de distintos namespace no se encuentran entre sí por nombres cortos |

Los contenedores merecen una palabra propia, porque es la principal diferencia respecto al mundo al que estás acostumbrado. Un contenedor es una aplicación en ejecución junto con todo lo que necesita para funcionar, empaquetado en un único archivo de imagen. Se diferencia de una máquina virtual en que no tiene un sistema operativo propio dentro: un contenedor usa el kernel de la máquina en la que se ejecuta. De ahí la diferencia de escala: una VM tarda un minuto en arrancar y pesa gigabytes, un contenedor arranca en un segundo y pesa decenas de megabytes. Justamente por eso al clúster no le importa reiniciarlos por lotes, que es lo que harás en los labs siguientes.

## Si estás en Windows — lee esto primero

Los comandos de los labs están escritos para la línea de comandos de Linux y macOS. En PowerShell a secas algunos de ellos no funcionarán: PowerShell tiene una sintaxis distinta y un conjunto de comandos distinto.

La solución es **WSL** — un subsistema Linux dentro de Windows. Se instala con un solo comando en PowerShell ejecutado como Administrador:

```powershell
# instala el subsistema Linux dentro de Windows: el kernel, el servicio y la distribución
# Ubuntu por defecto. Tras la instalación Windows te pedirá reiniciar.
wsl --install
```

Tras el reinicio tendrás una consola Ubuntu, y de ahí en adelante trabajas en ella como todos los demás. Dentro de WSL necesitarás un `kubectl` propio — el comando con el que te diriges al clúster:

```bash
# snap es el gestor de paquetes de Ubuntu. --classic instala el paquete sin aislamiento:
# en modo aislado kubectl no verá el archivo de acceso en tu carpeta personal.
sudo snap install kubectl --classic
```

Los discos de Windows son visibles desde WSL bajo la ruta `/mnt/c/...`, así que los archivos descargados con un navegador normal están disponibles también dentro — no hace falta copiarlos a ningún sitio. Esto viene bien un poco más adelante, cuando obtengas el archivo de acceso al clúster: si lo guardas en Windows, desde WSL quedará en una ruta como `/mnt/c/Users/Ivan/Downloads/nombre-de-archivo`.

⚠️ **Si WSL está bloqueado por la política de seguridad** — algo habitual en una laptop corporativa — los labs igual se pueden hacer: todo lo que se hace en el panel es independiente del sistema operativo. Lo único que no podrás ejecutar son los scripts de comprobación y unos pocos pasos compuestos enteramente de comandos. Esos lugares están marcados aparte.

## Qué hay en la carpeta del lab

Todos los archivos ya son tuyos — los tomaste junto con el repositorio. No hay nada que crear ni volver a teclear: allí donde más abajo diga `kubectl apply -f nombre.yaml`, el archivo se toma de aquí.

```bash
# la ruta se cuenta desde la raíz del repositorio — la obtienes en el paso siguiente
cd labs/00-cluster
```

| Archivo | Qué es | Cuándo lo necesitarás |
|---|---|---|
| `cluster.yaml` | Descripción del clúster de laboratorio: versión, nodos, monitoreo | lo aplicas en el clúster de gestión en el primer paso |
| `check.sh` | Una comprobación de que el clúster levantó y te conectaste a él | lo ejecutas al final del lab |

## Paso 0. Obtener los materiales

📍 **Dónde:** en tu laptop.

El repositorio contiene los manifiestos — archivos que describen qué crear en el clúster — y los scripts de comprobación. Los necesitas a partir de este lab:

```bash
# clone = descarga el repositorio completo, junto con su historial de cambios.
# Al lado aparece una carpeta cozystack-migration-workshop; entramos en ella.
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop
```

De aquí en adelante, cada ruta de los labs se cuenta desde esta carpeta.

## Obtener acceso a la plataforma

📍 **Dónde:** en el navegador, luego en tu laptop.

Todo lo que pidas a la plataforma vive en el **clúster de gestión** — el mismo lugar que tu tenant. Para dirigirte a él con comandos necesitas un archivo de acceso. Obtenlo en el panel: la aplicación `Info` → la pestaña `Secrets` → el Secret `kubeconfig-tenant-workshopXX` → `Reveal`. Copia el contenido y guárdalo en tu laptop con el nombre `~/.kube/workshop`.

Esta ruta se usa en todos los labs — si guardas el archivo en otro lugar, de aquí en adelante tendrás que sustituir la tuya cada vez.

```bash
# Comprueba que el archivo se puede leer y que el clúster responde.
# --kubeconfig le dice a kubectl qué archivo de acceso usar en este comando.
kubectl --kubeconfig ~/.kube/workshop get kubernetes.apps.cozystack.io -n tenant-workshopXX
```

**Lo que deberías ver:** o bien una lista vacía, o bien la línea `No resources found` — todavía no has creado ningún clúster. Lo que importa es otra cosa: respondió el clúster mismo, no un mensaje de error.

⚠️ **En la primera llamada se abre un navegador.** El acceso no se otorga con un certificado sino a través de Keycloak — un servidor de inicio de sesión, como el «inicia sesión con tu cuenta corporativa» de los servicios internos. `kubectl` llamará a `kubelogin`, que abre una ventana del navegador, inicias sesión como `workshopXX`, y de ahí en adelante los comandos se ejecutan en silencio hasta que tu pase expire. Si en lugar del navegador viste un error sobre un plugin que falta — `kubelogin` no está instalado, o su archivo no se llama `kubectl-oidc_login`. Cómo instalarlo está escrito al inicio del taller.

⚠️ **Tu número de tenant es el login con el que entras al panel:** `workshop03`, `workshop07` y así sucesivamente. El namespace de tu tenant se compone de la palabra `tenant-` y ese número: `tenant-workshop03`. En todo lo que sigue, donde diga `workshopXX`, sustituye el tuyo.

## Paso 1. Crear el clúster

📍 **Dónde:** en el navegador, en el panel de Cozystack.

Tenant → **Create application** → `Kubernetes`.

Rellena:

| Campo | Valor | Por qué así |
|---|---|---|
| Name | `lab` | corto — tendrás que teclearlo en los comandos |
| Version | deja la que se ofrece | es la última estable |
| Control plane replicas | **1** | por defecto son dos; para un entorno de pruebas de laboratorio basta con una |
| Node group: name | `md0` | este nombre acaba dentro del nombre del nodo — lo verás más tarde en la salida de `kubectl get nodes` |
| Node group: min replicas | **1** | empezamos con un nodo |
| Node group: max replicas | **3** | el techo hasta el que el grupo puede crecer por sí mismo; por defecto es 10, y el lab de escalado está construido sobre ese techo |
| Node group: instance type | `u1.medium` | 1 procesador, 4 GB |
| Node group: disk | `20Gi` | |
| Storage class | `replicated` | los datos quedan en tres copias en nodos distintos |
| Addons → **Monitoring agents** | **activar** | de lo contrario las métricas no se acumularán, y en el lab de gráficas no habrá nada que mirar |

Pulsa crear.

⚠️ **Activa `Monitoring agents` desde el principio.** La recolección de métricas no se puede activar de forma retroactiva: si marcas la casilla una semana después, todo lo que ocurrió antes se pierde para siempre. El lab de gráficas se apoya en datos que se acumulan a partir de hoy.

⚠️ **Si alguien a tu lado está haciendo lo mismo — espacien un par de minutos entre ustedes.** Varias creaciones simultáneas cargan el instalador interno, y ambos clústeres tardarán el triple en levantar. Los labs van a su propio ritmo; no hay por qué apurarse.

### Lo mismo desde la línea de comandos — y el archivo que hay detrás

Esto no es un plan de reserva para cuando el panel esté caído. El botón del panel ensambla exactamente este mismo archivo y lo envía al clúster — es decir, aquí el texto es lo primario, y el ratón es una capa por encima. Trabajar con texto es hacia donde vamos: una descripción que vive en un archivo se puede revisar, poner en Git y revertir, mientras que un clic no.

El archivo está en la carpeta de este lab: **`labs/00-cluster/cluster.yaml`**. No hay nada que abrir ni volver a teclear — ya es tuyo, si tomaste el repositorio al inicio del lab. Aquí está completo, para repasarlo campo por campo.

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Kubernetes
metadata:
  name: lab
  namespace: tenant-workshopXX
spec:
  version: v1.35
  storageClass: replicated
  controlPlane:
    replicas: 1
  addons:
    monitoringAgents:
      enabled: true
  nodeGroups:
    md0:
      minReplicas: 1
      maxReplicas: 3
      instanceType: u1.medium
      diskSize: 20Gi
      storageClass: replicated
```

⚠️ Los comandos de abajo se ejecutan **en el clúster de gestión** — con el acceso que te dieron junto con el tenant. Todavía no existe un archivo de acceso al clúster `lab` en sí: aparece solo después de que el clúster levante.

```bash
# entra en la carpeta del lab — de aquí en adelante todos los archivos se toman de aquí
cd labs/00-cluster
# antes de aplicar, sustituye en el archivo tu propio número de tenant en lugar de XX.
# apply = "lleva el clúster a lo que describe el archivo". El comando no levanta el
# clúster por sí mismo — entrega la orden a la plataforma, que decide qué crear y en
# qué orden.
#   -f   toma la descripción del archivo
kubectl apply -f cluster.yaml
# get = "muestra lo que hay". kubernetes.apps.cozystack.io es el nombre completo del tipo
# de objeto, el mismo descrito en el archivo (kind: Kubernetes), lab es el nombre de tu orden.
#   -n   en qué namespace buscar; sin el flag kubectl mira en el namespace por defecto
#   -w   observa e imprime los cambios. Para salir — Ctrl+C, la instalación no se interrumpe por ello
# Espera hasta que aparezca True en la columna READY.
kubectl -n tenant-workshopXX get kubernetes.apps.cozystack.io lab -w
```

## Paso 2. Esperar, y observar de qué se compone

📍 **Dónde:** en el navegador, en el panel.

El estado pasará a `Ready`, normalmente en cinco a diez minutos.

⚠️ **Si han pasado más de veinte minutos y el estado no cambia — la causa puede no estar en tu clúster.** La instalación de todas las aplicaciones en la plataforma la lleva una cola compartida, y si en ella hay una operación larga de alguien, tu clúster espera su turno. Para ver si lo han tomado para trabajarlo:

```bash
# Mira la orden en sí y lo que la plataforma escribe sobre ella.
# La sección status.conditions al final de la salida es su informe: si la han tomado para
# trabajarla, qué la bloquea, qué está esperando.
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX \
  get kubernetes.apps.cozystack.io lab -o yaml
```

Si tampoco ahí queda nada claro — mira los eventos del tenant. Es un registro de lo que la plataforma hizo con tus objetos:

```bash
# events = un registro de incidencias. Ordenamos por tiempo para que lo más reciente quede abajo.
kubectl --kubeconfig ~/.kube/workshop -n tenant-workshopXX \
  get events --sort-by=.lastTimestamp | tail -20
```

El hallazgo más frecuente aquí es la línea `exceeded quota: tenant-quota`. Significa que al clúster le falta la porción de recursos asignada a tu tenant, y por sí solo no saldrá de ese estado: hay que liberar espacio o ampliar la cuota.

Mientras la instalación transcurre, mira en el panel qué es exactamente lo que aparece en tu tenant.

**El plano de control** se desplegó como varias aplicaciones ordinarias. No hay una máquina aparte que haga de "el vCenter de este clúster": la capa de gestión son procesos que corren junto a todo lo demás.

**Un nodo** — eso sí es una máquina virtual. Una perfectamente ordinaria, igual que las que migras: con su propio disco, su propia memoria y su propia dirección, y vive en tu tenant.

De aquí se sigue algo importante: **Kubernetes aquí no reemplaza a la virtualización — vive encima de ella.** No tienes que elegir entre "corremos VMs" y "corremos contenedores" — funcionan ambos, sobre el mismo hardware y en la misma interfaz.

## Paso 3. Obtener acceso al nuevo clúster

📍 **Dónde:** en tu laptop; el archivo mismo se obtiene con un comando o desde el panel.

**Qué obtenemos.** El kubeconfig del clúster `lab` — un archivo de texto donde están registradas la dirección de su servidor API y tus datos de acceso a él. Sin un archivo así, `kubectl` no sabe a dónde dirigirse ni como quién presentarse. El archivo lo creas tú mismo en tu laptop, con el nombre `~/lab.kubeconfig`; `~` en las rutas es tu carpeta personal: `/Users/nombre` en macOS, `/home/nombre` en Linux y WSL.

⚠️ **Este es un segundo archivo de acceso, no un reemplazo del primero.** El que te dieron junto con el tenant (en los labs está en la ruta `~/.kube/workshop`) lleva al clúster de gestión — allí donde pides aplicaciones y donde acabas de crear `lab`. El nuevo archivo lleva dentro del clúster `lab` en sí. Son dos clústeres distintos con direcciones distintas, y de aquí en adelante necesitas ambos: las órdenes a la plataforma van por el primer archivo, el trabajo dentro de tu propio clúster por el segundo.

**Dónde está.** La plataforma lo puso en el Secret `kubernetes-lab-admin-kubeconfig` en tu tenant. Un Secret es un objeto del clúster donde se guardan contraseñas, claves y archivos de acceso. La clave que necesitas dentro del Secret es `admin.conf`.

⚠️ **Hay cuatro claves en el Secret, y quieres exactamente `admin.conf`.** Al lado está `admin.svc` — lo mismo pero con una dirección interna visible solo desde dentro del clúster; desde tu laptop no te puedes conectar por ella. El par `super-admin.*` otorga derechos que saltan las restricciones configuradas y está pensado para el trabajo posterior a un incidente, no para el uso cotidiano.

**La forma principal — con un comando.** Cozystack configura en tu clúster una regla de acceso aparte que permite leer exactamente este Secret y nada más. El comando se ejecuta **en el clúster de gestión**, con el acceso que te dieron junto con el tenant, y el resultado se pone en un archivo en tu laptop:

```bash
# get secret = muestra el Secret; -o go-template — no lo imprimas entero,
# sino saca de él un campo y muéstralo como texto:
#   index .data "admin.conf"   toma la clave admin.conf del Secret
#   base64decode               el contenido de los Secrets se guarda codificado en base64,
#                              esta función devuelve el texto original
#   > ~/lab.kubeconfig         escribe la salida en un archivo en lugar de la pantalla
kubectl -n tenant-workshopXX get secret kubernetes-lab-admin-kubeconfig \
  -o go-template='{{ printf "%s\n" (index .data "admin.conf" | base64decode) }}' > ~/lab.kubeconfig
```

**Lo mismo con el ratón.** Este mismo Secret se ve en el panel, en la página de la aplicación `lab`, en su lista de secrets — búscalo por el nombre `kubernetes-lab-admin-kubeconfig`. Copia el valor de la clave `admin.conf`, abre cualquier editor de texto, pega lo que copiaste y guarda el archivo con el nombre `lab.kubeconfig` en tu carpeta personal.

## Paso 4. Conectar

📍 **Dónde:** en tu laptop.

**Lo que va a ocurrir ahora:** le decimos a `kubectl` qué archivo de acceso usar, y le pedimos al clúster la lista de sus nodos.

macOS y Linux:

```bash
# KUBECONFIG es la variable de la que kubectl aprende qué archivo de acceso tomar.
# export la hace visible a todos los comandos ejecutados más adelante en esta ventana de terminal.
export KUBECONFIG=~/lab.kubeconfig
# nodes son los nodos del clúster, las mismas máquinas virtuales sobre las que correrán tus aplicaciones.
# La respuesta demuestra además que el archivo de acceso funciona.
kubectl get nodes
```

Windows PowerShell — solo si no pudiste instalar WSL:

```powershell
# en PowerShell las variables de entorno se establecen con $env: y viven hasta que se cierra la ventana
$env:KUBECONFIG="$HOME\lab.kubeconfig"
kubectl get nodes
```

**Lo que deberías ver** — una única línea con tu nodo y el estado `Ready`:

```
NAME                        STATUS   ROLES    AGE   VERSION
kubernetes-lab-md0-xxxxx    Ready    <none>   3m    v1.35.6
```

⚠️ **`TLS handshake timeout` y `context deadline exceeded` son un rechazo del lado del clúster, no un error en el comando.** La parte de gestión de tu clúster corre en una única copia, y cuando la plataforma está bajo carga deja de responder durante unas decenas de segundos. El comando falla, lo repites medio minuto después — y pasa. Si esto ocurrió en medio de un `apply`, repítelo: el comando lleva el clúster al estado descrito en el archivo en lugar de añadir algo nuevo, así que nada se crea dos veces.

⚠️ **La variable `KUBECONFIG` hay que establecerla en cada nueva ventana de terminal.** Si la olvidas, `kubectl` irá a algún otro clúster o dirá que no hay nada a lo que conectarse. Esta es la causa más frecuente de "se me rompió todo" en todos los labs. Si algo se comporta de forma rara — lo primero que hay que comprobar es `echo $KUBECONFIG`.

## La comprobación

📍 **Dónde:** en tu laptop, en la misma ventana de terminal donde estabas trabajando con `kubectl`.

```bash
# el script se ejecuta desde la carpeta del lab: busca los archivos junto a sí mismo
cd labs/00-cluster
# ./ antes del nombre significa "ejecuta el archivo justo desde aquí"; sin ello el shell
# buscará el comando check.sh entre las carpetas del sistema y no lo encontrará
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo instalarlo está escrito al inicio de este lab. Sin WSL el lab se puede completar, pero no habrá artefacto de informe.

El script se asegura de que el clúster responde, los nodos están en orden y hay espacio en ellos para futuras aplicaciones. Junto a él aparece un archivo de informe — lo puedes adjuntar donde sea como prueba de que el lab está hecho.

## Limpieza

Necesitarás el clúster en los labs 1–5 y más allá. No lo elimines ahora.

Cuando termines con todos los labs — elimina la aplicación `lab` a través del panel.

La eliminación en sí toma unos minutos: la plataforma apaga la VM del nodo, retira los componentes de gestión y libera los discos. Si la cola de instalación está ocupada en ese momento con la operación larga de alguien, la espera puede ser mayor — entonces ayuda el mismo truco con la anotación `reconcile.fluxcd.io/requestedAt`, descrito antes en el lab.

Lo que importa es otra cosa: **lo que se libera vuelve a la cuota por completo y por sí solo.** No hay que pedirle nada a nadie ni explicar por qué lo tomaste.

## Qué sabemos hacer ahora

- Levantar un clúster de Kubernetes para nosotros mismos, sin acudir a nadie
- Entender que el plano de control son procesos, y un nodo es una máquina virtual
- Obtener acceso y conectar desde tu laptop
- Saber dónde buscar la causa cuando `kubectl` se comporta de forma rara

## Y en vSphere esto sería

Kubernetes en vSphere es un producto aparte, una licencia aparte y un proyecto de despliegue con el proveedor de por medio. Aquí es una línea de un catálogo y diez minutos.

**Dónde vSphere es más cómodo, con honestidad.** Si todo lo que necesitas son máquinas virtuales y nada más, vCenter te da más herramientas listas para gestionarlas: plantillas, clones, personalización del SO invitado, permisos al nivel de una sola carpeta. Cozystack sabe hacer VMs, pero el ecosistema a su alrededor aquí es más joven. La ganancia aparece allí donde necesitas a la vez VMs y todo lo demás — bases de datos, colas, clústeres, registries — en un solo lugar y a través de una sola API.
