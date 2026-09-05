-- Lab 9 · Datengenerator: eine Million Drehkreuz-Durchgänge, von ClickHouse selbst erfunden.
--
-- Wo es läuft: auf dem Laptop, im Lab-Cluster, mit dem kurzen Befehl `ch`
-- aus der README:
--     cd labs/09-clickhouse && ch < 02-generate.sql
-- Zuvor muss die Tabelle bereits angelegt sein — 01-schema.sql.
--
-- Wie lange warten: eine Million Zeilen werden in wenigen Sekunden berechnet und geschrieben,
-- vollständig innerhalb des Servers. Die Daten wandern nicht über das Netzwerk und laufen nicht über Ihren Laptop.
-- Die Antwort des INSERT ist leer — das bedeutet Erfolg. Zum Prüfen: echo 'SELECT count() FROM passes' | ch
--
-- Führen Sie die Datei zweimal aus, und es gibt zwei Millionen Zeilen: INSERT hängt nur an und
-- ersetzt nichts. Um neu zu beginnen: TRUNCATE TABLE passes, dann diese Datei erneut ausführen.
--
-- Unten steht ein einziger INSERT ... SELECT-Befehl: die Zeilen kommen nicht von außen, sondern werden
-- von der nachfolgenden Abfrage berechnet.
INSERT INTO passes
SELECT
    -- Ausweisnummer. number ist innerhalb des Generators eindeutig — also ist auch pass_id
    -- eindeutig.
    number AS pass_id,
    -- Die Durchgangszeit setzt sich aus drei Teilen zusammen: Tag, Stunde und Minute. Jeder Teil ist
    -- seine eigene Pseudozufallszahl, gewonnen als cityHash64(number, 'Salz').
    -- cityHash64 ist eine schnelle Hash-Funktion: für dieselbe Eingabe liefert sie stets
    -- dasselbe Ergebnis, sodass die Daten reproduzierbar sind, während ein anderes 'Salz'
    -- ('day', 'hour', 'minute', ...) aus einer einzelnen number beliebig viele
    -- voneinander unabhängige Zufallsgrößen macht.
    addMinutes(
        addHours(
            addDays(
                -- Der Bezugspunkt ist der 1. Januar. Der Rest modulo 57600 ergibt eine Zahl bis 57599,
                -- ihre Quadratwurzel ist ein Tag von 0 bis 239, also acht Monate.
                -- Die Quadratwurzel ist hier nicht zur Zierde: sie verdichtet die Durchgänge
                -- zum Ende des Zeitraums. Mit der Zeit gibt es mehr Gäste — wie
                -- im echten Leben, und genau dieses Wachstum will die Führung im Bericht sehen.
                toDateTime('2026-01-01 00:00:00'),
                toUInt16(sqrt(cityHash64(number, 'day') % 57600))
            ),
            -- Die Ankunftsstunde wird nicht gleichmäßig „von 8 bis 18" genommen, sondern aus einem Array, in dem
            -- sich Stunden mit unterschiedlicher Häufigkeit wiederholen: 10 kommt dreimal vor, 15 dreimal,
            -- 8 einmal. Es ergeben sich zwei ausgeprägte Spitzen, vor dem Mittag und danach;
            -- der Bericht soll sie finden. Es ist gut, wenn die Testdaten das enthalten, was
            -- wir darin zu suchen beabsichtigen.
            -- Die Array-Indizierung beginnt in ClickHouse bei eins, daher 1 + …
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
        ),
        -- Die Minuten innerhalb der Stunde sind eine weitere unabhängige Größe aus derselben number.
        cityHash64(number, 'minute') % 60
    ) AS created_at,
    -- Der Gastname ist für jede Zeile eindeutig: eine Million verschiedene Werte in einer einzigen Spalte.
    -- Etwas weiter in der Lab wird sich zeigen, dass dies auf der Festplatte die schwerste Spalte ist.
    concat('Gast Nr. ', toString(number)) AS guest_name,
    -- Die Abteilung des empfangenden Mitarbeiters: fünf Werte, gleichmäßig verteilt.
    ['Vertrieb', 'Entwicklung', 'Buchhaltung',
     'Personal', 'Logistik'][1 + cityHash64(number, 'dept') % 5] AS host_dept,
    -- Der Eingang. Derselbe Trick, aber die Verteilung ist ungleichmäßig: „Nord" nimmt
    -- drei Zellen von sechs ein und erhält die Hälfte des Stroms, „Süd" ein Drittel, „West"
    -- den Rest. Gleichmäßige Daten wirken in einem Bericht unglaubwürdig und zeigen
    -- nichts.
    ['Nord', 'Nord', 'Nord',
     'Süd', 'Süd', 'West'][1 + cityHash64(number, 'entrance') % 6] AS entrance,
    -- Ausweistyp: sechs Zellen von zehn gehen an den Einmal-Ausweis, je zwei an den Wochen-,
    -- je einer an den Fahrzeug- und den Gruppen-Ausweis — so sieht es am Eingang aus.
    ['Einmalausweis', 'Einmalausweis', 'Einmalausweis', 'Einmalausweis', 'Einmalausweis', 'Einmalausweis',
     'Wochenausweis', 'Wochenausweis',
     'Fahrzeugausweis', 'Gruppenausweis'][1 + cityHash64(number, 'type') % 10] AS pass_type,
    -- Besuchsdauer von 30 bis 329 Minuten. toUInt16 wird benötigt, weil die Spalte
    -- als UInt16 deklariert ist, das Ergebnis der Arithmetik aber breiter ist und sich nicht selbst verengt.
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
-- numbers(1000000) ist eine eingebaute Generator-Tabelle: eine Million Zeilen mit einer einzigen
-- Spalte number mit Werten von 0 bis 999999. Auf der Festplatte existiert sie nicht, sie wird
-- im Flug berechnet. Braucht man mehr oder weniger Daten, ändert sich nur diese Zahl.
FROM numbers(1000000)
