# Laboratorio 10 · Almacén de documentos

| | |
|---|---|
| **Tiempo** | 45 minutos |
| **Qué demuestra** | Los datos de formas distintas pueden almacenarse sin columnas vacías y sin una tabla aparte para cada caso — y se paga por ello con disciplina |
| **Qué necesitarás** | El clúster del laboratorio 0 y `~/lab.kubeconfig`; acceso al panel de tu tenant; un número de tenant con la forma `workshopXX`; disposición para leer código JavaScript |

> ⚠️ **Este laboratorio es denso y te pide leer código JavaScript.** Abórdalo con la mente
> fresca, no justo después de otro laboratorio largo. El código se explica línea por línea en
> todas partes — no necesitas conocer el lenguaje de antemano.

## Por qué esto importa

El servicio «Pase» se desplegó con un único tipo de pase — un pase de una sola vez para una
fecha concreta. Un mes después el cliente volvió con precisiones, todas razonables:

| Tipo de pase | Qué más se necesita |
|---|---|
| De una sola vez | fecha, entrada |
| Semanal | un período desde/hasta, una lista de entradas, una marca de si se devolvió la credencial |
| De vehículo | número de matrícula, modelo, si lleva remolque, peso, número de plaza de estacionamiento |
| De grupo | organización, persona de contacto, acompañante, una lista de participantes con sus edades |

En una tabla con columnas fijas este problema tiene dos soluciones, y ambas son malas.

**Solución uno: una única tabla con todas las columnas.** Agregas `car_plate`, `car_model`,
`trailer`, `weight_kg`, `parking`, `valid_from`, `valid_to`, `badge_returned`,
`organization`, `contact`, `escort` — y un pase de una sola vez tiene once campos vacíos de
quince. Medio año después hay treinta columnas, nadie recuerda cuáles de ellas son
obligatorias para qué tipo, y el primer campo `NOT NULL` rompe la mitad de los escenarios.

**Solución dos: una tabla por tipo.** Cuatro tablas en lugar de una, más una quinta que las
une para que seguridad pueda mostrar una lista combinada en el control de acceso. Cada nuevo
tipo de pase significa una migración de esquema, un lanzamiento y una aprobación. Y la
consulta «muéstrame todos los pases de hoy» se convierte en un `UNION` de cuatro piezas que
hay que editar cuando agregas una quinta.

**La lista de participantes de un pase de grupo no cabe en ninguna de las dos.** Es de
longitud variable, así que necesita otra tabla más con una referencia de vuelta al pase.

Hay un tercer camino: un almacén que no exige que todos los registros tengan la misma forma.
En este laboratorio levantaremos MongoDB, pondremos en él cuatro pases de cuatro formas
distintas y buscaremos entre ellos. Y luego miraremos con honestidad qué pagamos por ello —
porque pagamos, y no poco.

Los términos de Kubernetes y MongoDB se explican en este laboratorio cuando aparecen por
primera vez, y algunos están reunidos en el pequeño glosario de abajo.

## Mini-glosario

| Término | Qué es | Como… pero |
|---|---|---|
| **Documento** | Un solo registro. Un conjunto de campos, objetos anidados y listas | **Una fila de tabla**, pero el registro vecino puede tener un conjunto de campos distinto, y eso no es un error |
| **Colección** | Un conjunto de documentos | **Una tabla**, pero no tiene esquema por defecto. Puedes agregar un esquema, pero esa es una decisión aparte |
| **BSON** | El formato binario en que se almacenan los documentos | Como JSON, pero con tipos: una fecha es una fecha, no una cadena |
| **Conjunto de réplicas** | Varias copias, una primaria, el resto toman el relevo | **Un clúster con HA**, pero las copias votan entre sí, así que se necesita un número impar de ellas |
| **`mongosh`** | El shell de comandos de MongoDB | **PowerCLI**, pero es JavaScript completo, no un lenguaje de consultas |

El resto de las palabras de este laboratorio — _id, Sharding, notación de campo con puntos,
índice disperso, validador de esquema, $lookup — se introducen sobre la marcha, en el paso
donde primero se necesitan. No hay necesidad de memorizarlas ahora: separadas de la acción no
se quedarán.

<details>
<summary><b>Si quieres ver toda la lista de una vez</b></summary>

| Término | Qué es | Como… pero |
|---|---|---|
| **`_id`** | La clave única del documento | **Una clave primaria**, pero se crea sola si no la defines |
| **Sharding** | Dividir los datos entre conjuntos de réplicas | Sobre volumen, no sobre fiabilidad |
| **Notación de campo con puntos** | Alcanzar un campo anidado a través de un punto: `car.plate` | **Una ruta de archivo en una carpeta**, pero también llega dentro de listas: `members.age` |
| **Índice disperso** | Un índice que incluye solo los documentos donde el campo está presente | Una necesidad simple y llana donde el campo está presente solo en una minoría de registros |
| **Validador de esquema** | Una regla que el documento está obligado a cumplir | **La validación de un formulario antes de guardar**, pero se activa manualmente y a posteriori — no hay esquema por defecto |
| **`$lookup`** | Una forma de traer datos de otra colección | **Un JOIN**, pero unidireccional y notablemente más caro: la unión no la elige un optimizador, se lleva a cabo por fuerza bruta |

</details>

## Qué hay en la carpeta del laboratorio

Ya tienes todos los archivos — los obtuviste junto con el repositorio. No hay nada que crear
ni volver a escribir: dondequiera que abajo diga `kubectl apply -f nombre.yaml`, el archivo se
toma de aquí.

```bash
cd labs/10-mongodb
```

| Archivo | Qué es | Cuándo lo necesitarás |
|---|---|---|
| `mongodb.yaml` | El pedido de una base de datos de documentos — lo mismo que el botón en el panel | lo aplicas **en el tenant**, no en el clúster `lab` |
| `passes.js` | Llenar la base de datos con pases de distintos tipos: de una sola vez, semanal, de vehículo | lo ejecutas en la base de datos |
| `validator.js` | Reglas para validar documentos — para que no entre basura en la base de datos | lo ejecutas a continuación |
| `check.sh` | Una comprobación de que documentos de distintas formas conviven lado a lado y los no aptos se rechazan | lo ejecutas al final del laboratorio |

## Paso 1. Pedir MongoDB

📍 **Dónde:** en el navegador, en el panel de Cozystack, en tu tenant.

Tenant → **Create application** → `MongoDB`.

