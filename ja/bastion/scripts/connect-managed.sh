#!/bin/bash
# 移行済みアプリケーションを、レガシーなハードコードIPからマネージドDNSエンドポイントへ切り替える。
# app-VM 上で root として、netfix-dhcp.sh + 再起動の後に実行すること（さもないとDNSが解決しない）。
set -e
CONF=/etc/orders/application.properties

# =========================================================================
# あなたのマネージドサービスの名前を貼り付けてください。
#   テナント内の Service DNS 形式（namespace = tenant-<あなたのログイン>）:
#     Postgres: postgres-<postgres名>-rw.<namespace>.svc.cozy.local
#     Kafka:    kafka-<kafka名>-kafka-bootstrap.<namespace>.svc.cozy.local
#   サービス名はダッシュボードで確認できます: Postgres/Kafka -> あなたのインスタンス -> Services。
# =========================================================================
# デフォルト値は manifests/04-managed.yaml と一致します（Postgres=db, Kafka=kafka）。
# tenant-workshopXX だけを自分の namespace に置き換えてください。Postgres/Kafka を別名で作成した場合は —
# db/kafka を自分の名前に変更してください。
PG_HOST="postgres-db-rw.tenant-workshopXX.svc.cozy.local"
KAFKA_HOST="kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local"
# =========================================================================

echo "== 変更前（レガシーなハードコードIP） =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

sed -i "s#192.168.10.30:5432#${PG_HOST}:5432#; s#192.168.10.40:9092#${KAFKA_HOST}:9092#" "$CONF"

echo "== 変更後（マネージドDNS） =="
grep -E 'datasource.url|bootstrap-servers' "$CONF"

echo "== アプリケーションを再起動しています =="
systemctl restart orders-api
sleep 8
systemctl is-active orders-api
curl -s -o /dev/null -w 'app-health HTTP %{http_code}\n' localhost:8080/actuator/health
