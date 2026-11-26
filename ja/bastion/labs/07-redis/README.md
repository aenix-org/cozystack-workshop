# ラボ7 · 遅いバックエンドの前にキャッシュを置く

| | |
|---|---|
| **所要時間** | 50分、うち10分は待ち時間 |
| **何を証明するか** | キャッシュの効果は宣言ではなく計測する。以前は800ミリ秒、今は1桁ミリ秒 |
| **必要なもの** | ラボ0のクラスター、ラボ6のHarborとイメージ、`kubectl`、`docker`、ダッシュボードへのアクセス |

> ⚠️ **`workshopXX` は名前ではなくプレースホルダーです。** 自分のテナント番号に置き換えてください。さもないとコマンドが他人のテナントに送られ、アクセス拒否になるか、もっと悪い場合には他人のデータを操作してしまいます。番号はパスワードと一緒に受け取っているはずです。

## なぜこれが重要か

「入館証（Passes）」サービスは動いていて、情報セキュリティ部門も満足、レジストリも自前のものになりました。そこへ警備員たちがやってきます。

> チェックポイントで来客リストが開くのに10秒かかる。人が列を作り、我々は画面を見つめて待つ。以前は問題なかったのに。

何が起きているか説明します。リストの各行が来客で、来客一人ひとりに招いた従業員がいます。そして従業員のレコードはあなたの手元にはありません。それは2011年に導入された人事システムの中にあり、1回のリクエストに応答するのに **800ミリ秒** かかります。画面に12行 — 合わせてほぼ10秒です。

人事システムを書き直すことはできません。あなたのものではなく、他人のもので、変更のバックログは来年まで埋まっています。同じ理由で、高速化することもできません。

あなたにできるのは、そこへ問い合わせる回数を減らすことです。従業員の姓や部署が変わるのは、せいぜい数年に一度です。リストが開くたびに **毎回** その遅いシステムに問い合わせるのは無駄です。一度問い合わせて答えを覚えておけば十分です。

答えを覚えておく場所をキャッシュと呼びます。今日はそれを一つ導入します。そして、より重要なのは、**前後の差を計測する** ことです。「速くなった」ではなく、具体的な数字で。

## ミニ用語集

| 用語 | それは何か | 〜に似ているが |
|---|---|---|
| **キャッシュ** | 繰り返される問い合わせに対する、できあがった答えの高速な保管場所 | **ストレージアレイの読み取りキャッシュ** に似ているが、ここでは何をキャッシュするかをデバイスではなくアプリケーションが決める |
| **Redis** | すべてをRAMに保持するキーバリューストア | 直接の対応物はない。最も近いのはmemcached、もし見かけたことがあれば |
| **キー** | キャッシュ内で値を引くための文字列 | **ファイル名** に似ているが、自分で考え出すもので、そのやり方次第ですべてが決まる |
| **TTL（time to live）** | エントリが自然に消えるまで存在する時間 | **スナップショットの保持期間** に似ているが、削除は誰の手も、スケジュールされたジョブも介さずに起こる |
| **ミス（キャッシュミス）** | 答えがキャッシュになく、遅い元のソースへ行かねばならない | **ストレージアレイの読み取りキャッシュのミス** に似ているが、ここでのミスの代償はミリ秒ではなく他人のシステムへの往復である |
| **ヒット（キャッシュヒット）** | 答えがキャッシュ内に見つかった | **読み取りキャッシュのヒット** に似ているが、ヒットを数えるのはアプリケーションで、それも応答の `cached` フィールドに現れる |
| **Sentinel** | Redisを監視し、障害時にリーダーの役割を再割り当てするサービス | **HAエージェント** に似ているが、Redis自体の内部で動作し、そのために別のクラスターは要らない |
| **マネージドサービス** | プラットフォームがあなたに代わって導入・更新・バックアップするサービス | それが動くマシンのrootは得られない — そしてそれこそが肝である |
| **Fortio** | Webインターフェースとレイテンシのヒストグラムを備えた負荷生成ツール | vSphereに対応物はない。インフラを計測する道具ではなく、サービスを計測する道具である |
| **p50 / p99** | 中央値と「最悪の割合」。99%のリクエストのレイテンシはこれ以下 | 平均レイテンシは誤解を招くが、この2つの数字はそうではない |

## 2つのkubeconfig：取り違えないこと

このラボでも、クラスターは再び2つあります。

| Kubeconfig | それは何か | そこで何をするか |
|---|---|---|
| `~/.kube/config` | Cozystackの管理クラスター、あなたのテナント | Redisを見る：アドレス、状態 |
| `~/lab.kubeconfig` | ラボ0で作った **あなたの** `lab` クラスター | アプリケーションをデプロイして計測する |

どちらもダッシュボードから取得します。テナント用は Secrets タブの `kubeconfig-tenant-workshopXX` Secret から、クラスター用はあなたの `lab` クラスターのアクセスセクションから。

⚠️ **各コマンドブロックの前に、どこ宛てかが書いてあります。** 何かおかしな動作をしたら、まず最初にやるべきは `echo $KUBECONFIG` です。

## ラボフォルダーの中身

必要なファイルはすべて揃っています — リポジトリと一緒に受け取っています。作ったり打ち直したりするものは何もありません。以下で `kubectl apply -f name.yaml` と書いてある箇所のファイルは、すべてここにあります。

```bash
# all commands in this lab run from the lab folder — switch into it
cd labs/07-redis
```

