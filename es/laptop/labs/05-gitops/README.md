# Laboratorio 5 · Infraestructura en Git

| | |
|---|---|
| **Tiempo** | 40 minutos |
| **Qué demuestra** | El clúster se lleva a sí mismo a lo que está escrito en Git, y mantiene ese estado |
| **Qué necesitarás** | El clúster del laboratorio 0, `kubectl`, `git`, una cuenta de GitHub, la CLI `flux` |

## Por qué esto importa

Se acabó la práctica. De aquí en adelante, es una tarea real.

El negocio pide un servicio interno llamado **«Pases»**: un empleado solicita un pase de visitante mediante una aplicación móvil, el personal de seguridad ve la lista en la recepción, y la gerencia revisa un informe una vez al mes. Tú estás en el equipo de plataforma, y sacar esto adelante es tu trabajo.

El servicio tendrá varios equipos detrás, y en el equipo de plataforma son tres. Y aquí empieza la razón por la que este laboratorio va primero en la parte de trabajo.

**Qué pasa cuando hay tres administradores.** Alguien levantó la aplicación desde el panel. Alguien ajustó los límites con `kubectl edit`, porque era mitad de la noche y todo estaba en llamas. Alguien cambió el número de copias el viernes y para el lunes ya se había olvidado. Un mes después, nadie puede responder dos preguntas: **por qué esta configuración es así** y **cómo debería ser**. Y cuando todo se viene abajo, resulta que no hay nada desde donde restaurar: el estado vivía solo en la cabeza del clúster, y desapareció junto con él.

La cura para esto no es una política, ni un «pongámonos de acuerdo en no tocar las cosas a mano». La cura es hacer que tocar las cosas a mano sea **inútil**: el clúster lo volverá a dejar como estaba. Es exactamente eso lo que hoy vamos a activar.

## Pequeño glosario

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Repositorio** | Un conjunto de archivos junto con el historial completo de sus cambios: qué cambió, quién lo cambió y por qué | **Una carpeta de plantillas en una unidad compartida**, pero cada quien tiene su propia copia completa en lugar de una sola compartida por todos |
| **GitOps** | Un enfoque: el estado deseado vive en Git, y un agente que corre en el clúster lo traslada hasta allí | **vRealize Automation con un blueprint**, pero no una aplicación única, sino una reconciliación continua |
| **Flux** | Ese mismo agente. Corre dentro del clúster | **Un agente/script programado**, pero no de «aplicar y olvidar»: revisa cada minuto y corrige cualquier divergencia |
| **Kustomization** | Un objeto en el clúster: qué es exactamente lo que se debe aplicar del repositorio | **Un trabajo de despliegue**, pero no lo confundas con la utilidad `kustomize`: mismo nombre, distinto significado |

El resto de las palabras de este laboratorio —Git, Commit, Rama, Pull request, Reconciliación, Deriva, GitRepository, Prune— se presentan sobre la marcha, en el paso donde se necesitan por primera vez. No hace falta memorizarlas ahora: separadas de la acción, no se quedan.

<details>
<summary><b>Si quieres ver toda la lista de una vez</b></summary>

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Git** | Un almacén de archivos de texto con el historial completo de cambios | **Un archivador de configuraciones + un registro de cambios**, pero no guarda copias de archivos sino cada cambio por separado, con su autor y su motivo |
| **Commit** | Un cambio guardado: qué, quién, por qué | **Una entrada en un registro de cambios**, pero guarda el propio texto modificado, no solo la mención de que hubo un cambio |
| **Rama** | Una línea paralela de cambios | sin analogía directa; la necesitas para preparar un cambio sin tocar la versión de trabajo |
| **Pull request** | Una propuesta para fusionar una rama, que alguien revisa antes de que se aplique | **Aprobar una solicitud**, pero la discusión es sobre líneas concretas de configuración, no sobre la idea general de la solicitud |
| **Reconciliación** | El ciclo: leer el estado deseado → compararlo con el estado real → corregirlo | **La lógica de DRS que atrae el clúster hacia un estado objetivo**, pero lo que se reconcilia no es la ubicación de las máquinas, sino todo lo que se ha descrito |
| **Deriva** | Una divergencia entre el hecho y la descripción | **Un cambio hecho fuera de la plantilla**, pero aquí la deriva no se «anota en un informe de cumplimiento», sino que se elimina en silencio |
| **GitRepository** | Un objeto en el clúster: de dónde tomar el estado | **La configuración de un origen de plantillas**, pero el origen se consulta por sí solo según un calendario, no en el momento en que alguien hace clic en «desplegar» |
| **Prune** | El modo «eliminar del clúster todo lo que desapareció de Git» | sin analogía directa; sin él, borrar un archivo del repositorio no borra nada en el clúster |

</details>

## Qué hay en la carpeta del laboratorio

