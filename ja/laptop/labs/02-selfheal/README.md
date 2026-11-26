# ラボ 2 · 自己修復: コピーを1つ殺して何が起きるか見る

| | |
|---|---|
| **所要時間** | 25分 |
| **何を証明するか** | コピーは数秒で自ら復活する。ただしそれだけでは耐障害性にはならない |
| **必要なもの** | ラボ0で作ったクラスター、ラボ1の `rickroll`、`kubectl`、ターミナルウィンドウ2枚 |

## なぜこれが大事か

まもなくあなたは「入館証（Gate Pass）」サービスの責任者になります。警備は朝7時にゲスト一覧を見るので、そこで「今リブート中なので待ってください」は通用しません。そんな約束を引き受ける前に、何も失うもののないうちに確かめておく価値があります。クラスターが自分でやってくれることは何で、あなた自身がやらなければならないことは何なのかを、正確に。

Kubernetes のもっとも声高な約束——自己修復——に取り組みましょう。動いているアプリケーションのコピーを1つ削除し、それが消えている時間を時計で計ります。そのあとで別のものを削除し、コピーが戻ってこないことを見ます。この2つのケースの違いこそが、このラボの中身です。

## ミニ用語集

| 用語 | それは何か | 似ているのは…ただし |
|---|---|---|
| **望ましい状態** | 「こうあるべき」というクラスター内の記録 | **vCenter のクラスター設定**。ただしクラスターはそれを一度だけ適用するのではなく、現実を延々とその状態に近づけ続ける |
| **コントローラー** | 「指示どおり」と「実際」を突き合わせる、クラスターのコントロールプレーン内のプロセス | **vSphere HA**。ただしホスト障害で目を覚ますのではなく、常時、あらゆるオブジェクトにわたって動き続ける |
| **ReplicaSet** | 注文どおりの数だけコピーがあることを保証するオブジェクト | **「N個のインスタンスを維持する」ルール**。ただし壊れたものを直すのではなく、消えたものの代わりに新しいものを作る |
| **ownerReferences** | オブジェクト内部の印:「これを作ったのはこいつだ」 | これのおかげで、親を削除すると子がすべて一緒に連れ去られる |
| **終了処理（Termination）** | 「削除」と「プロセスが殺される」の間の一時停止 | **Power Off ではなく Guest Shutdown**。ただしデフォルトで30秒、そのあとは強制的に殺される |
| **EndpointSlice** | 1つの Service の背後にある、生きているアドレスの一覧 | **ロードバランサー上のプールのメンバー一覧**。ただしラベルと準備状態から自動的に組み立てられ、手で書き込むものではない |

## ラボのフォルダに何が入っているか

ファイルはすべてもう手元にあります——リポジトリと一緒に受け取ったからです。新たに作ったり打ち込んだりするものは何もありません。以下で `kubectl apply -f name.yaml` と書いてあるところでは、ファイルはここから取られます。

```bash
# All the lab's commands are run from this folder — otherwise the relative paths in them won't line up.
cd labs/02-selfheal
```

| ファイル | それは何か | いつ役立つか |
|---|---|---|
| `check.sh` | 削除されたコピーをクラスターが自分で復元したことを確認する | ラボの最後に実行します |
| — | このラボ固有のマニフェストはありません。ラボ1のアプリケーションで作業し、ファイルはそこから取られます——`../01-deploy/rickroll.yaml` | |

## ステップ1. いま何があるかを見る

📍 **どこで:** ノートPC 上で。

`rickroll` アプリケーションはすでに動いています。何かを壊す前に、それがどんなオブジェクトから成り立っているかを見てみましょう。1つのコマンドで、3種類のエンティティについて一度にクラスターへ尋ねます。

```bash
# KUBECONFIG — the path to the file with the cluster's address and your login credentials.
# Until the variable is set, kubectl looks for a cluster on the laptop itself and doesn't find one.
export KUBECONFIG=~/lab.kubeconfig

# get = "show me what's there". Three kinds of object are listed at once, separated by commas.
#   -l app=rickroll   show only those labelled app=rickroll — that is, our
#                     application, not the entire contents of the cluster
kubectl get deployment,replicaset,pods -l app=rickroll
```

