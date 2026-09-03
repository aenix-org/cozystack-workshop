# ワークショップ: VMware の VM を Cozystack へ移行する（bastion 経由）

VMware の仮想マシン上で何年も動いてきたアプリケーションを、Cozystack へ移します。すべてをあなた
自身の手で行います。

**これは共有 VM（bastion）を経由する道です。** 自分のノートPCには何もインストールする必要は
ありません。`kubectl`、`virtctl`、`git` はすでに bastion に入っており、そこからのクラスターへの
アクセスもすでに設定済みです。SSH で bastion に入り、そのまま作業し、完成したアプリケーションは
ドメイン名でブラウザから開きます。

> 自分のノートPCから作業する場合（ツールを自分でインストールし、`port-forward` 経由でアプリケーション
> に到達する場合）は、もう一方のセット [`../laptop/`](../laptop/) が必要です。

このファイルは道順です。何の次に何が来るか、どのコマンドを打つか、そして最終的に何が得られるべきかを
示します。なぜこういう作りになっているのかの説明と、マニフェストやスクリプトを一行ずつたどる解説は、
[`chat/`](chat/) フォルダにあります — メッセージ1件につき1ファイルです。リンクは各ステップの末尾に
あります。

## 道順

アプリケーションは3台のマシンで動いています。アプリケーション本体、データベース、そしてメッセージ
キューです。移すのは最初の1台だけです — データベースとキューは残していき、その代わりに Cozystack の
カタログから出来合いのものを取ってきます。

| フェーズ | 何をするか | どこで |
|---|---|---|
| 1 | イメージ用のストレージを用意する | bastion 上で |
| 2 | ディスクを VMware 形式から KVM 形式へ再パッケージする | 一時的なマシンの中で |
| 3 | マシンを新しい場所で起動する | bastion 上で |
| 4 | データベースとキューをカタログから注文する | bastion 上で |
| 5 | ネットワークを直し、アプリケーションを新しいアドレスに切り替える | あなたのマシンの中で |

その後に最終チェックが続きます。アプリケーションで作成した注文が、データベースとキューまで最後まで
届くことを確認します。

## 講師から渡されたもの

ユーザー名1つとパスワード1つ — 3か所すべてで同じです。

* **dashboard** https://dashboard.workshop.aenix.io — ブラウザからログイン、namespace は `tenant-workshopXX`
* **bastion** — SSH でログイン: `ssh workshopXX@<bastion-address>`
* bastion の中では、クラスターへのアクセスはすでに設定済みで、kubeconfig は `~/.kube/config` にあります

以下ではどこでも、`workshopXX` をあなた自身の番号（講師から渡されたもの）に置き換えてください。

## bastion へのログイン

```bash
ssh workshopXX@<bastion-address>
```

パスワードは dashboard と同じです。SSH 鍵は不要で、ログインはパスワードで行います。クラスターへの
アクセスができていることを確認しましょう（ここではブラウザは開きません — bastion は Keycloak を
介さず、トークンによる直接アクセス用に設定されています）:

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**表示されるはず:** コンテキスト名 `tenant-workshopXX` と、（まだ空の）マシンの一覧。

## 教材はすでに bastion にあります

クローンするものは何もありません — 教材フォルダはあなたのホームディレクトリにあり、マニフェストや
スクリプト内のあなたのテナント番号は**すでに埋め込まれています**。bastion を準備した際に、
`tenant-workshopXX` というプレースホルダーがあなたの `tenant-workshopNN` に置き換えられています。
検索して置換するものは何もありません — ファイルをそのまま適用するだけです。

```bash
cd ~/workshop
ls manifests scripts
grep -rl tenant-workshop manifests | head -1 | xargs grep -m1 namespace   # あなたの番号が表示されます
```

