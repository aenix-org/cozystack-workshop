# ラボ11 · クラスター内でモバイルアプリをビルドする

| | |
|---|---|
| **所要時間** | 40分。うち最大15分は最初のビルド待ちに費やします |
| **何を証明するか** | ビルドサーバーはサーバーではなく、ビルドの間だけノードを占有し、終わったら解放するタスクである |
| **必要なもの** | ラボ0で作ったクラスター、`kubectl`、`~/lab.kubeconfig`、テナントのダッシュボードへのアクセス |

## なぜこれが重要か

モバイルチームはPropuskのクライアントを開発しています。従業員がゲスト用のパスを申請する、
まさにあの画面です。今のところ、そのビルドはある開発者1人のノートPCで行っています。その人が
休暇に入ると、リリースはできません。

自前のビルドサーバーは持っていませんし、今後も持てません。Android SDK用の専用マシンの申請は
二度却下されました——「負荷が不均一で、マシンは遊んでしまう」というわけです。正直なところ、
それは事実です。ビルドは1日20分しか動きませんが、そのために必要なマシンは4コア・16ギガバイト
です。

ここでは、まさに求められている通りにやります。その4コアを**20分だけ**借りて、APKをビルドし、
返します。そして出来上がったファイルは、電話を持ったテスターも含め誰でも取りに来られる場所、
すなわちbucketに置きます。

すべてのラボを通じて、ワークロードが**終了する**のはこれが初めてです。これまでデプロイして
きたものはすべて、永遠に動き続けることを想定していました。

## ミニ用語集

| 用語 | 何か | 似ているのは…ただし |
|---|---|---|
| **Job** | タスク。何かを実行し、正常に終わるまで待つ | **ゲストOS内のスケジュールされたタスク**に似ていますが、jobは実行用のマシンを自分で作り、自分で片付けます |
| **Deployment** | 永遠に動き続けるアプリケーションの記述 | **vApp**に似ていますが、決して「正常終了」しません。消えたコピーは再作成されます |
| **オブジェクトストレージ** | ファイルもディレクトリもないストレージ。あるのはキーとその中身だけ | **データストア**に似ていますが、マウントはしません。オブジェクトを丸ごと、HTTP経由で置いたり取り出したりします |
| **Bucket** | オブジェクトストレージ内の名前付きの領域 | **データストア上のフォルダ**に似ていますが、入れ子にはなりません。bucketは最上位であり、その中の「フォルダ」はオブジェクト名の一部です |
| **S3** | オブジェクトストレージにHTTP経由でアクセスするためのプロトコル | 直接の対応物はありません。NFSよりはREST APIに近いです |
| **アクセスキー** | ログインとパスワードの代わりの「access key / secret key」のペア | **サービスアカウント**に似ていますが、キーは人単位ではなくbucket単位で発行されます |
| **Secret** | パスワードやキーを入れておくクラスターのオブジェクト | **認証情報ストアのエントリ**に似ていますが、クラスター内ではそれは暗号化ではなくbase64です。人目からは隠しますが、管理者からは隠しません |
| **emptyDir** | Podとまったく同じ期間だけ存在する一時ディスク | **一時的なvmdk**に似ていますが、Podとともに消え、復元する手段はありません |

### JobとDeployment — 一つの表で

これはこのラボの肝となる区別であり、何かをapplyする前にしっかり押さえておく価値があります。

下の両方の行に**Pod**という語が出てきます。Podはクラスターにおける実行の最小単位で、特定の
ノード上に立ち上げられたコンテナ（1つまたは複数）です。最も近い対応物は単一のタスク専用の
仮想マシンですが、数秒で作成され、ノードより長生きしない点が違います。JobもDeploymentも、
それ自体は何も実行しません。Podを作り、Podが消えたときにどうするかを決めるだけです。

| | Deployment | Job |
|---|---|---|
| 「すべて順調」とは何か | コピーが今まさに動いていること | プロセスがコード0で終了したこと |
| Podが正常終了した | クラスターはそれを障害とみなし、新しいものを作る | クラスターは仕事が完了したとみなす |
| どれだけ生きるか | 削除するまで | 完了まで走りきるまで |
| 何回実行されるか | 一度も。「実行」するのではなく、動き続ける | 一度（または指定された回数だけ） |
| あとに残るもの | 動いているアプリケーション | 仕事の成果とログ |

ここから、誰もがつまずく実践的な帰結が出てきます。**ビルドをDeploymentとして動かすと、
クラスターはそれを何度も何度も実行します**。ビルドが正常終了した——だからコピーは消えた——
だから新しいものを作らなければならない。無限ループです。しかもクラスターのせいではありません。
そう言いつけられただけなのです。

## ラボのフォルダに何があるか

