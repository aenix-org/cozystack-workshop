-- Lab 9 · tabla del registro de accesos: una fila por cada marcaje del torniquete.
--
-- Dónde se ejecuta: en la VM, en el clúster de laboratorio, mediante el comando corto `ch`
-- del README — envía SQL a ClickHouse como cuerpo de una petición POST corriente:
--     cd labs/09-clickhouse && ch < 01-schema.sql
-- La respuesta de CREATE TABLE está vacía — así es como se ve el éxito.
--
-- Aquí no hay ni CREATE DATABASE ni CREATE USER: la base de datos y el usuario los creó el propio
-- servicio al pedirlo (el panel o el archivo clickhouse.yaml en esta misma carpeta).

-- IF NOT EXISTS — no protestar si la tabla ya existe. El archivo se puede aplicar dos veces.
CREATE TABLE IF NOT EXISTS passes
(
    -- Número de pase. UInt64 y UInt16 — enteros sin signo de 8 y de 2 bytes.
    -- En ClickHouse el tamaño del tipo se elige de forma deliberada: con mil millones de filas cada byte
    -- de más en una columna se convierte en un gigabyte de más en el disco.
    pass_id      UInt64,
    -- Cuándo pasó la persona por el torniquete. Todo el informe se construye en torno a esta columna.
    created_at   DateTime,
    -- Nombre del invitado. Casi cada fila tiene el suyo, por eso un String corriente.
    guest_name   String,
    -- Las tres columnas de abajo son LowCardinality(String): una cadena con pocos valores
    -- distintos (cinco departamentos, tres entradas, cuatro tipos de pase). ClickHouse
    -- mantiene un diccionario para tal columna y escribe en el disco números, en lugar de las mismas
    -- palabras repetidas un millón de veces.
    -- Regla: hasta unos pocos miles de valores distintos — LowCardinality, más que eso —
    -- un String corriente. Envolver así guest_name sería peor que no envolverlo:
    -- un diccionario de un millón de nombres únicos resultaría mayor que los propios datos.
    host_dept    LowCardinality(String),
    entrance     LowCardinality(String),
    pass_type    LowCardinality(String),
    -- Cuántos minutos estuvo el invitado dentro. Dos bytes bastan de sobra.
    duration_min UInt16
)
-- El motor de la tabla — cómo almacena ClickHouse los datos en el disco. En las bases de datos
-- habituales no existe tal elección; aquí sí la hay, y se hace al crear la tabla.
-- MergeTree: cada inserción deposita una parte nueva en el disco, y las partes se fusionan en segundo plano
-- en otras más grandes. De ahí la regla práctica — insertar por lotes de muchas filas.
-- Un millón de inserciones de una sola fila crearían un millón de partes y tumbarían el servidor.
ENGINE = MergeTree
-- La línea más importante del archivo, y se elige antes de que en la tabla entren datos.
-- ORDER BY fija el orden en que las filas yacen físicamente en el disco, y también
-- funciona como el único índice de verdad: ClickHouse guarda marcas cada
-- pocos miles de filas y a partir de ellas deduce qué partes del archivo se pueden no leer en absoluto.
--
-- Consecuencia: «cuántos accesos hubo en marzo» se convierte en leer un tramo del
-- archivo, mientras que «encontrar el pase con el número 424242» se convierte en leer toda la columna pass_id,
-- porque pass_id no está en la clave de ordenación. Esto no es un defecto, es el diseño.
--
-- Del mundo conocido: la misma decisión que en un archivo de papel — ordenar
-- los pases por fecha o por apellido. Ordenados por fecha, la carpeta de marzo
-- se saca al instante, mientras que un Ivanov concreto se busca recorriéndolo todo. Y reordenar
-- un millón de hojas de papel a posteriori nadie lo va a hacer.
--
-- No hay PARTITION BY en el archivo a propósito. Una partición es un conjunto separado de partes (normalmente
-- de un mes) que se puede tirar con un solo comando; esto es cómodo para la regla
-- «guardamos dos años y no más». Con ocho meses de datos de entrenamiento las particiones darían
-- partes de más sin beneficio, y recortar lecturas innecesarias aquí lo sabe hacer la clave de ordenación.
ORDER BY (created_at, entrance)
