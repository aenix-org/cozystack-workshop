## 30. ステップ9: チェーン全体を検証する

**真実の瞬間**

⚠️ **まず — 仮想マシンの中で — firewalld を停止してください。** 移行してきた CentOS は
過去の人生からルールを引き継いでおり、外部には SSH しか公開していません。アプリケーションの
ポートは閉じたままで、外から見ると「アプリケーションが動いていない」ように見えます。

```bash
systemctl stop firewalld
systemctl disable firewalld
```

その場で、マシンの内側から、アプリケーションが生きていることを確認します。

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — アプリケーションは応答しています。`503` — ネットワークのステップに戻ってください。ここでの
`localhost` は、あなたが今いるそのマシン自身です。アプリケーションが自分自身を確認しているのです。

📍 **次は — ドメイン名を使った外部からの確認です。** この経路ではポートフォワーディングは不要です。
講師があらかじめあなたのテナントに `Ingress` を作成してあり、マシン内部のアプリケーションが
`8080` でリッスンし始めた途端に、ショップは `https://app.workshopXX.workshop.aenix.io`
（`XX` はあなたの番号）で公開されます。ノートPCのブラウザで開いてください — あるいは bastion 上で
そのまま `curl` で確認しても構いません。

```bash
# ヘルスチェック
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

# 注文を作成する
curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# 記録されたことを確認する
curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

⚠️ app-VM がまだ起動していない、あるいは起動中の間は、ドメインは `503` を返します — これは
正常です。`Ingress` はバックエンドを待っています。`200` が見えたら、内部のマシンが `8080` で
リッスンしているということです。

注文が作成されたなら — あなたは道のり全体を歩き切りました。アプリケーションは VMware から
やってきて、クラスターの中で動き、マネージドなデータベースに書き込み、マネージドなキューに
イベントを送っています。

30分前、このシステムは ESXi の上で生きていました。
