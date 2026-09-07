-- Схема orders для managed Postgres (таблиця + сід історії).
--
-- Роль `orders` та БД `orders` створює Postgres-chart (Postgres CR), тому тут
-- НЕМАЄ CREATE USER / CREATE DATABASE — лише таблиця та трохи історії.
--
-- ВАЖЛИВО (PG 15+): роль orders не може створювати таблиці у схемі public без
-- гранту. Спершу один раз під superuser (secret postgres-db-superuser):
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- і тільки потім накочувати цей файл від ролі orders. Без таблиці застосунок
-- відповідає 500 на POST /api/orders (health при цьому 200 — він перевіряє лише
-- конект до PG, а не наявність таблиці).
--
-- Запуск (з app-VM або будь-якої машини з доступом до managed PG):
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

-- трохи історії, щоб список не виглядав порожнім на проекторі
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
