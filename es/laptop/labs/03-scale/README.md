# Lab 3 · Carga y autoescalado

| | |
|---|---|
| **Tiempo** | 30 minutos |
| **Qué demuestra** | El número de réplicas lo puede determinar la carga, no un ticket al service-desk |
| **Qué necesitarás** | El clúster del lab 0, `rickroll` del lab 1, tres ventanas de terminal, un navegador |

## Por qué importa

El servicio «Pase de acceso», la razón misma de este ejercicio, se comportará de forma irregular. A las ocho de la mañana seguridad y media oficina lo abren a la vez; a las tres de la tarde nadie lo toca. Dimensionar la capacidad para el pico significa calentar el aire nueve horas al día, y dimensionarla para el promedio significa una cola en la entrada.

Probemos la tercera opción a ver qué tal: el número de réplicas no lo fija una persona, sino la propia carga. Le daremos a la aplicación tráfico real y veremos cómo crece hasta seis réplicas y luego se encoge de vuelta a una.

De paso resolveremos aquello con lo que más suele tropezar la gente aquí: la diferencia entre «cuánto pedimos» y «cuánto permitimos».

## Mini-glosario

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **HPA** | Un objeto que cambia el número de réplicas según una métrica | **DRS más agregar VMs a mano**, pero cambia el número de instancias en vez de repartirlas entre hosts |
| **metrics-server** | Un servicio que recopila el consumo actual de los Pods | **la recopilación de estadísticas de vCenter**, pero solo guarda los últimos minutos, sin historial alguno |
| **requests** | Cuánto de un recurso reservamos como garantizado | **una Reservation**, pero el porcentaje de utilización se calcula a partir de él, y es también lo que decide dónde cabe un Pod |
| **limits** | El techo por encima del cual un Pod no puede subir | **un Limit**, pero en el techo la CPU se estrangula (throttling) mientras que la memoria mata al Pod |
| **Utilization** | El consumo como porcentaje de `requests` | **el «CPU Usage %» del gráfico**, pero puede ser 600% y eso no es un error |
| **Fortio** | Un generador de carga con interfaz web | **HCIBench**, pero vive dentro del clúster como una aplicación cualquiera |

## Qué hay en la carpeta del lab

Ya tienes todos los archivos: los obtuviste junto con el repositorio. No hay nada que crear ni reescribir: donde más abajo veas `kubectl apply -f name.yaml`, el archivo viene de aquí.

```bash
# Cada comando de este lab se ejecuta desde esta carpeta; de lo contrario, no se encontrarán los nombres de archivo que contienen.
cd labs/03-scale
```

| Archivo | Qué es | Cuándo sirve |
|---|---|---|
| `hpa.yaml` | La regla de autoescalado: hacer crecer las réplicas según la carga de CPU | lo aplicas en tu propio clúster `lab` |
| `fortio.yaml` | Un generador de carga con interfaz web — esto es lo que impulsa la carga | lo aplicas en el mismo lugar |
| `check.sh` | Verifica que las réplicas crecieron bajo carga y se encogieron después | lo ejecutas al final del lab |

## Paso 1. Confirmar que empezamos con una sola réplica

📍 **Dónde:** en la laptop.

Todo el lab se apoya en que el número de réplicas crezca de forma notable. Así que hay que empezar desde una; de lo contrario, no habrá con qué comparar el crecimiento. Veamos cuántas réplicas hay ejecutándose ahora mismo.

```bash
# KUBECONFIG es la ruta al archivo con la dirección del clúster y los datos de acceso.
# Hasta que la variable no esté definida, kubectl busca el clúster en la propia laptop y no lo encuentra.
export KUBECONFIG=~/lab.kubeconfig

# La columna READY se lee como «listas / solicitadas»: 1/1 significa una réplica solicitada y en ejecución.
kubectl get deployment rickroll
```

Debería decir `1/1`. Si es más, vuelve a dejarlo en una, de lo contrario el crecimiento no será tan visible:

```bash
# scale cambia exactamente un campo en el registro de la aplicación: el número de réplicas.
# El clúster retirará las réplicas de más por su cuenta, en cuestión de segundos.
kubectl scale deployment rickroll --replicas=1
```

## Paso 2. Leer qué pide la aplicación

Antes de configurar el autoescalado, hay que entender contra qué calculará los porcentajes.

