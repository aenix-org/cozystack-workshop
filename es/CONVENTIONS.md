# Cómo escribir labs

Léelo antes de tu primera edición en cualquier lab. Este documento tiene un único objetivo:
que las quince labs se lean como un solo trabajo, y no como quince distintos.

## Quién es el lector

Un administrador de sistemas VMware. Ve Kubernetes por primera vez, o casi, y **eso está bien**:
el material está pensado exactamente para esta persona. Es inteligente, tiene veinte años de
experiencia y conoce a fondo la virtualización, las redes y el almacenamiento. Lo que no conoce
es nuestra terminología.

De ahí se sigue todo lo demás.

## Reglas de lenguaje

**Ningún término sin explicación la primera vez que aparece en esta lab.** No vale «ya se explicó
en otra lab»: las labs se hacen en cualquier orden. Explícalo a través de algo que el lector ya
conozca de vSphere.

**Palabras prohibidas:** «simplemente», «obviamente», «como de costumbre», «tan solo»,
«trivialmente». Si algo es de verdad obvio, no hace falta escribirlo. Si no lo es, «simplemente»
humilla al lector.

**Dirígete al lector directamente de «tú».** Sin remilgos, sin falsa camaradería, sin signos
de exclamación.

**No vendas.** Nada de «potente», «flexible», «resuelve todos los problemas de fábrica». El
beneficio se muestra con un hecho y una comparación, no con un adjetivo. En lugar de «Cozystack
ofrece alta disponibilidad»: «elimina un Pod y mira el reloj».

**Sé honesto sobre las carencias.** Si algo funciona peor que en vSphere, dilo. El lector lo
notará de todos modos, y si callamos, dejará de confiar en el resto.

## La estructura obligatoria de una lab

Un archivo `README.md` en la carpeta de la lab. El orden de las secciones es estricto.

1. **Título** — `# Lab NN · Nombre`
2. **Cabecera** — el tiempo, qué demuestra, qué hará falta
3. **Para qué** — una tarea de la vida real, no «ahora estudiaremos X». Una continuación del
   escenario transversal (ver más abajo)
4. **Glosario breve** — solo los términos nuevos de esta lab, en una tabla de tres columnas:
   término, qué es, «se parece a… pero». La tercera columna nombra la cosa de vSphere y, en la
   misma frase, dice en qué se diferencia el término de ella, en una sola frase y no en dos
   fragmentos sueltos en celdas distintas. No debe haber una columna aparte de «dónde falla la
   analogía»: fuera de contexto, su encabezado no significa nada
5. **Qué hay en la carpeta de la lab** — una tabla de todos los archivos de la lab: archivo, qué
   es, cuándo resulta útil. El lector no debe adivinar de dónde salió el `nombre.yaml` de un
   comando `apply`, ni si tiene que crearlo él mismo. Cada archivo que la lab aplica debe estar en
   su carpeta (o en una vecina, y entonces la ruta se escribe de forma explícita:
   `../03-scale/hpa.yaml`)
6. **Pasos** — una acción por paso
7. **Verificación** — cuál debe ser el resultado y cómo verlo
8. **Limpieza** — obligatoria, y con una explicación de por qué es barata
9. **Qué sabemos hacer ahora** — tres o cuatro puntos
10. **Y en vSphere esto sería** — una comparación honesta, incluyendo dónde vSphere es más cómodo

## El escenario transversal

Todas las labs son partes de una sola tarea de trabajo, no un conjunto de ejercicios.

**El planteamiento:** estás en el equipo de plataforma. El negocio te pide desplegar un
servicio interno llamado «Pases»: un empleado pide un pase para un invitado desde una app móvil,
seguridad ve la lista en el control de acceso y la dirección mira un informe una vez al mes.

Cada servicio aparece **por un dolor concreto**, no porque le haya llegado el turno:

| Qué aparece | Por qué |
|---|---|
| Harbor | seguridad prohibió descargar imágenes de internet |
| Redis | el directorio de empleados del sistema heredado tarda 800 ms en responder |
| MongoDB | los pases tienen campos distintos: de un solo uso, semanal, para un auto |
| OpenBao | una auditoría encontró la contraseña de la base de datos en un manifiesto |
| ClickHouse | la dirección quiere «cuántos invitados y cuándo son los picos» |
| Bucket | el equipo móvil no tiene dónde poner el APK |
| GitOps | somos tres, alguien cambió algo a mano y todo se cayó |
| Catálogo | las empresas subsidiarias quieren el mismo servicio para ellas |

Las labs 0–4 son práctica sobre una aplicación inofensiva, antes de que empiece la tarea real.
Esto se dice sin rodeos: «primero con rueditas».

## Recorrido por el código y los manifiestos

**Ningún YAML aparece en ningún lado sin un recorrido.** Ni un solo archivo que el lector aplique
sin entenderlo.

El recorrido va en un spoiler, para que el flujo principal no se hinche:

```markdown
<details>
<summary><b>Recorremos el manifiesto línea por línea</b></summary>

...línea por línea, en prosa...

</details>
```

En el recorrido explicamos **por qué hace falta el bloque**, no qué está escrito en él. Mal:
«`replicas: 1` es el número de réplicas». Bien: «`replicas: 1`: cuántas copias mantener en marcha.
Si una copia desaparece, el clúster crea una nueva sin preguntar. De ahí viene la autoreparación
de la siguiente lab».

## Fallos predecibles

