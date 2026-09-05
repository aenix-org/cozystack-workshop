# Lab 9 · Analítica sobre un millón de filas

| | |
|---|---|
| **Tiempo** | 45 minutos |
| **Qué demuestra** | Un informe sobre un millón de registros se calcula en milisegundos, y montarlo lleva diez minutos |
| **Qué necesitarás** | El clúster del lab 0 y `~/lab.kubeconfig`; acceso al panel de tu tenant; un número de tenant con el formato `workshopXX`; saber leer SQL |

> ⚠️ **Un lab denso que exige leer SQL. No lo programes justo después del lab 8.**

## Por qué esto importa

El servicio «Pase» lleva ya seis meses en funcionamiento. La dirección aparece con una pregunta que
suena inofensiva:

> ¿Cuántos invitados recibimos al mes, va en aumento o en descenso, y a qué horas hay cola en
> la entrada? Nos gustaría mirarlo una vez al mes, idealmente cada día.

La base de datos donde viven los pases en sí no guarda eso: tiene las solicitudes actuales, no años
de historial. El historial vive en el registro de entradas: cada paso por el torniquete durante todo
el tiempo que el servicio lleva funcionando. Eso ya es un millón de filas, y seguirá creciendo.

Entonces empieza lo de siempre. Alguien escribe una consulta `GROUP BY` contra la base de datos de
producción; se ejecuta durante dos minutos y deja caído el servicio de pases durante esos dos
minutos. Alguien propone exportar a Excel, y choca con el límite de filas. Alguien monta una
exportación nocturna a una base de datos aparte, y seis meses después nadie recuerda por qué las
cifras del informe no cuadran con la realidad.

La respuesta correcta es **una base de datos aparte para analítica, construida de otra manera**. No
«la misma, pero en otro servidor», sino distinta por dentro. En este lab levantaremos ClickHouse,
cargaremos en él un millón de registros de entrada y veremos cuánto tarda en calcularse el informe.

Por el camino entenderemos **por qué una base de datos columnar es rápida en analítica y lenta en
operaciones puntuales**, porque la segunda mitad importa tanto como la primera, y no saberlo es justo
lo que lleva a poner ClickHouse donde no hace falta.

Cada término de este lab se explica la primera vez que aparece, y la siguiente sección es un glosario
de los ya introducidos.

## Glosario

| Término | Qué es | Como… pero |
|---|---|---|
| **OLAP** | Una carga de trabajo de «pocas consultas, pero cada una lee millones de filas» | **Un informe trimestral de vRealize**, pero el desglose se inventa en el momento en que se hace la pregunta, no se planifica de antemano |
| **SGBD columnar** | Almacena cada campo como un flujo separado | **Sin análogo directo**, pero lee solo los campos que pides. Cambiar un solo valor, en cambio, es caro |
| **ClickHouse** | Un SGBD columnar; aquí, un servicio gestionado del catálogo | no un reemplazo de PostgreSQL, sino un complemento |
| **MergeTree** | La forma principal de almacenar tablas en ClickHouse | los datos se guardan en partes, y las partes se fusionan periódicamente en otras más grandes |
| **Clave de ordenación (`ORDER BY`)** | El orden en que los datos se disponen dentro de las partes | **El orden de los archivos en disco**, pero es el único «índice» real. Hay una por tabla, y la eliges de antemano |
| **Interfaz HTTP** | Una manera de hablar con ClickHouse mediante una petición HTTP corriente | la consulta sale como texto en el cuerpo de un POST, la respuesta vuelve como una tabla |

El resto de los términos de este lab —OLTP, SGBD por filas, parte (part), mutación, shard, réplica,
Keeper— se introducen sobre la marcha, en el paso donde se necesitan por primera vez. No hace falta
memorizarlos ahora: separados de la acción no se quedan.

<details>
<summary><b>Si prefieres ver la lista completa de una vez</b></summary>

| Término | Qué es | Como… pero |
|---|---|---|
| **OLTP** | Una carga de trabajo de «muchas operaciones pequeñas»: crear una solicitud, cambiar un estado | **vCenter trabajando con su propia base de datos**, pero cada operación toca un puñado de filas: solo que son muchas |
| **SGBD por filas** | Almacena los registros enteros, fila tras fila | **Archivos en un datastore: cada uno está entero**, pero justo por eso una fila es fácil de cambiar y una columna difícil de sumar rápido |
| **Parte (part)** | Un trozo de datos en disco producido por una sola inserción | no las tocas a mano, pero su número y tamaño explican el comportamiento |
| **Mutación** | Un cambio o borrado de filas diferido | no se hace in situ: reescribe partes enteras, en segundo plano |
| **Shard** | Una porción de los datos en un conjunto de servidores aparte | sobre volumen, no sobre fiabilidad |
| **Réplica** | Una copia completa de los datos | **Una réplica de datastore**, pero sobre fiabilidad, no volumen |
| **Keeper** | El servicio a través del cual las copias se coordinan entre sí | **Un disco de quórum**, pero solo hace falta cuando hay más de una copia |

</details>

## Qué hay en la carpeta del lab

Ya tienes todos los archivos: los recibiste con el repositorio. No hay nada que crear ni volver a
teclear: allí donde más abajo diga `kubectl apply -f name.yaml`, el archivo viene de aquí.

```bash
cd labs/09-clickhouse
```

| Archivo | Qué es | Cuándo lo usarás |
|---|---|---|
| `clickhouse.yaml` | El pedido de una base de datos analítica: lo mismo que el botón del panel | lo aplicas **en el tenant**, no en el clúster `lab` |
| `01-schema.sql` | La tabla para los eventos de entrada | lo ejecutas en la base de datos |
| `02-generate.sql` | Generación de un millón de filas, para tener algo que calcular | lo ejecutas a continuación |
| `03-report.sql` | El informe en sí: «cuántos invitados y cuándo están los picos» | lo ejecutas al final |
| `check.sh` | Una comprobación de que el informe realmente se calcula, y en un tiempo razonable | lo ejecutas al final del lab |

## Paso 1. Pide ClickHouse

📍 **Dónde:** en el navegador, en el panel de Cozystack, en tu tenant.

Tenant → **Create application** → `ClickHouse`.

