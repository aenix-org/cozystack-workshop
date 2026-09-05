# Lab 8 · Secretos fuera del manifiesto

| | |
|---|---|
| **Tiempo** | 50 minutos, parte de ellos esperando mientras el almacén se levanta y lo desellas |
| **Qué demuestra** | Que una contraseña puede sacarse de Git para siempre y cambiarse sin tocar un solo archivo |
| **Qué necesitas** | El clúster del Lab 0 y `~/lab.kubeconfig`; acceso al panel de tu tenant; un número de tenant con la forma `workshopXX` |

> ⚠️ **`workshopXX` es un marcador, no un nombre.** Sustitúyelo por tu propio número de tenant,
> de lo contrario el comando irá al tenant de otra persona y obtendrás un error de acceso denegado
> — o peor, los datos de alguien más. Recibiste tu número junto con tu contraseña.

> ⚠️ **Una práctica densa: once pasos y un modelo de acceso poco familiar.**
> Plánala como una sola sesión continua, sin pausa en el medio.

## Por qué importa

El servicio de Pases funciona: un empleado solicita un pase para un invitado, seguridad ve la lista.
El equipo de seguridad se presentó para una auditoría de rutina y trajo una sola línea de tu repositorio:

```yaml
- name: DB_PASSWORD
  value: "Propusk2019!"
```

La contraseña de la base de datos de pases está en un manifiesto. El manifiesto está en Git. Git lo ven
doce personas de tres equipos, otras cuatro dejaron la empresa, y una copia completa del repositorio
vive en la laptop de un contratista que hizo una integración el año pasado.

La pregunta del auditor suena rutinaria: **«cambia esta contraseña y muéstrame quién la leyó durante
el último mes».** No hay nada que responder. Cambiar la contraseña significa encontrar cada lugar donde
está escrita a fuego; quién la leyó es un misterio, porque leer un archivo de Git no queda registrado
en ninguna parte.

En esta práctica sacaremos la contraseña a OpenBao, enseñaremos a la aplicación a obtenerla de allí,
cambiaremos la contraseña con un solo comando y veremos qué sabe el sistema al respecto.

En el camino resolveremos una pregunta con la que casi todos tropiezan: **en qué se diferencia un
Secret de Kubernetes de un verdadero almacén de secretos.**

Cada término de esta práctica se explica la primera vez que aparece, y la siguiente sección es un
glosario de los ya introducidos.

## Glosario

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Secret (Kubernetes)** | Un objeto del clúster que contiene datos escritos en base64 | **Un archivo de contraseñas en el disco de una VM**, pero parece protegido y no lo está — lo desmenuzamos abajo |
| **base64** | Una forma de escribir bytes arbitrarios como caracteres imprimibles | **uuencode, un adjunto MIME**, pero no es cifrado. No hay clave, y cualquiera puede revertirlo |
| **Almacén de secretos** | Un servicio aparte: guarda los secretos cifrados y los entrega según reglas | **Sin analogía directa**, pero no es una «carpeta de red llena de contraseñas» — es un servicio con políticas, caducidad y un registro |
| **OpenBao** | Uno de esos almacenes. Un fork de HashiCorp Vault, publicado bajo la licencia MPL | los comandos y la API coinciden con Vault; solo la utilidad se llama `bao` |
| **Token root** | Una cuenta con acceso total a todo | **root**, pero lo usas una vez durante la configuración y luego emites tokens acotados |

El resto del vocabulario de esta práctica — `sealed`, clave de desellado, política, token, KV v2, rotación,
registro de auditoría, init container — se introduce sobre la marcha, en el paso donde cada uno hace falta
por primera vez. No hace falta memorizarlos ahora: separados de la acción, de todos modos no se te quedarán.

<details>
<summary><b>Si prefieres ver la lista completa de una vez</b></summary>

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **Sellado (sealed)** | El servicio está en marcha, pero la clave maestra no está en memoria: los datos están cifrados y la API rechaza las solicitudes | **«El servicio arrancó, pero el volumen no está montado»**, pero después de cada reinicio tienes que desellarlo de nuevo, a mano |
| **Clave de desellado** | Un fragmento de la clave maestra con el que se desella el almacén | **Una llave de una caja fuerte**, pero hay varios fragmentos, y por defecto debes presentar más de uno |
| **Política (policy)** | Una lista de rutas y lo que se permite en ellas | **Una ACL sobre una carpeta**, pero la ruta es una dirección en la API, no un archivo en disco |
| **Token** | Un pase temporal al almacén | **Una sesión**, pero un token tiene un tiempo de vida, caduca por sí solo y puede revocarse |
| **KV v2** | Un motor «clave-valor» con historial de versiones | **Una carpeta de archivos con historial de cambios**, pero guarda cada versión y la marca de tiempo de cada escritura; el valor antiguo nunca desaparece |
| **Rotación** | El reemplazo programado de un secreto por uno nuevo | **Cambiar una contraseña según un calendario**, pero aquí es un solo comando, y la aplicación lo recoge en su siguiente arranque |
| **Registro de auditoría** | Un registro de «quién solicitó qué y cuándo» | **Un registro de acceso a un recurso compartido de archivos**, pero se escribe una línea por cada solicitud a la API, incluidas las fallidas y las denegaciones |
| **Secreto cero** | El único secreto que una aplicación usa para demostrar su derecho a todos los demás | no puede eliminarse por completo. Puede hacerse efímero, acotado y de un solo uso |
| **Init container** | Un contenedor que se ejecuta y termina antes de que arranque el principal | **Un script de arranque que corre antes de que el servicio se levante**, pero si falla el contenedor principal no arranca en absoluto — que es exactamente lo que quieres |

</details>

## Qué hay en la carpeta de la práctica

Ya tienes todos los archivos — los recibiste con el repositorio. No hay nada que crear ni volver a
escribir: donde el texto de abajo dice `kubectl apply -f nombre.yaml`, el archivo viene de aquí.

```bash
cd labs/08-openbao
```

| Archivo | Qué es | Cuándo lo usarás |
|---|---|---|
| `openbao.yaml` | Un pedido de un almacén de secretos — lo mismo que el botón en el panel | lo aplicas **en el tenant**, no en el clúster `lab` |
| `secrets-demo-naive.yaml` | Cómo se ve el servicio hoy: la contraseña justo en el archivo. Esto es lo que encontró la auditoría | lo aplicas en tu propio clúster `lab` |
| `secrets-demo-secret.yaml` | El «arreglo ingenuo»: la contraseña movida a un Secret — y por qué eso no basta | lo aplicas en el mismo lugar |
| `secrets-demo.yaml` | La versión final: la contraseña no está en ningún lado — ni en texto plano, ni en base64 | lo aplicas en el mismo lugar |
| `check.sh` | Una verificación de que la aplicación obtiene su contraseña del almacén | lo ejecutas al final de la práctica |

