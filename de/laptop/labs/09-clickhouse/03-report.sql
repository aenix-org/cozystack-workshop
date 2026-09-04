-- Lab 9 · der Bericht, nach dem die Geschäftsführung gefragt hat: wie viele Gäste in jedem Monat,
-- wie lange ein Besuch im Schnitt dauert, zu welcher Stunde sie am häufigsten kommen und welcher Eingang
-- stärker ausgelastet ist.
--
-- Wo es läuft: auf dem Laptop, im Lab-Cluster, mit dem kurzen Befehl `ch`
-- aus der README:
--     cd labs/09-clickhouse && ch < 03-report.sql
-- Zuvor müssen 01-schema.sql und 02-generate.sql ausgeführt worden sein.
--
-- Wie das Ergebnis zu lesen ist: eine Zeile pro Monat, der in den Daten vorkommt (es sind
-- acht), die Monate in aufsteigender Reihenfolge, die Gästezahl wächst von Monat zu Monat.
--
-- Warum eine Million Zeilen in Millisekunden gezählt werden. ClickHouse speichert jede Spalte
-- als separate Datei. Diese Abfrage berührt drei Spalten von sieben — die übrigen vier,
-- einschließlich der schwersten, guest_name, werden gar nicht von der Festplatte gelesen. In einer Datenbank, in der eine Zeile
-- vollständig auf der Festplatte liegt, müsste man alle Million Zeilen mit allen Feldern laden,
-- nur um über drei davon zu rechnen. Daher der Unterschied in der Zeit.
-- Um es in Zahlen zu sehen: hängen Sie die Zeile FORMAT JSON ans Ende der Abfrage an — in der Antwort
-- erscheint ein Statistikblock mit der aufgewendeten Zeit und dem gelesenen Volumen.
--
-- Eine Berichtszeile pro Monat, der in den Daten aufgetaucht ist.
SELECT
    -- Welchem Monat der Durchgang zuzuordnen ist. toStartOfMonth verwandelt die genaue Zeit
    -- in den ersten Tag des Monats: ein einziger Wert, nach dem gruppiert und sortiert wird,
    -- statt eines Paares aus "Jahr plus Monat".
    toStartOfMonth(created_at)          AS month,
    -- Wie viele Zeilen in die Gruppe gefallen sind — das ist "wie viele Gäste pro Monat".
    count()                             AS guests,
    -- Durchschnittliche Besuchsdauer, auf ganze Minuten gerundet.
    round(avg(duration_min))            AS avg_minutes,
    -- Die häufigste Ankunftsstunde — eben die Stoßzeit. topK(1)(x) gibt ein Array
    -- aus dem einen häufigsten Wert zurück, und [1] holt ihn dort heraus (Zählung ab eins).
    topK(1)(toHour(created_at))[1]      AS peak_hour,
    -- Der am stärksten ausgelastete Eingang dieses Monats, mit demselben Kniff.
    topK(1)(entrance)[1]                AS busiest_entrance
-- Beachten Sie, was die Abfrage nicht hat: Unterabfragen, temporäre Tabellen und Joins.
-- Alles wird in einem einzigen Durchgang über die Daten berechnet.
FROM passes
-- Alle Zeilen eines Monats zu einer einzigen Antwortzeile zusammenfalten.
GROUP BY month
-- Die Monate in aufsteigender Reihenfolge ausgeben, damit sich das Wachstum von oben nach unten liest.
ORDER BY month
