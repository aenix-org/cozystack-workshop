## 27. ステップ7: アプリケーションをマネージドサービスへ切り替える

**ハードコードされたアドレスを名前に置き換える**

📍 **場所:** マシン（app-VM）の内部、再起動後です。bastion 上ではありません。

📄 これは `scripts/connect-managed.sh` の内容です。これも手で入力してください。同じ理由からと、コマンドがたった3つだからです。

マシンの内部で、アプリケーションの設定を開きます:
```bash
cat /etc/orders/application.properties
```
例の `192.168.10.30` と `192.168.10.40` が見えるはずです。これはあらゆるレガシーシステムの悩みです。なぜこのアドレスなのか、もう誰も覚えていません。

これらをサービス名に置き換えます（`XX` は自分の番号に置き換えてください）:
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
（改行を挟んだ1つのコマンドではなく2つのコマンドにしています。チャットからコピーすると改行はしばしば失われ、コマンドが途中までしか実行されないことがあるためです）

確認します:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200` なら、アプリケーションはデータベースもキューも見えています。`503` が返ってきたら、ネットワークのステップに戻ってください。おそらくアドレスが変わっていません。
