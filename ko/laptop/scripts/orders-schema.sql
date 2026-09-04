-- managed Postgres용 orders 스키마 (테이블 + 히스토리 시드).
--
-- `orders` 역할과 `orders` DB는 Postgres 차트(Postgres CR)가 생성하므로, 여기에는
-- CREATE USER / CREATE DATABASE가 없습니다 — 테이블과 약간의 히스토리만 있습니다.
--
-- 중요 (PG 15+): orders 역할은 grant 없이는 public 스키마에 테이블을 생성할 수
-- 없습니다. 먼저 한 번 superuser로 (secret postgres-db-superuser):
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- 그런 다음에만 이 파일을 orders 역할로 적용하세요. 테이블이 없으면 애플리케이션은
-- POST /api/orders에 500을 반환합니다 (이때 health는 200 — PG 연결만 확인하고
-- 테이블의 존재 여부는 확인하지 않습니다).
--
-- 실행 (app-VM 또는 managed PG에 접근 가능한 임의의 머신에서):
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

-- 프로젝터에서 목록이 비어 보이지 않도록 약간의 히스토리
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
