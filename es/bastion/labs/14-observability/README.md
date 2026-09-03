# Lab 14 · Observabilidad: encuentra tu propio pico en los gráficos

| | |
|---|---|
| **Tiempo** | 30 minutos |
| **Qué demuestra** | Las métricas se recolectan solas, de forma continua y retroactiva. No necesitas comprar un sistema de monitorización aparte |
| **Qué necesitas** | El clúster del lab 0, la app del lab 1, el lab 3 completado (carga y HPA), acceso al panel del tenant |

## Por qué esto importa

Ayer a las 16:40, "Propusk" tardó quince minutos en responder. La queja llegó hoy a las 11:00,
como siempre. La pregunta de la gerencia: qué fue eso y si volverá a pasar.

El enfoque de "reproduzcámoslo ahora y echemos un vistazo" no funciona: no puedes reproducir la carga ajena
de ayer. La única forma de responder es tener **registros de ayer**, tomados antes de que nadie preguntara.

En este lab encontraremos, en los gráficos, las huellas de nuestra propia carga del lab 3: el pico de CPU cuando
empezó el tráfico y el escalón hacia arriba cuando el autoescalado añadió copias. No hicimos ninguna preparación
especial para esto: los registros ya están ahí.

## Miniglosario

| Término | Qué es | Como… pero |
|---|---|---|
| **Métrica** | Un número tomado con regularidad: cuánta CPU, cuánta memoria, cuántas solicitudes | **un contador en los gráficos de vCenter**, pero guardado como historial y no como el último valor |
| **Etiqueta (label)** | Un par "nombre=valor" en una métrica: pod, namespace, clúster | **el objeto al que se asocia un contador**, pero hay muchas etiquetas y puedes segmentar y agrupar por cualquiera de ellas |
| **Serie temporal** | Una única métrica con un único conjunto de etiquetas, a lo largo del tiempo | **un único gráfico en vCenter**, pero cada combinación de etiquetas es su propia serie, y hay miles de ellas |
| **Scrape** | Recolección: un agente sondea las fuentes cada N segundos | **la recolección de contadores de vCenter**, pero es el agente el que extrae los datos, y no la aplicación la que los envía |
| **PromQL** | El lenguaje de consultas para métricas | no hay analogía directa: en vCenter eliges un contador, aquí escribes una expresión |
| **VictoriaMetrics** | El almacén donde se guardan las métricas recolectadas | **la base de datos de estadísticas de vCenter**, pero entiende el lenguaje de consultas de Prometheus, aunque no sea Prometheus en sí |
| **Grafana** | La interfaz para métricas y registros | **la pestaña Performance**, pero un producto aparte; los paneles se escriben a mano o se toman ya hechos |
| **Retención** | Cuánto tiempo se conserva el historial | **los niveles de estadísticas de vCenter**, pero fijados por un parámetro; por defecto 3 días y 14 días repartidos en dos almacenes separados |
| **Registros (logs)** | Las líneas que escribe una aplicación | **los registros en el SO invitado**, pero recolectados de forma centralizada, con su propio lenguaje de consultas, no PromQL |
| **Pod** | La unidad mínima de ejecución: un contenedor o varios, siempre en un mismo nodo | **una máquina virtual**, pero desechable: en vez de reiniciarlo, se recrea con un nombre nuevo |
| **Namespace** | Una partición dentro del clúster: nombres idénticos en distintos namespaces no colisionan | **una carpeta en el inventario de vCenter**, pero también reparte permisos, cuotas y políticas de red |
| **Tenant** | Tu porción de la plataforma: ahí vive Grafana, y ahí fluyen las métricas del clúster | **un Resource Pool con sus propios permisos**, pero además reparte servicios ya hechos, no solo recursos |

### Métricas y registros — por qué son cosas distintas

Constantemente se los mete en el mismo saco, y luego la gente se pone a buscar en los registros algo que solo existe en las métricas.

| | Métricas | Registros |
|---|---|---|
| Qué son | números a intervalos regulares | líneas en el momento de un evento |
| Ejemplo | "a las 16:41:30 el Pod usó 240 millicores" | "16:41:31 ERROR connection refused" |
| Cuánto espacio | poco, y el volumen es predecible | mucho, y el volumen depende de lo hablador que sea la aplicación |
| Cuánto se conservan | semanas y meses | días |
| Qué pregunta responden | "cuánto y cuándo" | "qué pasó exactamente" |
| Lenguaje de consultas | PromQL | LogsQL (en Grafana es una fuente de datos aparte) |