| Campo | Valor | Por qué |
|---|---|---|
| Name | `passes` | corto — luego tendrás que escribirlo en direcciones |
| Version | `v8` | la rama actual |
| Replicas | **1** | un entorno de pruebas de formación. Por qué en producción son tres, justo abajo |
| Size | `5Gi` | cuatro documentos ocupan bytes, el resto es margen |
| Storage class | `replicated` | los datos se guardarán en tres copias en nodos distintos |
| Resources preset | `s1.small` | 1 procesador, 2 GB |
| Sharding | desactivado | se hace sharding cuando los datos no caben en un solo servidor |
| Users | el usuario `passapp`, define la contraseña **explícitamente** | es con el que trabajaremos |
| Databases | la base de datos `passes`, con `passapp` en el rol admin | sin un rol el usuario no será aceptado |
| External | desactivado | no lo exponemos hacia afuera |

⚠️ **Asegúrate de definir la contraseña a mano y anótala.** Si dejas el campo vacío, el chart
generará una contraseña por su cuenta — y la pondrá en un Secret que no se ve en el panel. Te
quedarás con una base de datos funcional a la que no puedes conectarte.

Dos palabras que encontrarás más de una vez de aquí en adelante. **Un chart** es el plano que
la plataforma usa para desplegar un servicio: un conjunto de plantillas más los valores que
rellenaste en el formulario. Lo más parecido es una plantilla de máquina virtual con un
asistente de configuración. **Un Secret** es un objeto del clúster que guarda contraseñas y
claves; en el panel se muestra como una pestaña aparte en la ficha de la aplicación.

⚠️ **Un usuario sin rol significa un fallo en el despliegue.** Si creas `passapp` en la sección
Users pero no le otorgas un rol en ninguna base de datos en la sección Databases, el chart se
detendrá con el error «user is not assigned to any database role». Esto no es una avería sino
una protección contra un usuario inútil, aunque el mensaje no se encuentra de inmediato.

⚠️ **Una sola copia no es MongoDB en su forma normal, y vale la pena entender por qué.**
MongoDB está diseñada para un conjunto de tres réplicas: eligen una primaria por votación, y
perder una no detiene el trabajo. Una votación requiere mayoría, por eso el número de copias
se hace impar. Con una sola copia no hay con quién votar, y para esto el chart activa un modo
especial `unsafeFlags`. En el laboratorio esto ahorra recursos del entorno de pruebas; en
producción no se debe hacer así.

### Una mirada más de cerca: qué hay dentro de mongodb.yaml

La carpeta del laboratorio contiene `mongodb.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: MongoDB
metadata:
  name: passes
  namespace: tenant-workshopXX
spec:
  replicas: 1
  size: 5Gi
  storageClass: replicated
  resourcesPreset: s1.small
  version: v8
  external: false
  sharding: false
  users:
    passapp:
      password: TuContraseñaAquí
  databases:
    passes:
      roles:
        admin:
          - passapp
  backup:
    enabled: false
```

`namespace: tenant-workshopXX` — **los servicios gestionados viven en tu tenant en el clúster
de gestión, no en el clúster de laboratorio del laboratorio 0.** Son dos clústeres distintos.

`users` y `databases` son dos mapas enlazados, y el enlace entre ellos es obligatorio.
`users` enumera las cuentas, `databases` enumera las bases de datos y quién puede hacer qué en
ellas. `roles.admin` otorga el derecho de leer, escribir y cambiar la estructura dentro de una
sola base de datos; `roles.readonly` — solo leer.

⚠️ Los usuarios se crean en la base de datos de servicio `admin`, pero los privilegios se
otorgan en la tuya. Por eso la cadena de conexión necesitará `authSource=admin` — más sobre
esto por separado en el siguiente paso.

`sharding: false` — un conjunto de réplicas ordinario. Activar el sharding agrega servidores
de configuración y enrutadores: tres o cuatro Pods de más para una división de datos que no
necesitamos.

Este archivo se aplica **no al clúster de laboratorio** sino al tenant — lo que significa que
el archivo de acceso también debe ser el del tenant. El kubeconfig (el archivo con la
dirección del clúster y los datos de inicio de sesión) se toma del panel: **Info → la pestaña
Secrets → `kubeconfig-tenant-workshopXX`**. Guárdalo en `~/.kube/workshop` — esta ruta se usa
en todos los laboratorios.

Ahora pedimos la base de datos como texto. El comando no instala nada por sí mismo: entrega el
pedido a la plataforma, y la plataforma levanta todo lo necesario de su lado.

```bash
# apply = «lleva el clúster a lo que se describe en el archivo».
#   --kubeconfig ~/.kube/workshop  qué archivo de acceso usar. Sin él, kubectl
#                                  tomará el acceso por defecto y se irá al clúster equivocado
#   -f mongodb.yaml                qué archivo aplicar (-f = file)
kubectl --kubeconfig ~/.kube/workshop apply -f mongodb.yaml
```

**Lo que deberías ver** — `mongodb.apps.cozystack.io/passes created`. La palabra `created`
significa que el pedido fue aceptado, no que la base de datos esté lista.

La preparación tarda de tres a cinco minutos: el servidor se levanta, se inicializa el
conjunto de réplicas, se crean los usuarios. Puedes ver cómo van las cosas así:

```bash
# get = «muéstrame lo que hay». La columna READY dirá si el pedido alcanzó un estado operativo.
#   -n tenant-workshopXX  en qué namespace mirar (un namespace es un tabique dentro
#                         del clúster; tu tenant es justamente uno de esos namespace aparte)
kubectl --kubeconfig ~/.kube/workshop get mongodb passes -n tenant-workshopXX
```

⚠️ **El Secret `mongodb-passes-credentials` en el panel tendrá una contraseña vacía durante
los primeros minutos.** Contiene las credenciales de la cuenta de servicio `databaseAdmin`, y
el chart las rellena solo después de que el operador (el programa de la plataforma que lleva
el pedido a un estado operativo y luego lo vigila) haya creado los usuarios — es decir, en la
siguiente vuelta de reconciliación del estado. Espera unos minutos y actualiza la página. No
necesitaremos esta cuenta: trabajamos con `passapp`, cuya contraseña definiste tú mismo.

## Paso 2. Crear un Pod de trabajo

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

La disposición es la misma que en los otros laboratorios sobre servicios gestionados.

**MongoDB vive en tu tenant en el clúster de gestión.** Tu rol en el tenant te permite pedir y
eliminar servicios, pero no ejecutar tus propios Pods allí ni reenviar puertos.

**Tu terreno de trabajo es el clúster de laboratorio del laboratorio 0.** Desde ahí iremos,
por la dirección interna:

```
mongodb-passes-rs0.tenant-workshopXX.svc.cozy.local:27017
```

| Parte | Qué significa |
|---|---|
| `mongodb-` | el prefijo que el catálogo de Cozystack agrega al nombre de la aplicación |
| `passes` | el nombre que definiste en el panel |
| `-rs0` | el nombre del conjunto de réplicas. El operador nombra así el servicio del primer conjunto |
| `tenant-workshopXX` | tu tenant. Sustituye por tu propio número |
| `svc.cozy.local` | la zona de nombres internos del clúster de gestión |
| `27017` | el puerto estándar de MongoDB |

