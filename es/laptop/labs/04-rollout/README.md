# Lab 4 · Desplegar una nueva versión y revertir

| | |
|---|---|
| **Tiempo** | 30 minutos |
| **Qué demuestra** | Una versión puede cambiarse y revertirse bajo tráfico real, sin ventana de mantenimiento |
| **Qué necesitarás** | El clúster del lab 0, `rickroll` del lab 1, Fortio del lab 3, tres ventanas de terminal, un navegador |

## Por qué esto importa

El servicio «Pase» lo desplegarás una sola vez, pero lo actualizarás decenas de veces. En el esquema de siempre, cada actualización significa concertar una ventana, un sábado por la noche, una instantánea antes de empezar y una persona sentada mirando. Cuando el cambio cuesta tanto, los cambios se acumulan: en lugar de diez despliegues pequeños haces uno grande, y el grande se rompe con más facilidad.

Cuánto cuesta esto lo averiguaremos aquí con conejillos de indias — es decir, con el `rickroll` de práctica, no con «Pase». Cambiaremos la versión de la aplicación **justo en medio de la carga** — no en una hora tranquila, sino entre miles de peticiones por minuto — y observaremos el contador de errores. Después revertiremos, otra vez bajo carga.

## Glosario breve

| Término | Qué es | Se parece a… pero |
|---|---|---|
| **RollingUpdate** | Reemplazar las copias de una en una, no todas de golpe | **Actualizar VMs una por una a mano**, pero el clúster lo hace por sí mismo y se detiene si una copia nueva no arranca |
| **Revision** | Una instantánea guardada de la descripción de la aplicación | **Una instantánea de VM**, pero solo guarda la descripción — no hay datos dentro |
| **maxSurge** | Cuántas copias por encima del número solicitado pueden levantarse durante el despliegue | sin analogía directa; se cuenta como porcentaje de `replicas` y se redondea hacia arriba |
| **maxUnavailable** | Cuántas copias pueden apagarse sin esperar a un reemplazo | **Cuántas VMs apagas a la vez**, pero se redondea hacia abajo, así que con tres copias da cero |
| **readinessProbe** | Una comprobación de «listo para recibir tráfico» | **Una comprobación de estado en el pool del balanceador**, pero además frena el despliegue, en vez de solo sacar a un miembro del balanceo |
| **ReplicaSet** | Un conjunto de copias idénticas responsable de una versión de la descripción | **Un pool de VMs idénticas de una plantilla**, pero cada versión tiene su propio conjunto, y el anterior permanece al lado con cero copias |
| **EndpointSlice** | Una lista de las direcciones de las copias listas para recibir tráfico | **Una lista de miembros del pool del balanceador**, pero la mantiene el clúster por etiquetas, no el administrador a mano |
| **JSON Patch** | Una edición puntual de un solo campo por su ruta dentro de un objeto | sin analogía directa; la ruta apunta al **índice** de un elemento en una lista, no a su nombre |

## Qué hay en la carpeta del lab

Ya tienes todos los archivos — los recibiste junto con el repositorio. No hay nada que crear ni volver a teclear: dondequiera que abajo veas `kubectl apply -f name.yaml`, el archivo se toma de aquí.

```bash
# De aquí en adelante, todos los comandos se ejecutan desde esta carpeta: las rutas en `kubectl apply -f` se cuentan desde ella.
cd labs/04-rollout
```

| Archivo | Qué es | Cuándo viene bien |
|---|---|---|
| `rickroll-page-v2.yaml` | La segunda versión de la página — lo que desplegamos bajo carga | lo aplicas en tu clúster `lab` |
| `check.sh` | Una comprobación de que el despliegue transcurrió sin perder ninguna petición | lo ejecutas al final del lab |
| — | El generador de carga lo tomamos del lab vecino: `../03-scale/fortio.yaml` | |

## Paso 1. Preparar el terreno

📍 **Dónde:** en el portátil.

Antes del despliegue hay que hacer dos cosas, y ninguna es cosmética.

**Apagamos el autoescalado**, porque él también controla el campo `replicas`. Observar un despliegue mientras alguien cambia a la vez el número de copias es una forma garantizada de no entender qué pasó. Un mecanismo por campo.