Funcionan como pareja: **las métricas te encuentran el momento, los registros te encuentran la causa.** El gráfico
mostró un pico a las 16:41 — vas a los registros de ese minuto. Al revés no funciona: buscar en los registros
"cuándo se puso feo" puede llevar una eternidad.

### Por qué las métricas se toman de forma continua, no bajo demanda

Esto es lo principal que separa la monitorización del diagnóstico, y vale la pena decirlo con claridad.

Recolectar bajo demanda es **físicamente** imposible: para cuando se formula la pregunta, el evento ya terminó.
Ningún sistema te mostrará la carga de anoche si nadie la estaba registrando anoche.

Así que el agente lo sondea todo, sin discriminar, cada 30 segundos y lo mete en el almacenamiento. Sí,
el 99 % de esos números nadie los mirará jamás. El precio de ese 99 % son unos pocos gigabytes de disco.
El precio del uno por ciento que falta es "no sabemos qué pasó, y nunca lo sabremos".

⚠️ **La contrapartida, que conviene conocer de antemano.** La recolección continua significa un coste
continuo: el agente consume CPU y memoria, y el almacenamiento crece. En un clúster grande, las métricas se vuelven
una línea de gasto apreciable en el consumo, y hay que adelgazarlas: reducir la retención,
descartar etiquetas innecesarias, apagar la recolección de métricas poco usadas. Este es un trabajo operativo
rutinario, y no aparece en el primer mes, pero aparece.

## Qué hay en la carpeta del lab

Ya tienes todos los archivos: los recibiste junto con el repositorio. No hay nada que crear ni volver a teclear:
donde más abajo diga `kubectl apply -f name.yaml`, el archivo se toma de aquí.

```bash
# cámbiate a la carpeta de este lab: todas las rutas relativas de abajo se cuentan desde aquí
cd labs/14-observability
```

| Archivo | Qué es | Cuándo es útil |
|---|---|---|
| `check.sh` | Comprueba que las métricas se están recolectando y que los gráficos responden | lo ejecutas al final del lab |
| — | Este lab no tiene manifiestos propios: tomamos la carga y el autoescalado del lab 3 — `../03-scale/` | |

## Paso 1. Asegúrate de que las métricas se recolectan siquiera

📍 **Dónde:** en el bastion (en la terminal del bastion).

El clúster `lab` no expone sus métricas por sí solo, sino a través del complemento `Monitoring agents`.
Comprueba si está habilitado:

```bash
# KUBECONFIG — la variable que kubectl lee para averiguar la dirección del clúster y con quién
# iniciar sesión. Guardaste el archivo ~/lab.kubeconfig cuando creaste el clúster `lab`.
# Hay que fijarla de nuevo en cada ventana de terminal nueva.
export KUBECONFIG=~/lab.kubeconfig

# get pods = "muéstrame qué pods existen".
#   -n cozy-monitoring   no mires en todo el clúster, sino en este namespace: es
#                        justo donde el complemento coloca sus recolectores.
kubectl get pods -n cozy-monitoring
```

**Si ves `vmagent` y `fluent-bit` en la lista** — todo está en su sitio, sigue adelante.

⚠️ **Fíjate en los nombres, no en si la lista está vacía.** El namespace `cozy-monitoring`
siempre existe: la plataforma también coloca ahí `metrics-server`, que se instala en cualquier
clúster con su propio etcd y no depende del complemento. Dicho de otro modo, ver una línea
`metrics-server` y concluir que la recolección de métricas está activa es un error clásico, y sale a la luz
solo en Grafana, donde todo estará vacío.

**Si la lista tiene `metrics-server` pero ni `vmagent` ni `fluent-bit`:**

```
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-7d4b8c9f5-x2klm    1/1     Running   0          3d
```

Eso significa que el complemento está apagado, y no tienes registros del pasado. Esto, por cierto, es una
ilustración precisa de la sección anterior: no puedes habilitar la recolección de forma retroactiva.

Se habilita en el panel: `Kubernetes` → `lab` → editar → en la sección Addons, marca
`Monitoring agents`. El complemento arranca en un par de minutos, pero **las métricas solo empiezan a acumularse
a partir de ese momento** — el pico del lab 3 ya no lo encontrarás.

Así que tendrás que crear el pico de nuevo. Ten en cuenta que la limpieza del lab 3 quitó
el autoescalado, y la limpieza del lab 4 quitó el generador de carga, así que necesitas traer de vuelta ambos:

```bash
export KUBECONFIG=~/lab.kubeconfig          # el mismo archivo de acceso que arriba

# apply = "lleva el clúster a lo que describe el archivo". Ambos archivos viven en la
# carpeta del lab vecino, así que la ruta empieza con `../` — no hace falta volver a teclearlos.
kubectl apply -f ../03-scale/hpa.yaml       # la regla de autoescalado para rickroll
kubectl apply -f ../03-scale/fortio.yaml    # el generador de carga

# rollout status = "retén la terminal y avísame cuando el despliegue haya terminado".
# deployment/fortio — el tipo de objeto y su nombre. El comando devuelve el prompt
# con la línea `successfully rolled out` en cuanto el generador arranca.
kubectl rollout status deployment/fortio
```

Espera hasta que `kubectl get hpa rickroll` muestre un porcentaje en vez de `<unknown>`; `hpa` es
la forma abreviada de `HorizontalPodAutoscaler`, el objeto de autoescalado. Esto lleva un par de
minutos. Luego reenvía el puerto del generador y aplica la misma carga que en el lab 3, de lo contrario
el escalón del autoescalado no aparecerá:

```bash
# port-forward = cava un túnel desde el bastion hacia dentro del clúster. Mientras el comando corre,
# una solicitud a localhost:8081 aterriza en el generador de carga.
#   svc/fortio    el destino: el service (no el pod) llamado fortio
#   8081:8080     a la izquierda, el puerto en tu bastion; a la derecha, el puerto dentro del service
# No cierres la ventana: el túnel vive exactamente lo que dura el comando.
kubectl port-forward svc/fortio 8081:8080
```

En <http://localhost:8081/fortio/>: **URL** `http://rickroll/`, **QPS** `1200`,
**Duration** `90s`, **Connections** `80`. Vuelve aquí un par de minutos después de que termine — los
datos estarán ahí.

⚠️ Para no acabar en esta situación, habilita `Monitoring agents` justo al crear el
clúster — en el lab 0 es una línea aparte en la tabla de parámetros.

<details>
<summary><b>Qué corre exactamente ahí y adónde van los datos recolectados</b></summary>

En el namespace `cozy-monitoring` de tu clúster corren los siguientes:

| Quién | Qué hace |
|---|---|
| `vmagent` | sondea las fuentes de métricas cada 30 segundos y envía lo que recolecta al tenant |
| `kube-state-metrics` | convierte el estado de los objetos del clúster en métricas: cuántas réplicas, en qué estado están los Pods |
| `node-exporter` | métricas del propio nodo: CPU, memoria, disco, red |
| `fluent-bit` | recolecta los registros de los contenedores y los envía al tenant |
| `metrics-server` | **no forma parte de la monitorización**: se instala junto con el clúster y suministra los números actuales para `kubectl top` y el autoescalado. No guarda nada y no participa en la recolección de métricas |

Nota: **aquí no hay almacenamiento**. Todo lo recolectado se envía de inmediato por la red al
tenant, al almacén de métricas compartido junto a Grafana. Esto es deliberado: el clúster `lab` es algo
desechable — lo borrarás, pero los registros de cómo se comportó tienen que sobrevivir a ese borrado.

Para ver la dirección a la que el recolector envía sus datos:

```bash
# get vmagent = "muéstrame el objeto del recolector". En vez de la tabla habitual pedimos un único
# campo de su descripción — la sintaxis -o jsonpath funciona con cualquier objeto del clúster:
#   .items[0]                  el primer (y aquí único) recolector encontrado
#   .spec.remoteWrite[0].url   la dirección a la que entrega las métricas
#   {"\n"}                     un salto de línea, de lo contrario la salida se pega al prompt
kubectl get vmagent -n cozy-monitoring \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}{"\n"}'
```

```
http://vminsert-shortterm.tenant-workshopXX.svc.cozy.local:8480/insert/0/prometheus
```

La dirección apunta hacia dentro de tu tenant. Es el mismo mecanismo que el bastion del lab 12 usó para hablar con la
aplicación: una red corriente entre direcciones corrientes.

</details>

## Paso 2. Abre la Grafana del tenant

📍 **Dónde:** en el navegador.

La dirección es el subdominio `grafana` del host de tu tenant:

```
https://grafana.<host de tu tenant>
```

La dirección exacta está anotada en el panel: tu tenant → la app `Monitoring` → la
pestaña `Ingress`. Un Ingress es una regla para publicar un service hacia fuera bajo un nombre de dominio; el
análogo más cercano es una entrada en un balanceador de carga, solo que descrita dentro del propio clúster. La dirección está
ahí completa, nombre de host incluido.

