# Lab 2 · Autoreparación: matar una copia y ver qué pasa

| | |
|---|---|
| **Tiempo** | 25 minutos |
| **Qué demuestra** | Una copia vuelve por sí sola en segundos, pero eso por sí solo no es tolerancia a fallos |
| **Qué necesitarás** | El clúster del lab 0, `rickroll` del lab 1, `kubectl`, dos ventanas de terminal |

## Por qué esto importa

Pronto tendrás que responder por el servicio «Pase de Entrada»: seguridad revisa la lista de invitados a las siete
de la mañana, y ahí un «estamos reiniciando, un momento» no cuela. Antes de asumir una promesa así,
conviene averiguar —donde nada está en juego— qué hace exactamente el clúster por su cuenta y qué tendrás que hacer tú.

Enfrentémonos a la promesa más ruidosa de Kubernetes: la autoreparación. Vamos a borrar una copia en marcha de la
aplicación y a cronometrar, reloj en mano, cuánto tiempo permanece ausente. Luego borraremos otra cosa —
y veremos que la copia no vuelve. La diferencia entre estos dos casos es de lo que trata este lab.

## Mini-glosario

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Estado deseado** | Un registro en el clúster que dice «debe verse así» | **La configuración del clúster en vCenter**, pero el clúster no la aplica una sola vez: sin descanso ajusta la realidad para que coincida con ella |
| **Controlador** | Un proceso en el plano de control del clúster que compara «lo ordenado» con «lo que hay» | **vSphere HA**, pero funciona de forma constante y sobre todos los objetos, en vez de despertar cuando falla un host |
| **ReplicaSet** | Un objeto que se asegura de que haya exactamente tantas copias como se ordenaron | **Una regla de «mantener N instancias»**, pero no repara lo que está roto: crea una nueva para reemplazar lo que desapareció |
| **ownerReferences** | Una marca dentro de un objeto: «este me creó» | es lo que hace que borrar a un padre se lleve automáticamente a todos sus hijos |
| **Terminación** | La pausa entre «borrar» y «proceso matado» | **Guest Shutdown en vez de Power Off**, pero 30 segundos por defecto, tras los cuales se mata a la fuerza |
| **EndpointSlice** | Una lista de las direcciones vivas que están detrás de un Service | **La lista de miembros de un pool en un balanceador de carga**, pero se construye automáticamente a partir de etiquetas y disponibilidad: no se escribe en ella a mano |

## Qué hay en la carpeta del lab

Ya tienes todos los archivos —los obtuviste junto con el repositorio. No hay nada que crear
ni volver a teclear: donde más abajo diga `kubectl apply -f nombre.yaml`, el archivo se toma de aquí.

```bash
# Todos los comandos del lab se ejecutan desde esta carpeta; de lo contrario, las rutas relativas que contienen no cuadrarán.
cd labs/02-selfheal
```

| Archivo | Qué es | Cuándo sirve |
|---|---|---|
| `check.sh` | Comprueba que el clúster restauró por sí mismo las copias borradas | lo ejecutas al final del lab |
| — | El lab no tiene manifiestos propios: trabajamos con la aplicación del lab 1, y el archivo se toma de ahí — `../01-deploy/rickroll.yaml` | |

## Paso 1. Miramos qué tenemos

📍 **Dónde:** en la laptop.

La aplicación `rickroll` ya está en marcha. Antes de romper nada, veamos de qué objetos
se compone: con un solo comando le preguntamos al clúster por tres tipos de entidad a la vez.

```bash
# KUBECONFIG — la ruta al archivo con la dirección del clúster y tus credenciales de acceso.
# Hasta que la variable no esté definida, kubectl busca un clúster en la propia laptop y no lo encuentra.
export KUBECONFIG=~/lab.kubeconfig

# get = «muéstrame qué hay». Se enumeran tres tipos de objeto a la vez, separados por comas.
#   -l app=rickroll   mostrar solo los etiquetados con app=rickroll, es decir, nuestra
#                     aplicación, y no todo el contenido del clúster
kubectl get deployment,replicaset,pods -l app=rickroll
```

**Lo que deberías ver** — una línea por cada uno de los tres objetos:

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/rickroll   1/1     1            1           14m

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/rickroll-6f4b9c8d57   1         1         1       14m