## Paso 1. Ve el problema con tus propios ojos

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

Reproduzcamos el hallazgo de la auditoría en nuestro propio terreno: levantaremos un pequeño servicio
`secrets-demo` en el clúster de laboratorio con la contraseña entregada directamente desde su descripción.
Primero repasamos el archivo, luego lo aplicamos.

<details>
<summary><b>Un vistazo de cerca: qué hay dentro de secrets-demo-naive.yaml</b></summary>

Es un `Deployment` corriente — una descripción de una aplicación: qué imagen tomar y cuántas copias
mantener en ejecución. **Una imagen** es una instantánea lista de un sistema de archivos con un programa
dentro; el análogo más cercano en vSphere es una plantilla de VM, solo que sin el sistema operativo.
**Un contenedor** es una instancia en ejecución de una imagen. **Un Pod** es la unidad de ejecución más
pequeña en Kubernetes: uno o más contenedores que siempre viven y mueren juntos.
El Deployment se asegura de que el número de Pods en ejecución coincida con el número pedido.

```yaml
      containers:
        - name: app
          image: busybox:1.36
```

No tocaremos la aplicación real de Pases que construiste en Go en la práctica sobre tu propio registro:
funciona, y no hay razón para romperla por un ejercicio. Así que levantamos aparte un pequeño servicio
`secrets-demo` junto a ella — lo que nos interesa no es la aplicación sino el camino por el que la
contraseña llega a ella. Por eso en su lugar hay un contenedor diminuto que hace la única cosa con
sentido — cada diez segundos escribe en el registro con qué contraseña está trabajando.

```yaml
          env:
            - name: DB_PASSWORD
              value: "Propusk2019!"
```

Esta línea es todo el meollo del asunto. Las variables de entorno son la forma más corriente de pasar
configuración a una aplicación: `env` en el manifiesto se convierte en una variable dentro del
contenedor. El mecanismo es bueno; lo malo es el **valor puesto justo en el archivo**.

```yaml
                  "$(printf %s "$DB_PASSWORD" | sha256sum | cut -c1-12)"
```

La aplicación imprime no la contraseña sino su **huella** — los primeros doce caracteres del sha256.
La huella muestra que la contraseña cambió, pero la contraseña misma no puede recuperarse a partir de
ella. Así es como deben escribirse los registros; lo usaremos durante el resto de la práctica.

`resources.requests` es cuánto recurso reservar como garantía (el análogo de una reserva en vSphere),
`resources.limits` es el techo por encima del cual no se le permite subir (el análogo de un límite).
Los valores son diminutos a propósito: la aplicación no hace nada.

</details>

**Aplícalo.**

```bash
# KUBECONFIG le dice a kubectl con qué clúster hablar. Aquí es el clúster de laboratorio
# del Lab 0; el tenant hará falta después, en el paso donde pedimos el almacén.
export KUBECONFIG=~/lab.kubeconfig
cd labs/08-openbao
# apply = «lleva el clúster a lo que se describe en el archivo». -f = toma la descripción del archivo.
# Aún no existe ningún objeto con este nombre, así que se creará.
kubectl apply -f secrets-demo-naive.yaml
```

**Lo que deberías ver** — una línea que termina con la palabra `created`.

Veamos qué obtuvimos:

```bash
# logs = muestra lo que la aplicación imprimió en su salida. No hay un archivo de registro aparte.
#   deploy/secrets-demo  toma la salida del Pod levantado por esta descripción
#   --tail=2             solo las dos últimas líneas, no todo desde el arranque
kubectl logs deploy/secrets-demo --tail=2
```

**Lo que deberías ver** — algo así:

```
08:14:31 conectando a passes-db.internal como passes_app, huella de la contraseña sha256:a609df223d57
```

La aplicación funciona. La contraseña está en un archivo, el archivo está en Git. Esta es exactamente
la situación que encontró la auditoría.

## Paso 2. El arreglo ingenuo: mover la contraseña a un Secret

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

Lo primero que sugiere cualquier búsqueda en internet: «Kubernetes tiene un Secret para eso».
Hagamos lo aconsejado — y primero veamos qué cambia en el archivo.

<details>
<summary><b>Qué cambió en el manifiesto</b></summary>

Ha aparecido un objeto aparte:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: passes-db
type: Opaque
data:
  password: UHJvcHVzazIwMTkh
```

Un `Secret` es un objeto del clúster destinado a datos sensibles. Los valores del campo `data` se
escriben en base64, así que en el archivo, en lugar de `Propusk2019!`, ahora está `UHJvcHVzazIwMTkh`.

Y en el Deployment, en lugar del valor, ha aparecido una referencia:

```yaml
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: passes-db
                  key: password