Un segundo lugar es la salida de `check.sh` de este mismo lab: la línea "Grafana for your metrics".
El script saca la dirección de ese mismo ingress, así que no hace falta teclearla a mano.

⚠️ **Si no hay ninguna app `Monitoring` en tu tenant** — entonces tampoco tienes Grafana propia, y
las métricas van a la monitorización del tenant padre. El camino fiable es desplegar `Monitoring` desde el
catálogo (la sección `Administration`): la dirección aparecerá en la pestaña `Ingress` de tu propia
app, y todas las consultas de abajo funcionarán. `check.sh` también encontrará la monitorización de otro y
nombrará el namespace en el que corre, pero solo podrás abrirla si tienes acceso a ese namespace.

**Cómo iniciar sesión.** El login es `admin`. La contraseña está en el Secret `grafana-admin-password`:
panel → la app `Monitoring` → la pestaña `Secrets` → la clave `password` → `Reveal`.

Como tenant, `kubectl` no te dará acceso a este Secret (los Secrets del núcleo no son visibles para ti), así que ve por el panel.

Si tu monitorización es la del padre, este Secret está fuera de tu alcance — entonces, o despliega tu propia
app `Monitoring`, como se describe arriba, o pide acceso a quien administre el entorno de pruebas.

Una vez dentro, abre **Explore** — esta es la sección para consultas puntuales, sin guardar paneles.
En el desplegable de la fuente de datos, selecciona **`vm-shortterm`** (que además es la predeterminada).

⚠️ **Cambia el campo de consulta al modo `Code`.** Grafana abre Explore en el constructor
(`Builder`) — un formulario con desplegables donde no hay dónde teclear el texto de la consulta.
El interruptor `Builder | Code` está encima del campo de entrada, a la derecha. Todas las consultas de abajo se
teclean en `Code`.

<details>
<summary><b>Qué son las fuentes de datos de la lista</b></summary>

| Fuente | Qué hay dentro | Conserva |
|---|---|---|
| `vm-shortterm` | métricas de alta resolución | 3 días |
| `vm-longterm` | las mismas métricas, adelgazadas | 14 días |
| `vlogs-generic` | registros de contenedores | 1 día |

Dos almacenes de métricas en vez de uno es un compromiso entre resolución y volumen.
Investigarás un incidente con `shortterm`, donde puedes ver cada 30 segundos. Responderás
la pregunta "cómo se comportó hace dos semanas" con `longterm`, donde la resolución
es más gruesa pero la profundidad es mayor.

Exactamente la misma lógica que en los niveles de estadísticas de vCenter, donde los datos con intervalo de 20 segundos
viven un día y los datos horarios un año.

⚠️ **`vlogs-generic` son registros, y el lenguaje de consultas ahí es distinto.** PromQL no funciona en él,
y eso no es un fallo: los registros tienen su propia gramática. No pierdas tiempo cambiando la fuente y
pegando la misma consulta.

</details>

⚠️ **En la Grafana del tenant no hay paneles ya hechos para Pods.** La lista tendrá paneles para
bases de datos, ingress y colas — las cosas que pertenecen a los servicios gestionados. Los paneles al
nivel de "Pods y nodos" no forman parte del conjunto del tenant. Así que de aquí en adelante trabajamos en Explore y escribimos
consultas a mano. Esto es menos cómodo que la pestaña Performance ya hecha de vCenter, y no tiene
sentido fingir lo contrario.

## Paso 3. Encuentra tus Pods

📍 **Dónde:** en Grafana, Explore, la fuente `vm-shortterm`.

Empecemos por la pregunta más burda: qué Pods se ven en el clúster siquiera. La consulta es corta, pero
tiene tres partes desconocidas — despliega el desglose antes de teclearla.

<details>
<summary><b>Desglosando la consulta parte por parte</b></summary>

```promql
container_cpu_usage_seconds_total
```

El nombre de la métrica. Es un contador: cuántos segundos de tiempo de CPU ha gastado el contenedor
desde que arrancó. Solo sube — hasta que el contenedor se reinicia, tras lo cual
empieza desde cero.

Por sí sola es inútil: "el Pod gastó 4718 segundos de CPU" no te dice nada.
Esta métrica se vuelve útil después de `rate()`, al que llegaremos en el siguiente paso.

```promql
{cluster="kubernetes-lab", namespace="default"}
```

Un filtro por etiquetas. Ambas etiquetas de aquí importan.

`cluster` — el nombre de tu clúster tal como lo conoce la plataforma. **No es igual** a `lab`:
la aplicación se llama `lab`, pero la release con la que se despliega es `kubernetes-lab`, y es
el nombre de la release el que acaba en las etiquetas. Este es el primer escollo con el que todos tropiezan. Para comprobar cómo
se llama el tuyo: borra el valor y mira qué sugiere el autocompletado de Grafana.