NAME                             READY   STATUS    AGE
pod/rickroll-6f4b9c8d57-xk2mp    1/1     Running   14m
```

⚠️ **Puede haber más de una línea de `replicaset`.** Cada despliegue (rollout) de una versión nueva deja el
conjunto anterior en el historial —con ceros en las columnas. El vivo es aquel donde están los
unos; el resto se conserva para que haya adónde revertir.

Hay tres objetos, aunque en el manifiesto del lab 1 describiste un único Deployment. Los otros dos los creó el clúster
por su cuenta, y esto no es un detalle cosmético: todo lo que sigue depende de esta cadena.

<details>
<summary><b>Desglosamos la cadena: quién creó a quién y por qué</b></summary>

Mira los nombres. El nombre de un Pod es el nombre del ReplicaSet más cinco caracteres aleatorios, y el nombre del
ReplicaSet es el nombre del Deployment más un hash. Así se construye la cadena.

**Deployment** guarda tu intención por completo: qué imagen, cuántas copias, cómo actualizar. No vigila
los Pods directamente: vigila al ReplicaSet.

**ReplicaSet** guarda un único pensamiento: «debe haber exactamente esta cantidad de Pods con la etiqueta
`app=rickroll`». Eso es todo. No sabe nada de imágenes ni de versiones.

**Un Pod** es una copia en marcha.

Puedes confirmar que esto no es una suposición así:

```bash
# La tabla por defecto de kubectl no muestra el campo ownerReferences: hay que pedirlo explícitamente.
#   -o jsonpath=...   «saca estos campos de la respuesta del servidor e imprímelos así»
# Dentro de la expresión: range .items[*] — recorrer todos los Pods encontrados, .metadata.name —
# el nombre del Pod, ownerReferences[0].kind y .name — el tipo y el nombre de quien lo creó.
kubectl get pods -l app=rickroll -o jsonpath='{range .items[*]}{.metadata.name}{"  <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}'
```

Salida:

```
rickroll-6f4b9c8d57-xk2mp  <- ReplicaSet/rickroll-6f4b9c8d57
```

El campo `ownerReferences` es el registro «este objeto me creó». El ReplicaSet tiene el mismo
registro, solo que ahí apunta al Deployment.

Por qué tres niveles en vez de un solo objeto: cada nivel se encarga de cosas distintas. Cuando en el lab 4 despleguemos
una versión nueva, el Deployment creará un **segundo** ReplicaSet para la nueva versión y
empezará a trasladar copias del conjunto viejo al nuevo, de una en una. El ReplicaSet viejo no irá a
ningún lado mientras tanto: es justamente lo que te permite revertir con un solo comando.

Un dato secundario que vale la pena recordar: borrar a un padre se lleva a sus hijos. Borra el ReplicaSet
a mano y el Deployment crea uno nuevo en un segundo. Borra el Deployment y desaparece todo. El segundo
caso lo comprobaremos al final del lab.

</details>

## Paso 2. Matamos una copia y medimos el tiempo

Ahora borraremos un Pod. No lo apagaremos ni lo reiniciaremos: lo borraremos por completo, como si alguien hubiera
hecho clic en Delete from Disk sobre una máquina virtual.

**Lo que va a pasar:** el comando de abajo recordará el nombre de la copia actual, la borrará y
luego, una vez por segundo, le preguntará al clúster si ha aparecido una copia con un nombre **distinto** en
estado Running. En cuanto aparezca, imprime cuánto tardó.

```bash
# items[0].metadata.name — el nombre del primer Pod de la lista. Lo guardamos en la variable POD:
# sin eso no podremos distinguir luego la copia vieja de la nueva.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')
echo "matando: $POD"

# date +%s — la hora actual en segundos. Es nuestro cronómetro: lo anotamos antes de borrar,
# y al final lo restamos de una nueva lectura.
START=$(date +%s)

# delete pod — borrar la copia para siempre.
#   --wait=false   no esperar a que el Pod desaparezca por completo, devolver el control de inmediato:
#                  hay que empezar a contar los segundos desde este momento, no después
kubectl delete pod "$POD" --wait=false