Todos los archivos ya son tuyos: los tomaste junto con el repositorio. No hay nada que crear ni volver a escribir: allí donde más abajo diga `kubectl apply -f nombre.yaml`, el archivo se toma de aquí.

```bash
# De aquí en adelante, todos los comandos se ejecutan desde esta carpeta: las rutas en `kubectl apply -f` son relativas a ella.
cd labs/05-gitops
```

| Archivo | Qué es | Cuándo resulta útil |
|---|---|---|
| `app/` | Lo que debe terminar en el clúster: el namespace y el propio servicio «Pases» | lo pones en tu propio repositorio de Git |
| `flux/` | Dos descripciones para Flux: de dónde tomar el repositorio y qué aplicar de él | lo aplicas a tu propio clúster `lab` |
| `check.sh` | Una comprobación de que el clúster tomó el cambio de Git por sí solo | lo ejecutas al final del laboratorio |

## Paso 1. Preparar el repositorio

📍 **Dónde:** en el navegador, en GitHub.

Crea un nuevo repositorio:

| Campo | Valor | Por qué |
|---|---|---|
| Nombre | `passes-gitops` | así queda claro que es el estado del servicio, no su código fuente |
| Visibilidad | **Public** | para que Flux pueda alcanzarlo sin claves y no pierdas tiempo en accesos |
| Add a README file | marca la casilla | de lo contrario el repositorio quedará vacío, sin rama, y Flux no encontrará nada que leer |

⚠️ **Un repositorio público aquí es una simplificación deliberada del entorno de pruebas de capacitación.** En producción el repositorio es privado, y Flux lo alcanza mediante una deploy key. Eso son otros veinte minutos de lidiar con claves SSH, y hoy vamos a otra cosa. Lo que vivirá ahí —manifiestos sin una sola contraseña— lo verás por ti mismo: las contraseñas no van a Git, y para ellas hay un laboratorio aparte.

📍 **Dónde:** en la laptop.

Trae el repositorio a tu máquina:

```bash
# clone = descargar el repositorio por completo, junto con todo su historial de cambios. Obtienes
# no el acceso a una carpeta compartida sino tu propia copia completa en disco: puedes trabajar con ella sin conexión.
# Reemplaza `TU-USUARIO` por tu propio usuario de GitHub, o el comando irá al repositorio de otra persona.
git clone https://github.com/TU-USUARIO/passes-gitops.git
# clone crea una carpeta con el nombre del repositorio. De aquí en adelante trabajamos dentro de ella.
cd passes-gitops
```

## Paso 2. Poner el servicio «Pases» en el repositorio

📍 **Dónde:** en la laptop.

En la carpeta de este laboratorio hay dos archivos: `app/namespace.yaml` y `app/passes.yaml`. Cópialos a tu repositorio, a la carpeta `apps`:

```bash
# apps — la carpeta de la que Flux tomará las descripciones. El nombre lo elegimos nosotros, y es exactamente
# el mismo que se indica en la configuración de Flux, así que no hay razón para cambiarlo sin necesidad.
#   -p  no tratarlo como error si la carpeta ya existe
mkdir -p apps
# Copia ambos archivos a tu propio repositorio. Reemplaza `/ruta/a/` por el lugar donde
# clonaste el repositorio de los laboratorios; `*.yaml` tomará ambos archivos de una vez.
cp /ruta/a/labs/05-gitops/app/*.yaml apps/
```

Antes de enviarlos, repasemos qué es lo que estás poniendo.

<details>
<summary><b>Con más detalle: qué hay dentro de namespace.yaml y passes.yaml</b></summary>

### `namespace.yaml` — un namespace propio

```yaml
kind: Namespace
metadata:
  name: passes
```

Un namespace es una partición lógica dentro de un mismo clúster. La analogía más cercana en vSphere es una carpeta en el árbol de vCenter o un resource pool: los mismos recursos, pero un ámbito separado, permisos separados y cuotas separadas.

Por qué ponerlo en Git junto con la aplicación en lugar de crearlo a mano: cuando el servicio algún día salga del repositorio, Flux también eliminará el namespace. No quedará una partición vacía de la que, seis meses después, nadie recuerde por qué se creó.

### `passes.yaml` — el propio servicio

Cuatro objetos, separados por una línea `---`.

**El primero — un `ConfigMap` con la configuración de nginx.** Un `ConfigMap` pone un archivo de texto en el clúster por separado de la aplicación, y luego ese archivo se monta dentro del contenedor. La idea es cambiar la configuración sin reconstruir la imagen.

Dentro hay una configuración de nginx corriente. Una línea merece atención:

```
sub_filter '__POD__' '$hostname';
```

Esto le indica a nginx: en la página que entrega, reemplaza el texto `__POD__` por el nombre de la máquina donde se ejecuta. Dentro de un Pod, el nombre de la máquina es el nombre del propio Pod. Así es como la página informa qué copia la entregó. Más adelante, por ese nombre, verás que ahora hay dos copias.

