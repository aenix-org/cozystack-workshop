# Laboratorio 13 · Tu propia aplicación en el catálogo de Cozystack

| | |
|---|---|
| **Tiempo** | 40 minutos |
| **Qué demuestra** | El catálogo de la plataforma está abierto: tu propia aplicación ocupa su lugar en él, justo al lado de Redis y las VMs |
| **Qué necesitas** | `helm` en la laptop, `kubectl`, acceso de tenant. El clúster `lab` no hace falta aquí |

## Por qué esto importa

El «Guest Pass» ya está en marcha. Una semana después se entera la filial: tienen la misma
recepción y el mismo problema. Una semana más tarde llega la segunda filial.

A las dos primeras se lo explicaste de palabra: qué imágenes, qué configuración, qué
parámetros, qué levantar primero. A la tercera quedó claro que así no se podía seguir. La
explicación vive en la cabeza de una persona, esa cabeza es una sola, y las empresas serán
cinco.

Lo que necesitas es que «Guest Pass» les aparezca igual que apareció Redis: una entrada en
el catálogo, un formulario con parámetros, un botón. Sin ti.

Este es el final del taller. Hemos recorrido el camino desde «despliégame un Pod» hasta
«aquí tienes una plataforma con nuestro servicio dentro».

## Antes que nada: dónde terminan tus permisos

Este laboratorio **no** desplegará la aplicación en el catálogo. Y no es porque nos faltara
tiempo para escribir la parte que lo haría.

El objeto `ApplicationDefinition`, el que registra una aplicación en el catálogo, es
**cluster-scoped**: hay uno por clúster, no tiene namespace, y cambia el catálogo para todos
los tenants a la vez. Un tenant no puede crear un objeto así. Compruébalo tú mismo, ahora
mismo: al clúster se le puede preguntar por tus permisos sin crear nada.

```bash
# KUBECONFIG — la variable que kubectl lee para encontrar la dirección del clúster y tus credenciales.
# Aquí es el acceso de tenant, el mismo archivo que en todos los demás laboratorios.
export KUBECONFIG=~/.kube/workshop
# auth can-i = «¿me está permitido?». El clúster responde yes o no y no cambia nada:
#   create                   qué acción comprobamos
#   applicationdefinitions   sobre qué tipo de objeto
kubectl auth can-i create applicationdefinitions
```

**Lo que verás:**

```
no
```

Aquí no hay ningún atajo, ni se pretende que lo haya. Por eso el laboratorio está planteado
con honestidad: **tú escribes el chart y la definición de la aplicación, los verificas
localmente y se los entregas al administrador de la plataforma.** Así es exactamente como
funciona en la vida real: construir el catálogo y operarlo son roles distintos.

Una analogía del mundo conocido: el contenido de la plantilla OVF lo preparas tú, pero en la
Content Library compartida lo coloca quien tiene los derechos sobre esa biblioteca.

## Pequeño glosario

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Helm** | Una herramienta de plantillas de manifiestos con parámetros y versiones | lo más cercano a una plantilla OVF con campos de entrada, pero en texto y en Git |
| **Chart (chart)** | Un paquete de Helm: plantillas, valores por defecto, esquema | una **plantilla OVF**, pero desplegada muchas veces con distintos parámetros desde un solo lugar |
| **Release (release)** | Un despliegue concreto de un chart bajo su propio nombre | una **VM desplegada desde una plantilla**, pero recuerda su historial de versiones y sabe revertir |
| **values** | Los parámetros con los que se despliega un chart | los **campos del asistente de despliegue de OVF**, pero YAML plano, guardado en Git junto con todo lo demás |
| **values.schema.json** | Una descripción de los valores permitidos | la **validación de campos en el asistente**, pero comprueba antes de aplicar, no durante |
| **ApplicationDefinition** | Una entrada en el catálogo de la plataforma: qué mostrar y qué desplegar | una **entrada en la Content Library**, pero una por clúster y visible para todos los tenants |
| **Namespace** | Una sección del clúster donde viven los objetos de un solo dueño | una **carpeta o resource pool**, pero por él pasa la frontera de permisos: tu tenant es un namespace |
| **Cluster-scoped** | Un objeto sin namespace, compartido por todo el clúster | un **ajuste a nivel de vCenter**, pero los derechos sobre él pertenecen al equipo de plataforma, no al tenant |
| **CRD** | La forma de añadir un nuevo tipo de objeto a Kubernetes | una vez registrado, tu tipo es indistinguible de los integrados |