**Ponemos tres copias**, para que el reemplazo se vea de una en una. Una copia aquí es un Pod: la unidad mínima de ejecución en el clúster, el contenedor de la aplicación junto con su entorno, la analogía más cercana a una sola VM. Con una copia el despliegue también transcurriría sin caída, pero solo verías «había un Pod, ahora hay otro» y no verías en qué orden el clúster los reemplaza.

```bash
# KUBECONFIG — el archivo con la dirección del clúster y las credenciales para entrar en él. Mientras
# la variable esté definida, cada comando kubectl va al clúster `lab`, no a aquel desde el que se lanzó.
export KUBECONFIG=~/lab.kubeconfig

# hpa — el autoescalador configurado en el lab de escalado. Lo eliminamos
# para que el número de copias cambie solo por orden nuestra.
#   --ignore-not-found  no tratarlo como error si ya no está en el clúster
kubectl delete hpa rickroll --ignore-not-found

# scale = «mantén esta cantidad de copias». El número entra en la descripción de la aplicación,
# y el clúster luego levanta por sí mismo las que faltan.
kubectl scale deployment rickroll --replicas=3

# rollout status = «espera hasta que lo solicitado se vuelva real». El comando mantiene la ventana
# ocupada hasta que las tres copias estén listas, y solo entonces devuelve el prompt.
kubectl rollout status deployment/rickroll
```

Comprueba que el generador de carga Fortio está en su sitio:

```bash
# get = «muestra lo que hay». La respuesta `Error from server (NotFound)` significa que no está.
kubectl get deployment fortio
```

Si no está, levántalo desde la carpeta vecina: `kubectl apply -f ../03-scale/fortio.yaml`.

## Paso 2. Poner la segunda versión en el clúster

📍 **Dónde:** en el portátil.

En la carpeta está `rickroll-page-v2.yaml` — la descripción de un objeto de tipo ConfigMap. Un ConfigMap mantiene un archivo de texto en el clúster, aparte de la aplicación, y luego el clúster coloca ese archivo dentro del contenedor. Aquí guarda la página que sirve nginx.

<details>
<summary><b>De cerca: qué hay dentro de rickroll-page-v2.yaml</b></summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rickroll-page-v2
data:
  index.html: |
    ...
    <div class="tag">VERSIÓN 2</div>
    <h1>We're No Strangers To Love</h1>
    ...
    <div class="pod">te atendió el Pod<b>__POD__</b></div>
```

Dentro hay una sola página: otro encabezado, otra gama de colores, una llamativa insignia «VERSIÓN 2». Las diferencias se hicieron deliberadamente vistosas — estarás mirando el navegador, no un diff.

Fíjate en dos cosas.

**`__POD__` sigue ahí.** La sustitución del nombre de la copia la hacen los ajustes de nginx del ConfigMap `rickroll-conf`, que es compartido por ambas versiones. Estamos cambiando la página, no el comportamiento del servidor.

**El nombre del objeto es `rickroll-page-v2`, no `rickroll-page`.** Esta es la decisión clave de todo el lab, y vale la pena explicar por qué.

La jugada obvia es otra: tomar el `rickroll-page-v1` existente y reescribir su contenido. Un comando, ningún objeto nuevo. No lo hagas, y aquí está por qué.

Primero, perderías el viejo. No habría reversión: la página anterior ya no existe en ningún sitio salvo en tu archivo — y si hiciste la edición con `kubectl edit`, ni siquiera está en el archivo.

Segundo, la actualización sería incontrolada. La descripción de la aplicación no cambia cuando editas un ConfigMap, lo que significa que el Deployment — el objeto que guarda esa descripción (qué imagen, cuántas copias, de dónde tomar los archivos) y se asegura de que se cumpla — no notaría nada y no iniciaría ningún despliegue. Aun así, el clúster cambiaría los archivos dentro de los Pods en ejecución — por sí mismo, en su propio momento, a lo largo de aproximadamente un minuto y en un orden arbitrario entre las copias. Obtendrías un cambio que no está en el historial, que no puede revertirse con un comando y que llegó a las copias de forma descoordinada.

De ahí la regla: **las versiones son objetos distintos, y cambiar de versión es un cambio en la descripción de la aplicación.** Así es exactamente como lo ve el Deployment, como aterriza en el historial de revisiones y como puede deshacerse.

</details>

Aplícalo. Aparece un segundo ConfigMap en el clúster; no tocará la aplicación en ejecución, porque todavía nada lo referencia:

```bash
# apply = «lleva el clúster a lo descrito en el archivo».
#   -f name.yaml   de dónde tomar la descripción; el archivo está en esta misma carpeta
kubectl apply -f rickroll-page-v2.yaml
```

**Lo que deberías ver:** `configmap/rickroll-page-v2 created`.

Ahora abre la aplicación y asegúrate de que **nada ha cambiado**:

```bash
# port-forward = un túnel temporal desde el portátil hacia dentro del clúster.
#   svc/rickroll  adónde lleva: al Service, es decir, con las peticiones repartidas entre las copias
#   8080:80       a la izquierda el puerto en el portátil, a la derecha el puerto del servicio dentro del clúster
# Mientras el túnel está abierto la ventana está ocupada; se cierra con Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> — la misma primera versión. Pusimos la nueva página en el clúster, pero la aplicación no sabe de ella: su volumen sigue apuntando a `rickroll-page-v1`. Cierra el túnel (`Ctrl+C`), esto todavía no es el despliegue.

