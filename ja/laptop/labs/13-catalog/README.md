# Lab 13 · Cozystack カタログにあなた自身のアプリケーションを載せる

| | |
|---|---|
| **所要時間** | 40分 |
| **何が証明できるか** | プラットフォームのカタログは開かれている。あなた自身のアプリケーションが、Redis や VM のすぐ隣に、その中に居場所を得る |
| **必要なもの** | ノートPC上の `helm`、`kubectl`、テナントアクセス。ここでは `lab` クラスターは不要 |

## なぜこれが重要か

「ゲストパス」は立ち上がって動いています。1週間後、子会社がそれを聞きつけます。彼らも
同じ受付を持ち、同じ問題を抱えているのです。そのまた1週間後、2つ目の子会社がやって
きます。

最初の2社には口頭で説明しました。どのイメージを使い、どの設定にし、どのパラメーターを
渡し、何を最初に立ち上げるか。3社目になる頃には、これは続けられないと明らかでした。
説明はある1人の頭の中にしかなく、そういう頭は1つしかないのに、会社は5つになるのです。

必要なのは、Redis がそうであったのと同じかたちで「ゲストパス」が彼らの前に現れること
です。カタログのエントリ、パラメーター入力フォーム、ボタン。あなたの手を煩わせずに。

これはワークショップの締めくくりです。私たちは「Pod を1つデプロイして」から「これが、
自分たちのサービスを内側に抱えたプラットフォームです」までの道のりを歩んできました。

## まず最初に: あなたの権限がどこで終わるか

この lab はアプリケーションをカタログに**デプロイしません**。そしてそれは、その部分を
書く時間が足りなかったからではありません。

アプリケーションをカタログに登録するオブジェクトである `ApplicationDefinition` は
**クラスタースコープ**です。クラスターに1つだけ存在し、namespace を持たず、すべての
テナントのカタログを一度に変えてしまいます。テナントはこのようなオブジェクトを作成
できません。今すぐ自分で確かめてみましょう。何も作成せずに、自分の権限についてクラスター
に尋ねることができます。

```bash
# KUBECONFIG — kubectl がクラスターのアドレスとあなたの認証情報を見つけるために読む変数。
# ここではテナントアクセス、他のすべての lab と同じファイルです。
export KUBECONFIG=~/.kube/workshop
# auth can-i = 「私は許可されている?」。クラスターは yes か no を答え、何も変えません:
#   create                   どのアクションを確認するか
#   applicationdefinitions   どの種類のオブジェクトに対して
kubectl auth can-i create applicationdefinitions
```

**表示されるもの:**

```
no
```

ここに回避策はなく、用意されてもいません。ですから lab は正直に組まれています。
**あなたはチャートとアプリケーション定義を書き、ローカルで検証し、それをプラットフォーム
管理者に渡します。** 現実でもまさにこう動いています。カタログを構築することと、それを
運用することは別の役割なのです。

おなじみの世界からの類推: あなたは OVF テンプレートの中身を準備しますが、それを共有の
Content Library に置くのは、そのライブラリへの権限を持つ人です。

## 小さな用語集

