## 1. Qué estamos haciendo en realidad

**Lee esto antes de tu primer comando. Todo lo que sigue tendrá más sentido.**

### Qué tienes ahora mismo

Un servicio interno de «Pedidos». En vSphere tiene asignadas **tres máquinas virtuales** —
exactamente como suele verse esto:

| Máquina | Qué hay en ella | Dirección |
|---|---|---|
| `app` | la aplicación `orders-api` en Java, CentOS 7 | — |
| `db` | PostgreSQL, instalado a mano | `192.168.10.30` |
| `mq` | Kafka, instalado a mano | `192.168.10.40` |

La aplicación está escrita en Spring Boot, corre como un servicio systemd corriente, y su
configuración vive en `/etc/orders/application.properties`. Y ahí está lo interesante:

```properties
spring.datasource.url=jdbc:postgresql://192.168.10.30:5432/orders
spring.kafka.bootstrap-servers=192.168.10.40:9092
```

**Las direcciones están fijadas a fuego.** No son nombres: son números. Alguien un día levantó tres
máquinas, tecleó las IP en la configuración, y desde entonces esos tres números sostienen toda la
instalación. Cambia la subred y la aplicación se cae. Mueve la base de datos a otro host y tienes
que abrir el archivo a mano y reiniciar el servicio.

Si acabas de reconocer tu propia infraestructura: sí, a todo el mundo le pasa lo mismo.

### Qué vamos a hacer al respecto

Movemos **solo `app`**. Las otras dos máquinas no van a ninguna parte — en su lugar tomamos
Postgres y Kafka ya listos del catálogo de Cozystack.

La diferencia es fundamental. Mover las tres VM podrías hacerlo sin nosotros — y acabarías con
el mismo zoológico, solo que sobre hardware nuevo. El mismo Postgres que instalaste allá por 2019,
que nadie actualiza y del que nadie hace respaldo, porque «para eso había un script, ¿no?». Un
servicio gestionado llega con replicación, respaldos y monitoreo, y dejas de pensar en él por
completo.

**Y en el proceso no se puede perder ningún dato** — los pedidos de todos estos años tienen que
trasladarse a la nueva base de datos. Ese es un paso aparte, y en una migración real es el que
más nervios cuesta.

Esa diferencia — «mover el zoológico» frente a «mover la aplicación y tirar el zoológico a la
basura» — es de lo que trata este taller.

El camino tiene tres fases.

**Fase 1 — sacar la imagen.** Hay que convertir el disco de la máquina virtual de vSphere a un
formato que Cozystack entienda, y ponerlo en algún lugar de donde el clúster pueda descargarlo.
Son los pasos 1–3.

**Fase 2 — levantar la máquina en su nuevo hogar.** A partir de la imagen exportada levantamos una
VM, ahora en Cozystack, y la hacemos volver en sí: no tendrá red, porque el hardware a su alrededor
ha cambiado. Son los pasos 4 y 6.

**Fase 3 — tirar el zoológico a la basura.** Levantamos Postgres y Kafka del catálogo, **sacamos
los datos de la vieja base de datos**, y reconfiguramos la aplicación para pasarla de las IP
clavadas a fuego a nombres como es debido. Son los pasos 5, 7, 8, 9.

> **Si nunca has trabajado con Kubernetes — no pasa nada, está pensado así.** Cada término se
> explica sobre la marcha, y el siguiente mensaje es un pequeño glosario donde todo esto está
> traducido al lenguaje de vSphere.