| ファイル | それは何か | いつ役に立つか |
|---|---|---|
| `app/` | 「入館証」サービスのソース、キャッシュ付きバージョン | ローカルでビルドする、`docker build` |
| `hr-legacy.yaml` | レガシーな名簿のスタブ：本物と同じく遅く応答する | あなたの `lab` クラスターに適用する |
| `passes-api.yaml` | キャッシュなしの「入館証」サービス — まずどれほどひどいかを計測する | 同じ場所に適用する |
| `cache-patch-broken.yaml` | キャッシュを有効にする **わざと不完全な** パッチ | エラーを見るために適用する |
| `cache-patch.yaml` | 動作するパッチ。完全なマニフェストではなくパッチなので、何が変わるかが正確に見える | 解説の後に適用する |
| `fortio.yaml` | 前後の計測のための負荷生成ツール | 同じ場所に適用する |
| `check.sh` | 2回目のリクエストが1回目より桁違いに速いことのチェック | ラボの最後に実行する |

## ステップ1. バージョンv2をビルドして自分のレジストリにpushする

📍 **場所：** bastion 上（bastion のターミナルで）。

`app/` フォルダーにはソースが入っています。前のラボのバージョンと2点で異なります。「遅い名簿」モードと、キャッシュの処理です。

<details>
<summary><b>詳しく見る：app/ の中身</b></summary>

**1つのイメージ、2つの役割。** `MODE` 変数が、プロセスが何として起動するかを決めます。

| `MODE` | それは何か | 何をするか |
|---|---|---|
| `hr` | レガシーな名簿のスタブ | `HR_DELAY`（デフォルト800ミリ秒）だけスリープし、従業員のデータを返す |
| `api` | 「入館証」サービス本体 | 名簿へ行き、`REDIS_ADDR` が設定されていれば — 先にキャッシュへ行く |

1つでなく2つのイメージにすると、バージョンの更新を忘れうる場所が2つになってしまいます。

**データを取りに行く仕組み。** キャッシュのロジック全体はおよそ20行です。

```go
if cache != nil {
    raw, found, err := cache.Get(key)
    switch {
    case err != nil:
        log.Printf("cache unavailable (%v), going to the directory", err)
    case found:
        if json.Unmarshal([]byte(raw), &emp) == nil {
            fromCache = true
        }
    }
}

if !fromCache {
    emp, err = fetchEmployee(hrClient, hrURL, id)
    ...
    cache.SetTTL(key, string(b), ttl)
}
```

最初の分岐に注目してください。**キャッシュが利用できなくても、アプリケーションはクラッシュしません。** ログに書き込んで名簿へ行きます — 遅いけれど正しく。これは飾りではなく、あらゆるキャッシュの必須の性質です。キャッシュは高速化するものであって、稼働し続けるための条件になってはいけません。キャッシュと一緒にサービスが落ちるなら、あなたが作ったのはキャッシュではなく、もう1つの障害点です。

ちなみに、この性質から、このラボの少し先で予測可能な障害が育ってきます。黙って動き続けるアプリケーションは、本番では心地よく、デバッグでは厄介です。

**キー。** `employee:42` — エンティティ名、コロン、識別子。ここのコロンはRedisの構文ではなく、広く採用されている習慣です。後で `employee:*` というパターンで検索でき、2つのアプリケーションが1つのRedisに同居するときに自分のキーと他人のキーを混同せずに済みます。

**寿命は書き込みと同じコマンドで設定します。**

```go
r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
```

`SET` してから `EXPIRE` という2つのコマンドではありません。2つのコマンドの間に接続が切れることがあり — そうするとキーは永遠にキャッシュに残ります。そういうキーは、後から何か月も追いかけられることになります。

**ここのRedisクライアントは自前で、50行です。** Redisのプロトコルはテキストベースで、`GET` と `SET` なら1つの関数に収まります。実際のプロジェクトなら既製のライブラリを使うでしょう — 接続プーリング、リトライ、sentinelを扱ってくれます。ここで自前にするのは、まさにビルドに外部依存を持たせないためです。前のラボがどう始まったか思い出してください。

**接続プールを拡大した専用のHTTPクライアント：**

```go
tr := http.DefaultTransport.(*http.Transport).Clone()
tr.MaxIdleConnsPerHost = 64
```

この行がないと、負荷がかかったとき時間の半分が名簿へのTCP接続の確立に費やされ、計測は名簿のレイテンシではなく我々自身のずさんさを映すことになります。計測の第一の鉄則：自分が思っているものを本当に計測しているか確かめること。

</details>

ビルドして自分のHarborにpushします。`build` は `Dockerfile` からイメージをビルドしてbastion上に残し、`push` はそれをレジストリに送ります。イメージ名は前のラボと同じですが、タグが異なります — `v2`：レジストリには両方のバージョンが保持され、古いものはどこへも消えません。

自分のアドレスに置き換えてください。

```bash
cd labs/07-redis

# build = "build the image from the Dockerfile".
#   --platform linux/amd64  which processor to build for; the cluster nodes are x86
#   -t <host>/<project>/<name>:<tag>  what to name the result; the registry host at the
#                           start of the name is where push will send it later
#   app/                    the folder with the Dockerfile and sources to build from
docker build --platform linux/amd64 -t harbor.workshop03.example.org/passes/passes-api:v2 app/

# push = "send the image to the registry". The address is taken from the first part of the
# image name, the credentials — from the docker login you did in the previous lab.
docker push harbor.workshop03.example.org/passes/passes-api:v2
```

