-- orders-Schema für managed Postgres (Tabelle + History-Seed).
--
-- Die Rolle `orders` und die DB `orders` werden vom Postgres-Chart (Postgres CR) erstellt,
-- daher gibt es hier KEIN CREATE USER / CREATE DATABASE — nur die Tabelle und etwas History.
--
-- WICHTIG (PG 15+): Die Rolle orders kann ohne Grant keine Tabellen im Schema public
-- erstellen. Zuerst einmalig als Superuser (Secret postgres-db-superuser):
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- und erst danach diese Datei als Rolle orders anwenden. Ohne die Tabelle antwortet die
-- Anwendung mit 500 auf POST /api/orders (health bleibt dabei 200 — es prüft nur die
-- Verbindung zu PG, nicht das Vorhandensein der Tabelle).
--
-- Ausführung (vom app-VM oder einer beliebigen Maschine mit Zugriff auf managed PG):
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

-- etwas History, damit die Liste auf dem Projektor nicht leer aussieht
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