**El segundo — un `ConfigMap` con la página.** Por ahora es un marcador: la aplicación real aparece en el siguiente laboratorio, y hoy lo que importa no es lo que muestra el servicio sino **de dónde salió** en el clúster.

**El tercero — un `Deployment`.** La descripción de la aplicación: qué imagen, cuántas copias, cómo comprobar que está lista.

```yaml
spec:
  replicas: 1
```

Cuántas copias mantener en ejecución. Fíjate en la formulación: no «arranca una» sino «mantén una». Este es el número que cambiaremos a través de Git para ver qué pasa.

```yaml
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
```

La comprobación de que está lista: el clúster toca esta dirección y no envía tráfico a una copia hasta que recibe respuesta. Flux también la necesita: le pediremos que espere a que esté lista en vez de reportar éxito justo después de aplicar.

**El cuarto — un `Service`.** Un nombre permanente que está delante de todas las copias. El vínculo entre el `Service` y los Pods no es una lista de direcciones sino la condición `selector: app: passes`, es decir, «todos los Pods con esta etiqueta». Apareció una copia nueva con la etiqueta: queda automáticamente bajo el balanceo de carga.

Ninguno de los cuatro objetos contiene una contraseña, una clave ni un token. No es casualidad: todo lo que entra en Git entra para siempre —la historia se puede reescribir, pero todo el que alcanzó a clonarlo conserva la copia vieja. Los Secrets no tienen lugar aquí; para ellos hay un mecanismo aparte y un laboratorio aparte.

</details>

Envíalo a GitHub. Git no recuerda todo indiscriminadamente, sino lo que se le mostró explícitamente, y por eso hay tres comandos, cada uno haciendo lo suyo:

```bash
# add = marcar los archivos que entrarán en la próxima entrada del historial.
git add apps
# commit = guardar lo marcado como una entrada: contenido, autor, hora y motivo.
#   -m "..."  ese mismo motivo. Queda en el historial para siempre, y la gente lo leerá.
# El commit por ahora vive solo en tu laptop, todavía no está en GitHub.
git commit -m "add passes service v1"
# push = enviar los commits acumulados a GitHub. Hasta este comando, allí no cambia nada.
git push
```

**Lo que deberías ver** — en el navegador, en la página del repositorio, la carpeta `apps` con dos archivos. Mientras tanto, en el clúster aún no ha cambiado nada: Git no sabe nada del clúster.

## Paso 3. Instalar Flux en tu clúster

📍 **Dónde:** en la laptop.

Flux son varios servicios dentro de tu clúster. Uno va a Git y descarga el contenido, otro aplica lo descargado al clúster y vigila las divergencias.

El clúster es tuyo, y tú eres su administrador pleno. Lo instalas tú mismo; no hace falta pedírselo al equipo de plataforma.

Primero, la herramienta de línea de comandos `flux`. Vive en tu laptop, no en el clúster: la usarás para instalar los servicios y luego para preguntarles por su estado.

macOS:

```bash
# Homebrew toma la fórmula del repositorio del proyecto Flux y deja un único archivo ejecutable.
brew install fluxcd/tap/flux
```

Linux:

```bash
# El script del sitio de Flux detecta tu arquitectura y deja el archivo en /usr/local/bin.
#   -s          curl trabaja en silencio, sin indicador de descarga
#   | sudo bash el texto descargado se ejecuta de inmediato con permisos de administrador — se
#               necesitan por la escritura en una carpeta del sistema
curl -s https://fluxcd.io/install.sh | sudo bash
```

Windows (PowerShell, si Chocolatey está instalado):

```powershell
# choco — un gestor de paquetes de terceros para Windows; instala el mismo y único archivo flux.exe.
choco install flux
```

Ahora instalamos los propios servicios en el clúster:

```bash
# Fija el archivo de acceso: el comando de abajo crea objetos en el clúster, e importa en cuál.
export KUBECONFIG=~/lab.kubeconfig
# flux install crea en el clúster un namespace `flux-system` y despliega los servicios en él.
#   --components=...  cuáles exactamente instalar:
#     source-controller     va a Git y mantiene una copia fresca del repositorio
#     kustomize-controller  aplica lo descargado al clúster y vigila las divergencias
flux install --components=source-controller,kustomize-controller
```

⚠️ **Comprueba a dónde apunta `KUBECONFIG` antes de pulsar Enter.** Estamos instalando Flux en tu propio clúster `lab`, no en aquel desde el que te lo entregaron. Si tienes dudas, `kubectl get nodes` debería mostrar un nodo con un nombre del tipo `kubernetes-lab-md0-...`.

**Lo que deberías ver** — un listado de lo que se está creando, y al final una línea sobre una instalación exitosa:

```
✔ install finished
```

Instalamos solo dos de los cuatro servicios. El conjunto completo de Flux también sabe desplegar Helm charts y enviar notificaciones a mensajeros — hoy eso no hace falta, y tenemos un solo nodo con no mucha memoria.