```bash
# Un objeto en el clúster tiene cientos de campos; la tabla no los muestra. jsonpath extrae
# exactamente un punto de la respuesta. Lee la ruta de arriba abajo: spec.template es la plantilla
# a partir de la cual se crean las réplicas, containers[0] es el primer contenedor en ella, resources es su
# request y su techo para CPU y memoria. La cola {"\n"} es un salto de línea, para que la respuesta
# no choque con el siguiente prompt de la línea de comandos.
kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

```json
{"limits":{"cpu":"300m","memory":"128Mi"},"requests":{"cpu":"20m","memory":"32Mi"}}
```

Dos pares de números, y se confunden constantemente. Repasémoslo con la CPU.

**`requests: cpu: 20m`** — «veinte millicpu», es decir, dos centésimas de un núcleo. Esto es el request: la cantidad que el clúster se compromete a mantener detrás del Pod en todo momento. El scheduler usa este número para decidir si el Pod cabe en un nodo: la suma de los requests de todos los Pods de un nodo no puede superar la capacidad del nodo. El análogo más cercano es una reservation en vSphere.

**`limits: cpu: 300m`** — el techo. Al Pod no se le darán más de tres décimas de núcleo, aunque el nodo esté ocioso. El análogo es un limit en vSphere.

Entre ambos hay una diferencia de quince veces, y es deliberada: un Pod puede tomar mucho cuando la CPU está libre, pero solo se le garantiza poco.

⚠️ **La CPU y la memoria se comportan de forma distinta al toparse con su limit, y esto importa más de lo que parece.** Al topar con el limit de CPU, la aplicación simplemente empieza a ir más lenta (throttling). Al topar con el limit de memoria, el kernel mata al contenedor: ves el estado `OOMKilled` y el Pod se recrea. Lo primero es molesto; lo segundo es una caída. En vSphere la memoria tampoco se puede exceder, pero allí el invitado obtiene swap y se degrada en vez de morir.

**Y ahora lo clave para este lab.** El HPA calcula la carga no a partir del limit, ni de la capacidad del nodo, ni de cuántos núcleos ve la aplicación dentro de sí. La calcula **a partir de `requests`**. Un umbral del 50% con `requests: 20m` significa 10 millicpu por réplica.

De aquí se deriva lo que más a menudo impide que el autoescalado funcione a quienes lo configuran por primera vez: **si un contenedor no tiene `requests.cpu` especificado, no hay contra qué calcular, y el HPA no funcionará en absoluto.** No lanzará un error: seguirá mostrando en silencio `<unknown>`.

## Paso 3. Encender el autoescalado

El archivo `hpa.yaml` está en la carpeta. Repasémoslo y luego lo aplicamos.

<details>
<summary><b>Un vistazo más de cerca: qué hay dentro de hpa.yaml</b></summary>

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rickroll
```

`autoscaling/v2` no es decoración. En la vieja `v1` solo podías fijar un objetivo de CPU y no podías controlar la velocidad de crecimiento. Todo lo que va por debajo del bloque `metrics` no está disponible en `v1`. Si ves un ejemplo en internet con `autoscaling/v1`, no está desactualizado de forma fatal, pero no cubrirá la mitad de lo que necesitas.

```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rickroll
```

A quién vigilamos y a quién movemos. El HPA no gestiona los Pods directamente: cambia el campo `replicas` en el Deployment, y de ahí en adelante funciona la misma cadena que en el lab de autoreparación: el Deployment pasa el número al ReplicaSet, y el ReplicaSet crea las réplicas que faltan.

De esto se deriva una regla práctica: **mientras el HPA exista, cambiar `replicas` a mano no tiene sentido.** Pones tres, y quince segundos después el HPA pone el suyo. Dos mecanismos sobre un mismo campo son siempre una discusión, y el HPA la gana.

```yaml
  minReplicas: 1
  maxReplicas: 6
```

Un corredor. El límite inferior protege contra el «no hay carga, apaguemos todo»: el HPA no puede bajar hasta cero. El límite superior protege el presupuesto y el nodo: sin él, un pico repentino (o un bug en la aplicación que se coma la CPU) multiplicaría las réplicas hasta que a los nodos se les acabe el espacio.

Se eligió seis para el nodo de entrenamiento `u1.medium`. Seis réplicas a 20m de request cada una son 120m: el nodo lo aguanta con facilidad.

