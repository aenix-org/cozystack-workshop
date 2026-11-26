#!/bin/bash
# Switch the migrated application from legacy hardcoded IPs to managed DNS endpoints.
# Run in the app-VM as root AFTER netfix-dhcp.sh + reboot (otherwise DNS won't resolve).
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# PASTE THE NAMES OF YOUR managed services.
#   Service DNS format in your tenant (namespace = tenant-<your-login>):
#     Postgres: postgres-<postgres-name>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<kafka-name>-kafka-bootstrap.<namespace>.svc.cozy.local
#   Service names are visible in the dashboard: Postgres/Kafka -> your instance -> Services.
# =========================================================================
# default values match manifests/04-managed.yaml (Postgres=db, Kafka=kafka).
# Replace only tenant-workshopXX with your namespace. If you named Postgres/Kafka differently —
# change db/kafka to your names.
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== before (legacy hardcoded IP) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== after (managed DNS) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== restarting the application =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
