# ラボ 4 · 新バージョンのロールアウトとロールバック

| | |
|---|---|
| **所要時間** | 30 分 |
| **証明できること** | メンテナンスウィンドウなしで、ライブトラフィックのもとバージョンを変更し、元に戻せること |
| **必要なもの** | ラボ 0 で用意したクラスター、ラボ 1 の `rickroll`、ラボ 3 の Fortio、ターミナルウィンドウ 3 枚、ブラウザ |

## なぜこれが重要か

「Pass」サービスをロールアウトするのは一度きりですが、更新は何十回も行うことになります。いつものやり方では、更新のたびにウィンドウを調整し、土曜の夜を使い、始める前にスナップショットを取り、誰かが張り付いて見守ることになります。変更のコストがこれほど高いと、変更は溜まっていきます。10 回の小さなロールアウトの代わりに 1 回の大きなロールアウトになり、大きなものほど壊れやすいのです。

そのコストがどれくらいかを、ここではモルモット、つまり練習用の `rickroll` で確かめます。「Pass」ではありません。アプリケーションのバージョンを**負荷のただ中で**切り替えます。静かな時間帯ではなく、毎分数千のリクエストが飛び交う最中に切り替え、エラーカウンターを見守ります。それからロールバックします。これも負荷のもとで行います。

## ちょっとした用語集

| 用語 | 何か | …に似ているが |
|---|---|---|
| **RollingUpdate** | コピーを一斉にではなく、一つずつ入れ替える方式 | **VM を 1 台ずつ手作業で更新するのに似ている**が、クラスターが自分でやり、新しいコピーが立ち上がらなければ止まる |
| **Revision** | アプリケーションの記述を保存したスナップショット | **VM のスナップショットに似ている**が、記述だけを保持する。中にデータは入っていない |
| **maxSurge** | ロールアウト中に、要求した数を超えて立ち上げてよいコピーの数 | 直接の対応物はない。`replicas` に対する割合で数え、切り上げる |
| **maxUnavailable** | 置き換えを待たずに停止してよいコピーの数 | **同時に停止する VM の台数に似ている**が、切り捨てるので、コピーが 3 つならゼロになる |
| **readinessProbe** | 「トラフィックを受ける準備ができた」かのチェック | **ロードバランサープールのヘルスチェックに似ている**が、単にメンバーをバランシングから外すだけでなく、ロールアウトそのものを押しとどめる |
| **ReplicaSet** | 記述の一つのバージョンを担う、同一のコピーの集合 | **テンプレートから作った同一 VM のプールに似ている**が、バージョンごとに独自の集合を持ち、前のものはコピー数ゼロで隣に残り続ける |
| **EndpointSlice** | トラフィックを受ける準備ができたコピーのアドレス一覧 | **ロードバランサープールのメンバー一覧に似ている**が、管理者が手で書くのではなく、クラスターがラベルで維持する |
| **JSON Patch** | オブジェクト内のパスを指定して、単一のフィールドをピンポイントで書き換えること | 直接の対応物はない。パスはリスト内の要素の名前ではなく、その**インデックス**を指す |

## ラボフォルダーの中身

ファイルはすべてすでに揃っています。リポジトリと一緒に受け取っています。作ったり打ち直したりするものは何もありません。以下で `kubectl apply -f name.yaml` と出てきたら、そのファイルはここから取られます。

```bash
# From here on, all commands are run from this folder: paths in `kubectl apply -f` are counted from it.
cd labs/04-rollout
```

| ファイル | 何か | いつ役に立つか |
|---|---|---|
| `rickroll-page-v2.yaml` | ページの第 2 バージョン。負荷のもとでロールアウトする対象 | `lab` クラスターに適用する |
| `check.sh` | ロールアウトが 1 件もリクエストを落とさずに通ったかのチェック | ラボの最後に実行する |
| — | 隣のラボから借りてくる負荷生成器: `../03-scale/fortio.yaml` | |

## ステップ 1. 地ならし

📍 **場所:** bastion 上（bastion のターミナルで）。