```yaml
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

La regla: mantener la carga **promedio** de todas las réplicas al 50% de sus `requests`, es decir, 10m por réplica.

La palabra «promedio» es clave aquí, y toda la aritmética depende de ella. El HPA calcula así:

```
réplicas necesarias = ceil( réplicas actuales × carga actual ÷ carga objetivo )
```

Una réplica al 645% de carga con un objetivo del 50% da `ceil(1 × 645 / 50) = 13`. Trece es más que seis, así que el HPA topará con `maxReplicas`.

Por qué el objetivo es 50 y no 80: al 80% el crecimiento empieza solo cuando la aplicación ya está en apuros. La mitad deja margen para el tiempo que tardan en levantarse las nuevas réplicas. Para servicios reales este número se ajusta según cuántos segundos tarda el arranque.

```yaml
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 2
          periodSeconds: 15
```

La velocidad de crecimiento. Por defecto, antes de escalar hacia arriba, Kubernetes mira el historial de la métrica durante una ventana para no reaccionar de golpe ante un pico casual. En un lab eso se ve como «no pasa nada», así que la ventana se pone en cero: reaccionamos a la primera medición.

`Pods: 2 / 15s` — agregar no más de dos réplicas cada quince segundos. Por eso el camino hacia arriba será por escalones: 1 → 3 → 5 → 6.

⚠️ **Al especificar `policies`, reemplazas las estándar en vez de sumarte a ellas.** La política de crecimiento estándar (duplicar cada 15 segundos) ya no aplica aquí.

```yaml
    scaleDown:
      stabilizationWindowSeconds: 60
