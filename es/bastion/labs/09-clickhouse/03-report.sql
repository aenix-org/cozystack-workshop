-- Lab 9 · el informe que vino a pedir la dirección: cuántos invitados hay cada mes,
-- cuánto dura una visita en promedio, a qué hora llegan con más frecuencia y qué
-- entrada está más concurrida.
--
-- Dónde se ejecuta: en la VM, en el clúster de laboratorio, con el comando corto `ch`
-- del README:
--     cd labs/09-clickhouse && ch < 03-report.sql
-- Antes de esto, 01-schema.sql y 02-generate.sql deben haberse ejecutado.
--
-- Cómo leer el resultado: una fila por cada mes presente en los datos (hay
-- ocho de ellos), los meses en orden ascendente, con el número de invitados creciendo mes a mes.
--
-- Por qué un millón de filas se cuentan en milisegundos. ClickHouse almacena cada columna
-- como un archivo separado. Esta consulta toca tres columnas de siete — las otras cuatro,
-- incluida la más pesada guest_name, no se leen del disco en absoluto. En una base de datos donde una fila
-- está en disco de una sola pieza, habría que levantar el millón entero de filas con todos sus campos
-- solo para contar sobre tres de ellas. De ahí la diferencia en el tiempo.
-- Para verlo en números: añade la línea FORMAT JSON al final de la consulta — la respuesta
-- incluirá un bloque de estadísticas con el tiempo transcurrido y el volumen leído.
--
-- Una fila de informe por cada mes que apareció en los datos.
SELECT
    -- A qué mes atribuir el pase. toStartOfMonth convierte la hora exacta
    -- en el primer día del mes: un único valor por el que agrupar y ordenar,
    -- en lugar de un par «año más mes».
    toStartOfMonth(created_at)          AS month,
    -- Cuántas filas cayeron en el grupo — eso es «cuántos invitados por mes».
    count()                             AS guests,
    -- Duración media de la visita, redondeada a minutos enteros.
    round(avg(duration_min))            AS avg_minutes,
    -- La hora de llegada más frecuente — la mismísima hora punta. topK(1)(x) devuelve un array
    -- con el único valor más frecuente, [1] lo extrae de ahí (contando desde uno).
    topK(1)(toHour(created_at))[1]      AS peak_hour,
    -- La entrada más concurrida de este mes, con la misma técnica.
    topK(1)(entrance)[1]                AS busiest_entrance
-- Fíjate en lo que la consulta no tiene: subconsultas, tablas temporales ni joins.
-- Todo se calcula en una sola pasada sobre los datos.
FROM passes
-- Colapsar todas las filas de un mes en una única fila de respuesta.
GROUP BY month
-- Mostrar los meses en orden ascendente para que el crecimiento se lea de arriba abajo.
ORDER BY month