ロールアウトの前に 2 つやっておくことがあり、どちらも見た目だけのものではありません。

**オートスケーリングを切ります**。これも `replicas` フィールドを制御するからです。誰かが同時にコピー数を変えている横でロールアウトを見守るのは、何が起きたのか分からなくなる確実な方法です。1 つのフィールドには 1 つの仕組み。

**コピーを 3 つにします**。そうすれば入れ替えが一つずつ見えます。ここでいうコピーとは Pod です。クラスター内の最小の実行単位で、アプリケーションのコンテナとその環境を合わせたもの、単一の VM にもっとも近い対応物です。コピーが 1 つでもロールアウトはダウンタイムなしに通りますが、見えるのは「Pod が 1 つあった、今は別の 1 つがある」だけで、クラスターがどの順番でコピーを入れ替えるかは見えません。

```bash
# KUBECONFIG — the file with the cluster's address and the credentials to log into it. While the
# variable is set, every kubectl command goes to the `lab` cluster, not the one it was issued from.
export KUBECONFIG=~/lab.kubeconfig

# hpa — the autoscaler set up in the scaling lab. We delete it
# so the number of copies changes only on our command.
#   --ignore-not-found  don't treat it as an error if it's no longer in the cluster
kubectl delete hpa rickroll --ignore-not-found

# scale = "keep this many copies". The number goes into the application's description,
# and the cluster then brings up the missing ones itself.
kubectl scale deployment rickroll --replicas=3

# rollout status = "wait until the requested becomes actual". The command keeps the window
# busy until all three copies are ready, and only then returns the prompt.
kubectl rollout status deployment/rickroll
```

Fortio 負荷生成器が所定の場所にあることを確認します:

```bash
# get = "show what's there". The reply `Error from server (NotFound)` means it isn't there.
kubectl get deployment fortio
```

無ければ、隣のフォルダーから立ち上げます: `kubectl apply -f ../03-scale/fortio.yaml`。

## ステップ 2. 第 2 バージョンをクラスターに入れる

📍 **場所:** bastion 上（bastion のターミナルで）。

フォルダーには `rickroll-page-v2.yaml` があります。ConfigMap という種類のオブジェクトの記述です。ConfigMap はテキストファイルをアプリケーションとは別にクラスター内へ保持し、あとでクラスターがそのファイルをコンテナの中に置きます。ここでは nginx が配信するページを保持しています。

<details>
<summary><b>もっと詳しく: rickroll-page-v2.yaml の中身</b></summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rickroll-page-v2
data:
  index.html: |
    ...
    <div class="tag">VERSION 2</div>
    <h1>We're No Strangers To Love</h1>
    ...
    <div class="pod">served by pod<b>__POD__</b></div>
