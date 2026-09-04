-- Esquema orders para Postgres gestionado (tabla + semilla de historial).
--
-- El rol `orders` y la BD `orders` los crea el chart de Postgres (Postgres CR), por eso
-- aquí NO HAY CREATE USER / CREATE DATABASE — solo la tabla y un poco de historial.
--
-- IMPORTANTE (PG 15+): el rol orders no puede crear tablas en el esquema public sin
-- un grant. Primero, una vez, como superuser (secret postgres-db-superuser):
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- y solo después aplicar este archivo con el rol orders. Sin la tabla, la aplicación
-- responde 500 a POST /api/orders (health sigue en 200 — solo comprueba la
-- conexión con PG, no la existencia de la tabla).
--
-- Ejecución (desde la app-VM o cualquier máquina con acceso al PG gestionado):
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

-- un poco de historial para que la lista no se vea vacía en el proyector
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