## Paso 3. Entender cómo reemplazará el clúster las copias

📍 **Dónde:** en el portátil.

Antes de cambiar la versión, veamos las reglas que seguirá el reemplazo. Viven en la propia descripción de la aplicación:

```bash
# -o jsonpath=... — en lugar de una tabla, imprimir un solo campo del objeto indicando la ruta hacia él.
#   {.spec.strategy}  el bloque de reglas por las que el clúster reemplaza las copias
#   {"\n"}            un salto de línea al final, si no la salida se pega al prompt
kubectl get deployment rickroll -o jsonpath='{.spec.strategy}{"\n"}'
```

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

Este bloque no está en `rickroll.yaml` — el clúster rellenó los valores por defecto.

<details>
<summary><b>Qué significan estos porcentajes con nuestras tres copias</b></summary>

Ambos números se cuentan a partir de `replicas`, es decir, a partir de tres. Y redondean en direcciones opuestas.

**`maxSurge: 25%`** — cuántas copias pueden levantarse **por encima** del número solicitado mientras el reemplazo está en curso. El 25% de tres es 0,75, y redondear **hacia arriba** da 1. Así que durante el despliegue el clúster puede tener temporalmente cuatro copias.

**`maxUnavailable: 25%`** — cuántas copias pueden mantenerse **no disponibles** a la vez. El 25% de tres es el mismo 0,75, pero redondear **hacia abajo** da **0**.

Cero es una restricción dura. Al clúster no se le permite apagar ni una sola copia en funcionamiento hasta que haya aparecido un reemplazo listo. No «lo intentará» — no se le permite: esto es una restricción, no una intención.

De ahí el orden de operaciones en cada paso del reemplazo:

1. levantar una copia nueva (permitido por `maxSurge`);
2. esperar a que su `readinessProbe` responda con éxito;
3. añadirla al EndpointSlice, es decir, enviarle tráfico;
4. **solo ahora** sacar del balanceo y apagar una copia vieja;
5. repetir hasta que no queden copias viejas.

Todo depende del tercer y el cuarto punto, y ellos dependen del `readinessProbe`. Quita la comprobación de readiness del manifiesto y el clúster empezará a tratar una copia como utilizable en el momento en que el proceso arranca. El tráfico irá a un nginx que aún no ha leído su config, y obtendrás una tanda de 500. La comprobación de readiness aquí no es monitorización, es un **freno del despliegue**, y ese es su trabajo principal.

Un corolario útil: si la versión nueva está rota lo bastante como para no pasar la comprobación de readiness, el despliegue se **detendrá**. Las copias viejas siguen funcionando. Lo veremos hacia el final del lab, solo que la romperemos de otra manera.

</details>

## Paso 4. Encender la carga

Desplegar en silencio no tiene gracia — así se hacía también en vSphere. Enviemos tráfico y cambiemos la versión bajo él.

