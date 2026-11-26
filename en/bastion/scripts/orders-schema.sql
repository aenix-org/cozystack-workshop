-- Orders schema for the managed PostgreSQL from the catalog: one table and one row of history.
--
-- The `orders` user and the `orders` database come from the Postgres declaration, so there is
-- no CREATE USER or CREATE DATABASE here. Without the table the application answers 500 on
-- POST /api/orders while its health check stays 200: the check only opens a connection.
--
-- Apply it from the platform side, in the primary database pod, as the `orders` role:
--     ( echo 'SET ROLE orders;'; cat orders-schema.sql ) | \
--       kubectl exec -i postgres-orders-1 -c postgres -- psql -d orders -v ON_ERROR_STOP=1

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