La etiqueta hace falta porque un único almacén guarda las métricas de **todos** tus clústeres y
servicios gestionados. Sin el filtro obtendrás una mezcla de todo lo que hay en el tenant.

`namespace` — el namespace **dentro** del clúster `lab`. La app del primer lab se desplegó
en `default`, así que aquí es `default`. No lo confundas con el namespace del tenant
(`tenant-workshopXX`) — son cosas distintas en clústeres distintos. El namespace del tenant vive en la
etiqueta `tenant`.

```promql
count by (pod) ( ... )
```

Agrupa por la etiqueta `pod` y cuenta cuántas series cayeron en cada grupo. No nos
interesan los números en sí, sino la lista de valores de `pod` resultantes.

</details>

```promql
# count by (pod) — separa las series coincidentes por la etiqueta pod y cuenta cuántas series
# hay en cada grupo. Los números en sí dan igual: lo que queremos es la lista de nombres de pod que resulta.
count by (pod) (
  # el nombre de la métrica — el contador de tiempo de CPU del contenedor
  container_cpu_usage_seconds_total{
    cluster="kubernetes-lab",   # tu clúster: aquí el nombre de la release, no el nombre de la app lab
    namespace="default"         # el namespace dentro del clúster lab donde se despliega rickroll
  }
)
```

**Qué deberías ver:** cambia la vista de Graph a **Table** — la lista se lee
mejor así. La tabla tendrá `rickroll-...`, `fortio-...` y, si hiciste el lab 11,
`propusk-build-...`.

## Paso 4. Encuentra el pico de CPU

El contador del paso anterior no se puede leer en su forma cruda. Convirtámoslo en una cantidad que
puedas comparar con el request del Pod y con lo que muestra `kubectl top` — en cores consumidos.
Qué hace `rate()` en el proceso, y de dónde salen las dos condiciones extra de la consulta, está en el desglose de abajo;
despliégalo antes de teclear.

<details>
<summary><b>Desglosando la consulta parte por parte</b></summary>

```promql
rate( ... [2m])
```

`rate` toma un contador y calcula **su tasa de crecimiento por segundo**, promediando sobre una ventana
de dos minutos. Para una métrica de tiempo de CPU esto da una cantidad muy cómoda: "cuántos
segundos de CPU por segundo", es decir, cuántos cores se estaban consumiendo. `0.24` significa el 24 % de
un core, es decir `240m` en millicores.

La ventana `[2m]` es un compromiso. Una ventana más pequeña (`[30s]`) — el gráfico da saltos y se corta con
datos escasos. Una más grande (`[5m]`) — el pico se difumina y un pico bajo puede desaparecer por completo.
Empieza con `[2m]` y ajusta a partir de ahí.

⚠️ **La ventana debe ser al menos el doble del intervalo de recolección.** La recolección ocurre cada 30 segundos,
así que no puedes fijar nada por debajo de `[1m]` — solo un punto caería dentro de la ventana, y una tasa no puede
calcularse a partir de un único punto, así que el gráfico se queda vacío. Esta es la causa más común de "no me
dibuja nada".

```promql
pod=~"rickroll-.*"
```

`=~` — una comparación por expresión regular en vez de una coincidencia exacta. Una coincidencia exacta no
sirve aquí: los nombres de los Pods contienen una cola aleatoria y cambian en cada recreación.

```promql
container!=""
```

Descarta las series sin nombre de contenedor. Esas series existen: son un agregado sobre el Pod entero,
y si no las descartas, cada Pod se cuenta dos veces y el gráfico muestra exactamente el doble
de la verdad. Otra trampa clásica.

```promql
sum by (pod) ( ... )
```

Suma todo lo que queda, por Pod. Un Pod puede tener varios contenedores; nos
interesa el Pod como un todo.

</details>

```promql
# rate(...[2m]) — la tasa de crecimiento del contador por segundo, promediada sobre una ventana de 2 minutos.
# Para el tiempo de CPU se lee como "cuántos cores se estaban consumiendo":
# 0.24 — veinticuatro por ciento de un core, es decir 240m.
sum by (pod) (     # suma los contenedores del pod: una línea por pod, no por contenedor
  rate(container_cpu_usage_seconds_total{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*",  # =~ comparación por expresión regular: la cola del nombre del pod es aleatoria
    container!=""        # descarta la serie total del pod entero, de lo contrario todo se duplica
  }[2m])
)
```