**Un Pod** es la unidad de ejecución más pequeña en Kubernetes: uno o varios contenedores que
siempre viven en el mismo nodo y comparten una sola dirección. El análogo más cercano es una
máquina virtual levantada para una sola tarea, salvo que se crea en segundos y se apaga sin
pena. Levantaremos un Pod así con la imagen `mongo:8.0`: dentro está `mongosh` — el shell de
comandos de MongoDB — y no tendrás que instalarlo en tu laptop.

La dirección de la base de datos junto con el nombre de usuario y la contraseña se escribe en
una sola línea — se llama cadena de conexión. Recorrámosla antes de escribir el comando.

<details>
<summary><b>Recorriendo la cadena de conexión</b></summary>

```
mongodb://passapp:contraseña@host:27017/passes?authSource=admin&directConnection=true
```

`mongodb://` — el esquema. Después el nombre de usuario, la contraseña, la dirección, el
puerto.

`/passes` después del puerto — **la base de datos por defecto**. Te conectas y quedas
inmediatamente en ella, sin un comando aparte.

`authSource=admin` — **en qué base de datos buscar la cuenta misma.** El usuario `passapp` se
crea en la base de datos de servicio `admin`, mientras que sus privilegios se otorgan en
`passes`. Sin este parámetro el driver irá a buscar la cuenta en `passes`, no la encontrará y
devolverá «Authentication failed» — un mensaje que parece «contraseña incorrecta» y desvía la
búsqueda por el camino equivocado. Este es el error más común en una primera conexión a una
MongoDB gestionada.

`directConnection=true` — «conéctate directo a este servidor, no intentes averiguar la
composición del conjunto de réplicas». Sin este parámetro el driver le preguntará al servidor
quién más está en el conjunto, y recibirá los nombres internos de los miembros, que no siempre
se resuelven desde afuera. Con una sola copia no hay nada que averiguar, así que es más simple
decirlo directamente. En producción con tres copias es al revés: no se pone el parámetro,
porque lo que se quiere ahí es justamente el cambio automático a una nueva primaria cuando la
vieja falla.

**Por qué la dirección y la contraseña van en una variable del Pod y no directamente en el
comando.** Todo lo que escribas en `kubectl exec` termina en el historial de tu shell y en la
lista de procesos del nodo. La variable del Pod se define una vez, y después de eso la
contraseña no aparece en los comandos.

Esto no resuelve el problema por completo, y es más honesto decirlo de entrada: un valor
pasado a través de `--env` queda en la especificación del Pod — visible para cualquiera que
tenga derecho a leer Pods en tu namespace, está en la base de datos del clúster y llega al
registro de auditoría. Para un entorno de pruebas de formación es aceptable, para uno de
producción no: ahí la contraseña se pone en un Secret y se conecta a través de `envFrom`. De
eso trata justamente el laboratorio sobre secretos.

</details>

Levanta el Pod. Sustituye `workshopXX` por tu número de tenant y `TuContraseñaAquí` por tu
contraseña:

```bash
# KUBECONFIG — qué archivo de acceso usa kubectl. Aquí es el clúster de laboratorio
# del laboratorio 0: tus propios Pods los lanzas solo en él, al tenant no te dejarán entrar con esto.
export KUBECONFIG=~/lab.kubeconfig

# run = «crea un solo Pod y ejecuta esta imagen en él». Las banderas que importan:
#   --image=mongo:8.0        qué ejecutar. La imagen contiene el shell mongosh
#   --restart=Never          crear exactamente un único Pod, no un Deployment. De lo contrario
#                            el clúster lo volvería a levantar cada vez que terminara
#   --env=MONGO_URI=...      una variable de entorno dentro del Pod. La contraseña queda en ella,
#                            en lugar de repetirse en cada comando siguiente
#   --command -- sleep 86400 con qué mantener ocupado el contenedor. La imagen mongo por defecto iniciaría
#                            el servidor de la base de datos — no lo necesitamos, necesitamos un contenedor vivo
#                            en el que se pueda entrar. 86400 segundos es un día
kubectl run mongo-workbench \
  --image=mongo:8.0 \
  --restart=Never \
  --env=MONGO_URI="mongodb://passapp:TuContraseñaAquí@mongodb-passes-rs0.tenant-workshopXX.svc.cozy.local:27017/passes?authSource=admin&directConnection=true" \
  --command -- sleep 86400

# wait = «no devuelvas el control hasta que se cumpla la condición»
#   --for=condition=Ready  esperamos hasta que el Pod informe por sí mismo que está listo
#   --timeout=180s         cuánto esperar antes de devolver un error en lugar de colgarse para siempre
kubectl wait --for=condition=Ready pod/mongo-workbench --timeout=180s
```

**Lo que deberías ver** — `pod/mongo-workbench created`, y a continuación
`pod/mongo-workbench condition met`.

Ahora definamos un comando corto para no tener que escribir todo esto cada vez, y comprobemos
la conexión con la base de datos:

```bash
# mo — un atajo que vive hasta que cierras la ventana de la terminal: así se
# declara un comando propio en el shell.
#   exec        ejecutar algo dentro de un Pod que ya está corriendo
#   -i          reenviar hacia adentro la entrada estándar: sin ella no se puede pasar un programa
#   sh -c '...' ejecutamos un shell en el Pod para que él mismo sustituya $MONGO_URI.
#               Las comillas son simples a propósito: quien debe sustituir la variable es el Pod, no
#               tu terminal — de lo contrario la contraseña termina en el historial de comandos
#   --quiet     no imprimir el saludo de mongosh, dejar solo la respuesta
mo() { kubectl exec -i mongo-workbench -- sh -c 'mongosh --quiet "$MONGO_URI"'; }

# ping — una solicitud de servicio, «¿estás vivo?». No lee ni escribe nada, comprueba la conexión
# y que las credenciales fueron aceptadas. El signo | envía esta línea a la entrada de mongosh
echo 'db.runCommand({ ping: 1 })' | mo
```

**Lo que deberías ver** — `{ ok: 1 }`.

`mongosh` lee el programa desde la entrada estándar, así que este mismo comando puede tragarse
archivos enteros: `mo < passes.js`.

⚠️ **Si la respuesta es `Authentication failed`** — la conexión está pero las credenciales no
son las correctas. Comprueba en orden: `authSource=admin` en la cadena de conexión; la
contraseña coincide con la que definiste en el panel; el nombre de usuario es `passapp`. Para
recrear el Pod con la cadena corregida: `kubectl delete pod mongo-workbench` y empieza de
nuevo.