| 用語 | 何か | 〜に近いが |
|---|---|---|
| **Helm** | パラメーターとバージョンを持つマニフェストのテンプレートツール | 入力フィールド付きの OVF テンプレートに最も近いが、テキストであり Git の中にある |
| **チャート (chart)** | Helm パッケージ: テンプレート、デフォルト値、スキーマ | **OVF テンプレート**だが、1箇所で異なるパラメーターとともに何度もデプロイされる |
| **リリース (release)** | チャートを固有の名前でデプロイした具体的なインスタンス | **テンプレートからデプロイされた VM** だが、バージョン履歴を覚えていてロールバックできる |
| **values** | チャートをデプロイするときのパラメーター | **OVF デプロイウィザードのフィールド**だが、素の YAML であり、すべてと一緒に Git に保管される |
| **values.schema.json** | 許される値の記述 | **ウィザードのフィールド検証**だが、適用中ではなく適用前にチェックする |
| **ApplicationDefinition** | プラットフォームカタログのエントリ: 何を表示し何をデプロイするか | **Content Library のエントリ**だが、クラスターに1つで、すべてのテナントから見える |
| **Namespace** | 1人のオーナーのオブジェクトが住む、クラスターの区画 | **フォルダーやリソースプール**だが、権限の境界はこれに沿って走る: あなたのテナントは1つの namespace |
| **クラスタースコープ (Cluster-scoped)** | namespace を持たず、クラスター全体で共有されるオブジェクト | **vCenter レベルの設定**だが、それへの権限はテナントではなくプラットフォームチームに属する |
| **CRD** | Kubernetes に新しい種類のオブジェクトを追加する方法 | いったん登録されれば、あなたの型は組み込みのものと区別がつかない |

## lab フォルダーに何があるか

すべてのファイルはすでにそこにあります。リポジトリと一緒に手に入れました。新たに作成
したり打ち込んだりするものは何もありません。以下で `kubectl apply -f name.yaml` と書いて
あれば、そのファイルはここから取られます。

```bash
cd labs/13-catalog
```

| ファイル | 何か | いつ役に立つか |
|---|---|---|
| `chart/` | カタログ向けにパッケージ化されたあなたのアプリケーション: テンプレート、values、フォームフィールドのスキーマ | ローカルで読んで検証する |
| `applicationdefinition.yaml` | カタログエントリの記述: 何と呼ばれ、ダッシュボードに何を表示するか | 適用を試みて、権限拒否を見る |
| `guestpass-example.yaml` | 公開後にあなたのアプリケーションを注文する様子 | 読む。公開後にのみ適用できる |
| `icon.svg`, `icon.b64` | エントリのアイコン — ソースと、それを文字列にした同じもの。すでに定義に埋め込み済み | もしアイコンを変えるときに役立つ |
| `check.sh` | チャートがレンダリングされ、クラスターが受け入れることのチェック | lab の最後に実行する |

## ステップ 1. 何をパッケージ化するかを見る

`chart/` フォルダーには完成した「ゲストパス」チャートが入っています。中のアプリケーション
はあえてシンプルにしてあります。ページを持つ nginx です。なぜなら、この lab はアプリケーション
についてではなく、パッケージ化についてだからです。

```
chart/
├── Chart.yaml            name, version, description
├── values.yaml           parameters and default values
├── values.schema.json    which values to consider valid
└── templates/
    ├── configmap.yaml    the page and the nginx config
    ├── deployment.yaml   the application itself
    └── service.yaml      the address
```

<details>
<summary><b>もっと詳しく: チャートの中身</b></summary>

### `Chart.yaml` — パスポート

```yaml
name: guest-pass
version: 0.1.0
appVersion: "1.0"
```

2つの異なるバージョン番号があり、これらは絶えず混同されます。

`version` は**チャート**のバージョン、つまりパッケージのバージョンです。テンプレートを
いじった、パラメーターを追加した、説明のタイプミスを直した — これを上げます。

`appVersion` は中の**アプリケーション**のバージョンです。これは「ゲストパス」そのものの
新バージョンが出たときに変わり、パッケージのバージョンとは何のつながりもありません。

実用上の要点: `version` から管理者はデプロイの仕組みそのものが更新されているのかを判断
でき、`appVersion` から人々が実際に使うものが更新されているのかを判断できます。

### `values.yaml` — パラメーター

```yaml
## @param {int} replicas=2 - Number of application replicas.
replicas: 2

## @param {string} greeting=Order a pass for your guest - Text shown on the main page.
greeting: "Order a pass for your guest"

## @param {bool} external=false - Enable external access from outside the cluster.
external: false
```