📍 **Ventana 1** — un túnel a Fortio:

```bash
# Una ventana de terminal nueva no recuerda las variables de la anterior — definimos KUBECONFIG de nuevo.
export KUBECONFIG=~/lab.kubeconfig
# Un túnel al generador de carga: puerto 8081 en el portátil → puerto 8080 del servicio fortio.
# A la izquierda se eligió 8081 para no chocar con el túnel a la propia aplicación en 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **En el navegador** — <http://localhost:8081/fortio/>. Rellena:

| Campo | Valor | Por qué así |
|---|---|---|
| URL | `http://rickroll/` | el nombre del Service — la dirección estable detrás de la cual están todas las copias; el tráfico irá por el balanceo, no a un Pod concreto |
| QPS | `300` | un fondo estable; no hace falta exprimir el máximo ahora mismo |
| Duration | `180s` | tres minutos — la ventana dentro de la cual conseguiremos tanto desplegar como revertir |
| Connections | `20` | |

Pulsa **Start** y **no toques el navegador hasta el final del lab**.

La misma carga puede generarse con un comando, si el formulario no funcionó:

```bash
# exec = ejecutar un comando dentro de un Pod ya en ejecución. La carga la genera no tu portátil,
# sino el propio Fortio desde dentro del clúster, así que no hace falta ningún túnel para esto.
#   deploy/fortio  en cualquier copia de la aplicación fortio
#   --             todo lo que va a la derecha es un comando para el contenedor, no para kubectl
#   -qps 300       trescientas peticiones por segundo
#   -c 20          veinte conexiones simultáneas
#   -t 180s        mantener la carga tres minutos
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **Ventana 2** — observando las copias:

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — mostrar solo los Pods con esta etiqueta; los demás no aparecerán en la salida.
# -w = «observa y añade»: la ventana queda ocupada e imprime una línea nueva cada vez
# que el estado de alguna copia cambia. Salir — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## Paso 5. Cambiar la versión

📍 **Ventana 3** — una ventana libre. La primera tiene el túnel a Fortio, la segunda está ocupada observando los Pods, así que ejecutamos el patch en la tercera. En ella hay que configurar el acceso de nuevo:

```bash
# Una ventana de terminal nueva no recuerda las variables de la anterior — definimos KUBECONFIG de nuevo.
export KUBECONFIG=~/lab.kubeconfig
```

Ahora cambiaremos exactamente un campo en la descripción de la aplicación: el volumen llamado `page` — la carpeta que se coloca dentro del contenedor — debe tomar su contenido del ConfigMap `rickroll-page-v2`. No hay un comando «actualiza la aplicación», y nunca lo habrá: solo hay un nuevo registro de cómo deben ser las cosas. El clúster notará por sí mismo la discrepancia con el estado real y empezará a reemplazar las copias.

```bash
# patch = cambiar un campo de un objeto de forma puntual, sin reescribir el objeto entero.
#   --type=json  el formato de la edición: «operación + ruta + valor»
#   op: replace  reemplazar lo que hay en esta ruta
#   path         la dirección del campo dentro del objeto; volumes/0 — el primer volumen de la lista (ver abajo)
#   value        el nuevo nombre de ConfigMap del que el volumen tomará la página
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v2"}]'
```

**Lo que deberías ver:**

```
deployment.apps/rickroll patched
```

⚠️ **Este patch es frágil, y hay que decirlo sin rodeos.** La ruta `/spec/template/spec/volumes/0/...` direcciona el volumen **por su índice en la lista**. En `rickroll.yaml` el volumen `page` va primero y `conf` segundo — hay incluso un comentario al respecto ahí. Pero si alguien los intercambia (y YAML no lo prohíbe de ninguna manera), ese mismo comando, sin un solo error, sobrescribirá el nombre de la config de nginx, y la aplicación se romperá de forma desconcertante.

<details>
<summary><b>Por qué lo hacemos así de todas formas, y cómo hacerlo bien</b></summary>

Tomamos JSON Patch porque muestra la mecánica en su forma pura: un comando, un campo, una consecuencia visible. Para un lab eso es valioso.

**Más seguro** — lo mismo con un merge patch corriente. Las listas en Kubernetes pueden fusionarse por una clave, y para `volumes` esa clave es `name`:

```bash
# Sin --type=json esto es un merge patch: describes un trozo del objeto en la misma forma
# que tiene en el manifiesto, y el clúster lo fusiona con lo que ya hay. La lista volumes se fusiona
# por la clave `name`, así que aquí se direcciona el volumen `page`, no «el volumen en tal índice».
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