⚠️ **Si la respuesta es `getaddrinfo ENOTFOUND` o la conexión se cuelga** — el nombre no se
resuelve. Lo más probable es que no hayas sustituido `workshopXX` por tu propio número, o que
la aplicación en el panel aún no esté lista.

Es más cómodo examinar los datos no comando por comando sino en un shell vivo — permanece
abierto, y las consultas se escriben en él una tras otra:

```bash
# -it en lugar de -i: se agrega una t — «dame una terminal». De ahí el prompt de entrada,
# el historial de comandos con la flecha arriba, y el resaltado. Sin la t el shell esperaría la entrada en silencio.
kubectl exec -it mongo-workbench -- sh -c 'mongosh "$MONGO_URI"'
```

**Lo que deberías ver** — un prompt de la forma `passes>`: el nombre de la base de datos en la
que has caído.

De aquí en adelante los comandos en el texto se muestran tal como se escriben en este shell.
Para salir — `exit`.

## Paso 3. Poner cuatro pases de cuatro formas distintas

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

El archivo `passes.js` es un programa para `mongosh`: agrega cuatro pases a la base de datos e
imprime cuántos documentos resultaron. No hace falta crear ni una sola tabla de antemano, y
justo abajo hay una explicación de por qué.

```bash
cd labs/10-mongodb
# El signo < pasa el contenido del archivo a la entrada del comando — lo mismo que si
# escribieras todo el texto del archivo a mano en el shell de mongosh.
mo < passes.js
```

**Lo que deberías ver** — `документов в коллекции: 4`.

<details>
<summary><b>Recorriendo lo que pusimos</b></summary>

Lo primero que vale la pena notar: **no hubo ningún `CREATE TABLE`**. La colección `passes`
nació en el momento de la primera inserción. No tiene esquema — es decir, por defecto MongoDB
no tiene opinión sobre qué campos puede tener un documento.

Ahora a los documentos.

**El pase de una sola vez** — la forma más corta:

```js
  {
    type: "разовый",
    guest: "Иванов Иван Иванович",
    host: "petrov@corp.ru",
    entrance: "Северная",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "собеседование"
  }
```

Seis campos, todos escalares. En una tabla esto sería una fila ordinaria.

`ISODate(...)` no es una cadena sino precisamente una fecha. MongoDB almacena los documentos
en el formato binario BSON, donde un valor tiene tipo: fecha, entero, de punto flotante,
booleano, datos binarios. Esta es una diferencia importante respecto al JSON simple: por una
fecha se puede comparar y ordenar, por la cadena `"2026-09-01"` solo si se tiene suerte con la
forma en que fue escrita.

**El pase semanal** — en lugar de `valid_on` ahora hay `valid_from` y `valid_to`, y en lugar
de una sola entrada, `entrances` ahora es **una lista**:

```js
    entrances: ["Северная", "Южная"],
    badge_returned: false
```

Una lista directamente en el campo. En una tabla esto habría requerido o bien una tabla aparte
«pase — entrada» o bien una cadena separada por comas que luego nadie podría buscar como es
debido.

El pase de una sola vez no tiene el campo `badge_returned` en absoluto. Ni `NULL`, ni vacío —
**no existe tal campo en este documento.** Son cosas distintas, y se buscan de forma distinta.

**El pase de vehículo** — apareció un **objeto anidado**:

```js
    car: {
      plate: "А123ВС174",
      model: "ГАЗель Next",
      trailer: false,
      weight_kg: 3500
    },
```

Todo lo relacionado con el vehículo está dentro de un único campo `car`. Esto no es una cadena
con JSON dentro, sino una estructura hecha y derecha: se puede buscar por `car.plate` y
construir un índice sobre él.

**El pase de grupo** — **una lista de objetos**:

```js
    members: [
      { name: "Орлов Пётр", age: 16 },
      { name: "Волкова Мария", age: 15 },
      { name: "Зайцев Илья", age: 17 }
    ]
```

Una lista de participantes de longitud variable, cada uno con sus propios campos. Y — fíjate —
este documento **no tiene campo `guest`**: en lugar de un invitado hay una organización y una
persona de contacto. La forma del documento se diferencia de las demás no por un campo sino en
esencia.

Para esto existe justamente el modelo documental. Ni columnas vacías, ni cuatro tablas, ni una
quinta que las una.

</details>

## Paso 4. Buscar entre documentos de distintas formas

📍 **Dónde:** en el shell `mongosh` dentro del Pod de trabajo.

Todo lo que necesitan seguridad y la gerencia son consultas ordinarias. Todas se leen igual:
`db` es la base de datos a la que estás conectado, `passes` es la colección en ella, luego tras
un punto viene la acción, y entre paréntesis está la condición de selección. La condición
siempre se escribe como un objeto: «campo — qué valor debe tener».

**Todos los pases para una fecha concreta:**

```js
// find = «muestra los documentos que cumplen la condición»
// { valid_on: ISODate(...) } — el campo valid_on del documento debe ser igual exactamente a esta
// fecha. ISODate es una fecha, no una cadena: la comparación es por tiempo, no por escritura
db.passes.find({ valid_on: ISODate("2026-09-02T07:30:00Z") })
```

**Lo que deberías ver** — un solo documento, el pase de vehículo de Kuznetsov.

**Solo los pases de vehículo:**

```js
// Una condición sobre un campo de cadena ordinario: coincidencia completa, aquí no existe la insensibilidad a mayúsculas y minúsculas
db.passes.find({ type: "автомобильный" })
```

**Búsqueda por número de matrícula — llegando dentro de un objeto anidado a través de un
punto:**

```js
// "car.plate" — una ruta dentro del documento: el campo plate dentro del objeto car.
// Las comillas alrededor de la ruta son obligatorias, de lo contrario JavaScript leerá el punto a su manera
db.passes.find({ "car.plate": "А123ВС174" })
```

<details>
<summary><b>Por qué esto funciona y en qué se diferencia de «una cadena con JSON dentro»</b></summary>

`"car.plate"` es la notación con puntos para una ruta a un campo. MongoDB entiende la
estructura del documento y puede llegar hacia adentro, en lugar de almacenar el objeto anidado
como un bloque de texto.

La diferencia es práctica. Si `car` estuviera en una tabla relacional como una columna `TEXT`
con JSON dentro, buscar por matrícula significaría `LIKE '%А123ВС174%'` — un escaneo completo
sin índice, con falsos positivos. Aquí es una condición ordinaria sobre la que se puede
construir un índice, y lo haremos.

⚠️ Las comillas alrededor de `"car.plate"` son obligatorias: sin ellas JavaScript leerá el
punto como un acceso a una propiedad de objeto y no entenderá qué se le pide.

</details>