⚠️ **Apple Silicon の Mac や ARM の VM を使っている場合は `--platform linux/amd64` が必須です。** これがないとイメージは ARM 向けにビルドされ、エラーなく push され、クラスターでは `CrashLoopBackOff` になり、ログに `exec format error` が出ます。

## ステップ2. 名簿とサービスをデプロイする

📍 **場所：** bastion 上、`lab` クラスター。

どちらのマニフェストにも、レジストリのアドレスの代わりに `HARBOR-HOST` というプレースホルダーが入っています。`sed` がそれを置き換え、ファイルをその場で編集します。次に `apply` がファイルに記述された内容をクラスターに渡し、`rollout status` がコピーの起動を待ちます。

```bash
# KUBECONFIG tells kubectl which access file to use. We switch to
# your `lab` cluster; it holds until you close the terminal window.
export KUBECONFIG=~/lab.kubeconfig

# sed -i = "edit the file in place".
#   's|old|new|g'  replace every occurrence; the | separator is used instead of / because
#                  the address contains slashes
#   The macOS version of sed requires a mandatory argument after -i; empty quotes
#   mean "don't make a backup". On Linux that argument must not be there.
#   There are two files at the end of the line: sed accepts several at once and edits them in one pass.

# Linux
sed -i    's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml

# apply = "bring the cluster to what's described in the files". The -f flag is repeated for each file.
kubectl apply -f hr-legacy.yaml -f passes-api.yaml

# rollout status waits for the copies to be ready and exits on its own; if they don't, it returns an error
kubectl rollout status deployment/hr-legacy
kubectl rollout status deployment/passes-api
```

⚠️ どちらのマニフェストも `harbor` Secret を参照しています — 前のラボの `imagePullSecret` そのものです。作っていないと、Pod は `ImagePullBackOff` になります。Secret を作るには：

```bash
# create secret docker-registry = "create a Secret with registry credentials";
# such a Secret can be read by the kubelet itself when it pulls the image onto a node.
#   harbor             the Secret's name in the cluster — both manifests reference it
#   --docker-server    which registry these credentials are for
#   --docker-username  who logs in; --docker-password — the Harbor administrator password
kubectl create secret docker-registry harbor \
  --docker-server=harbor.workshop03.example.org \
  --docker-username=admin --docker-password='YOUR-PASSWORD'
```

つながりが機能しているか確かめましょう。サービスはクラスターの内側からしか見えないので、リクエストもそこから出します。`curl` を持つ使い捨ての Pod を起動し、それが `passes-api` サービスに問い合わせ、答えを表示して消えます。

```bash
# run probe = "run a Pod named probe".
#   --rm              delete the Pod as soon as it's done
#   -i                show us its output
#   --restart=Never   don't restart: this is a one-time command, not a permanent service
#   --image=...       which image to use; the version is pinned so nothing new arrives
#   --quiet           don't print service lines, only the answer
#   --                everything after these two dashes is the command inside the Pod
# An address of the form <service>.<namespace>.svc.cluster.local is the service's internal name;
# by it the Pods find each other without knowing addresses.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**見えるはずのもの：**

```json
{"cache":"off","cached":false,"dept":"Logistics","id":"42","name":"Popova E. K.",
 "pod":"passes-api-6f8b9c7d5-x2ktm","took_ms":803,"ttl_s":60}
```

肝心のフィールド：`cache: off` — キャッシュなし、`took_ms: 803` — ほら、あなたの800ミリ秒です。これがまさに、これから減らそうとしている数字です。

## ステップ3. 今どれほどひどいかを計測する

📍 **場所：** bastion 上、`lab` クラスター。

リクエスト1回では計測になりません。現実に近い負荷と、レイテンシの分布が必要です。

生成ツールをデプロイします。ふつうのアプリケーションと同じように起動し、サービスの隣でクラスター内に居続けます — そうすれば計測があなたのインターネットやトンネルに左右されません。

```bash
# the file has two objects: the generator itself and a service for it
kubectl apply -f fortio.yaml
kubectl rollout status deployment/fortio
```

さあ負荷をかけます。`kubectl exec` コマンドはすでに動いている Pod の中で何かを実行します — ここでは生成ツールの中で、生成ツール自身を砲撃モードで起動します。

```bash
# exec deploy/fortio = run a command inside this application's Pod
#   --            the boundary: kubectl on the left, on the right the command that goes into the Pod
#   fortio load   bombardment mode: send requests and measure the response time
#   -qps 20       twenty requests per second — we set a pace, not "push as hard as we can"
#   -t 20s        how long the measurement lasts
#   -c 16         sixteen parallel connections. The number isn't arbitrary:
#                 the directory answers in 800 ms, so one connection manages
#                 a little more than one request per second. To hold the set 20 per
#                 second, you need no fewer than sixteen connections — otherwise Fortio
#                 will hit the latency wall and not deliver the requested pace.
#   the last argument is the address we're bombarding
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**見えるはずのもの** — 出力の末尾に、ヒストグラムとパーセンタイルの行：

```
# target 50% 0.801
# target 90% 0.806
# target 99% 0.812
Code 200 : 400 (100.0 %)
```

**これらの数字を書き留めてください。** 10分後に比較のために必要になります。そして記憶というものは、「まあ800ミリ秒くらいだった」が「まあ0.5秒くらいだった」に化けるようにできています。