Aquí el direccionamiento es por el nombre del volumen, el orden en la lista no importa, y no hay nada que confundir.

**Bien** — no hacer patch en absoluto. Un patch, igual que `kubectl edit`, cambia el objeto en el clúster pero no cambia tu archivo. Una semana después alguien aplica `rickroll.yaml` del repositorio, y la aplicación deriva silenciosamente de vuelta a la primera versión. Nadie entenderá por qué.

En el trabajo normal la versión se cambia así: editas una línea en el archivo, envías el cambio a revisión, y tras el merge la automatización lo aplica. Entonces el estado del clúster y el contenido del repositorio siempre coinciden. Es exactamente lo que haremos en el lab 5.

</details>

Observa cómo transcurre el reemplazo:

```bash
# rollout status imprime el progreso del reemplazo línea por línea y termina cuando todas las copias están actualizadas.
# Si el despliegue no converge, el comando devuelve un código de salida distinto de cero — cómodo para
# detenerlo en scripts.
kubectl rollout status deployment/rickroll
```

```
Waiting for deployment "rickroll" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "rickroll" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "rickroll" successfully rolled out
```

📍 **En la ventana 2** puedes ver entretanto cómo las copias se reemplazan de una en una: primero aparece una nueva y alcanza `1/1 Running`, y solo después una de las viejas pasa a `Terminating`.

Fíjate en la cola de los nombres: las copias nuevas tienen también la parte central cambiada — ese es un ReplicaSet distinto. El Deployment no rehízo el viejo, creó un segundo al lado y vierte las copias de uno al otro. El viejo no se ha ido a ninguna parte; tiene cero copias y espera entre bastidores:

```bash
# rs — abreviatura de ReplicaSet, un conjunto de copias de una versión de la descripción.
# DESIRED — cuántas copias se solicitan en este conjunto, READY — cuántas de ellas están listas para responder.
kubectl get rs -l app=rickroll
```

```
NAME                  DESIRED   CURRENT   READY   AGE
rickroll-6f4b9c8d57   0         0         0       48m
rickroll-7c5d4f9b21   3         3         3       40s
```

## Paso 6. Contar los errores

📍 **Dónde:** en el portátil, en la ventana 3 — se liberó tras el comando anterior.

Abre un túnel a la aplicación:

```bash
# El mismo túnel que al inicio del lab: puerto 8080 en el portátil → puerto 80 del servicio rickroll.
kubectl port-forward svc/rickroll 8080:80
```

📍 **En el navegador** <http://localhost:8080> — la página verde con la insignia «VERSIÓN 2». Refréscala unas cuantas veces: el nombre de la copia al pie cambia, porque el Service distribuye las peticiones entre las tres copias.

Cierra el túnel (`Ctrl+C`).

📍 **Ahora lo principal — la pestaña de Fortio.** Espera a que termine la ejecución y busca las líneas con los códigos de respuesta:

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**Cero errores.** La aplicación cambió su versión por completo, bajo tráfico continuo, y ninguna de las cincuenta y cuatro mil peticiones sufrió daño.

Pagamos por esto con un solo bloque en el manifiesto — ese mismo `readinessProbe` del lab 1. Sin él, el clúster habría sacado la copia vieja del balanceo antes de asegurarse de que la nueva estaba lista para responder, y esta línea tendría otro aspecto.

⚠️ **Unas decenas de errores entre decenas de miles de peticiones en lugar de cero** no es un entorno de pruebas roto. Sacar una copia del balanceo y detener el proceso dentro de ella ocurren en paralelo, y bajo tráfico rápido a un puñado de conexiones les da tiempo a colarse en ese hueco. Esto se cura con una pausa antes del apagado (`preStop`) y un drenaje ordenado de las conexiones en la propia aplicación. Deliberadamente no lo hacemos en el lab: es más útil saber que el hueco existe que suponer que se cierra por sí solo.

