-- Lab 9 · der Bericht, für den die Geschäftsführung kam: wie viele Gäste pro Monat,
-- wie lange ein Besuch im Schnitt dauert, zu welcher Stunde sie am häufigsten kommen und welcher
-- Eingang stärker ausgelastet ist.
--
-- Wo es läuft: auf der VM, im Labor-Cluster, mit dem kurzen Befehl `ch`
-- aus der README:
--     cd labs/09-clickhouse && ch < 03-report.sql
-- Davor müssen 01-schema.sql und 02-generate.sql ausgeführt worden sein.
--
-- Wie das Ergebnis zu lesen ist: eine Zeile pro Monat, der in den Daten vorkommt (es sind
-- acht), Monate aufsteigend, die Gästezahl wächst von Monat zu Monat.
--
-- Warum eine Million Zeilen in Millisekunden gezählt werden. ClickHouse speichert jede Spalte
-- als eigene Datei. Diese Abfrage berührt drei von sieben Spalten — die anderen vier,
-- darunter die schwerste guest_name, werden gar nicht von der Platte gelesen. In einer Datenbank, in der eine Zeile
-- als Ganzes auf der Platte liegt, müsste man alle Millionen Zeilen mit allen Feldern heraufholen,
-- nur um über drei davon zu zählen. Daher der Zeitunterschied.
-- Um es in Zahlen zu sehen: hängen Sie die Zeile FORMAT JSON ans Ende der Abfrage — in der Antwort
-- erscheint ein Statistikblock mit der verbrauchten Zeit und dem gelesenen Volumen.
--
-- Eine Berichtszeile pro Monat, der in den Daten vorkam.
SELECT
    -- Welchem Monat der Durchgang zuzuordnen ist. toStartOfMonth verwandelt die exakte Zeit
    -- in den ersten Tag des Monats: ein einziger Wert, nach dem gruppiert und sortiert wird,
    -- statt einem Paar aus «Jahr plus Monat».
    toStartOfMonth(created_at)          AS month,
    -- Wie viele Zeilen in die Gruppe gefallen sind — das ist «wie viele Gäste pro Monat».
    count()                             AS guests,
    -- Durchschnittliche Besuchsdauer, auf ganze Minuten gerundet.
    round(avg(duration_min))            AS avg_minutes,
    -- Die häufigste Ankunftsstunde — die eigentliche Stoßzeit. topK(1)(x) liefert ein Array
    -- aus dem einen häufigsten Wert, [1] holt ihn dort heraus (Zählung ab eins).
    topK(1)(toHour(created_at))[1]      AS peak_hour,
    -- Der am stärksten ausgelastete Eingang dieses Monats, mit demselben Kniff.
    topK(1)(entrance)[1]                AS busiest_entrance
-- Beachten Sie, was die Abfrage nicht hat: Unterabfragen, temporäre Tabellen und Joins.
-- Alles wird in einem einzigen Durchlauf über die Daten berechnet.
FROM passes
-- Alle Zeilen eines Monats zu einer Antwortzeile zusammenfassen.
GROUP BY month
-- Monate aufsteigend ausgeben, damit das Wachstum von oben nach unten lesbar ist.
ORDER BY month