Asegúrate de que los servicios se levantaron:

```bash
# -n flux-system — el namespace en el que Flux se instaló. Sin este flag kubectl mira en el
# namespace default y no muestra nada.
kubectl get pods -n flux-system
```

**Lo que deberías ver** — dos líneas en estado `Running`.

<details>
<summary><b>Si no se pudo instalar la CLI <code>flux</code></b></summary>

Lo mismo exactamente se instala con un manifiesto corriente, sin la herramienta:

```bash
# El mismo conjunto de servicios, pero como una descripción ya hecha: -f acepta no solo una ruta en disco
# sino también un enlace. kubectl descargará el archivo y aplicará su contenido.
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
```

La diferencia: así se levantan los cuatro servicios en vez de dos. Eso se notará en la memoria, pero el laboratorio saldrá igual. Más adelante en el texto los comandos `flux ...` solo hacen falta para mirar el estado — se pueden reemplazar por `kubectl get gitrepository` y `kubectl get kustomization`, que muestran lo mismo, solo que de forma menos prolija.

</details>

## Paso 4. Apuntar Flux al repositorio

📍 **Dónde:** en la laptop.

Flux está instalado, pero todavía no sabe a dónde ir. Se lo diremos con dos objetos.

Abre `flux/gitrepository.yaml` de la carpeta de este laboratorio y pon la dirección de **tu** repositorio en lugar del marcador `REEMPLAZAME`:

```yaml
  url: https://github.com/REEMPLAZAME/passes-gitops
```

<details>
<summary><b>Con más detalle: qué hay dentro de gitrepository.yaml y kustomization.yaml</b></summary>

### `GitRepository` — de dónde tomar

```yaml
kind: GitRepository
spec:
  interval: 1m
  url: https://github.com/REEMPLAZAME/passes-gitops
  ref:
    branch: main
```

El único trabajo de este objeto es mantener una copia fresca del repositorio. No aplica nada al clúster, solo descarga.

`interval: 1m` — cada cuánto ir a por actualizaciones. El minuto se eligió para el laboratorio, para no esperar. En producción se suele poner entre uno y cinco minutos, y la reacción instantánea a un push no se logra reduciendo el intervalo sino con un webhook: GitHub mismo toca al clúster cuando algo ha cambiado.

`ref: branch: main` — qué rama tratar como fuente de verdad. Todo lo que se fusione en `main` viajará al clúster. Todo lo que esté en otras ramas, no. De aquí viene la revisión: un cambio primero vive en su propia rama, donde se lo puede mirar, y solo la fusión en `main` lo hace efectivo.

### `Kustomization` — qué aplicar

```yaml
kind: Kustomization
spec:
  interval: 1m
  path: ./apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: passes
  wait: true
```

`path: ./apps` — la carpeta dentro del repositorio. Todo lo que hay en ella viajará al clúster. Los archivos junto a ella —por ejemplo un `README.md` en la raíz— no se tocarán.

`interval: 1m` aquí no significa lo mismo que en `GitRepository`. Allí es «cada cuánto descargar». Aquí es **cada cuánto reconciliar el estado real del clúster con el descrito**. Aunque en Git no haya cambiado nada, una vez por minuto Flux comprueba si el clúster coincide con la descripción y lo pone en línea. Es exactamente en esto en lo que nos vamos a atrapar un poco más adelante en el laboratorio.

`prune: true` — eliminar del clúster los objetos que han desaparecido de Git. Sin esto, Git deja de ser una descripción completa: borras un archivo del repositorio, pero el objeto sigue corriendo en el clúster, y seis meses después nadie entiende de dónde salió. Con `prune`, descripción y realidad coinciden en ambos sentidos.

`wait: true` — no reportar éxito justo después de aplicar, sino esperar hasta que lo aplicado esté listo. La diferencia es exactamente la misma que entre «envié la solicitud» y «la solicitud está hecha».

</details>

Aplica ambos:

```bash
# -f apunta a una carpeta, no a un archivo: se aplicarán todos los manifiestos que hay en ella —
# tanto GitRepository como Kustomization. Ambos se crean en el namespace flux-system.
kubectl apply -f flux/
```

Veamos qué resultó:

```bash
# Le preguntamos a Flux por el estado de la reconciliación.
#   --watch  mantener la ventana ocupada y refrescar la línea a medida que las cosas cambian
# READY: True significa que el contenido del repositorio llegó al clúster y se aplicó.
# REVISION — la rama y el identificador corto del commit aplicado actualmente.
flux get kustomizations --watch
```

**Lo que deberías ver** — tras unas cuantas decenas de segundos, el estado `Ready: True` y el hash del commit que está aplicado:

```
NAME     REVISION            SUSPENDED  READY  MESSAGE
passes   main@sha1:a1b2c3d   False      True   Applied revision: main@sha1:a1b2c3d
```

Detén la observación con `Ctrl+C` y mira qué apareció en el clúster:

```bash
# all — una abreviatura para los principales tipos de objetos a la vez: Pods, Deployment, Service y demás.
# El namespace `passes` no lo creaste a mano: llegó del repositorio junto con la aplicación.
kubectl get all -n passes
```

**No aplicaste nada a mano.** Pusiste texto en GitHub, y el clúster lo tomó por sí solo. La diferencia entre esto y `kubectl apply -f` no es la comodidad — es que ahora hay un único lugar donde está escrito cómo deben ser las cosas.

## Paso 5. El primer cambio a través de `git push`

📍 **Dónde:** en la laptop, en la carpeta del repositorio.

Una sola copia no le basta al servicio «Pases»: la seguridad vigila la lista las 24 horas, y actualizar la aplicación no debería tumbar la recepción. Pongamos dos.

Antes habrías ejecutado `kubectl scale`. Ahora, una edición en el archivo.

Abre `apps/passes.yaml` y cambia:

```yaml
spec:
  replicas: 2
```

Envíalo:

```bash
# Los mismos tres pasos que en el primer envío: marcar el archivo, guardar con un motivo, enviar.
git add apps/passes.yaml
git commit -m "passes: two replicas so the gate does not go dark during rollout"
git push
```

Ahora observa el clúster y espera:

```bash
# -w = «observar y seguir agregando»: la ventana queda ocupada, aparece una nueva línea cada vez
# que cambia el estado de las copias. Sal con Ctrl+C.
kubectl get pods -n passes -w
```

**Lo que deberías ver** — en menos de un minuto aparece una segunda copia. No la creaste tú.

No quieres esperar un minuto — puedes pedirle a Flux que reconcilie ahora mismo:

```bash
# reconcile = «reconcilia ahora mismo, sin esperar al siguiente minuto».
#   kustomization passes  qué objeto reconciliar
#   --with-source         primero ir a Git por el commit fresco y solo entonces aplicar;
#                         sin este flag la reconciliación se hace sobre la copia descargada antes
flux reconcile kustomization passes --with-source
```

Fíjate en el mensaje del commit. `two replicas so the gate does not go dark during rollout` — ese es el motivo. Dentro de seis meses, cuando alguien pregunte «¿por qué aquí hay dos y no una?», la respuesta se encuentra en cinco segundos:

```bash
# log = el historial de commits, los más frescos arriba.
#   --oneline         una línea por commit: un identificador corto y el texto del motivo
#   apps/passes.yaml  mostrar solo los commits que tocaron exactamente este archivo
git log --oneline apps/passes.yaml
```

Ni el panel ni `kubectl` dejan un rastro como este.

## Paso 6. Comprobemos que todo está bajo control

📍 **Dónde:** en la laptop.

Es de noche, un incidente, al servicio le faltan copias. Haces lo que siempre hiciste:

```bash
# Cambia el número de copias directamente en el clúster, sin pasar por Git — como hacías hasta hoy.
#   -n passes  la aplicación vive en este namespace; sin el flag el comando no la encontrará
kubectl scale deployment passes -n passes --replicas=5
```

```
deployment.apps/passes scaled
```

Funcionó. Comprobemos:

```bash
# La columna READY se lee como «listas/pedidas»: cuántas copias responden y cuántas debería haber.
kubectl get deployment passes -n passes
```

Cinco copias. Espera un minuto y mira de nuevo:

```bash
# El mismo comando. La única diferencia es que entre las dos ejecuciones pasó un minuto.
kubectl get deployment passes -n passes
```