# Una vez por segundo releemos la lista de Pods y buscamos una línea donde se cumpla todo esto a la vez:
#   $1!=old        el nombre no coincide con el viejo, así que esta es una copia distinta
#   $2=="1/1"      hay un contenedor listo de uno
#   $3=="Running"  el Pod está en marcha
#   --no-headers   no imprimir el encabezado de la tabla, para que awk vea solo datos
#   2>/dev/null    ocultar los mensajes de error durante los segundos en que no hay ningún Pod
while true; do
  NEW=$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null \
        | awk -v old="$POD" '$1!=old && $2=="1/1" && $3=="Running" {print $1; exit}')
  [ -n "$NEW" ] && break
  sleep 1
done
echo "nueva copia $NEW lista en $(( $(date +%s) - START ))s"
```

**Lo que deberías ver:**

```
matando: rickroll-6f4b9c8d57-xk2mp
pod "rickroll-6f4b9c8d57-xk2mp" deleted
nueva copia rickroll-6f4b9c8d57-p9wqt lista en 4s
```

Cuatro segundos. En el entorno de pruebas la variación va de dos a quince, según lo ocupado que esté el
nodo. La imagen ya está en el nodo, no hay nada que descargar, así que todo se reduce a arrancar el
proceso y a la comprobación de disponibilidad.

**Fíjate en el nombre.** La cola cambió: `xk2mp` pasó a `p9wqt`. No es el mismo Pod
reiniciado: es un Pod distinto. El viejo ya no está en ninguna parte; no puedes repararlo, recuperarlo
de una papelera ni ver qué había en su disco.

Nadie «restauró» nada. Varias veces por segundo el ReplicaSet compara «ordenado: 1» con
«hay: 0» y, ante una discrepancia, crea lo que falta. La copia desapareció —surgió una discrepancia—
se creó una copia. El mismo mecanismo se habría disparado si el Pod hubiera sido desalojado del nodo
por una carga de trabajo más importante, si el propio nodo se hubiera caído o si la aplicación dentro del Pod
hubiera muerto por falta de memoria.

## Paso 3. Comprobamos si hubo tolerancia a fallos

La copia volvió en cuatro segundos. ¿Significa eso que el servicio no se interrumpió?

Comprobémoslo. Necesitaremos **dos ventanas de terminal**.

📍 **Ventana 1** — dentro del clúster arrancamos un Pod diminuto que sondea nuestra aplicación a través del Service
una vez por segundo y dibuja un punto si tiene éxito, una `X` si hay error:

```bash
export KUBECONFIG=~/lab.kubeconfig

# run = crear un único Pod directamente desde la línea de comandos, sin manifiesto.
#   --rm             borrar el Pod en cuanto interrumpas el comando
#   -it              la salida del Pod llega a tu pantalla, Ctrl+C lo detiene
#   --restart=Never  hay una sola copia y no hace falta recrearla: esto es una herramienta, no un servicio
#   --image          busybox — una imagen de unos pocos megabytes que trae wget
# Todo lo que va después de -- se ejecuta dentro del Pod. La dirección http://rickroll es el nombre del Service;
# dentro del clúster se convierte por sí sola en la dirección de la aplicación.
#   -q               no imprimir las estadísticas de descarga
#   -T 2             esperar la respuesta no más de dos segundos, de lo contrario lo contamos como fallo
#   -O /dev/null     descartar el cuerpo de la respuesta, solo nos importa el hecho de que haya respuesta
kubectl run pinger --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'while true; do wget -q -T 2 -O /dev/null http://rickroll/healthz \
         && echo "$(date +%T) ." || echo "$(date +%T) X"; sleep 1; done'
```

Cada línea lleva una marca de tiempo: así verás no solo el fallo en sí, sino **cuántos segundos**
duró —y ese es el número que busca todo este lab.

⚠️ **Necesitas una segunda terminal, no una ejecución en segundo plano.** El sentido del ejercicio es ver el
fallo **en el momento** en que borras la copia en la otra ventana: la línea con la cruz debe
aparecer ante tus ojos. Puedes leerlo después en `kubectl logs`, pero entonces se pierde lo
principal: el vínculo entre tu acción y su consecuencia.

Por qué desde dentro del clúster y no desde la laptop: `port-forward` se engancha a un Pod concreto y
muere junto con él, así que mostraría un fallo de todos modos —incluso donde no lo hay.
En cambio, `wget` desde un Pod vecino pasa por el Service, es decir, exactamente como lo haría un cliente real.

Espera hasta que empiecen a correr los puntos.

📍 **Ventana 2** — matamos la copia:

```bash
export KUBECONFIG=~/lab.kubeconfig