ファイルはすべてすでに手元にあります——リポジトリと一緒に受け取っています。作成したり打ち
直したりするものは何もありません。以下で `kubectl apply -f name.yaml` と書かれている箇所では、
そのファイルはここから来ます。

```bash
cd labs/11-android
```

| ファイル | 何か | いつ必要になるか |
|---|---|---|
| `bucket.yaml` | ビルド済みAPKを置くストレージ | **テナントで**applyします |
| `propusk-src.yaml` | モバイルアプリPropuskのソースコード | 自分の `lab` クラスターでapplyします |
| `android-build.yaml` | ビルドそのもの。スクリプトはjobに直接書き込まず、ConfigMapに切り出してあります | これも同じ場所でapplyします |
| `check.sh` | ビルドが成功し、APKがストレージに届いたかの確認 | ラボの最後に実行します |

## ステップ1. bucketを作る

📍 **場所:** ブラウザで、テナントのダッシュボードで。

**テナント**はプラットフォームにおけるあなたの区画です。ダッシュボードで見えるもの、そして
あなたが管理するものです。ラボ0の `lab` クラスターはその中で注文しましたし、bucketもそこで
注文します。

bucketは**マネージドサービス**、つまりすぐ使えるカタログの品目です。必要なものを伝えれば、
プラットフォームがそれを立ち上げ、更新し、修復します。それは **`lab` クラスターの中ではなく**、
その隣、テナントに存在します。そしてそれが本来あるべき姿です。ビルドの成果物は、それがビルド
されたクラスターより長生きするからです。

テナントのアクセスファイル（kubeconfig）はダッシュボードから取得します: **Info → Secrets タブ →
`kubeconfig-tenant-workshopXX`**、そして `~/.kube/workshop` に保存します。他のすべてのラボと
同じパスです。

テナント → **Create application** → `Bucket`。

| フィールド | 値 | なぜそうするか |
|---|---|---|
| Name | `builds` | 短く、中身が何か分かる |
| Users | ユーザー `ci` を追加 | ビルドはこのキーで書き込む |
| Locking | オフ | オブジェクト削除に対する保護。ビルドには過剰 |
| Storage pool | 空のままにする | デフォルトのプールで十分 |

**同じbucketをテキストで**書くなら、こうです。注意: ここでの `namespace`（クラスター内の仕切り。
あなたのテナントは独立した1つのnamespaceです）はテナントのものであり、`lab` クラスター用では
なくテナントのアクセスファイルが必要です。

```bash
# KUBECONFIG — which access file kubectl uses. Here it's the tenant's: the bucket
# is ordered on the management cluster, not in the lab cluster
export KUBECONFIG=~/.kube/workshop

# apply = "bring the cluster to what's described in the file." The command doesn't create
# the storage itself — it hands the order to the platform.
#   -f bucket.yaml   which file to apply. Before this, replace
#                    tenant-workshopXX in it with your namespace, or the order goes elsewhere
kubectl apply -f bucket.yaml
```

**表示されるはず** — `bucket.apps.cozystack.io/builds created`。

<details>
<summary><b>詳しく見る: bucket.yaml の中身</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
```

`apps.cozystack.io` は、プラットフォームのマネージドサービスが属するAPIグループです。仮想マシン、
データベース、キューも同じプレフィックスを持ちます。これは「Kubernetesの上に載せたアドオン」では
ありません——プラットフォームが記述する、ごく普通のKubernetesオブジェクトです。

```yaml
spec:
  users:
    ci: {}
```

ユーザーのマップです。各キーが個別のS3ユーザーで、それぞれにプラットフォームが**専用の**
アクセスキーのペアを発行します。空のオブジェクト `{}` は完全なアクセスを意味します。

1つのbucketに複数ユーザーを置く理由: ビルドには書き込みが必要ですが、モバイルチームとテスターには
読み取り専用で十分です。異なるキー、異なる権限、個別に失効させられます:

```yaml
  users:
    ci: {}
    mobile:
      readonly: true
```

ラボの時間を節約するため1人で済ませますが、知っておく価値はあります。

</details>

bucketのプロビジョニングには数秒かかります。ダッシュボードで使用可能と表示されるまで待ちます。

## ステップ2. キーを取得する

📍 **場所:** ダッシュボードの、bucketのカードの **Secrets** タブ。

`bucket-builds-ci-credentials` Secret を探します。中には4つの値があります:

| フィールド | 何か |
|---|---|
| `endpoint` | ストレージのアドレス。`https://` は**付いていません**——プレフィックスは自分で足す必要があります |
| `bucketName` | 本当のbucket名。識別子付きで長く、`builds` ではありません |
| `accessKey` | 「ログイン」 |
| `secretKey` | 「パスワード」 |

