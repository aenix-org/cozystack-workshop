-- Lab 9 · Tabelle des Durchgangsprotokolls: eine Zeile pro Drehkreuz-Erfassung.
--
-- Wo es läuft: auf der VM, im Lab-Cluster, über den kurzen Befehl `ch`
-- aus der README — er sendet SQL an ClickHouse als Body einer gewöhnlichen POST-Anfrage:
--     cd labs/09-clickhouse && ch < 01-schema.sql
-- Die Antwort bei CREATE TABLE ist leer — genau das bedeutet Erfolg.
--
-- Weder CREATE DATABASE noch CREATE USER stehen hier: Datenbank und Benutzer hat der
-- Dienst selbst bei der Bestellung angelegt (das Dashboard oder die Datei clickhouse.yaml im selben Ordner).

-- IF NOT EXISTS — nicht meckern, wenn die Tabelle bereits erstellt ist. Die Datei kann zweimal angewendet werden.
CREATE TABLE IF NOT EXISTS passes
(
    -- Ausweisnummer. UInt64 und UInt16 — vorzeichenlose Ganzzahlen mit 8 und 2 Byte.
    -- Die Größe eines Typs wählt man in ClickHouse bewusst: bei einer Milliarde Zeilen wird jedes zusätzliche
    -- Byte in einer Spalte zu einem zusätzlichen Gigabyte auf der Festplatte.
    pass_id      UInt64,
    -- Wann die Person durch das Drehkreuz gegangen ist. Um diese Spalte herum ist der gesamte Bericht aufgebaut.
    created_at   DateTime,
    -- Name des Gastes. Fast jede Zeile hat einen eigenen, daher ein gewöhnlicher String.
    guest_name   String,
    -- Die drei Spalten unten sind LowCardinality(String): eine Zeichenkette mit wenigen verschiedenen
    -- Werten (fünf Abteilungen, drei Eingänge, vier Ausweistypen). ClickHouse
    -- hält für eine solche Spalte ein Wörterbuch und schreibt Nummern auf die Festplatte statt der eine
    -- Million Mal wiederholten Wörter.
    -- Regel: bis zu einigen Tausend verschiedenen Werten — LowCardinality, mehr —
    -- ein gewöhnlicher String. guest_name so zu umhüllen wäre schlechter, als es nicht zu tun:
    -- ein Wörterbuch aus einer Million einzigartiger Namen würde größer als die Daten selbst.
    host_dept    LowCardinality(String),
    entrance     LowCardinality(String),
    pass_type    LowCardinality(String),
    -- Wie viele Minuten der Gast drinnen war. Zwei Byte reichen mit großem Spielraum.
    duration_min UInt16
)
-- Die Tabellen-Engine — die Art, wie ClickHouse die Daten auf der Festplatte speichert. In gewohnten Datenbanken
-- gibt es diese Wahl nicht, hier gibt es sie und sie wird beim Erstellen der Tabelle getroffen.
-- MergeTree: jede Einfügung legt ein neues Stück auf die Festplatte, die Stücke verschmelzen im Hintergrund
-- zu größeren. Daher die praktische Regel — in Stapeln mit vielen Zeilen einfügen.
-- Eine Million Einfügungen zu je einer Zeile würden eine Million Stücke erzeugen und den Server lahmlegen.
ENGINE = MergeTree
-- Die wichtigste Zeile der Datei, und sie wird ausgewählt, bevor Daten in die Tabelle gelangen.
-- ORDER BY legt die Reihenfolge fest, in der die Zeilen physisch auf der Festplatte liegen, und dient zugleich
-- als einziger echter Index: ClickHouse speichert Markierungen alle
-- paar Tausend Zeilen und erkennt daran, welche Stücke der Datei gar nicht gelesen werden müssen.
--
-- Folge: „wie viele Durchgänge es im März gab“ wird zum Lesen eines einzigen Abschnitts
-- der Datei, während „den Ausweis mit der Nummer 424242 finden“ zum Lesen der gesamten Spalte pass_id wird,
-- weil pass_id nicht im Sortierschlüssel steht. Das ist kein Mangel, sondern die Bauart.
--
-- Aus der vertrauten Welt: dieselbe Entscheidung wie in einem Papierarchiv — die
-- Ausweise nach Datum oder nach Nachnamen abzulegen. Nach Datum abgelegt — die März-Mappe
-- ist sofort zur Hand, während ein bestimmter Ivanov durch Durchsuchen gefunden wird. Und eine
-- Million Blätter nachträglich umzusortieren wird niemand.
--
-- PARTITION BY steht absichtlich nicht in der Datei. Eine Partition ist ein separater Satz von Stücken (meist
-- für einen Monat), den man mit einem einzigen Befehl verwerfen kann; das ist praktisch für die Regel
-- „wir bewahren zwei Jahre auf und nicht mehr“. Bei acht Monaten Lerndaten würden Partitionen
-- überflüssige Stücke ohne Nutzen bringen, und überflüssiges Lesen abzuschneiden kann hier der Sortierschlüssel.
ORDER BY (created_at, entrance)