| Campo | Valor | Por qué |
|---|---|---|
| Name | `analytics` | corto: lo estarás tecleando en direcciones más adelante |
| Replicas | **1** | un entorno de pruebas de formación. Son copias del **servidor**, no de los datos; mira la advertencia de abajo |
| Shards | **1** | un millón de filas es poco. Se hace shard cuando los datos no caben en un solo servidor |
| Size | `5Gi` | un millón de filas ocupa unos pocos megabytes; el resto es margen |
| Log storage size | `2Gi` | el volumen para los registros de texto del propio servidor, `/var/log/clickhouse-server` |
| Log TTL | `15` | el registro de consultas de más de quince días se descarta |
| Storage class | `replicated` | los datos acabarán en tres copias en nodos distintos |
| Resources preset | `u1.small` | 1 procesador, 4 GB. Las agrupaciones se calculan en memoria |
| Users | usuario `analyst`, inventa una contraseña | es el usuario con el que trabajaremos |
| ClickHouse Keeper → enabled | **desactívalo** | Keeper coordina las copias entre sí. Hay una copia: nada que coordinar |

> ⚠️ **Una copia del servidor no es una copia de los datos.** El campo `Replicas` levanta varios
> servidores ClickHouse, pero las tablas en sí no se replican: un `MergeTree` corriente, que
> crearemos en el paso siguiente, vive en el servidor donde se creó. Pon dos réplicas con una tabla
> así y las inserciones irán a un servidor, mientras que las consultas caerán unas veces en él y
> otras en su vecino vacío.
>
> Para que los datos realmente se dupliquen, creas la tabla como `ReplicatedMergeTree`, y la
> coordinación necesita Keeper activado. Ese es un tema aparte, y no tiene sentido en un entorno de
> pruebas de formación; pero necesitas conocer esta diferencia antes de poner un dos en producción.

⚠️ **Inventa una contraseña como es debido y anótala.** La necesitarás más adelante, tanto en
comandos como en el script de comprobación. Después puedes consultarla en el panel:
aplicación `analytics` → la pestaña **Secrets** → `clickhouse-analytics-credentials`.

⚠️ **Keeper está activado por defecto, y ese es el valor correcto.** En cuanto hay más de una copia,
necesitan un sitio donde ponerse de acuerdo sobre quién escribió qué. Nosotros tenemos una copia, y
tres copias de Keeper malgastarían los recursos del entorno de pruebas para nada. Si no ves esta
casilla en tu formulario, despliega la sección con los parámetros adicionales.

### Una mirada más de cerca: qué hay dentro de clickhouse.yaml

La carpeta del lab contiene `clickhouse.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: ClickHouse
metadata:
  name: analytics
  namespace: tenant-workshopXX
spec:
  replicas: 1
  shards: 1
  size: 5Gi
  logStorageSize: 2Gi
  logTTL: 15
  storageClass: replicated
  resourcesPreset: u1.small
  users:
    analyst:
      password: TuContraseñaAquí
  backup:
    enabled: false
  clickhouseKeeper:
    enabled: false
```

`apiVersion: apps.cozystack.io/v1alpha1`: el catálogo de Cozystack visto desde el lado en que parece
una API. Cuando pulsas el botón, el panel ensambla exactamente este objeto.

`namespace: tenant-workshopXX`: **los servicios gestionados viven en tu tenant en el clúster de
gestión, no en el clúster de laboratorio del lab 0.** Son dos clústeres distintos, y tendrás que
tenerlo presente durante el resto del lab.

`shards` y `replicas` son dos cosas distintas que la gente confunde constantemente. **Los shards son
sobre volumen:** los datos se reparten entre conjuntos de servidores, cada uno con su propia porción.
**Las réplicas son sobre fiabilidad:** cada una guarda todo por completo. Un millón de filas son unos
pocos megabytes: no hay nada que fragmentar.

`users`: un mapa de usuarios. ClickHouse creará `analyst` con la contraseña indicada y lo pondrá en
el Secret `clickhouse-analytics-credentials`, que es visible en el panel.

⚠️ Junto a tu usuario, en este Secret aparecerá otro: `backup`. El chart lo crea por sí mismo, para
el mecanismo de copias de seguridad. No necesitas tocarlo.

`backup.enabled: false`: en el lab no hacen falta las copias de seguridad. En producción es lo
primero que activas.

`clickhouseKeeper.enabled: false`: mira arriba, lo de la copia única.

Este archivo se aplica **no al clúster de laboratorio** sino al tenant:

```bash
# --kubeconfig nombra el archivo de acceso de forma explícita y anula la variable KUBECONFIG.
# Así el pedido va al tenant en el clúster de gestión, no al clúster de laboratorio.
kubectl --kubeconfig ~/.kube/config apply -f clickhouse.yaml
```

El acceso de gestión al tenant ya está configurado en este bastion: el archivo `~/.kube/config`
(basado en token, no se abre ningún navegador). No hay nada que descargar ni guardar.

Espera a que esté listo. Son de dos a cuatro minutos: el servidor arranca, se crea el volumen, se
configura el usuario.

## Paso 2. Prepara un Pod de trabajo

📍 **Dónde:** en el bastion, en el clúster de laboratorio.

Aquí hay que detenerse y entender la disposición.

**Un Pod** es la unidad de ejecución más pequeña de Kubernetes: uno o más contenedores que siempre
viven y mueren juntos. El análogo más cercano de vSphere es una máquina virtual, solo que sin su
propio sistema operativo y sin su propio disco. De aquí en adelante esta palabra aparece
constantemente.

**ClickHouse vive en tu tenant en el clúster de gestión.** Tu rol en el tenant te permite pedir y
eliminar servicios, pero no ejecutar tus propios Pods allí ni reenviar puertos. Esto no es una
avería, sino un límite.

**Tu zona de trabajo es el clúster de laboratorio del lab 0.** Desde ahí llegaremos a ClickHouse, por
su dirección interna:

```
chendpoint-clickhouse-analytics.tenant-workshopXX.svc.cozy.local:8123
```

Desglosemos el nombre en partes:

| Parte | Qué significa |
|---|---|
| `chendpoint-` | un prefijo que el operador de ClickHouse añade a su Service |
| `clickhouse-` | un prefijo que el catálogo de Cozystack añade al nombre de la aplicación |
| `analytics` | el nombre que pusiste en el panel |
| `tenant-workshopXX` | tu tenant. Sustituye por tu propio número |
| `svc.cozy.local` | la zona de nombres internos del clúster de gestión |
| `8123` | el puerto de la interfaz HTTP. También está el 9000, para el protocolo nativo |

