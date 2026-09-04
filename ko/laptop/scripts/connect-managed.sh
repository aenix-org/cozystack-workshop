#!/bin/bash
# 마이그레이션된 애플리케이션을 legacy 하드코딩 IP에서 managed DNS 엔드포인트로 전환합니다.
# app-VM에서 root 권한으로 netfix-dhcp.sh + 재부팅 이후에 실행하세요(그렇지 않으면 DNS가 확인되지 않습니다).
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# 당신의 managed 서비스 이름을 붙여넣으세요.
#   당신 테넌트에서의 Service DNS 형식(namespace = tenant-<당신의-로그인>):
#     Postgres: postgres-<postgres-이름>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<kafka-이름>-kafka-bootstrap.<namespace>.svc.cozy.local
#   서비스 이름은 대시보드에서 확인할 수 있습니다: Postgres/Kafka -> 당신의 인스턴스 -> Services.
# =========================================================================
# 기본값은 manifests/04-managed.yaml과 일치합니다(Postgres=db, Kafka=kafka).
# tenant-workshopXX만 당신의 namespace로 교체하세요. Postgres/Kafka를 다르게 이름 지었다면 —
# db/kafka를 당신의 이름으로 바꾸세요.
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== 이전 (legacy 하드코딩 IP) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== 이후 (managed DNS) =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== 애플리케이션을 재시작합니다 =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