⚠️ **`bucketName` はあなたが入力した名前ではありません。** `builds` という名前はCozystack
オブジェクトの名前です。ストレージ内の本当のbucket名はプラットフォーム自身が発行し、
`bucket-a9209f83-...` のような見た目です。置き換えるべきはまさにこれで、さもないと存在しない
bucketへのアクセス拒否を食らい、タイプミス探しに10分費やすことになります。

この同じ4つの値はコマンドラインからも取得できます——プラットフォームは、あなたが作成した各
アプリケーションの認証情報へのアクセスを付与します。下のコマンドは4つのうち1つ、`accessKey` を
取り出します。残りも同じ方法で取得でき、変わるのはフィールド名だけです。

```bash
# We work with the same tenant access as in the previous step: the secret lives in the tenant.
# get secret = "show the object with passwords and keys." The values inside the secret are
# base64-encoded — this isn't encryption, just a way of writing binary data as text.
#   -n tenant-workshopXX   which namespace to look in
#   -o jsonpath='...'      return not the whole object, but a single field from it:
#                          .data.accessKey — the accessKey field inside the data section
#   base64 -d              decode it back into readable form (d = decode)
#   ; echo                 add a line break: without it the value would run into
#                          the next terminal prompt
kubectl -n tenant-workshopXX get secret bucket-builds-ci-credentials \
  -o jsonpath='{.data.accessKey}' | base64 -d; echo
```

ただし、テナントがすべてのシークレットをまとめて読むことは許可されていません。`kubectl auth can-i get
secrets` は `no` と答えます。権限は特定の名前に絞って付与されています——そしてラボ0のあなたの
クラスターのkubeconfigに対しても同様です。

## ステップ3. キーを自分のクラスターに入れる

ビルドは `lab` クラスターで走りますが、キーはテナントにあります。クラスターは別物で、自動では
何も移りません。手で移します。

📍 **場所:** ノートPC上。

前のステップの4つの値で、`lab` クラスターに自前のシークレットを組み立てます。フィールド名は
変えないでください。ビルドスクリプトはまさにこの名前の変数を探します。

```bash
# From here to the end of the lab we work with the lab cluster, not the tenant
export KUBECONFIG=~/lab.kubeconfig

# create secret generic = "create a secret from the values I'm about to list."
# generic means "an arbitrary set of name-value pairs," not a ready-made type
# for an image-registry password or a TLS certificate.
#   bucket-creds        the secret's name. The Job will reference it by this name
#   --from-literal=name='value'   one pair. In place of PASTE_..., substitute
#                       the values from the bucket's card in the dashboard
kubectl create secret generic bucket-creds \
  --from-literal=endpoint='PASTE_endpoint' \
  --from-literal=bucketName='PASTE_bucketName' \
  --from-literal=accessKey='PASTE_accessKey' \
  --from-literal=secretKey='PASTE_secretKey'
```

**表示されるはず:**

```
secret/bucket-creds created
```

⚠️ **引用符はシングルクォートを使うこと。** シークレットのキーには `$`、`!`、`&` がよく
含まれます。ダブルクォートの中ではシェルがそれらを独自に解釈してしまい、コピーしたものとは
別のキーになってしまいます。

**このコマンドがファイルとしてリポジトリに置かれず、手で打たれる理由。** これらのラボの他の
すべては、Gitに入れられるテキストです。シークレットはそうではありません。クラスター内の
`Secret` オブジェクトは値をbase64で保存しますが、base64は暗号化ではなく書き方にすぎません。
ファイルにたどり着いた者は誰でもキーを読めます。Gitの中のシークレットファイルとは、履歴全体を
含め、キーが永遠にGitの中にあるということです。これはまさに、Propuskのシナリオに OpenBao を
登場させる類の監査指摘です。

## ステップ4. これから何をビルドするのか見る

フォルダには `propusk-src.yaml`——ConfigMapとしてのアプリのソースコードがあります。**ConfigMap** は
テキストファイルを内部に保持するクラスターのオブジェクトで、クラスターはそれらをコンテナ内に
ディスク上の普通のファイルとして配置します。最も近い対応物は設定ファイルの共有フォルダですが、
それがクラスター自身に保存され、タスクの記述と一緒に届く点が違います。

ソースコードがそこにあるのも同じ理由です。ビルドにはファイルが必要ですが、6つのテキストファイルの
ためにネットワークディスクを用意する意味はありません。

アプリがすることは1つ、«Request a guest pass» という行を表示することです。それで十分です。
このラボはAndroidについてではなく、それがどこでビルドされるかについてだからです。

**APK** が最後に出てくるものです。コンパイル済みのアプリケーション、画像、テキスト、どの画面を
起動するかの記述を含むアーカイブで、電話がインストールするのはまさにこれです。役割としては
Windowsの `.msi` と同じ、ユーザーに手渡す1つのファイルです。

