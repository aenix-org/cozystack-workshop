# Laboratorio 1 · Tu primera aplicación

| | |
|---|---|
| **Tiempo** | 25 minutos |
| **Qué demuestra** | Una aplicación se describe con texto, se despliega en segundos, y no le pides permiso a nadie |
| **Qué necesitarás** | El clúster del laboratorio 0, `kubectl`, el archivo `~/lab.kubeconfig` |

## Por qué esto importa

Antes de abordar una tarea real, practiquemos con algo inofensivo. Desplegaremos una aplicación
diminuta que no hace nada salvo una cosa: muestra **el nombre de su propia copia**.

Suena inútil, pero ese mismo nombre es el protagonista de los próximos tres laboratorios. A través
de él verás cómo una copia muere y vuelve a nacer, cómo se multiplican hasta seis, y cómo una
versión antigua cede paso a una nueva.

Lo desplegaremos con texto: un archivo y un comando. En este laboratorio no hay ratón, y hay una
razón para ello: por ahí empezaremos.

## Pequeño glosario

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Pod** | Una copia en ejecución de una aplicación | Una **máquina virtual**, pero el Pod es desechable. No se repara ni se respalda: lo eliminas y se crea uno nuevo |
| **Imagen (image)** | Una instantánea de la aplicación con todo lo necesario para ejecutarse | Una **plantilla de VM**, pero inmutable. No puedes entrar y arreglarla: construyes una nueva |
| **Deployment** | Una descripción: qué imagen, cuántas copias, cómo actualizarlas | Un **vApp**, pero guarda un número deseado de copias en lugar de referencias a VMs concretas |
| **Service** | Una dirección permanente detrás de la cual están las copias | Un **pool de balanceador**, pero el nombre no cambia aunque todas las copias detrás de él se hayan recreado |
| **ConfigMap** | Un archivo de configuración que vive dentro del clúster | Un **archivo en el disco de una VM**, pero vive aparte de la aplicación y se introduce dentro al arrancar |
| **Manifiesto** | Un archivo que describe el estado deseado | No hay analogía directa, y en eso está todo el sentido |

## Qué hay en la carpeta del laboratorio

Ya tienes todos los archivos: los descargaste junto con el repositorio. No hay que crear ni volver
a teclear nada: allí donde más abajo dice `kubectl apply -f name.yaml`, el archivo se toma de aquí.

```bash
# la ruta es relativa a la raíz del repositorio que descargaste en el laboratorio 0
cd labs/01-deploy
```

| Archivo | Qué es | Cuándo lo necesitarás |
|---|---|---|
| `rickroll.yaml` | La aplicación completa: configuración de nginx, el despliegue en sí y el punto de entrada a él | lo aplicas en tu propio clúster `lab` |
| `check.sh` | Una comprobación de que la aplicación responde y devuelve el nombre del Pod | lo ejecutas al final del laboratorio |

## Paso 1. Dónde termina el panel y empieza tu clúster

📍 **Dónde:** en el bastion (en la terminal del bastion).

El panel (dashboard) de Cozystack muestra lo que **pides a la plataforma**: clústeres de Kubernetes,
bases de datos, colas, máquinas virtuales — elementos del catálogo. El clúster `lab` aparece ahí
como un único elemento: pedido y en funcionamiento.

El panel no mira dentro de él, y no puede. Tu clúster es un API server aparte, con su propia
dirección y su propio archivo de acceso —ese mismo `~/lab.kubeconfig`—; el panel de gestión no se
comunica con él. El clúster `lab` tampoco tiene consola gráfica propia: no figura ninguna entre los
complementos que puedes conectarle.

De ahí la frontera de responsabilidad, y conviene recordarla: **la plataforma responde por lo que
pediste, y por lo que hay dentro de lo que pediste, respondes tú.** Dentro del clúster el trabajo va
a través de `kubectl` — el comando que envía descripciones de objetos a su API server y te muestra
lo que hay ahí ahora mismo.

Conectémonos:

```bash
# KUBECONFIG — la variable que kubectl lee para saber qué archivo de acceso usar.
# Aquí es el acceso al clúster lab, no al tenant: archivos distintos, clústeres distintos.
export KUBECONFIG=~/lab.kubeconfig
# get nodes = «muestra los nodos». La respuesta confirma que kubectl se comunica con el sitio correcto.
kubectl get nodes
```

**Lo que deberías ver:** una línea con tu nodo y el estado `Ready`. Si en su lugar obtienes un error
de conexión, revisa `echo $KUBECONFIG`: la variable hay que definirla en cada nueva ventana de
terminal.