## Qué hay en la carpeta del laboratorio

Todos los archivos ya están ahí: los obtuviste junto con el repositorio. No hay nada que
crear ni volver a teclear: allí donde más abajo dice `kubectl apply -f name.yaml`, el archivo
se toma de aquí.

```bash
cd labs/13-catalog
```

| Archivo | Qué es | Cuándo resulta útil |
|---|---|---|
| `chart/` | Tu aplicación, empaquetada para el catálogo: plantillas, values, esquema de los campos del formulario | lo lees y verificas localmente |
| `applicationdefinition.yaml` | La descripción de la entrada del catálogo: cómo se llama y qué mostrar en el panel | intentas aplicarlo, para ver la denegación de permisos |
| `guestpass-example.yaml` | Qué aspecto tendrá el pedido de tu aplicación una vez publicada | lo lees; solo puedes aplicarlo tras la publicación |
| `icon.svg`, `icon.b64` | El icono de la entrada: el fuente y eso mismo como cadena; ya está incrustado en la definición | resulta útil si alguna vez cambias el icono |
| `check.sh` | Una comprobación de que el chart se renderiza y el clúster lo acepta | lo ejecutas al final del laboratorio |

## Paso 1. Miramos qué empaquetamos

La carpeta `chart/` contiene un chart terminado del «Guest Pass». La aplicación de dentro es
deliberadamente simple —nginx con una página— porque el laboratorio no va de la aplicación,
va del empaquetado.

```
chart/
├── Chart.yaml            nombre, versión, descripción
├── values.yaml           parámetros y valores por defecto
├── values.schema.json    qué values considerar válidos
└── templates/
    ├── configmap.yaml    la página y la configuración de nginx
    ├── deployment.yaml   la propia aplicación
    └── service.yaml      la dirección
```

<details>
<summary><b>Miramos de cerca: qué hay dentro del chart</b></summary>

### `Chart.yaml` — el pasaporte

```yaml
name: guest-pass
version: 0.1.0
appVersion: "1.0"
```

Dos números de versión distintos, y constantemente se confunden.

`version` es la versión del **chart**, es decir, del empaquetado. Ajustaste una plantilla,
añadiste un parámetro, corregiste una errata en la descripción: súbela.

`appVersion` es la versión de la **aplicación** de dentro. Cambia cuando sale una nueva
versión del propio «Guest Pass», y no tiene ninguna relación con la versión del empaquetado.

El sentido práctico: por `version` el administrador entiende si se actualiza el propio
mecanismo de despliegue, y por `appVersion` si se actualiza aquello que la gente realmente
usa.

### `values.yaml` — los parámetros

```yaml
## @param {int} replicas=2 - Number of application replicas.
replicas: 2

## @param {string} greeting=Order a pass for your guest - Text shown on the main page.
greeting: "Order a pass for your guest"

## @param {bool} external=false - Enable external access from outside the cluster.
external: false
```

Los comentarios `## @param` no son adorno ni documentación para humanos. A partir de ellos el
generador de Cozystack (`cozyvalues-gen`) construye `values.schema.json` y la tabla de
parámetros en el README del chart. Una única fuente de verdad: cambias el comentario,
regeneras el esquema, y el formulario en el panel cambia con él.

El formato es estricto: `## @param {tipo} nombre=valor-por-defecto - Descripción.`

Los parámetros son pocos a propósito. Cada nuevo parámetro es un campo más en el formulario,
una forma más de desplegar mal la aplicación y una rama más que tendrás que mantener. Un buen
chart deja configurar lo que de verdad difiere entre instalaciones, y nada más.

### `values.schema.json` — qué considerar válido

El esquema lo comprueba Helm **antes** de que nada viaje al clúster. Compruébalo en el acto:
cuela una cadena en un parámetro numérico.

