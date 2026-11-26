-- Lab 9 · the report management came asking for: how many guests each month,
-- how long a visit lasts on average, at which hour they arrive most often, and which
-- entrance is busier.
--
-- Where it runs: on the VM, in the lab cluster, with the short command `ch`
-- from the README:
--     cd labs/09-clickhouse && ch < 03-report.sql
-- Before this, 01-schema.sql and 02-generate.sql must have been run.
--
-- How to read the result: one row per month present in the data (there are
-- eight of them), months in ascending order, the guest count growing month over month.
--
-- Why a million rows are counted in milliseconds. ClickHouse stores each column
-- as a separate file. This query touches three columns out of seven — the other four,
-- including the heaviest guest_name, are not read from disk at all. In a database where a row
-- sits on disk in one piece, you would have to lift all million rows with all their fields
-- just to count over three of them. Hence the difference in time.
-- To see it in numbers: append the line FORMAT JSON to the end of the query — the response
-- will include a statistics block with the elapsed time and the volume read.
--
-- One report row per month that appeared in the data.
SELECT
    -- Which month to attribute the pass to. toStartOfMonth turns the exact time
    -- into the first day of the month: a single value to both group and sort by,
    -- instead of a "year plus month" pair.
    toStartOfMonth(created_at)          AS month,
    -- How many rows fell into the group — that is "how many guests per month".
    count()                             AS guests,
    -- Average visit duration, rounded to whole minutes.
    round(avg(duration_min))            AS avg_minutes,
    -- The most frequent arrival hour — the very rush hour. topK(1)(x) returns an array
    -- of the single most frequent value, [1] pulls it out of there (counting from one).
    topK(1)(toHour(created_at))[1]      AS peak_hour,
    -- The busiest entrance of this month, by the same technique.
    topK(1)(entrance)[1]                AS busiest_entrance
-- Note what the query does not have: subqueries, temporary tables, or joins.
-- Everything is computed in a single pass over the data.
FROM passes
-- Collapse all rows of one month into a single response row.
GROUP BY month
-- Output months in ascending order so the growth reads top to bottom.
ORDER BY month