```

中身は 1 枚のページです。見出しが違い、配色が違い、目立つ「VERSION 2」バッジがあります。違いはわざと目立つように作ってあります。あなたが見るのは diff ではなくブラウザだからです。

2 つ注意してください。

**`__POD__` はそのまま残っています。** コピー名の差し込みは、両バージョンで共有される `rickroll-conf` ConfigMap の nginx 設定が行います。我々が変えているのはページであって、サーバーの振る舞いではありません。

**オブジェクトの名前は `rickroll-page` ではなく `rickroll-page-v2` です。** これはこのラボ全体の要となる判断であり、なぜそうするのかを明確にする価値があります。

分かりやすいのは別のやり方です。既存の `rickroll-page-v1` を取り、その中身を書き換える。コマンド 1 つ、新しいオブジェクトなし。それはやってはいけません。理由は次のとおりです。

第一に、古いものを失います。ロールバックできなくなります。以前のページは、あなたのファイルの中以外どこにも存在しなくなり、しかも `kubectl edit` で編集したのであれば、ファイルの中にすらありません。

第二に、更新が制御されません。ConfigMap を編集してもアプリケーションの記述は変わりません。つまり、その記述（どのイメージか、コピーはいくつか、ファイルはどこから取るか）を保持し、それが確実に実行されるようにする Deployment は、何も気づかず、ロールアウトを何も始めません。それでもクラスターは、稼働中の Pod の中のファイルを差し替えます。自分の判断で、自分のタイミングで、およそ 1 分かけて、しかもコピー間でばらばらの順番で。結果として、履歴に残らず、コマンドでロールバックできず、コピーへの反映がそろわない変更を手にすることになります。

だからこそのルール: **バージョンは別々のオブジェクトであり、バージョンを切り替えるのはアプリケーションの記述を変えることである。** それこそが Deployment の見方であり、リビジョン履歴に載る形であり、取り消せる形です。

</details>

適用します。クラスターに 2 つ目の ConfigMap が現れますが、まだ誰も参照していないので、稼働中のアプリケーションには触れません:

```bash
# apply = "bring the cluster to what's described in the file".
#   -f name.yaml   where to take the description from; the file is in this same folder
kubectl apply -f rickroll-page-v2.yaml
```

**見えるはず:** `configmap/rickroll-page-v2 created`。

ここでアプリケーションを開き、**何も変わっていない**ことを確認します:

```bash
# port-forward = a temporary tunnel from the bastion into the cluster.
#   svc/rickroll  where it leads: into the Service, that is, with requests spread across the copies
#   8080:80       on the left the port on the bastion, on the right the service's port inside the cluster
# While the tunnel is open the window is busy; it closes on Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> — 同じ第 1 バージョンです。新しいページをクラスターに入れましたが、アプリケーションはそれを知りません。ボリュームは依然として `rickroll-page-v1` を指しています。トンネルを閉じてください（`Ctrl+C`）。これはまだロールアウトではありません。

## ステップ 3. クラスターがどうコピーを入れ替えるかを理解する

📍 **場所:** bastion 上（bastion のターミナルで）。

バージョンを切り替える前に、入れ替えが従うルールを見ておきましょう。ルールはアプリケーションの記述そのものの中にあります:

```bash
# -o jsonpath=... — instead of a table, print a single field of the object by giving the path to it.
#   {.spec.strategy}  the block of rules by which the cluster replaces copies
#   {"\n"}            a newline at the end, otherwise the output runs into the prompt
kubectl get deployment rickroll -o jsonpath='{.spec.strategy}{"\n"}'
```

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

このブロックは `rickroll.yaml` にはありません。クラスターがデフォルト値を埋めました。

<details>
<summary><b>この割合が、我々の 3 つのコピーで何を意味するか</b></summary>

どちらの数も `replicas`、つまり 3 から数えます。そして、丸め方は逆向きです。

**`maxSurge: 25%`** — 入れ替えの進行中に、要求した数を**超えて**立ち上げてよいコピーの数。3 の 25% は 0.75、**切り上げ**て 1。だからロールアウト中、クラスターは一時的に 4 つのコピーを持てます。

**`maxUnavailable: 25%`** — 同時に**利用不能**にしておいてよいコピーの数。3 の 25% は同じく 0.75 ですが、**切り捨て**て **0** になります。

このゼロは絶対の制約です。準備できた置き換えが現れるまで、クラスターは稼働中のコピーを 1 つも停止することを許されません。「しようとする」ではなく、許されない。これは意図ではなく制約です。

だから各入れ替えステップの操作の順序はこうなります:

1. 新しいコピーを 1 つ立ち上げる（`maxSurge` が許す）;
2. その `readinessProbe` が成功で応えるのを待つ;
3. それを EndpointSlice に加える、つまりトラフィックを送る;
4. **ここで初めて**古いコピーを 1 つバランシングから外し、停止する;
5. 古いコピーが無くなるまで繰り返す。

すべては 3 点目と 4 点目にかかっており、その 2 点は `readinessProbe` にかかっています。マニフェストから readiness チェックを外すと、クラスターはプロセスが起動した瞬間からコピーを使える状態とみなし始めます。まだ設定を読み込んでいない nginx にトラフィックが向かい、500 の束を受け取ることになります。ここでの readiness チェックは監視ではなく、**ロールアウトのブレーキ**であり、それが本来の仕事です。