```bash
# template = «arma los manifiestos a partir del chart e imprímelos», el clúster no se toca:
#   gp                    el nombre del release bajo el que el chart se despliega de forma nominal
#   chart                 la carpeta con el chart
#   --set replicas=abc    sobrescribe un solo parámetro directamente en la línea de comandos
helm template gp chart --set replicas=abc
```

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
guest-pass:
- at '/replicas': got string, want integer
```

El error se atrapa en la laptop en medio segundo. Sin el esquema habría llegado hasta el
clúster y se habría convertido en un Deployment que nunca se crea, con un mensaje de tres
pantallas.

Este mismo esquema, palabra por palabra, irá al `ApplicationDefinition`, y allí crece hasta
convertirse en el formulario de creación del panel.

### `templates/configmap.yaml` — la página

```yaml
    <h1>{{ .Values.greeting }}</h1>
```

Esta es la razón misma por la que existe una herramienta de plantillas: un valor de `values`
aterriza en el manifiesto en el momento del render. Sin Helm tendrías que mantener una copia
del manifiesto por cada filial y editarlas a mano.

### `templates/deployment.yaml` — la aplicación

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

La línea que todos olvidan, y que luego cuesta una hora de depuración.

Kubernetes **no reinicia los Pods cuando cambia un ConfigMap**. Editas el texto, lanzas una
actualización, el panel muestra «actualizado», y la página sigue mostrando el saludo viejo.
La anotación con el hash de la configuración cambia junto con la configuración, y un cambio en
una anotación de la plantilla del Pod ya es un cambio del propio Pod, así que el clúster lo
recrea.

```yaml
            requests:
              cpu: {{ .Values.resources.cpu | quote }}
```

`quote` es obligatorio aquí. Sin comillas, YAML lee el valor `100m` como cadena, pero `1`
como número, y en uno de cada dos casos obtienes un error de tipo. Las comillas eliminan de
golpe toda esta clase de problemas.

### `templates/service.yaml` — la dirección

```yaml
  type: {{ if .Values.external }}LoadBalancer{{ else }}ClusterIP{{ end }}
```

Un único parámetro booleano decide si la aplicación obtiene una dirección fuera del clúster o
no. Así es exactamente como están hechas las aplicaciones integradas de Cozystack: la mayoría
tiene un campo `external` con precisamente este significado. Vale la pena seguir las
convenciones de otros en el catálogo: quien desplegó tres servicios gestionados antes que tú
buscará este campo en el mismo sitio y con el mismo nombre.

</details>

## Paso 2. Verificamos el chart localmente

📍 **Dónde:** en la laptop. Para esto no hace falta clúster.

Primero el linter. Lee el chart como un conjunto de archivos y atrapa errores estructurales:
la indentación equivocada, un campo obligatorio perdido, una plantilla que no se puede analizar.

```bash
cd labs/13-catalog
# lint = «comprueba el paquete en busca de errores de formato y campos obligatorios»
#   chart   ruta a la carpeta del chart; dentro Helm espera Chart.yaml, values.yaml
#           y la carpeta templates/
helm lint chart
```

**Lo que deberías ver:**

```
==> Linting chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

`[INFO]` es una observación, no un error: el chart no tiene campo `icon`. Para el catálogo de
Cozystack no hace falta de todos modos, el icono se toma del `ApplicationDefinition`, al que
llegaremos.

Ahora el render. Una plantilla es un manifiesto en el que parte de los valores están
reemplazados por sustituciones de la forma `{{ .Values.replicas }}`. Renderizar es convertir
las plantillas en manifiestos terminados: Helm toma los valores de `values.yaml`, los
sustituye en el texto e imprime el resultado.

```bash
# main — el nombre del release, es decir, de este despliegue concreto del chart. Va
# a los nombres de los objetos creados, por lo que dos instalaciones contiguas no chocarán.
helm template main chart
```

La salida son manifiestos corrientes, los mismos que escribiste a mano en los primeros
laboratorios. No hay nada mágico en Helm: sustituye valores en texto.

Comprueba que los parámetros de verdad llegan a los manifiestos. Renderizamos dos veces con
valores distintos y conservamos en la salida solo la línea que debía cambiar.

```bash
# --set replicas=5 sobrescribe el valor de values.yaml durante una sola ejecución.
# | grep 'replicas:' — de toda la salida conserva solo las líneas con esta palabra.
helm template main chart --set replicas=5 | grep 'replicas:'
# lo mismo para el parámetro booleano: external decide qué tipo de Service acaba en el manifiesto
helm template main chart --set external=true | grep 'type:'
```

