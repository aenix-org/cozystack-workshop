#!/bin/bash
# Cambiar la aplicacion migrada de las IP legacy hardcodeadas a los endpoints DNS gestionados.
# Ejecutar en la app-VM como root DESPUES de netfix-dhcp.sh + reboot (de lo contrario el DNS no resuelve).
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# PEGUE LOS NOMBRES DE SUS servicios gestionados.
#   Formato del Service DNS en su tenant (namespace = tenant-<su-login>):
#     Postgres: postgres-<nombre-postgres>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<nombre-kafka>-kafka-bootstrap.<namespace>.svc.cozy.local
#   Los nombres de los servicios se ven en el dashboard: Postgres/Kafka -> su instancia -> Services.
# =========================================================================
# los valores por defecto coinciden con manifests/04-managed.yaml (Postgres=db, Kafka=kafka).
# Reemplace solo tenant-workshopXX con su namespace. Si nombro Postgres/Kafka de otra forma —
# cambie db/kafka por sus propios nombres.
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== antes (legacy hardcoded IP) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== despues (managed DNS) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== reiniciando la aplicacion =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