役に立つ帰結: 新バージョンが readiness チェックを通らないほどひどく壊れていれば、ロールアウトは**止まります**。古いコピーは動き続けます。これはラボの終わりの方で見ますが、そこでは別のやり方で壊します。

</details>

## ステップ 4. 負荷をかける

静かなところでロールアウトしても面白くありません。それは vSphere でも同じでした。トラフィックを送り、その下でバージョンを変えましょう。

📍 **ウィンドウ 1** — Fortio へのトンネル:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
# A tunnel to the load generator: port 8081 on the bastion → port 8080 of the fortio service.
# 8081 was chosen on the left so as not to collide with the tunnel to the application itself on 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **ブラウザで** — <http://localhost:8081/fortio/>。次を入力します:

| フィールド | 値 | なぜそうするか |
|---|---|---|
| URL | `http://rickroll/` | Service の名前。すべてのコピーがその背後に控える安定したアドレス。トラフィックは特定の Pod ではなくバランシングを通る |
| QPS | `300` | 一定の背景負荷。今は最大を絞り出す必要はない |
| Duration | `180s` | 3 分。ロールアウトとロールバックの両方を間に合わせられるウィンドウ |
| Connections | `20` | |

**Start** を押し、**ラボが終わるまでブラウザには触れないでください**。

同じ負荷はコマンドでも生成できます。フォームがうまくいかなかった場合に:

```bash
# exec = run a command inside an already-running Pod. The load is generated not by your bastion,
# but by Fortio itself from inside the cluster, so no tunnel is needed for this.
#   deploy/fortio  in any copy of the fortio application
#   --             everything to the right is a command for the container, not for kubectl
#   -qps 300       three hundred requests per second
#   -c 20          twenty simultaneous connections
#   -t 180s        hold the load for three minutes
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **ウィンドウ 2** — コピーを見守る:

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — show only Pods with this label; others won't get into the output.
# -w = "watch and append": the window stays busy and prints a new line every time
# the state of some copy changes. Exit — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## ステップ 5. バージョンを切り替える

📍 **ウィンドウ 3** — 空いているウィンドウ。1 枚目は Fortio へのトンネルを保持し、2 枚目は Pod の見守りで占有されているので、3 枚目で patch を実行します。ここでもアクセスを改めて設定する必要があります:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
```

ここでアプリケーションの記述のうち、ちょうど 1 つのフィールドを変えます。`page` という名前のボリューム、つまりコンテナの中に置かれるフォルダーが、その中身を ConfigMap `rickroll-page-v2` から取るようにするのです。「アプリケーションを更新する」というコマンドは存在しませんし、これからも存在しません。あるのは、あるべき状態の新しい記録だけです。クラスターは実際の状態との食い違いを自分で見つけ、コピーの入れ替えを始めます。

```bash
# patch = change a field in an object pinpoint-style, without rewriting the whole object.
#   --type=json  the edit format: "operation + path + value"
#   op: replace  replace what sits at this path
#   path         the address of the field inside the object; volumes/0 — the first volume in the list (see below)
#   value        the new ConfigMap name from which the volume will take the page
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v2"}]'
```

**見えるはず:**

```
deployment.apps/rickroll patched
```

⚠️ **この patch は壊れやすく、それははっきり言っておく必要があります。** パス `/spec/template/spec/volumes/0/...` はボリュームを**リスト内のインデックスで**指定しています。`rickroll.yaml` では `page` ボリュームが先で `conf` が後になっており、そこにはそのことのコメントまで書いてあります。しかし誰かがそれらを入れ替えると（YAML はそれを何ら禁じません）、まさに同じコマンドが、1 つのエラーも出さずに nginx 設定の名前を上書きし、アプリケーションは訳の分からない壊れ方をします。

<details>
<summary><b>それでもなぜこのやり方を採るのか、そして正しくはどうするか</b></summary>

JSON Patch を採ったのは、仕組みを純粋な形で見せるからです。コマンド 1 つ、フィールド 1 つ、目に見える結果。ラボにとってはそれに価値があります。