**Lo que verás:**

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
passes   2/2     2            2           8m
```

Dos copias otra vez. Tu comando se ejecutó y luego se deshizo.

> **Detente y piensa antes de seguir leyendo.**
>
> ¿Quién lo deshizo? ¿Por qué ocurrió en silencio, sin un solo error en respuesta a tu comando?
> Y lo más importante: ¿es esto una avería que hay que arreglar, o funciona según lo previsto?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

Lo deshizo Flux, y es exactamente para eso que se instaló.

Una vez por minuto el `Kustomization` toma lo que hay en Git y lo compara con lo que hay en el clúster. Git dice `replicas: 2`. El clúster resultó tener `5`. Una divergencia — lo que significa que el clúster está equivocado, porque no es él la fuente de verdad.

**Por qué `kubectl scale` no devolvió un error.** No podía: hizo honestamente exactamente lo que se le pidió. Kubernetes aceptó el cambio, las copias de verdad se levantaron. Un minuto después llegó la reconciliación y restauró el estado descrito. Nadie discutió con nadie — mecanismos distintos trabajaron cada uno según sus propias reglas.

**Por qué esto es una característica, no un error.** Vuelve al dolor con el que empezó el laboratorio: son tres, alguien cambió algo a mano, y nadie sabe qué está puesto dónde. Ahora eso no pasa. Un cambio hecho fuera de Git vive hasta la siguiente reconciliación — es decir, no vive. De esto se siguen tres cosas:

1. **El clúster no se puede desconfigurar en silencio.** No «está mal visto», sino físicamente imposible.
2. **Git siempre describe la realidad.** No «debería describir» — describe, porque la divergencia se elimina sola.
3. **Restaurar el clúster se vuelve un procedimiento aburrido.** Instala Flux, dale el repositorio, espera. Todo lo que había vuelve, porque está todo escrito.

**La lección es más amplia que este error.** Acabas de ver la diferencia entre «aplicar y olvidar» y «reconciliar constantemente». Un `kubectl apply` corriente es un disparo: el estado cambió y luego vive por su cuenta, y cualquiera puede moverlo. La reconciliación no es un disparo sino una tracción: la descripción atrae constantemente la realidad hacia sí.

El mismísimo mecanismo, por cierto, también arregla errores que no son tuyos. Si una falla de nodo elimina un Pod o alguien borra por accidente el `Service` — eso también vuelve.

**Cuándo estorba.** Estorba durante un incidente, cuando de verdad necesitas cambiar algo de inmediato y no hay tiempo para discutir. Para casos así, Flux puede pausarse:

```bash
# suspend = pausar la reconciliación para este objeto. Flux deja de llevar el clúster a la
# descripción, y los cambios manuales empiezan a vivir. El contenido de Git no cambia mientras tanto.
flux suspend kustomization passes
```

Después de esto, la reconciliación no corre, y a mano puedes hacer cualquier cosa. Para revertirlo:

```bash
# resume = volver a activar la reconciliación. La siguiente reconciliación elimina todo lo hecho a mano.
flux resume kustomization passes
```

⚠️ Pausar es una deuda diferida: mientras el `Kustomization` está en pausa, Git otra vez deja de describir la realidad, y estás de vuelta exactamente donde empezaste. Hay una regla: si pausaste, ponte un recordatorio para volver a activarlo.

</details>

## Paso 7. Revertir a través de `git revert`

📍 **Dónde:** en la laptop.

Ahora una situación real. Despliegas un cambio, y resulta ser malo.

Haz una edición: digamos que alguien, sin pensar, aprieta la memoria hasta un valor inoperable. En `apps/passes.yaml`, cambia el límite de memoria:

```yaml
          resources:
            requests:
              cpu: 20m
              memory: 4Mi
            limits:
              cpu: 300m
              memory: 4Mi