1か所だけ、意図的にプレースホルダーのまま残してあります。`manifests/03-app-vm.yaml` の
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` という行です — このリンクは第2フェーズの後に得られるので、自分で
書き込みます。

詳しくは: [chat/10](chat/10-clone-and-set-number.md) ·
ファイルマップ [chat/11](chat/11-file-map.md)

---

## フェーズ1. イメージ用のストレージ

📍 bastion 上で。

再パッケージしたディスクは、プラットフォームがネットワーク越しに取ってこられる場所に置く必要が
あります。バケットを用意します — S3 インターフェイスを持つオブジェクトストレージです。

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**表示されるはず:** `bucket.apps.cozystack.io/my-images created`、続いて `READY: True`。

⚠️ **型名は `bucket` と略さず、完全に書いてください。** この単語はクラスター内で3回使われています。
カタログにある私たちの型、Flux の型、そしてオブジェクトストレージ標準の型です。短い名前に対して
`kubectl` が3つのうちどれを当てはめるかは事前には分からず、もし別のものだった場合、頼んでもいない
リソースに対して権限拒否を受けます: `buckets.source.toolkit.fluxcd.io is forbidden`。これはアクセスの
問題ではなく、直すべきものは何もありません。

⚠️ **`apply` が `SchemaError … unknown model in reference` で失敗する場合** — つまずいているのは
あなたの側のクライアント検証であって、クラスターではありません。マニフェストは正しいです。回避するには:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`。このフラグはローカルのチェックだけを
無効にし、サーバー側ではオブジェクトを引き続き検証します。

**次に鍵が必要になります:** dashboard → `Bucket` → `my-images` → `Secrets` タブ →
`bucket-my-images-app-credentials` という secret。そこから `bucketName`、`accessKey`、`secretKey` を
取ってきます — 次のフェーズでスクリプトに書き込みます。

マニフェストの解説: [chat/13](chat/13-bucket-manifest.md) ·
ステップ全体: [chat/14](chat/14-step-1-bucket.md)

---

## フェーズ2. ディスクの再パッケージ

📍 まず bastion 上で、その後は一時的なマシンの中で。

VMware のディスクは VMDK 形式で書かれていますが、KVM が読むのは QCOW2 です。再パッケージは
`virt-v2v` が担当します。一度きりのためにこれを bastion にインストールする意味はないので、ツールが
すでに揃った一時的なマシンを立ち上げます。

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**表示されるはず:** `created` の行が2つ、続いて `Running`。

⚠️ `Running` は「電源が入った」という意味であって、「準備ができた」ではありません。内部ではあと数分間
`cloudInit` が動き続けています — パッケージをインストールし、`mc` をダウンロードしています。早く
ログインすると `virt-v2v` が見つかりません。

ログインします（ユーザー名 `ubuntu`、パスワード `ubuntu`）:

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

中で: `nano convert.sh` を実行し、`scripts/convert.sh` の内容を貼り付け、`ВСТАВЬТЕ_...` の代わりに
自分の `bucketName`、`accessKey`、`secretKey` を書き込みます。

⚠️ **変換は `screen` の中で実行してください** — 5分ほどかかり、bastion への SSH セッションが切れると、
普通の実行は途中で打ち切られます。`screen` は接続がなくなってもプロセスを保ち続けます:

```bash
screen -S convert          # 別のセッションに入る
sudo bash convert.sh       # そのセッションの中で実行する
#  接続が切れた? もう一度 bastion に ssh して、次を実行:  screen -r convert
```

**表示されるはず:** 出力の最後、`Share:` という単語の後に、イメージへの署名付きリンク。次のフェーズで
必要になります。

マニフェストの解説: [chat/15](chat/15-conversion-vm-manifest.md) ·
スクリプトの解説: [chat/17](chat/17-convert-script.md) ·
両ステップ全体: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## フェーズ3. 新しい場所のマシン

📍 bastion 上で。

⚠️ まず変換用マシンを停止してください — 役目を終え、あなたのクォータを 8Gi 占有しています。取り除か
ないと、新しいマシンは `Pending` のまま止まってしまいます:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