`## @param` コメントは装飾でもなければ、人間向けのドキュメントでもありません。ここから
Cozystack のジェネレーター（`cozyvalues-gen`）が `values.schema.json` と、チャートの README
にあるパラメーター表を生成します。唯一の真実の源です。コメントを変え、スキーマを再生成
すれば、ダッシュボードのフォームもそれと一緒に変わります。

書式は厳格です: `## @param {type} name=default-value - Description.`

パラメーターはあえて少なくしてあります。新しいパラメーターは1つ増えるごとに、フォームの
フィールドが1つ増え、アプリケーションを間違ってデプロイする方法が1つ増え、あなたが保守
する分岐が1つ増えます。良いチャートは、インストールごとに本当に異なるものを設定させ、
それ以上のものは設定させません。

### `values.schema.json` — 何を有効とみなすか

スキーマは、何かがクラスターに送られる**前に** Helm によってチェックされます。その場で
確かめてみましょう。数値パラメーターに文字列を差し込みます。

```bash
# template = 「チャートからマニフェストを組み立てて出力する」、クラスターには触れません:
#   gp                    チャートが名目上デプロイされるリリース名
#   chart                 チャートの入ったフォルダー
#   --set replicas=abc    単一のパラメーターをコマンドラインで直接上書きする
helm template gp chart --set replicas=abc
```

```
Error: values don't meet the specifications of the schema(s) in the following chart(s):
guest-pass:
- at '/replicas': got string, want integer
```

エラーはノートPC上で0.5秒で捕まえられます。スキーマがなければ、これはクラスターへ飛んで
いき、決して作成されない Deployment に変わり、3画面分のメッセージが付いてきたでしょう。

このまったく同じスキーマが、一字一句そのまま `ApplicationDefinition` に入ります。そして
そこでは、ダッシュボードの作成フォームへと育ちます。

### `templates/configmap.yaml` — ページ

```yaml
    <h1>{{ .Values.greeting }}</h1>
```

これこそが、そもそもテンプレートツールが存在する理由そのものです。`values` からの値が
レンダリング時にマニフェストに着地します。Helm がなければ、子会社ごとにマニフェストの
コピーを1つずつ持ち、手で編集しなければならなかったでしょう。

### `templates/deployment.yaml` — アプリケーション

```yaml
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

誰もが忘れる行で、あとで1時間のデバッグを費やさせる行です。

Kubernetes は **ConfigMap が変わっても Pod を再起動しません**。テキストを編集し、更新を
実行し、ダッシュボードは「更新済み」と表示するのに、ページは古い挨拶のままです。設定の
ハッシュを入れたアノテーションは設定と一緒に変わり、Pod のテンプレート内のアノテーション
の変更はすでに Pod 自体の変更なので、クラスターはそれを作り直します。

```yaml
            requests:
              cpu: {{ .Values.resources.cpu | quote }}
```

`quote` はここでは必須です。引用符がないと、YAML は値 `100m` は文字列として読みますが、
`1` は数値として読み、2回に1回は型エラーになります。引用符はこの種の問題を一気にまるごと
取り除きます。

### `templates/service.yaml` — アドレス

```yaml
  type: {{ if .Values.external }}LoadBalancer{{ else }}ClusterIP{{ end }}
```

1つのブール値パラメーターが、アプリケーションがクラスター外部のアドレスを得るかどうかを
決めます。組み込みの Cozystack アプリケーションはまさにこう作られています。そのほとんどが、
まさにこの意味の `external` フィールドを持っています。カタログでは他者の慣習に従う価値が
あります。あなたより前にマネージドサービスを3つデプロイした人は、このフィールドを同じ
場所に、同じ名前で探すからです。

</details>

## ステップ 2. チャートをローカルで検証する

📍 **場所:** ノートPC上。これにクラスターは不要です。

まずリンター。これはチャートをファイルの集まりとして読み、構造的なエラーを捕まえます。
インデントの誤り、必須フィールドの欠落、パースできないテンプレートなどです。

```bash
cd labs/13-catalog
# lint = 「パッケージを書式エラーと必須フィールドについてチェックする」
#   chart   チャートフォルダーへのパス。その中に Helm は Chart.yaml、values.yaml
#           と templates/ フォルダーを期待する
helm lint chart
```

**表示されるべきもの:**

```
==> Linting chart
[INFO] Chart.yaml: icon is recommended

