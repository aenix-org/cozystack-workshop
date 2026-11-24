CREATE TABLE IF NOT EXISTS journal_stream (raw String)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'kafka-kafka-kafka-bootstrap:9092',
         kafka_topic_list = 'auth.journal',
         kafka_group_name = 'clickhouse-analytics',
         kafka_format = 'JSONAsString',
         kafka_num_consumers = 1, kafka_max_block_size = 1000, kafka_poll_max_batch_size = 1000;

CREATE TABLE IF NOT EXISTS payments (
  ts DateTime64(3),
  card_id String, bin String, amount_usd Float64,
  merchant String, city String, country String,
  decision LowCardinality(String), source LowCardinality(String),
  score Float64, latency_ms Float64,
  reasons Array(String)
) ENGINE = MergeTree ORDER BY ts;

CREATE MATERIALIZED VIEW IF NOT EXISTS payments_stream_mv TO payments AS
SELECT
  parseDateTime64BestEffortOrZero(JSONExtractString(raw, 'ts'), 3) AS ts,
  JSONExtractString(raw, 'request', 'card_id') AS card_id,
  JSONExtractString(raw, 'request', 'bin') AS bin,
  JSONExtractInt(raw, 'request', 'amount_cents') / 100 AS amount_usd,
  JSONExtractString(raw, 'request', 'merchant_name') AS merchant,
  JSONExtractString(raw, 'request', 'city') AS city,
  JSONExtractString(raw, 'request', 'country') AS country,
  JSONExtractString(raw, 'decision') AS decision,
  JSONExtractString(raw, 'source') AS source,
  JSONExtractFloat(raw, 'score') AS score,
  JSONExtractFloat(raw, 'latency_ms') AS latency_ms,
  arrayMap(x -> JSONExtractString(x, 'code'), JSONExtractArrayRaw(raw, 'reasons')) AS reasons
FROM journal_stream;

-- Declines by reason per minute.
SELECT toStartOfMinute(ts), arrayJoin(reasons), count(*)
FROM payments
WHERE decision = 'DECLINE'
GROUP BY toStartOfMinute(ts), arrayJoin(reasons)
ORDER BY toStartOfMinute(ts), arrayJoin(reasons);

-- Top 10 merchants by declines.
SELECT merchant, count(*)
FROM payments
WHERE decision = 'DECLINE'
GROUP BY merchant
ORDER BY count(*) DESC
LIMIT 10;

-- Stand-in count and share per minute.
SELECT toStartOfMinute(ts), countIf(source = 'STAND_IN'),
       count(*), countIf(source = 'STAND_IN') / count(*)
FROM payments
GROUP BY toStartOfMinute(ts)
ORDER BY toStartOfMinute(ts);