## Paso 7. Revertir

Arranca la carga en Fortio otra vez (los mismos parámetros) y, mientras corre, mira el historial de cambios:

```bash
# history = la lista de revisiones guardadas de la descripción. Cada línea es un estado al que puedes
# volver con un solo comando. CHANGE-CAUSE — una nota opcional sobre por qué se cambió.
kubectl rollout history deployment/rickroll
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

Dos revisiones. Cada una es una instantánea guardada de la descripción de la aplicación en el momento del cambio. La primera con `rickroll-page-v1`, la segunda con `v2`. Se conservan precisamente porque los ReplicaSets viejos no se eliminan: por defecto el clúster guarda los diez más recientes.

La reversión:

```bash
# undo sin parámetros adicionales = volver a la revisión anterior. Esto no es «rebobinar
# el tiempo», es un despliegue corriente de la descripción vieja: las copias se reemplazan de una en una, por las mismas
# reglas maxSurge y maxUnavailable.
kubectl rollout undo deployment/rickroll
# Esperamos hasta que la composición de las copias converja con la descripción.
kubectl rollout status deployment/rickroll
```

📍 **En la ventana 2** — el mismo procedimiento al revés: tres copias nuevas se levantan de una en una, tres actuales se marchan. `kubectl get rs -l app=rickroll` mostrará que las copias volvieron al primer ReplicaSet — el que estaba ahí colgado con cero.

📍 **En el navegador** la aplicación es de nuevo la primera versión.

📍 **En Fortio** — de nuevo `Code 200 ... (100.0 %)`.

**Compara esto con una reversión en vSphere.** Allí una reversión significa restaurar desde una instantánea: la máquina se apaga, los archivos se reponen, la máquina arranca. Minutos de indisponibilidad más la pérdida de todo lo que ocurrió después de tomar la instantánea. Aquí una reversión significa devolver la descripción a la revisión anterior, y no se diferencia en nada de un despliegue corriente: las mismas copias de una en una, la misma cero caída.

⚠️ **`CHANGE-CAUSE` está vacío, y eso es incómodo.** El historial guarda *qué* cambió pero no *por qué*. Dentro de un mes la revisión 2 no te dirá nada. Puedes rellenar la causa con la anotación `kubernetes.io/change-cause`, pero la verdadera respuesta a esta pregunta no es una anotación, es Git, donde cada cambio tiene un autor, una fecha y un mensaje de commit.

## Paso 8. Una comprobación que no va a pasar

El mecanismo está claro. Ahora veamos qué pasa cuando un despliegue sale mal — y eso ocurre más a menudo de lo que uno querría.

Imagina una mañana cualquiera: un compañero está preparando la tercera versión de la página, va con prisa y comete un error tipográfico en el nombre. El manifiesto, sin embargo, es válido — el clúster no está obligado a saber que ese objeto no existe. Reproduzcamos exactamente esto:

```bash
# El mismo patch que al cambiar a la segunda versión, pero con un error en el nombre del ConfigMap:
# no hay ningún objeto `rickroll-page-v3` en el clúster. La existencia de la referencia no se comprueba en la aceptación,
# así que el comando terminará con éxito.
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v3"}]'

