-- Lab 9 · die Durchgangsprotokoll-Tabelle: eine Zeile pro Drehkreuz-Durchgang.
--
-- Wo es läuft: auf dem Laptop, im Lab-Cluster, über den kurzen Befehl `ch`
-- aus der README — er sendet das SQL im Body einer gewöhnlichen POST-Anfrage an ClickHouse:
--     cd labs/09-clickhouse && ch < 01-schema.sql
-- CREATE TABLE liefert eine leere Antwort — genau so sieht Erfolg aus.
--
-- Es gibt hier weder CREATE DATABASE noch CREATE USER: Datenbank und Benutzer wurden vom
-- Service selbst bei der Bestellung angelegt (das Dashboard oder die Datei clickhouse.yaml in diesem Ordner).

-- IF NOT EXISTS — nicht meckern, wenn die Tabelle schon existiert. Die Datei kann zweimal angewandt werden.
CREATE TABLE IF NOT EXISTS passes
(
    -- Ausweisnummer. UInt64 und UInt16 — vorzeichenlose Ganzzahlen mit 8 und 2 Byte.
    -- Die Typgröße wird in ClickHouse bewusst gewählt: bei einer Milliarde Zeilen wird jedes zusätzliche
    -- Byte in einer Spalte zu einem zusätzlichen Gigabyte auf der Platte.
    pass_id      UInt64,
    -- Wann die Person das Drehkreuz passiert hat. Der gesamte Bericht ist um diese Spalte herum aufgebaut.
    created_at   DateTime,
    -- Gastname. Fast jede Zeile hat ihren eigenen, daher ein einfacher String.
    guest_name   String,
    -- Die drei Spalten unten sind LowCardinality(String): eine Zeichenkette mit wenigen verschiedenen
    -- Werten (es gibt fünf Abteilungen, drei Eingänge, vier Ausweistypen). ClickHouse
    -- hält für eine solche Spalte ein Wörterbuch und schreibt Nummern auf die Platte, nicht die
    -- millionenfach wiederholten Wörter.
    -- Regel: bis zu einigen tausend verschiedenen Werten — LowCardinality, mehr —
    -- ein einfacher String. guest_name so zu umhüllen wäre schlechter als es nicht zu tun:
    -- ein Wörterbuch aus einer Million eindeutiger Namen wäre größer als die Daten selbst.
    host_dept    LowCardinality(String),
    entrance     LowCardinality(String),
    pass_type    LowCardinality(String),
    -- Wie viele Minuten der Gast drinnen war. Zwei Byte reichen mit großem Puffer.
    duration_min UInt16
)
-- Die Tabellen-Engine — wie ClickHouse Daten auf der Platte speichert. Gewohnte Datenbanken haben keine
-- solche Wahl; hier gibt es sie und sie wird beim Erstellen der Tabelle getroffen.
-- MergeTree: jedes Insert legt einen neuen Part auf die Platte, und Parts werden im Hintergrund
-- zu größeren zusammengeführt. Daher die praktische Regel — in Stapeln von vielen Zeilen einfügen.
-- Eine Million Einzelzeilen-Inserts würden eine Million Parts erzeugen und den Server lahmlegen.
ENGINE = MergeTree
-- Die wichtigste Zeile der Datei, und sie wird gewählt, bevor irgendwelche Daten in die Tabelle gelangen.
-- ORDER BY legt die Reihenfolge fest, in der die Zeilen physisch auf der Platte liegen, und dient zugleich
-- als der einzige echte Index: ClickHouse speichert Marken alle paar tausend Zeilen und nutzt sie, um
-- herauszufinden, welche Teile der Datei ganz übersprungen werden können.
--
-- Folge: „wie viele Durchgänge gab es im März“ wird zum Lesen eines einzigen Abschnitts
-- der Datei, während „den Ausweis mit der Nummer 424242 finden“ zum Lesen der ganzen
-- pass_id-Spalte wird, weil pass_id nicht im Sortierschlüssel steht. Das ist kein Mangel, sondern Absicht.
--
-- Aus der vertrauten Welt: dieselbe Entscheidung wie in einem Papierarchiv — die Ausweise
-- nach Datum oder nach Nachnamen sortieren. Nach Datum sortiert, ist die März-Mappe
-- sofort zur Hand, während ein bestimmter Müller durch Durchsuchen gefunden wird. Und eine
-- Million Blatt Papier wird niemand nachträglich umsortieren.
--
-- Ein PARTITION BY gibt es in der Datei absichtlich nicht. Eine Partition ist ein separater Satz von Parts
-- (üblicherweise pro Monat), der mit einem einzigen Befehl verworfen werden kann; das ist praktisch für die Regel
-- „zwei Jahre aufbewahren und nicht mehr“. Bei acht Monaten Trainingsdaten würden Partitionen
-- zusätzliche Parts ohne Nutzen hinzufügen, und unnötiges Lesen abzuschneiden erledigt hier der Sortierschlüssel.
ORDER BY (created_at, entrance)
