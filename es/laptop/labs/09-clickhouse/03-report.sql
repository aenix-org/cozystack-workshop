-- Lab 9 · el informe que pidió la dirección: cuántos invitados hay cada mes,
-- cuánto dura en promedio una visita, a qué hora llegan con más frecuencia y qué entrada
-- está más cargada.
--
-- Dónde se ejecuta: en el portátil, en el clúster de laboratorio, con el comando corto `ch`
-- del README:
--     cd labs/09-clickhouse && ch < 03-report.sql
-- Antes de esto deben haberse ejecutado 01-schema.sql y 02-generate.sql.
--
-- Cómo leer el resultado: una fila por cada mes presente en los datos (hay
-- ocho), los meses en orden ascendente, el número de invitados creciendo de mes a mes.
--
-- Por qué un millón de filas se cuentan en milisegundos. ClickHouse almacena cada columna
-- en un archivo separado. Esta consulta toca tres columnas de siete — las otras cuatro,
-- incluida la más pesada, guest_name, no se leen del disco en absoluto. En una base donde una fila
-- se almacena en el disco por completo, habría que levantar el millón de filas con todos sus campos
-- para calcular sobre tres de ellos. De ahí la diferencia de tiempo.
-- Para verlo en cifras: añada al final de la consulta la línea FORMAT JSON — en la respuesta
-- aparecerá un bloque de estadísticas con el tiempo empleado y el volumen leído.
--
-- Una fila de informe por cada mes que apareció en los datos.
SELECT
    -- A qué mes atribuir el pase. toStartOfMonth convierte la hora exacta
    -- en el primer día del mes: un único valor por el que agrupar y ordenar a la vez,
    -- en lugar de un par «año más mes».
    toStartOfMonth(created_at)          AS month,
    -- Cuántas filas cayeron en el grupo — esto es «cuántos invitados por mes».
    count()                             AS guests,
    -- Duración media de la visita, redondeada a minutos enteros.
    round(avg(duration_min))            AS avg_minutes,
    -- La hora de llegada más frecuente — la mismísima hora punta. topK(1)(x) devuelve un array
    -- del único valor más frecuente, y [1] lo extrae de ahí (contando desde uno).
    topK(1)(toHour(created_at))[1]      AS peak_hour,
    -- La entrada más cargada de este mes, con el mismo truco.
    topK(1)(entrance)[1]                AS busiest_entrance
-- Fíjese en lo que la consulta no tiene: subconsultas, tablas temporales ni joins.
-- Todo se calcula en una sola pasada sobre los datos.
FROM passes
-- Colapsar todas las filas de un mes en una única fila de respuesta.
GROUP BY month
-- Mostrar los meses en orden ascendente, para que el crecimiento se lea de arriba abajo.
ORDER BY month