**Cada lab, donde encaje, debe incluir una comprobación que no pasará.** El lector se topa con el
muro, lo diagnostica y llega por sí mismo a entender la necesidad del siguiente paso.

La forma es siempre la misma, y su orden nunca se reordena:

1. Proponemos comprobar, como si todo ya estuviera en su sitio
2. **Mostramos el error** — primero la salida, luego las preguntas. No al revés
3. Detenemos al lector
4. Un spoiler con la respuesta, y con una lección más amplia que este error concreto

Tres lugares donde la redacción está fijada al pie de la letra, para que las labs no se separen
entre sí.

La parada es siempre una cita destacada (block-quote), sin ⚠️ (ese marcador está reservado para
las trampas):

```markdown
> **Deténgase y piense antes de seguir leyendo.**
>
> Una pregunta. Una segunda pregunta, si la hay.
```

El encabezado del spoiler es siempre `La respuesta, y una lección más amplia que este error`.

El párrafo con la lección en sí, dentro del spoiler, abre así:
`**La lección es más amplia que este error.**`

El fallo debe ser real, no montado. Si un paso funciona, no hace falta romperlo artificialmente.

## Dos caminos: con el ratón y con texto

Cuando una acción está disponible tanto en el panel como a través de `kubectl`,
mostramos **ambos** y decimos cuándo es apropiado cada uno.

**Ninguno de los dos caminos se esconde en un spoiler.** Trabajar con texto no es un recurso de
respaldo para cuando el panel se cae: es exactamente aquello hacia lo que llevamos al lector,
porque una descripción en un archivo se puede revisar, poner en Git y revertir. El spoiler es para
recorrer los campos, no para la forma de trabajar en sí.

Los servicios gestionados (Harbor, Redis, MongoDB, ClickHouse, OpenBao, buckets, máquinas
virtuales) los conducimos por el panel: ahí es donde se capta la sensación de autoservicio.

La aplicación propia, a través de `kubectl` y Git: ahí se capta que la infraestructura es texto,
que se puede revisar y revertir.

## Nombres consistentes

Una misma cosa se llama igual en cada lab y en cada mensaje de chat. El lector recorre el material
en cualquier orden y no debería tener que adivinar que `lab` y «el clúster de laboratorio» son una
y la misma cosa.

| Cosa | Cómo la llamamos |
|---|---|
| La unidad de material | «lab». No «ejercicio de laboratorio», ni «módulo», ni «lección» |
| El clúster de laboratorio de la lab 0 | la aplicación `lab` |
| La aplicación de práctica de las labs 0–4 | `rickroll` |
| El servicio de producción de las labs 5–14 | «Pases» en el texto, `passes` en los manifiestos |
| El número de tenant | `workshopXX` en los marcadores, `workshop03` en los ejemplos resueltos |

Aparte: **las rutas a los archivos de acceso y los nombres de las variables de entorno son los
mismos en todas partes.** Si en una lab el kubeconfig del tenant está en una ruta y en una vecina
en otra, el lector decidirá que son dos archivos distintos y acabará guardando dos.

El nombre de una lab en su título y su nombre corto en la tabla del `README.md` raíz deben
reconocerse el uno en el otro. «Caché» en la tabla y «Una caché delante de un backend lento» en el
archivo son claramente la misma lab. Si la tabla dice una palabra y el título dice otra, el lector
abrirá archivos al azar.

El tiempo en la cabecera de la lab y el tiempo en la tabla del `README.md` raíz son el mismo
número. En la cabecera damos el tiempo completo, incluida la espera, y anotamos por separado cuánto
de él se va en esperar.

## Formato

- Las secciones y los pasos son ambos de nivel `##`. El encabezado de un paso:
  `## Paso N. Qué hacemos`. No usamos las palabras «parte», «etapa», «ejercicio»: en todos lados es
  «paso». Los subencabezados dentro de un paso son `###`, aunque más a menudo un spoiler encaja
  mejor
- Los comandos van en bloques con el lenguaje indicado: ` ```bash `, ` ```yaml `, ` ```sql `
- Antes de cada comando, qué va a ocurrir. Después, qué debería ver
- Líneas de no más de 100 caracteres
- Los emoji son solo marcadores funcionales: 📍 dónde se ejecuta, ⚠️ una trampa. Nada más en las
  labs. En los mensajes de chat se les suman 🖱 el camino con el ratón, 📄 un archivo del
  repositorio, ⏳ una espera larga, y con eso se cierra la lista
- Tablas en lugar de listas allí donde haya columnas

## Verificación

En cada carpeta hay un `check.sh`. El participante lo ejecuta él mismo y obtiene un informe: qué se
comprobó, qué pasó, qué no, y las evidencias adjuntas. Los requisitos para los scripts están en
`check/README.md`.

En el texto de la lab lo referenciamos en la sección «Verificación».

## Qué no hacer

- No referenciar números de paso de otras labs: se hacen en cualquier orden
- No referenciar un número de paso ni siquiera dentro de su propia lab («el fallo predecible del
  paso 7»): los pasos se desplazan al editar, y la referencia empieza a mentir en silencio. Escribe
  «un poco más adelante en la lab»
- No dar por hecho que la lab anterior se ha hecho, salvo que esté escrito en «qué hará falta»
- No dejar `TODO`, `TBD` ni marcadores de posición en el texto publicado
- No inventar campos de manifiesto ni nombres de Secret. Verifícalos contra
  `packages/apps/<app>/values.schema.json` en el repositorio cozystack
