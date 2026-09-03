# Lab 15 · Qué hacer el lunes

| | |
|---|---|
| **Tiempo** | 20 minutos, y ni un solo comando |
| **Qué demuestra** | Que lo aprendido puede aplicarse a tu propio parque, empezando por lo pequeño |
| **Qué necesitas** | Solo a ti y una lista de tus sistemas |

Aquí no hay comandos, ni tampoco `check.sh`: a este lab solo lo puede comprobar el lunes.
Una conversación sobre qué hacer a continuación, cuando el entorno de pruebas esté apagado y en el trabajo todo siga como estaba.

## Con qué nos quedamos

A lo largo de catorce labs construiste un servicio interno que funciona — «Pase», con el que un
empleado solicita un pase para un invitado, seguridad ve la lista en el control de acceso y la dirección
mira un informe una vez al mes. Cada parte no apareció por orden, sino a raíz de un dolor concreto:

| Qué apareció | Por qué |
|---|---|
| Tu propio registro de imágenes | El equipo de seguridad prohibió descargar imágenes de internet |
| Una caché | el directorio de empleados heredado tardaba 800 ms en responder |
| Almacenamiento de documentos | los pases tienen campos distintos: de un solo uso, semanal, para vehículo, grupal |
| Almacenamiento de secretos | una auditoría encontró la contraseña de la base de datos en un manifiesto |
| Una base de datos analítica | la dirección quería saber cuántos invitados hay y cuándo están los picos |
| Un `Bucket` | el equipo de móvil no tenía dónde poner los APK que compilaba |
| Infraestructura en Git | sois tres, alguien hizo un cambio a mano — y todo se cayó |
| Tu propia entrada en el catálogo | las filiales quisieron el mismo servicio para ellas |

No instalaste ni actualizaste ninguno de estos servicios: son entradas del catálogo de las que
se responsabiliza la plataforma. Lo único que instalaste y arreglaste fue tu propia aplicación.

A continuación — sobre cómo repetir esto fuera del entorno de pruebas.

## Por qué importa

El destino más habitual de una formación así es «interesante, pero a nosotros no nos va a funcionar». No porque
no vaya a funcionar, sino porque tras catorce labs no queda claro por dónde empezar en tu propia
infraestructura, donde hay trescientas VM y nadie recuerda qué hace la mitad de ellas.

Vamos a verlo por orden: por dónde empezar, qué no tocar y cómo explicarle el sentido a quien
firma el presupuesto.

## Por dónde empezar: tres candidatos para el primer movimiento

No con la aplicación más importante. Y tampoco con la más abandonada. Empiezas por aquella
donde equivocarse sale barato y el resultado se ve.

### Candidato uno: eso que ibas a reinstalar de todos modos

Todo el mundo tiene un sistema del que hace tiempo se decidió «habría que pasarlo a un SO nuevo» o
«ya toca actualizar la versión». Ese es el primer movimiento ideal: ibas a tocarlo de todos modos,
así que el riesgo ya está contemplado en el plan, y necesitas exactamente la misma cantidad de aprobaciones.

### Candidato dos: un entorno de pruebas o de demostración

Una copia de la aplicación de producción que no vas a echar de menos. Aquí pondrás a prueba tu propia capacidad de repetir
la migración, no la plataforma — a la plataforma ya la probaste en el taller. La diferencia es
que ahora son tus imágenes, tus redes y tus políticas de seguridad.

### Candidato tres: eso que está pidiendo recursos nuevos

Un equipo que viene a por un par de VM para un servicio nuevo es el caso más cómodo. No se migra
nada, todo se crea desde cero, y les muestras un panel de inmediato en lugar de un formulario
de solicitud. Ambas partes verán la diferencia de velocidad.

## Qué no tocar primero

**Un sistema con una licencia atada al hardware.** Revisa las condiciones antes de mover nada. Hay
productos que cuentan las licencias por los núcleos físicos del hipervisor, y el traslado puede acabar costando más
de lo que ahorra.

