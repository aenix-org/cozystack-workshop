-- 面向托管 Postgres 的 orders 架构（表 + 历史种子数据）。
--
-- `orders` 角色和 `orders` 数据库由 Postgres chart（Postgres CR）创建，
-- 因此这里没有 CREATE USER / CREATE DATABASE —— 只有表和少量历史数据。
--
-- 重要（PG 15+）：orders 角色在没有授权的情况下无法在 public 架构中创建表。
-- 首先，以 superuser 身份执行一次（secret postgres-db-superuser）：
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- 然后才能以 orders 角色应用此文件。没有该表时，应用会对
-- POST /api/orders 返回 500（此时 health 仍为 200 —— 它只检查
-- 到 PG 的连接，而不检查表是否存在）。
--
-- 运行方式（在 app-VM 或任何可访问托管 PG 的机器上）：
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

-- 少量历史数据，使列表在投影仪上不显得空白
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