```

Hacia abajo, en cambio, viene con un retraso. El HPA mira el máximo de los recuentos solicitados durante el último minuto y reduce el número de réplicas solo si la carga fue baja durante todo ese intervalo. De lo contrario, en cada pausa entre picos, las réplicas empezarían a desaparecer y reaparecer.

El valor estándar aquí es de **300 segundos**, cinco minutos. Lo recortamos a un minuto para que te dé tiempo a ver el regreso dentro del lab. En producción cinco minutos es más sensato.

</details>

Aplícalo:

```bash
# apply = «lleva el clúster a lo que describe el archivo». El objeto HPA aparecerá de inmediato,
# pero no empezará a calcular enseguida — con eso tropezaremos en el siguiente paso.
kubectl apply -f hpa.yaml
```

## Paso 4. La comprobación que no pasará

Veamos qué obtuvimos:

```bash
# hpa es la forma abreviada de horizontalpodautoscaler; kubectl entiende ambas escrituras.
# La columna TARGETS se lee como «carga actual / objetivo», REPLICAS es cuántas
# réplicas se solicitan ahora mismo.
kubectl get hpa rickroll
```

**Lo que verás:**

```
NAME       REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: <unknown>/50%   1         6         1          10s
```

En la columna `TARGETS`, en lugar de la carga, aparece `<unknown>`. El autoescalado no sabe cuánta CPU consume la aplicación, y por tanto no tiene sobre qué basar una decisión.

⚠️ **O quizá veas un porcentaje de inmediato** — por ejemplo, `cpu: 5%/50%`. Eso no significa que en tu caso algo sea distinto: el recopilador de métricas de tu clúster ya lleva un rato funcionando y ha tenido tiempo de sondear los Pods. `<unknown>` aparece en un clúster recién levantado. Si obtienes un número enseguida, lee de todas formas el desglose de abajo, porque un día te toparás con la causa de `<unknown>`, y es mejor aprenderla de antemano que en el momento en que te estorbe.

> **Detente y piensa antes de seguir leyendo.**
>
> El manifiesto se aplicó sin errores, el objeto está creado, el contenedor tiene `requests` — acabamos de mirarlo. Así que no es que falte algo en la descripción.
>
> Pista: ¿de dónde aprende el autoescalado la carga actual, para empezar? Alguien tiene que reportarle ese número, y ese alguien sondea los Pods no de forma continua, sino una vez cada varias decenas de segundos.

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

No hay tiempo suficiente. Espera un minuto y medio o dos minutos y mira de nuevo:

```bash
# El mismo comando que arriba. Miramos la misma columna TARGETS.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 0%/50%     1         6         1          2m
```

**Esto no es una avería y aquí no hay nada que arreglar.** La carga de los Pods la recopila un servicio aparte, `metrics-server`. Sondea los nodos aproximadamente una vez cada quince segundos y promedia el resultado sobre una ventana corta. Hasta que no tiene dos mediciones seguidas, no tiene nada que entregar, y el HPA escribe honestamente «no lo sé».

Puedes comprobar que las métricas están fluyendo directamente:

```bash
# top = «cuántos recursos están comiendo estos Pods ahora mismo». Los números vienen del
# mismo metrics-server que alimenta al autoescalado: si top responde, entonces la
# fuente de datos está viva y es solo cuestión de tiempo.
kubectl top pods -l app=rickroll
```

```
NAME                        CPU(cores)   MEMORY(bytes)
rickroll-6f4b9c8d57-p9wqt   1m           4Mi
```

Si al cabo de cinco minutos sigue en `<unknown>` y `kubectl top` responde `error: Metrics API not available`, entonces sí es una avería de verdad, y la causa es una de dos: `metrics-server` no está instalado en el clúster, o el contenedor no tiene `requests.cpu` definido (en cuyo caso `kubectl top` funciona pero el HPA sigue sin poder calcular — no hay de qué tomar el porcentaje).

`metrics-server` se instala en el clúster junto con él: no necesitas habilitarlo por separado. Vive en el namespace `cozy-monitoring`, y puedes comprobarlo así:

```bash
# -n = en qué namespace buscar. Un namespace es una sección del clúster;
# por defecto kubectl mira en default y ahí no ve los Pods del sistema.
# deploy es la forma abreviada de deployment.
kubectl -n cozy-monitoring get deploy metrics-server
```

No lo confundas con la casilla **Monitoring agents** del lab 0: esa se encarga de recopilar las métricas hacia el almacenamiento y de los gráficos (el lab de observabilidad), mientras que `metrics-server` se encarga de los números actuales para `kubectl top` y el autoescalado. Mecanismos distintos, y viven de forma independiente.

La causa exacta te la dirá:

```bash
# describe = la ficha completa del objeto: todos los campos, eventos y condiciones,
# a diferencia de get, que imprime unas pocas columnas de tabla.
kubectl describe hpa rickroll
```

Justo al final, en `Conditions`, habrá una línea `ScalingActive` con una explicación en lenguaje humano.

**Una lección más amplia que este error.** En Kubernetes «aplicado» y «funcionando» están separados en el tiempo. El comando `apply` solo registra tu intención en el clúster. De ahí la recogen los controladores, y cada uno tiene su propio ritmo: el HPA recalcula una vez cada quince segundos, las métricas se retrasan un minuto, el recolector de basura pasa una vez cada varios minutos. La costumbre de vCenter — «el diálogo se cerró, así que está hecho» — aquí te falla. Lo que debes mirar no es el código de retorno del comando, sino el `status` del objeto.

</details>

## Paso 5. Levantar el generador de carga

Cargar la aplicación desde la laptop a través de `port-forward` no tiene sentido: el cuello de botella pasa a ser tu internet doméstico y el propio túnel, no la aplicación. El generador tiene que estar dentro del clúster, junto al objetivo.

El archivo `fortio.yaml` está en la carpeta.

<details>
<summary><b>Un vistazo más de cerca: qué hay dentro de fortio.yaml</b></summary>

```yaml
kind: Deployment
metadata:
  name: fortio
```

Fortio es una aplicación cualquiera en el clúster, desplegada con el mismo Deployment que todo lo demás. Aquí no hay ninguna «infraestructura de pruebas» especial, y eso ya de por sí es revelador.

```yaml
        - name: fortio
          image: fortio/fortio:latest
          args: ["server"]
```

La imagen de Fortio puede ejecutarse en dos modos. `fortio load ...` es una ejecución puntual desde la línea de comandos. `fortio server` es un servicio que corre de forma continua con una interfaz web, donde arrancas la carga con un botón y ves el resultado allí mismo como un gráfico. Tomamos el segundo: en un taller, mirar un histograma de latencia en el navegador es más claro que leer una columna de números en la terminal.

⚠️ **El tag `latest` en un manifiesto es algo que no deberías hacer en producción.** Hoy es una imagen, dentro de un mes otra, y no podrás reproducir tu propia prueba. Para un generador de entrenamiento es tolerable; para cualquier otra cosa, no.

```yaml
          ports:
            - containerPort: 8080
              name: http
```

La interfaz web de Fortio escucha en el 8080 y vive en la ruta `/fortio/`. El nombre `http` se necesitará más abajo, en el Service.

```yaml
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: "1"
              memory: 256Mi