**表示されるはずのもの**——3つのオブジェクトそれぞれについて1行ずつ:

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/rickroll   1/1     1            1           14m

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/rickroll-6f4b9c8d57   1         1         1       14m

NAME                             READY   STATUS    AGE
pod/rickroll-6f4b9c8d57-xk2mp    1/1     Running   14m
```

⚠️ **`replicaset` の行は1行より多いことがあります。** 新しいバージョンをロールアウトするたびに、以前のセットが履歴として残ります——各カラムがゼロの状態で。生きているのは数字の1が並んでいる方で、残りはロールバックできる先を確保するために残っているのです。

マニフェストではラボ1で Deployment を1つだけ記述したのに、オブジェクトは3つあります。残りの2つはクラスターが自分で作ったものであり、これは見た目上の些細な話ではありません——以降のすべてが、この連鎖に依存しています。

<details>
<summary><b>連鎖を解きほぐす: 誰が誰を作ったのか、そしてなぜか</b></summary>

名前を見てください。Pod の名前は ReplicaSet の名前に5つのランダムな文字を足したもので、ReplicaSet の名前は Deployment の名前にハッシュを足したものです。連鎖はそのように組み立てられています。

**Deployment** はあなたの意図をまるごと保持します。どのイメージか、コピーは何個か、どう更新するか。Pod を直接見張るのではなく、ReplicaSet を見張ります。

**ReplicaSet** はたった1つの考えを保持します:「ラベル `app=rickroll` の付いた Pod がちょうどこれだけあるべきだ」。それだけです。イメージのこともバージョンのことも何も知りません。

**Pod** は動いているコピーです。

これが当て推量でないことは、次のように確かめられます:

```bash
# The default kubectl table doesn't show the ownerReferences field — you have to ask for it explicitly.
#   -o jsonpath=...   "pull these fields out of the server's response and print them like this"
# Inside the expression: range .items[*] — walk through every Pod found, .metadata.name —
# the Pod's name, ownerReferences[0].kind and .name — the kind and name of whatever created it.
kubectl get pods -l app=rickroll -o jsonpath='{range .items[*]}{.metadata.name}{"  <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}'
```

出力:

```
rickroll-6f4b9c8d57-xk2mp  <- ReplicaSet/rickroll-6f4b9c8d57
```

`ownerReferences` フィールドは「このオブジェクトが私を作った」という記録です。同じ記録が ReplicaSet にもあり、そこでは Deployment を指しています。

なぜ1つのオブジェクトではなく3階層なのか: 各階層が別々のことに責任を負っているからです。ラボ4で新しいバージョンをロールアウトするとき、Deployment は新しいバージョン用に**2つめの** ReplicaSet を作り、古いセットから新しいセットへコピーを1つずつ移し始めます。その間、古い ReplicaSet はどこにも行きません——まさにこれが、1つのコマンドでロールバックできる理由です。

覚えておく価値のある副次的な事実: 親を削除すると子が連れ去られます。ReplicaSet を手で削除すれば、Deployment が1秒で新しいものを作ります。Deployment を削除すれば、すべてが消えます。2つめのケースはラボの最後で試します。

</details>

## ステップ2. コピーを殺して時間を計る

これから Pod を1つ削除します。電源を切るのでも、リブートするのでもなく、まるで誰かが仮想マシンに対して Delete from Disk をクリックしたかのように、完全に削除します。

**これから何が起きるか:** 下のコマンドは現在のコピーの名前を覚え、それを削除し、そのあと1秒ごとに、**別の**名前のコピーが Running 状態で現れたかどうかをクラスターに尋ねます。現れたらすぐに、それにかかった時間を表示します。

```bash
# items[0].metadata.name — the name of the first Pod in the list. We save it in the POD variable:
# without that we won't be able to tell the old copy from the new one later.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')
echo "killing: $POD"

# date +%s — the current time in seconds. This is our stopwatch: we note it before the delete,
# and subtract it from a fresh reading right at the end.
START=$(date +%s)

