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
ni volver a escribir: dondequiera que abajo diga `kubectl apply -f name.yaml`, el archivo se
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
      password: YourPasswordHere
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
# apply = "bring the cluster to what's described in the file".
#   --kubeconfig ~/.kube/workshop  which access file to use. Without it kubectl
#                                  will take the default access and wander off to the wrong cluster
#   -f mongodb.yaml                which file to apply (-f = file)
kubectl --kubeconfig ~/.kube/workshop apply -f mongodb.yaml
```

**Lo que deberías ver** — `mongodb.apps.cozystack.io/passes created`. La palabra `created`
significa que el pedido fue aceptado, no que la base de datos esté lista.

La preparación tarda de tres a cinco minutos: el servidor se levanta, se inicializa el
conjunto de réplicas, se crean los usuarios. Puedes ver cómo van las cosas así:

```bash
# get = "show me what's there". The READY column will tell you whether the order reached a working state.
#   -n tenant-workshopXX  which namespace to look in (a namespace is a partition inside
#                         the cluster; your tenant is exactly such a separate namespace)
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
mongodb://passapp:password@host:27017/passes?authSource=admin&directConnection=true
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

Levanta el Pod. Sustituye `workshopXX` por tu número de tenant y `YourPasswordHere` por tu
contraseña:

```bash
# KUBECONFIG — which access file kubectl uses. Here it's the lab cluster
# from lab 0: you launch your own Pods only in it, the tenant won't let you in with this.
export KUBECONFIG=~/lab.kubeconfig

# run = "create a single Pod and run this image in it". The flags that matter:
#   --image=mongo:8.0        what to run. The image contains the mongosh shell
#   --restart=Never          create exactly a single Pod, not a Deployment. Otherwise
#                            the cluster would bring it back up every time it finished
#   --env=MONGO_URI=...      an environment variable inside the Pod. The password stays in it,
#                            rather than being repeated in every following command
#   --command -- sleep 86400 what to keep the container busy with. The mongo image would by default start
#                            the database server — we don't need it, we need a live container
#                            you can step into. 86400 seconds is a day
kubectl run mongo-workbench \
  --image=mongo:8.0 \
  --restart=Never \
  --env=MONGO_URI="mongodb://passapp:YourPasswordHere@mongodb-passes-rs0.tenant-workshopXX.svc.cozy.local:27017/passes?authSource=admin&directConnection=true" \
  --command -- sleep 86400

# wait = "don't return control until the condition is met"
#   --for=condition=Ready  we wait until the Pod reports readiness itself
#   --timeout=180s         how long to wait before returning an error rather than hanging forever
kubectl wait --for=condition=Ready pod/mongo-workbench --timeout=180s
```

**Lo que deberías ver** — `pod/mongo-workbench created`, y a continuación
`pod/mongo-workbench condition met`.

Ahora definamos un comando corto para no tener que escribir todo esto cada vez, y comprobemos
la conexión con la base de datos:

```bash
# mo — a shortcut that lives until you close the terminal window: this is how you
# declare your own command in the shell.
#   exec        run something inside an already-running Pod
#   -i          forward standard input inside: without it you can't feed in a program
#   sh -c '...' we run a shell in the Pod so that it substitutes $MONGO_URI itself.
#               The quotes are single on purpose: the Pod should substitute the variable, not
#               your terminal — otherwise the password ends up in the command history
#   --quiet     don't print the mongosh greeting, leave only the answer
mo() { kubectl exec -i mongo-workbench -- sh -c 'mongosh --quiet "$MONGO_URI"'; }

# ping — a service request, "are you alive?". It reads and writes nothing, it checks the connection
# and that the credentials were accepted. The | sign sends this line to mongosh's input
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
# -it instead of -i: a t is added — "give me a terminal". Hence the input prompt,
# command history on the up arrow, and highlighting. Without t the shell would silently wait for input.
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
# The < sign feeds the file's contents into the command's input — the same thing as if you
# typed the whole text of the file by hand in the mongosh shell.
mo < passes.js
```

**Lo que deberías ver** — `documents in collection: 4`.

<details>
<summary><b>Recorriendo lo que pusimos</b></summary>

Lo primero que vale la pena notar: **no hubo ningún `CREATE TABLE`**. La colección `passes`
nació en el momento de la primera inserción. No tiene esquema — es decir, por defecto MongoDB
no tiene opinión sobre qué campos puede tener un documento.

Ahora a los documentos.

**El pase de una sola vez** — la forma más corta:

```js
  {
    type: "single-use",
    guest: "James P. Whitfield",
    host: "petrov@corp.example",
    entrance: "North",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "job interview"
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
    entrances: ["North", "South"],
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
      plate: "AB-1174-CD",
      model: "Ford Transit",
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
      { name: "Peter Hale", age: 16 },
      { name: "Mary Fenwick", age: 15 },
      { name: "Isaac Hart", age: 17 }
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
// find = "show the documents that match the condition"
// { valid_on: ISODate(...) } — the document's valid_on field must equal exactly this
// date. ISODate is a date, not a string: the comparison is by time, not by spelling
db.passes.find({ valid_on: ISODate("2026-09-02T07:30:00Z") })
```

**Lo que deberías ver** — un solo documento, el pase de vehículo de Kuznetsov.

**Solo los pases de vehículo:**

```js
// A condition on an ordinary string field: a whole match, there's no case-insensitivity here
db.passes.find({ type: "vehicle" })
```

**Búsqueda por número de matrícula — llegando dentro de un objeto anidado a través de un
punto:**

```js
// "car.plate" — a path into the document: the plate field inside the car object.
// The quotes around the path are mandatory, otherwise JavaScript will read the dot its own way
db.passes.find({ "car.plate": "AB-1174-CD" })
```

<details>
<summary><b>Por qué esto funciona y en qué se diferencia de «una cadena con JSON dentro»</b></summary>

`"car.plate"` es la notación con puntos para una ruta a un campo. MongoDB entiende la
estructura del documento y puede llegar hacia adentro, en lugar de almacenar el objeto anidado
como un bloque de texto.

La diferencia es práctica. Si `car` estuviera en una tabla relacional como una columna `TEXT`
con JSON dentro, buscar por matrícula significaría `LIKE '%AB-1174-CD%'` — un escaneo completo
sin índice, con falsos positivos. Aquí es una condición ordinaria sobre la que se puede
construir un índice, y lo haremos.

⚠️ Las comillas alrededor de `"car.plate"` son obligatorias: sin ellas JavaScript leerá el
punto como un acceso a una propiedad de objeto y no entenderá qué se le pide.

</details>

**Pases válidos en varias entradas:**

```js
// entrances is not a string but a list: ["North", "South"]. The condition is still written
// as for an ordinary field, MongoDB will check it against each element of the list itself
db.passes.find({ entrances: "South" })
```

Fíjate: la condición está escrita como si `entrances` fuera un campo ordinario con el valor
`"South"`, cuando en realidad es una lista. **MongoDB entiende por sí sola que si un campo es
una lista, la condición debe comprobarse contra cada elemento.** No se requiere una sintaxis
aparte para «contiene».

**Pases de grupo que incluyen menores de edad:**

```js
// The path members.age leads inside a list of objects — to the age field of each participant.
// $lt = less than. A condition with $ is not a value but a way of comparing:
// "the field must be less than 16", not "the field must equal 16"
db.passes.find({ "members.age": { $lt: 16 } })
```

La ruta con puntos también funciona hacia dentro de una lista de objetos: la condición se
comprueba contra cada participante. `$lt` — «menor que». Hay cerca de veinte condiciones de
este tipo: `$gt`, `$gte`, `$in`, `$ne`, `$exists`, `$regex`, y así sucesivamente.

**Todos los pases en los que se indica algún vehículo:**

```js
// $exists asks not about the value but about the very presence of the field in the document:
// "does this document have a car field at all?"
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
// aggregate = "run the documents through a chain of stages". The stages go in order,
// each receiving what the previous one produced:
//   $group — sort the documents into groups by the value of the type field, and count each one
//   $sort  — order the groups by count, -1 means "descending"
db.passes.aggregate([
  { $group: { _id: "$type", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
])
```

**Lo que deberías ver** — cuatro filas de la forma `{ _id: 'single-use', count: 1 }`.

## Paso 5. Un índice sobre un campo que la mayoría no tiene

📍 **Dónde:** en el shell `mongosh` dentro del Pod de trabajo.

Seguridad busca por número de matrícula todos los días. Veamos cuánto cuesta esta búsqueda
ahora mismo: la consulta es la misma que antes, pero en lugar de documentos pedimos un informe
de cómo la base de datos los buscó.

```js
// explain = "don't give me the documents, tell me how you looked for them"
//   "executionStats"     report mode: not only the plan, but what actually happened
//   .executionStats      we take exactly this section from the answer, so as not to read all of it
// In the report we look at totalDocsExamined — how many documents the database read,
// to return one
db.passes.find({ "car.plate": "AB-1174-CD" }).explain("executionStats").executionStats
```

**Lo que deberías ver** — `totalDocsExamined` es igual al número de documentos en la colección.
La base de datos los recorrió todos para encontrar uno. Con cuatro documentos esto pasa
desapercibido, con cuatrocientos mil ya no.