Levanta el Pod de trabajo. Sustituye tu número de tenant y tu contraseña:

```bash
# Todo lo que sigue ocurre en el clúster de laboratorio, así que cambiamos kubectl a él.
export KUBECONFIG=~/lab.kubeconfig
# run crea un único Pod a partir de la imagen indicada: una pequeña máquina desechable dentro del clúster.
# La imagen trae curl, y con eso basta: no hará falta un cliente ClickHouse aparte.
#   --restart=Never  no volver a levantarlo cuando el comando de dentro termine
#   --env=CH_URL     la dirección de la interfaz HTTP del almacenamiento; la barra final es obligatoria
#   --env=CH_AUTH    el par «usuario:contraseña» para la autenticación HTTP corriente
#   --command --     todo lo que va tras los dos guiones es el comando que ejecutará el Pod
# sleep 86400 = «no hacer nada durante un día»: el Pod solo se necesita como espacio de trabajo.
kubectl run ch-workbench \
  --image=curlimages/curl:8.11.1 \
  --restart=Never \
  --env=CH_URL="http://chendpoint-clickhouse-analytics.tenant-workshopXX.svc.cozy.local:8123/" \
  --env=CH_AUTH="analyst:TuContraseñaAquí" \
  --command -- sleep 86400
# wait retiene la terminal hasta que el Pod arranca, pero no más de dos minutos.
kubectl wait --for=condition=Ready pod/ch-workbench --timeout=120s
```

**Por qué la dirección y la contraseña son variables del Pod y no van directamente en el comando.**
Todo lo que tecleas en `kubectl exec` acaba en el historial de tu shell y en la lista de procesos del
nodo. Las variables del Pod se fijan una sola vez, y después la contraseña no vuelve a aparecer en los
comandos.

⚠️ **Esto no resuelve el problema por completo, y es más honesto decirlo de entrada.** Un valor pasado
por `--env` queda en la descripción del Pod: es visible para cualquiera con derecho a leer Pods en tu
namespace, reside en la base de datos del clúster y acaba en el registro de auditoría. Para un entorno de
pruebas de formación es aceptable; para uno de producción no lo es: allí la contraseña va a un objeto
aparte del clúster (`Secret`: un objeto pensado para valores sensibles) y se adjunta mediante una
referencia a él, mientras que el objeto mismo se rellena desde un almacén de secretos. De eso trata el
lab sobre secrets.

Ahora preparemos un comando corto para no tener que teclear `curl` cada vez. Primero desmontemos de
qué está hecho.

<details>
<summary><b>Desmontando este comando, pieza a pieza</b></summary>

`kubectl exec -i ch-workbench`: ejecutar algo dentro del Pod de trabajo. El flag `-i` reenvía la
entrada estándar hacia dentro: sin él, la consulta no llegará a ClickHouse.

`sh -c '…'` entre comillas simples: la cadena se pasa hacia dentro tal cual, y `$CH_AUTH` se expande
**dentro del Pod**, desde la variable del Pod. Tu bastion no ve estos valores y no los escribe en el
historial de comandos.

`curl -sS`: en silencio, pero informando de los errores. `-s` quita el indicador de progreso, `-S`
recupera los mensajes de error que `-s` se tragaría en otro caso.

`-u "$CH_AUTH"`: el usuario y la contraseña. ClickHouse acepta la autenticación HTTP corriente.

`--data-binary @-`: «toma el cuerpo de la petición de la entrada estándar tal cual». Así es
exactamente como el SQL llega a ClickHouse: **la consulta es el cuerpo de una petición POST
corriente**, no un protocolo especial. De ahí un corolario: para llegar a ClickHouse no necesitas un
driver. Con `curl` basta, y eso a menudo ayuda cuando estás depurando un problema.

`?default_format=PrettyCompact`: la forma en que devolver la respuesta. `PrettyCompact` es una tabla
para un humano. Hay más de treinta formatos; más abajo necesitaremos `JSON`.

</details>

```bash
# Definimos ch: un nombre corto para un comando largo. A partir de aquí «ch» significa: enviar a
# ClickHouse el SQL que llega por la entrada estándar, y mostrar la respuesta como una tabla.
# El nombre vive hasta que cierras esta ventana de terminal; en una ventana nueva vuelve a definirlo.
ch() {
  kubectl exec -i ch-workbench -- sh -c \
    'curl -sS -u "$CH_AUTH" --data-binary @- "$CH_URL?default_format=PrettyCompact"'
}
```

Comprobemos la conexión:

```bash
# echo imprime una cadena, | la pasa a la entrada de ch. SELECT version() es la consulta más barata
# posible: el servidor no lee nada del disco, solo dice su versión.
echo 'SELECT version()' | ch
```

**Lo que deberías ver**: el número de versión de ClickHouse en un pequeño marco.

⚠️ **Si el comando queda en silencio o falla con `Could not resolve host` / `Connection refused`**: no
tiene sentido seguir adelante. Causas comunes, en orden decreciente de probabilidad: no sustituiste
`workshopXX` por tu propio número; la aplicación en el panel aún no está lista; una errata
en el nombre del servicio. Si la respuesta es `Authentication failed`, la conexión está ahí pero la
contraseña es incorrecta: recrea el Pod con el `CH_AUTH` correcto.

Usuarios de Windows PowerShell, vuestra versión:

```powershell
# $input: lo que entró en la función a través de la tubería de la izquierda.
# El acento grave al final de una línea continúa el comando en la línea siguiente.
function ch {
  $input | kubectl exec -i ch-workbench -- sh -c `
    'curl -sS -u "$CH_AUTH" --data-binary @- "$CH_URL?default_format=PrettyCompact"'
}
"SELECT version()" | ch
```

## Paso 3. Crea la tabla del registro de entradas

📍 **Dónde:** en el bastion, en el clúster de laboratorio.

Preparamos una tabla para el registro de entradas: una fila por cada paso por el torniquete. El
archivo `01-schema.sql` está en la carpeta del lab, y conviene leerlo antes de aplicarlo: dos líneas
de él determinan qué consultas resultarán rápidas después y cuáles no.

<details>
<summary><b>Recorriendo el esquema línea por línea</b></summary>

```sql
-- IF NOT EXISTS: no protestar si la tabla ya existe. El archivo puede aplicarse dos veces.
CREATE TABLE IF NOT EXISTS passes
(
    pass_id      UInt64,                 -- el número del pase
    created_at   DateTime,               -- cuándo pasó la persona por el torniquete
    guest_name   String,                 -- el nombre del invitado: cada uno tiene el suyo
    host_dept    LowCardinality(String), -- el departamento del anfitrión: pocos valores
    entrance     LowCardinality(String), -- la entrada: hay tres
    pass_type    LowCardinality(String), -- de un solo uso, semanal, de vehículo
    duration_min UInt16                  -- cuántos minutos estuvo dentro el invitado
)
ENGINE = MergeTree               -- cómo almacenar: partes en disco, fusión en segundo plano
ORDER BY (created_at, entrance)  -- en qué orden colocar los datos; también el índice
```

`UInt64`, `UInt16`: enteros sin signo de 8 y 2 bytes. En ClickHouse eliges el tamaño de un tipo de
forma deliberada: mil millones de filas por cuatro bytes de más son cuatro gigabytes. Para una
duración en minutos, dos bytes sobran.

`LowCardinality(String)`: una cadena con pocos valores distintos. Tenemos tres nombres de entrada y
cinco departamentos. ClickHouse almacena tales campos como un diccionario: en disco hay números, no
palabras repetidas un millón de veces. El ahorro es enorme, y lo veremos en cifras.

⚠️ **La regla es esta:** hasta unos pocos miles de valores distintos, `LowCardinality`; más que eso,
un `String` normal. Envolver en `LowCardinality` el nombre de un invitado, que casi siempre es único,
significa empeorar las cosas: el diccionario crecería más que los propios datos.

`ENGINE = MergeTree`: la forma principal de almacenar. Cada inserción coloca una nueva **parte** en
disco, y las partes se fusionan en otras más grandes en segundo plano. De ahí, por cierto, una regla
práctica importante: hay que insertar **en lotes de muchas filas**, no de una en una. Un millón de
inserciones de una sola fila crearían un millón de partes y tumbarían el servidor.

```sql
ORDER BY (created_at, entrance)
```

Esta es la línea más importante del archivo, y la eliges antes de empezar a escribir datos.

`ORDER BY` fija **el orden en que los datos se asientan físicamente en disco**. También funciona como
el único índice real: ClickHouse mantiene marcas cada pocos miles de filas y las usa para averiguar
qué partes del archivo puede saltarse por completo sin leerlas.

La consulta «cuántas entradas hubo en marzo» se convierte en «lee este tramo del archivo». La consulta
«encuentra la entrada con número 424242» no se convierte en nada: `pass_id` no está en la clave de
ordenación, así que tendrá que leer la columna entera. Lo veremos en un paso aparte, y no es un
defecto de la implementación, sino una consecuencia directa del diseño.

**Una analogía de un mundo conocido.** La clave de ordenación es como decidir en qué orden archivar
los pases de papel en el archivo: por fecha o por apellido. Archívalos por fecha y la carpeta de marzo
se saca al instante, mientras que a un tal Ivanov se lo encuentra pasándolos uno a uno. Y nadie va a
reordenar un millón de hojas a posteriori.

</details>

**Aplícalo.**

```bash
# < lee el archivo y lo pasa a la entrada de ch, es decir, envía el contenido del archivo
# a ClickHouse en una sola consulta. CREATE TABLE devuelve una respuesta vacía: eso es éxito.
ch < 01-schema.sql
```

## Paso 4. Genera un millón de registros

📍 **Dónde:** en el bastion, en el clúster de laboratorio.

No tenemos datos de entradas, y necesitamos un millón. Los generaremos dentro del propio ClickHouse:
sin exportaciones, scripts ni archivos intermedios. Primero veamos de qué está hecho el generador.

<details>
<summary><b>Recorriendo el generador línea por línea</b></summary>

```sql
INSERT INTO passes
SELECT …
FROM numbers(1000000)
```

`numbers(1000000)`: una tabla generadora integrada: un millón de filas con una única columna `number`
de 0 a 999999. No lee nada del disco, no existe en la realidad, se calcula al vuelo. Es un truco
estándar: cualquier dato de prueba en ClickHouse se hace así.

```sql
    number AS pass_id,
```

El número del pase. Único, porque `number` es único.

```sql
    addDays(
        toDateTime('2026-01-01 00:00:00'),
        toUInt16(sqrt(cityHash64(number, 'day') % 57600))
    )
```

`cityHash64(number, 'day')`: una función hash rápida. A partir del número de una fila produce un
número pseudoaleatorio, y la misma entrada siempre da el mismo resultado. El segundo argumento,
`'day'`, es la «sal»: con una sal distinta el mismo número da un resultado distinto. Así es como, a
partir de un único `number`, hacemos tantos valores aleatorios independientes como queramos.

`% 57600` da un número de 0 a 57599, y su `sqrt` da de 0 a 239, es decir, un día dentro de ocho meses.
La raíz cuadrada aquí no es por estética: **concentra los datos hacia el final del período**. Los
invitados se vuelven más numerosos con el tiempo, como en la vida, y es justo lo que la dirección
quiere ver en el informe.

```sql
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
```

La hora de llegada. En lugar de un uniforme «de 8 a 18» tomamos un valor de un array donde las horas
se repiten con distintas frecuencias: el diez aparece tres veces, el quince tres veces, el ocho solo
una. Esto produce **dos picos pronunciados**: antes del almuerzo y después. Son justo lo que la
dirección nos pidió encontrar, y está bien que los datos de prueba contengan lo que vamos a buscar.

⚠️ La indexación de arrays en ClickHouse empieza en uno, no en cero. De ahí el `1 + …`.

```sql
    ['Norte', 'Norte', 'Norte',
     'Sur', 'Sur', 'Oeste'][1 + cityHash64(number, 'entrance') % 6] AS entrance
