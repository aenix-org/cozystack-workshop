#!/bin/bash
# 移行したアプリケーションを、レガシーなハードコードIPからmanaged DNSエンドポイントへ切り替える。
# netfix-dhcp.sh + 再起動の後に、app-VM上でrootとして実行すること（そうしないとDNSが解決しない）。
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# あなたのmanagedサービスの名前を貼り付けてください。
#   あなたのテナントでのService DNSの形式（namespace = tenant-<あなたのログイン>）:
#     Postgres: postgres-<postgresの名前>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<kafkaの名前>-kafka-bootstrap.<namespace>.svc.cozy.local
#   サービス名はダッシュボードで確認できます: Postgres/Kafka -> あなたのインスタンス -> Services。
# =========================================================================
# デフォルト値は manifests/04-managed.yaml と一致します（Postgres=db, Kafka=kafka）。
# tenant-workshopXX だけを自分のnamespaceに置き換えてください。Postgres/Kafka を別の名前にした場合は —
# db/kafka を自分の名前に変更してください。
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== 変更前（レガシーなハードコードIP） =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== 変更後（managed DNS） =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== アプリケーションを再起動します =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
