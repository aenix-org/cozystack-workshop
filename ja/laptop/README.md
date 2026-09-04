# ワークショップ: VMware の VM を Cozystack へ移行する（自分のノートPCから）

VMware の仮想マシン上で何年も動いてきたアプリケーションを、Cozystack へ移します。すべてをあなた
自身の手で行います。

> 講師から、ツールとアクセスがすでに整った共有 VM（bastion）を渡された場合は、もう一方のセット
> [`../bastion/`](../bastion/) が必要です。そちらではすべてが設定済みです。

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
| 1 | イメージ用のストレージを用意する | ノートPC 上で |
| 2 | ディスクを VMware 形式から KVM 形式へ再パッケージする | 一時的なマシンの中で |
| 3 | マシンを新しい場所で起動する | ノートPC 上で |
| 4 | データベースとキューをカタログから注文する | ノートPC 上で |
| 5 | ネットワークを直し、アプリケーションを新しいアドレスに切り替える | あなたのマシンの中で |

その後に最終チェックが続きます。アプリケーションで作成した注文が、データベースとキューまで最後まで
届くことを確認します。

## 講師から渡されたもの

講師から渡されるもの:

* dashboard https://dashboard.workshop.aenix.io
* ユーザー名 `workshopXX`、パスワードは当日その場で渡されます
* kubeconfig — dashboard の中で: `Info` → `Secrets` タブ → `kubeconfig-tenant-workshopXX` という secret

以下ではどこでも、`workshopXX` をあなた自身の番号に置き換えてください。

## 始める前に: 4つのユーティリティ

ワークショップの前に、ノートPC へ一度だけインストールしておきます。

| ユーティリティ | 何のため | インストール |
|---|---|---|
| `kubectl` | ファイルを適用し、クラスターの中身を表示する | [chat/04](chat/04-install-kubectl.md) |
| `virtctl` | 仮想マシンのコンソールとポートフォワーディング | [chat/05](chat/05-install-virtctl.md) |
| `kubelogin` | ブラウザ経由のログイン。これがないとクラスターに入れません | [chat/06](chat/06-install-kubelogin.md) |
| `git` | このリポジトリを取得する | [chat/09](chat/09-install-git.md) |

⚠️ **このワークショップに krew は不要です** — その理由は [chat/07](chat/07-about-krew.md) に。

すべてが揃ったかの確認。各コマンドは「command not found」ではなく、バージョンかヘルプを表示するはず
です:

```bash
kubectl version --client
virtctl version --client
kubectl oidc-login --help
```

## クラスターへの接続

dashboard から kubeconfig をディスクに保存し、`KUBECONFIG` 変数でそれを指し示します。

**macOS と Linux** — secret の内容を `~/.kube/workshop` に置き、それから:

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Windows (PowerShell):**

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # kubeconfig を貼り付ける; ファイルの種類 —「すべてのファイル」
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

最初のリクエストでブラウザが開きます — `workshopXX` としてログインしてください。

⚠️ **Windows: ファイルは UTF-8 でのみ保存してください。** メモ帳と PowerShell の `>` リダイレクトは
UTF-16 で書き込み、`kubectl` はそのようなファイルを読めません — 証明書には何の問題もないのに、
`x509: certificate signed by unknown authority` と答えます。

⚠️ `dial tcp [::1]:8080 ... refused` というエラーは、クラスターに到達できないという意味ではなく、
`kubectl` が kubeconfig を見つけられなかったという意味です。両方の解説は
[chat/08](chat/08-connect-to-cluster.md) に。

## 教材を取得する

```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/laptop
```

⚠️ 末尾の `/laptop` は必須です。このフォルダにはノートPC の道の教材、つまりマニフェストとスクリプトが
入っています。これがないと、コマンドは `manifests` も `scripts` も見つけられません。

すべてのファイルに `tenant-workshopXX` というプレースホルダーが入っています。自分の番号を一括で
置き換えてください（例では `workshop03`）:

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +

# macOS — 同じ sed だが、-i の後に空のクォートが必要
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