```
  replicas: 5
  type: LoadBalancer
          type: RuntimeDefault
```

La tercera línea no es un error ni una errata tuya. `grep` busca la palabra por todo el texto,
y `type:` aparece también en los requisitos de seguridad (`seccompProfile`). Un recordatorio
útil de que `grep` no entiende la estructura de YAML: busca líneas, no campos.

⚠️ **`helm template` no envía nada al clúster ni comprueba nada de su lado.** Renderiza texto.
Un manifiesto que pasó `helm template` todavía puede ser rechazado por el clúster; por
ejemplo, por un CRD que falta. Es una comprobación barata, no una completa.

## Paso 3. Desglosamos el ApplicationDefinition

El chart sabe desplegar la aplicación. Pero el catálogo aún no sabe de ella: para que «Guest
Pass» aparezca como entrada en el panel y se convierta en un tipo de objeto en la API, hace
falta un archivo más.

Está justo ahí: `applicationdefinition.yaml`.

<details>
<summary><b>Miramos de cerca: qué hay dentro de applicationdefinition.yaml</b></summary>

```yaml
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: guest-pass
```

Fíjate en lo que **no** está aquí: el campo `namespace`. Esta es esa misma naturaleza
cluster-scoped del objeto. Hay uno por clúster, y la entrada del catálogo que produce la verán
todos los tenants a la vez.

### El bloque `application` — cómo se ve esto en la API

```yaml
  application:
    kind: GuestPass
    plural: guestpasses
    singular: guestpass
```

Tras aplicar este archivo, en el clúster aparece un nuevo tipo de objeto. No una
«integración» ni un «plugin»: un tipo con todas las de la ley con el que trabajas usando
`kubectl` de siempre. Estos dos comandos funcionarán para cualquier tenant en cuanto el
administrador aplique la definición:

```bash
# get = «muéstrame qué hay». guestpasses es ese mismo nombre del campo plural de abajo:
#   -n tenant-workshopXX   en qué namespace mirar; reemplaza XX por tu propio número
kubectl get guestpasses -n tenant-workshopXX
# describe = «muéstrame todo sobre un objeto»: parámetros, estado, eventos recientes.
# main aquí es el nombre de una aplicación concreta pedida, no el nombre del tipo.
kubectl describe guestpass main -n tenant-workshopXX
```

`plural` es lo que se sustituye en los comandos y en la URL de la API. `singular` es lo que
escribes en `kubectl describe`. Ambos se escriben en minúsculas y sin espacios: un requisito
de Kubernetes, no una cuestión de estilo.

```yaml
    openAPISchema: |-
      {"title":"Chart Values","type":"object","properties":{...}}
```

El mismo esquema que está en el chart como el archivo `values.schema.json`, solo que escrito
en una única línea de JSON. Funciona en dos sitios: la API rechaza los valores inválidos, y el
panel dibuja a partir de él el formulario de creación: tipos de campo, valores por defecto,
pistas.

⚠️ **El esquema de aquí y el esquema del chart deben coincidir.** No hay ningún vínculo
automático entre ellos: son dos archivos, y mantenerlos sincronizados es tu tarea. Deja que se
separen, y el formulario del panel muestra un conjunto de campos mientras el chart espera
otro. `check.sh` los coteja por ti, pero vale la pena acostumbrarse a esa comprobación.

### El bloque `release` — qué desplegar

```yaml
  release:
    prefix: guest-pass-
```

El nombre del release se compone del prefijo y del nombre del objeto: un `GuestPass` llamado
`main` se despliega como el release `guest-pass-main`. El campo es obligatorio. Hace falta
para que los releases de distintas aplicaciones no choquen de nombre en un mismo namespace:
muchas cosas se llaman `main`, pero `guest-pass-main` es solo tuyo.

```yaml
    labels:
      sharding.fluxcd.io/key: tenants
```

Una etiqueta de servicio de Cozystack: por ella, los releases de los tenants se reparten entre
los manejadores de Flux. Sin ella no habrá quién atienda el release, y se quedará colgado
esperando. Este no es el lugar para mostrar iniciativa: cópiala tal cual.