<details>
<summary><b>詳しく見る: ソースコードの中身</b></summary>

6つのファイルが、ConfigMapのキーに分かれて入っています。

### `settings.gradle.kts` — Gradleが依存関係を探す場所

```kotlin
pluginManagement {
  repositories { google(); mavenCentral(); gradlePluginPortal() }
}
```

Androidのビルドプラグイン、Kotlinプラグイン、そしてそれらが引き込むすべてがダウンロードされる、
3つのパブリックリポジトリです。このリストこそが、最初のビルドが遅い理由を説明します。空の
コンテナからは、すべてを引っ張ってこなければなりません。

⚠️ このまさに同じ箇所が、セキュリティが依存関係のためにインターネットへ出ることを禁じたとき、
あなたが最初に変える場所です。そのときはここにあなたのプロキシリポジトリが書き込まれます。
ちょうどHarborがDocker Hubの代わりになったのと同じです。

### `build.gradle.kts` — ツールのバージョン

```kotlin
plugins {
  id("com.android.application") version "8.5.2" apply false
  id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
```

`apply false` は「バージョンは宣言するが、ルートプロジェクトでは有効にしない」という意味で——
有効にするのは `app` モジュールです。バージョンは意図的に固定してあります。「最新」を引っ張る
ビルドは、1か月後には今日とは違うようにビルドされ、その理由を調べるのはあなたです。

### `app-build.gradle.kts` — モジュールそのもの

```kotlin
android {
  namespace = "io.aenix.propusk"
  compileSdk = 34
  defaultConfig { minSdk = 24; targetSdk = 34 }
}
```

`compileSdk 34` は、コンパイル対象とするAndroid SDKのバージョンです。これはSDKインストールの
ステップで何をダウンロードしなければならないかも正確に決め、それはおよそ1.5ギガバイトです。

`minSdk 24` は、アプリが動作する最も古いAndroidです。ここではAndroid 7です。

```kotlin
  kotlinOptions { jvmTarget = "17" }
```

KotlinはJVMバイトコードにコンパイルされるため、Javaのバージョンに要件が生じます。使用する
イメージはJDK 17を同梱しており、この2つの数は一致していなければなりません。

### `MainActivity.kt` — アプリケーション

```kotlin
class MainActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    ...
    view.text = getString(R.string.greeting)
```

1つのアクティビティ、1つの `TextView`、リソースからのテキスト。互換ライブラリではなく素の
`android.app.Activity` を使っています。アプリの外部依存はゼロで、それが毎回のビルドで数分の
ダウンロードを節約します。

`R.string.greeting` は `strings.xml` の文字列への参照です。`R` クラスはビルド時に生成され、
ソースには含まれません。「unresolved reference: R」というエラーが出たら、それはあなたのコード
ではなく、リソース生成のステップが失敗したという意味です。

### `AndroidManifest.xml` と `strings.xml`

マニフェストは、どのアクティビティがアイコンから起動するかを宣言します。`strings.xml` はテキストを
コードから分けて保持します——そうすることで、プログラマーを煩わせずに翻訳できます。

</details>

ソースコードをクラスターに入れます。まだ何も動きません。これは次のステップでビルドが必要とする
ファイルにすぎません。

```bash
# Creates a ConfigMap with six files inside. To check it's in place:
# kubectl get configmap propusk-src
kubectl apply -f propusk-src.yaml
```

**表示されるはず** — `configmap/propusk-src created`。

## ステップ5. Jobを分解する

実行する前に、自分が何を実行するのかを読んでください。ビルドはノードを丸ごと占有します。何の
ためなのかを理解しておく価値があります。

<details>
<summary><b>詳しく見る: android-build.yaml の中身</b></summary>

ファイルには2つのオブジェクトがあります。ビルドスクリプトの入ったConfigMapと、Jobそのものです。

### ビルドスクリプト

これがConfigMapに入っているのは、nginxのページがDeploymentと別に置かれていたのと同じ理由です。
`command` フィールドの中に40行のシェルがあっては読めません。

5つのステップで、5つとも、ビルドサーバー上で手で打つような普通のコマンドです。コンテナは空の
状態で始まります。イメージ由来のJavaとGradleはありますが、Android SDKもキーもソースもありません
——SDKとキーはビルドコマンドが引き込み、ソースはコンテナにマウントされたConfigMapが持ってきます。

| ステップ | 何をするか | どれくらいかかるか |
|---|---|---|
| 1 | Android command-line tools をダウンロードする——SDK自体をインストールするのに使うユーティリティ群 | 1〜2分 |
| 2 | ライセンスに同意し、SDK、platform 34、build-tools をインストールする | 5〜15分 |
| 3 | `gradle :app:assembleDebug` — ソースをAPKにコンパイルする | 3〜8分 |
| 4 | S3ストレージ用のコマンドラインクライアント `mc` をインストールする | 数秒 |
| 5 | APKを2つの名前でbucketに置く | 数秒 |