**Pases válidos en varias entradas:**

```js
// entrances no es una cadena sino una lista: ["Северная", "Южная"]. La condición se escribe igual
// que para un campo ordinario, MongoDB misma la comprobará contra cada elemento de la lista
db.passes.find({ entrances: "Южная" })
```

Fíjate: la condición está escrita como si `entrances` fuera un campo ordinario con el valor
`"Южная"`, cuando en realidad es una lista. **MongoDB entiende por sí sola que si un campo es
una lista, la condición debe comprobarse contra cada elemento.** No se requiere una sintaxis
aparte para «contiene».

**Pases de grupo que incluyen menores de edad:**

```js
// La ruta members.age lleva dentro de una lista de objetos — al campo age de cada participante.
// $lt = less than («menor que»). Una condición con $ no es un valor sino una forma de comparar:
// «el campo debe ser menor que 16», no «el campo debe ser igual a 16»
db.passes.find({ "members.age": { $lt: 16 } })
```

La ruta con puntos también funciona hacia dentro de una lista de objetos: la condición se
comprueba contra cada participante. `$lt` — «menor que». Hay cerca de veinte condiciones de
este tipo: `$gt`, `$gte`, `$in`, `$ne`, `$exists`, `$regex`, y así sucesivamente.

**Todos los pases en los que se indica algún vehículo:**

```js
// $exists no pregunta por el valor sino por la mera presencia del campo en el documento:
// «¿tiene este documento un campo car siquiera?»
db.passes.find({ car: { $exists: true } })
```

`$exists` es esa misma distinción entre «el campo está ausente» y «el campo está vacío». En
una tabla esta pregunta no surge: la columna siempre está, la única cuestión es `NULL`.

**Un resumen para la gerencia — cuántos pases de cada tipo.** Aquí la consulta no selecciona
documentos sino que calcula un total sobre ellos, así que el comando es distinto — `aggregate`.
Recorrámoslo antes de escribir.

<details>
<summary><b>Recorriendo la tubería de agregación</b></summary>

La agregación en MongoDB es una **tubería**: una lista de etapas, cada una de las cuales toma
como entrada el resultado de la anterior. Es como una tubería de comandos en un shell, donde
la salida de una va a la entrada de la siguiente.

`$group` — agrupar. `_id: "$type"` significa «la clave de agrupación es el valor del campo
`type`»; el signo de dólar antes del nombre dice «esto es una referencia a un campo, no una
cadena». `$sum: 1` — sumar uno por cada documento, es decir, contarlos.

`$sort: { count: -1 }` — ordenar en orden descendente; `-1` es «descendente», `1` es
«ascendente».

El mismo resultado en SQL — `SELECT type, count(*) FROM passes GROUP BY type ORDER BY 2 DESC`.
Más corto, más familiar, y aquí una comparación honesta va en contra de MongoDB: su lenguaje
de consultas es más verboso y lleva más tiempo dominarlo.

</details>

```js
// aggregate = «pasa los documentos por una cadena de etapas». Las etapas van en orden,
// cada una recibe lo que produjo la anterior:
//   $group — reparte los documentos en grupos por el valor del campo type, y cuenta cada uno
//   $sort  — ordena los grupos por count, -1 significa «descendente»
db.passes.aggregate([
  { $group: { _id: "$type", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
])
```

**Lo que deberías ver** — cuatro filas de la forma `{ _id: 'разовый', count: 1 }`.

## Paso 5. Un índice sobre un campo que la mayoría no tiene

📍 **Dónde:** en el shell `mongosh` dentro del Pod de trabajo.

Seguridad busca por número de matrícula todos los días. Veamos cuánto cuesta esta búsqueda
ahora mismo: la consulta es la misma que antes, pero en lugar de documentos pedimos un informe
de cómo la base de datos los buscó.

```js
// explain = «no me des los documentos, dime cómo los buscaste»
//   "executionStats"     modo de informe: no solo el plan, sino lo que de hecho ocurrió
//   .executionStats      tomamos justamente esta sección de la respuesta, para no leerla toda
// En el informe miramos totalDocsExamined — cuántos documentos leyó la base de datos
// para devolver uno
db.passes.find({ "car.plate": "А123ВС174" }).explain("executionStats").executionStats
```

**Lo que deberías ver** — `totalDocsExamined` es igual al número de documentos en la colección.
La base de datos los recorrió todos para encontrar uno. Con cuatro documentos esto pasa
desapercibido, con cuatrocientos mil ya no.

Construimos un índice — una estructura aparte que la base de datos usa para encontrar los
documentos que necesita sin leerlos todos de corrido:

```js
// createIndex = «construye un índice sobre este campo y mantenlo tú misma de ahora en adelante»
//   { "car.plate": 1 }   sobre qué campo. 1 es el orden «ascendente»
//   name: "car_plate"    cómo nombrar el índice, para poder reconocerlo y eliminarlo después
//   sparse: true         al índice entran solo los documentos que tienen el campo
db.passes.createIndex({ "car.plate": 1 }, { name: "car_plate", sparse: true })

// Repetimos el mismo informe y lo comparamos con el anterior
db.passes.find({ "car.plate": "А123ВС174" }).explain("executionStats").executionStats
```

**Lo que deberías ver** — `totalDocsExamined` es igual a uno, y en el plan apareció `IXSCAN` en
lugar de `COLLSCAN`. Estos son los nombres de los métodos de búsqueda: `COLLSCAN` es un
escaneo de toda la colección, `IXSCAN` es una búsqueda por índice.

<details>
<summary><b>Qué es un índice disperso y por qué está aquí</b></summary>

`{ "car.plate": 1 }` — sobre qué campo construir; `1` significa «ascendente», `-1` —
descendente. Para una búsqueda por coincidencia exacta la dirección no importa; para ordenar,
sí.

`sparse: true` — **al índice entran solo aquellos documentos que tienen el campo.**

Sin esta bandera MongoDB habría creado una entrada de índice también para los tres documentos
sin vehículo, con un valor «campo ausente». El índice se volvería casi el doble de grande, y
esas entradas no servirían para nada en absoluto: nadie busca pases por el criterio «vehículo
no especificado».

En un registro de pases real cerca del diez por ciento son pases de vehículo. Un índice
disperso será diez veces más pequeño que uno ordinario y diez veces más barato de mantener.

⚠️ **Un índice disperso tiene un precio, y hay que conocerlo.** Ordenar por este campo a través
de tal índice perderá los documentos sin el campo — no están en él. En esos casos MongoDB
misma abandonará el índice y recurrirá a un escaneo; lo desagradable es que esto ocurre en
silencio.