```

El mismo truco para una distribución desigual: la entrada norte se lleva la mitad del flujo, la sur un
tercio, la oeste el resto. Los datos uniformes parecen inverosímiles en los informes y no muestran
nada.

```sql
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
```

Duración de la visita de 30 a 329 minutos. `toUInt16` es necesario porque el tipo de la columna se
declara de forma explícita, mientras que el resultado de la aritmética es más ancho.

**Cuánto tardó.** Un millón de filas se generaron y escribieron en segundos, enteramente dentro del
servidor. Los datos no viajaron por la red, no pasaron por tu bastion y no quedaron en un archivo
intermedio. Compáralo con la forma habitual de hacer datos de prueba: un script que inserta una fila
cada vez.

</details>

**Aplícalo.**

```bash
# El archivo contiene un único INSERT … SELECT: ClickHouse inventará él mismo un millón de filas y las escribirá,
# sin salir nunca del servidor.
ch < 02-generate.sql
```

**Lo que deberías ver**: una respuesta vacía y el prompt de vuelta al cabo de unos segundos. Una
respuesta vacía de `INSERT` es éxito.

Comprobemos lo que obtuvimos:

```bash
# count() sin condiciones responde a la pregunta «cuántas filas hay en la tabla en total».
echo 'SELECT count() FROM passes' | ch
```

**Lo que deberías ver**: `1000000`.

## Paso 5. El informe que vino a pedir la dirección

📍 **Dónde:** en el bastion, en el clúster de laboratorio.

El informe mismo que la dirección vino a pedir: cuántos invitados hay en cada mes, cuánto dura una
visita de media, a qué hora llega la gente con más frecuencia y qué entrada está más concurrida. El
archivo `03-report.sql` es una sola consulta; la desmontamos antes de ejecutarla.

<details>
<summary><b>Recorriendo el informe línea por línea</b></summary>

```sql
-- Una fila de informe por cada mes que aparece en los datos.
SELECT
    toStartOfMonth(created_at)          AS month,        -- a qué mes asignarlo
    count()                             AS guests,       -- cuántas entradas hay en él
    round(avg(duration_min))            AS avg_minutes,  -- duración media de la visita
    topK(1)(toHour(created_at))[1]      AS peak_hour,    -- la hora de llegada más frecuente
    topK(1)(entrance)[1]                AS busiest_entrance  -- la entrada más frecuente
FROM passes
GROUP BY month   -- colapsar todas las filas de un mes en una sola fila de respuesta
ORDER BY month   -- sacar los meses en orden ascendente
```

`toStartOfMonth` convierte un instante exacto en el primer día del mes. Un truco clásico para agrupar
por período: en lugar de «agrupar por año y mes», un único valor por el que agrupamos y ordenamos a la
vez.

`count()`: cuántas filas cayeron en el grupo. Eso es exactamente «cuántos invitados por mes».

`topK(1)(x)[1]`: el valor más frecuente de `x` en el grupo. `topK(1)` devuelve un array de un
elemento, `[1]` lo extrae. Así es como tanto la hora pico como la entrada más concurrida acaban en una
sola fila de informe.

Conviene señalar aparte lo que la consulta no tiene: subconsultas, tablas temporales ni joins. Todo se
calcula en una sola pasada sobre los datos.

</details>

**Aplícalo.**

```bash
# Una agrupación sobre toda la tabla. La respuesta tendrá tantas filas como meses
# aparezcan en los datos.
ch < 03-report.sql
```

**Lo que deberías ver**: ocho filas, una por mes, con un número creciente de invitados.

Ahora lo principal: **cuánto tardó en calcularse**. El formato `JSON` al final de la consulta añade un
bloque de estadísticas a la respuesta:

```bash
# <<'SQL' … SQL: una forma de pasar texto de varias líneas a la entrada de un comando, sin archivo.
# Las comillas alrededor de SQL significan «deja el contenido en paz»: si no, el shell intentaría
# interpretar los caracteres de dentro de la consulta como suyos.
ch <<'SQL'
-- El mismo informe, recortado a dos columnas: mes y número de invitados.
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM passes
GROUP BY month
ORDER BY month
FORMAT JSON  -- devolver la respuesta no como tabla sino como JSON: contiene un bloque de estadísticas
SQL
```

Desplaza la salida hasta el final:

```json
    "statistics": {
        "elapsed": 0.0089,
        "rows_read": 1000000,
        "bytes_read": 4000000
    }
```

**Un millón de filas, unos nueve milisegundos.** Tu cifra será la tuya, pero el orden es el mismo:
unidades o decenas de milisegundos.

<details>
<summary><b>Cómo se haría este mismo informe en una base de datos corriente</b></summary>

Toma el escenario conocido: el registro de entradas está en PostgreSQL o MS SQL, justo al lado del
propio servicio de pases.

**Qué le pasa a la consulta.** Una base de datos por filas almacena un registro entero: número, hora,
nombre del invitado, departamento, entrada, tipo, duración, todo en una fila, uno tras otro. Para
calcular `count()` por mes tiene que recorrer cada fila, lo que significa **leer todos los campos del
disco**, incluidos los nombres de los invitados que no figuran en el informe. En un millón de filas
son decenas de segundos; en diez millones, minutos.

Puedes sortearlo con un índice sobre `created_at`, un índice de cobertura, una vista materializada o
una tabla preagregada. Cada una de estas soluciones funciona, y cada una significa: alguien tuvo que
**saber de antemano qué informe se iba a pedir**. Pide un desglose distinto y vuelves al punto de
partida.

**Qué le pasa al servicio.** Una consulta pesada compite por el disco y la memoria con la carga de
producción. Mientras se calcula el informe, los guardias de la entrada ven un indicador girando. De
ahí viene la regla «informes solo de noche», y de ella: una réplica de lectura, una exportación
nocturna, cifras que no cuadran y la pregunta «por qué el informe muestra los datos de ayer».

**Qué hace la gente en la práctica.** Levantan una segunda base de datos al lado, construida para
analítica, y vuelcan los datos en ella. Es exactamente lo que acabamos de hacer, salvo que la segunda
base de datos surgió en diez minutos desde un catálogo en vez de a lo largo de un trimestre con un
proyecto de despliegue.

| | Por filas (PostgreSQL) | Columnar (ClickHouse) |
|---|---|---|
| Buscar un pase por número | microsegundos, mediante el índice | lee la columna entera |
| Cambiar el estado de un pase | microsegundos | reescribe partes en segundo plano |
| Contar invitados por mes | segundos o minutos | milisegundos |
| Añadir una fila | rutinario | mejor en lote; de una en una es malo |
| Transacciones | de pleno derecho | ninguna en el sentido habitual |

Ninguna columna es «mejor». Son herramientas para trabajos distintos, y la respuesta correcta es casi
siempre ambas, cada una en su sitio.

</details>

## Paso 6. Por qué es rápido: una mirada a las columnas

📍 **Dónde:** en el bastion, en el clúster de laboratorio.

La palabra «columnar» suena abstracta hasta que ves las cifras.

```bash
ch <<'SQL'
-- Le preguntamos al propio ClickHouse cuánto espacio ocupa cada columna de la tabla.
SELECT
    name,                                                    -- el nombre de la columna
    formatReadableSize(data_compressed_bytes)   AS on_disk,  -- cuánto ocupa en disco
    formatReadableSize(data_uncompressed_bytes) AS raw,      -- cuánto sería sin compresión
    round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio  -- cuántas veces se comprimió