3行が、より詳しく見る価値があります。

```bash
# yes — a command that prints "y" endlessly: this way a batch of "accept the
# license? [y/n]" questions gets answered without a human.
#   >/dev/null 2>&1   discard both normal output and error output: it's not needed here
#   || true           "even if the command returned an error, treat it as fine"
yes | sdkmanager --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null 2>&1 || true
```

ここでの `|| true` は手抜きではなく必要です。`sdkmanager` が入力を閉じると `yes` はSIGPIPEを
受け取り、ゼロでないコードを返します。`set -o pipefail` の下では、これが理由もなくビルドを
失敗させてしまいます。ライセンスが本当に同意されていなければ、次のコマンドがSDKのインストールを
拒否するので、エラーを隠しているわけではありません。

```bash
# alias set = "remember the storage address and keys under the short name builds," so
# we don't repeat them in every copy command that follows.
#   "https://${endpoint}"   the address: we add the https:// prefix ourselves, it's not in the secret
#   ${accessKey} ${secretKey}   the login and password in S3 terms, they come from the secret
#   >/dev/null              suppress the output
mc alias set builds "https://${endpoint}" "${accessKey}" "${secretKey}" >/dev/null
```

出力は意図的に消してあり、スクリプトに `set -x` がないのも同じ理由です。Jobのログはクラスターに
アクセスできる全員に見えるので、キーがそこに残ってはいけません。

```bash
# echo prints a line to the task's log. It does no work — it's a marker
# that the previous copy command ran to completion
echo "APK-UPLOADED ${bucketName}/propusk/propusk-${STAMP}.apk"
```

マーカー行です。これによって `check.sh` は「Jobが走った」と「APKが実際にbucketに届いた」を区別
します——これらは異なる主張で、後者のほうが強い主張です。

### Job

```yaml
kind: Job
spec:
  backoffLimit: 1
```

ビルドが失敗した場合にPodを何回再作成するか。ゼロのほうが正直ですが、1.5ギガバイトのSDKを
ダウンロードしている最中にネットワークが時々途切れることがあり、2回目の試行のほうが「なぜ
自分のは失敗したのか」を調べるより安上がりです。

```yaml
  activeDeadlineSeconds: 7200
```

タスク全体に対する上限、2時間です。これがないと、ハングしたビルドが夕方までノードを握り続け、
デプロイできない隣人からそれを聞かされることになります。

カウントダウンはコンテナの起動からではなく、Jobの作成から始まります。`Pending` で過ごした時間や、
ラボの少し先で行うノードの再作成が、同じ制限を消費します。これには1時間では足りませんでした——
人がすでに待ちきったちょうどその直後に、ビルドが `DeadlineExceeded` で死んでいたのです。

```yaml
      restartPolicy: Never
```

Jobではこのフィールドは必須で、有効な値は2つだけです。`Never` は、失敗したプロセスを同じPod内で
再起動せず、判断をJobに委ねる——Jobが新しいものを作る、という意味です。そうすることで各試行が
自分のログを持ち、何回目が失敗したか分かります。

Deploymentでおなじみの値 `Always` はここでは使えません。「常に再起動する」と「終わるまで待つ」は
互いに矛盾するからです。

```yaml
          envFrom:
            - secretRef:
                name: bucket-creds
```

シークレットの4つのキーすべてが、同じ名前の環境変数になります。代わりに各変数を個別に列挙する
こともできますが、同種の4つのキーに対しては余計なノイズです。

⚠️ 知っておく価値のある副作用: `envFrom` は、あとから追加されたものも含め、シークレットの
**すべての**キーを環境に引き込みます。自分で作った、単一のタスク用のシークレットなら、それは
許容できます。namespace全体にまたがる共有シークレットに対しては、そうではありません。

```yaml
          resources:
            requests: {cpu: "1", memory: 4Gi}
            limits:   {cpu: "2", memory: 6Gi}
```

これがAndroidビルドの正直な値段です。`requests` は予約するもの、1コアと4ギガバイトです。これより
少なくても意味はありません——Kotlinコンパイラがそれを食い尽くし、もっと要求します。`limits` は
上限、2コアと6ギガバイトです。

最初のラボのアプリと比べてみてください。CPU `20m`、メモリ `32Mi`。CPUで50倍、メモリで130倍の
差です。これは「そもそもなぜ `requests` を指定するのか」という問いに関わります。それがなければ、
スケジューラはビルドをnginxと同じくらい軽いものとみなし、収まらないノードに配置してしまいます。

```yaml
        - name: work
          emptyDir:
            sizeLimit: 12Gi
```