```yaml
    chartRef:
      kind: HelmChart
      name: cozystack-guest-pass
      namespace: cozy-public
```

De dónde tomar el chart. Hay tres valores válidos de `kind`: `OCIRepository`, `HelmChart`,
`ExternalArtifact`.

Los catálogos externos suelen llegar por la cadena `GitRepository` → `HelmChart`: el
administrador añade tu repositorio como fuente en el namespace `cozy-public`, Flux extrae de él
el chart, y el `ApplicationDefinition` referencia ese chart. Este es exactamente el camino que
se muestra en `cozystack/external-apps-example`, y es un punto sensato por donde empezar.

⚠️ **Los nombres en `chartRef` no los inventas tú solo.** Deben coincidir con cómo el
administrador registre la fuente. Acuérdalos antes de enviar el archivo; de lo contrario la
definición se aplicará pero no habrá nada que desplegar, y el error solo saldrá a la luz para
la primera persona que pulse «crear».

### El bloque `dashboard` — cómo se ve esto en la interfaz

```yaml
  dashboard:
    category: PaaS
    singular: Guest Pass
    plural: Guest Passes
    description: Internal guest pass service for employees and reception
    tags: [internal, web]
```

`category` es la sección del catálogo. Cozystack usa cinco: `PaaS`, `IaaS`, `NaaS`,
`Administration`, `Networking`. Toma una existente. Una sección propia significa una sección de
una sola entrada, en la que nadie encontrará tu aplicación.

`singular` y `plural` aquí son los nombres **humanos**, con espacios y mayúsculas. No los
confundas con los del bloque `application`: aquellos son para la API, estos para el ojo.

```yaml
    icon: PHN2ZyB3aWR0aD0iMTQ0IiBoZWlnaHQ9IjE0NCIgdmlld0JveD0iMCAwIDE0NCAxNDQi...
```

El icono es un SVG codificado en base64. Codificado, no una ruta ni un enlace: el panel no va
a ninguna parte a descargarlo, la imagen vive en el propio objeto.

El fuente está justo ahí, en `icon.svg`, y la cadena lista, en `icon.b64`. Si editaste el
fuente, la cadena hay que reconstruirla. El codificador por defecto parte la salida en líneas,
pero el campo `icon` necesita una única cadena continua, así que los saltos de línea se
eliminan en un paso aparte.

```bash
# base64 = convertir un archivo binario en una cadena de letras, dígitos y los signos + / =
#   -i icon.svg   qué codificar (la grafía del flag para macOS y BSD)
# tr -d '\n' = descartar todos los saltos de línea de la salida, pegándola en una sola
base64 -i icon.svg | tr -d '\n'
```

En Linux el mismo comando tiene otros flags: `base64 -w0 icon.svg`, donde `-w0` significa «no
ajustar la salida en absoluto». Las grafías de los flags de GNU y BSD no coinciden aquí.

El tamaño del lienzo 144×144 coincide con los iconos integrados de la plataforma. Más no hace
falta: en el catálogo se dibuja pequeño.

```yaml
    keysOrder: [["apiVersion"], ["kind"], ["metadata"], ..., ["spec", "replicas"], ...]
```

El orden de los campos en la representación YAML del objeto. Cosmético, pero sin él los campos
se alinean de cualquier manera —primero el poco usado `resources`, después el principal
`replicas`— y el formulario se lee peor de lo que podría.

</details>

## Paso 4. Intentamos aplicar — y recibimos una denegación

📍 **Dónde:** en la laptop, con acceso de tenant.

El archivo está listo y es sintácticamente correcto: intentemos aplicarlo como si tuviéramos
los derechos. La denegación vendrá del clúster, no de `kubectl`, y el texto de la denegación
dirá exactamente qué faltaba.

```bash
# acceso de tenant — el mismo con el que has trabajado durante todo el taller
export KUBECONFIG=~/.kube/workshop
# apply = «pon el clúster en línea con lo que está escrito en el archivo»; -f — leer de un archivo
kubectl apply -f applicationdefinition.yaml
```

**Lo que verás:**