FROM system.columns   -- una tabla de sistema: en ella ClickHouse se describe a sí mismo
WHERE database = currentDatabase() AND table = 'passes'   -- solo nuestra tabla
ORDER BY data_compressed_bytes DESC   -- las columnas más pesadas arriba
SQL
```

**Lo que deberías ver**: aproximadamente este cuadro:

```
name          on_disk    raw       ratio
guest_name    5.20 MiB   13.4 MiB  2.6
pass_id       3.81 MiB   7.63 MiB  2.0
created_at    1.20 MiB   3.81 MiB  3.2
duration_min  1.10 MiB   1.91 MiB  1.7
entrance      35.1 KiB   1.00 MiB  29.2
pass_type     41.0 KiB   1.05 MiB  26.1
host_dept     52.3 KiB   1.10 MiB  21.4
```

Tus cifras serán las tuyas, pero las proporciones son las mismas.

<details>
<summary><b>Qué se ve aquí y por qué explica la velocidad</b></summary>

**Primero: cada campo se asienta por separado.** Eso es lo que significa «columnar». En una base de
datos por filas, el disco va «fila 1 entera, fila 2 entera, fila 3 entera». Aquí es «todo `created_at`
de seguido, todo `entrance` de seguido, todo `guest_name` de seguido».

De ahí la consecuencia por la que se emprendió todo esto: **una consulta lee solo los campos que
menciona.** El informe mensual necesita `created_at` y un contador de filas. Leerá algo más de un
megabyte y no tocará los nombres de los invitados, que ocupan cinco veces más.

Una base de datos por filas leerá todo para la misma consulta. No porque esté mal escrita, sino porque
los campos están entremezclados: para llegar a la hora de la fila 500001 hay que leer el bloque que
guarda la hora junto con todo lo demás.

**Segundo: mira el `ratio` de `entrance`.** Veintinueve veces. Un millón de valores extraídos de tres
opciones comprimidos hasta casi nada.

Así funciona `LowCardinality`: en disco hay un diccionario de tres cadenas y un millón de números
pequeños, y junto a eso la compresión general, para la que números idénticos seguidos son un regalo.
Para `guest_name`, donde cada valor es distinto, la compresión es solo de dos veces y media.

**Tercero, y esto rompe la intuición: la compresión acelera las cosas, no las frena.** Parece que
descomprimir es trabajo de más. En la práctica el cuello de botella es el disco, no el procesador:
leer 35 kilobytes y descomprimirlos es más rápido que leer un megabyte. Por eso las bases de datos
columnares comprimen de forma agresiva y ganan dos veces: en espacio y en tiempo.

</details>

Confirmemos que la consulta realmente lee poco. Contaremos sobre una única columna pequeña:

```bash
ch <<'SQL'
-- Contamos las visitas de más de cien minutos. La consulta nombra una columna de siete, así que
-- debería leer solo una pequeña parte de la tabla. Lo comprobaremos por bytes_read.
SELECT count() FROM passes WHERE duration_min > 100 FORMAT JSON
SQL
```

Mira `bytes_read` al final de la salida y compáralo con el volumen de datos de la tabla:

```bash
ch <<'SQL'
-- Sumamos el volumen sin comprimir de todas las columnas. Eso es exactamente «cuántos datos hay en total»:
-- la cifra con la que hay que comparar el bytes_read de la salida anterior.
SELECT formatReadableSize(sum(data_uncompressed_bytes)) AS total
FROM system.columns
WHERE database = currentDatabase() AND table = 'passes'
SQL
```

⚠️ **Hay que comparar con el volumen sin comprimir, no con el tamaño en disco.** `bytes_read` en las
estadísticas de la consulta es lo que la base de datos descomprimió y leyó: una cifra sin comprimir.
Divídelo por `bytes_on_disk` y obtienes una fracción de los datos comprimidos, y en una tabla con
buena compresión tal «fracción» supera con facilidad el cien por cien. Las cifras tienen que ser
comparables, de lo contrario el número es bonito pero no significa nada.

La consulta pasó por un millón de filas leyendo apenas un pequeño porcentaje de los datos: leyó
`duration_min` y no tocó `guest_name`.

## Paso 7. Encontrar los picos

📍 **Dónde:** en el bastion, en el clúster de laboratorio.

La segunda mitad de la pregunta de la dirección es sobre la cola en la entrada. Contaremos cuántas
entradas cayeron en cada hora del día y lo dibujaremos como barras directamente en la terminal. La
consulta tiene dos partes; la desmontamos antes de ejecutarla.

<details>
<summary><b>Desmontando la consulta</b></summary>

La consulta interior es una agrupación corriente: cuántas entradas cayeron en cada hora del día. Salen
once filas.

La exterior les añade una imagen. `bar(value, from, to, width)` dibuja una barra de pseudográficos:
una función integrada de ClickHouse hecha precisamente para que puedas mirar el resultado en la
terminal sin abrir Excel.

`max(guests) OVER ()`: una función de ventana: el máximo sobre **todo el resultado**, no sobre un
grupo. Los paréntesis vacíos tras `OVER` significan «la ventana es el conjunto entero de filas». Hace
falta para que la barra más larga sea exactamente de cincuenta caracteres, y el resto sean
proporcionales.

Por qué no podías escribir simplemente `max(guests)` sin `OVER ()`: sería una función de agregación, y
colapsaría las once filas en una. La función de ventana calcula lo mismo pero deja las filas en su
sitio.

</details>

```bash
ch <<'SQL'
SELECT
    hour,                                     -- la hora del día
    guests,                                   -- cuántas entradas cayeron en esta hora
    bar(guests, 0, max(guests) OVER (), 50) AS chart  -- una barra de pseudográficos