**Y ahora el sentido de este paso.** En una base de datos relacional con una sola tabla para
todos los tipos de pase, un índice sobre `car_plate` habría que construirlo sobre una columna
donde el noventa por ciento de las filas son `NULL`. Algunos SGBD meten tales filas en el
índice de todos modos, y este se hincha. Esto se sortea con índices parciales — un mecanismo
del mismo tipo que `sparse`, solo que no disponible en todas partes y no evidente de inmediato.

Así que el problema es uno y el mismo. La diferencia es que aquí no surge como efecto
secundario de «pongamos todos los tipos en una tabla»: no tenemos ninguna columna que haya
habido que crear en aras de una minoría de registros.

</details>

## Un fallo predecible · El pase que no está en la lista

Sigamos trabajando. El guardia de turno en el control de acceso emitió otro pase de una sola
vez — mediante un script escrito con prisas:

```js
// insertOne = «agrega un documento». Qué campos tiene, la base de datos no lo pregunta
db.passes.insertOne({
  tipe: "разовый",
  guest: "Николаев Сергей Игоревич",
  host: "petrov@corp.ru",
  data: ISODate("2026-09-04T09:00:00Z")
})
```

La inserción tuvo éxito: volvió `acknowledged: true` («aceptado») y un nuevo `_id` — la clave
única del documento, que la base de datos ideó por sí misma. Comprobemos que ahora hay cinco
documentos:

```js
// countDocuments = «cuenta los documentos que cumplen la condición».
// Las llaves vacías son una condición sin restricciones, es decir, «todos»
db.passes.countDocuments({})
```

Cinco. Ahora lo que seguridad hace cada mañana — abre la lista de pases de una sola vez:

```js
// La misma selección por tipo que en el paso de búsqueda: mostrar los pases cuyo
// campo type es igual a "разовый"
db.passes.find({ type: "разовый" })
```

> **Detente y piensa antes de seguir leyendo.**
>
> ¿Cuántos pases volvieron? ¿Dónde está el quinto? ¿Qué pasaría con el mismo error en una base
> de datos relacional — y por qué eso es mejor?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

Volvió un pase, no dos. El invitado Nikolaev llegará, seguridad no lo encontrará, y resolverlo
llevará un buen rato — porque el documento **existe**, se **insertó con éxito**, y no se
registró ningún error en ninguna parte.

La causa son dos erratas: `tipe` en lugar de `type` y `data` en lugar de `valid_on`. MongoDB
no las notó, porque **la colección no tiene esquema, y por tanto ninguna opinión sobre qué
campos son correctos.** Para ella, `tipe` es un campo tan legítimo como cualquier otro.

Encontremos a los damnificados — documentos que no tienen el campo `type` en absoluto:

```js
// $exists: false — lo contrario del paso anterior: «el campo no está en el documento».
// Vale la pena tener a mano una consulta así: muestra lo que se ha acumulado al margen del esquema
db.passes.find({ type: { $exists: false } })
```

En una base de datos relacional un `INSERT` con una columna `tipe` fallaría de inmediato:
`column "tipe" does not exist`. El error saldría a la luz en las pruebas, no una semana después
en el control de acceso. **Este es el precio principal de la flexibilidad de esquema: la
comprobación que antes hacía la base de datos ahora debe hacerla alguien más.**

**Una lección más amplia que este error.** Y aquí es importante no sacar la conclusión
equivocada. La conclusión correcta no es «las bases de datos documentales son malas», sino
«que no haya esquema por defecto no significa que no haya esquema en absoluto». Tus datos
siempre tienen un esquema: o está descrito explícitamente, o vive en las cabezas de la gente y
en el código, donde nadie lo comprueba.

Quitemos el documento corrupto y activemos la validación.

</details>

Eliminamos los documentos sin tipo:

```js
// deleteMany = «elimina todos los documentos que cumplen la condición». La condición es la misma
// que en la búsqueda de arriba — lo que significa que se eliminará exactamente lo que acabas de ver
db.passes.deleteMany({ type: { $exists: false } })
```

**Lo que deberías ver** — `deletedCount: 1`.

Ahora activemos la validación — una regla que todo documento está obligado a cumplir. Está en
el archivo `validator.js`; recorrámosla antes de aplicarla.

<details>
<summary><b>Recorriendo la regla</b></summary>

```js
db.runCommand({
  collMod: "passes",
  validator: { $jsonSchema: { … } },
  validationLevel: "strict",
  validationAction: "error"
});
```

`collMod` — cambiar la configuración de una colección existente. El validador se cuelga sobre
una colección viva a posteriori, no hace falta detener nada.

```js
      required: ["type", "host"],
```

Los campos obligatorios. **Fíjate en lo que no está en la lista: `guest`.** El pase de grupo
no tiene invitado, en su lugar una organización. La regla tiene que ser lo bastante amplia
para que una forma de documento legítima pase a través de ella — y esta limitación se siente
de inmediato: cuanto más variados sean tus documentos, menos puedes exigir de todos ellos en
conjunto.

```js
        type: {
          enum: ["разовый", "недельный", "автомобильный", "групповой"],
        },
```

Un valor solo de la lista. Un quinto tipo de pase requerirá cambiar la regla — y eso es bueno:
el cambio se vuelve deliberado.

```js
        car: {
          bsonType: "object",
          required: ["plate"],
          …
        },
```

Las reglas funcionan también sobre objetos anidados. Si el campo `car` está presente, debe
tener un `plate`. Si el campo está ausente — ningún requisito, el documento es legítimo.

```js
  validationLevel: "strict",
  validationAction: "error"
```

`strict` — validar todos los inserts y todas las actualizaciones. Hay uno más suave,
`moderate`: valida los documentos nuevos y las actualizaciones de aquellos que ya cumplen la
regla, mientras que deja en paz a los viejos inválidos. Es con `moderate` como se activa la
validación en una colección donde la inconsistencia ya se ha acumulado: primero dejamos de
empeorarla, luego arreglamos lo viejo, luego pasamos a `strict`.

`error` — rechazar. Hay `warn`: anotarlo en el registro y aceptarlo de todos modos. Sirve para
observar durante una semana cuánto llega antes de activar el rechazo.

</details>

Aplicamos la regla:

```bash
# El mismo truco que con passes.js: el contenido del archivo se pasa a la entrada de mongosh.
# La regla se cuelga sobre una colección viva — no hace falta detener la base de datos
mo < validator.js
```

**Lo que deberías ver** — `правило установлено`.

Intentamos repetir la misma errata — ahora bajo la vigilancia de la regla:

```js
// El campo tipe le es desconocido a la regla, y no hay type obligatorio en el documento.
// Antes, un documento así se posaba silenciosamente en la colección
db.passes.insertOne({ tipe: "разовый", guest: "Проверка", host: "x@corp.ru" })
```

**Lo que deberías ver** — `MongoServerError: Document failed validation`. Ahora la errata no
pasa.

