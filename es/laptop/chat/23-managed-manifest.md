## 23. Una mirada más de cerca: qué hay dentro de 04-managed.yaml

```yaml
kind: Postgres
metadata:
  name: db
spec:
  replicas: 1
  size: 10Gi
  storageClass: local
  resourcesPreset: t1.micro
  users:
    orders:
      password: Orders2019!
  databases:
    orders:
      roles:
        admin: [ orders ]
```

`kind: Postgres` — otro elemento del catálogo, igual que `Bucket` en la primera fase. No estás instalando un motor de base de datos: lo estás pidiendo. La propia plataforma levanta los procesos, configura la replicación, arma un calendario de respaldos y conecta el monitoreo.

`users` y `databases` — la plataforma creará el usuario `orders`, la base de datos `orders` y otorgará a ese usuario derechos de administrador sobre esa base. No hay nada que crear a mano: por eso mismo el archivo de esquema que aplicamos más adelante no contiene comandos `CREATE DATABASE` ni `CREATE USER` — ya se ejecutaron por ti.

`replicas: 1` — una sola copia, un entorno de pruebas de práctica. En un sistema de producción configuras más, y entonces la propia plataforma lleva la cuenta de cuál es la primaria y hace conmutación por error (failover) ante una caída.

`resourcesPreset: t1.micro` — el tamaño, un paquete ya listo de CPU y memoria. El más pequeño.

⚠️ **La contraseña está en texto plano** justo en el archivo que subes al repositorio. Para un entorno de pruebas de práctica esto es aceptable; para uno de producción no lo es: allí la contraseña vive en un almacén de secretos, y la descripción conserva solo una referencia a ella.

Más abajo en el mismo archivo hay un objeto `kind: Kafka`.

**Qué es una cola y por qué está aquí.** Kafka es una cola de mensajes. Cuando la aplicación acepta un pedido, hace dos cosas: escribe el pedido en la base de datos y deja un mensaje en la cola — "llegó el pedido número tal". A partir de ahí otros programas leen ese mensaje — el que envía el correo al cliente, el que arma los informes. El sentido de esta capa es que la aplicación no necesita saber quién lo leerá, ni cuándo: dejó el mensaje y siguió adelante. Si en ese momento un lector está caído, el mensaje lo espera en la cola.

En nuestro entorno de pruebas no hay lectores; la cola está para completar el panorama: la aplicación escribe en ella al crear un pedido, y si Kafka no está disponible, la comprobación de estado informará honestamente que las cosas andan mal. Esto es exactamente lo que ocurre también en un sistema real.