```

Envíalo. Un cambio a sabiendas malo recorre el mismo camino que uno bueno: ahora mismo no hay ninguna comprobación entre tu `push` y el clúster — y ese es el punto de este paso.

```bash
# Los mismos add, commit, push. El motivo en el commit está escrito con honestidad — vendrá bien
# en cinco minutos, cuando haya que deshacer el cambio.
git add apps/passes.yaml
git commit -m "passes: trim memory limit"
git push
```

Esperamos y observamos:

```bash
# Observa las copias hasta que la reconciliación traiga la nueva descripción.
kubectl get pods -n passes -w
```

**Lo que deberías ver** — las nuevas copias no se levantan. El estado `OOMKilled` significa que el proceso fue matado por exceder el límite de memoria; `CrashLoopBackOff` significa que el clúster ya reinició la copia varias veces seguidas y ahora espera cada vez más antes del siguiente intento. Nginx no cabe en cuatro megabytes y muere justo después de arrancar.

```bash
# La misma lista, pero como una única instantánea, sin observación continua.
kubectl get pods -n passes
```

```
NAME                      READY   STATUS             RESTARTS   AGE
passes-6c9d4f7b8-2xk4n    1/1     Running            0          12m
passes-7f8a1b2c3-qq7lp    0/1     CrashLoopBackOff   3          90s
```

La copia vieja sigue corriendo — el servicio está vivo, pero la actualización se atascó. Hora de revertir.

**Cómo habrías revertido antes:**

```bash
# undo devolvería el Deployment a la revisión anterior — a la configuración de antes de la edición.
kubectl rollout undo deployment/passes -n passes
```

Este comando funcionará. Las copias volverán a la imagen anterior y a la configuración anterior, y en veinte segundos todo estará bien — justo hasta el momento en que Flux se reconcilie con Git. Y en Git sigue diciendo `memory: 4Mi`. En un minuto el estado roto vuelve.

**No hagas `rollout undo`. Revierte donde vive la verdad** — en Git:

```bash
# revert = agregar un nuevo commit que deshace los cambios del indicado.
#   HEAD       «el último commit de la rama actual» — justo el que tiene el límite malo
#   --no-edit  no abrir un editor para el mensaje del commit; Git escribe el encabezado por sí mismo
git revert --no-edit HEAD
# Hasta que el commit que revierte se envíe a GitHub, Flux no sabe nada de él.
git push
```

**Lo que deberías ver** — un nuevo commit con el encabezado `Revert "passes: trim memory limit"`, y en un minuto de nuevo dos copias funcionando en el clúster.

```bash
# Las copias se levantan de nuevo: volvió el límite de memoria que funciona.
kubectl get pods -n passes
# Y aquí puedes ver qué commit está aplicado ahora — debería coincidir con el que revierte.
flux get kustomizations
```

<details>
<summary><b>En qué se diferencia <code>git revert</code> de «devolverlo como estaba»</b></summary>

`git revert` no borra el commit malo. Agrega un **nuevo** commit que deshace los cambios del malo. Todo queda en el historial: qué se rompió, cuándo se notó, y qué se revirtió.

```bash
# -4 — mostrar los cuatro commits más recientes; el de arriba es el más fresco.
git log --oneline -4
```

```
9f3c1ab Revert "passes: trim memory limit"
5d2b8e0 passes: trim memory limit
c71a4f9 passes: two replicas so the gate does not go dark during rollout
0e5f2d3 add passes service v1
```

Compara esto con cómo se ve sin Git. Un mes después la pregunta «espera, ¿ya tropezamos con esta piedra?» no tiene respuesta: `kubectl rollout undo` no deja rastro, y el historial de revisiones del `Deployment` guarda las últimas diez y muere junto con el objeto.

Aquí tienes cuatro líneas de las que se ve: sí, lo hicimos, aquí está cuándo, aquí quién, aquí qué exactamente hicieron, aquí cuánto vivió antes de la reversión.

**Hay también un segundo comando — `git reset`, que sí borra la historia de verdad.** En un repositorio compartido no se usa: un commit que borraste en tu máquina sigue en las máquinas de dos colegas, y su siguiente `push` lo trae de vuelta. Deshacer en una rama compartida es siempre `revert`.

</details>

## Paso 8. Revisión a través de un pull request

📍 **Dónde:** en el navegador, en GitHub.

La última parte del dolor que estamos curando: un cambio viajaba al clúster de inmediato, y nadie lo miraba. El límite de memoria malo del paso anterior no habría pasado la revisión en diez segundos — pero no hubo revisión.

Crea una rama para el cambio:

```bash
# checkout -b = crear una nueva rama y cambiar a ella de inmediato. Una rama es una línea separada
# de cambios: los commits hechos en ella no llegan a `main`, y por lo tanto tampoco llegan al clúster.
#   passes/version-line  el nombre de la rama; una barra en el nombre está permitida y sirve para agrupar
git checkout -b passes/version-line
```

En `apps/passes.yaml`, cambia la línea de la página — por ejemplo, la versión en el texto de `v1` a `v1.1`. Envía la rama:

```bash
git add apps/passes.yaml
git commit -m "passes: bump the version shown on the page"
# origin — el nombre bajo el que Git recuerda la dirección desde la que clonaste el repositorio.
#   -u origin passes/version-line  crear una rama con el mismo nombre en GitHub y recordar
#                                  el vínculo con ella, para que después baste un `git push` a secas
git push -u origin passes/version-line
```

En respuesta GitHub imprime un enlace para crear un pull request. Ábrelo.

**Mira la pestaña «Files changed».** Esto es lo que es la revisión de infraestructura: no «Pedro dice que arregló los límites», sino líneas concretas — antes y después, resaltadas. Tu colega ve exactamente lo que viajará al clúster y puede dejar un comentario en una línea concreta.

El clúster mientras tanto no ha cambiado, y no cambiará: `GitRepository` mira la rama `main`, y el cambio vive en otra rama.

Haz clic en **Merge pull request** — el cambio aterriza en `main`, y la siguiente reconciliación lo trae al clúster. En un minuto abrimos un túnel y miramos qué entrega el servicio:

```bash
# port-forward = un túnel temporal desde tu laptop hacia dentro del clúster.
#   -n passes     el namespace en el que vive el servicio
#   svc/passes    a dónde llevamos: al Service, no a una copia concreta
#   8080:80       a la izquierda el puerto en tu laptop, a la derecha el puerto del servicio dentro del clúster
kubectl port-forward -n passes svc/passes 8080:80
```

📍 **En el navegador** <http://localhost:8080> — la página dice `v1.1`. Cierra el túnel con `Ctrl+C`.

La ruta completa de un cambio es ahora esta: **rama → pull request → revisión → merge → clúster**. En ningún paso nadie entró al clúster a mano.

<details>
<summary><b>Qué de esto se hace en producción que nosotros no hicimos</b></summary>

Tres cosas que un repositorio de trabajo agrega por encima:

**Protección de ramas.** En la configuración de GitHub la rama `main` se cierra a los push directos, y la única forma de entrar es un pull request con una aprobación. De lo contrario la disciplina descansa en la buena fe, y la buena fe se rompe a las tres de la mañana.

**Comprobaciones antes del merge.** La automatización revisa los manifiestos en busca de errores de sintaxis y de cumplimiento de políticas antes de que viajen al clúster, y no deja fusionar los que están rotos.

**Varios entornos.** Normalmente el repositorio no guarda una sola carpeta sino `apps/staging` y `apps/production`, cada una con su propio `Kustomization` en su propio clúster. Un cambio primero viaja a staging, se asienta, luego a production.

No hicimos esto porque cada cosa es una hora aparte, y la mecánica no cambia por ellas: la fuente de verdad sigue siendo Git, y Flux sigue atrayendo el clúster hacia ella.

</details>

## Verificación

📍 **Dónde:** en la laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

```bash
# Vuelve a la carpeta del laboratorio: el script está ahí, y tú trabajaste en la carpeta de tu propio repositorio.
cd labs/05-gitops
export KUBECONFIG=~/lab.kubeconfig
# El script no cambia nada en el clúster: solo lee el estado e imprime un informe.
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo instalarlo está escrito al inicio del laboratorio 0. Sin WSL igual puedes completar el laboratorio, pero no habrá artefacto de informe.