**より安全** — 同じことを普通の merge patch で。Kubernetes のリストはキーでマージでき、`volumes` にとってそのキーは `name` です:

```bash
# Without --type=json this is a merge patch: you describe a piece of the object in the same form
# it has in the manifest, and the cluster merges it with what's already there. The volumes list merges
# by the `name` key, so here the `page` volume is addressed, not "the volume at such-and-such index".
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

ここでは指定がボリュームの名前で行われ、リスト内の順序は関係なく、取り違えるものは何もありません。

**正しくは** — そもそも patch しないことです。patch は `kubectl edit` と同じく、クラスター内のオブジェクトは変えますが、あなたのファイルは変えません。1 週間後、誰かがリポジトリから `rickroll.yaml` を適用すると、アプリケーションは静かに第 1 バージョンへ戻ってしまいます。なぜかは誰にも分かりません。

通常の運用ではバージョンはこう変えます。ファイルの 1 行を編集し、変更をレビューに出し、マージ後に自動化が適用する。そうすればクラスターの状態とリポジトリの中身は常に一致します。それこそがラボ 5 でやることです。

</details>

入れ替えが進むのを見ます:

```bash
# rollout status prints the progress of the replacement line by line and finishes when all copies are updated.
# If the rollout doesn't converge, the command returns a non-zero exit code — convenient for
# stopping it in scripts.
kubectl rollout status deployment/rickroll
```

```
Waiting for deployment "rickroll" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "rickroll" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "rickroll" successfully rolled out
```

📍 **ウィンドウ 2 では**その間、コピーが一つずつ入れ替わるのが見えます。まず新しいものが現れて `1/1 Running` に達し、そのあとで初めて古いもののどれかが `Terminating` に入ります。

名前の末尾に注目してください。新しいコピーは中間の部分も変わっています。それが別の ReplicaSet です。Deployment は古いものを作り直したのではなく、その隣に 2 つ目を作り、一方からもう一方へコピーを注ぎ込んでいるのです。古いものはどこにも消えておらず、コピー数ゼロで出番を待っています:

```bash
# rs — shorthand for ReplicaSet, a set of copies of one version of the description.
# DESIRED — how many copies are requested in this set, READY — how many of them are ready to answer.
kubectl get rs -l app=rickroll
```

```
NAME                  DESIRED   CURRENT   READY   AGE
rickroll-6f4b9c8d57   0         0         0       48m
rickroll-7c5d4f9b21   3         3         3       40s
```

## ステップ 6. エラーを数える

📍 **場所:** bastion 上、ウィンドウ 3 で。前のコマンドが終わって空きました。

アプリケーションへのトンネルを開きます:

```bash
# The same tunnel as at the start of the lab: port 8080 on the bastion → port 80 of the rickroll service.
kubectl port-forward svc/rickroll 8080:80
```

📍 **ブラウザで** <http://localhost:8080> — 「VERSION 2」バッジの付いた緑のページです。何度か再読み込みしてください。下部のコピー名が変わります。Service がリクエストを 3 つのコピーに分配しているからです。

トンネルを閉じます（`Ctrl+C`）。

📍 **さていちばん大事なところ、Fortio のタブです。** 実行が終わるのを待ち、レスポンスコードの行を見つけます:

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**エラーゼロ。** アプリケーションは継続的なトラフィックのもと、バージョンをまるごと切り替え、5 万 4 千のリクエストのうち 1 つも損なわれませんでした。

その代償に払ったのは、マニフェスト内のたった 1 つのブロック、ラボ 1 のあの `readinessProbe` です。それがなければ、クラスターは新しいコピーが応答できる準備ができたと確かめる前に古いコピーをバランシングから外していて、この行は違って見えていたでしょう。

⚠️ **数万のリクエストのうち数十のエラーが出て、ゼロにならなかったとしても**、それはテスト環境が壊れているわけではありません。コピーをバランシングから外すことと、その中のプロセスを止めることは並行して起こり、速いトラフィックのもとでは一握りの接続がその隙間に滑り込みます。これは停止前の一時停止（`preStop`）と、アプリケーション自身での接続の穏やかな排出（graceful draining）で治ります。ラボではあえてこれをしません。隙間がひとりでに閉じると思い込むより、隙間が存在すると知っておく方が役に立つからです。

## ステップ 7. ロールバック

Fortio で負荷をもう一度（同じパラメーターで）開始し、それが走っている間に変更履歴を見ます:

```bash
# history = the list of saved revisions of the description. Each line is a state you can
# return to with a single command. CHANGE-CAUSE — an optional note on why it was changed.
kubectl rollout history deployment/rickroll
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