1 chart(s) linted, 0 chart(s) failed
```

`[INFO]` はエラーではなく注意です。チャートに `icon` フィールドがないというもの。Cozystack
カタログにはそもそも不要で、アイコンは `ApplicationDefinition` から取られます。これには
後で触れます。

さてレンダリングです。テンプレートとは、一部の値が `{{ .Values.replicas }}` のかたちの
置換に差し替えられたマニフェストです。レンダリングとは、テンプレートを完成したマニフェスト
に変えることです。Helm は `values.yaml` から値を取り、テキストに差し込み、結果を出力します。

```bash
# main — リリース名、つまりこのチャートのこの具体的なデプロイの名前。これは
# 作成されるオブジェクトの名前に入るので、隣り合う2つのインストールが衝突しません。
helm template main chart
```

出力は普通のマニフェスト、最初の lab で手で書いたのと同じものです。Helm に魔法めいた
ところは何もありません。テキストに値を差し込むだけです。

パラメーターが本当にマニフェストに届くことを確認しましょう。異なる値で2回レンダリング
し、変わるはずだった行だけを出力から残します。

```bash
# --set replicas=5 は1回の実行の間だけ values.yaml の値を上書きします。
# | grep 'replicas:' — 出力全体からこの語を含む行だけを残します。
helm template main chart --set replicas=5 | grep 'replicas:'
# ブール値パラメーターも同様に: external はマニフェストにどの Service タイプが入るかを決めます
helm template main chart --set external=true | grep 'type:'
```

```
  replicas: 5
  type: LoadBalancer
          type: RuntimeDefault
```

3行目はエラーでも、あなたのタイプミスでもありません。`grep` はテキスト全体からその語を
探すので、`type:` はセキュリティ要件（`seccompProfile`）にも現れます。`grep` は YAML の
構造を理解しないという、役に立つ注意喚起です。フィールドではなく、行を探すのです。

⚠️ **`helm template` はクラスターへ何も送らず、その側で何もチェックしません。** テキストを
レンダリングします。`helm template` を通ったマニフェストでも、クラスターに拒否されることは
あります。たとえば CRD が欠けているためです。これは安価なチェックであって、完全なチェック
ではありません。

## ステップ 3. ApplicationDefinition を分解する

チャートはアプリケーションをデプロイする方法を知っています。しかしカタログはまだそれを
知りません。「ゲストパス」がダッシュボードに一覧として現れ、API 上のオブジェクトの型に
なるためには、もう1つファイルが必要です。

それはすぐそこにあります — `applicationdefinition.yaml` です。

<details>
<summary><b>もっと詳しく: applicationdefinition.yaml の中身</b></summary>

```yaml
apiVersion: cozystack.io/v1alpha1
kind: ApplicationDefinition
metadata:
  name: guest-pass
```

ここに**ない**ものに注目してください。`namespace` フィールドです。これがまさにこの
オブジェクトのクラスタースコープな性質です。クラスターに1つあり、それが生み出すカタログ
エントリはすべてのテナントから一度に見られます。

### `application` ブロック — API 上でどう見えるか

```yaml
  application:
    kind: GuestPass
    plural: guestpasses
    singular: guestpass
