-- Lab 9 · data generator: a million turnstile entries, invented by ClickHouse itself.
--
-- Where it runs: on the laptop, in the lab cluster, with the short command `ch`
-- from the README:
--     cd labs/09-clickhouse && ch < 02-generate.sql
-- Before this, the table must already be created — 01-schema.sql.
--
-- How long to wait: a million rows are computed and written in a few seconds,
-- entirely inside the server. The data does not travel over the network and does not pass through your laptop.
-- The INSERT reply is empty — that means success. To check: echo 'SELECT count() FROM passes' | ch
--
-- Run the file twice and there will be two million rows: INSERT only appends and
-- replaces nothing. To start over: TRUNCATE TABLE passes, then run this file again.
--
-- Below is a single INSERT ... SELECT command: the rows do not come from outside, they are computed
-- by the query that follows.
INSERT INTO passes
SELECT
    -- Pass number. number is unique within the generator — so pass_id
    -- is unique too.
    number AS pass_id,
    -- The entry time is assembled from three parts: day, hour, and minute. Each part is
    -- its own pseudo-random number, obtained as cityHash64(number, 'salt').
    -- cityHash64 is a fast hash function: for the same input it always gives
    -- the same result, so the data is reproducible, while a different 'salt'
    -- ('day', 'hour', 'minute', ...) turns a single number into as many
    -- mutually independent random values as you like.
    addMinutes(
        addHours(
            addDays(
                -- The reference point is January 1st. The remainder modulo 57600 gives a number up to 57599,
                -- its square root is a day from 0 to 239, that is, eight months.
                -- The square root here is not for looks: it clusters entries
                -- toward the end of the period. Over time there are more guests — as
                -- in real life, and it is exactly this growth that management wants to see in the report.
                toDateTime('2026-01-01 00:00:00'),
                toUInt16(sqrt(cityHash64(number, 'day') % 57600))
            ),
            -- The arrival hour is taken not uniformly "from 8 to 18", but from an array where
            -- hours repeat with different frequency: 10 appears three times, 15 three times,
            -- 8 once. The result is two pronounced peaks, before lunch and after;
            -- the report should find them. It is good when the test data contains what
            -- we intend to look for in it.
            -- Array indexing in ClickHouse starts at one, hence 1 + …
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
        ),
        -- The minutes within the hour are yet another independent value from the same number.
        cityHash64(number, 'minute') % 60
    ) AS created_at,
    -- The guest name is unique to each row: a million different values in a single column.
    -- A bit further into the lab it will be clear that on disk this is the heaviest column.
    concat('Гость № ', toString(number)) AS guest_name,
    -- The host employee's department: five values, distributed equally.
    ['Продажи', 'Разработка', 'Бухгалтерия',
     'Кадры', 'Логистика'][1 + cityHash64(number, 'dept') % 5] AS host_dept,
    -- The entrance. The same trick, but the distribution is uneven: "Северная" takes
    -- three cells out of six and gets half the flow, "Южная" a third, "Западная"
    -- the rest. Uniform data looks implausible in a report and shows
    -- nothing.
    ['Северная', 'Северная', 'Северная',
     'Южная', 'Южная', 'Западная'][1 + cityHash64(number, 'entrance') % 6] AS entrance,
    -- Pass type: six cells out of ten go to single-use, two each to weekly,
    -- one each to vehicle and group — that is how it looks at the entrance.
    ['разовый', 'разовый', 'разовый', 'разовый', 'разовый', 'разовый',
     'недельный', 'недельный',
     'автомобильный', 'групповой'][1 + cityHash64(number, 'type') % 10] AS pass_type,
    -- Visit duration from 30 to 329 minutes. toUInt16 is needed because the column
    -- is declared as UInt16, while the result of the arithmetic is wider and will not narrow itself.
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
-- numbers(1000000) is a built-in generator table: a million rows with a single
-- column number holding values from 0 to 999999. It is not on disk, it is computed
-- on the fly. If you need more or less data, only this number changes.
FROM numbers(1000000)
