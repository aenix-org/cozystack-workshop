#!/bin/bash
# माइग्रेट किए गए एप्लिकेशन को legacy hardcoded IP से managed DNS-endpoints पर स्विच करें।
# app-VM में root के रूप में netfix-dhcp.sh + रीबूट के बाद ही चलाएँ (वरना DNS रिज़ॉल्व नहीं होगा)।
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# अपने managed-सर्विसेज़ के नाम यहाँ डालें।
#   आपके टेनंट में Service DNS का फ़ॉर्मैट (namespace = tenant-<आपका-लॉगिन>):
#     Postgres: postgres-<postgres-नाम>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<kafka-नाम>-kafka-bootstrap.<namespace>.svc.cozy.local
#   सर्विस के नाम डैशबोर्ड में दिखते हैं: Postgres/Kafka -> आपका इंस्टेंस -> Services।
# =========================================================================
# डिफ़ॉल्ट वैल्यूज़ manifests/04-managed.yaml से मेल खाती हैं (Postgres=db, Kafka=kafka)।
# केवल tenant-workshopXX को अपने namespace से बदलें। अगर आपने Postgres/Kafka को अलग नाम दिया है —
# तो db/kafka को अपने नामों से बदलें।
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== पहले (legacy hardcoded IP) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== अब (managed DNS) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== एप्लिकेशन को रीस्टार्ट कर रहे हैं =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