⚠️ **La validación no atrapa todo, y esto hay que decirlo con claridad.** La regla exige que el
campo `type` esté presente y sea de la lista. Una errata en un campo **opcional** — `guestt` en
lugar de `guest` — la dejará pasar: el documento sigue siendo legítimo, solo con un campo de
más. Se pueden prohibir todos los campos desconocidos (`additionalProperties: false`), pero
entonces cada campo nuevo requerirá editar la regla, y volverás justo a aquello de lo que te
estabas librando — una migración de esquema por cada nimiedad. Dónde trazar la línea es una
decisión que tú tomas, y siempre es un compromiso.

## Paso 6. Con honestidad: dónde pierde el modelo documental

📍 **Dónde:** en el shell `mongosh` dentro del Pod de trabajo.

La flexibilidad de esquema no es la única diferencia, y las demás no están a favor de MongoDB.

<details>
<summary><b>No hay joins en la forma habitual</b></summary>

La tarea: para cada pase, traer el número de teléfono y el cargo del empleado que lo pidió.
Los empleados están en una colección aparte `staff`, con la clave en el email.

En SQL esto es una línea: `JOIN staff ON staff.email = passes.host`.

Aquí — una etapa de la tubería:

```js
db.passes.aggregate([
  // $lookup = «para cada pase, ve a otra colección y trae de allí un registro»
  { $lookup: {
      from: "staff",          // adónde ir — la colección de empleados
      localField: "host",     // qué campo del pase comparar
      foreignField: "email",  // con qué campo del empleado
      as: "host_info"         // bajo qué nombre poner lo encontrado en el documento
  } },
  // Lo encontrado siempre se pone como una lista, aunque haya una sola coincidencia.
  // $unwind desenrolla la lista de vuelta a un solo valor
  { $unwind: "$host_info" }
])
```

No tenemos una colección `staff` — la consulta no devolverá nada. Está aquí como muestra de la
sintaxis, no como paso del laboratorio.

Funciona. Pero:

- `$lookup` es **unidireccional**: para cada documento de la izquierda se ejecuta una búsqueda
  a la derecha. Esto no es un optimizador que elegirá un método de unión, sino precisamente una
  búsqueda por fuerza bruta
- el resultado vuelve **como una lista**, aunque haya una sola coincidencia. De ahí `$unwind`,
  para desenrollarla
- unir más de dos colecciones resulta engorroso y lento
- en un despliegue con sharding, hasta hace poco `$lookup` funcionaba con limitaciones

Por eso en el mundo de MongoDB la tarea se resuelve de otra forma: **los datos que se
necesitan juntos se almacenan juntos.** El número de teléfono y el cargo del solicitante se
escriben directamente en el documento del pase.

Y esto es un verdadero compromiso, no una molestia menor:

| | Una referencia a `staff` | Una copia de los datos en el documento |
|---|---|---|
| Lectura | necesita `$lookup` | una sola búsqueda |
| Un empleado cambió su número de teléfono | se corrige en un solo lugar | hay que recorrer todos los pases |
| Integridad | la base de datos la vigila | la aplicación la vigila, es decir, tú |

En una base de datos relacional no hay elección — ahí es normalización y claves foráneas. Aquí
hay elección, y con ella responsabilidad.

</details>

<details>
<summary><b>No hay claves foráneas en absoluto</b></summary>

Pruébalo:

```js
// El campo host, por su significado, se refiere a un empleado. Tal empleado no existe —
// ¿comprobará esto la base de datos? El documento cumple la regla del último paso: type está
// en su sitio y es de la lista, host es una cadena
db.passes.insertOne({ type: "разовый", host: "не-существует@corp.ru", guest: "Тест" })
```

El documento se insertará. No hay ningún empleado con ese email, y la base de datos no lo
mirará.

En una base de datos relacional una clave foránea rechazaría tal fila. Aquí el concepto de
clave foránea no existe en absoluto: **la coherencia de los datos recae por completo en la
aplicación.** El validador del paso anterior comprueba la forma del documento, pero no puede
comprobar que el valor de un campo exista en otra colección.

En la práctica esto significa: cada comprobación de «¿existe tal empleado?» la escribe el
desarrollador, y si la olvidó — te enterarás cuando seguridad intente llamar al solicitante.

No olvides quitar el documento de prueba:

```js
// deleteOne = «elimina un documento que cumple la condición», no todos de una vez
db.passes.deleteOne({ host: "не-существует@corp.ru" })
```

</details>

<details>
<summary><b>Hay transacciones, pero no por defecto</b></summary>

Aquí es importante ser preciso, porque a menudo se dicen cosas falsas sobre MongoDB en ambas
direcciones.

**Cierto:** las transacciones multidocumento sí existen en MongoDB, a partir de la versión 4.0
para conjuntos de réplicas. Se pueden cambiar dos documentos de modo que se apliquen ambos o
ninguno.

**También cierto:** por defecto no están. Una operación sobre **un solo documento** es atómica.
Si quieres más — abre una sesión y comienza explícitamente una transacción:

```js
// Una sesión es una «conversación» aparte con la base de datos, dentro de la cual se puede declarar una transacción
const s = db.getMongo().startSession();
s.startTransaction();          // desde este punto los cambios se acumulan, pero nadie los ve
// … operaciones a través de s.getDatabase("passes") …
s.commitTransaction();         // aplicarlo todo de una vez. Para cancelarlo todo de una vez — abortTransaction()
```

**Y una tercera verdad, la más práctica:** las transacciones en MongoDB son más caras que en
una base de datos relacional, tienen un límite de tiempo, y todo el modelo de datos está
construido sobre el supuesto de que casi no las necesitas. Si tu escenario las requiere a
menudo, es una señal de que los datos deberían haberse dispuesto de otra forma — o de que aquí
no hace falta una base de datos documental.

Para un servicio de pases esto no es problema: un pase es un solo documento, y todas las
operaciones sobre él son atómicas por sí mismas. Para la nómina es un problema, y grande.

</details>

<details>
<summary><b>La inconsistencia de esquema se cuela por sí sola</b></summary>

Ya lo vimos con la errata. Pero hay una variedad más insidiosa: la inconsistencia que se coló
no por un error sino por descuido.

Un año después descubres en la colección que las fechas se almacenan de tres maneras: como
`ISODate`, como la cadena `"2026-09-01"`, y como un número con una marca de tiempo — porque
tres equipos distintos las escribieron en momentos distintos. Una búsqueda por rango sobre
fechas encuentra un tercio de los registros, y nadie entiende por qué.

Puedes ver qué hay realmente en la colección así:

```js
db.passes.aggregate([
  // $$ROOT — el documento entero completo. $objectToArray lo descompone en
  // pares «nombre de campo — valor», para luego trabajar con los campos como datos
  { $project: { fields: { $objectToArray: "$$ROOT" } } },
  // Desenrollamos la lista de pares: un par — una fila en la entrada de la siguiente etapa
  { $unwind: "$fields" },
  // Agrupamos por dos atributos a la vez: el nombre del campo (k) y el tipo de su valor (t),
  // y contamos cuántas veces ocurrió tal combinación
  { $group: { _id: { k: "$fields.k", t: { $type: "$fields.v" } }, n: { $sum: 1 } } },
  { $sort: { "_id.k": 1 } }   // alfabéticamente, para que un campo quede junto a sus propios tipos
])
```

La consulta descompone cada documento en pares «campo — valor», determina el tipo del valor, y
cuenta cuántas veces apareció cada campo con cada tipo. En nuestros cuatro documentos mostrará
un cuadro parejo. En una colección real un año después muestra lo que nadie sospechaba, y es
una de las consultas más útiles al desenredar una base de datos heredada.

**La conclusión que vale la pena llevarse:** un validador de esquema no es un adorno ni una
«formalidad para cumplir el trámite». En una base de datos documental es lo único que se
interpone entre tú y la inconsistencia. Debe activarse de inmediato, no cuando la cosa se
pone desesperada.

</details>

**El balance de una comparación honesta:**

| Tarea | Relacional | Documental |
|---|---|---|
| Registros de la misma forma | natural | también posible, pero para qué |
| Registros de formas distintas | columnas vacías o una tabla por tipo | natural |
| Listas y anidamiento | tablas aparte | un campo en el documento |
| Unión con otros datos | JOIN, un optimizador | `$lookup` o una copia de los datos |
| Integridad referencial | la base de datos la vigila | la aplicación la vigila |
| Transacciones | por defecto | explícitas, más caras, más raras |
| Protección contra erratas | siempre hay un esquema | un validador, si lo activaste |
| Cambiar el esquema | una migración y un lanzamiento | un campo nuevo aparece por sí solo |

## Verificación

📍 **Dónde:** en la laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

El script de verificación se conecta a la base de datos por su cuenta, así que necesita lo
mismo que tú: acceso al clúster de laboratorio, el número de tenant, y la contraseña del
usuario `passapp`. Se pasan como variables de entorno.

```bash
cd labs/10-mongodb
# El mismo archivo de acceso que en los pasos de arriba: el script trabaja desde dentro del clúster lab
export KUBECONFIG=~/lab.kubeconfig
# El número de tenant: a partir de él el script armará la dirección de la base de datos. Sustituye por el tuyo
export COZY_TENANT=workshop03
# La contraseña entre comillas simples: dentro de ellas el shell no toca $, ! ni & dentro de la cadena.
# La contraseña no llega al informe
export MONGO_PASSWORD='tu-contraseña-passapp'
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo configurarlo está
escrito al comienzo del laboratorio 0. Sin WSL igual puedes completar el laboratorio, pero no
habrá artefacto de informe.

El script comprobará no el hecho de la creación del servicio sino el trabajo en sustancia: la
colección tiene documentos de las cuatro formas, la búsqueda por un campo anidado y hacia
dentro de una lista funciona, sobre el campo raro está construido un índice disperso, el
validador de esquema está activado, y no queda ningún documento sin tipo.

La contraseña no llega al informe.

## Limpieza

El Pod de trabajo ya no se necesita — todo este tiempo mantuvo el contenedor ocupado con el
comando `sleep`:

```bash
# delete = «quita del clúster». El Pod desaparece junto con su variable MONGO_URI,
# así que la contraseña no permanece en el clúster
kubectl delete pod mongo-workbench
```

La propia MongoDB se elimina en el panel: la aplicación `passes` → eliminar.

Por qué esto es barato. Un conjunto de réplicas de MongoDB en la infraestructura clásica son
tres máquinas virtuales, instalación, configuración de la votación, monitoreo del retraso de
replicación, y una persona que sabe arreglar todo eso. Aquí tomaste un servicio por una hora y
lo devolviste en diez segundos, y el espacio que ocupaba volvió a la capacidad libre del
clúster — otra persona puede reclamarlo de inmediato.

⚠️ **Los datos desaparecerán junto con la eliminación.** Los cuatro pases se restauran con un
solo comando, así que en el laboratorio esto no es ninguna pérdida. Si pones algo real ahí —
activa primero las copias de seguridad; son una sección aparte en el formulario de pedido.

## Qué sabemos hacer ahora

- Explicar cuándo el modelo documental es apropiado y cuándo es una forma de buscarse problemas
- Pedir MongoDB desde el catálogo y no tropezar con `authSource`, los roles y una sola copia
- Almacenar documentos de formas distintas y buscar por campos anidados y hacia dentro de listas
- Construir un índice disperso y entender con qué paga su ahorro
- Activar un validador de esquema y ver contra qué protege y contra qué no
- Nombrar en voz alta lo que le falta a una base de datos documental: claves foráneas, los
  joins habituales, transacciones por defecto

## Y en vSphere esto sería

Tres máquinas para el conjunto de réplicas, y lo más laborioso de ellas no es la instalación
sino configurar la votación entre las copias: quién es primaria, qué hacer ante la pérdida de
conexión, cómo traer de vuelta a una rezagada. Más una conversación aparte con el equipo de
seguridad de la información sobre quién actualizará esta base de datos dentro de un año.

Aquí — una entrada en el catálogo y cinco minutos.

**Dónde vSphere es más cómodo, con honestidad.** Una máquina virtual con MongoDB es una
máquina a la que puedes acercarte: entrar por SSH, mirar `mongotop`, ajustar la config, tomar
una instantánea antes de una operación arriesgada. Un servicio gestionado no te da esto **a
propósito**: el tenant no te permitirá hacer `exec` en un Pod ni en los registros de la base de
datos. Mientras todo funciona, eso es una ventaja — menos maneras de romperlo. Cuando la base
de datos se comporta de forma extraña, el conjunto habitual de acciones del administrador no
está disponible, y lo único que queda es acudir a quien opera la plataforma.

Y una segunda cosa, específica de MongoDB en particular. Un servicio gestionado fija la versión
y el conjunto de parámetros. Actualizar una versión mayor de MongoDB es una operación que en tu
propia instalación planificas tú mismo, con una comprobación de compatibilidad de la
aplicación y la opción de revertir a una instantánea. Aquí un cambio de versión es un campo en
el formulario y el procedimiento de actualización de otra persona bajo el capó. Normalmente
esto es justamente lo que quieres. Pero el día en que la actualización salga mal, no lo estarás
resolviendo con tus propias manos, y esto hay que entenderlo de antemano, no descubrirlo sobre
la marcha.