**Cualquier cosa que no entiendas.** Si un contratista instaló la aplicación hace siete años y desde entonces
nadie ha entrado en ella, la migración se convierte en una investigación. Es un trabajo que se puede hacer, pero no
el primero.

**Sistemas en clúster con su propia tolerancia a fallos.** Bases de datos con replicación, clústeres
de aplicaciones, todo lo que vigila sus propias copias. Aquí hay que decidir quién se responsabiliza ahora
de la tolerancia a fallos — la aplicación o la plataforma — y esa es una conversación aparte con el
dueño del sistema.

## Un orden que funciona

1. **Levanta un entorno de pruebas.** No para una migración — para tener dónde comprobar cualquier corazonada dentro de la
   misma hora, sin abrir una solicitud. Un servidor, una instalación, cero compromisos.
2. **Traslada un sistema de los de arriba.** Entero, con sus datos, hasta el punto de «funciona y los usuarios
   lo están mirando».
3. **Convive con él un mes.** Aquí aprenderás lo que ningún taller puede darte: cómo se comporta a
   las tres de la madrugada, qué se rompe durante una actualización, qué le falta a la monitorización.
4. **Solo ahora arma el plan para el resto.** Con cifras obtenidas en tu propio hardware, no
   de una presentación.

Entre los pasos 2 y 3 lo normal es que quieras acelerar. No lo hagas: un mes operando un sistema en
producción enseña más que diez sistemas trasladados en la misma semana.

## Cómo explicarle esto a la dirección

La conversación no será sobre tecnología. Suelen decidirla tres cosas.

**El coste de las licencias** — el argumento más habitual, pero también el más resbaladizo. Cuenta
con honestidad: en el ahorro entra no solo la línea que tachas, sino también el coste de tu tiempo en el traslado,
la formación del equipo, y el periodo en que ambas plataformas funcionan a la vez.

**La velocidad de aprovisionamiento de recursos.** Aquí tienes experiencia de primera mano: con tus propias manos
levantaste un clúster en diez minutos y una base de datos en cinco. Compáralo con lo que tarda la misma
solicitud en tu empresa. Esa es una cifra que el negocio entiende sin traducción.

**La independencia de un único proveedor.** Un argumento que ha ganado peso en los últimos años. Funciona
no por sí solo, sino en tándem con el primero: la capacidad de cambiar de plataforma es justamente lo que te da
una posición de negociación sobre el precio.

Lo que es mejor no prometer: que será más sencillo. No lo será — al menos no el primer año.
Será más barato, más rápido en el aprovisionamiento de recursos y libre de dependencia de un único proveedor, pero
no será más sencillo. Prometer sencillez es la forma más rápida de perder la confianza medio año después.

## Adónde acudir con las preguntas

- **La comunidad en Telegram** — el mismo chat en el que se desarrolló el taller. La pregunta «cómo hago esto
  bien» siempre es bienvenida.
- **Documentación** — [cozystack.io/docs](https://cozystack.io/docs/).
- **Código fuente** — [github.com/cozystack/cozystack](https://github.com/cozystack/cozystack).
  Si algo se comporta de forma distinta a lo escrito, normalmente es más rápido mirar en el chart que
  adivinar. Ya lo hiciste en el lab sobre tu propio registro.

## Qué sabemos hacer ahora

- Elegir el primer sistema a trasladar por el criterio de «barato equivocarse», no de «lo más importante»
- Distinguir los casos que conviene aplazar de los que conviene abordar ahora
- No prometerle a la dirección una sencillez que no va a haber
- Saber dónde preguntar cuando nadie alrededor conoce la respuesta

## Y en vSphere esto sería

La conversación sería más corta: ya sabes qué hacer el lunes, porque llevas diez años haciéndolo.
Esa es la diferencia — no en la tecnología, sino en el hecho de que aquí tendrás que
construir tus hábitos otra vez desde cero.

La buena noticia es que puedes irlos acumulando poco a poco, un sistema a la vez. La mala es que durante
los primeros meses trabajarás más despacio de lo que estás acostumbrado. La velocidad vuelve a medida que
los nuevos hábitos se acumulan — pero ese retraso tendrás que contemplarlo en tus plazos con antelación.