Fija el rango temporal al momento en que hacías el lab 3 — por ejemplo, las últimas 3 horas.

**Qué deberías ver:** una línea plana justo en cero, luego una subida brusca durante toda la
carga, luego un regreso hacia abajo. Si llegó a haber varias réplicas, habrá varias líneas, y
aparecerán no todas de golpe sino a medida que se crean los Pods.

## Paso 5. Encuentra el escalón del autoescalado

Hemos encontrado el pico. Ahora veamos cómo respondió el clúster: cuántas copias de la aplicación
mantuvo en marcha en cada momento y cuántas quería mantener. Estos son dos números distintos, y
la diferencia entre ellos es lo más interesante de este paso. De dónde salen está en el desglose de abajo.

<details>
<summary><b>De dónde salen estas métricas y en qué se diferencia desired de current</b></summary>

Estas métricas no vienen de la aplicación sino de `kube-state-metrics` — que lee los objetos del clúster
a través de la API y convierte sus campos en números. La etiqueta `horizontalpodautoscaler` es el nombre del
objeto HPA (`HorizontalPodAutoscaler`, esa misma regla de autoescalado del lab 3), la
etiqueta `deployment` es el nombre del Deployment, es decir, de la descripción "mantén tantas
copias de la aplicación", y así para cada tipo de objeto.

`desired` — cuántas copias **quiere** el autoescalado ahora mismo, tras calcular a partir de la
carga. `current` — cuántas están **realmente** en marcha. Siempre hay una brecha entre ambas:
los Pods no se crean al instante.

Si `desired` se mantiene por encima de `current` mucho tiempo, significa que las copias no se están creando. La causa es
casi siempre la misma: no hay suficiente sitio en los nodos, y los Pods nuevos se quedan colgados en `Pending`. Exactamente la situación
con la que te topaste en el lab 11.

Útil en paralelo:

```promql
# cuántas copias de rickroll se han creado en total
kube_deployment_status_replicas{cluster="kubernetes-lab", deployment="rickroll"}
# cuántas de ellas han pasado la comprobación de readiness y ya reciben tráfico
kube_deployment_status_replicas_available{cluster="kubernetes-lab", deployment="rickroll"}
```

La divergencia entre ambas durante el despliegue de una versión nueva es justo esa pausa mientras la
copia nueva pasa su comprobación de readiness.

</details>

```promql
# ..._status_current_replicas — cuántas copias de rickroll están corriendo ahora mismo.
# El número no viene de la aplicación sino del objeto HPA, leído por kube-state-metrics.
kube_horizontalpodautoscaler_status_current_replicas{
  cluster="kubernetes-lab",             # solo tu clúster lab
  horizontalpodautoscaler="rickroll"    # el nombre del objeto de autoescalado del lab 3
}
```

y en paralelo, como segunda consulta:

```promql
# ..._status_desired_replicas — cuántas copias quiere tener el autoescalado ahora,
# según la carga. current rezagado respecto a desired es justo el tiempo de creación del pod.
kube_horizontalpodautoscaler_status_desired_replicas{
  cluster="kubernetes-lab",
  horizontalpodautoscaler="rickroll"
}
```

**Qué deberías ver:** una línea escalonada. Era una, luego tres, luego cinco o
seis, luego — con un retraso de aproximadamente un minuto después de que la carga baja — de vuelta abajo.

Superpónla sobre el gráfico de consumo de CPU del paso anterior: en Explore se añade una segunda
consulta con el botón `+ Add query`. Puedes ver que el escalón va **por detrás** del pico con
un retraso de varias decenas de segundos: primero subió la CPU, luego el autoescalado lo notó y
reaccionó. Esta es la respuesta a la pregunta "por qué los usuarios sí llegaron a notar la ralentización
al fin y al cabo".

## Paso 6. Mira lo mismo a través de los ojos del autoescalado

El autoescalado no mira el consumo absoluto sino la **fracción de los `requests`**.
`requests` es la solicitud de recursos de un Pod: cuánta CPU y memoria le reserva el scheduler
en un nodo, use el Pod esos recursos o no.
El análogo más cercano es una reserva (reservation) en vSphere.

Miremos exactamente la cantidad sobre la que se toma la decisión. La consulta consta de dos
partes separadas por un signo de división: arriba, el consumo real; abajo, el request.