### 同じことをマウスで

マウスで — これは Cozystack のダッシュボードではありません。あちらは管理クラスターを扱い、テナントのカタログエントリを表示しますが、あなたの `lab` クラスターの中は覗きません。生成ツール自身が独自のWebインターフェースを持っていて、トンネル経由でそこへ到達する必要があります。

```bash
# port-forward svc/fortio = a tunnel from the bastion to the generator's service in the cluster
#   8081:8080 — the left number is the port on your bastion, the right one the service port in the cluster
# Port 8081 is used because 8080 might be taken by something else on your machine.
# Don't close the window: the tunnel lives as long as the command runs. To stop it — Ctrl+C.
kubectl port-forward svc/fortio 8081:8080
```

<http://localhost:8081/fortio> を開きます。次を入力します。

| フィールド | 値 |
|---|---|
| URL | `http://passes-api.default.svc.cluster.local/employee?id=42` |
| QPS | `20` |
| Duration | `20s` |
| Connections | `16` |

**Start** をクリックします。下部にレイテンシのヒストグラムが描かれます。数字より分かりやすいです：すべてのリクエストが800ミリ秒あたりの1本の細い帯に集まっているのが見えます — つまり、遅いのは「時々」ではなく、常に、同じだけ、ということです。


<details>
<summary><b>なぜ平均レイテンシではなく p50 と p99 なのか</b></summary>

平均レイテンシは、運用において最も欺瞞的な指標です。

想像してください：90件のリクエストが10ミリ秒、10件が2000ミリ秒。平均は209ミリ秒で、レポート上はすべて申し分なく見えます。しかし実際には、10人に1人のユーザーが2秒待たされて去っていったのです。

**p50（中央値）** — 半分のリクエストがこの数字より速く、半分が遅い。「ふつうのユーザーがどれくらい待つか」という問いに答えます。

**p99** — 99%のリクエストがこの数字より速い。「どこまでひどくなるか」という問いに答えます。チェックポイントの警備員が不満を言うかどうかを決めるのは、この p99 です。人が不満を言うのは平均についてではなく、あの一度だけ待たされた時についてです。

我々の計測では p50 と p99 がほぼ一致しました — 801 と 812 ミリ秒。これは遅さがランダムではなく系統的だという証拠です：ちょうどいつも遅い。これはキャッシュで治ります。もし p50 が10ミリ秒で p99 が2000ミリ秒なら、原因は別で、キャッシュは効きません。

</details>

## ステップ4. Redis を作る

📍 **場所：** ブラウザで、Cozystack のダッシュボード。Redis は Harbor と同じく、テナントで共有されるリソースです。

テナント → **Create application** → `Redis`。

| フィールド | 値 | なぜそうするか |
|---|---|---|
| Name | `cache` | サービス名に入るので、短いほうが扱いやすい |
| Replicas | `2` | リーダーのコピー1つとフォロワー1つ：それが何をもたらすか見てみる |
| Size | `1Gi` | 従業員の名簿はメモリに余裕をもって収まる |
| Storage class | `replicated` | |
| Resources preset | 提案されたものをそのまま | |
| Version | `v8` | |
| Auth enabled | **オン**（デフォルト） | プラットフォームがパスワードを自ら生成する |
| External | **オフ** | このキャッシュを外部に露出する理由はない |

準備できるまで3〜5分の待ち時間を見込んでください。

⚠️ **この Redis は、Harbor の作成フォームで見たかもしれない Redis とは何の関係もありません。** あちらはレジストリ自身の内部キャッシュです。こちらはあなた自身のもの、あなたのアプリケーションのためのものです。

<details>
<summary><b>マネージド Redis は VM に入れた Redis とどう違うか</b></summary>

Redis を仮想マシンに入れるのは30分の仕事です：`apt install redis`、`bind` と `requirepass` を調整、起動時に有効化。だからこそマネージドサービスは大げさに思えます。違いは導入にではなく、その後に起こることにあります。

**レプリケーション。** `replicas: 2` を設定した — そして異なるノード上に2つのデータのコピーと、それらを見張る3つの sentinel を得ました。リーダーのコピーがあるノードが死ぬと、sentinel が選挙を行い、2つ目のコピーをリーダーにします。アプリケーションは数秒の停止でこれを生き延びます。同じものを手で組み立てるのは1日仕事で、さらにもう1日、それが本当にフェイルオーバーするか — 単に設定できているように見えるだけでなく — を検証するのにかかります。

**更新。** Redis の脆弱性はまれではありません。VM では更新は `apt upgrade`、再起動、そしてメジャーバージョンの変更に設定が耐えることを祈ることを意味します。ここではイメージの更新がプラットフォームの更新と一緒に届き、コピーの再起動順序はサービスが消えないように調整されています。

**可観測性。** メトリクスはすでに収集されています：各コピーの隣で exporter が動いていて、グラフはあなたの手間なしにそこにあります。VM ではそれはもう1つのパッケージ、もう1つの設定、そしてもう1つの忘れられがちなものです。

**何を諦めるか。** 正直に言うと：Redis の動くマシンの root です。SSH で入れず、設定を手で編集できず、自分のスクリプトをその隣に置くこともできません。アプリケーションのパラメータとして表に出ていないものは、あなたには手が届きません — そして、決してすべてが表に出ているわけではありません。標準外の `maxmemory-policy` や Redis モジュールが必要なら、マネージドサービスはそれを与えてくれず、自分で VM に入れることになります。これは些細なことではなく、本物の制限です。