ノード上の一時ディスクです。SDK、Gradleのキャッシュ、ビルド結果がここに置かれます——合計
6〜8ギガバイト。Podとまったく同じ期間だけ存在します。Jobが終われば、ディスクは消えます。

**ここから、なぜ毎回のビルドが遅いのかが直接導かれます。** 私たちは毎回SDKと依存関係をゼロから
ダウンロードしています。本物のビルドサーバーなら、`emptyDir` の代わりに永続ボリュームがあり、
それはタスクより長生きします。最初のビルドは遅く、2回目は目に見えて速くなります。ラボでは余計な
ものを持ち込まないため、あえてこれをしませんが、実際には最初に追加するのがこれです。

```yaml
            items:
              - key: app-build.gradle.kts
                path: app/build.gradle.kts
```

ConfigMapのキーはスラッシュを含められませんが、マウントパスは含められます。こうして6つのキーの
平坦なマップが、Gradleが期待するディレクトリツリーへと展開されます。

</details>

## ステップ6. 実行する——そして壁にぶつかる

📍 **場所:** ノートPC上、`lab` クラスターで。

jobをapplyし、それが作成したPodをすぐに見ます。

```bash
# Creates two objects from the file: a ConfigMap with the script and the Job itself.
# From this moment the cluster is obliged to find a node for the build and start it
kubectl apply -f android-build.yaml

# get pods = "show the Pods." The task's Pod has no name of its own — the Job invents it
# itself, appending a random tail to its own name. So we search not by name but by label:
#   -l job-name=propusk-build   select Pods with the job-name label equal to the job's name.
#                               The Job attaches this label to its Pods itself
kubectl get pods -l job-name=propusk-build
```

**おそらく表示されるもの:**

```
NAME                   READY   STATUS    RESTARTS   AGE
propusk-build-x7k2p    0/1     Pending   0          40s
```

`Pending` は「起動中」という意味ではありません。「起動しなかったし、起動しない」という意味です。
クラスターはその理由をPodのイベントに書きます——誰が何をしようとしたかの、そのPodの記録です。

```bash
# describe = "show everything known about the object": settings, state, events.
# The output is long, so we keep only its tail:
#   sed -n '/Events:/,$p'   print lines from the one where "Events:" appears,
#                           through the end of the output ($ — end)
kubectl describe pod -l job-name=propusk-build | sed -n '/Events:/,$p'
```

**表示されるはず** — Podが配置されなかった理由の行:

```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory.
```

> **読み進める前に、立ち止まって考えてください。**
>
> 何が合わなかったのでしょうか。ラボ0でどのノードを注文したか、そしてJobがどれだけのメモリを
> 要求したかを思い出してください。

<details>
<summary><b>答えと、このエラーより広い教訓</b></summary>

ラボ0では `u1.medium` ノード——1コアと4ギガバイトを選びました。Jobは `requests: memory 4Gi` と
`cpu 1` を要求します。ノードにあるのはまさにそれだけですが、その一部はすでに使われています。
kubeletは自分用にメモリを予約し、加えてノードはネットワークと監視のためのシステムPodを動かし、
加えて最初のラボのアプリもあります。

**両方とも**足りていないことに注意してください——CPUもです。`u1.medium` ノードは1コアを提供し、
ビルドは丸ごと1つを要求し、そのコアの一部はすでにシステムPodに取られています。だからメッセージには
理由が1つではなく2つあります。スケジューラにとっては、どちらか1つで十分なのです。

スケジューラはノード上のすべてのPodの `requests` を合計し、それをノードが実際に提供できる量と
比べます。空きが足りず、Podは永遠に待たされたままになります。

**このエラーより広い教訓。** Kubernetesのスケジューラは、実際の消費ではなく**宣言された**量を
数えます。すべてのPodがまどろみ、CPU使用率が3パーセントのノードでも、スケジューラから見れば完全に
埋まっていることがあります——`requests` の合計がすでに容量と等しければ。そして逆も然り。負荷で
息も絶え絶えのノードが、`requests` の合計が上限に達するまで新しいPodを受け入れ続けます。

これは、一見空に見えるクラスターで一見奇妙な `Insufficient cpu, Insufficient memory` の組み合わせも
説明します——これには一度ならず出くわすでしょう。

vSphereではあなたは両方に馴染みがあります。DRSが配置の際に考慮するreservationと、それとは別に見る
実際の負荷です。ここでは配置は、後半なしで、reservationからの**みで**計算されます。

</details>

## ステップ7. ノードを大きくする

📍 **場所:** ダッシュボードの、`lab` アプリケーションで。

`Kubernetes` → `lab` → 編集 を開きます。node group で、以下を変更します:

| フィールド | 変更前 | 変更後 | なぜ |
|---|---|---|---|
| Instance type | `u1.medium`（1コア、4GB） | `u1.large`（2コア、8GB） | ビルドが収まる最小 |
| Disk | `20Gi` | `40Gi` | SDK、Gradleのキャッシュ、イメージのレイヤーは20には収まらない |

テナントのクォータが許すなら、`u1.xlarge`（4コア、16GB）を選んでください。ビルドは目に見えて
速くなり、余分なリソースはラボの直後に返します。許さない場合は、保存時にフォームが拒否するので、
残るのは `u1.large` です。

⚠️ **ノードのタイプを変更すると、ノードの仮想マシンが再作成されます。** 古いノードは去り、新しい
ノードが立ち上がり、Podは移動します。これには数分かかり、ノードのローカルディスクにあったものは
すべて消えます。私たちのラボではこれは無痛です——データはノード上ではなくマネージドサービスに
あるからです——が、本番クラスターではこれは計画して行う操作です。

新しいノードを待ちます。`lab` クラスターにはグラフィカルコンソールがないので、コマンドで監視します:

```bash
# get nodes = "show the cluster's nodes" — those very virtual machines on which
# the Pods run.
#   -w   watch, "don't exit; append lines on every change." The old node
#        will drop from the list, a new one will appear and reach STATUS=Ready.
#        To leave the watch — Ctrl+C, which has no effect on the cluster
kubectl get nodes -w
```

ノードが `Ready` になり次第、止まっていたビルドのPodは自分で動き出します——スケジューラは
`Pending` のPodを絶えず見直しているので、頼む必要はありません。動き出したことを確認します:

```bash
# The same query as before the node edit. Now the STATUS column should show
# ContainerCreating, and in a minute or two Running
kubectl get pods -l job-name=propusk-build
```

## ステップ8. ビルドを待つ

📍 **場所:** ノートPC上、`lab` クラスターで。

ビルドはそのログで——つまり、コンテナ内でスクリプトが画面に出力するもので——見守ります。

```bash
# logs = "show what the task printed."
#   -f                  follow: don't exit, but append lines as they appear.
#                       Exit — Ctrl+C, the build keeps going regardless
#   job/propusk-build   you can point at the Job itself, not the Pod: kubectl will find its Pod on its own
kubectl logs -f job/propusk-build
```

**表示されるはず** — スクリプトの5つのステップが順番に。時間の目安:

| ログのマーカー | だいたいいつ |
|---|---|
| `== 1/5 installing Android command-line tools ==` | すぐ |
| `== 2/5 accepting licenses and downloading the SDK (the longest step) ==` | +1〜2分、そして最も長く止まる |
| `== 3/5 building the APK ==` | 開始から+5〜15分 |
| `BUILD SUCCESSFUL in ...` | 開始から+10〜25分 |
| `APK-UPLOADED bucket-.../propusk/propusk-...apk` | その直後 |

⚠️ **`2/5` のマーカーで20分間の沈黙があるのは正常で、フリーズではありません。** `sdkmanager` は
非対話モードではダウンロードの進捗を表示しません。黙っていて、その後 `done` と出力します。
プロセスが生きていることは別のターミナルウィンドウで確認できます——Podがどれだけの CPU と
メモリを食べているか見てください:

```bash
# top = "how much it's consuming right now." Not the requests claim, but actual usage
# this very second. Non-zero CPU means work is happening inside
kubectl top pod -l job-name=propusk-build
```

Jobは、Podがコード0で終了したときに完了とみなされます（ゼロの戻り値は、広く受け入れられた
「エラーなく走った」の意味です）:

```bash
# We look not at the Pod but at the job itself: it has columns the Pod doesn't
kubectl get job propusk-build
```

```
NAME             STATUS     COMPLETIONS   DURATION   AGE
propusk-build    Complete   1/1           18m32s     19m
```

`DURATION` カラムこそ、モバイルチームの「ビルドはどれくらいかかるのか」という問いへの答えです。
同じJobを削除して作り直して2回目を走らせても、同じだけかかります。キャッシュがなく、その理由も
分かっています。

## ステップ9. APKを取り出す

📍 **場所:** テナントのダッシュボードの、bucketのカードで。

bucketにはウェブインターフェースがあります——bucketのカードから開き、同じ `accessKey` と
`secretKey` でログインします。中には次が見えます:

```
propusk/propusk-20260821-141207.apk
propusk/propusk-latest.apk
```

1つのファイルに2つの名前を付けるのはよくあるやり方です。日付入りの名前はビルドの履歴を示し、
`latest` によってテスターは今日が何日かを尋ねずに常に最新のものを取ります。

`propusk` という「フォルダ」は実際には存在しないことに注意してください。オブジェクトストレージに
ディレクトリはありません。`propusk/propusk-latest.apk` はオブジェクト名の全体であり、その中の
スラッシュは、私たちの便宜のためインターフェースがツリーとして描いているものです。