Construimos un índice — una estructura aparte que la base de datos usa para encontrar los
documentos que necesita sin leerlos todos de corrido:

```js
// createIndex = "build an index on this field and keep maintaining it yourself from now on"
//   { "car.plate": 1 }   on which field. 1 is "ascending" order
//   name: "car_plate"    what to name the index, so you can recognize and delete it later
//   sparse: true         only documents that have the field get into the index
db.passes.createIndex({ "car.plate": 1 }, { name: "car_plate", sparse: true })

// We repeat the same report and compare it with the previous one
db.passes.find({ "car.plate": "AB-1174-CD" }).explain("executionStats").executionStats
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
// insertOne = "add one document". What fields are in it, the database doesn't ask
db.passes.insertOne({
  tipe: "single-use",
  guest: "Nathan S. Graham",
  host: "petrov@corp.example",
  data: ISODate("2026-09-04T09:00:00Z")
})
```

La inserción tuvo éxito: volvió `acknowledged: true` («aceptado») y un nuevo `_id` — la clave
única del documento, que la base de datos ideó por sí misma. Comprobemos que ahora hay cinco
documentos:

```js
// countDocuments = "count the documents that match the condition".
// Empty curly braces are a condition with no restrictions, that is, "all"
db.passes.countDocuments({})
```

Cinco. Ahora lo que seguridad hace cada mañana — abre la lista de pases de una sola vez:

```js
// The same selection by type as in the search step: show the passes whose
// type field equals "single-use"
db.passes.find({ type: "single-use" })
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
// $exists: false — the opposite of the previous step: "the field is not in the document".
// It's worth keeping such a query handy: it shows what has accumulated past the schema
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
// deleteMany = "delete all documents that match the condition". The condition is the same
// as in the search above — which means exactly what you just saw will be deleted
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
          enum: ["single-use", "weekly", "vehicle", "group"],
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
# The same trick as with passes.js: the file's contents are fed to mongosh's input.
# The rule is hung on a live collection — no need to stop the database
mo < validator.js
```

**Lo que deberías ver** — `rule installed`.

Intentamos repetir la misma errata — ahora bajo la vigilancia de la regla:

```js
// The tipe field is unknown to the rule, and there's no required type in the document.
// Before, such a document would silently settle into the collection
db.passes.insertOne({ tipe: "single-use", guest: "Check", host: "x@corp.example" })
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
  // $lookup = "for each pass, go to another collection and bring back a record from there"
  { $lookup: {
      from: "staff",          // where to go — the employees collection
      localField: "host",     // which pass field to compare
      foreignField: "email",  // with which employee field
      as: "host_info"         // under what name to put what's found into the document
  } },
  // What's found is always put as a list, even if there's a single match.
  // $unwind unrolls the list back into a single value
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
// The host field, by meaning, refers to an employee. No such employee exists —
// will the database check this? The document satisfies the rule from the last step: type is
// in place and from the list, host is a string
db.passes.insertOne({ type: "single-use", host: "does-not-exist@corp.example", guest: "Test" })
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
// deleteOne = "delete one document that matches the condition", not all of them at once
db.passes.deleteOne({ host: "does-not-exist@corp.example" })
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
// A session is a separate "conversation" with the database, within which you can declare a transaction
const s = db.getMongo().startSession();
s.startTransaction();          // from this point changes accumulate, but are visible to no one
// … operations through s.getDatabase("passes") …
s.commitTransaction();         // apply it all at once. To cancel it all at once — abortTransaction()
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
  // $$ROOT — the whole document in full. $objectToArray breaks it into
  // "field name — value" pairs, so you can then work with the fields as data
  { $project: { fields: { $objectToArray: "$$ROOT" } } },
  // We unroll the list of pairs: one pair — one row at the input of the next stage
  { $unwind: "$fields" },
  // We group by two attributes at once: the field name (k) and its value type (t),
  // and count how many times such a combination occurred
  { $group: { _id: { k: "$fields.k", t: { $type: "$fields.v" } }, n: { $sum: 1 } } },
  { $sort: { "_id.k": 1 } }   // alphabetically, so one field sits next to its own types
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
# The same access file as in the steps above: the script works from inside the lab cluster
export KUBECONFIG=~/lab.kubeconfig
# The tenant number: from it the script will assemble the database address. Substitute your own
export COZY_TENANT=workshop03
# The password in single quotes: inside them the shell doesn't touch $, ! and & within the string.
# The password doesn't make it into the report
export MONGO_PASSWORD='your-passapp-password'
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
# delete = "remove from the cluster". The Pod disappears along with its MONGO_URI variable,
# so the password doesn't remain in the cluster
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
