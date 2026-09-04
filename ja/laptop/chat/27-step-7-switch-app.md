## 27. ステップ7: アプリケーションをマネージドサービスに切り替える

**ハードコードされたアドレスを名前に置き換える**

📍 **場所:** 仮想マシンの中、再起動のあと。

📄 これは `scripts/connect-managed.sh` の内容です。これも手で打ち込んでください。理由は同じで、しかもコマンドは3つだけです。

マシンの中で、アプリケーションの設定を開きます:
```bash
cat /etc/orders/application.properties
```
例の `192.168.10.30` と `192.168.10.40` が見えます。これはあらゆるレガシーシステムの痛みです。なぜこのアドレスなのか、もう誰も覚えていません。

これらをサービス名に置き換えます（`XX` は自分の番号に置き換えてください）:
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
（改行を含む1つのコマンドではなく2つのコマンドにしています。チャットからコピーすると改行が失われがちで、コマンドが途中までしか実行されないことがあるためです）

確認します:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200` なら、アプリケーションはデータベースとキューの両方を見えています。`503` が返ってきた場合は、ネットワークのステップに戻ってください。おそらくアドレスが変わっていません。