```
Error from server (Forbidden): error when creating "applicationdefinition.yaml":
applicationdefinitions.cozystack.io is forbidden: User "workshopXX" cannot create
resource "applicationdefinitions" in API group "cozystack.io" at the cluster scope
```

La denegación es esperada: se dijo al comienzo del laboratorio. Lo que importa aquí son las
últimas cuatro palabras: **at the cluster scope**.

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

Tus derechos en el tenant son derechos dentro de un namespace. Eres el dueño absoluto de tu
propio trozo: levantas clústeres, bases de datos, VMs, las borras, las rompes, las arreglas.
Ni uno solo de tus objetos es visible para un vecino ni le estorba.

`ApplicationDefinition` está construido de otra manera. Cambia el catálogo **para todos los
tenants a la vez**. Una aplicación con un error en su esquema, aplicada por ti, la verán e
intentarán desplegar personas de otros departamentos. Una aplicación con el mismo nombre que
una existente romperá la existente.

Por eso la frontera pasa justo aquí, y no es cuestión de desconfianza. Lo mismo ocurría en
vSphere: tus propias VMs en tu propio pool las creabas tú, pero el contenido de la Content
Library compartida, y los derechos sobre ella, no.

**Qué hacer en la práctica.** Entrega al administrador de la plataforma dos archivos y un
acuerdo:

| Qué entregar | Por qué |
|---|---|
| `applicationdefinition.yaml` | el objeto en sí, que él aplicará |
| un enlace al repositorio con el chart | a partir de él el administrador construye la fuente en `cozy-public` |
| los nombres acordados en `chartRef` | para que la definición encuentre el chart |

Y comprueba antes de enviar que ambos archivos están en orden, porque el ciclo de
retroalimentación aquí es largo: el administrador lo aplica, y un tercero ve el error.

</details>

La denegación también podría haber venido de un error en el propio archivo. Separemos ambas
cosas: primero preguntamos por los permisos, luego hacemos que `kubectl` analice el archivo
entero, sin enviarlo a ninguna parte.

```bash
# auth can-i = «¿me está permitido?». La respuesta es yes o no, y el clúster no se cambia.
kubectl auth can-i create applicationdefinitions
# --dry-run=client = «analiza el archivo y muestra qué saldría, pero no vayas al clúster».
# client significa que toda la comprobación corre en la laptop y el clúster ni siquiera se entera.
kubectl apply -f applicationdefinition.yaml --dry-run=client
```

**Lo que deberías ver.** El primer comando: `no`. El segundo:
`applicationdefinition.cozystack.io/guest-pass created (dry run)`: el archivo se analiza, la
sintaxis está bien, el problema de verdad son los permisos.

⚠️ **`--dry-run=client` comprueba solo la sintaxis.** No le pregunta nada en absoluto al
clúster. `--dry-run=server` sí preguntaría, pero eso requiere esos mismos derechos que faltan.

## Paso 5. Qué verán las filiales

Cuando el administrador aplique la definición, el catálogo gana una entrada. A partir de ese
momento cualquier tenant despliega «Guest Pass» igual que desplegó Redis: **Create
application** → `Guest Pass` → un formulario a partir de tus cuatro parámetros → un botón.

O como texto: el archivo `guestpass-example.yaml` de esta carpeta:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: GuestPass
metadata:
  name: main
  namespace: tenant-workshopXX
spec:
  replicas: 2
  greeting: "Order a pass for your guest"
  external: false