**これが、あなたが慣れているファイル共有とどう違うか:**

| | ファイル共有（NFS、SMB） | オブジェクトストレージ（S3） |
|---|---|---|
| どう接続するか | ディスクとしてマウント | マウントしない、HTTP経由でリクエスト |
| 部分的な書き込み | ファイルの途中に書き込める | 不可、オブジェクトは丸ごと置く |
| ディレクトリ | 本物 | なし、スラッシュは名前の一部 |
| ロック | あり | なし |
| 誰が到達できるか | 同じネットワークにいる人 | キーとHTTPSを持つ人なら誰でも |
| どれだけ入るか | ボリュームが持てるだけ | 実質的に上限なし |

ここから選び方のルールが出ます。**データベースや文書の共有フォルダはファイル共有、成果物と
バックアップはオブジェクトストレージ**です。データベースをS3に置こうとするのは、インターネット
越しにSMBでAPKを配るのと同じくらい苦痛です。

## 確認

📍 **場所:** ノートPC上、あなたが `kubectl` で作業したのと同じターミナルウィンドウで。

```bash
# The script reaches the lab cluster with the same access file as you. The bucket
# credentials it takes from the bucket-creds secret — you don't need to enter anything separately
export KUBECONFIG=~/lab.kubeconfig
./check.sh
```

⚠️ **Windowsではスクリプトは、PowerShellからではなくWSLから実行します**——その入れ方はラボ0の
最初に書いてあります。WSLなしでもラボは完了できますが、成果物のレポートは出ません。

スクリプトが確認するのは、マニフェストをapplyしたことではなく、ビルドが最後まで走ったことです。
Jobが正常に終わり、ログに `BUILD SUCCESSFUL` があり、APKがbucketに届き、シークレットのストレージが
実際にクラスター内部から応答すること。

## 後片付け

終わってしまえば、Jobは何も消費しません。Podは終了し、そのコアとギガバイトは `Complete` の瞬間に
ノードの空き容量へ戻りました——他の誰かがすぐにそれを取れます。残るのはクラスター内の記録とログ
だけ——数キロバイトです。

すぐに削除する必要はありません。ログはまだ役に立ちます。済んだら:

```bash
# delete -f = "remove from the cluster what's described in this file." Along with the Job
# its logs will disappear too, so this command comes last in time, not first
kubectl delete -f android-build.yaml
kubectl delete -f propusk-src.yaml
# We delete the secret separately: there's no file for it, you created it with a command
kubectl delete secret bucket-creds
```

⚠️ **ノードはもう必要なければ `u1.medium` に戻してください**——さもないと、ワークショップの
終わりまで4コアを占有します。bucketとその中身は残しておいてください。小さいですし、作り直し
たくなったときに役立ちます。

この後片付けの安さこそが、専用ビルドサーバーに反対する論拠です。私たちはビルドの間だけ大きめの
ノードを取り、フィールドを1つ編集するだけで元のノードに戻しました。

## これでできるようになったこと

- JobをDeploymentと区別し、なぜビルドを後者として動かしてはいけないのかを理解する
- そのためのマシンを用意せずに、重い一度きりのタスクをクラスターで動かす
- 成果物をオブジェクトストレージに置き、それがファイル共有ではない理由を説明する
- `Pending` を「読み込み中」ではなく「`requests` で収まらなかった」と読む
- Androidビルドの本当の値段を、コア、ギガバイト、分で言える

## そしてvSphereではこうなっていた

ビルドエージェントとして使うVMの申請。1日20分しか働かないのになぜ16ギガバイトが必要かの正当化。
却下。四半期後の2回目の申請。そして98%の時間を遊んで過ごし、1年経つと、削除するのが怖いために
3世代分のSDKがインストールされているマシン。

ここでは、リソースはタスクの間だけ取られ、自分で返っていきます。

**正直に言って、vSphereのほうが便利な点。** ずっと生き続けるビルドマシンには、否定しがたい利点が
1つあります。その上ではすでにすべてがダウンロードされていることです。私たちのビルド時間の大半は
SDKと依存関係のダウンロードで、常設のエージェントならそれがありません。これはキャッシュ用の永続
ボリュームで解決できますが、ボリュームは用意し、サイズを見張り、掃除しなければなりません——つまり、
私たちが逃れようとしていた、まさにその仕事の一部を引き受け直すことになります。違いは、ボリュームは
二束三文で申請も要らないのに対し、マシンは申請が要ったという点です。

そして2つ目: ビルドがおかしな挙動をする理由を見るためにSSHで入れる生きたマシンは便利です。Jobの
Podではログを見ることしかできず、完了後はさらに少なくなります。クラスターでのビルドのデバッグは、
最初のうちは遅くなります。
