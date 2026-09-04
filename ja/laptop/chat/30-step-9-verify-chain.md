## 30. ステップ9: チェーン全体を検証する

**真実の瞬間**

⚠️ **まず — 仮想マシンの中で — firewalld を停止してください。** 移行してきた CentOS は
過去の人生からルールを引き継いでおり、外部には SSH しか公開していません。アプリケーションの
ポートは閉じたままで、ノートPCからのポートフォワーディングは `no route to host` に突き当たります
— そして外から見ると「アプリケーションが動いていない」ように見えます。

```bash
systemctl stop firewalld
systemctl disable firewalld
```

その場で、マシンの内側から、アプリケーションが生きていることを確認します。

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — ポートフォワーディングできます。`503` — ネットワークのステップに戻ってください。

📍 **次は — ノートPCで。** アプリケーションのポートを自分の手元にフォワードします。
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
このコマンドのウィンドウは閉じないでください。トンネルはコマンドが動いている間だけ生きています。

⚠️ **ここでは `vmi/` が必須ですが、`virtctl console` では逆に — 邪魔になります。** これは
打ち間違いでも私たちの気まぐれでもありません。2つのコマンドはターゲットの構文が異なるのです。
`port-forward` は `type/name` を要求し、プレフィックスがないと `target must contain type
and name separated by '/'` と答えます。`console` は名前だけを期待し、プレフィックスを付けると
`forbidden` と答えます。`vmi` という語をマシンの名前だと受け取ってしまうからです。

virtctl がクライアントとクラスターのバージョンの違いについて文句を言う場合 — それは警告であって
エラーではなく、動作の妨げにはなりません。

それでもポートフォワーディングが立ち上がらない場合は、同じトンネルをマシンの Pod 経由でも作れます。
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <出力に表示されたPod名> 8080:8080
```

別のターミナルウィンドウで:
```bash
# ヘルスチェック
curl -s http://localhost:8080/actuator/health

# 注文を作成する
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# 記録されたことを確認する
curl -s http://localhost:8080/api/orders
```

注文が作成されたなら — あなたは道のり全体を歩き切りました。アプリケーションは VMware から
やってきて、クラスターの中で動き、マネージドなデータベースに書き込み、マネージドなキューに
イベントを送っています。

30分前、このシステムは ESXi の上で生きていました。