```powershell
# Windows
Get-ChildItem -Path manifests,scripts -File -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw) -replace 'tenant-workshopXX','tenant-workshop03' |
    Set-Content $_.FullName -NoNewline
}
```

プレースホルダーが1つも残っていないことを確認します:

```bash
grep -rn tenant-workshopXX manifests scripts || echo "all clean, you can continue"
```

1か所だけ、コマンドは意図的に触れません。`manifests/03-app-vm.yaml` の
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` という行です — このリンクは第2フェーズの後に得られます。

詳しくは: [chat/10](chat/10-clone-and-set-number.md) ·
ファイルマップ [chat/11](chat/11-file-map.md)

---

## フェーズ1. イメージ用のストレージ

📍 ノートPC 上で。

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

📍 まずノートPC 上で、その後は一時的なマシンの中で。

VMware のディスクは VMDK 形式で書かれていますが、KVM が読むのは QCOW2 です。再パッケージは
`virt-v2v` が担当します。一度きりのためにこれをノートPC にインストールする意味はないので、ツールが
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
自分の `bucketName`、`accessKey`、`secretKey` を書き込み、`bash convert.sh` を実行します。

**表示されるはず:** 出力の最後、`Share:` という単語の後に、イメージへの署名付きリンク。次のフェーズで
必要になります。

マニフェストの解説: [chat/15](chat/15-conversion-vm-manifest.md) ·
スクリプトの解説: [chat/17](chat/17-convert-script.md) ·
両ステップ全体: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## フェーズ3. 新しい場所のマシン

📍 ノートPC 上で。

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

📍 ノートPC 上で。

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

**表示されるはず:** `200`。`503` の場合 — データベースかキューの何かが接続できていません。

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

スキーマを取ってきて適用します:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql

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

### ステップ3. ポートフォワーディングと外側からのチェック

📍 ノートPC 上で。

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

ウィンドウは閉じないでください — トンネルはコマンドが動いている間だけ生きています。別のウィンドウで:

```bash
curl -s http://localhost:8080/actuator/health

curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s http://localhost:8080/api/orders
```

**表示されるはず:** 一覧の中に注文。これで道のりはすべて完了です。

詳しくは: [chat/30](chat/30-step-9-verify-chain.md)

---

## チートシート

> **`vmi/` という接頭辞はすべてのコマンドに必要なわけではなく、これは打ち間違いではありません。**
> 2つのコマンドはターゲットの構文が異なります。`virtctl console` は名前だけを期待し、接頭辞を付けると
> `vmi` という単語をマシンの名前だと解釈して `forbidden` と答えます。`virtctl port-forward` は
> `type/name` を要求し、接頭辞がないと `target must contain type and name separated by '/'` と答えます。

```bash
# app-VM にログイン (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# conversion-VM にログイン (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# アプリケーションのポートをノートPC に転送する
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

コンソールから抜けるには `Ctrl+]`。接続後に画面が空白なら、Enter を押してください。同じことはマウス
でもできます: dashboard のマシンのページにある **VNC** ボタンです。

## つまずきやすいところ

* conversion-VM には `ubuntu-20.04` だけを使ってください。24.04 ではカーネルがパニックし、22.04 では
  `virt-v2v` が古い CentOS 7 の RPM データベースを解析できません。
* カタログイメージ用の VMDisk は、イメージ自体より大きくなければなりません。さもないとクローンが
  通らず、ディスクは `Terminating` のまま止まります。`ubuntu-20.04` なら 25Gi で足ります。
* 新しい app-VM では、まず `netfix`、次に `connect` の順で — さもないとアプリケーションはマネージド
  サービスを認識しません。
* `.yaml` ファイルを Word や Google Docs で開かないでください。クォートやダッシュが置き換えられ、
  ファイルは適用されなくなり、エラーは説明のつかないものに見えます。

残りの落とし穴は — [chat/31](chat/31-troubleshooting.md)。

## テスト環境を構築する人へ

クォータ、テナントを作成する順番、プラットフォームのバージョンは [REQUIREMENTS.md](../REQUIREMENTS.md) に
あります。

## すべてのメッセージを順番に

32件のメッセージの一覧は — [chat/README.md](chat/README.md)。
</content>
</invoke>