得られたリンクを `manifests/03-app-vm.yaml` の `url: "ВСТАВЬТЕ_PRESIGNED_URL"` の代わりに書き込み、
それから:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**表示されるはず:** `created` の行が2つ、続いて `Running`。ここでは待ち時間が長めです — プラット
フォームがあなたのリンクからイメージをダウンロードしています。

ログインします（ユーザー名 `root`、パスワード `cozydemo`）:

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **中にはネットワークがありません。** これはテスト環境の故障ではなく、そうあるべき状態です。第5
フェーズで直します。

マニフェストの解説: [chat/20](chat/20-app-vm-manifest.md) ·
ステップ全体: [chat/21](chat/21-step-4-your-vm.md)

---

## フェーズ4. カタログからのデータベースとキュー

📍 bastion 上で。

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**表示されるはず:** `postgres.apps.cozystack.io/db created` と
`kafka.apps.cozystack.io/kafka created`。Kafka は Postgres よりも起動に目に見えて時間がかかります。

マニフェストの解説: [chat/23](chat/23-managed-manifest.md) ·
ステップ全体: [chat/24](chat/24-step-5-database-and-queue.md)

---

## フェーズ5. アプリケーションの接続

📍 あなたの仮想マシンの中で。

厳密な順番で3つの作業を行います。ネットワークがなければスクリプトはデータベースに到達できず、
データベースがなければスキーマを受け付けません。

| ステップ | 何を直すか | 何で |
|---|---|---|
| 5.1 | マシンがネットワークにいない | `scripts/netfix-dhcp.sh` |
| 5.2 | アプリケーションが古いアドレスを探している | `scripts/connect-managed.sh` |
| 5.3 | 新しいデータベースにテーブルがない | `scripts/orders-schema.sql` |

**5.1.** スクリプトは `BOOTPROTO=static` を `dhcp` に変え、VMware ネットワークのアドレスを取り除き
ます。手で打ち込みます — マシンにはまだネットワークがなく、ファイルをダウンロードできないからです。
その後、マシンは**再起動**が必要です。CentOS 7 はネットワーク設定を起動時に適用します。

**5.2.** スクリプトは `/etc/orders/application.properties` に直書きされたアドレス `192.168.10.30` と
`192.168.10.40` をサービス名に置き換え、アプリケーションを再起動します。

**5.3.** `psql` クライアントをインストールしてスキーマを適用します — コマンドは以下、最終チェックの
中にあります。

詳しくは: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## 最終チェック: 順番に3ステップ

### ステップ1. firewalld を止める

📍 あなたのマシンの中で。ルールは古いネットワークから残っており、アプリケーションへのリクエストを
遮断しています。

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**表示されるはず:** `200`。`503` の場合 — データベースかキューの何かが接続できていません。ここでの
`localhost` はあなたが今いるマシンそのものです。アプリケーションを内側からチェックしています。

### ステップ2. データベースのスキーマ

📍 あなたのマシンの中で。CentOS 7 標準の psql はバージョン 9.2 で、SCRAM ができず、
`SCRAM authentication requires libpq version 10 or above` と答えます。新しいものをインストールします:

```bash
# 1. PGDG リポジトリ — PostgreSQL パッケージの供給元
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: CentOS 7 のリポジトリにはないので、EPEL のアーカイブから取ってくる
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. クライアント本体 — 生きている pgdg15 リポジトリのみから
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ 2番目と3番目のコマンドは無駄ではありません。`libzstd` がないとインストールは
`Requires: libzstd >= 1.4.0` で失敗します。`--disablerepo`/`--enablerepo` がないと —
`HTTPS Error 410 - Gone` で失敗します。リポジトリパッケージは、サポートが終了した12番と13番を含む
すべての PostgreSQL バージョンを一度に有効にしてしまい、`yum` はインストール前に有効なリポジトリを
すべて巡回し、最初の死んだものでつまずくからです。

```bash
psql --version
```

`command not found` の場合 — クライアントが `PATH` の外に落ちています。`ls /usr/pgsql-*/bin/psql` を
見て、それから `export PATH="$PATH:/usr/pgsql-15/bin"` を実行してください。

スキーマを取ってきて適用します（この app-VM はインターネットに出られるので、ファイルはダウンロード
されます）:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**表示されるはず:** 最後のコマンドで — `orders` テーブル。

データベースのアドレスは IP ではなく名前です: `postgres-db-rw`（`db` サービス、読み書き用）、
`tenant-workshopXX`（あなたの namespace）、`svc.cozy.local`（クラスター内部の名前の接尾辞）。
パスワードは `manifests/04-managed.yaml` に設定されているので、どこかで探し回る必要はありません。

詳しくは: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### ステップ3. 外側からのチェック — ドメイン名で

📍 自分のノートPCのブラウザで、または bastion 上の `curl` で。

ここでこの道の最大の違いが表れます: **ポートフォワーディングは不要です。** 講師はあなたのテナントに
`Ingress` をすでに作成しており、マシンの中のアプリケーションが `8080` をリッスンし始めた瞬間に、
ショップは `https://app.workshopXX.workshop.aenix.io` で公開されます（`XX` はあなたの番号）。そのまま
そこからチェックします:

```bash
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

**表示されるはず:** 一覧の中に注文。これで道のりはすべて完了です。

⚠️ app-VM がまだ起動していない、または起動中の間は、ドメインは `503` を返します — これは正常です。
`Ingress` はバックエンドを待っています。マシンが起動すると（内部で `8080` がリッスンされる）、`200` に
なります。

詳しくは: [chat/30](chat/30-step-9-verify-chain.md)

---

## チートシート

> **`vmi/` という接頭辞はすべてのコマンドに必要なわけではなく、これは打ち間違いではありません。**
> テナント権限のもとでは、`virtctl console` は**素の**名前（`vm-instance-app-1`）だけを受け付けます。
> `vmi/` を付けると、`vmi` という単語をマシンの名前だと解釈して `forbidden` と答えます。一方
> `virtctl ssh` と `virtctl port-forward` は逆に、`vmi/<name>` という形を要求します。

```bash
# app-VM にログイン (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# conversion-VM にログイン (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# SSH 経由で app-VM の中のシェル（マシンのネットワークが上がったら）
virtctl ssh ubuntu@vmi/vm-instance-app-1 --namespace=tenant-workshopXX
```

アプリケーションのチェックはドメイン `https://app.workshopXX.workshop.aenix.io` で行い、この道では
`port-forward` は不要です。コンソールから抜けるには `Ctrl+]`。接続後に画面が空白なら、Enter を押して
ください。同じことはマウスでもできます: dashboard のマシンのページにある **VNC** ボタンです。

## つまずきやすいところ

* conversion-VM には `ubuntu-20.04` だけを使ってください。24.04 ではカーネルがパニックし、22.04 では
  `virt-v2v` が古い CentOS 7 の RPM データベースを解析できません。
* カタログイメージ用の VMDisk は、イメージ自体より大きくなければなりません。さもないとクローンが
  通らず、ディスクは `Terminating` のまま止まります。`ubuntu-20.04` なら 25Gi で足ります。
* 新しい app-VM では、まず `netfix`、次に `connect` の順で — さもないとアプリケーションはマネージド
  サービスを認識しません。
* 長い変換は `screen` の中で実行してください — さもないと SSH の切断が途中で打ち切ります。

残りの落とし穴は — [chat/31](chat/31-troubleshooting.md)。

## テスト環境を構築する人へ

クォータ、テナントを作成する順番、プラットフォームのバージョンは [REQUIREMENTS.md](../REQUIREMENTS.md) に
あります。

## すべてのメッセージを順番に

27件のメッセージの一覧は — [chat/README.md](chat/README.md)。