リビジョンが 2 つ。それぞれが、変更の瞬間のアプリケーションの記述を保存したスナップショットです。1 つ目は `rickroll-page-v1`、2 つ目は `v2`。これらが保たれているのは、まさに古い ReplicaSet が削除されないからです。デフォルトでクラスターは最新 10 件を保持します。

ロールバック:

```bash
# undo with no extra parameters = return to the previous revision. This isn't "rewinding
# time", it's an ordinary rollout of the old description: copies are replaced one at a time, by the same
# maxSurge and maxUnavailable rules.
kubectl rollout undo deployment/rickroll
# We wait until the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

📍 **ウィンドウ 2 では**同じ手順が逆向きに見えます。3 つの新しいコピーが一つずつ立ち上がり、現行の 3 つが去っていきます。`kubectl get rs -l app=rickroll` を見ると、コピーが第 1 の ReplicaSet、つまりゼロでぶら下がっていたものへ戻ったのが分かります。

📍 **ブラウザでは**アプリケーションはまた第 1 バージョンです。

📍 **Fortio では**また `Code 200 ... (100.0 %)`。

**これを vSphere でのロールバックと比べてください。** あちらではロールバックはスナップショットからの復元を意味します。マシンを停止し、ファイルを戻し、マシンを起動する。数分の利用不能と、スナップショットを取った後に起きたことすべての喪失です。ここではロールバックは記述を前のリビジョンに戻すことを意味し、普通のロールアウトと何ら変わりません。同じコピーを一つずつ、同じダウンタイムゼロです。

⚠️ **`CHANGE-CAUSE` は空で、それは不便です。** 履歴は*何が*変わったかは保つが、*なぜ*かは保ちません。1 か月も経てば、リビジョン 2 は何も教えてくれません。原因は `kubernetes.io/change-cause` アノテーションで埋められますが、この問いへの本当の答えはアノテーションではなく Git です。そこでは変更のすべてに作者と日付とコミットメッセージがあります。

## ステップ 8. 通らないチェック

仕組みは分かりました。次に、ロールアウトがうまくいかないときに何が起きるかを見ましょう。それは望ましいよりも頻繁に起こります。

ありふれた朝を思い浮かべてください。同僚がページの第 3 バージョンを用意していて、急いでいて、名前を打ち間違える。とはいえマニフェスト自体は妥当です。そんなオブジェクトが存在しないことをクラスターが知っている義務はありません。まさにこれを再現してみましょう:

```bash
# The same patch as when switching to the second version, but with a mistake in the ConfigMap name:
# there is no object `rickroll-page-v3` in the cluster. The reference's existence isn't checked on acceptance,
# so the command will finish successfully.
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v3"}]'