```

Fíjate en el grupo: `apps.cozystack.io`, el mismo que para `Bucket` y `VMInstance`. Tu
aplicación ha ocupado su lugar **en la misma fila** que las integradas, no en un aparte. Se ve
igual en la lista de aplicaciones del tenant, sus recursos se cuentan igual, los permisos
funcionan igual.

⚠️ No puedes aplicar este archivo antes de que el administrador haya registrado la definición:
`kubectl` responderá `no matches for kind "GuestPass"` — todavía no existe ese tipo de objeto
en el clúster.

## Paso 6. Cómo no escribir todo esto a mano

Todo lo que desglosaste en este laboratorio es un esqueleto: `Chart.yaml`, `values.yaml`, el
esquema, las plantillas, el `ApplicationDefinition` con los nombres y las etiquetas correctas.
La mitad del archivo son campos obligatorios que son iguales en todas partes, y es más fácil
equivocarse en ellos que escribirlos.

Para esto hay una herramienta ya lista.

| Qué | Dónde | Por qué |
|---|---|---|
| El repositorio `cozystack/ccp` | github.com/cozystack/ccp | un conjunto de plugins y skills para Claude Code |
| El plugin `cozystack` | de ahí mismo | le enseña a Claude Code la estructura de los paquetes de Cozystack |
| El skill `external-app-create` | en el plugin | genera el esqueleto completo de la aplicación externa |
| El repositorio de ejemplo | github.com/cozystack/external-apps-example | un ejemplo funcional con la construcción y publicación del chart |

El skill pregunta el nombre de la aplicación, el kind, la categoría y los parámetros, y
despliega un árbol de archivos terminado: el chart con su esquema, el `ApplicationDefinition`
con los prefijos y las etiquetas correctas, un Makefile para la construcción.

Desglosar todo esto a mano no pierde su sentido. El esqueleto generado habrá que leerlo y
editarlo igualmente, y editar lo que no entiendes es la peor forma conocida de trabajar.

## La comprobación

📍 **Dónde:** en la laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

El script corre **localmente** y no toca el clúster: comprueba que el chart pasa el linter,
que se renderiza, que los parámetros de verdad llegan a los manifiestos, que el
`ApplicationDefinition` se analiza y contiene todos los campos obligatorios, que el icono se
decodifica en SVG y, lo más importante, que el esquema de la definición coincide con el
esquema del chart.

```bash
# ./ antes del nombre significa «el archivo de la carpeta actual», es decir, de labs/13-catalog
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo configurarlo está
escrito al comienzo del laboratorio 0. Sin WSL puedes completar el laboratorio, pero no habrá
informe-artefacto.

Si `KUBECONFIG` está definido, el script además preguntará al clúster por los permisos y
confirmará que no tienes derecho a aplicar la definición. El script cuenta la ausencia de
derechos como el resultado esperado, no como un error.

## Limpieza

No hay nada que limpiar: no creaste nada en el clúster. Este es el único laboratorio del taller
que no deja rastro, y esa es su particularidad: el trabajo del equipo de plataforma en su mayor
parte se ve exactamente así: texto, revisión, manos ajenas en el apply.

Llévate contigo los archivos `chart/` y `applicationdefinition.yaml`. Es un punto de partida
funcional; de él puede crecer una aplicación real para tu catálogo.

## Qué sabemos hacer ahora

- Empaquetar una aplicación en un chart de Helm con un esquema de parámetros y verificarla localmente
- Escribir un `ApplicationDefinition` y explicar el propósito de cada uno de sus bloques
- Entender por qué el catálogo es compartido y por qué un tenant no tiene derechos sobre él
- Preparar la entrega al administrador para que aplique el archivo a la primera
- Saber con qué generar el esqueleto y qué ejemplo mirar

## Y en vSphere esto sería

La Content Library y una plantilla OVF con campos de entrada. La mecánica se parece más de lo
que aparenta: un equipo prepara la plantilla, otro la coloca en la biblioteca compartida, y
otros la despliegan.

La diferencia está en lo que obtienes al final. Una plantilla OVF es una máquina con un disco:
la despliegas, y a partir de entonces vive por su cuenta, y la actualizarás a mano en cada
copia. Un `ApplicationDefinition` es una descripción respaldada por un chart: actualizas el
chart, subes la versión, y todas las instalaciones se actualizan por un solo mecanismo.

**Dónde vSphere es más cómodo, con honestidad.** La Content Library es una interfaz ya lista:
sueltas el archivo, repartes los derechos, y listo. Aquí necesitas montar un repositorio,
configurar la construcción y publicación del chart, acordar con el administrador los nombres de
la fuente — y todo eso antes de que algo aparezca en el catálogo. La barrera de entrada es más
alta, y la primera aplicación llevará un día, no una hora.

Se amortiza en la segunda y la tercera aplicación, y especialmente en la primera
actualización. Actualizar una aplicación que se ha extendido por cinco filiales, desde un
chart, frente a actualizar la misma aplicación en cinco copias OVF que se han separado entre sí
— es una cantidad de trabajo distinta. Un orden de magnitud distinto.