El script no comprueba el hecho de que Flux esté instalado, sino que el mecanismo funciona: los servicios de Flux están vivos, el origen apunta a tu repositorio y lee de él con éxito, los objetos en el clúster de verdad pertenecen a Flux (en vez de haber sido aplicados a mano), el servicio responde por HTTP, y la reconciliación no está en pausa.

Si quieres que el script también mire el historial de tu repositorio — muéstrale dónde está el clon:

```bash
# LAB_REPO — la variable de la que el script aprende dónde está el clon de tu repositorio.
# Pon tu propia ruta si lo clonaste en un lugar distinto de la carpeta de inicio.
export LAB_REPO=~/passes-gitops
./check.sh
```

Entonces verificará además que el commit aplicado en el clúster coincide con el último de tu rama, y que la reversión se hizo a través de `revert`.

## Limpieza

No borramos nada: el repositorio y Flux harán falta más adelante — los próximos servicios llegarán al clúster de la misma manera.

Cuando termines con todos los laboratorios, puedes quitar todo de una vez así:

```bash
# delete kustomization = quitar el objeto de reconciliación del clúster.
#   --silent  no volver a pedir confirmación
flux delete kustomization passes --silent
```

Gracias a `prune: true`, todo lo que trajo el `Kustomization` se irá junto con él: la aplicación, la configuración, y el propio namespace `passes`. No hay que enumerar nada a mano y nadie olvida un resto — porque Flux guarda para sí la lista de lo que se creó.

Esto, por cierto, es un beneficio aparte de GitOps que no se nota de inmediato. Borrar por completo un servicio es un `git rm` de la carpeta y un `push`.

## Qué sabemos hacer ahora

- Mantener el estado del clúster en Git y entender en qué se diferencia de `kubectl apply`
- Instalar Flux en nuestro clúster y apuntarlo a un repositorio
- Explicar qué es la reconciliación y por qué un cambio hecho fuera de Git no sobrevive
- Revertir a través de `git revert` en vez de a través de `kubectl rollout undo`
- Llevar un cambio de infraestructura a través de un pull request y una revisión

## Y en vSphere esto sería

La analogía más cercana es un blueprint en vRealize Automation: la configuración deseada se describe por separado y se despliega a partir de la descripción. Pero de ahí en adelante los caminos divergen. Un blueprint despliega y suelta; si alguien luego entra a vCenter y cambia la memoria de una máquina, el blueprint no se enterará. Las herramientas de cumplimiento mostrarán la divergencia en un informe — y ya está, un humano va a resolverla.

Aquí la divergencia se resuelve sola, cada minuto, sin informe y sin humano.

La segunda diferencia es sobre la historia. En vCenter hay un registro de tareas: quién hizo qué y cuándo. Responde la pregunta «qué pasó», pero no responde «por qué» ni «cómo debería ser». Git tiene ambas: el texto del cambio, el autor, el motivo en el mensaje del commit, y la discusión en el pull request.

**Dónde vSphere es más cómodo, con honestidad.** Tres cosas.

**La barrera de entrada.** Para cambiar la memoria de una máquina virtual en vCenter, necesitas saber usar vCenter. Para cambiarla aquí, necesitas saber usar Git: ramas, commits, merges, conflictos. Para alguien que no conoce Git, esto no es «más cómodo» — es una nueva profesión, y las primeras dos semanas trabajará más lento de lo que trabajaba.

**Velocidad de reacción.** En una emergencia quieres cambiar el estado ahora, no a través de una rama, una revisión y un minuto de reconciliación. El mecanismo de pausa existe, pero hay que acordarse de usarlo y acordarse de apagarlo.

**Claridad del fallo.** Cuando algo no se despliega en vCenter, se te muestra una tarea con un error. Cuando no se despliega aquí, hay que mirar el estado del `GitRepository`, luego el `Kustomization`, luego los eventos, luego los registros de dos servicios. El diagnóstico está repartido por capas, y eso es honestamente incómodo hasta que te acostumbras.