# delete pod — delete the copy for good.
#   --wait=false   don't wait for the Pod to fully disappear, return control immediately:
#                  we need to start counting seconds from this moment, not afterwards
kubectl delete pod "$POD" --wait=false

# Once a second we re-read the Pod list and look for a line where all of these hold at once:
#   $1!=old        the name doesn't match the old one — so this is a different copy
#   $2=="1/1"      one container out of one is ready
#   $3=="Running"  the pod is running
#   --no-headers   don't print the table header, so awk sees only data
#   2>/dev/null    hide error messages during the seconds when there are no Pods at all
while true; do
  NEW=$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null \
        | awk -v old="$POD" '$1!=old && $2=="1/1" && $3=="Running" {print $1; exit}')
  [ -n "$NEW" ] && break
  sleep 1
done
echo "new copy $NEW ready in $(( $(date +%s) - START ))s"
```

**表示されるはずのもの:**

```
killing: rickroll-6f4b9c8d57-xk2mp
pod "rickroll-6f4b9c8d57-xk2mp" deleted
new copy rickroll-6f4b9c8d57-p9wqt ready in 4s
```

4秒。テスト環境でのばらつきは、ノードがどれだけ忙しいかによって2から15までです。イメージはすでにノードの上にあり、ダウンロードするものはないので、すべてはプロセスの起動と準備チェックにかかっています。

**名前に注目してください。** 末尾が変わりました: `xk2mp` が `p9wqt` になりました。これは同じ Pod が再起動したのではなく、別の Pod です。古い方はもうどこにもありません。直すことも、ごみ箱から復元することも、そのディスクに何があったかを見ることもできません。

誰も何も「復元」していません。1秒に何度も、ReplicaSet は「注文: 1」と「実際: 0」を突き合わせ、食い違いがあれば足りないものを作ります。コピーが消えた——食い違いが生じた——コピーが作られた。同じ仕組みは、より重要なワークロードのために Pod がノードから追い出された場合でも、ノード自体が落ちた場合でも、Pod の中のアプリケーションがメモリ不足で死んだ場合でも、同じように発火したはずです。

## ステップ3. このとき耐障害性はあったのかを確かめる

コピーは4秒で戻りました。ということは、サービスは中断しなかったのでしょうか?

確かめましょう。**ターミナルウィンドウが2枚**必要です。

📍 **ウィンドウ1** — クラスターの内側で、私たちのアプリケーションを Service 経由で1秒ごとに突き、成功なら点を、エラーなら `X` を描く小さな Pod を起動します:

```bash
export KUBECONFIG=~/lab.kubeconfig

# run = create a single Pod straight from the command line, without a manifest.
#   --rm             delete the Pod as soon as you interrupt the command
#   -it              the Pod's output comes to your screen, Ctrl+C stops it
#   --restart=Never  there's a single copy and no need to recreate it: this is a tool, not a service
#   --image          busybox — an image a few megabytes in size that has wget
# Everything after -- runs inside the Pod. The address http://rickroll is the name of the Service;
# inside the cluster it turns into the application's address on its own.
#   -q               don't print download statistics
#   -T 2             wait no longer than two seconds for a reply, otherwise we count it as a failure
#   -O /dev/null     throw the response body away, all we care about is the fact of a reply
kubectl run pinger --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'while true; do wget -q -T 2 -O /dev/null http://rickroll/healthz \
         && echo "$(date +%T) ." || echo "$(date +%T) X"; sleep 1; done'
```

各行にはタイムスタンプが付きます。こうすれば、失敗そのものだけでなく、それが**何秒間**続いたかが分かります——そしてそれこそ、このラボ全体が求めている数字です。

⚠️ **バックグラウンド実行ではなく、2枚目のターミナルが必要です。** この演習の狙いは、別のウィンドウでコピーを削除する**その瞬間**に失敗を見ることです。バツ印の行が、あなたの目の前で現れるべきなのです。あとから `kubectl logs` で読むこともできますが、そうすると肝心なもの——あなたの行動とその結果とのつながり——が失われます。

なぜノートPC からではなくクラスターの内側からなのか: `port-forward` は特定の Pod に食いつき、それと一緒に死ぬので、失敗が無いところでも——どのみち失敗を見せてしまいます。一方、隣の Pod からの `wget` は Service を通って行きます。つまり、本物のクライアントが通るのとまったく同じ経路です。

点が走り出すまで待ってください。

📍 **ウィンドウ2** — コピーを殺します:

```bash
export KUBECONFIG=~/lab.kubeconfig