```

このファイルが適用されると、クラスターに新しい種類のオブジェクトが現れます。「連携」でも
「プラグイン」でもなく、普通の `kubectl` で扱う一人前の型です。次の2つのコマンドは、
管理者が定義を適用した瞬間に、どのテナントでも動きます。

```bash
# get = 「そこに何があるか見せて」。guestpasses は下の plural フィールドのまさにあの名前:
#   -n tenant-workshopXX   どの namespace を見るか。XX は自分の番号に置き換える
kubectl get guestpasses -n tenant-workshopXX
# describe = 「1つのオブジェクトについてすべて見せて」: パラメーター、状態、最近のイベント。
# ここでの main は型の名前ではなく、注文された具体的なアプリケーションの名前です。
kubectl describe guestpass main -n tenant-workshopXX
```

`plural` はコマンドと API URL に差し込まれるものです。`singular` は `kubectl describe` に
書くものです。どちらも小文字で、スペースなしで書きます。これはスタイルの問題ではなく、
Kubernetes の要件です。

```yaml
    openAPISchema: |-
      {"title":"Chart Values","type":"object","properties":{...}}
```

チャートに `values.schema.json` というファイルとして存在するのと同じスキーマ、ただし
JSON の1行として書かれたものです。これは2箇所で働きます。API は無効な値を拒否し、
ダッシュボードはこれから作成フォームを描きます — フィールドの型、デフォルト値、ヒント。

⚠️ **ここのスキーマとチャートのスキーマは一致していなければなりません。** 両者の間に自動的
なつながりはありません。これらは2つのファイルであり、同期を保つのはあなたの仕事です。
ずれさせてしまうと、ダッシュボードのフォームは一方のフィールドの組を表示し、チャートは
別のものを期待します。`check.sh` はこれをあなたに代わって突き合わせますが、そのチェックを
習慣にする価値があります。

### `release` ブロック — 何をデプロイするか

```yaml
  release:
    prefix: guest-pass-
```

リリース名はプレフィックスとオブジェクトの名前から作られます。`main` という名前の
`GuestPass` は `guest-pass-main` というリリースとしてデプロイされます。このフィールドは
必須です。異なるアプリケーションのリリースが1つの namespace で名前を衝突させないために
必要です。`main` と呼ばれるものは多くありますが、`guest-pass-main` はあなたのものだけです。

```yaml
    labels:
      sharding.fluxcd.io/key: tenants
```

Cozystack のサービスラベルです。これによって、テナントのリリースが Flux のハンドラーの
間に振り分けられます。これがないとリリースを世話する者がおらず、待ったまま止まってしまい
ます。ここは創意工夫を見せる場ではありません。そのままコピーしてください。

```yaml
    chartRef:
      kind: HelmChart
      name: cozystack-guest-pass
      namespace: cozy-public
```

チャートをどこから取ってくるか。`kind` の有効な値は3つあります: `OCIRepository`、
`HelmChart`、`ExternalArtifact`。

外部カタログは通常 `GitRepository` → `HelmChart` という連鎖で届きます。管理者があなたの
リポジトリを `cozy-public` namespace のソースとして追加し、Flux がそこからチャートを
引き出し、`ApplicationDefinition` がそのチャートを参照します。これはまさに
`cozystack/external-apps-example` に示されている道であり、始めるのに理にかなった場所です。

⚠️ **`chartRef` の名前はあなただけで考えて決められるものではありません。** それらは管理者
がソースを登録する仕方と一致していなければなりません。ファイルを送る前に合意してください。
さもないと定義は適用されるのにデプロイするものが何もなく、エラーは「作成」をクリックした
最初の人になって初めて表面化します。

### `dashboard` ブロック — インターフェイス上でどう見えるか

```yaml
  dashboard:
    category: PaaS
    singular: Guest Pass
    plural: Guest Passes
    description: Internal guest pass service for employees and reception
    tags: [internal, web]