# No se da el nombre del Pod, sino una etiqueta: borrar toda copia con la etiqueta app=rickroll.
# Ahora mismo solo hay una, así que la que sondea el pinger es justamente la que se va.
kubectl delete pod -l app=rickroll
```

📍 **Mira la ventana 1.** Verás algo así:

```
.........XXXXX.........
```

Durante unos segundos el servicio respondió con un error —nos salieron cinco, en un nodo ocupado pueden ser
quince. La copia volvió rápido, pero mientras no estuvo no había quien respondiera.

**Esta es la formulación honesta de lo que observamos.** La autoreparación no es tolerancia a fallos.
La autoreparación devuelve el sistema a la normalidad sin intervención humana. La tolerancia a fallos significa que el cliente
no notó absolutamente nada. Una sola copia te da lo primero y no lo segundo.

No detengas el pinger, lo necesitarás enseguida.

## Paso 4. Hacemos lo mismo, pero con tres copias

📍 **Ventana 2.** Pedimos tres copias en vez de una y esperamos a que las tres estén listas.

```bash
# scale cambia exactamente un campo en el registro de la aplicación: la cantidad de copias.
kubectl scale deployment rickroll --replicas=3

# rollout status retiene la terminal e imprime el progreso hasta que todas las copias que pediste
# estén listas. El comando termina solo: no hace falta consultar get pods a mano.
kubectl rollout status deployment/rickroll
```

Cambiamos exactamente un número en el estado deseado. A partir de ahí todo lo hace el mismo ReplicaSet:
ve «ordenado 3, hay 1» y crea las dos copias que faltan. Esto toma los mismos segundos que antes.

Asegúrate de que ahora hay tres copias y de que todas quedaron detrás del Service:

```bash
# EndpointSlice — esa misma lista de direcciones vivas que el Service mantiene por ti.
#   -l kubernetes.io/service-name=rickroll   tomar la lista que pertenece al Service rickroll
#   -o jsonpath=...                          de cada entrada imprimir solo la dirección en sí,
#                                            una por línea
kubectl get endpointslices -l kubernetes.io/service-name=rickroll \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

Tres direcciones. Nadie las metió ahí: el Service armó la lista por sí mismo, a partir de la etiqueta `app=rickroll`
y de la disponibilidad de cada copia. Esta es exactamente la diferencia con el pool de un balanceador de carga de la que
hablaba el lab 1: allí introduces las direcciones, aquí describes una condición.

Ahora matamos una de las tres copias:

```bash
# Tomamos el nombre de la primera de las tres copias; cuál exactamente da igual.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')

# Y la borramos. Aquí sin --wait=false: el comando retorna cuando el Pod ya ha desaparecido.
kubectl delete pod "$POD"
```

📍 **Mira la ventana 1:**

```
...........................
```

Ni una sola `X`. La copia fue eliminada, se recreó, el cliente no lo notó.

La diferencia entre la prueba con una copia y la prueba con tres copias es un único número en el manifiesto. **La tolerancia a fallos aquí no es una
función que se activa, sino una consecuencia de que haya más de una copia.** Justamente por eso en
Kubernetes no hay una casilla de «activar HA»: no hay nada que activar, solo existe `replicas`.

Detén el pinger en la ventana 1 pulsando `Ctrl+C`. Si el Pod se queda colgado, quítalo:
`kubectl delete pod pinger`.

## Paso 5. Una prueba que no va a pasar

El mecanismo está claro: borras una copia y vuelve. Probémoslo una vez más, pero esta vez borrando
no una copia, sino la propia aplicación:

```bash
# Borramos no una copia, sino el propio registro de la aplicación. No habrá confirmación,
# el objeto no irá a ninguna papelera: no habrá de dónde restaurarlo salvo el archivo.
kubectl delete deployment rickroll
```