```

`valueFrom` en lugar de `value` significa: «toma el valor no de aquí, sino de aquel objeto de allá».
Kubernetes sustituirá el contenido de la clave `password` del secret `passes-db` en la variable
`DB_PASSWORD` cuando el contenedor arranque.

Esta es la técnica correcta en sí misma — referenciar un secret en vez de escribir el valor.
La cuestión es qué hay al otro extremo de la referencia.

</details>

**Aplícalo.**

```bash
# El mismo apply. El archivo contiene dos objetos — un Secret y el Deployment modificado; el clúster
# comparará lo descrito con lo que ya tiene y los ajustará entre sí.
kubectl apply -f secrets-demo-secret.yaml
```

Confirmemos que la aplicación sigue funcionando:

```bash
# rollout status espera hasta que la nueva versión de la aplicación haya reemplazado por completo a la vieja, y solo
# entonces devuelve el control. Sin él podrías leer los registros del Pod viejo.
kubectl rollout status deploy/secrets-demo
kubectl logs deploy/secrets-demo --tail=2
```

La huella es la misma — `sha256:a609df223d57`. La aplicación obtuvo la misma contraseña por un camino
distinto.

**¿Problema resuelto?** La contraseña ya no está escrita en el Deployment. En el archivo hay una cadena
ininteligible. Comprobemos.

## Un fallo predecible · «Secret» no significa «cifrado»

Intenta convencerte de que ahora todo está bien. Pregúntale al clúster qué hay dentro del secret:

```bash
# get … -o yaml = «muestra el objeto completo, exactamente como lo guarda el clúster».
# Mira el campo data — ese es el contenido del secret.
kubectl get secret passes-db -o yaml
```

Verás la misma cadena `UHJvcHVzazIwMTkh`. Parece ininteligible, y por tanto segura.

Ahora un comando:

```bash
#   -o jsonpath='{.data.password}'  extrae exactamente un campo del objeto, sin la envoltura
#   | base64 -d                     pásalo adelante y decodifícalo: d = decode
#   ; echo                          imprime un salto de línea final, si no el resultado se pega
#                                   al siguiente prompt de la terminal
kubectl get secret passes-db -o jsonpath='{.data.password}' | base64 -d; echo
```

> **Detente y piensa antes de seguir leyendo.**
>
> ¿Qué hiciste exactamente para obtener la contraseña? ¿Qué clave necesitaste? ¿Quién más puede
> ejecutar este comando?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

La salida es `Propusk2019!`. En texto plano.

**base64 no es cifrado, es codificación.** Se inventó para transportar bytes arbitrarios por canales
pensados para texto: adjuntos de correo, datos en JSON, binarios en archivos de configuración. No hay
clave en él, porque tampoco hay protección en él. Cualquiera puede revertirlo — cualquier persona,
cualquier navegador, cualquier sitio web decodificador.

Kubernetes usa base64 en un Secret exactamente por esta razón: no puedes poner bytes arbitrarios
(un certificado o una clave, digamos) en YAML, pero sí puedes ponerlos en base64. La palabra «Secret»
en el nombre del objeto significa «aquí van cosas sensibles», no «aquí están protegidas».

Qué significa esto en la práctica:

| Afirmación | ¿Verdad? |
|---|---|
| Un Secret está cifrado en el clúster | No. En el almacén de datos del clúster está en casi texto plano, a menos que un administrador haya activado por separado el cifrado en reposo |
| Un Secret puede subirse a Git | No. Eso es lo mismo que poner ahí la contraseña |
| Se puede ver quién ha leído un Secret | No. Una lectura común del objeto no queda registrada en ninguna parte |
| Un Secret no puede leerse sin permisos | Verdad, y esta es la única protección real. Los permisos en el clúster sí limitan el acceso |
| Un Secret se cambia solo según un calendario | No. Lo cambias tú, a mano, en todos los lugares a la vez |

**Una lección más amplia que este error.** Y lo principal. Incluso si todo esto estuviera resuelto,
queda la pregunta del auditor: **muéstrame quién leyó la contraseña durante el último mes.** Kubernetes
no tiene respuesta a eso en absoluto — no porque esté mal hecho, sino porque no es su tarea. Guardar
secretos es una tarea aparte, y para ella hay un servicio aparte.

Por cierto, tu rol en el tenant de Cozystack **no** te deja leer secrets vía `kubectl` — inténtalo y
recibirás una denegación. Pero el clúster de laboratorio del Lab 0 es enteramente tuyo, y allí eres el
administrador. Precisamente por eso funcionó el comando de arriba.

</details>

## Paso 3. Pide OpenBao

📍 **Dónde:** en el navegador, en el panel de Cozystack, en tu tenant.

Tenant → **Crear aplicación** → `OpenBAO`.

| Campo | Valor | Por qué |
|---|---|---|
| Nombre | `secrets` | corto, y tendrás que teclearlo en direcciones más adelante |
| Replicas | **1** | un entorno de pruebas de formación. Con dos o más el chart activa la replicación Raft, y eso ya es otro modo de almacenamiento |
| Size | `2Gi` | los secretos ocupan kilobytes; el espacio es para datos internos |
| Storage class | `replicated` | los datos se colocarán en tres copias en distintos nodos |
| Resources preset | `t1.small` | 1 CPU, 512 MB |
| UI | activado | la interfaz web dentro del clúster |
| External | desactivado | no lo exponemos hacia afuera |

⚠️ **Cambiar entre una copia y varias no es una casilla de verificación.** Una copia guarda los datos
en un archivo, varias los guardan en Raft. Cambiar de modo requiere migrar los datos, así que en
producción la decisión se toma antes de la instalación, no después.

### Lo mismo en texto — y un repaso por los campos

La carpeta de la práctica contiene `openbao.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: OpenBAO
metadata:
  name: secrets
  namespace: tenant-workshopXX
spec:
  replicas: 1
  size: 2Gi
  storageClass: replicated
  resourcesPreset: t1.small
  ui: true
  external: false
```

`apiVersion: apps.cozystack.io/v1alpha1` es el catálogo de Cozystack mismo, solo que visto desde el
lado donde parece una API. Cuando presionas el botón, el panel arma exactamente este objeto y lo envía
al clúster. El botón es una capa encima del texto, no una alternativa a él.

`kind: OpenBAO` es la posición en el catálogo. Cuida las mayúsculas: `OpenBAO`, no `OpenBao`. El clúster
es quisquilloso con las mayúsculas.

`namespace: tenant-workshopXX` — **los servicios gestionados viven en tu tenant en el clúster de gestión,
no en el clúster de laboratorio del Lab 0.** Son dos clústeres distintos, y es importante tenerlo
presente durante el resto de la práctica: la aplicación estará en uno, el almacén en el otro.

`replicas`, `size`, `storageClass`, `resourcesPreset` — lo mismo que rellenaste con el ratón.

`ui: true` — levanta la interfaz web. `external: false` — no le des al servicio una dirección externa;
desde dentro del clúster es accesible de todos modos.

Este archivo se aplica **no al clúster de laboratorio** sino al tenant:

```bash
# --kubeconfig nombra el archivo de acceso explícitamente y anula la variable KUBECONFIG.
# Así el pedido va al tenant en el clúster de gestión, no al clúster de laboratorio.
kubectl --kubeconfig ~/.kube/workshop apply -f openbao.yaml
```

El kubeconfig del tenant se toma del panel: **Info → pestaña Secrets →
`kubeconfig-tenant-workshopXX`**. Guárdalo en `~/.kube/workshop`.

En el resto del texto apenas usamos este archivo: los servicios se piden con el ratón, y el trabajo con
el propio OpenBao va por su propia API.

Espera hasta que la aplicación llegue a un estado listo. Eso es un minuto o dos.

## Paso 4. Prepara un Pod de trabajo y comprueba la conectividad

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

Aquí hay que detenerse y entender la disposición.

**OpenBao vive en tu tenant en el clúster de gestión.** Tu rol en el tenant te deja pedir y eliminar
servicios, pero no ejecutar tus propios Pods allí ni conectarte a servicios con port-forwarding. Esto
no es un defecto, es un límite: el tenant es un lugar para servicios gestionados, no un banco de trabajo.

**Tu banco de trabajo es el clúster de laboratorio del Lab 0.** Allí eres el administrador. Desde allí
llegaremos a OpenBao — por la dirección interna que tiene todo servicio:

```
openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
```

Descompongamos el nombre en partes:

| Parte | Qué significa |
|---|---|
| `openbao-` | un prefijo que el catálogo añade al nombre. Nombraste la aplicación `secrets`; los objetos recibieron nombres como `openbao-secrets…` |
| `secrets` | el nombre que diste en el panel |
| `tenant-workshopXX` | tu tenant. Sustituye por tu propio número |
| `svc.cozy.local` | la zona de nombres internos del clúster de gestión |
| `8200` | el puerto de la API de OpenBao |

Levantemos un Pod de trabajo. Dentro estará la utilidad `bao` — con ella comandaremos el almacén, y no
tendrás que instalarla en la laptop. Sustituye por tu propio número de tenant:

```bash
# run crea un único Pod a partir de la imagen dada — una maquinita desechable dentro del clúster.
#   --image          de dónde tomar el contenido: la imagen oficial de OpenBao con la utilidad bao
#   --restart=Never  no lo levantes de nuevo cuando el comando de dentro termine
#   --env            variable de entorno del Pod: cualquier comando dentro de él la verá
#   --command --     todo lo que va después de los dos guiones es el comando que el Pod ejecutará
# sleep 86400 = «no hagas nada durante un día»: necesitamos el Pod solo como espacio de trabajo.
kubectl run bao-workbench \
  --image=openbao/openbao:2.5.1 \
  --restart=Never \
  --env=BAO_ADDR=http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200 \
  --command -- sleep 86400
