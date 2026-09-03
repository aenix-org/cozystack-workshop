## 24. Paso 5: base de datos y cola desde el catálogo

**Levantamos Postgres y Kafka gestionados**

📍 **Dónde:** en la laptop.

En el sistema original, la base de datos y la cola vivían en VM de CentOS 7 separadas — las mismas
`192.168.10.30` y `192.168.10.40` de la configuración. Esas **no las trasladamos**: en su lugar tomamos
los servicios de la plataforma. Parchear un sistema operativo obsoleto ya no es tu trabajo.

<details>
<summary><b>Por qué la aplicación necesita una cola y qué hace en realidad</b></summary>

Es una pregunta justa: la base de datos se entiende para qué sirve, pero la cola qué pinta aquí.

**Cómo funciona la aplicación.** Un usuario crea un pedido. Si la aplicación hiciera todo el
trabajo de una vez — registrara el pedido, hiciera los cálculos, enviara el correo, avisara al sistema vecino —
el usuario esperaría hasta que todo eso terminara. Y si el sistema vecino estuviera caído, esperaría
hasta que se agotara el tiempo de espera y recibiría un error, aunque el pedido ya estuviera creado.

Por eso el trabajo se parte en dos. La aplicación escribe el pedido en la base de datos con estado `NEW`,
pone un mensaje «apareció el pedido №123» en la cola y **le responde al usuario de inmediato**.
A partir de ahí, un manejador toma el mensaje de la cola a su propio ritmo, hace la parte pesada y
le pone al pedido el estado `PROCESSED`.

Justo por eso la tabla tiene un campo `processed_by`. En el paso 9 verás allí el valor
`kafka` — y esa será la prueba de que la cadena «aplicación → cola → manejador»
se ha vuelto a armar en su nuevo hogar.

**Cómo era en vSphere.** Una VM separada, con Kafka y ZooKeeper instalados a mano en ella.
Quién los instaló, se desconoce; la versión, la que hubiera en ese momento; nunca hubo actualizaciones,
y no hay monitoreo. La clásica máquina que a todos les da miedo reiniciar.

**Por qué la cola no hace falta trasladarla pero la base de datos sí.** La diferencia está en lo que guardan.
La base de datos contiene todos los pedidos de toda la historia — piérdela, y la empresa pierde datos. La cola
contiene solo los mensajes que están en tránsito ahora mismo — segundos de vida. Una migración correcta de la
cola consiste en dejar que el manejador termine de procesar lo que queda y cambiar a la nueva.
No hay nada que copiar.

Esta es una regla general que vale la pena llevarse del taller: **en una mudanza, con lo que sufres es
con aquello que guarda estado.** Todo lo demás se recrea desde cero.

</details>

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

No se levantan al instante — mientras esperas, mira en el panel qué fue exactamente lo que se creó.

**Qué se creó:** un objeto **Postgres** con nombre `db` — con una base de datos `orders`
y un usuario `orders` dentro — y un objeto **Kafka** con nombre `kafka` con un topic `orders`.
No cambies los nombres: de ellos dependen las direcciones de abajo y los comandos de los pasos siguientes.

🖱 **Vía el panel:** este es el paso más visual para el ratón. El catálogo de la plataforma —
**Postgres → Deploy new**: nombre `db`, una réplica, en la sección users un usuario
`orders`, en la sección databases una base de datos `orders`. Luego **Kafka → Deploy new**: nombre `kafka`,
una réplica, topic `orders`.

**No hace falta anotar nada, pero aquí están las direcciones — vendrán bien en el paso 7.** Desde dentro
del clúster, la base de datos y la cola son accesibles por nombre:

• Postgres — `postgres-db-rw.tenant-workshopXX.svc.cozy.local:5432`
• Kafka — `kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local:9092`

Estas dos líneas son exactamente lo que, dentro de dos pasos, reemplazará a las direcciones fijas `192.168.10.30`
y `192.168.10.40` en la configuración de la aplicación. Te las enviaré como comandos ya listos; tú
sustituirás tu propio número en lugar de `XX`.

Recuerda la diferencia en sí: antes la aplicación iba a una dirección fija, ahora va por nombre.
Una dirección puede cambiar, un nombre permanecerá.