Esperamos unos segundos y miramos si las copias volvieron:

```bash
# Buscamos pods por la etiqueta de la aplicación. Una respuesta vacía aquí también es una respuesta.
kubectl get pods -l app=rickroll
```

**Lo que verás:**

```
No resources found in default namespace.
```

Las copias no volvieron. Ni a los cinco segundos, ni al cabo de un minuto.

> **Detente y piensa antes de seguir leyendo.**
>
> ¿Por qué antes, cuando matabas la copia, volvía a aparecer, y ahora no? Al fin y al cabo, no apagamos nada.

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

Antes borrabas una **copia** —es decir, un hecho. El registro «debe haber tres copias» seguía en su
sitio, la realidad se apartó de él y el controlador eliminó la divergencia.

Esta vez borraste el **propio registro**. Ya no queda nada de lo que apartarse: el estado deseado es «esta
aplicación no existe», el estado real es «esta aplicación no existe». Coinciden,
y el controlador no tiene nada que hacer. De paso, siguiendo la cadena de `ownerReferences`, el ReplicaSet y los tres
Pods se marcharon junto con el Deployment.

**Una lección más amplia que este error.** La regla que vale la pena llevarse entera del lab:

> Kubernetes te protege de perder un **hecho**, pero no hace nada para protegerte de perder la **intención**.

Toda la autoreparación funciona exactamente mientras esté intacto el registro de cómo deben ser las cosas. Si el
registro se cambia o se borra, el clúster ajustará diligentemente y muy rápido la realidad al
nuevo estado deseado, sea cual sea. No preguntará «¿estás seguro?» ni dejará una papelera.

Hay dos consecuencias prácticas, y ambas son desagradables exactamente una vez.

**Primera: aquí borrar es más silencioso que en vSphere.** Derribar un Deployment es una línea: sin
confirmación, sin ningún «Delete from Disk?» con un icono rojo. No puedes restaurarlo desde el clúster:
un objeto borrado no se guarda en ninguna parte.

**Segunda: la única protección real es mantener la intención fuera del clúster.** Si el manifiesto
vive en Git y la automatización lo lleva al clúster, entonces un borrado accidental se cura porque la automatización
devuelve el objeto desde el repositorio un minuto después. Eso es GitOps, y lo activaremos en el lab 5.
Por ahora, tu `rickroll.yaml` es la única copia de la intención. Menos mal que está en un archivo: puedes
revisarlo, ponerlo en Git y aplicarlo de nuevo.

Por cierto, el eslabón intermedio conviene probarlo por separado y se comporta de otra manera. Restaura la
aplicación (el siguiente paso) y luego intenta borrar el ReplicaSet en vez del Deployment:

```bash
# rs — abreviatura de replicaset; kubectl entiende ambas grafías.
# Borramos el eslabón intermedio, dejando el Deployment en su sitio.
kubectl delete rs -l app=rickroll

# Y miramos de inmediato qué queda: compara el nombre del conjunto con el que tenía antes del borrado.
kubectl get rs -l app=rickroll
```

El conjunto reaparece en un segundo —y **con el mismo nombre**. El hash del nombre se calcula a partir de la plantilla del
Pod, y la plantilla no la tocamos: el mismo nombre significa que el clúster restauró exactamente lo mismo,
en vez de crear algo nuevo. El registro «debe existir esta aplicación» permaneció intacto: de él
se encarga el Deployment, y sobrevivió al borrado del conjunto.

</details>

## Paso 6. Devolvemos la aplicación

Tienes la intención, está en un archivo. Restaurarla es un solo comando:

```bash
# apply = «lleva el clúster a lo que describe el archivo». El objeto no existe: será creado.
#   -f ../01-deploy/rickroll.yaml   el archivo está en la carpeta del lab 1, de ahí la ruta con ../
kubectl apply -f ../01-deploy/rickroll.yaml

# Esperamos a que la copia se levante y quede lista para atender peticiones.
kubectl rollout status deployment/rickroll
```