# wait retiene la terminal hasta que se cumpla la condición.
#   --for=condition=Ready  el Pod arrancó y está listo para aceptar comandos
#   --timeout=120s         ríndete tras dos minutos y devuelve un error
kubectl wait --for=condition=Ready pod/bao-workbench --timeout=120s
```

`BAO_ADDR` es la variable de la que la utilidad `bao` toma la dirección del almacén. Puesta una vez al
crear el Pod, nos ahorra `-address=…` en cada comando.

El Pod es un banco de trabajo desechable, nada que lamentar: al final de la práctica lo eliminaremos con
un comando.

Comprobemos que el tenant es visible desde el clúster de laboratorio:

```bash
# exec = ejecuta un comando dentro de un Pod ya en marcha; el comando en sí va después de --.
# bao status le pregunta al almacén por su estado: si está sellado, si está inicializado.
# Aquí sirve además como comprobación de conectividad: llegó una respuesta — así que el tenant es visible.
kubectl exec bao-workbench -- bao status
```

**Lo que deberías ver** — una tabla de estado. Los valores `Initialized false` y
`Sealed true` son correctos aquí: el almacén está en marcha, pero aún no está configurado y está cerrado:

```
Key                Value
---                -----
Seal Type          shamir
Initialized        false
Sealed             true
Total Shares       0
Threshold          0
Version            2.5.0
Storage Type       file
```

⚠️ **El comando devolverá un código de salida distinto de cero — 2, y eso no es un error.** Para
`bao status` el código de salida significa el estado del almacén, no el éxito del comando: 0 — desellado,
2 — sellado. Si tu shell resalta un código distinto de cero o ves la nota
`command terminated with exit code 2` — no te alarmes, todo va como debe.

⚠️ **Si el comando falla con `connection refused`, `no such host` o `i/o timeout` —**
no tiene sentido seguir; primero la conectividad. Causas comunes, en orden decreciente de probabilidad:
no sustituiste `workshopXX` por tu propio número; la aplicación en el panel aún no está lista; un error
de tecleo en el nombre. El nombre se construye por la regla `openbao-<nombre de la aplicación>`: nombraste
la aplicación `secrets`, así que la dirección contiene `openbao-secrets`, no `secrets`.

## Un fallo predecible · El almacén se niega a servir

Hay conectividad, así que podemos guardar la contraseña. Inténtalo:

```bash
# bao kv put = coloca un registro en el almacén.
#   secret/passes/db  la ruta donde vivirá
#   password=…        el contenido del registro: un par «nombre de campo = valor»
kubectl exec bao-workbench -- bao kv put secret/passes/db password=Propusk2026
```

**Lo que verás** — en lugar de una confirmación de escritura, una negativa:

```
Error making API request.
Code: 503. Errors:
* Vault is sealed
```

> **Detente y piensa antes de seguir leyendo.**
>
> El servicio está en marcha, el puerto responde, y sin embargo el almacén se niega a trabajar. ¿Por qué
> un servicio en marcha podría, a propósito, no atender solicitudes? ¿Y por qué eso es, muy probablemente,
> lo correcto?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

Mira con más atención la salida de `bao status` del paso anterior:

```
Sealed             true
Initialized        false
```

**Un almacén sellado es el estado normal de un OpenBao recién instalado.** Los datos en disco están
cifrados con la clave maestra, y la clave maestra no está en la memoria del proceso. Hasta que se coloque
allí, el servicio no puede ni leer ni escribir nada, y honestamente lo rechaza todo.

Durante el resto de la práctica, «desellar» significa exactamente una cosa: presentarle al almacén
fragmentos de la clave maestra para que ponga la clave en su memoria. La palabra no tiene nada que ver
con imprimir en papel.

Por qué está hecho así. Si la clave maestra estuviera junto a los datos cifrados, el cifrado no
significaría nada: quien robara el disco obtendría ambos. Por eso la clave vive **solo en la RAM** y
llega allí cuando una persona o un sistema externo la presenta.

De esto se sigue una consecuencia que conviene aceptar de inmediato: **después de cada reinicio del Pod,
OpenBao queda sellado de nuevo.** Se reinició un nodo, se actualizó una versión, el clúster reubicó el
Pod — y el almacén deja de responder otra vez hasta que se desella. En producción esto se resuelve con
auto-desellado mediante un módulo externo (un KMS en la nube, un HSM por hardware), y eso es un proyecto
en sí mismo. En la práctica desellaremos a mano y veremos el mecanismo en vivo.

**Una lección más amplia que este error.** **Un servicio gestionado te quitó de encima la instalación,
las actualizaciones, la replicación y los respaldos, pero no te quitó las decisiones operativas.**
Cozystack levantó el proceso de OpenBao por ti en dos minutos. Dónde guardar las claves de desellado,
quién puede desellar, qué hacer a las tres de la madrugada cuando un nodo se reinició — esas siguen siendo
tus preguntas, y qué bueno que la plataforma no las respondiera por ti en silencio.

</details>

## Paso 5. Inicializa y desella

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

**Lo que está por pasar:** OpenBao generará una clave maestra, la cortará en fragmentos y nos los
entregará junto con un token root. Esto no volverá a ocurrir una segunda vez — las claves se muestran
exactamente una vez.

```bash
# operator init se ejecuta una vez en la vida del almacén: crea la clave maestra e imprime
# sus fragmentos junto con un token root. Nadie mostrará estos valores de nuevo.
#   -key-shares=1     en cuántos fragmentos cortar la clave maestra
#   -key-threshold=1  cuántos fragmentos hay que presentar para reensamblarla
kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1
```

**Lo que deberías ver:**

```
Unseal Key 1: 8kJq…=
Initial Root Token: s.7Yx…
```

⚠️ **Copia ambos valores a un archivo en la laptop ahora mismo** — digamos en
`~/openbao-lab.txt`, y no solo al portapapeles. Nadie los mostrará de nuevo. Pierde la clave de desellado
y pierdes todos los secretos del almacén — recuperarlos es imposible por diseño.

Necesitarás ambos más de una vez, y he aquí cuándo:

- **la clave de desellado** — cada vez que el Pod del almacén se reinicie. Al reiniciarse queda sellado
  de nuevo, y todos los comandos empiezan a responder `Code: 503 ... * Vault is sealed`.
  La cura es desellar de nuevo con el mismo comando, desde el mismo punto donde lo dejaste;
- **el token root** — al final de la práctica, para el script de verificación. Entre estos dos momentos
  pasará casi toda la práctica, y para entonces lo más probable es que hayas cerrado la terminal.

<details>
<summary><b>Qué significan `-key-shares` y `-key-threshold`, y por qué en producción es distinto</b></summary>

La clave maestra no se entrega entera. Se corta en `key-shares` fragmentos, y para reensamblarla debes
presentar `key-threshold` de ellos. El esquema se llama Compartición de Secretos de Shamir.

El punto es que **ninguna persona sola pueda hacer el desellado**. La configuración clásica de producción
son cinco fragmentos con un umbral de tres: los fragmentos se entregan a cinco poseedores en distintos
departamentos, y para levantar el almacén tras un reinicio hay que reunir cualesquiera tres. Un
administrador que se va no se lleva el acceso consigo, y un administrador deshonesto no lo obtiene por
sí solo.

Ponemos un fragmento y un umbral de uno, porque en la práctica estás solo y queremos el mecanismo, no el
procedimiento. **No debes hacer esto en producción**, y eso no es una formalidad: un único fragmento
significa un único punto desde el que todo puede filtrarse.

</details>

Deséllalo. Sustituye por tu propia clave de desellado:

```bash
# unseal le entrega al almacén un fragmento de la clave maestra. Cuando los fragmentos alcanzan el umbral,
# la clave acaba en la memoria del proceso y el almacén empieza a atender solicitudes.
kubectl exec bao-workbench -- bao operator unseal <tu-clave-de-desellado>
# Repetimos status para ver el estado cambiado.
kubectl exec bao-workbench -- bao status
```

**Lo que deberías ver** — `Sealed  false` y `Initialized  true`.

Ahora iniciamos sesión con el token root. Quedará recordado dentro del Pod de trabajo, y los comandos
siguientes no pedirán el token:

```bash
# login intercambia el token introducido por una entrada en un archivo dentro del Pod — a partir de entonces la utilidad
# toma el token de allí por sí misma, y no tendrás que teclearlo en cada comando.
# -it le da al Pod una terminal: sin ella la utilidad no tiene dónde imprimir su prompt ni dónde recibir la entrada.
kubectl exec -it bao-workbench -- bao login
```

La utilidad pedirá el token y **no lo mostrará mientras lo tecleas** — es a propósito. Pega el
Initial Root Token de la salida de `init`.

⚠️ **Si `bao login` se queja de que no puede escribir el archivo del token**, pasa el token como variable
de entorno en cada comando:
`kubectl exec bao-workbench -- env BAO_TOKEN='tu-token' bao status`.
Funciona, pero el token acaba en tu historial de comandos — tolerable en la práctica, no en producción.

## Paso 6. Activa el motor y guarda la contraseña

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

Un OpenBao recién creado está vacío: no hay ni un solo lugar en él donde poner algo. Los motores de
secretos se activan explícitamente.

```bash
# secrets enable activa un motor — una parte del almacén que sabe hacer un tipo de trabajo.
#   -path=secret  en qué ruta colgarlo: de aquí en adelante todo se escribe como secret/…
#   kv-v2         qué motor exactamente: «clave-valor» con historial de versiones
kubectl exec bao-workbench -- bao secrets enable -path=secret kv-v2
```

<details>
<summary><b>Qué es un motor de secretos, y por qué hay más de uno</b></summary>

OpenBao no es un único almacén sino un conjunto de motores, cada uno de los cuales sabe su propio trabajo
y se monta en su propia ruta:

| Motor | Qué hace |
|---|---|
| `kv-v2` | guarda lo que pones en él, con historial de versiones. Un «clave-valor» corriente |
| motores de bases de datos | **ellos mismos** crean un usuario temporal en PostgreSQL o MongoDB por dos horas y lo eliminan ellos mismos |
| PKI | emite certificados bajo demanda, en lugar de una solicitud anual al departamento de seguridad |
| transit | cifra datos bajo demanda sin guardarlos: la clave nunca sale del almacén |

`-path=secret` — en qué ruta montarlo. De aquí en adelante todo acceso a este motor va por `secret/…`.

Tomamos `kv-v2` — el caso más simple: tenemos una contraseña lista que hay que guardar. Los motores de
bases de datos son mucho más interesantes: eliminan la contraseña permanente como fenómeno, emitiéndole
a la aplicación una cuenta temporal para cada ejecución. Ese es el siguiente nivel, y hay que crecer
hasta él; tiene sentido empezar aquí.

</details>

Guarda la contraseña:

```bash
# kv put escribe una versión nueva entera: los campos listados se convierten en su contenido.
# Puede haber cualquier número de campos; aquí hay dos — la contraseña y el nombre de usuario de la base de datos.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026 username=passes_app
```

**Lo que deberías ver** — una tablita con `version  1` y una hora de creación.

Comprobemos que se lee de vuelta:

```bash
# kv get lee el registro e imprime sus campos como tabla. Seguimos leyendo con el token root — es decir,
# comprobamos que el registro quedó, no que la aplicación vaya a tener permisos suficientes.
kubectl exec bao-workbench -- bao kv get secret/passes/db
```

## Paso 7. Concede acceso a la aplicación — a exactamente una línea

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

No debes darle a la aplicación el token root: con él se puede hacer cualquier cosa, incluido leer
secretos ajenos y eliminar el almacén. La aplicación necesita acceso de lectura a una sola ruta.

Escribamos una política:

```bash
# policy write guarda en el almacén una lista de permisos con nombre.
#   passes-read  el nombre de la política; luego se le concede a un token por este nombre
#   -            toma el texto de la política de la entrada estándar en vez de un archivo
#   -i           en kubectl exec: reenvía esa entrada dentro del Pod
# <<'HCL' … HCL es una forma de pasar texto multilínea directamente al comando, sin archivo.
kubectl exec -i bao-workbench -- bao policy write passes-read - <<'HCL'
path "secret/data/passes/db" {
  capabilities = ["read"]
}
path "secret/metadata/passes/db" {
  capabilities = ["read"]
}
HCL
```

<details>
<summary><b>Leyendo la política</b></summary>

Una política es una lista de rutas y lo que se permite en ellas. Todo lo que no se permite explícitamente
queda denegado; no hace falta escribir un «denegar» aparte.

```hcl
path "secret/data/passes/db" {
  capabilities = ["read"]
}
```

`secret/data/passes/db` es una ruta **en la API**, no en el sistema de archivos. En el motor `kv-v2`
está estructurada así: `secret` — donde se monta el motor, `data` — el prefijo interno propio del motor,
`passes/db` — lo que especificaste en el comando `kv put`.

⚠️ **Este prefijo `data` es la fuente de la mitad de todas las denegaciones desconcertantes.** En la
línea de comandos escribes `secret/passes/db`, pero en la política — `secret/data/passes/db`. La utilidad
`bao kv` inserta `data` por ti; la política no.

`capabilities = ["read"]` — solo lectura. No escribir, no eliminar, no listar rutas vecinas.

El segundo bloque, `secret/metadata/passes/db`, es acceso a la información de versiones: cuándo se
escribió, cuántas versiones hay, cuál es la actual. También solo lectura.

`bao policy write passes-read -` — el guion final significa «lee el contenido de la entrada estándar».
Por eso el comando se ejecuta con `kubectl exec -i`: la bandera `-i` reenvía la entrada dentro del Pod.

</details>

Emite un token con esta política:

```bash
# token create emite un token nuevo y le vincula un conjunto de permisos.
#   -policy=passes-read  qué permisos: la política escrita arriba
#   -ttl=24h             tiempo de vida; tras un día el token deja de funcionar por sí solo
#   -field=token         imprime solo el valor del token, sin la tabla alrededor —
#                        así es fácil copiarlo y pasarlo adelante
kubectl exec bao-workbench -- \
  bao token create -policy=passes-read -ttl=24h -field=token