```

`category` はカタログのセクションです。Cozystack は5つを使っています: `PaaS`、`IaaS`、
`NaaS`、`Administration`、`Networking`。既存のものを取ってください。自分専用のセクション
とは、エントリが1つだけのセクション、誰もあなたのアプリケーションを見つけられない場所を
意味します。

ここの `singular` と `plural` は、スペースと大文字を含む**人間向け**の名前です。
`application` ブロックのものと混同しないでください。あちらは API 向け、こちらは目のため
です。

```yaml
    icon: PHN2ZyB3aWR0aD0iMTQ0IiBoZWlnaHQ9IjE0NCIgdmlld0JveD0iMCAwIDE0NCAxNDQi...
```

アイコンは base64 でエンコードされた SVG です。パスでもリンクでもなくエンコードされたもの
です。ダッシュボードはそれをダウンロードするためにどこにも行きません。絵はオブジェクトそ
のものの中に住んでいます。

ソースはすぐそこ、`icon.svg` にあり、出来上がった文字列は `icon.b64` にあります。ソースを
編集したなら、文字列は作り直さなければなりません。エンコーダーはデフォルトで出力を行に
分割しますが、`icon` フィールドには途切れない1本の文字列が必要です。ですから改行は別の
ステップで取り除かれます。

```bash
# base64 = バイナリファイルを、英字・数字・記号 + / = の文字列に変える
#   -i icon.svg   何をエンコードするか（macOS と BSD のフラグ表記）
# tr -d '\n' = 出力からすべての改行を落とし、1本に貼り合わせる
base64 -i icon.svg | tr -d '\n'
```

Linux では同じコマンドのフラグが異なります: `base64 -w0 icon.svg`、ここで `-w0` は
「出力をまったく折り返さない」という意味です。GNU と BSD のフラグ表記はここでは一致
しません。

キャンバスサイズ 144×144 はプラットフォームの組み込みアイコンに合わせてあります。これ以上
は不要です。カタログでは小さく描かれます。

```yaml
    keysOrder: [["apiVersion"], ["kind"], ["metadata"], ..., ["spec", "replicas"], ...]