```promql
# La parte de arriba — el consumo real de CPU del pod. La misma consulta que arriba.
sum by (pod) (
  rate(container_cpu_usage_seconds_total{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*", container!=""
  }[2m])
)
/
# La parte de abajo — cuánto solicitó el pod. El resultado de la división es la fracción del request: 1 significa
# "consume exactamente lo que solicitó", 0.5 — la mitad de lo solicitado.
sum by (pod) (
  kube_pod_container_resource_requests{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*",
    resource="cpu"     # la métrica también tiene series de memoria — conservamos solo CPU
  }
)
```

**Qué deberías ver:** una línea que corre baja casi todo el tiempo y sube durante toda la
carga. Un valor de uno en este gráfico significa "el Pod consume exactamente lo que
solicitó".

En `hpa.yaml` del lab 3 hay `averageUtilization: 50`, y en `rickroll.yaml` —
`requests.cpu: 20m`. Es decir, el umbral de disparo es 10 millicores por Pod, que en el gráfico es la
marca `0.5`. Encuentra el momento en que la línea la cruzó, y contrástalo con el escalón del
paso anterior: entre ambos habrá esas mismas decenas de segundos.

⚠️ Dividir dos expresiones en PromQL funciona haciendo coincidir **todas** las etiquetas. Aquí cuadra,
porque ambas partes están agrupadas `by (pod)` y no queda ninguna otra etiqueta tras el agrupamiento.
Si los conjuntos de etiquetas difirieran, el resultado saldría vacío — ni error ni aviso, un gráfico
vacío. Esta es la característica más traicionera del lenguaje.

## Paso 7. Tres consultas para el uso diario

Vale la pena guardarlas — cubren la mayoría de las preguntas del día a día.

**Quién en el clúster consume más CPU, top 10:**

```promql
# topk(10, ...) — conserva solo las diez series con los valores más grandes.
# Agrupar by (namespace, pod) añade el namespace a la respuesta: puedes ver de quién es el pod.
# La ventana [5m] es más ancha que en los pasos anteriores: no queremos la forma del pico, sino el nivel medio.
topk(10,
  sum by (namespace, pod) (
    rate(container_cpu_usage_seconds_total{cluster="kubernetes-lab", container!=""}[5m])
  )
)
```

**Memoria por Pod (no es un contador, así que sin `rate`):**

```promql
# container_memory_working_set_bytes — no es un contador sino un valor instantáneo: tantos bytes
# están ocupados en este momento. rate() aquí daría una tontería — "bytes por segundo".
sum by (pod) (
  container_memory_working_set_bytes{
    cluster="kubernetes-lab", namespace="default", container!=""
  }
)
```

⚠️ Concretamente `working_set`, no `container_memory_usage_bytes`. Este último incluye la caché de
archivos, que el kernel cederá bajo presión, y por eso asusta con regularidad a la gente con cifras que no tienen nada
que ver con las necesidades reales de la aplicación. La decisión de matar un Pod por memoria
también se toma sobre `working_set`.

**Cuánto recurso está reservado frente a cuánto se usa realmente:**

```promql
# sum without by — suma todo en un único número: cuánta CPU está reservada para todos
# los pods del clúster. Esto es el request, no el consumo: lo que está reservado y sin usar
# también entra en la suma.
sum(kube_pod_container_resource_requests{cluster="kubernetes-lab", resource="cpu"})
```

Compara este número con la suma de la primera consulta. La diferencia entre "reservado" y
"usado" es lo que pagas y a cambio no obtienes nada. La misma conversación que sobre las
reservas en vSphere, solo que aquí puedes verlo en un gráfico.

Si hiciste el lab 11, echa de paso un vistazo al build de Android — se ve claramente:

```promql
# El mismo rate, pero un filtro sobre los pods del build. sum without by (pod) — una línea para todo el build,
# levante los pods que levante.
sum(rate(container_cpu_usage_seconds_total{
  cluster="kubernetes-lab", pod=~"propusk-build-.*", container!=""
}[2m]))
```

Veinte minutos de una meseta plana a un core y medio o dos cores, luego una caída a cero. Así se ve un
Job en un gráfico — una tarea puntual que lleva el trabajo hasta el final y termina. A diferencia de
una aplicación, que se mantiene en marcha de forma permanente, su línea tiene un fin.

## Paso 8. Echa un vistazo a los registros

Cambia la fuente de datos a **`vlogs-generic`**. El lenguaje de consultas aquí es distinto: en PromQL
describías series numéricas, en LogsQL seleccionas líneas por los valores de sus campos.

La consulta de abajo se lee así: "muestra las líneas cuyo campo `kubernetes_namespace_name` sea igual a
`default` y cuyo campo `kubernetes_pod_name` empiece con `rickroll`".
El asterisco al final es esa misma cola aleatoria del nombre del Pod, la que te obligó a escribir
`=~` en PromQL.