```

**Lo que deberías ver** — una sola línea con el token.

Copia el token — lo necesitarás en un momento.

El tiempo de vida aquí no es una formalidad. El token se coló en un registro, acabó en un respaldo, se filtró
con la laptop — pasado mañana es inútil. Una contraseña en un manifiesto no tiene esa propiedad.

## Paso 8. Pon el token en el clúster y quita la contraseña del manifiesto

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

La aplicación necesita algo para demostrarle a OpenBao que es quien dice ser. El token es ese algo.

```bash
# create secret generic crea un objeto Secret directamente en el clúster, sin pasar por un archivo en disco.
#   passes-bao-token      el nombre del objeto; la descripción de la aplicación referenciará el secret por él
#   --from-literal=nombre=…  fija el valor como una cadena desde la línea de comandos
#                          (también existe --from-file, cuando el valor está en un archivo)
kubectl create secret generic passes-bao-token \
  --from-literal=token='pega-el-token-del-paso-anterior'
```

**Nota: un comando, no un archivo.** El token se crea directamente en el clúster y nunca llega a Git —
no hay ningún archivo al que pudiera llegar.

<details>
<summary><b>Secreto cero: una palabra honesta sobre lo que no vencimos</b></summary>

Una objeción razonable: quitamos la contraseña de la base de datos pero pusimos un token en el clúster.
¿No hemos cambiado simplemente un problema por otro?

No, y he aquí en qué se diferencia el token de la contraseña:

| | Contraseña en un manifiesto | Token en el clúster |
|---|---|---|
| Está en Git | sí, para siempre, en todo el historial de commits | no, se creó con un comando |
| Tiempo de vida | eterno | un día, luego muerto por sí solo |
| Qué concede | acceso total a la base de datos de pases | leer una línea en el almacén |
| Revocación | cambiar la contraseña en todos los lugares donde está escrita | un comando, al instante |
| Se puede ver quién lo usó | no | sí, en el registro de auditoría |

Pero esto no cierra del todo el problema, y fingir que lo hace sería deshonesto. **Siempre hay un secreto
con el que la aplicación demuestra su derecho a los demás.** Incluso tiene un nombre — secreto cero.
Eliminarlo es imposible: hay que identificarse con algo.

Lo que hacen con él los sistemas maduros:

- **Autenticación de Kubernetes.** OpenBao verifica el token de servicio del Pod contra el propio
  Kubernetes y emite el suyo a cambio. Entonces el «secreto cero» pasa a ser la identidad del Pod,
  otorgada por el clúster, en vez de una cadena que un humano puso allí
- **Tokens de un solo uso (response wrapping).** Un operador emite un token que puede usarse una vez. Si
  la aplicación recibe una denegación de «ya usado», el token fue interceptado — y eso se ve de inmediato

Ambos enfoques existen y funcionan, pero en esta práctica nos llevarían muy lejos. Ten presente que
existe un camino, y que la meta no es «cero secretos» sino «un secreto efímero, acotado y revocable en
lugar de una docena de eternos».

</details>

Ahora aplicamos el manifiesto limpio. Primero, sustituye por tu propio número de tenant:

```bash
# sed edita texto por el patrón s/qué-reemplazar/por-qué/g; g = en cada lugar de la línea,
# no solo el primero. -i significa «edita el propio archivo» en vez de imprimir el resultado
# en pantalla. En lugar de workshop03 del ejemplo, sustituye por tu propio número.