</details>

## ステップ5. Redis のアドレスを見つけ、疎通を確認する

📍 **場所：** bastion 上、**管理** クラスター。

Redis は管理クラスター上のあなたのテナントに、アプリケーションはあなたの `lab` クラスターに居ます。これは2つの異なるクラスターであり、まずやるべきは、2つ目が1つ目に到達できることを確かめることです。

どんなサービスが現れたか見てみましょう。

```bash
# --kubeconfig sets the access file right in the command — just once, without touching KUBECONFIG.
# This way two commands in a row can be addressed to different clusters without getting confused.
#   -n tenant-workshopXX  the namespace of your tenant
#   get svc               "show the services" — permanent addresses backed by Pods
#   | grep redis          keep only the lines with the word redis in the output
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX get svc | grep redis
```

**見えるはずのもの** — 意味ありげな接頭辞を持ついくつかのサービス：

| 名前 | その裏にあるもの |
|---|---|
| `rfrm-redis-cache` | リーダーのコピー（master） — ここに書き込み、ここから読む |
| `rfrs-redis-cache` | フォロワーのコピー（replica） — 読み取り専用 |
| `rfs-redis-cache` | sentinel — 見張って役割を切り替えるサービス |

⚠️ **名前の中の余分な `redis-` はどこから来るか。** プラットフォームはアプリケーション名に、サービスの種類を表す接頭辞を付けます：Redis 型の `cache` アプリケーションは、内部的には `redis-cache` と呼ばれます。だから `rfrm-cache` ではなく `rfrm-redis-cache` です。名前を推測しないこと — 上のコマンドの出力を見ること、それが真実の源です。

必要なのは `rfrm-redis-cache` です：キャッシュは書き込みも読み取りもし、書き込めるのはリーダーのコピーだけだからです。

あなたのクラスターから見える完全な名前は、次のように組み立てられます。

```
rfrm-redis-cache.tenant-workshopXX.svc.cozy.local
```

パスワードを取得します。📍 **場所：** ダッシュボードの `cache` アプリケーション、secrets タブ。`redis-cache-auth` Secret の `password` キーが必要です。

さて — 疎通確認です。📍 **場所：** bastion 上、**`lab`** クラスター。

あなたのクラスターで、Redis クライアントを持つ使い捨ての Pod を起動し、Redis に `ping` という語をかけるよう頼みます。答えが返ってくれば、テナントのキャッシュが `lab` クラスターから見えているということです — そして、それこそが今この瞬間に確かめている唯一のことです。

⚠️ **パスワードは `-a` フラグではなく `REDISCLI_AUTH` 変数で渡します。** コマンドの引数に入るものは、ノードのプロセス一覧に見え、Pod の記述に残ります — それはあなたの namespace にアクセスできる者なら誰でも読めます。`redis-cli` 自身がこれについて警告します。原因を取り除く代わりに警告を黙らせるのは悪い習慣です。

```bash
export KUBECONFIG=~/lab.kubeconfig

# run redis-probe = a one-off Pod with the redis-cli client:
#   --rm --restart=Never  it did its job and deleted itself, no need to restart
#   -i --quiet            show us the output and don't print service lines
#   --env=REDISCLI_AUTH   the password goes into the Pod as an environment variable, not an argument
#   --                    to the right of these dashes is the command that goes into the Pod
#   redis-cli -h <name>   which server to connect to; the name is that same full one
#   ping                  a short "are you alive"; the answer to it is PONG
kubectl run redis-probe --rm -i --restart=Never --image=redis:7-alpine --quiet \
  --env=REDISCLI_AUTH='YOUR-PASSWORD' -- \
  redis-cli -h rfrm-redis-cache.tenant-workshopXX.svc.cozy.local ping
```

**見えるはずのもの：**

```
PONG
```

⚠️ **`PONG` の代わりに名前解決のエラーが出た場合** — 管理クラスターの内部名があなたのクラスターから見えていない、ということです。これは IP で宛てることで解決します。

```bash
# -o jsonpath='{.spec.clusterIP}' — print one field of the object: the internal address
# the platform assigned to this service. {"\n"} adds a line break.
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX get svc rfrm-redis-cache \
  -o jsonpath='{.spec.clusterIP}{"\n"}'
```

これ以降、あらゆる箇所で名前の代わりに得られたアドレスに置き換えてください。同じように動きます。唯一の難点は、Redis が作り直されるとアドレスが変わることです。名前は変わりません。アドレスでも応答しない場合 — ワークショップのチャットに書いてください。これはあなたのミスではなく、テスト環境の構成の問題です。

## ステップ6. キャッシュを有効にする

📍 **場所：** bastion 上、`lab` クラスター。

アプリケーションを、まるごとのマニフェストではなくパッチで変更します — そうすれば何が変わるかが正確に見えます。まずあなたの Redis のアドレスをパッチに埋め込み、次にパッチをクラスターに渡します：`kubectl patch` は、すでに存在するオブジェクトをまるごと置き換えるのではなく、変更を追記します。

```bash
# the same address substitution as before, only the placeholder is different — REDIS-ADDR

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml

# patch deployment passes-api = "fix up this object with what's in the file"
#   --patch-file  where to take the changes from
# Changing environment variables means new Pods: the old ones will be replaced.
kubectl patch deployment passes-api --patch-file cache-patch-broken.yaml

# wait until the new copies become ready — otherwise we'll measure the old ones still
kubectl rollout status deployment/passes-api
```

