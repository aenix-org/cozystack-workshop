-- Lab 9 · pass log table: one row per turnstile tap.
--
-- Where it runs: on the VM, in the lab cluster, via the short `ch` command
-- from the README — it sends SQL to ClickHouse as the body of a plain POST request:
--     cd labs/09-clickhouse && ch < 01-schema.sql
-- The response for CREATE TABLE is empty — that is what success looks like.
--
-- There is no CREATE DATABASE or CREATE USER here: the database and user were set up
-- by the service itself when it was ordered (the dashboard or the clickhouse.yaml file in this same folder).

-- IF NOT EXISTS — don't complain if the table already exists. The file can be applied twice.
CREATE TABLE IF NOT EXISTS passes
(
    -- Pass number. UInt64 and UInt16 — unsigned integers of 8 and 2 bytes.
    -- In ClickHouse the size of a type is chosen deliberately: over a billion rows every extra
    -- byte in a column turns into an extra gigabyte on disk.
    pass_id      UInt64,
    -- When the person passed through the turnstile. The whole report is built around this column.
    created_at   DateTime,
    -- Guest name. Almost every row has its own, so a plain String.
    guest_name   String,
    -- The three columns below are LowCardinality(String): a string that has few distinct
    -- values (five departments, three entrances, four pass types). ClickHouse
    -- keeps a dictionary for such a column and writes numbers to disk instead of the same
    -- words repeated a million times.
    -- Rule: up to a few thousand distinct values — LowCardinality, more than that —
    -- a plain String. Wrapping guest_name this way would be worse than not wrapping it:
    -- a dictionary of a million unique names would end up larger than the data itself.
    host_dept    LowCardinality(String),
    entrance     LowCardinality(String),
    pass_type    LowCardinality(String),
    -- How many minutes the guest stayed inside. Two bytes are more than enough.
    duration_min UInt16
)
-- The table engine — how ClickHouse stores the data on disk. In familiar databases
-- there is no such choice; here there is, and it is made when the table is created.
-- MergeTree: each insert lays a new part on disk, and parts merge in the background
-- into larger ones. Hence the practical rule — insert in batches of many rows.
-- A million single-row inserts would create a million parts and bring the server down.
ENGINE = MergeTree
-- The most important line of the file, and it is chosen before any data enters the table.
-- ORDER BY sets the order in which rows physically lie on disk, and it also
-- serves as the only real index: ClickHouse stores marks every
-- few thousand rows and from them figures out which parts of the file can be skipped entirely.
--
-- Consequence: "how many passes were there in March" turns into reading one stretch of
-- the file, while "find the pass with number 424242" turns into reading the whole pass_id column,
-- because pass_id is not in the sort key. This is not a shortcoming, it is by design.
--
-- From the familiar world: the same decision as in a paper archive — filing
-- passes by date or by surname. File them by date and the March folder is
-- retrieved instantly, while one particular Ivanov is found by scanning through. And nobody
-- is going to re-file a million sheets of paper after the fact.
--
-- There is deliberately no PARTITION BY in the file. A partition is a separate set of parts (usually
-- one month) that can be dropped with a single command; this is handy for the rule
-- "keep two years and no more". Over eight months of training data partitions would give
-- extra parts with no benefit, and cutting out unnecessary reads is something the sort key handles here.
ORDER BY (created_at, entrance)
