-- Lab 9 · la tabla del registro de pases: una fila por cada marcaje del torniquete.
--
-- Dónde se ejecuta: en el portátil, en el clúster de laboratorio, con el breve comando `ch`
-- del README — envía el SQL a ClickHouse en el cuerpo de una petición POST corriente:
--     cd labs/09-clickhouse && ch < 01-schema.sql
-- La respuesta de CREATE TABLE es vacía — eso es precisamente el éxito.
--
-- Aquí no hay ni CREATE DATABASE ni CREATE USER: la base de datos y el usuario los creó el propio
-- servicio al hacer el pedido (el panel o el archivo clickhouse.yaml en esta misma carpeta).

-- IF NOT EXISTS — no protestar si la tabla ya existe. El archivo se puede aplicar dos veces.
CREATE TABLE IF NOT EXISTS passes
(
    -- Número del pase. UInt64 y UInt16 — enteros sin signo de 8 y de 2 bytes.
    -- El tamaño del tipo en ClickHouse se elige de forma deliberada: en mil millones de filas cada
    -- byte de más en una columna se convierte en un gigabyte de más en el disco.
    pass_id      UInt64,
    -- Cuándo pasó la persona el torniquete. Todo el informe se construye en torno a esta columna.
    created_at   DateTime,
    -- Nombre del invitado. Casi cada fila tiene el suyo, por eso un String normal.
    guest_name   String,
    -- Las tres columnas de abajo son LowCardinality(String): una cadena que tiene pocos valores
    -- distintos (hay cinco departamentos, tres entradas, cuatro tipos de pase). ClickHouse
    -- mantiene un diccionario para tal columna y escribe en el disco números, y no las palabras
    -- repetidas un millón de veces.
    -- Regla: hasta unos pocos miles de valores distintos — LowCardinality, más que eso —
    -- un String normal. Envolver así guest_name sería peor que no envolverlo:
    -- un diccionario de un millón de nombres únicos resultaría mayor que los propios datos.
    host_dept    LowCardinality(String),
    entrance     LowCardinality(String),
    pass_type    LowCardinality(String),
    -- Cuántos minutos pasó el invitado dentro. Dos bytes son más que suficientes.
    duration_min UInt16
)
-- El motor de la tabla — cómo ClickHouse almacena los datos en el disco. En las bases de datos
-- habituales no existe tal elección; aquí sí existe y se hace al crear la tabla.
-- MergeTree: cada inserción pone en el disco una parte nueva, y las partes se fusionan en segundo
-- plano en otras más grandes. De ahí la regla práctica — insertar en lotes de muchas filas.
-- Un millón de inserciones de una sola fila crearían un millón de partes y tumbarían el servidor.
ENGINE = MergeTree
-- La línea más importante del archivo, y se elige antes de que a la tabla lleguen datos.
-- ORDER BY fija el orden en que las filas están físicamente en el disco, y es también el único
-- índice de verdad: ClickHouse guarda marcas cada varios miles de filas y por ellas averigua
-- qué partes del archivo se pueden no leer en absoluto.
--
-- Consecuencia: «cuántos pases hubo en marzo» se convierte en la lectura de un solo tramo del
-- archivo, mientras que «encontrar el pase con el número 424242» se convierte en la lectura de
-- toda la columna pass_id, porque pass_id no está en la clave de ordenación. Esto no es un defecto,
-- sino el diseño.
--
-- Del mundo conocido: la misma decisión que en un archivo de papel — ordenar los pases por fechas
-- o por apellidos. Ordenados por fechas, la carpeta de marzo se saca al instante, mientras que un
-- Иванов concreto se busca recorriéndolo todo. Y nadie va a reordenar un millón de hojas de papel
-- a posteriori.
--
-- No hay PARTITION BY en el archivo, a propósito. Una partición es un conjunto aparte de partes
-- (normalmente por mes) que se puede descartar con un solo comando; esto es cómodo para la regla
-- «guardar dos años y no más». En ocho meses de datos de práctica las particiones añadirían partes
-- de más sin ningún beneficio, y recortar lecturas innecesarias es lo que aquí hace la clave de ordenación.
ORDER BY (created_at, entrance)
