-- Lab 9 · data generator: a million turnstile records, invented by ClickHouse itself.
--
-- Where it runs: on the VM, in the lab cluster, with the short command `ch`
-- from the README:
--     cd labs/09-clickhouse && ch < 02-generate.sql
-- Before this, the table must be created — 01-schema.sql.
--
-- How long to wait: a million rows are computed and written in a few seconds,
-- entirely inside the server. The data does not travel over the network or pass through your VM.
-- The INSERT reply is empty — that means success. To check: echo 'SELECT count() FROM passes' | ch
--
-- Run the file twice and you get two million rows: INSERT only appends and
-- replaces nothing. To start over: TRUNCATE TABLE passes, then this file again.
--
-- Below is a single INSERT ... SELECT command: the rows don't come from outside, they are
-- computed by the query that follows.
INSERT INTO passes
SELECT
    -- Pass number. number is unique within the generator — so pass_id
    -- is unique too.
    number AS pass_id,
    -- The entry time is assembled from three parts: day, hour, and minute. Each part
    -- is its own pseudo-random number, obtained as cityHash64(number, 'salt').
    -- cityHash64 is a fast hash function: for the same input it always gives
    -- the same result, so the data is reproducible, while a different salt
    -- ('day', 'hour', 'minute', ...) turns a single number into as many
    -- mutually independent random values as you like.
    addMinutes(
        addHours(
            addDays(
                -- The starting point is January 1. The remainder modulo 57600 gives a number up to 57599,
                -- and its square root is a day from 0 to 239, that is, eight months.
                -- The square root here is not for looks: it concentrates the passes
                -- toward the end of the period. Guests grow more numerous over time — as
                -- in real life, and that growth is exactly what management wants to see in the report.
                toDateTime('2026-01-01 00:00:00'),
                toUInt16(sqrt(cityHash64(number, 'day') % 57600))
            ),
            -- The arrival hour is taken not uniformly "from 8 to 18", but from an array where
            -- hours repeat with different frequency: 10 occurs three times, 15 three times,
            -- 8 once. This produces two pronounced peaks, before lunch and after;
            -- the report is meant to find them. It's good when the test data contains
            -- what we intend to look for in it.
            -- Array numbering in ClickHouse starts at one, hence 1 + …
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
        ),
        -- The minutes within the hour are yet another independent value from the same number.
        cityHash64(number, 'minute') % 60
    ) AS created_at,
    -- Each row has its own guest name: a million different values in one column.
    -- A bit later in the lab you'll see that on disk this is the heaviest column.
    concat('Гость № ', toString(number)) AS guest_name,
    -- The host employee's department: five values, distributed evenly.
    ['Продажи', 'Разработка', 'Бухгалтерия',
     'Кадры', 'Логистика'][1 + cityHash64(number, 'dept') % 5] AS host_dept,
    -- Entry gate. The same trick, but the distribution is uneven: «Северная» takes
    -- three cells out of six and gets half the flow, «Южная» a third, «Западная» the
    -- remainder. Evenly distributed data looks implausible in a report and shows
    -- nothing.
    ['Северная', 'Северная', 'Северная',
     'Южная', 'Южная', 'Западная'][1 + cityHash64(number, 'entrance') % 6] AS entrance,
    -- Pass type: six cells out of ten go to «разовый», two to «недельный»,
    -- one each to «автомобильный» and «групповой» — that's how it looks at the gate.
    ['разовый', 'разовый', 'разовый', 'разовый', 'разовый', 'разовый',
     'недельный', 'недельный',
     'автомобильный', 'групповой'][1 + cityHash64(number, 'type') % 10] AS pass_type,
    -- Visit duration from 30 to 329 minutes. toUInt16 is needed because the column
    -- is declared as UInt16, while the arithmetic result is wider and won't narrow itself.
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
-- numbers(1000000) is a built-in generator table: a million rows with a single
-- column number holding values from 0 to 999999. It doesn't exist on disk, it's computed
-- on the fly. Need more or less data — only this number changes.
FROM numbers(1000000)