# macOS: las comillas vacías después de -i son obligatorias — de lo contrario sed tomará la siguiente palabra
# como extensión de archivo de respaldo y no reemplazará nada
sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
# Linux
sed -i 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
```

<details>
<summary><b>Un vistazo de cerca: qué hay dentro de secrets-demo.yaml</b></summary>

Empecemos por lo principal: **encuentra la contraseña en este archivo.** No está — ni en texto plano,
ni en base64, ni como referencia a un objeto en el que estaría.

```yaml
      volumes:
        - name: secrets
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
```

`emptyDir` es una carpeta temporal que vive tanto como el Pod y desaparece junto con él.
`medium: Memory` significa que no es un archivo en disco sino una región de RAM. La contraseña no llegará
al disco del nodo, ni a una instantánea de volumen, ni a un respaldo.

```yaml
      initContainers:
        - name: fetch-secret
          image: openbao/openbao:2.5.1
```

Un init container es un contenedor que se ejecuta **antes** que el principal y debe terminar con éxito.
Si falla, el principal no arranca en absoluto. Para obtener un secreto este es exactamente el
comportamiento que quieres: la aplicación no debería arrancar con una contraseña vacía y luego fallar en
su primera solicitud a la base de datos.

```yaml
              bao kv get -field=password secret/passes/db \
                | tr -d '\n' > /secrets/db_password
              chmod 0400 /secrets/db_password
