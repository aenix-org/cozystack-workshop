-- managed Postgres 用の orders スキーマ（テーブル + 履歴シード）。
--
-- `orders` ロールと `orders` DB は Postgres チャート（Postgres CR）が作成するため、
-- ここには CREATE USER / CREATE DATABASE は無く、テーブルと少しの履歴だけです。
--
-- 重要（PG 15+）: orders ロールは grant 無しでは public スキーマにテーブルを作成できません。
-- まず一度だけ superuser（secret postgres-db-superuser）として実行します:
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- その後にのみ、このファイルを orders ロールで適用してください。テーブルが無いと
-- アプリケーションは POST /api/orders に 500 を返します（health はその場合でも 200 のまま
-- ── PG への接続だけを確認し、テーブルの有無は確認しないため）。
--
-- 実行（app-VM または managed PG にアクセスできる任意のマシンから）:
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

-- プロジェクターで一覧が空に見えないよう、少しだけ履歴を入れます
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