# --timeout=90s — no esperar eternamente: al no obtener copias listas, el comando se rinde tras un
# minuto y medio y devuelve un error. El despliegue en sí no irá a ninguna parte y quedará colgado.
kubectl rollout status deployment/rickroll --timeout=90s
```

**Lo que verás:**

```
Waiting for deployment "rickroll" rollout to finish: 0 of 3 updated replicas are available...
error: timed out waiting for the condition
```

Mira la composición de las copias: tres anteriores funcionan, la nueva está atascada en el arranque.

```bash
# La columna READY cuenta los contenedores listos dentro del Pod: 1/1 — listo, 0/1 — no.
# STATUS dice exactamente dónde se atascó el arranque.
kubectl get pods -l app=rickroll
```

```
NAME                        READY   STATUS              RESTARTS   AGE
rickroll-6f4b9c8d57-4kk2p   1/1     Running             0          6m
rickroll-6f4b9c8d57-9dnvt   1/1     Running             0          6m
rickroll-6f4b9c8d57-lm7bq   1/1     Running             0          6m
rickroll-8b6a1e5c39-wr4tz   0/1     ContainerCreating   0          90s
```

> **Detente y piensa antes de seguir leyendo.**
>
> Aquí hay dos preguntas, y la segunda importa más que la primera. Primera: ¿por qué no arranca la copia nueva? Segunda: ¿qué le está pasando al servicio ahora mismo — está caído?

<details>
<summary><b>La respuesta, y una lección más amplia que este error</b></summary>

**Por qué la copia no arrancó.** Nunca creamos un ConfigMap llamado `rickroll-page-v3` — no está en el clúster. Pregúntale al clúster directamente:

```bash
# events — el registro de sucesos del clúster, la analogía más cercana a la pestaña Tasks & Events de vCenter.
#   --field-selector reason=FailedMount  quedarse solo con los registros sobre un montaje de volumen fallido
#   --sort-by=.lastTimestamp             ordenar por tiempo, los más recientes acaban abajo
#   | tail -3                            mostrar las tres últimas líneas, descartar el resto
kubectl get events --field-selector reason=FailedMount --sort-by=.lastTimestamp | tail -3
```

```
Warning  FailedMount  kubelet  MountVolume.SetUp failed for volume "page":
         configmap "rickroll-page-v3" not found