```

Fíjate: al generador se le asigna más que al objetivo. Un request de 100m frente a los 20m de `rickroll`, un techo de un núcleo entero frente a 300m.

Esto no es generosidad, es una condición obligatoria para una prueba correcta. Si al generador le falta CPU, topará con su propio techo, y estarás midiendo a Fortio, no a la aplicación. El síntoma de este error es reconocible: las latencias suben mientras la carga del objetivo se queda quieta.

```yaml
kind: Service
metadata:
  name: fortio
spec:
  ports:
    - port: 8080
      targetPort: http
```

Una dirección estable para la interfaz web. Desde dentro del clúster ahora es alcanzable como `http://fortio:8080/`, y desde fuera vía `port-forward`, que es lo que haremos a continuación.

</details>

Aplica y espera:

```bash
# En el archivo hay dos objetos a la vez: el Deployment con el generador y un Service — una
# dirección estable para su interfaz web.
kubectl apply -f fortio.yaml

# rollout status retiene la terminal e imprime el progreso hasta que la réplica esté lista.
# Esperamos aquí a propósito: hasta que el generador no esté levantado, no hay con qué impulsar la carga.
kubectl rollout status deployment/fortio
```

## Paso 6. Abrir Fortio en el navegador

📍 **Ventana 1** — el túnel hacia Fortio. Se eligió el puerto `8081` para no chocar con el `8080` si todavía tienes abierto el túnel hacia `rickroll` del lab 1:

```bash
export KUBECONFIG=~/lab.kubeconfig

# port-forward levanta un túnel desde tu laptop hacia el interior del clúster.
#   svc/fortio    a qué nos conectamos: el Service llamado fortio
#   8081:8080     se lee como «puerto de tu lado : puerto en el clúster» — una petición
#                 a localhost:8081 va al puerto 8080 de este Service
kubectl port-forward svc/fortio 8081:8080
```

El comando no termina: mantiene el túnel abierto. Mientras se ejecuta, abre <http://localhost:8081/fortio/>.

⚠️ **La barra final en la ruta es obligatoria.** En `http://localhost:8081/fortio` sin ella, Fortio responde 404, y parece como si no hubiera arrancado.

## Paso 7. Preparar una segunda ventana para observar el crecimiento

Lo importante del lab no son los números del informe de Fortio, sino lo que le pasa a las réplicas. Necesitas ver esto al mismo tiempo que la carga, no después de ella.

📍 **Ventana 2** — déjala abierta hasta el final del lab.

Observaremos con la opción `-w` (watch). Significa no «refrescar la pantalla», sino «imprimir una línea nueva en cada cambio». La salida sale como un registro de eventos en vez de una tabla. Esta es una diferencia importante frente a `watch kubectl get pods`, donde ves solo la instantánea del «ahora» y fácilmente te pierdes los estados intermedios.

```bash
export KUBECONFIG=~/lab.kubeconfig

# Observamos las réplicas de rickroll: cada línea nueva es un cambio de estado de una de ellas.
# El comando no termina; para salir, Ctrl+C — esto no afecta en nada a las réplicas en sí.
kubectl get pods -l app=rickroll -w
```

Si tienes una tercera ventana, pon esto también en ella — así puedes ver el propio proceso de toma de decisiones:

```bash
# La misma observación, pero de las decisiones del autoescalado: TARGETS muestra cómo cambia
# la carga, REPLICAS muestra cuántas réplicas solicitó en respuesta.
kubectl get hpa rickroll -w
```

## Paso 8. Aplicar la carga

📍 **Dónde:** en el navegador, en la pestaña de Fortio.

Rellena el formulario:

| Campo | Valor | Por qué así |
|---|---|---|
| URL | `http://rickroll/` | el nombre del Service; Fortio está en el clúster y lo ve directamente |
| QPS | `1200` | mil doscientas peticiones por segundo |
| Duration | `90s` | un minuto y medio: suficiente tanto para el crecimiento como para alcanzar a verlo |
| Connections | `80` | ochenta conexiones en paralelo |

Pulsa **Start**.

⚠️ **Si en tu versión de Fortio los campos se llaman distinto** (por ejemplo, el número de conexiones aparece etiquetado como `Threads`), guíate por el significado: URL, tasa de peticiones, duración, paralelismo. Puedes aplicar la misma carga con un comando, sin pasar por el navegador:

```bash
# exec ejecuta un comando dentro de un Pod que ya está en ejecución, no en tu laptop.
#   deploy/fortio   en un pod de esta aplicación; qué pod exactamente — kubectl lo elige solo
#   --              todo lo que va tras este separador es el comando para el Pod
#   -qps 1200       mil doscientas peticiones por segundo
#   -c 80           ochenta conexiones en paralelo
#   -t 90s          mantener la carga durante un minuto y medio
# El último argumento es el objetivo: el nombre del Service de nuestra aplicación.
kubectl exec deploy/fortio -- fortio load -qps 1200 -c 80 -t 90s http://rickroll/
```

## Paso 9. Observar qué ocurre

📍 **Ventana 2**, unos veinte segundos después del arranque:

```
NAME                        READY   STATUS              AGE
rickroll-6f4b9c8d57-p9wqt   1/1     Running             22m
rickroll-6f4b9c8d57-mn4kd   0/1     Pending             0s
rickroll-6f4b9c8d57-mn4kd   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-t8zxc   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-mn4kd   1/1     Running             3s
rickroll-6f4b9c8d57-t8zxc   1/1     Running             3s
```

Luego dos más, después una más. En un minuto hay seis réplicas.

📍 **Mira el HPA** — qué ve y qué decidió:

```bash
# TARGETS es la carga promedio actual frente al objetivo, REPLICAS es cuántas réplicas se solicitan.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 645%/50%   1         6         6          8m
```

**645%.** En el entorno de pruebas donde se probó este lab, salió exactamente eso; el tuyo tendrá otro orden de números, pero seguro cientos por ciento.

El número parece absurdo hasta que recuerdas contra qué se calcula. No contra la capacidad del nodo, sino contra el **request** de la réplica, y nuestro request es 20m — dos centésimas de un núcleo. Una réplica toma varias veces más de lo solicitado, y eso está permitido: `requests` es un mínimo garantizado, no un techo. El techo es `limits`, y todavía queda lejos.

El nodo, mientras tanto, está lejos de estar libre: `u1.medium` es un núcleo, y en este minuto sobre él corren tanto las réplicas de la aplicación como el propio generador de carga. El porcentaje alto no viene de una abundancia de capacidad, sino de un denominador pequeño.

**Los porcentajes por encima de cien aquí son la norma, no una alarma.** Esto es lo principal que rompe la intuición traída de vCenter: allí «CPU Usage 645%» significaría una catástrofe, porque el porcentaje se calculaba a partir de lo asignado. Aquí se calcula a partir del mínimo solicitado, y entre el request y el techo tenemos una diferencia de quince veces.

Comprueba tú mismo la aritmética del HPA:

```bash
# El consumo de cada réplica por separado. CPU(cores) se imprime en millicpu:
# 100m es una centésima de un núcleo, 1000m es un núcleo entero.
kubectl top pods -l app=rickroll
```

El promedio entre las réplicas es exactamente el número que el HPA compara con el umbral: el 50% del request de 20m, es decir, 10m. La suma de todas las réplicas topará con el núcleo del nodo — y ahí es donde el crecimiento se detiene, aunque subas más la carga.

📍 **En el navegador, en la pestaña de Fortio**, mientras tanto, se está dibujando un histograma de latencia. Mira la ejecución hasta el final: al terminar aparecerá una línea como `Code 200 : 108000 (100.0 %)`. Cero errores — la aplicación aguantó. Recuerda dónde está esta línea: en el lab 4 será la principal pieza de evidencia.

## Paso 10. Observar cómo las réplicas bajan de vuelta

La carga terminó. No hagas nada, observa la ventana 2.

Durante el primer minuto y medio o dos minutos no pasará nada. La pausa se compone de tres retrasos: las métricas se retrasan alrededor de un minuto, `stabilizationWindowSeconds: 60` exige que la carga sea baja durante todo el último minuto, y el propio HPA recalcula una vez cada quince segundos.

Luego las líneas caerán todas de golpe:

```
rickroll-6f4b9c8d57-t8zxc   1/1     Terminating   4m
rickroll-6f4b9c8d57-mn4kd   1/1     Terminating   4m
...
```

Cinco réplicas se van, queda una — `minReplicas`.

**Fíjate en la asimetría.** Subimos en escalones de dos réplicas; bajamos de un solo movimiento. Es por diseño: equivocarse por el lado de «demasiadas réplicas» cuesta solo la cartera, mientras que equivocarse por el lado de «demasiado pocas» significa tumbar el servicio. Por eso crecen de forma agresiva y se encogen con cautela.