# --timeout=90s — don't wait forever: not having gotten ready copies, the command gives up after a
# minute and a half and returns an error. The rollout itself won't go anywhere and will stay hanging.
kubectl rollout status deployment/rickroll --timeout=90s
```

**見えるはず:**

```
Waiting for deployment "rickroll" rollout to finish: 0 of 3 updated replicas are available...
error: timed out waiting for the condition
```

コピーの顔ぶれを見てください。前の 3 つは動いており、新しいものは起動で止まっています。

```bash
# The READY column counts the ready containers inside the Pod: 1/1 — ready, 0/1 — not.
# STATUS says exactly where the startup stalled.
kubectl get pods -l app=rickroll
```

```
NAME                        READY   STATUS              RESTARTS   AGE
rickroll-6f4b9c8d57-4kk2p   1/1     Running             0          6m
rickroll-6f4b9c8d57-9dnvt   1/1     Running             0          6m
rickroll-6f4b9c8d57-lm7bq   1/1     Running             0          6m
rickroll-8b6a1e5c39-wr4tz   0/1     ContainerCreating   0          90s
```

> **先を読む前に、立ち止まって考えてください。**
>
> ここには問いが 2 つあり、2 つ目が 1 つ目より重要です。第一に、なぜ新しいコピーは起動しないのか。第二に、今この瞬間サービスに何が起きているのか。ダウンしているのか。

<details>
<summary><b>答え、そしてこのエラーより広い教訓</b></summary>

**なぜコピーが立ち上がらなかったか。** `rickroll-page-v3` という名前の ConfigMap は一度も作っていません。クラスターにはありません。クラスターに直接尋ねます:

```bash
# events — the cluster's log of occurrences, the nearest analogue of the Tasks & Events tab in vCenter.
#   --field-selector reason=FailedMount  keep only the records about a failed volume mount
#   --sort-by=.lastTimestamp             sort by time, the freshest end up at the bottom
#   | tail -3                            show the last three lines, discard the rest
kubectl get events --field-selector reason=FailedMount --sort-by=.lastTimestamp | tail -3
```

```
Warning  FailedMount  kubelet  MountVolume.SetUp failed for volume "page":
         configmap "rickroll-page-v3" not found
```

注意してください: `kubectl patch` コマンドは正常に終わり、`patched` と出力しました。クラスターは参照がどこにも通じない記述を受理し、一言も言いませんでした。マニフェストの受理時に ConfigMap の存在をチェックする仕組みはありません。それが可能なのは Pod が起動する瞬間だけで、まさにそれが起きたのです。

**さて 2 つ目の問い、このステップがそのために作られた問いです。** 止まったロールアウトのただ中でアプリケーションを開きます:

```bash
# The same tunnel. Traffic will go only to the copies that passed the readiness check,
# that is, to the three old ones: the stuck one didn't make it into balancing.
kubectl port-forward svc/rickroll 8080:80
```

動きます。第 1 バージョン、3 つのコピー、エラーなし。もしその瞬間 Fortio で負荷を走らせていたなら、レポートは今なお 100 パーセントの 200 を示します。

**完全に壊れたロールアウトが、サービスを落とさなかったのです。** これはラボの最初に確かめた `maxUnavailable: 0` の直接の帰結です。準備できた置き換えを得るまで、クラスターは稼働中のコピーを 1 つも停止することを許されませんでした。置き換えは得られなかった、だから何も停止もしなかった。ロールアウトは壊れ始めたまさにその場所で止まり、その状態のまま留まりました。

**教訓はこのエラーより広いものです。**

> Kubernetes での失敗したロールアウトは、デフォルトで**行き詰まる**のであって、崩壊するのではない。

これは更新についてのおなじみの論理をひっくり返します。「止める・更新する・起動する」方式では、途中のどんなエラーもダウンタイムを意味し、だからこそ更新は夜、人を電話口に待機させて行われます。「新しいものを立ち上げ、確かめ、切り替える」方式では、エラーは切り替えが起きなかったことを意味し、古いものは今までどおり動き続けます。

だから当番の人にとっての実践的な結論はこうです: **行き詰まったロールアウトはインシデントではない。** 夜中にあなたを起こしはしません。朝に対処すればよいし、あるいは 1 つのコマンドでロールバックして後から対処してもよい。

それこそが、これからやることです。

</details>

抜け出します:

```bash
# We return the previous revision — the one where the ConfigMap name is written correctly.
kubectl rollout undo deployment/rickroll
# We wait until the stuck copy disappears and the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

止まったコピーは消え、記述は動くものに戻ります。

## 検証

📍 **場所:** bastion 上、`kubectl` で作業したのと同じターミナルウィンドウで。