```

Tomamos un campo y lo escribimos en un archivo. `tr -d '\n'` quita el salto de línea, por si apareciera:
una contraseña con un carácter de más al final no le servirá a la base de datos, y rastrear eso es
desagradable. `chmod 0400` — solo el propietario puede leerlo.

```yaml
          env:
            - name: BAO_ADDR
              value: http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: passes-bao-token
                  key: token
```

La dirección del almacén y el token. El token llega por referencia al objeto que creaste con un comando.
El archivo contiene solo el nombre del objeto, y un nombre no es un secreto.

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        fsGroup: 1000
```

Todo se ejecuta como non-root. `fsGroup` hace falta para que ambos contenedores — el que escribe el
archivo y el que lo lee — tengan acceso a la carpeta. Sin él, el init container escribirá un archivo que
el principal no podrá abrir, y pasarás media hora preguntándote en qué te equivocaste.

```yaml
          volumeMounts:
            - name: secrets
              mountPath: /secrets
              readOnly: true
```

La carpeta se le da al contenedor principal en solo lectura. La aplicación no puede ni corromper la
contraseña ni sustituirla.

</details>

**Aplícalo.** El Deployment pasará a una nueva versión: el init container irá al almacén, colocará la
contraseña en la memoria del Pod, y solo entonces arrancará la propia aplicación.

```bash
kubectl apply -f secrets-demo.yaml
# Esperamos hasta que la nueva versión haya reemplazado por completo a la vieja. Si el init container no logra obtener
# la contraseña, la espera no terminará — y ese es exactamente el comportamiento que queremos.
kubectl rollout status deploy/secrets-demo
```

## Paso 9. Verifica que la aplicación obtuvo su contraseña del almacén

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

Primero veamos qué dijo el init container:

```bash
# -c selecciona un contenedor dentro del Pod. Aquí hay dos, y sin -c kubectl no puede adivinar cuál
# quieres. fetch-secret es el que se ejecutó antes de que la aplicación arrancara.
kubectl logs deploy/secrets-demo -c fetch-secret
```

**Lo que deberías ver:**

```
contraseña obtenida de OpenBao, no está en el manifiesto
```

Ahora el servicio en sí:

```bash
# El contenedor principal: lee el archivo que colocó el init container.
kubectl logs deploy/secrets-demo -c app --tail=2
```

La huella ha **cambiado** — antes era `sha256:a609df223d57`, ahora es distinta. La aplicación está
trabajando con una contraseña nueva que no está en ningún archivo del repositorio.

Quitemos el secret ingenuo; ya no hace falta y solo estorba:

```bash
# delete elimina el objeto del clúster. La aplicación ya no lo referencia,
# así que la eliminación no romperá nada.
kubectl delete secret passes-db
```

## Paso 10. Rotación: cambia la contraseña sin tocar un solo archivo

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

De vuelta a la primera exigencia del auditor: «cambia la contraseña». Antes, eso significaba encontrar
cada lugar donde está escrita, corregirlos, hacer commit, desplegar y esperar que no se haya olvidado
nada.

Ahora:

```bash
# El mismo kv put. La versión anterior del registro no se borra — aparece una segunda junto a ella.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026-otoño username=passes_app
# rollout restart recrea los Pods de la aplicación sin cambiar ni una línea de su descripción.
# Para esto era todo: la nueva contraseña se recoge en el siguiente arranque.
kubectl rollout restart deploy/secrets-demo
kubectl rollout status deploy/secrets-demo
# La huella en el registro mostrará que la contraseña cambió, sin mostrar la contraseña misma.
kubectl logs deploy/secrets-demo -c app --tail=2
```

**Lo que deberías ver** — la huella ha cambiado de nuevo. Dos comandos, cero archivos cambiados, cero
commits.

⚠️ **La aplicación recoge el nuevo valor al reiniciar, no al instante.** Obtenemos el secreto con un
init container en el arranque — un enfoque simple y fiable, pero actualizar requiere un reinicio. Si un
servicio necesita recoger un secreto al vuelo, se añade un contenedor sidecar que relee el valor con un
temporizador y actualiza el archivo. Eso es más complejo, y no es por donde deberías empezar.

Veamos el historial:

```bash
# kv metadata get muestra no los valores sino información sobre las versiones del registro: cuántas hay,
# cuándo se creó cada una, y cuál es la actual ahora.
kubectl exec bao-workbench -- bao kv metadata get secret/passes/db
```

**Lo que deberías ver** — ambas versiones con sus horas de creación. El valor antiguo no ha desaparecido:
si resulta que la nueva contraseña no le sirve a la base de datos, hay a dónde revertir.

También puedes leer el valor anterior por completo:

```bash
# -version=1 lee la primera versión escrita en vez de la actual.
kubectl exec bao-workbench -- bao kv get -version=1 secret/passes/db
```

Esto es lo que es la **rotación**: reemplazar un secreto por uno nuevo según un plan, no después de que
haya ocurrido una filtración. Una regla como «las contraseñas de las cuentas de servicio se cambian una
vez por trimestre» pasa de inalcanzable a una línea en un calendario.

## Paso 11. El registro de auditoría: quién pidió qué

📍 **Dónde:** en la laptop, en el clúster de laboratorio.

La segunda exigencia del auditor — «muéstrame quién leyó la contraseña». Activemos el registro:

```bash
# audit enable activa un dispositivo de auditoría.
#   file              el tipo de dispositivo: escribe los registros como texto
#   file_path=stdout  en vez de un archivo en disco — a la salida estándar del Pod, de donde
#                     la plataforma recoge los registros
kubectl exec bao-workbench -- bao audit enable file file_path=stdout
# audit list lista los dispositivos activados — comprobación de que el comando de arriba pasó.
kubectl exec bao-workbench -- bao audit list
```

