-- Lab 9 · generador de datos: un millón de registros de torniquete, inventados por el propio ClickHouse.
--
-- Dónde se ejecuta: en el portátil, en el clúster de laboratorio, con el breve comando `ch`
-- del README:
--     cd labs/09-clickhouse && ch < 02-generate.sql
-- Antes de esto, la tabla ya debe estar creada — 01-schema.sql.
--
-- Cuánto esperar: un millón de filas se calcula y se escribe en unos segundos,
-- por completo dentro del servidor. Los datos no viajan por la red ni pasan por tu portátil.
-- La respuesta del INSERT está vacía — eso significa éxito. Para comprobar: echo 'SELECT count() FROM passes' | ch
--
-- Ejecuta el archivo dos veces y habrá dos millones de filas: INSERT solo añade y
-- no reemplaza nada. Para empezar de nuevo: TRUNCATE TABLE passes, y luego ejecuta este archivo otra vez.
--
-- A continuación hay un único comando INSERT ... SELECT: las filas no vienen de fuera, se calculan
-- mediante la consulta que sigue.
INSERT INTO passes
SELECT
    -- Número de pase. number es único dentro del generador — así que pass_id
    -- también es único.
    number AS pass_id,
    -- La hora de entrada se ensambla a partir de tres partes: día, hora y minuto. Cada parte es
    -- su propio número pseudoaleatorio, obtenido como cityHash64(number, 'sal').
    -- cityHash64 es una función hash rápida: para la misma entrada siempre da
    -- el mismo resultado, por lo que los datos son reproducibles, mientras que una 'sal' distinta
    -- ('day', 'hour', 'minute', ...) convierte un único number en tantos
    -- valores aleatorios mutuamente independientes como quieras.
    addMinutes(
        addHours(
            addDays(
                -- El punto de referencia es el 1 de enero. El resto módulo 57600 da un número hasta 57599,
                -- su raíz cuadrada es un día de 0 a 239, es decir, ocho meses.
                -- La raíz cuadrada aquí no es por estética: agrupa las entradas
                -- hacia el final del período. Con el tiempo hay más invitados — como
                -- en la vida real, y es precisamente este crecimiento lo que la dirección quiere ver en el informe.
                toDateTime('2026-01-01 00:00:00'),
                toUInt16(sqrt(cityHash64(number, 'day') % 57600))
            ),
            -- La hora de llegada no se toma de forma uniforme "de 8 a 18", sino de un array donde
            -- las horas se repiten con distinta frecuencia: 10 aparece tres veces, 15 tres veces,
            -- 8 una vez. El resultado son dos picos pronunciados, antes del almuerzo y después;
            -- el informe debe encontrarlos. Es bueno que los datos de prueba contengan aquello que
            -- pretendemos buscar en ellos.
            -- La indexación de arrays en ClickHouse empieza en uno, de ahí 1 + …
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
        ),
        -- Los minutos dentro de la hora son otro valor independiente más del mismo number.
        cityHash64(number, 'minute') % 60
    ) AS created_at,
    -- El nombre del invitado es único para cada fila: un millón de valores distintos en una sola columna.
    -- Un poco más adelante en la lab quedará claro que en disco esta es la columna más pesada.
    concat('Гость № ', toString(number)) AS guest_name,
    -- El departamento del empleado anfitrión: cinco valores, distribuidos por igual.
    ['Продажи', 'Разработка', 'Бухгалтерия',
     'Кадры', 'Логистика'][1 + cityHash64(number, 'dept') % 5] AS host_dept,
    -- La entrada. El mismo truco, pero la distribución es desigual: "Северная" toma
    -- tres celdas de seis y recibe la mitad del flujo, "Южная" un tercio, "Западная"
    -- el resto. Los datos uniformes parecen inverosímiles en un informe y no muestran
    -- nada.
    ['Северная', 'Северная', 'Северная',
     'Южная', 'Южная', 'Западная'][1 + cityHash64(number, 'entrance') % 6] AS entrance,
    -- Tipo de pase: seis celdas de diez van al de un solo uso, dos a cada semanal,
    -- una a cada uno de vehículo y grupo — así es como se ve en la entrada.
    ['разовый', 'разовый', 'разовый', 'разовый', 'разовый', 'разовый',
     'недельный', 'недельный',
     'автомобильный', 'групповой'][1 + cityHash64(number, 'type') % 10] AS pass_type,
    -- Duración de la visita de 30 a 329 minutos. toUInt16 es necesario porque la columna
    -- está declarada como UInt16, mientras que el resultado de la aritmética es más ancho y no se estrechará por sí solo.
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
-- numbers(1000000) es una tabla generadora incorporada: un millón de filas con una única
-- columna number que contiene valores de 0 a 999999. No está en disco, se calcula
-- sobre la marcha. Si necesitas más o menos datos, solo cambia este número.
FROM numbers(1000000)