もう一度計測します — キャッシュを有効にする前に計測したのと同じコマンドで。砲撃の条件は最後のフラグまで一致していなければなりません。さもないと比較のしようがありません。

```bash
# the same twenty requests per second, the same twenty seconds, the same sixteen connections
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

> **読み進める前に、立ち止まって考えてください。**
>
> 数字は変わっていません：同じ800ミリ秒。それでいて Pod は1つもクラッシュせず、応答にエラーはなく、すべてのリクエストが `200` を返しました。Redis は作成済み、アドレスも正しい — たった今そこから `PONG` をもらったばかりです。
>
> どこを見ればいいでしょう？

<details>
<summary><b>答えと、このエラーより広い教訓</b></summary>

まずアプリケーション自身が何を答えるか見ましょう：応答には、キャッシュが有効か、答えがそこから来たかを示すフィールドがあります。

```bash
# the same one-off Pod with curl as before: we ask the service from inside the cluster
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

```json
{"cache":"redis","cached":false,"took_ms":802, ...}
```

`cache: redis` — キャッシュは有効。`cached: false` — それでいて答えはそこから来ていない。しかも、何度繰り返しても **常に** false です。

さてログです。アプリケーションは、できなかったことをそこに書きます — そして今、真実が見える唯一の場所がそこです。

```bash
# logs = "show what the application wrote to its output".
#   -l app=passes-api  across all copies with this label at once, not one named copy
#   --tail=20          the last twenty lines of each copy, not the whole log
kubectl logs -l app=passes-api --tail=20
```

```
cache unavailable (redis: NOAUTH Authentication required.), going to the directory
cache unavailable (redis: NOAUTH Authentication required.), going to the directory
```

そこに答えがあります。Redis のアドレスは指定しましたが、パスワードは指定しませんでした。Redis は認証を要求します — 作成時に自分で `Auth enabled` をオンにしたのであり、それは正しい設定です。アプリケーションは正直に試み、拒否され、それをログに書き、名簿へ行きました。

**なぜこれが故障のように見えなかったか。** 故障がなかったからです。アプリケーションはキャッシュが利用できなくても生き延びるよう設計されています：キャッシュは高速化するものであって、稼働し続けるための条件になってはいけません。本番ではこれがあなたを救います — Redis が落ちてもサービスを道連れにしません。デバッグでは、まさにその性質が問題を隠します：すべて緑、エラーなし、でも一向に速くない。

**このミスより広い教訓。** 仕事の邪魔をしない障害は、最も高くつく種類の障害です。それは何の警報も上げず、本番で何か月も生き続けます。だから実践的なルール：**あらゆる高速化装置には、それが働いていることの観測可能なしるしがなければならない。** 我々にとってそれは応答の `cached` フィールドです。もしそれがなかったら、あなたは今この瞬間、当てずっぽうをしていたでしょう。

実際のシステムでは、この場所に「キャッシュヒット率」のメトリクスと、それがゼロに落ちた場合のアラートがあります。

</details>

## ステップ7. パスワードを入れて、もう一度計測する

📍 **場所：** bastion 上、`lab` クラスター。

Redis のパスワードは管理クラスターに住んでいて、アプリケーションはそれをあなたのクラスターで必要とします。それを移します — シェル変数を通して、パスワードがコマンド履歴に残らないように。

```bash
# read puts what's typed on the keyboard into the REDIS_PASS variable:
#   -s  don't show what's typed on the screen
#   -r  don't treat a backslash as a special character
# Nothing will appear on screen after this line: paste the password from the dashboard and Enter.
read -rs REDIS_PASS

# create secret generic = an ordinary Secret, a set of key-value pairs.
#   redis-password              the Secret's name in the cluster
#   --from-literal=password=... create a password key in it with this value;
#                               it's the "Secret name + key" pair the patch will reference
kubectl create secret generic redis-password --from-literal=password="$REDIS_PASS"

# unset erases the variable so the password doesn't reach the next commands in this window
unset REDIS_PASS
```

完全なパッチを適用します。同じ Redis のアドレスに加えて、たった今作った Secret への参照と、キャッシュエントリの寿命が入っています。解説はコマンドのすぐ後のスポイラーにあります。

```bash
# the same address substitution, now in the working patch file

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml

# fix up the existing Deployment with the file's contents and wait for the new copies
kubectl patch deployment passes-api --patch-file cache-patch.yaml
kubectl rollout status deployment/passes-api
```

<details>
<summary><b>詳しく見る：cache-patch.yaml の中身</b></summary>

```yaml
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: REDIS_ADDR
              value: "rfrm-redis-cache.tenant-workshopXX.svc.cozy.local:6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-password
                  key: password
            - name: CACHE_TTL
              value: "60"
```

**なぜ完全なマニフェストではなくパッチか。** パッチは「これを変える」であって、「状態はこうあるべき」ではありません。ファイルの中で、200行の中から目で3つの新しい行を探すのではなく、何が変わるかを正確に見られます。

**なぜこれで他の変数が消えないか。** Kubernetes のリストはキーでマージできます。`env` の場合キーは `name` フィールドです：パッチの3つのエントリはすでにあるものに追加され、`REDIS_ADDR` のエントリは壊れたパッチが残した同名のものを置き換えます。コンテナのリストも同じく name でマージされます — だからこそ `- name: api` が必須です。これがないと Kubernetes はあなたがどのコンテナを編集しているのか分かりません。