**Lo que deberías ver** — una tabla con un dispositivo activado de tipo `file`.

<details>
<summary><b>Qué entra en el registro de auditoría, y en qué se diferencia de un registro corriente</b></summary>

Desde este momento OpenBao escribe un registro **por cada solicitud a la API**: quién pidió (qué token,
qué política), qué exactamente, cuándo, desde qué dirección y qué se respondió. Hay dos registros por
solicitud — la solicitud misma y la respuesta a ella.

Tres diferencias respecto de un registro de aplicación conocido:

**Las denegaciones también se escriben.** Un intento de leer la ruta de otro deja rastro exactamente
igual que una lectura exitosa. Son las denegaciones las que le interesan al equipo de seguridad: las
lecturas exitosas son trabajo, mientras que una serie de denegaciones es reconocimiento.

**Los valores de los secretos no entran en el registro.** Las rutas, los nombres y los tokens se hashean;
los secretos mismos no se escriben. El registro puede entregarse hacia afuera sin entregar su contenido
junto con él.

**Si no hay dónde escribir el registro, OpenBao deja de funcionar.** Esta es una decisión deliberada: un
almacén que atiende solicitudes sin poder registrarlas es peor que uno caído. De ahí un corolario
práctico — no apuntes tu único dispositivo de auditoría a un archivo en un disco que puede llenarse.

⚠️ **No se te permitirá leer este registro en la práctica, y hay que decirlo claramente.** Lo dirigimos
a la salida estándar del Pod de OpenBao, y tu rol no puede leer los registros de los Pods en el tenant — el
tenant te entrega la gestión de los servicios, pero no el acceso a sus entrañas. En una instalación real
el recolector de registros de la plataforma toma el registro y lo pone donde lo mira el equipo de seguridad,
no tú vía `kubectl`.

Lo que sí puedes ver tú mismo es el historial de versiones del paso anterior
(`bao kv metadata get`): quién **escribió**, y cuándo, con precisión de segundos. No es una auditoría
completa, pero responde a la pregunta «cuándo se cambió la contraseña por última vez».

</details>

## La verificación

📍 **Dónde:** en la laptop, en la misma ventana de terminal donde trabajaste con `kubectl`.

```bash
cd labs/08-openbao
# El script lee estas tres variables de entorno, así que debes fijarlas antes de ejecutarlo
# y en la misma ventana de terminal.
export KUBECONFIG=~/lab.kubeconfig     # qué clúster verificar
export COZY_TENANT=workshop03          # tu número de tenant
export BAO_TOKEN='tu-token-root'       # el que imprimió bao operator init
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo configurarlo está escrito
al principio del Lab 0. Puedes completar la práctica sin WSL, pero no habrá artefacto de informe.

El script no verifica el hecho de que se aplicaron los manifiestos, sino el fondo del trabajo: el almacén
está desellado, el secreto se lee de vuelta con el token, hay más de una versión (así que hubo una
rotación), la auditoría está activada, y no hay ni una sola contraseña en texto plano en el manifiesto
de la aplicación.

Aparecerá al lado un archivo de informe. **Ni un solo secreto entra en el informe** — solo versiones,
nombres y huellas.

## Limpieza

```bash
# delete -f = «elimina del clúster todo lo descrito en este archivo».
kubectl delete -f secrets-demo.yaml
# Lo que se creó con un comando en vez de un archivo se elimina por nombre.
kubectl delete secret passes-bao-token
kubectl delete pod bao-workbench
```

El propio OpenBao se elimina en el panel: la aplicación `secrets` → eliminar.

Por qué esto es barato. Un almacén de secretos en una instalación clásica es un proyecto: un servidor,
clustering, certificados, un procedimiento de desellado, integración con el monitoreo. Aquí lo obtuviste
en dos minutos y lo devolviste en diez segundos, y el espacio que ocupaba queda liberado.

⚠️ **Al eliminarlo se borran todos los secretos de dentro.** La clave de desellado y el token root de un
almacén eliminado se convierten en cadenas inútiles. Si pusiste algo real ahí — recupéralo primero.

## Qué sabemos hacer ahora

- Explicarle a un colega por qué un Secret de Kubernetes no está «cifrado», y respaldarlo con un solo
  comando
- Pedir OpenBao, inicializarlo y desellarlo, entendiendo qué está pasando
- Poner un secreto en el almacén y conceder a la aplicación acceso a exactamente una ruta con un token
  efímero
- Cambiar una contraseña sin tocar un solo archivo del repositorio, y ver el historial de versiones
- Responder con claridad a la pregunta «quién leyó esta contraseña» — y entender de dónde viene la
  respuesta

## Y en vSphere esto sería

No hay análogo directo, y esa es la respuesta honesta. En la infraestructura clásica, las contraseñas de
las cuentas de servicio viven en tres lugares a la vez: en un archivo de configuración en una VM, en el
gestor de contraseñas del departamento, y en la cabeza de quien la configuró. La rotación significa un
recorrido por los tres, y por eso no se hace. La pregunta «quién la leyó» no tiene respuesta, porque
nadie registra la lectura de un archivo.

Está el vSphere Credential Store, está el Windows Credential Manager, están los gestores de contraseñas
corporativos — todos resuelven el problema de «a una persona le conviene guardar contraseñas». El
problema de «una aplicación obtiene la contraseña por sí misma, según una política, por un tiempo
limitado, y quedando registrada» no lo resuelven.

**Dónde vSphere es más conveniente, honestamente.** En nada de lo anterior — pero la conveniencia tiene
un precio, y he aquí cuál es.

Una contraseña en un archivo en una VM está **siempre disponible**: el host se reinició, la máquina
arrancó, el servicio leyó el archivo y empezó a funcionar. No hay que despertar a nadie a las tres de la
madrugada. OpenBao después de un reinicio está sellado, y hasta que se desella las aplicaciones no
arrancan. Esto añade un nuevo punto de fallo y un nuevo procedimiento a tu infraestructura — con personal
de guardia, con poseedores de claves, con un proceso documentado. El auto-desellado mediante un KMS
externo elimina este problema, pero añade una dependencia de ese mismo KMS externo.

Y segundo. Un archivo en disco lo entiende cualquier administrador de un vistazo. Rutas, políticas,
tokens, TTL, el prefijo `data` en medio de una ruta — este es un modelo aparte que el equipo tendrá que
aprender, y durante el primer par de meses será una fuente de denegaciones desconcertantes.

La ganancia aún pesa más, pero no es gratis, y deberías planear la migración con este costo en mente.