Fíjate en lo que aquí **no** hubo: ni copia de seguridad, ni instantánea, ni exportación desde vCenter. Restauraste la
aplicación a partir de un archivo de texto de diez kilobytes, y lo que obtuviste fue literalmente lo mismo
que antes. Con una máquina virtual este truco no funciona: su descripción y su contenido son inseparables.

## Verificación

📍 **Dónde:** en la laptop, en la misma ventana de terminal donde estabas trabajando con `kubectl`.

El script comprueba no que ejecutaste los comandos, sino lo que quedó en el clúster: la aplicación
vuelve a atender peticiones a través del Service, inserta en la página el nombre de su copia, y ese nombre
pertenece a un Pod que realmente está en marcha. Por separado busca rastros de la recreación de copias —
a partir de la antigüedad de los Pods y de los eventos del clúster.

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell —cómo instalarlo está escrito al
comienzo del lab 0. Puedes completar el lab sin WSL, pero no habrá informe-artefacto.

```bash
# ./ significa «un archivo de la carpeta actual», no un comando del PATH del sistema.
# El script no cambia nada en el clúster: solo lee e imprime un informe.
./check.sh
```

## Limpieza

La aplicación `rickroll` hace falta en los labs 3 y 4: no la borramos.

Aquí no hay nada que limpiar, y eso vale la pena señalarlo por sí solo. Restauraste la aplicación a partir del archivo,
y el archivo ordena una copia: las dos de más las apagó el clúster por su cuenta, ya en el paso anterior, sin
preguntar y sin esperar tu orden. Para confirmarlo:

```bash
# La columna READY debe indicar 1/1.
kubectl get deployment rickroll
```

Los recursos del nodo se liberaron en el mismo momento en que terminaron los contenedores. Aquí no hay ninguna
«desfragmentación» ni recuperación de espacio programada: un contenedor terminó y su memoria y su tiempo de CPU
quedan de inmediato a disposición de sus vecinos.

## Qué sabemos hacer ahora

- Explicar la cadena Deployment → ReplicaSet → Pod y entender por qué tiene tres niveles
- Distinguir la autoreparación (la copia volvió) de la tolerancia a fallos (el cliente no lo notó)
- Cambiar la cantidad de copias con un solo número y ver cómo el Service las incorpora por sí mismo
- Entender que el clúster protege un hecho pero no la intención, y dónde va la intención

## Y en vSphere esto sería

vSphere HA reinicia una VM tras el fallo de un host: primero el clúster tiene que asegurarse de que el host realmente
está perdido (eso son decenas de segundos), luego la máquina arranca desde cero —
kernel, servicios, aplicación. Minutos. VM Monitoring basado en la pérdida de heartbeats funciona de la misma
manera y en el mismo orden de tiempo.

Aquí son segundos, y no solo ante el fallo de un host: el mismo mecanismo se dispara cuando una copia es
desalojada, cuando la mata OOM, cuando la borras tú mismo.

**Dónde vSphere es más cómodo, con honestidad.** Tres cosas.

Primero, vSphere HA devuelve **la misma máquina exacta** con todo lo que había en su disco. Un Pod
vuelve vacío: todo lo que no estuviera en un volumen persistente se pierde para siempre. Para una aplicación
sin estado eso es una ventaja; para un servicio legacy que durante años escribió algo en su propio
`/var`, es una fuente de sorpresas muy desagradables.

Segundo, vSphere tiene Fault Tolerance: dos máquinas en lock-step y cero tiempo de inactividad ante el
fallo de un host, sin ninguna modificación de la aplicación. En Kubernetes no hay un análogo directo, y no
puede haberlo: aquí el cero tiempo de inactividad se logra teniendo varias copias, lo que significa que la aplicación debe
poder funcionar en varias copias. Si no puede, Kubernetes no te resolverá ese problema, sino que lo dejará al descubierto.

Tercero, el análisis post-mortem. En vCenter el motivo por el que se reinició una máquina se ve como una única entrada en los
eventos del clúster, y ahí se queda. En Kubernetes los eventos viven alrededor de una hora y luego
desaparecen, y tendrás que reconstruir el cuadro a partir de los registros de varios componentes. Hasta que no hayas configurado
la recolección de registros y eventos (lab 14), «por qué se reinició durante la noche» es una pregunta sin respuesta.