## Verificación

📍 **Dónde:** en la laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

El script comprueba no el hecho de que el manifiesto se haya aplicado, sino que el mecanismo esté genuinamente vivo: que el HPA exista y apunte al Deployment correcto, que el contenedor tenga un `requests.cpu` a partir del cual se calcule el porcentaje, que `metrics-server` esté entregando números de verdad (que `TARGETS` no sea `<unknown>`), y que el status del HPA aún lleve una marca de que el escalado ya se disparó.

⚠️ **Ejecuta la comprobación antes de la limpieza** — una vez borrado el HPA no habrá nada que comprobar.

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo instalarlo está escrito al inicio del lab 0. Sin WSL puedes completar el lab, pero no habrá artefacto de informe.

```bash
# ./ significa «un archivo de la carpeta actual», no un comando del PATH del sistema.
# El script no cambia nada en el clúster: solo lee e imprime un informe.
./check.sh
```

## Limpieza

**Borra el HPA.** En el lab 4 estaremos desplegando una versión nueva bajo carga, y un mecanismo de más que cambie el número de réplicas al mismo tiempo solo enturbiaría la imagen:

```bash
# delete -f = «quita del clúster lo que describe este archivo». La aplicación se queda:
# en el archivo solo está descrito el HPA. Tras el borrado, el número de réplicas se congela en el valor actual.
kubectl delete -f hpa.yaml
```

**Conserva Fortio** — se necesitará en el lab 4 como fuente de carga. Si no tienes previsto el lab 4, quítalo también:

```bash
# Quita ambos objetos del archivo — el Deployment del generador y su Service.
kubectl delete -f fortio.yaml
```

No toques la aplicación `rickroll`.

Todo lo que liberaste volvió al pool compartido del nodo en el mismo momento en que los contenedores terminaron. Aquí no hay «asignado y no devuelto»: un request vive exactamente lo que vive el Pod.

## Qué sabemos hacer ahora

- Explicar la diferencia entre `requests` y `limits` y predecir qué pasa cuando se topa con cada uno
- Entender por qué el HPA calcula los porcentajes a partir de `requests` y por qué sin ellos no funciona
- Leer la fórmula del HPA y decir de antemano cuántas réplicas solicitará
- Distinguir «el manifiesto está aplicado» de «el mecanismo empezó a funcionar» y saber dónde mirar el status
- Darle a una aplicación carga real desde dentro del clúster, no desde la laptop

## Y en vSphere esto sería

En vSphere escalas hacia arriba: hot-add de CPU y memoria a una máquina en ejecución. Una persona lo hace según un calendario o ante una alerta, y ya está — vCenter no puede multiplicar instancias de una aplicación; para eso necesitas un balanceador de carga, una plantilla de máquina, y el trabajo manual de alguien. DRS resuelve un problema distinto: mueve máquinas existentes entre hosts, pero no cambia su número.

Aquí el número de réplicas es una consecuencia de la carga, descrita en veinte líneas de texto.

**Dónde vSphere es más cómodo, con honestidad.** Tres cosas, y todas significativas.

Primero, el hot-add funciona con cualquier aplicación, incluida una escrita en 2009 que existe estrictamente como una sola instancia. El HPA exige que la aplicación pueda correr en varias réplicas a la vez: sin estado compartido, sin escribir en un archivo local, sin sesión fijada a una instancia. Si no puede hacer eso, el autoescalado no está disponible para ti, y Kubernetes no resolverá este problema — lo dejará al descubierto. Justo aquí es donde pasa la verdadera frontera de la migración, no en los manifiestos.

Segundo, las métricas. vCenter guarda estadísticas durante meses, y la pregunta «qué pasó el martes pasado» se responde con un gráfico. `metrics-server` guarda los últimos minutos y nada más — está diseñado precisamente para alimentar al HPA. Para el historial tendrás que montar Prometheus, y eso es un trabajo aparte (lab 14).

Tercero, la predictibilidad del costo. Una máquina con cuatro núcleos cuesta una cantidad determinada, y eso se sabe de antemano. El autoescalado significa que en un mal día tendrás seis veces más consumo que en uno normal. `maxReplicas` no es una perilla de ajuste fino del rendimiento, es tu fusible del dinero, y hay que tratarlo en consecuencia.
