-- orders schema for managed Postgres (table + history seed).
--
-- The `orders` role and `orders` DB are created by the Postgres chart (Postgres CR),
-- so there is NO CREATE USER / CREATE DATABASE here — only the table and a bit of history.
--
-- IMPORTANT (PG 15+): the orders role cannot create tables in the public schema without
-- a grant. First, once, as superuser (secret postgres-db-superuser):
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- and only then apply this file as the orders role. Without the table the application
-- returns 500 on POST /api/orders (health stays 200 — it only checks the
-- connection to PG, not the presence of the table).
--
-- Run (from the app-VM or any machine with access to managed PG):
--     PGPASSWORD='<orders-pw>' psql -h postgres-db-rw -U orders -d orders -f orders-schema.sql

CREATE TABLE IF NOT EXISTS orders (
    id           BIGSERIAL PRIMARY KEY,
    item         TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'NEW',
    created_by   TEXT,
    processed_by TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);

-- a bit of history so the list does not look empty on the projector
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
