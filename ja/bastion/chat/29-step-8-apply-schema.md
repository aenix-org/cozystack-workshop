## 29. ステップ8: クライアントを入れてスキーマを適用する

**データベースへのアクセス情報:**
```
host:     postgres-db-rw.tenant-workshopXX.svc.cozy.local
database: orders
login:    orders
password: Orders2019!
```
パスワードは `manifests/04-managed.yaml` で設定されているので、他を探す必要はありません。

⚠️ **CentOS 7 に標準で入っている psql は使えません。** バージョンが 9.2 と古く、私たちのデータベースは
SCRAM 認証を要求しますが、この psql はそれを扱えず、次のように返してきます:
`psql: SCRAM authentication requires libpq version 10 or above`。バージョン 10 以降のクライアントが必要です。
PGDG リポジトリから取得しますが、CentOS 7 向けにそこで入手できるのは最大でも 15 系です。

3つのコマンドを続けて実行します。それぞれに理由が1つずつあります:

```bash
# 1. PostgreSQL パッケージの提供元である PGDG リポジトリを追加する。
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd ライブラリ。これがないとクライアントはインストールできない。CentOS 7 の
#    リポジトリには存在しないので、EPEL のアーカイブから取得する。
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. クライアント本体 — 生きている pgdg15 リポジトリからのみ取得する。
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

2番目と3番目のコマンドは余計に見えますが、これらがないとインストールは失敗します。そうでなければ、
2つのエラーをあなた自身の目で見ることになったはずです:

- `libzstd` がない場合 — `Requires: libzstd >= 1.4.0`;
- `--disablerepo`/`--enablerepo` がない場合 — `HTTPS Error 410 - Gone`。リポジトリパッケージは
  サポートの切れた 12 系や 13 系も含め、あらゆる PostgreSQL のバージョンを一度に引き込みます。そして
  インストール前に `yum` は有効なリポジトリを**すべて**巡回し、最初に見つけた死んだリポジトリで失敗します。
  そこで、必要なものだけを明示的に残しています。

クライアントが入ったか確認します:

```bash
psql --version
```

もし `command not found` と返ってきたら、クライアントは `PATH` の外に置かれています。それを見つけて、
現在のセッションにそのディレクトリを追加します:

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**スキーマファイルを取得します** — マシンには既にネットワークがあります:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql
```

**適用します。** 手探りで入力しなくて済むよう、コマンドを部分ごとに分解して見ていきましょう:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'` — パスワードを環境変数で渡すことで、`psql` が対話的に入力を求めてこないようにします。
  スクリプトではこうします。
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local` — データベースのアドレスです。これは **IP ではなく**、
  クラスター内部の名前です。`-rw` というサフィックスが重要です。managed Postgres には複数のコピーがあり、
  この名前は常に**書き込める**方を指します。対になる `-ro` 付きの名前もあります — 読み取り専用です。
  コピー間でロールが切り替わっても名前は変わらないので、アプリケーションの設定には特定のサーバーのアドレスではなく、
  この名前を書いておきます。
- `-U orders` — どのユーザーで接続するか、`-d orders` — どのデータベースに接続するか。
- `-f orders-schema.sql` — ファイル内のコマンドを実行する。

まさに IP ではなく安定した名前でデータベースにアクセスできることが、コピーの切り替えをアプリケーションから
見えなくしているのです。古いマシンでは設定に `localhost` と書いてあり、そもそも切り替え自体がありませんでした。

テーブルが所定の場所にあるか確認します:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

現れたなら、これで注文が作成されるようになります。それは次のステップで、一連の流れ全体と合わせて確認します。
