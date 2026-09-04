#!/bin/bash
# 将已迁移的应用从旧的硬编码 IP 切换到托管 DNS 端点。
# 在 app-VM 中以 root 身份运行，需在 netfix-dhcp.sh + 重启之后（否则 DNS 无法解析）。
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# 粘贴你的 managed 服务的名称。
#   你的租户中的 Service DNS 格式（namespace = tenant-<你的登录名>）：
#     Postgres: postgres-<postgres-name>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<kafka-name>-kafka-bootstrap.<namespace>.svc.cozy.local
#   服务名称可在仪表板中查看：Postgres/Kafka -> 你的实例 -> Services。
# =========================================================================
# 默认值与 manifests/04-managed.yaml 一致（Postgres=db, Kafka=kafka）。
# 只需将 tenant-workshopXX 替换为你的 namespace。如果你给 Postgres/Kafka 起了不同的名字 —
# 请把 db/kafka 改成你的名称。
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== 之前（旧的硬编码 IP）=="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== 之后（managed DNS）=="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== 正在重启应用 =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
