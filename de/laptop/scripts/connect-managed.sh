#!/bin/bash
# Die migrierte Anwendung von legacy hardcoded IPs auf managed DNS-Endpunkte umstellen.
# In der app-VM als root NACH netfix-dhcp.sh + Reboot ausführen (sonst löst DNS nicht auf).
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# FÜGEN SIE DIE NAMEN IHRER managed-Services EIN.
#   Service-DNS-Format in Ihrem Tenant (namespace = tenant-<Ihr-Login>):
#     Postgres: postgres-<postgres-name>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<kafka-name>-kafka-bootstrap.<namespace>.svc.cozy.local
#   Die Service-Namen sind im Dashboard sichtbar: Postgres/Kafka -> Ihre Instanz -> Services.
# =========================================================================
# Standardwerte entsprechen manifests/04-managed.yaml (Postgres=db, Kafka=kafka).
# Ersetzen Sie nur tenant-workshopXX durch Ihren namespace. Wenn Sie Postgres/Kafka anders benannt haben —
# ändern Sie db/kafka in Ihre eigenen Namen.
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== vorher (legacy hardcoded IP) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== nachher (managed DNS) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== starte die Anwendung neu =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
