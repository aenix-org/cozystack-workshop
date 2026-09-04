-- managed Postgres के लिए orders स्कीमा (टेबल + इतिहास-सीड)।
--
-- `orders` रोल और `orders` DB को Postgres-chart (Postgres CR) बनाता है, इसलिए यहाँ
-- कोई CREATE USER / CREATE DATABASE नहीं है — केवल टेबल और थोड़ा इतिहास।
--
-- महत्वपूर्ण (PG 15+): orders रोल grant के बिना public स्कीमा में टेबल नहीं बना
-- सकता। पहले एक बार superuser के रूप में (secret postgres-db-superuser):
--     GRANT CREATE,USAGE ON SCHEMA public TO orders;
-- और उसके बाद ही इस फ़ाइल को orders रोल से लगाएँ। टेबल के बिना एप्लिकेशन
-- POST /api/orders पर 500 देता है (health तब भी 200 रहता है — यह केवल PG से
-- कनेक्शन जाँचता है, टेबल की मौजूदगी नहीं)।
--
-- चलाएँ (app-VM से या managed PG तक पहुँच वाली किसी भी मशीन से):
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

-- थोड़ा इतिहास, ताकि प्रोजेक्टर पर सूची खाली न दिखे
INSERT INTO orders (item, status, created_by, processed_by, created_at, processed_at)
SELECT '12x rack rails', 'PROCESSED', 'app-1', 'kafka',
       now() - interval '3 days', now() - interval '3 days' + interval '2 seconds'
WHERE NOT EXISTS (SELECT 1 FROM orders);