# No pod name is given, a label instead: delete every copy with the label app=rickroll.
# Right now there's only one, so the one the pinger is polling is exactly the one that goes.
kubectl delete pod -l app=rickroll
```

📍 **ウィンドウ1を見てください。** だいたいこんなふうに見えます:

```
.........XXXXX.........
```

数秒間、サービスはエラーで応答しました——私たちの場合は5つ、忙しいノードでは15になることもあります。コピーはすぐ戻りましたが、それが無い間、応答する者はいませんでした。

**観察したことを正直に言い表すとこうなります。** 自己修復は耐障害性ではありません。自己修復は、人手なしにシステムを正常へ戻します。耐障害性は、クライアントが何ひとつ気づかなかったことを意味します。コピーが1つだと、前者は得られても後者は得られません。

pinger は止めないでください。すぐに使います。

## ステップ4. 同じことを、ただし3つのコピーで

📍 **ウィンドウ2。** 1つではなく3つのコピーを注文し、3つすべてが準備完了になるまで待ちます。

```bash
# scale changes exactly one field in the application's record — the number of copies.
kubectl scale deployment rickroll --replicas=3

# rollout status holds the terminal and prints progress until all the copies you asked for
# are ready. The command finishes on its own — no need to poll get pods by hand.
kubectl rollout status deployment/rickroll
```

私たちは望ましい状態のちょうど1つの数字を変えました。そこから先はすべて、同じ ReplicaSet がやります: 「注文3、実際1」を見て、足りない2つのコピーを作ります。これは以前と同じ数秒しかかかりません。

いまコピーが3つになり、そのすべてが Service の背後に収まったことを確かめてください:

```bash
# EndpointSlice — that very list of live addresses the Service keeps for you.
#   -l kubernetes.io/service-name=rickroll   take the list belonging to the Service rickroll
#   -o jsonpath=...                          from each entry print only the address itself,
#                                            one per line
kubectl get endpointslices -l kubernetes.io/service-name=rickroll \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

3つのアドレス。誰もそこに入力していません——Service がラベル `app=rickroll` と各コピーの準備状態から、自分で一覧を組み立てたのです。これこそ、ラボ1で語られたロードバランサーのプールとの違いです: あちらはアドレスを入力するのに対し、こちらは条件を記述します。

いま、3つのうち1つのコピーを殺します:

```bash
# We take the name of the first of the three copies — which one exactly doesn't matter.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')

# And delete it. No --wait=false here: the command returns once the Pod is already gone.
kubectl delete pod "$POD"
```

📍 **ウィンドウ1を見てください:**

```
...........................
```

`X` は1つもありません。コピーは殺され、作り直され、クライアントは気づきませんでした。

1つのコピーでのテストと3つのコピーでのテストの違いは、マニフェスト内のたった1つの数字です。**ここでの耐障害性は、スイッチを入れる機能ではなく、コピーが1つより多いことの帰結です。** まさにこれが、Kubernetes に「HA を有効化」というチェックボックスが無い理由です: 有効化するものなど無く、あるのは `replicas` だけです。

ウィンドウ1の pinger を `Ctrl+C` で止めてください。Pod が残ってぶら下がっていたら、消してください: `kubectl delete pod pinger`。

## ステップ5. 通らないテスト

仕組みははっきりしています: コピーを削除すると、それは戻ってくる。もう一度試しましょう。ただし今度は、コピーではなくアプリケーションそのものを削除します:

```bash
# We delete not a copy but the application's record itself. There will be no confirmation,
# the object won't go to any recycle bin — there'll be nowhere to restore it from but the file.
kubectl delete deployment rickroll
```

数秒待って、コピーが戻ってきたかどうかを見ます:

```bash
# We look for pods by the application's label. An empty response here is an answer too.
kubectl get pods -l app=rickroll
```

**表示されるもの:**

```
No resources found in default namespace.
```

コピーは戻ってきませんでした。5秒経っても、1分経っても。

> **読み進める前に、立ち止まって考えてください。**
>
> さっきコピーを殺したときは再び現れたのに、いまはなぜ現れないのでしょうか? 私たちは何も無効化していません。

<details>
<summary><b>答えと、このエラーより広い教訓</b></summary>

さっきあなたは**コピー**——つまり事実——を削除していました。「コピーは3つあるべき」という記録はその場に残り、現実がそれと食い違い、コントローラーが食い違いを消しました。

今回あなたは**記録そのもの**を削除しました。食い違う相手がもう残っていません: 望ましい状態は「このアプリケーションは存在しない」、実際の状態も「このアプリケーションは存在しない」。両者は一致しており、コントローラーには何もすることがありません。ついでに、`ownerReferences` の連鎖に従って、ReplicaSet と3つの Pod すべてが Deployment と一緒に去りました。

**このエラーより広い教訓。** このラボからまるごと持ち帰る価値のあるルール:

> Kubernetes は**事実**を失うことからは守ってくれるが、**意図**を失うことからは何ら守ってくれない。

自己修復のすべては、どうあるべきかの記録が無傷であるかぎりにおいて、ちょうどそのぶんだけ働きます。記録が変更されたり削除されたりすれば、クラスターはそれがどんなものであれ、新しい望ましい状態へと現実を、律儀に、そして非常に速く近づけます。「本当によろしいですか?」とは尋ねず、ごみ箱も残しません。

実務上の帰結が2つあり、どちらもちょうど一度だけ不快です。

**1つめ: ここでの削除は vSphere より静かです。** Deployment を取り壊すのは1行——確認もなく、赤いアイコン付きの「Delete from Disk?」もありません。クラスターから復元することはできません: 削除されたオブジェクトはどこにも保存されないのです。

**2つめ: 唯一の本当の防御は、意図をクラスターの外に置くことです。** マニフェストが Git にあり、それを自動化がクラスターへ運び込むなら、うっかり削除しても、1分後に自動化がリポジトリからオブジェクトを戻すことで治ります。それが GitOps であり、ラボ5でそれを有効化します。今のところ、あなたの `rickroll.yaml` が意図の唯一のコピーです。それがファイルにあるのは良いことです: レビューし、Git に入れ、もう一度適用できます。

ちなみに、中間の環は別に試す価値があり、振る舞いも異なります。アプリケーションを復元し（次のステップ）、そのあと Deployment ではなく ReplicaSet を削除してみてください:

```bash
# rs — short for replicaset; kubectl understands both spellings.
# We delete the middle link, leaving the Deployment in place.
kubectl delete rs -l app=rickroll

# And immediately look at what's left: compare the set's name with what it was before the delete.
kubectl get rs -l app=rickroll
```

セットは1秒で再び現れます——しかも**同じ名前で**。名前の中のハッシュは Pod テンプレートから計算され、私たちはテンプレートに触れていません: 同じ名前ということは、クラスターが何か新しいものを作ったのではなく、まったく同じものを復元したということです。「この アプリケーションがあるべき」という記録は無傷のまま残りました——それに責任を負うのは Deployment であり、それはセットの削除を生き延びたのです。

</details>

## ステップ6. アプリケーションを取り戻す

意図はあなたの手にあり、ファイルの中にあります。復元はコマンド1つです:

```bash
# apply = "bring the cluster to what's described in the file". The object doesn't exist — it will be created.
#   -f ../01-deploy/rickroll.yaml   the file lives in the lab 1 folder, hence the path via ../
kubectl apply -f ../01-deploy/rickroll.yaml

# We wait for the copy to come up and become ready to take requests.
kubectl rollout status deployment/rickroll
```

ここに何が**無かった**かに注目してください: バックアップもなく、スナップショットもなく、vCenter からのエクスポートもありませんでした。あなたは10キロバイトのテキストファイルからアプリケーションを復元し、手に入れたものは以前と文字どおり同じでした。仮想マシンではこの手は通用しません: その記述と中身は分かちがたいのです。

