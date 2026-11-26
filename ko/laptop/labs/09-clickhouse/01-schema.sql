-- Lab 9 · the pass log table: one row per turnstile swipe.
--
-- Where it runs: on the laptop, in the lab cluster, via the short `ch` command
-- from the README — it sends the SQL to ClickHouse in the body of an ordinary POST request:
--     cd labs/09-clickhouse && ch < 01-schema.sql
-- CREATE TABLE returns an empty response — that is what success looks like.
--
-- There is no CREATE DATABASE or CREATE USER here: the database and user were set up by the
-- service itself at order time (the dashboard or the clickhouse.yaml file in this same folder).

-- IF NOT EXISTS — do not complain if the table already exists. The file can be applied twice.
CREATE TABLE IF NOT EXISTS passes
(
    -- Pass number. UInt64 and UInt16 — unsigned integers of 8 and 2 bytes.
    -- Type size in ClickHouse is chosen deliberately: on a billion rows every extra
    -- byte in a column turns into an extra gigabyte on disk.
    pass_id      UInt64,
    -- When the person passed the turnstile. The entire report is built around this column.
    created_at   DateTime,
    -- Guest name. Almost every row has its own, so a plain String.
    guest_name   String,
    -- The three columns below are LowCardinality(String): a string that has few distinct
    -- values (there are five departments, three entrances, four pass types). ClickHouse
    -- keeps a dictionary for such a column and writes numbers to disk, not the words
    -- repeated a million times.
    -- Rule: up to a few thousand distinct values — LowCardinality, more than that —
    -- a plain String. Wrapping guest_name this way would be worse than not wrapping it:
    -- a dictionary of a million unique names would be larger than the data itself.
    host_dept    LowCardinality(String),
    entrance     LowCardinality(String),
    pass_type    LowCardinality(String),
    -- How many minutes the guest spent inside. Two bytes are more than enough.
    duration_min UInt16
)
-- The table engine — how ClickHouse stores data on disk. Familiar databases have no
-- such choice; here it exists and is made when the table is created.
-- MergeTree: each insert puts a new part on disk, and parts are merged in the background
-- into bigger ones. Hence the practical rule — insert in batches of many rows.
-- A million single-row inserts would create a million parts and bring the server down.
ENGINE = MergeTree
-- The most important line in the file, and it is chosen before any data reaches the table.
-- ORDER BY sets the order in which rows physically lie on disk, and it also serves as
-- the only real index: ClickHouse stores marks every few thousand rows and uses them to
-- figure out which parts of the file can be skipped entirely.
--
-- Consequence: "how many passes were there in March" turns into reading a single stretch
-- of the file, while "find the pass with number 424242" turns into reading the whole
-- pass_id column, because pass_id is not in the sort key. This is not a shortcoming but by design.
--
-- From the familiar world: the same decision as in a paper archive — sort the passes
-- by date or by surname. Sorted by date, the March folder is pulled instantly, while a
-- particular Smith is found by scanning. And nobody is going to re-sort a million
-- sheets of paper after the fact.
--
-- There is no PARTITION BY in the file, deliberately. A partition is a separate set of parts
-- (usually per month) that can be dropped with a single command; this is handy for the rule
-- "keep two years and no more". On eight months of training data partitions would add
-- extra parts for no benefit, and cutting out unnecessary reads is what the sort key does here.
ORDER BY (created_at, entrance)
