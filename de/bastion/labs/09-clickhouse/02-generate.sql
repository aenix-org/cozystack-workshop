-- Lab 9 · Datengenerator: eine Million Drehkreuz-Datensätze, von ClickHouse selbst erfunden.
--
-- Wo es läuft: auf der VM, im Lab-Cluster, mit dem kurzen Befehl `ch`
-- aus der README:
--     cd labs/09-clickhouse && ch < 02-generate.sql
-- Zuvor muss die Tabelle angelegt sein — 01-schema.sql.
--
-- Wie lange zu warten ist: eine Million Zeilen wird in wenigen Sekunden berechnet und geschrieben,
-- vollständig innerhalb des Servers. Die Daten wandern nicht über das Netzwerk und laufen nicht durch Ihre VM.
-- Die Antwort des INSERT ist leer — das bedeutet Erfolg. Zum Prüfen: echo 'SELECT count() FROM passes' | ch
--
-- Führen Sie die Datei zweimal aus, und Sie erhalten zwei Millionen Zeilen: INSERT hängt nur an und
-- ersetzt nichts. Um von vorn zu beginnen: TRUNCATE TABLE passes, dann diese Datei erneut.
--
-- Unten steht ein einziger Befehl INSERT ... SELECT: die Zeilen kommen nicht von außen, sie werden
-- von der nachfolgenden Abfrage berechnet.
INSERT INTO passes
SELECT
    -- Ausweisnummer. number ist innerhalb des Generators eindeutig — also ist auch pass_id
    -- eindeutig.
    number AS pass_id,
    -- Die Eintrittszeit wird aus drei Teilen zusammengesetzt: Tag, Stunde und Minute. Jeder Teil
    -- ist eine eigene pseudozufällige Zahl, gewonnen als cityHash64(number, 'salt').
    -- cityHash64 ist eine schnelle Hash-Funktion: für dieselbe Eingabe liefert sie immer
    -- dasselbe Ergebnis, sodass die Daten reproduzierbar sind, während ein anderes Salt
    -- ('day', 'hour', 'minute', ...) aus einer einzelnen number so viele
    -- voneinander unabhängige Zufallswerte macht, wie Sie möchten.
    addMinutes(
        addHours(
            addDays(
                -- Der Ausgangspunkt ist der 1. Januar. Der Rest modulo 57600 ergibt eine Zahl bis 57599,
                -- und ihre Quadratwurzel ist ein Tag von 0 bis 239, also acht Monate.
                -- Die Quadratwurzel hier ist nicht zur Zierde: sie verdichtet die Durchgänge
                -- zum Ende des Zeitraums hin. Gäste werden mit der Zeit zahlreicher — wie
                -- im echten Leben, und genau dieses Wachstum will die Leitung im Bericht sehen.
                toDateTime('2026-01-01 00:00:00'),
                toUInt16(sqrt(cityHash64(number, 'day') % 57600))
            ),
            -- Die Ankunftsstunde wird nicht gleichmäßig "von 8 bis 18" genommen, sondern aus einem Array, in dem
            -- sich die Stunden mit unterschiedlicher Häufigkeit wiederholen: 10 kommt dreimal vor, 15 dreimal,
            -- 8 einmal. Das erzeugt zwei ausgeprägte Spitzen, vor dem Mittagessen und danach;
            -- der Bericht soll sie finden. Es ist gut, wenn die Testdaten das enthalten,
            -- was wir darin zu suchen beabsichtigen.
            -- Die Array-Nummerierung in ClickHouse beginnt bei eins, daher 1 + …
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
        ),
        -- Die Minuten innerhalb der Stunde sind noch ein weiterer unabhängiger Wert aus derselben number.
        cityHash64(number, 'minute') % 60
    ) AS created_at,
    -- Jede Zeile hat ihren eigenen Gästenamen: eine Million verschiedene Werte in einer Spalte.
    -- Etwas später im Lab werden Sie sehen, dass dies auf der Festplatte die schwerste Spalte ist.
    concat('Гость № ', toString(number)) AS guest_name,
    -- Die Abteilung des empfangenden Mitarbeiters: fünf Werte, gleichmäßig verteilt.
    ['Продажи', 'Разработка', 'Бухгалтерия',
     'Кадры', 'Логистика'][1 + cityHash64(number, 'dept') % 5] AS host_dept,
    -- Eingangspforte. Derselbe Trick, aber die Verteilung ist ungleichmäßig: «Северная» nimmt
    -- drei von sechs Zellen und erhält die Hälfte des Stroms, «Южная» ein Drittel, «Западная» den
    -- Rest. Gleichmäßig verteilte Daten wirken im Bericht unglaubwürdig und zeigen
    -- nichts.
    ['Северная', 'Северная', 'Северная',
     'Южная', 'Южная', 'Западная'][1 + cityHash64(number, 'entrance') % 6] AS entrance,
    -- Ausweistyp: sechs von zehn Zellen gehen an «разовый», zwei an «недельный»,
    -- je eine an «автомобильный» und «групповой» — genau so sieht es an der Pforte aus.
    ['разовый', 'разовый', 'разовый', 'разовый', 'разовый', 'разовый',
     'недельный', 'недельный',
     'автомобильный', 'групповой'][1 + cityHash64(number, 'type') % 10] AS pass_type,
    -- Besuchsdauer von 30 bis 329 Minuten. toUInt16 wird benötigt, weil die Spalte
    -- als UInt16 deklariert ist, während das Ergebnis der Arithmetik breiter ist und sich nicht von selbst verengt.
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
-- numbers(1000000) ist eine eingebaute Generator-Tabelle: eine Million Zeilen mit einer einzigen
-- Spalte number, die Werte von 0 bis 999999 enthält. Auf der Festplatte existiert sie nicht, sie wird
-- im Fluge berechnet. Braucht man mehr oder weniger Daten — nur diese Zahl ändert sich.
FROM numbers(1000000)