FROM
(
    -- La consulta interior: una agrupación corriente por hora
    SELECT toHour(created_at) AS hour, count() AS guests
    FROM passes
    GROUP BY hour
)
ORDER BY hour   -- horas ascendentes, para que la imagen se lea de arriba abajo
SQL
```

**Lo que deberías ver**: dos jorobas: en torno a las diez de la mañana y en torno a las tres de la
tarde.

La respuesta para la dirección está lista: picos a las 10 y a las 15, y es justo en estas horas donde
tiene sentido poner a una segunda persona en la entrada.

Ya que estás, mira el registro de consultas: ClickHouse registra ahí cada consulta:

```bash
ch <<'SQL'
-- ClickHouse registra cada consulta ejecutada en la tabla de sistema system.query_log.
SELECT
    event_time,                                       -- cuándo terminó la consulta
    query_duration_ms,                                -- cuántos milisegundos tardó
    formatReadableQuantity(read_rows) AS rows_read,   -- cuántas filas leyó
    formatReadableSize(read_bytes)    AS bytes_read,  -- cuántos bytes levantó al hacerlo
    -- El texto de la consulta: colapsamos en él los saltos de línea y tomamos los primeros 50 caracteres,
    -- de lo contrario la salida no cabe en la pantalla
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 50) AS query
FROM system.query_log
WHERE type = 'QueryFinish'  -- solo las terminadas: hay un registro aparte para el inicio
  AND user = 'analyst'      -- solo las tuyas, sin las consultas de servicio del propio servidor
ORDER BY event_time DESC    -- las recientes arriba
LIMIT 10                    -- y con diez basta
SQL
```

Todo el historial de tus consultas, con duración y volumen leído. Es una tabla corriente, y vive en el
volumen de datos, no en el de registros: `Log storage size` del formulario de pedido es sobre los registros de
texto del servidor, no sobre este registro. El período de retención del registro lo fija `Log TTL`. En
producción es justamente esta tabla la que responde a la pregunta «por qué ayer a las siete de la
tarde todo iba lento».

⚠️ El registro se vuelca a disco una vez cada pocos segundos, así que la consulta más reciente puede que aún
no esté en él. Repite el comando.

## Un fallo predecible · Buscar un único pase por número

Los informes están listos. Seguridad viene con una petición cotidiana: **encuentra la entrada con
número 424242.**

La consulta se sugiere sola:

```bash
ch <<'SQL'
-- Buscamos una única fila por número de pase. SELECT * significa «devolver todas las columnas».
SELECT * FROM passes WHERE pass_id = 424242 FORMAT JSON
SQL
```

La fila se encontrará. Pero no mires a ella sino a las estadísticas al final de la salida: a
`rows_read`.

> **Detente y piensa antes de seguir leyendo.**
>
> ¿Cuántas filas leyó la base de datos para devolver una? ¿Cuántas leería PostgreSQL con un índice
> sobre `pass_id`? ¿Y por qué la diferencia es exactamente así de grande?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

`rows_read` será de unos **1 000 000**. Para devolver una sola fila, ClickHouse leyó la columna
`pass_id` entera.

La razón es la que ya trabajamos un poco antes en el lab: **el único índice real en ClickHouse es la
clave de ordenación**, y la nuestra es `(created_at, entrance)`. Los datos no están ordenados por
`pass_id`, no hay por qué saltarse partes, y lo único que queda es un escaneo completo.

PostgreSQL con un índice sobre `pass_id` leería unas pocas páginas de árbol y una fila. Una diferencia
de cinco órdenes de magnitud, y no a favor de ClickHouse.

Ahora lo mismo, pero bien hecho. Seguridad suele saber no solo el número sino también **cuándo
ocurrió**:

```sql
-- La misma búsqueda, pero con un marco temporal. La condición sobre created_at cae
-- en la clave de ordenación, y ClickHouse descarta todo lo que quede fuera de ese día.
SELECT * FROM passes
WHERE created_at >= '2026-03-01' AND created_at < '2026-03-02'
  AND pass_id = 424242
FORMAT JSON
```

Mira `rows_read` ahora: unos pocos miles en lugar de un millón. La condición sobre `created_at` cayó
en la clave de ordenación, y ClickHouse descartó todas las partes salvo el tramo necesario. Puede que
el pase no se encuentre si fue en un día distinto: lo que importa no es el hallazgo sino el número de
filas leídas.

**Una lección más amplia que este error.** ClickHouse no es una «base de datos rápida». Es una base de
datos construida para un tipo de trabajo: leer muchas filas a través de unas pocas columnas y calcular
algo. En ese trabajo adelanta a las bases de datos por filas por órdenes de magnitud. En lo contrario
—encontrar una fila, cambiar un campo, revertir una transacción— se queda atrás por otros tantos
órdenes de magnitud.

De ahí una regla práctica que vale la pena llevarse:

| Tarea | Dónde |
|---|---|
| Pedir un pase, cambiarlo, cancelarlo | Una base de datos corriente al lado del servicio |
| Buscar un pase concreto por número | El mismo sitio |
| Un informe anual, embudos, picos, tendencias | ClickHouse |
| Un registro de eventos, métricas, registros | ClickHouse |

Ambas bases de datos en un tenant, ambas del catálogo, ambas levantadas en minutos. Ya no hace falta
elegir «una para todo», y ese es, quizá, el cambio principal frente a un mundo donde cada nueva base
de datos significaba una nueva VM y una nueva solicitud.

</details>

## Paso 8. Honestamente sobre lo que aquí resulta incómodo

📍 **Dónde:** en el bastion, en el clúster de laboratorio.

Un invitado cambió de apellido; hay que corregir un registro. En una base de datos corriente eso es un
`UPDATE` y microsegundos.

Fíjate en la sintaxis de antemano: no `UPDATE passes SET …` sino `ALTER TABLE … UPDATE`. Esto no es un
capricho de los autores sino una advertencia honesta: **lo que ejecutas no es una actualización de
fila sino un cambio en la tabla.**

```bash
ch <<'SQL'
-- Cambiamos el nombre de un invitado en una fila. El comando devuelve el control de inmediato, pero el trabajo
-- no termina ahí: ClickHouse lo pondrá en cola y lo llevará a cabo en segundo plano.
ALTER TABLE passes UPDATE guest_name = 'Herrera J.' WHERE pass_id = 424242
SQL
```

Veamos qué ocurre:

```bash
ch <<'SQL'
-- La cola de cambios diferidos de la tabla: otra tabla de sistema de ClickHouse.
SELECT
    command,       -- qué se le ha ordenado hacer exactamente
    is_done,       -- 1 si el trabajo está terminado
    parts_to_do,   -- cuántas partes quedan por reescribir
    create_time    -- cuándo se puso la tarea en la cola