**なぜパスワードをテキストではなく `secretKeyRef` 経由にするか。** 値は Pod が起動する瞬間に `redis-password` Secret から届きます。マニフェスト自体にはパスワードがありません — そしてそれが大事です。マニフェストは Git に入り、そこに永遠に残るからです。Secret は Git に入りません。

正直に言うと：クラスター内の Secret は、場所が違うだけで、依然として平文のまま置かれています。この namespace で Secret を読める者なら誰でもパスワードを見られます。本当の解決策は外部のシークレットストアで、それは別のラボです。

**`CACHE_TTL: 60`。** 60秒は妥協点です。以下 — 次のスポイラーを読んでください。

</details>

負荷をかける前に、1件ずつ確かめましょう。まだ問い合わせられたことのない識別子に対する、同一の2つの連続リクエスト：1回目は必ず遅く、2回目は速いはずです。

```bash
# the same one-off Pod with curl, but an sh shell is launched inside it:
#   sh -c '...'  run several commands passed as a single string
#   ; echo       insert a line break between the answers so they don't run together
# id=777 is used because this employee hasn't been asked for yet: it's definitely not in the cache.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  sh -c 'curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"; echo;
         curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"'
```

**見えるはずのもの** — 2つの答え、そしてそれらは異なります：

```json
{"cached":false,"took_ms":804, ...}
{"cached":true,"took_ms":1, ...}
```

1回目のリクエストはミス：キャッシュは空で、名簿へ行かねばならず、804ミリ秒。2回目はヒット：答えはすでにそこにあり、1ミリ秒。

さて負荷をかけての計測、同じフラグの同じコマンドで、3回目：

```bash
# we change nothing in the bombardment conditions: only what's inside the service changes
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**見えるはずのもの：**

```
# target 50% 0.0012
# target 90% 0.0021
# target 99% 0.0043
Code 200 : 400 (100.0 %)
```

## ステップ8. 得られた効果を集計する

📍 **場所：** 紙切れの上で。

3つの数字を1つの表にまとめます。あなたの数字は異なります — テスト環境、ネットワーク、ノード上の隣人のせいで：

| | p50 | p99 | 警備員にとって何を意味するか |
|---|---|---|---|
| キャッシュなし | 801 ms | 812 ms | 12行のリストが開くのに約9.6秒 |
| キャッシュ有効、パスワードなし | 802 ms | 815 ms | 何も変わらない |
| キャッシュ動作 | 1.2 ms | 4.3 ms | 同じリスト — 約0.05秒 |

差は **数百倍** で、これは言葉のあやではなく、計測した2つの数字の商です。

我々が **やらなかった** ことに注目してください。人事システムは書き直していません。ノードを追加していません。「入館証」サービスのロジックを1行も変えていません — ただ、同じことを二度問い合わせないよう教えただけです。変更は3つの環境変数に収まりました。

<details>
<summary><b>キャッシュが効かないとき、そしてそれを事前に見抜く方法</b></summary>

キャッシュは万能の高速化ではありません。1つの条件のもとでのみ効きます：**同じ問いが何度も問われる** こと。3つのケースで自分を試してみてください。

**すべてのリクエストが一意。** もし来客リストが毎回新しい従業員の情報を要求したら、ヒットは1つも起きず、すべてのリクエストに Redis への往復が上乗せされるだけです。遅くなります。次のように確かめられます — 異なる識別子で2つの短いシリーズを走らせ、それぞれの最初のリクエストを見ます：

```bash
# two bombardments in a row over different employees, ten seconds each.
# At the start of each series the cache is empty for that key — and the first request goes to the directory.
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=1"
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=2"
```

各シリーズの最初のリクエストはミスです。めったに繰り返されないキーの大きな集合では、キャッシュはオーバーヘッドに堕します。

**データが TTL より頻繁に変わる。** もし従業員の情報が10秒ごとに変わるのに TTL が60に設定されていたら、警備員は最大1分間、古いデータを見ることになります。キャッシュは常に新鮮さを速さと引き換えにします。そしてどれだけの新鮮さを諦められるかを決めるのは、技術的な判断ではなく、顧客への問いです。

**いつも遅いのではなく、時々遅い。** 最初の計測での p50 と p99 の違いを覚えていますか？ もし p50 が小さく p99 が巨大なら、遅いのはデータソースではなく、断続的な何か：ガベージコレクション、ノード上の隣人、データベースのロックです。キャッシュはこれを覆い隠しますが治しはしません。そしていつか、まさに同じものを、ただし1年後に、しかもキャッシュを上に載せた状態で、解きほぐすことになります。

</details>

<details>
<summary><b>TTL はどう選ぶか</b></summary>

TTL はキャッシュの唯一の本当のパラメータであり、それは技術的な根拠では選ばれません。

問いはこうです：**あなたはどれだけの間、古いデータを見せて構わないか？**

従業員の名簿の場合：姓が変わるのは数年に一度、部署は年に一度。チェックポイントで昨日の部署が出ても誰も困りません。TTL は1時間でも、1日でも同じくらい良かったでしょう。

我々は60秒に設定しました。ラボを観測可能にするためです：1分待ってリクエストを繰り返すと — 再び `cached: false` が見えます。エントリが期限切れになって名簿へ行ったからです。TTL が1日だったら、それを信じるしかなかったでしょう。

エッジケース：

| TTL | 何が得られるか |
|---|---|
| 小さすぎる | ヒットがわずか、キャッシュがほとんど働かず、ソースへの負荷が残る |
| 大きすぎる | 速いが、ユーザーは昨日のデータを見て、別のことで不満を言う |
| まったく設定しない | キーが積み上がり、メモリが尽き、Redis が手当たり次第に追い出し始める |

最後の行が最も厄介です。TTL のないキャッシュは、時間が経つと、誰もバックアップしないデータベースに化けます。

</details>

## 検証

📍 **場所：** bastion 上、`kubectl` で作業したのと同じターミナルウィンドウで。

スクリプトは2つのクラスターに同時にアクセスし、それらを環境変数から取ります。最初の2つは必須、3つ目はテナントの kubeconfig へのパスです。

```bash
cd labs/07-redis