```bash
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **Windows ではスクリプトは PowerShell からではなく WSL から実行します**。インストール方法はラボ 0 の最初に書いてあります。WSL がなくてもラボはこなせますが、成果物のレポートは出ません。

スクリプトは、あなたが打ったコマンドではなく、事柄の中身を見ます。アプリケーションの履歴にいくつものリビジョンがあること（つまりバージョンが本当に変更され、元に戻されたこと）、第 2 バージョンの ConfigMap がクラスターにあること、アプリケーションが HTTP で応答すること、そして配信しているページが記述の指す ConfigMap と一致すること。それとは別に `readinessProbe` をチェックします。それがなければダウンタイムゼロは再現できません。

## 後片付け

`rickroll` アプリケーションは後で必要になります。削除しません。コピーを 1 つに戻します:

```bash
# Two extra copies will free up the node's memory — there won't be any load in the labs ahead.
kubectl scale deployment rickroll --replicas=1
```

負荷生成器はもう要りません:

```bash
# delete -f = delete exactly the objects listed in the file, and nothing besides them.
# The path leads to the neighboring folder, because the file is where the scaling lab is.
kubectl delete -f ../03-scale/fortio.yaml
```

`rickroll-page-v2` ConfigMap はそのままにしておいて構いません。数キロバイトを占めるだけで、CPU もメモリも消費しません。Kubernetes の記述は control plane のデータベースに保管され、何も参照していない間はコストがかかりません。仮想マシンのスナップショットとは違います。あちらはストレージ上の場所を取り、長く生き延びるほどマシンを遅くします。

## これでできるようになったこと

- ライブトラフィックのもとでアプリケーションのバージョンを変え、カウンターでエラーが無かったことを確認する
- ダウンタイムゼロがどこから来るかを説明する: `maxUnavailable`、`readinessProbe`、そして「まず準備、それから切り替え」の順序
- リビジョン履歴を読み、1 つのコマンドでロールバックする
- なぜバージョンを既存のものの編集ではなく別々のオブジェクトとして作るのかを理解する
- 壊れたロールアウトはサービスを落とすのではなく行き詰まること、そしてなぜそれがインシデントでないのかを知る

## これが vSphere であれば

事前に合意されたメンテナンスウィンドウ。始める前のスナップショット、数分とストレージの場所。その場での更新。うまく飛ばなければ、スナップショットからの復元、さらに数分の利用不能。そのすべてを夜に。日中にはできないからです。

ここでは、日中に 1 つのコマンド、トラフィックのもとで、そして結果が気に入らなければもう 1 つのコマンド。

**正直に言って、vSphere の方が便利なところ。** 3 つあります。

まず何より: **スナップショットは状態をまるごと取るが、`rollout undo` は記述だけを取る。** 新バージョンが動いていた間に、アプリケーションがデータベースに何かを書き込んだり、スキーマを変えたりしていたら、ロールバックはコードを戻してもデータは戻しません。新しいデータの上に古いバージョンが乗ることになり、それはときに、そのままにしておくより悪い結果です。VM のスナップショットはこれから救ってくれますが、`rollout undo` は救ってくれません。まさにこのために、データベースのスキーママイグレーションは双方向に互換であるよう書かれます。それは Kubernetes があなたに要求する規律であり、vSphere が要求しなかったものです。

第二に、vSphere のロールバックは絶対にすべてを戻します。手で入れたパッケージ、電話越しに設定へ加えた編集も。ここではマニフェストに記述されていたものだけがロールバックされます。誰かが脇でやったことは、クラスターがそれを知らないので、ロールバックされません。

第三に、スナップショットはアプリケーションが一度に 2 つのバージョンで動けることを要求しません。しかし `RollingUpdate` はそれを要求します。ロールアウト中は古いコピーと新しいコピーが 1 つのアドレスの背後で一緒にリクエストをさばくからです。互いに互換でなければ、セッション形式で、データスキーマで、プロトコルで、ダウンタイムゼロにはならず、混乱になります。これに備えていないアプリケーションのためには `Recreate` 戦略があります。すべて停止し、それからすべて立ち上げる。ダウンタイムは出ますが、予測できるものであり、ときにはそれを選ぶ方が誠実です。
