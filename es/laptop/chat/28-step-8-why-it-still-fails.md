## 28. Paso 8: por qué la aplicación sigue fallando

**La base de datos está vacía — la aplicación necesita su esquema**

📍 **Dónde:** dentro de tu propia VM. Ya está en la red del clúster y ve la base de datos por su nombre.

### Primero — una segunda comprobación que tampoco va a pasar

Corregimos las direcciones, la aplicación se reinició y su endpoint de comprobación de estado responde `200`. Parece que todo está listo. Probemos a crear un pedido:

```bash
curl -s -X POST localhost:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"item":"test order"}' -w '\nHTTP %{http_code}\n'
```

**Y llega un `500`.** Aunque hace un momento la comprobación de estado era `200`.

<details>
<summary><b>Por qué la comprobación de estado está en verde pero el pedido no se crea</b></summary>

Porque la comprobación de estado de esta aplicación mira solo el **hecho de la conexión** con la base de datos: la conexión se abrió, el servidor respondió — así que está «vivo». Si dentro están las tablas que necesita, eso no lo comprueba.

Y no hay tablas. Cuando pediste Postgres en el catálogo, te entregaron un **servidor vacío**: la base de datos `orders` y el usuario `orders` están creados, y nada más. En la máquina vieja las tablas existían — la aplicación las creó una vez, hace mucho, en su primer arranque, y con los años todos se olvidaron de eso.

De paso, acabas de ver, por añadidura, cuánto vale una comprobación de estado en verde. Dice «llegué a la base de datos», no «estoy funcionando». En un proyecto real es fácil montar sobre una comprobación así un monitoreo que muestre alegremente todo en verde mientras los usuarios no pueden hacer ni un solo pedido.

</details>

**Qué hacemos.** Llevamos la aplicación, no sus datos, así que las tablas hay que crearlas de nuevo. Esto se hace una sola vez, con un archivo que contiene una lista de comandos SQL. A un archivo así se le llama **esquema** — describe cómo está dispuesto el almacenamiento: qué tablas hay, qué campos tienen y de qué tipo.

<details>
<summary><b>Qué crea realmente este archivo — un desglose línea por línea</b></summary>

El archivo es `scripts/orders-schema.sql` en el repositorio. Contiene apenas dos comandos.

**El primero crea la tabla de pedidos:**

```sql
CREATE TABLE IF NOT EXISTS orders (
    id           BIGSERIAL PRIMARY KEY,
    item         TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'NEW',
    created_by   TEXT,
    processed_by TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);
```

Campo por campo:

- `id BIGSERIAL PRIMARY KEY` — el número de pedido. `BIGSERIAL` significa «la base de datos entrega ella misma el siguiente en orden», `PRIMARY KEY` significa «es único y por él se busca la fila».
- `item` — qué se pidió. `NOT NULL` — un pedido sin artículo no tiene sentido, y la base de datos no aceptará una fila así.
- `status` — el estado del pedido, `NEW` por defecto. Cambia a `PROCESSED` una vez que el mensaje ha pasado por Kafka.
- `created_by` / `processed_by` — quién lo creó y quién lo procesó. Justo aquí es donde la aplicación escribe `kafka`, y es este campo el que mostrará, en el paso 9, que la cola realmente funciona.
- `created_at` / `processed_at` — cuándo. `TIMESTAMPTZ` — una marca de tiempo con zona horaria.
- `IF NOT EXISTS` — «si la tabla ya existe, no hagas nada y no te quejes». Gracias a esto el archivo se puede aplicar de nuevo sin romper nada.

**El segundo agrega una fila de historial:**

```sql
INSERT INTO orders (...) SELECT '12x rack rails', 'PROCESSED', ...
WHERE NOT EXISTS (SELECT 1 FROM orders);
```

Esto es cosmético: para que en el paso 9 la lista de pedidos no esté vacía. `WHERE NOT EXISTS` significa «inserta solo si la tabla está vacía» — ejecutarlo de nuevo no creará un duplicado.

**Lo que falta deliberadamente en el archivo:** ni `CREATE DATABASE`, ni `CREATE USER`. Tanto la base de datos como el rol ya fueron creados por el catálogo de Cozystack cuando pediste Postgres en el paso 5. En esto consiste el sentido de un servicio gestionado: se encarga él mismo de la rutina, y lo único que te queda a ti es tu propio esquema.

</details>

> ⚠️ **Discrepancia en los comentarios del archivo.** La cabecera de `orders-schema.sql` dice que primero necesitas `GRANT CREATE,USAGE ON SCHEMA public` como superusuario. **Esto está desactualizado, no lo hagas** — el rol `orders` pertenece a `orders_admin`, que es dueño de la base de datos y del esquema, así que ya tiene los permisos. Verificado. Corregiremos el comentario en el archivo.