```logsql
kubernetes_namespace_name:default AND kubernetes_pod_name:rickroll*
```

Ajusta la hora: toma el minuto del pico que encontraste en el gráfico de consumo de
CPU, y mira los registros de ese minuto. En ese minuto nginx tendrá un pico de registros de solicitudes.

**Para esto separamos las métricas y los registros.** Con el gráfico encontraste el momento entre tres
horas en un segundo. Con los registros de ese minuto — qué estaba pasando exactamente. Al revés no
funciona: buscar "cuándo se puso feo" desplazándote por los registros puede llevar muchísimo tiempo.

## Comprobación

📍 **Dónde:** en el bastion, en la misma ventana de terminal donde trabajaste con `kubectl`.

```bash
export KUBECONFIG=~/lab.kubeconfig          # acceso al clúster lab `lab`

# Las dos variables de abajo dan al script acceso también al tenant. Con ellas, además
# comprobará que las métricas llegaron ahí, e imprimirá la dirección de tu Grafana. Sin ellas
# la comprobación pasará, pero el informe será más corto.
export COZY_TENANT=workshopXX               # tu número en vez de XX
export COZY_KUBECONFIG=~/.kube/config     # el archivo de acceso al tenant

./check.sh                                  # ./ = "ejecuta el archivo desde la carpeta actual"
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo configurarlo está
escrito al principio del lab 0. Puedes completar el lab sin WSL, pero no habrá informe de artefacto.

El script no comprueba "miraste el gráfico" — eso no se puede comprobar — sino lo que
se puede y se debe comprobar: que la recolección de métricas realmente funciona, que el envío está configurado hacia tu
tenant, que la recolección de registros funciona, y que el clúster tiene una huella de la carga del lab 3 que puede encontrarse en estos
gráficos.

## Limpieza

No hay nada que limpiar. El complemento `Monitoring agents` consume poco y será útil hasta el final del
taller — déjalo habilitado.

Las métricas se borrarán solas: por defecto `shortterm` conserva 3 días, `longterm` 14, los registros
un día. Este es ese raro caso en que la limpieza la hacen por ti y no se puede olvidar.

## Qué sabemos hacer ahora

- Explicar por qué las métricas se recolectan de forma continua, y en qué se diferencian de los registros
- Comprobar que la recolección en el clúster está habilitada y hacia dónde envía exactamente
- Escribir consultas que encuentran tus Pods y su consumo, y no caer en `container!=""`
- Encontrar el pico de carga en los gráficos y la reacción del autoescalado a él
- Leer la divergencia de `desired` y `current` como señal de sitio insuficiente

## Y en vSphere esto sería

vCenter muestra contadores para hosts y máquinas virtuales — eso basta mientras las preguntas
se hagan sobre máquinas virtuales. En cuanto la pregunta pasa a ser "qué le pasó al servicio", necesitas
vRealize Operations: un producto aparte, una licencia aparte, una instalación aparte,
máquinas virtuales aparte para ejecutarlo, y una persona aparte que sepa configurarlo.

Aquí, la recolección de métricas y registros es un complemento que habilitas con una casilla en la aplicación, y
Grafana con su almacenamiento arranca como un elemento del catálogo. Ni licencia, ni proyecto de implementación.

**Dónde vSphere es más cómodo, con honestidad.** Cuando se trata de lo que funciona justo después de la instalación,
vCenter gana de calle, y lo vimos aquí mismo en el lab:

| | vSphere | Cozystack |
|---|---|---|
| Gráficos justo después de la instalación | la pestaña Performance en cada objeto | tienes que habilitar el complemento y abrir Grafana |
| Vistas ya hechas | presentes para cualquier VM y host | en el tenant — solo para servicios gestionados |
| Encontrar el contador que necesitas | lo eliges de una lista con el ratón | escribes una consulta en PromQL |
| Barrera de entrada | una hora | varios días, hay que aprender PromQL |
| Profundidad una vez le has cogido el truco | limitada por el conjunto de contadores | limitada por qué métricas y etiquetas se recolectan |

PromQL es un lenguaje, y realmente hay que aprenderlo. Las primeras dos semanas estarás
copiando consultas ajenas sin entender por qué el gráfico está vacío. A cambio obtienes lo que
vCenter no tiene en absoluto: la capacidad de hacer una pregunta arbitraria — "muestra el consumo de los
Pods de esta aplicación en relación con su reserva, agrupado por nodo, del martes pasado" — y obtener una
respuesta, en vez de "no existe ese contador".