## Paso 2. Desplegar la aplicación

📍 **Dónde:** en el bastion (en la terminal del bastion).

Ve a la carpeta de este laboratorio: los materiales están en `~/workshop`:

```bash
cd ~/workshop/labs/01-deploy
```

En la carpeta está `rickroll.yaml`. Antes de aplicarlo, veamos qué contiene.

<details>
<summary><b>Un vistazo más de cerca: qué hay dentro de rickroll.yaml</b></summary>

En el archivo hay cuatro objetos, separados por una línea `---`. Vamos por orden.

### Primero: la configuración del servidor web

```yaml
kind: ConfigMap
metadata:
  name: rickroll-conf
data:
  default.conf: |
    server {
      listen 8080;
      root /usr/share/nginx/html;
      location / {
        sub_filter '__POD__' '$hostname';
        sub_filter_once off;
      }
    }
```

`ConfigMap` es una forma de colocar un archivo de configuración en el clúster, aparte de la
aplicación. Dentro hay una configuración de nginx corriente (nginx es un servidor web, y es el que
servirá nuestra página), la misma que estaría en `/etc/nginx/conf.d/` en el bastion.

La línea clave es `sub_filter '__POD__' '$hostname'`. Le dice a nginx: en la página que sirves,
reemplaza el texto `__POD__` por el nombre de la máquina en la que te ejecutas. Dentro de un Pod, el
nombre de la máquina es el nombre del propio Pod. Así es como la página averigua quién la sirvió.

Por qué la configuración es un objeto aparte y no está incrustada en la imagen: para poder cambiarla
sin reconstruir la imagen. Aprovecharemos esto en el laboratorio sobre el despliegue (rollout) de
versiones.

### Segundo: la página en sí

```yaml
kind: ConfigMap
metadata:
  name: rickroll-page-v1
data:
  index.html: |
    ...<div class="pod">вас обслужил под<b>__POD__</b></div>...
```

Ese mismo `__POD__` que nginx sustituirá. El `-v1` en el nombre no es casual: en el laboratorio sobre
el despliegue de versiones aparecerá un `-v2`, y cambiar entre ellos será el despliegue de la nueva
versión.

### Tercero: la aplicación

```yaml
kind: Deployment
spec:
  replicas: 1
```

`Deployment` es la descripción de la aplicación en su conjunto. `replicas: 1` es cuántas copias
mantener en ejecución. Fíjate en la formulación: no «ejecuta una», sino **«mantén una»**. La
diferencia se nota en el próximo laboratorio, cuando eliminemos la copia.

```yaml
      image: nginxinc/nginx-unprivileged:1.27-alpine
```

La imagen. Hemos tomado la variante sin privilegios de nginx: escucha en el puerto 8080 y no se
ejecuta como root. El nginx corriente exige privilegios que un clúster bien configurado no concede.
No es una manía nuestra: es un requisito de seguridad con el que te toparás en cualquier clúster
moderno.

```yaml
      resources:
        requests: {cpu: 20m, memory: 32Mi}
        limits:   {cpu: 300m, memory: 128Mi}
```

Dos cosas distintas, y constantemente se confunden.

`requests` es cuánto **reservar como garantía**. El planificador usa este número para decidir en qué
nodo cabe el Pod. La analogía más cercana es una reserva en vSphere.

`limits` es el techo por encima del cual **no se le permitirá subir**. La analogía es un límite en
vSphere.

`20m` se lee como «20 mili-CPUs», es decir, dos centésimas de un núcleo. Pedimos poco a propósito: la
aplicación es diminuta, y en el laboratorio sobre escalado un request bajo te permitirá ver crecer
las copias con tus propios ojos.

```yaml
      readinessProbe:
        httpGet: {path: /healthz, port: http}
```

La comprobación de preparación. El clúster llama a esta dirección y no envía tráfico al Pod hasta que
obtiene respuesta. Es precisamente lo que proporcionará la actualización sin interrupciones en el
laboratorio sobre el despliegue de versiones: una nueva copia empieza a recibir solicitudes solo
cuando está de verdad lista para atenderlas.

### Cómo la configuración llega dentro del contenedor

Hemos descrito los dos ConfigMap, pero por sí solos simplemente están en el clúster y nunca llegan a
nginx. Dos bloques los enlazan, y en ellos se apoya todo el truco de este laboratorio:

```yaml
          volumeMounts:
            - name: page
              mountPath: /usr/share/nginx/html
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: page
          configMap:
            name: rickroll-page-v1
        - name: conf
          configMap:
            name: rickroll-conf
```

Se lee de abajo hacia arriba. `volumes` declara: «toma este ConfigMap y conviértelo en una carpeta de
archivos». `volumeMounts` dice: «coloca esa carpeta dentro del contenedor en esta ruta». El resultado
es que `index.html` acaba donde nginx busca las páginas, y `default.conf` donde busca la
configuración.

La analogía más cercana de tu mundo es conectar una carpeta compartida a una máquina virtual. La
diferencia es que el contenido vive en el clúster como un objeto aparte, y puedes cambiarlo sin tocar
ni la imagen ni la propia máquina.

⚠️ **El orden en `volumes` importa.** El laboratorio sobre el despliegue de versiones cambia la
página con un comando que se dirige al volumen **por número** — el primero de la lista. Si
intercambias los bloques, el comando sustituirá silenciosamente la configuración por la página, y
nginx dejará de funcionar. En el propio archivo hay un comentario sobre esto. El enfoque seguro —un
patch-merge por nombre de volumen en lugar de por número— se explica en el laboratorio sobre el
despliegue de versiones.

### Cuarto: la dirección permanente

```yaml
kind: Service
spec:
  selector:
    app: rickroll
  ports:
    - port: 80
      targetPort: http
```

`Service` es un nombre permanente detrás del cual están todas las copias de la aplicación. Te diriges
a `rickroll` y llegas a cualquiera de ellas.

El vínculo entre el Service y los Pods no es una lista de direcciones, sino una **condición**:
`selector: app: rickroll` significa «todos los Pods con la etiqueta `app: rickroll`». Una etiqueta
(label) es un par arbitrario «clave: valor» que cuelgas de un objeto para luego encontrarlo por él;
lo más parecido son los tags en vSphere, solo que aquí las etiquetas no sirven para buscar a ojo,
sino para construir conexiones de trabajo. Aparece un nuevo Pod con esta etiqueta: entra
automáticamente en el balanceo. Desaparece: queda fuera. Nadie edita la lista a mano.

Esta es precisamente la diferencia clave frente a un pool de balanceador, donde las direcciones se
escriben a mano.

</details>

Ahora apliquémoslo:

```bash
# apply = «lleva el clúster a lo que se describe en el archivo». Los cuatro objetos se crean
# con un solo comando; el clúster resuelve por sí mismo el orden dentro del archivo.
#   -f   toma la descripción de un archivo
kubectl apply -f rickroll.yaml
```

**Lo que deberías ver** — cuatro líneas sobre la creación de objetos:

```
configmap/rickroll-conf created
configmap/rickroll-page-v1 created
deployment.apps/rickroll created
service/rickroll created
```

Espera a que la copia arranque:

```bash
# rollout status espera a que el Deployment lleve la tarea hasta el final: el número necesario de copias
# está en ejecución y listo para aceptar solicitudes. El comando termina por sí solo cuando eso ocurre.
kubectl rollout status deployment/rickroll
```

La espera fue cuestión de segundos. Lo que arrancó no fue un sistema operativo, sino un único proceso
dentro de otro ya en marcha: el kernel del nodo se levantó hace mucho y es compartido por todos los
contenedores. Una máquina virtual en el mismo lugar tardaría un minuto o dos en arrancar: tiene que
levantar su propio kernel, sus servicios y su red.

## Paso 3. Mira qué hizo el clúster con el archivo

📍 **Dónde:** en el bastion (en la terminal del bastion).

El clúster no guarda el archivo en sí, sino los objetos que creó a partir de él. Preguntemos cómo se
ve ahora lo que aplicamos:

```bash
# get deployment rickroll = muestra un único objeto por tipo y nombre.
#   -o yaml   imprímelo completo, en la misma forma en que podrías escribirlo a mano
kubectl get deployment rickroll -o yaml
```

La salida es larga: el clúster completó la mayor parte por sí mismo — valores por defecto, campos
internos, el estado actual. Encuentra estas líneas a ojo:

```yaml
spec:
  replicas: 1
  template:
    spec:
      containers:
      - image: nginxinc/nginx-unprivileged:1.27-alpine
```

Esto es lo que escribiste en el archivo. **Dentro del clúster todo se describe con texto** — tanto lo
que aplicas como lo que el clúster te devuelve. Cuando pediste el clúster a través del panel de
Cozystack en el laboratorio 0, este ensambló ese mismo texto y lo envió a la plataforma: el botón es
una capa sobre el texto, no una alternativa a él.