```

オブジェクトの YAML 表現でのフィールドの順序です。装飾的なものですが、これがないと
フィールドは好き勝手に並び — めったに使わない `resources` が先、主役の `replicas` が後に
なり — フォームは本来より読みにくくなります。

</details>

## ステップ 4. 適用を試みて — 拒否される

📍 **場所:** ノートPC上、テナントアクセスで。

ファイルは準備でき、構文的にも健全です。権限があるかのように適用してみましょう。拒否は
`kubectl` からではなくクラスターから来て、拒否の文言は何が足りなかったかをはっきり述べます。

```bash
# テナントアクセス — ワークショップを通してずっと扱ってきたのと同じもの
export KUBECONFIG=~/.kube/workshop
# apply = 「クラスターをファイルに書かれたものに合わせる」; -f — ファイルから読む
kubectl apply -f applicationdefinition.yaml
```

**表示されるもの:**

```
Error from server (Forbidden): error when creating "applicationdefinition.yaml":
applicationdefinitions.cozystack.io is forbidden: User "workshopXX" cannot create
resource "applicationdefinitions" in API group "cozystack.io" at the cluster scope
```

拒否は想定どおりです。lab の冒頭で述べたとおり。ここで大事なのは最後の4語です —
**at the cluster scope**（クラスタースコープにおいて）。

<details>
<summary><b>答えと、このエラーより広い教訓</b></summary>

テナントにおけるあなたの権限は、1つの namespace の内側の権限です。あなたは自分の一区画の
完全な主です。クラスターを立ち上げ、データベースや VM を作り、削除し、壊し、直します。
あなたのオブジェクトのどれ1つとして、隣人から見えたり、隣人に干渉したりしません。

`ApplicationDefinition` は別のつくりです。これは**すべてのテナントのために一度に**カタログ
を変えます。スキーマにエラーのあるアプリケーションをあなたが適用すれば、他部署の人々が
それを見て、試すことになります。既存のものと同じ名前を付けたアプリケーションは、既存の
ものを壊します。

だからこそ境界はまさにここに走っており、それは不信のためではありません。vSphere でも同じ
でした。自分のプールで自分の VM は自分で作りましたが、共有 Content Library の中身と、それ
への権限は — 作りませんでした。

**実務で何をするか。** プラットフォーム管理者に2つのファイルと1つの合意を渡します。

| 何を渡すか | なぜ |
|---|---|
| `applicationdefinition.yaml` | 彼が適用する、オブジェクトそのもの |
| チャートの入ったリポジトリへのリンク | ここから管理者は `cozy-public` にソースを構築する |
| `chartRef` の合意された名前 | 定義がチャートを見つけられるように |

そして送る前に、両方のファイルが問題ないことを確認してください。ここではフィードバック
ループが長いからです。管理者が適用し、3人目がエラーを目にするのです。

</details>

拒否はファイルそのもののエラーから来た可能性もあります。この2つを切り分けましょう。まず
権限について尋ね、次に `kubectl` にファイル全体をパースさせ、どこにも送らせません。

```bash
# auth can-i = 「私は許可されている?」。答えは yes か no で、クラスターは変わりません。
kubectl auth can-i create applicationdefinitions
# --dry-run=client = 「ファイルをパースして何が出てくるか見せる、ただしクラスターへは行かない」。
# client は、チェック全体がノートPC上で走り、クラスターはそれについて一切耳にしないという意味です。
kubectl apply -f applicationdefinition.yaml --dry-run=client
```

**表示されるべきもの。** 1つ目のコマンド — `no`。2つ目 —
`applicationdefinition.cozystack.io/guest-pass created (dry run)`: ファイルはパースされ、
構文は問題なく、問題は本当に権限です。

⚠️ **`--dry-run=client` は構文だけをチェックします。** クラスターには何一つ尋ねません。
`--dry-run=server` なら尋ねるでしょうが、それにはまさに、いま欠けている権限が必要です。

## ステップ 5. 子会社に何が見えるか

管理者が定義を適用すると、カタログにエントリが加わります。その瞬間から、どのテナントも
Redis をデプロイしたのと同じかたちで「ゲストパス」をデプロイします。**Create application**
→ `Guest Pass` → あなたの4つのパラメーターから成るフォーム → ボタン。

あるいはテキストとして — このフォルダーの `guestpass-example.yaml` ファイルです。

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: GuestPass
metadata:
  name: main
  namespace: tenant-workshopXX
spec:
  replicas: 2
  greeting: "Order a pass for your guest"
  external: false
```

グループに注目してください: `apps.cozystack.io` — `Bucket` や `VMInstance` と同じです。
あなたのアプリケーションは、脇にそれてではなく、組み込みのものと**同じ列に**居場所を得た
のです。テナントのアプリケーション一覧に同じように現れ、そのリソースは同じように数えられ、
権限は同じように働きます。

⚠️ 管理者が定義を登録する前にこのファイルを適用することはできません。`kubectl` は
`no matches for kind "GuestPass"` と答えます — クラスターにはまだそのようなオブジェクトの
型がないのです。

## ステップ 6. これをすべて手で書かない方法

この lab で分解したものはすべて骨組みです: `Chart.yaml`、`values.yaml`、スキーマ、
テンプレート、正しい名前とラベルを持つ `ApplicationDefinition`。ファイルの半分は、どこでも
同じ必須フィールドで、書くよりも間違える方が簡単です。

そのために、出来合いのツールがあります。

| 何 | どこ | なぜ |
|---|---|---|
| `cozystack/ccp` リポジトリ | github.com/cozystack/ccp | Claude Code 用のプラグインとスキルの集まり |
| `cozystack` プラグイン | そこから | Cozystack パッケージの構造を Claude Code に教える |
| `external-app-create` スキル | プラグイン内 | 外部アプリケーションの骨組み全体を生成する |
| サンプルリポジトリ | github.com/cozystack/external-apps-example | チャートのビルドと公開を含む動く例 |

