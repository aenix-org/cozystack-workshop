#!/bin/bash
# Переключити мігрований застосунок з legacy hardcoded IP на managed DNS-endpoints.
# Запускати в app-VM під root ПІСЛЯ netfix-dhcp.sh + ребута (інакше DNS не резолвить).
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# ВСТАВТЕ ІМЕНА ВАШИХ керованих сервісів.
#   Формат Service DNS у вашому тенанті (namespace = tenant-<ваш-логін>):
#     Postgres: postgres-<ім'я-postgres>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<ім'я-kafka>-kafka-bootstrap.<namespace>.svc.cozy.local
#   Імена сервісів видно в дашборді: Postgres/Kafka -> ваш інстанс -> Services.
# =========================================================================
# значення за замовчуванням збігаються з manifests/04-managed.yaml (Postgres=db, Kafka=kafka).
# Заміни лише tenant-workshopXX на свій namespace. Якщо називав Postgres/Kafka інакше —
# зміни db/kafka на свої імена.
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== було (legacy hardcoded IP) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== стало (managed DNS) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== перезапускаю застосунок =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
