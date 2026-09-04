-- managed Postgres 用の orders スキーマ（テーブル + 履歴シード）。
--
-- `orders` ロールと `orders` DB は Postgres chart（Postgres CR）が作成するため、ここには
-- CREATE USER / CREATE DATABASE はなく、テーブルと少量の履歴だけがある。
--
-- 重要（PG 15+）: orders ロールはグラントなしに public スキーマへテーブルを作成できない。
-- まず一度だけ superuser（secret postgres-db-superuser）として:
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- を実行し、その後にこのファイルを orders ロールとして適用する。テーブルがないとアプリケーションは
-- POST /api/orders に対して 500 を返す（health は 200 のまま — PG への接続を確認するだけで、
-- テーブルの有無は確認しない）。
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

-- プロジェクターで一覧が空に見えないよう、少量の履歴を入れる
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