スキルはアプリケーション名、kind、カテゴリ、パラメーターを尋ね — 完成したファイルツリー
を並べます。スキーマ付きのチャート、正しいプレフィックスとラベルを持つ
`ApplicationDefinition`、ビルド用の Makefile。

これをすべて手で分解することは、その意義を失いません。生成された骨組みはやはり読んで編集
しなければならず、理解していないものを編集することは、知られている中で最悪の働き方です。

## チェック

📍 **場所:** ノートPC上、`kubectl` で作業したのと同じターミナルウィンドウで。

スクリプトは**ローカルで**走り、クラスターには触れません。チャートがリンターを通ること、
レンダリングされること、パラメーターが本当にマニフェストに届くこと、`ApplicationDefinition`
がパースされて必須フィールドをすべて含むこと、アイコンが SVG にデコードされること — そして
最も重要なこととして、定義のスキーマがチャートのスキーマと一致することをチェックします。

```bash
# 名前の前の ./ は「現在のフォルダーからのファイル」、つまり labs/13-catalog からを意味します
./check.sh
```

⚠️ **Windows ではスクリプトは WSL から実行します**、PowerShell からではありません — 設定
方法は lab 0 の冒頭に書いてあります。WSL がなくても lab は完了できますが、アーティファクト
レポートは出ません。

`KUBECONFIG` が設定されていれば、スクリプトはクラスターにも権限について尋ね、あなたに定義
を適用する資格がないことを確認します。スクリプトは権限がないことを、エラーではなく期待
される結果として数えます。

## 後片付け

片付けるものは何もありません。あなたはクラスターに何も作成しませんでした。これはワーク
ショップで唯一、痕跡を残さない lab であり、それがこの lab の際立った特徴です — プラット
フォームチームの仕事の大半は、まさにこう見えます: テキスト、レビュー、apply は他人の手で。

`chart/` と `applicationdefinition.yaml` のファイルを持ち帰ってください。これは動く出発点
です。あなたのカタログ向けの本物のアプリケーションが、ここから育ちうるのです。

## いま何ができるようになったか

- アプリケーションをパラメータースキーマ付きの Helm チャートにパッケージ化し、ローカルで検証する
- `ApplicationDefinition` を書き、その各ブロックの目的を説明する
- なぜカタログが共有され、なぜテナントにそれへの権限がないのかを理解する
- 管理者が一発でファイルを適用できるよう、引き継ぎを準備する
- 骨組みを何で生成するか、どの例を見るべきかを知る

## vSphere ならこれは

Content Library と、入力フィールド付きの OVF テンプレートです。仕組みは見た目より似ています。
一方のチームがテンプレートを準備し、別のチームがそれを共有ライブラリに置き、また別の者
たちがそれをデプロイします。

違いは、何を手にするかにあります。OVF テンプレートはディスクを持つマシンです。デプロイ
すれば、そこから先はそれ自身で生き、コピーごとに手で更新することになります。
`ApplicationDefinition` はチャートに裏打ちされた記述です。チャートを更新し、バージョンを
上げれば、すべてのインストールが1つの仕組みで更新されます。

**vSphere の方が便利なところ、正直に言えば。** Content Library は出来合いのインターフェイス
です。ファイルを放り込み、権限を配れば、完了。こちらではリポジトリを用意し、チャートの
ビルドと公開を設定し、ソースの名前を管理者と合意する必要があります — しかもそのすべてを、
何かがカタログに現れる前にやるのです。参入の敷居はより高く、最初のアプリケーションには
1時間ではなく1日かかります。

それが報われるのは、2つ目と3つ目のアプリケーションで、とりわけ最初の更新のときです。
5つの子会社に広がったアプリケーションを、チャートから更新するのと、同じアプリケーションを
5つのずれ合った OVF コピーで更新するのとでは — 仕事の量が違います。桁が違うのです。
