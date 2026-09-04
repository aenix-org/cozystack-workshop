-- Lab 9 · the report management asked for: how many guests each month,
-- how long a visit lasts on average, at what hour they arrive most often, and which entrance
-- is busier.
--
-- Where it runs: on the laptop, in the lab cluster, with the short command `ch`
-- from the README:
--     cd labs/09-clickhouse && ch < 03-report.sql
-- Before this, 01-schema.sql and 02-generate.sql must have been run.
--
-- How to read the result: one row per month present in the data (there are
-- eight), months in ascending order, the guest count growing from month to month.
--
-- Why a million rows are counted in milliseconds. ClickHouse stores each column
-- as a separate file. This query touches three columns out of seven — the other four,
-- including the heaviest one, guest_name, are not read from disk at all. In a database where a row
-- is stored on disk in full, you would have to pull all million rows with all their fields
-- just to compute over three of them. Hence the difference in time.
-- To see it in numbers: append the line FORMAT JSON to the end of the query — the response
-- will include a statistics block with the time spent and the volume read.
--
-- One report row per month that appeared in the data.
SELECT
    -- Which month to attribute the pass to. toStartOfMonth turns the exact time
    -- into the first day of the month: a single value to both group and sort by,
    -- instead of a "year plus month" pair.
    toStartOfMonth(created_at)          AS month,
    -- How many rows fell into the group — this is "how many guests per month".
    count()                             AS guests,
    -- Average visit duration, rounded to whole minutes.
    round(avg(duration_min))            AS avg_minutes,
    -- The most frequent arrival hour — the rush hour itself. topK(1)(x) returns an array
    -- of the single most frequent value, and [1] pulls it out of there (counting from one).
    topK(1)(toHour(created_at))[1]      AS peak_hour,
    -- The busiest entrance of this month, by the same trick.
    topK(1)(entrance)[1]                AS busiest_entrance
-- Note what the query does not have: subqueries, temporary tables, and joins.
-- Everything is computed in a single pass over the data.
FROM passes
-- Collapse all rows of one month into a single response row.
GROUP BY month
-- Output the months in ascending order, so the growth reads top to bottom.
ORDER BY month