## 検証

📍 **どこで:** ノートPC 上、`kubectl` で作業していたのと同じターミナルウィンドウで。

このスクリプトは、あなたがコマンドを実行したことではなく、クラスターに何が残っているかを確認します: アプリケーションが再び Service 経由でリクエストを処理していること、ページに自分のコピーの名前を差し込んでいること、そしてその名前が本当に動いている Pod のものであること。別途、コピーが作り直された痕跡を——Pod の齢と、クラスターのイベントから——探します。

⚠️ **Windows ではスクリプトは PowerShell からではなく WSL から実行します**——インストール方法はラボ0の冒頭に書いてあります。WSL なしでもラボはこなせますが、成果物レポートは出ません。

```bash
# ./ means "a file from the current folder", not a command from the system PATH.
# The script changes nothing in the cluster: it only reads and prints a report.
./check.sh
```

## 後片付け

`rickroll` アプリケーションはラボ3とラボ4で必要になります——削除しません。

ここには片付けるものが何もなく、それ自体が注目に値します。あなたはファイルからアプリケーションを復元し、そのファイルは1つのコピーを注文しています——余分な2つは、前のステップの時点で、あなたのコマンドを尋ねることも待つこともなく、クラスターが自分で落としました。確かめるには:

```bash
# The READY column should read 1/1.
kubectl get deployment rickroll
```

コンテナが終わったその瞬間に、ノードのリソースが解放されました。ここには「デフラグ」も、スケジュールに従った領域の回収もありません: コンテナが終わった——そのメモリと CPU 時間は、直ちに隣人たちに使えるようになります。

## これで私たちができること

- Deployment → ReplicaSet → Pod の連鎖を説明し、なぜそれが3階層なのかを理解する
- 自己修復（コピーが戻った）と耐障害性（クライアントが気づかなかった）を見分ける
- コピーの数を1つの数字で変え、Service がそれらを自分で拾い上げる様子を見る
- クラスターは事実を守るが意図は守らないこと、そして意図の置き場所はどこかを理解する

## これが vSphere だったら

vSphere HA はホスト障害のあとに VM を再起動します: まずクラスターがホストが本当に失われたことを確かめる必要があり（これが数十秒）、それから機械がゼロから起動します——カーネル、サービス、アプリケーション。数分です。ハートビートの喪失にもとづく VM Monitoring も、同じ仕組みで、同じ時間スケールで働きます。

ここでは数秒であり、しかもホスト障害のときだけではありません: コピーが追い出されたとき、OOM がそれを殺したとき、あなたが自分で削除したときにも、同じ仕組みが発火します。

**正直に言って、vSphere の方が便利なところ。** 3つあります。

第一に、vSphere HA は**まさに同じ機械**を、ディスクにあったものすべてごと取り戻します。Pod は空の状態で戻ってきます: 永続ボリュームに載っていなかったものは、永久に失われます。ステートレスなアプリケーションにとってはこれは利点ですが、何年も自分の `/var` に何かを書き込んできたレガシーサービスにとっては、非常に嫌なサプライズの源です。

第二に、vSphere には Fault Tolerance があります: 2台の機械が lock-step で動き、ホスト障害でもダウンタイムはゼロ、しかもアプリケーションの作り直しは一切不要です。Kubernetes には直接の対応物は無く、あり得ません——ここでダウンタイムをゼロにするのは複数のコピーを持つことによってであり、つまりアプリケーションは複数のコピーで動けなければならないのです。もしそれができないなら、Kubernetes はその問題を解決してはくれず、露わにします。

第三に、事後検証（post-mortem）です。vCenter では機械が再起動した理由がクラスターのイベントに1つのエントリとして見え、それはそこに残り続けます。Kubernetes ではイベントは1時間ほどしか生きず、そのあと消えるので、いくつかのコンポーネントのログから絵を組み立て直さなければなりません。ログとイベントの収集を整える（ラボ14）までは、「なぜ夜中に再起動したのか」は答えのない問いです。