La diferencia está en lo que queda después. Un archivo puedes ponerlo en Git, revisarlo antes de
aplicarlo, consultar quién lo cambió y cuándo, revertirlo con un solo comando, desplegar lo mismo en
un segundo clúster sin tratar de recordar qué casillas marcaste en el primero. Un clic del ratón no
deja rastro: un mes después nadie, tú incluido, recordará por qué estaba puesto justo ese valor.

## Paso 4. Ábrelo en el navegador

📍 **Dónde:** en el bastion (en la terminal del bastion).

**Lo que va a ocurrir:** la aplicación vive dentro del clúster y no es visible desde fuera. El comando
de abajo tiende un túnel desde el bastion hacia dentro.

```bash
# port-forward = un túnel desde el bastion hacia el clúster, vivo mientras el comando se ejecuta.
#   svc/rickroll   lleva el túnel al Service llamado rickroll, que a su vez enruta
#                  la solicitud a una copia viva de la aplicación
#   8080:80        el número de la izquierda es el puerto en el bastion, el de la derecha es el puerto del Service en el clúster
kubectl port-forward svc/rickroll 8080:80
```

El comando no termina: mantiene el túnel abierto hasta que lo detengas. Abre
<http://localhost:8080>.

**Lo que deberías ver:** un título tornasolado, una línea de la canción y, abajo, el nombre del Pod.
Compáralo con lo que muestra el clúster.

📍 **Dónde:** en una segunda ventana de terminal. La primera está ocupada con el túnel: mientras el
comando se ejecuta, no puedes escribir nada en ella. Abre una ventana nueva y define ahí de nuevo el
archivo de acceso: las variables de entorno no se trasladan a una ventana nueva.

```bash
export KUBECONFIG=~/lab.kubeconfig
```

```bash
# get pods = «muestra las copias en ejecución».
#   -l app=rickroll   muestra no todos los Pods, sino solo los que tienen la etiqueta app=rickroll —
#                     la misma que el Service usa para encontrarlos
kubectl get pods -l app=rickroll
```

Los nombres coinciden. Fue exactamente esta copia la que sirvió la página.

Para cerrar el túnel: `Ctrl+C`.

## La comprobación

📍 **Dónde:** en el bastion, en la misma ventana de terminal donde estabas trabajando con `kubectl`.

```bash
# ejecútalo desde la carpeta del laboratorio: el script busca sus archivos junto a sí mismo.
# el ./ antes del nombre significa «ejecuta el archivo desde aquí mismo», no lo busques en las carpetas del sistema
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo configurarlo está escrito
al inicio del laboratorio 0. Sin WSL puedes completar el laboratorio igualmente, pero no habrá
informe-artefacto.

El script comprueba no el hecho de que el manifiesto se aplicó, sino el trabajo en esencia: la
aplicación responde por HTTP, la respuesta contiene un nombre de Pod, y ese nombre coincide con una
copia realmente en ejecución.

## Limpieza

Necesitarás la aplicación en los laboratorios 2, 3 y 4 — no la elimines ahora. Mantenerla es barato:
una copia de nginx pide dos centésimas de un núcleo y 32 megabytes, y cuando llegue el momento de
eliminarla, es un solo comando, y los recursos vuelven al pool compartido del nodo en ese mismo
segundo.

## Qué sabemos hacer ahora

- Distinguir dónde termina el panel de la plataforma y empieza tu propio clúster
- Desplegar una aplicación con un solo archivo y un solo comando
- Leer un manifiesto y explicar para qué sirve cada bloque
- Distinguir `requests` de `limits`
- Entender que un Service encuentra las copias por una etiqueta, no por una lista de direcciones
- Llegar al interior del clúster con un navegador a través de `port-forward`

## Y en vSphere esto sería

Una solicitud de una VM, una solicitud a redes para una dirección, una solicitud a seguridad para un
certificado. Días en el mejor de los casos. Aquí: un archivo y un comando.

**Dónde vSphere es más cómodo, con honestidad.** Cuando despliegas una VM, obtienes una máquina de
pleno derecho: puedes entrar, instalar cualquier cosa, arreglarla en el sitio y dejarla funcionando
así. Un Pod está construido de otra manera: es inmutable, y «entrar y arreglarlo» no tiene sentido
ahí, porque en el siguiente reinicio la edición desaparece. Esto disciplina, pero al principio
irrita, y es una tontería fingir que no es así.