FROM system.mutations
WHERE table = 'passes'
ORDER BY create_time DESC
SQL
```

<details>
<summary><b>Qué es una mutación y por qué es cara</b></summary>

El comando devolvió el control de inmediato, mientras que el trabajo se puso en cola. Ese trabajo
diferido se llama **mutación**, y se ve en `system.mutations`: `is_done` muestra si está terminado,
`parts_to_do`, cuántas partes quedan por reescribir.

Por qué reescribir. Los datos se asientan en columnas dentro de partes comprimidas. No se puede
cambiar un solo valor dentro de un bloque comprimido: el bloque hay que descomprimirlo, cambiarlo,
comprimirlo y escribirlo de nuevo. En la práctica ClickHouse reescribe **la parte entera**, con todas
sus columnas.

En nuestro millón de filas eso son fracciones de segundo, y `is_done` lo más probable es que ya sea
`1`. En una tabla de mil millones de filas la misma operación son horas de trabajo de disco y el doble
de uso de espacio mientras dura la reescritura.

De ahí las reglas que en el mundo de ClickHouse se dan por sentadas:

- **No se cambian los datos.** Se añaden. El registro de entradas no debería cambiar de todos modos:
  una entrada o bien ocurrió o bien no
- Si un registro sí necesita corrección, escribes una nueva versión de la fila y al leer tomas la más
  reciente. Hay un tipo de tabla aparte para esto (`ReplacingMergeTree`)
- El borrado de datos antiguos se hace no con una consulta sino con un período de retención (`TTL`):
  «descartar filas de más de tres años». Entonces se borran partes enteras, no filas individuales
- Las ediciones masivas se juntan en una sola operación poco frecuente en lugar de cien pequeñas

**Y lo que aquí falta por completo: las transacciones en el sentido habitual.** Transferir dinero de
una cuenta a otra de forma que ambas operaciones se apliquen o ninguna lo haga no se puede hacer en
ClickHouse. Esto no es una carencia de la implementación: es una renuncia deliberada en aras de la
velocidad de lectura. Es justo por eso que ClickHouse no se coloca debajo del servicio de pases sino
al lado.

</details>

## Verificación

📍 **Dónde:** en el bastion, en la misma ventana de terminal donde trabajaste con `kubectl`.

```bash
cd labs/09-clickhouse
# El script lee estas tres variables de entorno, así que debes fijarlas antes de ejecutarlo
# y en la misma ventana de terminal.
export KUBECONFIG=~/lab.kubeconfig       # qué clúster comprobar
export COZY_TENANT=workshop03            # tu número de tenant
export CH_PASSWORD='tu-contraseña-analyst'  # la que pusiste al pedir ClickHouse
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell; cómo instalarlo se describe al
principio del lab 0. Puedes completar el lab sin WSL, pero no habrá informe de artefacto.

El script no comprueba el hecho de que el servicio se haya creado, sino el trabajo en sí: la tabla
existe, hay no menos de un millón de filas, los datos tienen picos pronunciados, el informe mensual se
calcula en milisegundos, y una consulta sobre una única columna lee una pequeña fracción de la tabla.

La contraseña no llega al informe.

## Limpieza

```bash
# El Pod de trabajo no guarda nada: todo el trabajo ocurrió dentro de ClickHouse, y el Pod solo
# fue pasando consultas. Elimínalo sin remordimientos.
kubectl delete pod ch-workbench
```

El propio ClickHouse se elimina en el panel: aplicación `analytics` → delete.

Por qué esto es barato. Una base de datos analítica en la infraestructura clásica es una VM (más
probablemente tres), discos, instalación, configuración, monitorización y una persona responsable de
todo ello. No la puedes devolver: el espacio ya está asignado, la licencia comprada, y «¿y si nos hace
falta?». Aquí tomaste un servicio durante una hora y lo devolviste en diez segundos, y el espacio que
ocupaba quedó liberado.

⚠️ **Al eliminarlo se borra también la tabla.** Un millón de filas se regeneran en segundos, así que en
el lab no es pérdida alguna. Si metiste algo real ahí, activa antes las copias de seguridad: son una
sección aparte del formulario de pedido.

## Qué sabemos hacer ahora

- Explicar la diferencia entre una base de datos por filas y una columnar no con palabras sino con
  cifras de compresión y bytes leídos
- Levantar ClickHouse desde el catálogo y entender por qué el formulario tiene shards, réplicas y
  Keeper
- Elegir una clave de ordenación de forma deliberada y predecir qué consultas serán rápidas
- Generar datos de prueba verosímiles dentro de la base de datos, sin scripts ni exportaciones
- Responder a la pregunta «cuándo están los picos» con una consulta en lugar de una exportación a Excel
- Entender dónde pierde ClickHouse, y no ponerlo donde hace falta una base de datos corriente

## Y en vSphere esto sería

Una máquina aparte para la base de datos analítica, y resulta casi de inmediato que con una no basta:
necesitas una segunda para la réplica y espacio para las exportaciones diarias. El informe «cuántos
invitados al mes» se convierte en un proyecto de infraestructura con su propio hardware, su propia
monitorización y su propio dueño.

Aquí: una entrada de catálogo y diez minutos, incluida la generación de un millón de filas.

**Dónde vSphere es más cómodo, honestamente.** Una VM con una base de datos es una máquina a la que
puedes acercarte. Entrar por SSH, mirar el top, ajustar una configuración, dejar un script al lado,
tomar una instantánea antes de una operación arriesgada y revertir si no funcionó. Un servicio gestionado
no te da esto **a propósito**: en el tenant no se te permitirá ni hacer `exec` en un Pod ni entrar en
los registros. Gestionas el servicio a través del formulario de pedido, no a través de la máquina que hay
debajo.

Mientras todo funciona, esto es una ventaja: menos maneras de romper cosas. Cuando algo se comporta de
forma extraña, esta limitación se siente con intensidad: el conjunto habitual de acciones del
administrador no está disponible, y lo único que queda es recurrir a quien opera la plataforma. El registro
de consultas y las métricas cubren parte de este dolor, pero no todo, y pretender que lo cubren todo
sería deshonesto.

Y una segunda cosa que la gente recuerda después. Un servicio gestionado significa los valores por
defecto de otro. La versión de ClickHouse, los parámetros de fusión de partes, los ajustes de memoria
se eligen por ti. Normalmente con criterio, a veces no para tu carga de trabajo, y no podrás
cambiarlos con tanta libertad como en tu propia máquina.