```

Fíjate: el comando `kubectl patch` terminó con éxito e imprimió `patched`. El clúster aceptó una descripción en la que la referencia no lleva a ninguna parte, y no dijo ni una palabra. No hay comprobación de que el ConfigMap exista cuando se acepta el manifiesto — solo sería posible en el momento en que arranca el Pod, que es exactamente lo que pasó.

**Y ahora la segunda pregunta, aquella para la que se hizo este paso.** Abre la aplicación justo en medio del despliegue atascado:

```bash
# El mismo túnel. El tráfico irá solo a las copias que pasaron la comprobación de readiness,
# es decir, a las tres viejas: la atascada no entró en el balanceo.
kubectl port-forward svc/rickroll 8080:80
```

Funciona. La primera versión, tres copias, sin errores. Si tenías carga corriendo en Fortio en ese momento — el informe sigue mostrando un cien por cien de 200.

**Un despliegue completamente roto no tiró el servicio.** Esto es consecuencia directa de `maxUnavailable: 0`, que calculamos al inicio del lab: al clúster no se le permitía apagar ni una sola copia en funcionamiento hasta obtener un reemplazo listo. No obtuvo reemplazo — así que tampoco apagó nada. El despliegue se detuvo exactamente donde empezó a romperse, y se quedó en ese estado.

**La lección es más amplia que este error.**

> Un despliegue fallido en Kubernetes por defecto **se atasca**, no se derrumba.

Esto pone patas arriba la lógica habitual de las actualizaciones. En el esquema «detén, actualiza, arranca» cualquier error a mitad de camino significa caída, y por eso las actualizaciones se hacen de noche, con gente al teléfono. En el esquema «levanta lo nuevo, asegúrate, cambia» un error significa que el cambio no ocurrió — y lo viejo sigue funcionando igual que antes.

De ahí la moraleja práctica para quien esté de guardia: **un despliegue atascado no es un incidente.** No te despertará de noche. Puede resolverse por la mañana — o revertir con un solo comando y resolverlo después.

Es exactamente lo que haremos ahora.

</details>

Cómo salir:

```bash
# Devolvemos la revisión anterior — aquella donde el nombre del ConfigMap está escrito correctamente.
kubectl rollout undo deployment/rickroll
# Esperamos hasta que la copia atascada desaparezca y la composición de las copias converja con la descripción.
kubectl rollout status deployment/rickroll
```

La copia atascada desaparece, y la descripción vuelve a la que funciona.

## Verificación

📍 **Dónde:** en el portátil, en la misma ventana de terminal donde trabajaste con `kubectl`.

```bash
# El script no cambia nada en el clúster: solo lee el estado e imprime un informe.
./check.sh
```

⚠️ **En Windows el script se ejecuta desde WSL**, no desde PowerShell — cómo instalarlo está escrito al inicio del lab 0. Sin WSL puedes completar el lab, pero no habrá informe-artefacto.

El script mira el fondo del asunto, no los comandos que tecleaste: el historial de la aplicación tiene varias revisiones (lo que significa que la versión realmente se cambió y se revirtió), el ConfigMap de la segunda versión está en el clúster, la aplicación responde por HTTP, y la página que sirve coincide con el ConfigMap al que apunta la descripción. Por separado comprueba el `readinessProbe` — sin él la cero caída no puede reproducirse.

## Limpieza

La aplicación `rickroll` se necesitará más adelante — no la eliminamos. Devuélvela a una copia:

```bash
# Dos copias de más liberarán la memoria del nodo — en las labs siguientes no habrá carga.
kubectl scale deployment rickroll --replicas=1
```

El generador de carga ya no hace falta:

```bash
# delete -f = eliminar exactamente los objetos listados en el archivo, y nada más aparte de ellos.
# La ruta lleva a la carpeta vecina, porque el archivo está donde el lab de escalado.
kubectl delete -f ../03-scale/fortio.yaml
```

El ConfigMap `rickroll-page-v2` puede dejarse tal cual: ocupa un par de kilobytes y no consume ni CPU ni memoria. Las descripciones en Kubernetes se guardan en la base de datos del plano de control y no cuestan nada mientras nada las referencie — a diferencia de una instantánea de máquina virtual, que ocupa espacio en el almacenamiento y ralentiza la máquina tanto más cuanto más tiempo vive.

## Qué sabemos hacer ahora

- Cambiar la versión de una aplicación bajo tráfico real y confirmar por el contador que no hubo errores
- Explicar de dónde viene la cero caída: `maxUnavailable`, `readinessProbe` y el orden «primero listo, luego cambiamos»
- Leer el historial de revisiones y revertir con un solo comando
- Entender por qué las versiones se hacen como objetos separados, no editando uno existente
- Saber que un despliegue roto se atasca en vez de tirar el servicio, y por qué eso no es un incidente

## Y en vSphere esto sería

Una ventana de mantenimiento, acordada de antemano. Una instantánea antes de empezar — minutos y espacio de almacenamiento. Una actualización in situ. Si no despegó — una restauración desde la instantánea, más minutos de indisponibilidad. Todo ello de noche, porque de día no se puede.

Aquí — un comando de día, bajo tráfico, y un segundo comando si no te gusta el resultado.

**Dónde vSphere es más cómodo, con honestidad.** Tres cosas.

Primero y ante todo: **una instantánea toma el estado entero, mientras que `rollout undo` toma solo la descripción.** Si, durante el tiempo en que la versión nueva estuvo funcionando, tu aplicación consiguió escribir algo en la base de datos o cambiar el esquema, la reversión devuelve el código y no devuelve los datos. Obtendrás la versión vieja sobre datos nuevos — a veces eso es peor que dejar las cosas como estaban. Una instantánea de VM te salva de esto, `rollout undo` no. Es precisamente por esto que las migraciones de esquema de base de datos se escriben para ser compatibles en ambos sentidos, y esa es una disciplina que Kubernetes te va a exigir allí donde vSphere no lo hacía.

Segundo, una reversión en vSphere devuelve absolutamente todo: paquetes instalados a mano, una edición hecha a una config por teléfono. Aquí solo se revierte lo que estaba descrito en el manifiesto. Cualquier cosa que alguien haya hecho por su cuenta no se revertirá, porque el clúster no sabe de ella.

Tercero, una instantánea no exige que la aplicación sepa funcionar en dos versiones a la vez. Pero `RollingUpdate` sí: durante el despliegue las copias viejas y nuevas atienden peticiones juntas, detrás de una sola dirección. Si son incompatibles entre sí — en formato de sesión, en esquema de datos, en protocolo — no habrá cero caída, habrá un desbarajuste. Para las aplicaciones que no están preparadas para esto existe la estrategia `Recreate`: apagarlas todas, luego levantarlas todas. Da caída, pero es predecible, y a veces es más honesto elegirla.