# which cluster to check the application in — your `lab`
export KUBECONFIG=~/lab.kubeconfig
# your tenant number: from it the script assembles the namespace name tenant-workshop03
export COZY_TENANT=workshop03
# where the access to the management cluster lives — there the script looks at Redis itself.
# You can leave it unset: then the script looks for ~/.kube/config, and not finding it — skips
# the checks on the management cluster and says so.
export COZY_KUBECONFIG=~/.kube/config

./check.sh
```

⚠️ **Windows ではスクリプトは PowerShell からではなく WSL から実行します** — その導入方法はラボ0の冒頭に書かれています。WSL がなくてもラボはこなせますが、成果物のレポートは出ません。

スクリプトはどのマニフェストの言い分も鵜呑みにしません。ランダムな識別子に対して自分で2回連続でリクエストを出し、観察します：1回目はミスで数百ミリ秒かかるはず、2回目はヒットで1桁ミリ秒。その差を数字としてレポートに記録します。ついでに、遅い名簿が本当に遅いことを確かめます：それなしでは比較は何の意味もないからです。

## 後片付け

以降のラボですべて必要になります — 今は何も削除しません。

すべてのラボが終わったら：

```bash
# delete -f = remove from the cluster exactly the objects described in the files
kubectl delete -f passes-api.yaml -f hr-legacy.yaml -f fortio.yaml
# the Secret was created by a command, not a file — we delete it by name
kubectl delete secret redis-password
```

Redis 自体は、ふつうのアプリケーションと同じくダッシュボードから削除します。

キャッシュを削除するのは安価でほぼ安全な操作であり、それはキャッシュの際立った性質です：**キャッシュは、どこにも他に存在しないデータを保持しない。** その中のすべては、ソースへの往復で取り戻せます。Redis を失うことは、それが再び満たされるまでの数分間、速さを失うことを意味します — けれど情報を失うことではありません。データベースではそうはいきません。データベースのラボで、あなたはここに立ち返ることになります。

## 今できるようになったこと

- マネージド Redis をプロビジョニングし、あなたが設定しなかったレプリケーションが何をもたらすかを説明する
- 変更の前後のレイテンシを、語るのではなく計測する
- p50 と p99 を読み、なぜ平均レイテンシが欺くのかを理解する
- 顧客がどれだけ古さを許容するかに基づいて TTL を選ぶ
- 仕事の邪魔をしない障害 — 最も高くつく種類の障害 — を見つける

## そして vSphere ではこうなる

vSphere にはこのタスクの対応物がなく、それははっきり言っておく価値があります。キャッシュはインフラのオブジェクトではなく、アプリケーションのアーキテクチャの一部です。ハイパーバイザーは人事システムの答えをキャッシュできませんし、できるべきでもありません。

仮想マシンの世界であなたがやること：Redis 用の VM の申請、導入、`requirepass` の設定、自動起動の設定、それから — もし手が回れば — レプリカ用の2台目の VM、sentinel、フェイルオーバーの検証。数日の仕事で、そのうちキャッシュそのものは30分、残りはすべて足場です。だからこそ、どんな管理者にもおなじみの習慣が生まれます：「とりあえずレプリカなしでいこう、後で足せばいい」。後で、彼らはそれを足しません。

違いは、ここでは Redis の導入が速いということではありません。違いは、レプリカ、フェイルオーバー、メトリクス、更新がデフォルトで付いてきて、「とりあえずレプリカなし」が選択肢としてそもそも上がらないということです。

**正直に、vSphere のほうが便利なところ。** 3つあります。

**完全な制御。** 自分の VM なら、どんなバージョンの Redis も、どんなモジュールも、どんな `maxmemory-policy` も、そして自前の監視スクリプトも隣に入れられます。ここではアプリケーションのパラメータとして表に出ているものにしかアクセスできません — そして、決してすべてが表に出ているわけではありません。

**診断。** VM 上の Redis が妙な振る舞いをしたら、SSH で入って `redis-cli INFO`、`SLOWLOG`、システムのカウンタを見ます。ここには SSH がなく、同じ情報にたどり着くには `kubectl exec` とメトリクスを経由するしかありません — より遅く、より粗い解像度で。

**隣人の予測可能性。** Redis 用の VM は、vCenter で見える保証されたコアとメモリを意味します。マネージドサービスは、他人のワークロードの隣で共有ノードに居ます。リミットがそれを守りますが、「なぜ今日は2ミリ秒遅いのか」を突き止めるのは、専用マシンでよりも時間がかかります。
