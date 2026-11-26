# ラボ 3 · 負荷とオートスケーリング

| | |
|---|---|
| **所要時間** | 30 分 |
| **何を証明するか** | レプリカ数は、サービスデスクへのチケットではなく、負荷そのものによって決められる |
| **必要なもの** | ラボ 0 のクラスター、ラボ 1 の `rickroll`、ターミナルウィンドウ 3 枚、ブラウザ |

## なぜこれが重要か

この演習全体の理由でもある「Access Pass」サービスは、ムラのある挙動をします。朝の 8 時には警備とオフィスの半分が一斉に開き、午後 3 時には誰も触りません。ピークに合わせてキャパシティを見積もれば 1 日 9 時間も空気を暖め続けることになり、平均に合わせれば入口に行列ができます。

そこで 3 つ目の選択肢を試着してみましょう。レプリカ数を人が決めるのではなく、負荷そのものに決めさせるのです。アプリケーションに本物のトラフィックを与え、6 レプリカまで増えてから 1 に戻るのを観察します。

その道すがら、ここで最もつまずきやすいもの — 「どれだけ要求するか」と「どれだけ許すか」の違い — も整理していきます。

## ミニ用語集

| 用語 | それは何か | 〜に似ているが |
|---|---|---|
| **HPA** | メトリクスに基づいてレプリカ数を変更するオブジェクト | **DRS に VM の手動追加を足したもの**に似ているが、インスタンスをホスト間に分散させるのではなく、その数を変える |
| **metrics-server** | Pod の現在の消費量を集めるサービス | **vCenter の統計収集**に似ているが、直近の数分しか保持しない — 履歴はいっさいない |
| **requests** | 保証として予約するリソース量 | **Reservation**（予約）に似ているが、使用率のパーセンテージはここから計算され、Pod がどこに収まるかを決めるのもこれ |
| **limits** | Pod がそれを超えられない上限 | **Limit** に似ているが、上限に達すると CPU はスロットリングされ、メモリは Pod を殺す |
| **使用率（Utilization）** | `requests` に対するパーセンテージとしての消費量 | **グラフ上の「CPU Usage %」**に似ているが、600% になることもあり、それは間違いではない |
| **Fortio** | Web インターフェイス付きの負荷生成ツール | **HCIBench** に似ているが、これはクラスターの内側に普通のアプリケーションとして存在する |

## ラボフォルダーの中身

ファイルはすでにすべて揃っています — リポジトリと一緒に受け取っています。作ったり打ち直したりするものは何もありません。以下で `kubectl apply -f name.yaml` を見かけたら、そのファイルはここにあります。

```bash
# Every command in this lab is run from this folder — otherwise the file names in them won't be found.
cd labs/03-scale
```

| ファイル | それは何か | いつ役立つか |
|---|---|---|
| `hpa.yaml` | オートスケーリングのルール: CPU 負荷に基づいてレプリカを増やす | 自分の `lab` クラスターに適用する |
| `fortio.yaml` | Web インターフェイス付きの負荷生成ツール — 負荷を掛けるのはこれ | 同じ場所に適用する |
| `check.sh` | 負荷でレプリカが増え、その後に減ったことを検証する | ラボの最後に実行する |

## ステップ 1. 1 レプリカから始まっていることを確認する

📍 **どこで:** ノートPC 上。

このラボ全体は、レプリカ数が目に見えて増えることに拠っています。ですから 1 から始めなければなりません — さもないと増加を比べる相手がなくなります。今いくつのレプリカが動いているか見てみましょう。

```bash
# KUBECONFIG is the path to the file with the cluster's address and login details.
# Until the variable is set, kubectl looks for the cluster on the laptop itself and doesn't find it.
export KUBECONFIG=~/lab.kubeconfig

# The READY column reads as "ready / requested": 1/1 means one replica requested and running.
kubectl get deployment rickroll
```

`1/1` と出るはずです。それより多ければ 1 に戻してください。さもないと増加が見えにくくなります。

```bash
# scale changes exactly one field in the application's record — the replica count.
# The cluster will retire the extra replicas on its own, within seconds.
kubectl scale deployment rickroll --replicas=1
```

## ステップ 2. アプリケーションが何を要求しているかを読む

オートスケーリングを設定する前に、それが何に対してパーセンテージを計算するのかを理解しておく必要があります。

```bash
# An object in the cluster has hundreds of fields; the table doesn't show them. jsonpath extracts
# exactly one spot from the response. Read the path top to bottom: spec.template is the template
# from which replicas are created, containers[0] is the first container in it, resources is its
# request and ceiling for CPU and memory. The tail {"\n"} is a newline, so the response
# doesn't run into the next command prompt.
kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

```json
{"limits":{"cpu":"300m","memory":"128Mi"},"requests":{"cpu":"20m","memory":"32Mi"}}
```

2 組の数字があり、これは絶えず混同されます。CPU で順を追って見ていきましょう。

**`requests: cpu: 20m`** — 「20 ミリCPU」、つまりコアの 100 分の 2 です。これが要求です。クラスターが Pod の背後に常に確保すると約束する量です。スケジューラーはこの数字を使って Pod がノードに収まるかを判断します。ノード上の全 Pod の requests の合計は、そのノードの容量を超えられません。最も近いアナロジーは vSphere の reservation（予約）です。

**`limits: cpu: 300m`** — 上限です。ノードが空いていても、Pod にはコアの 10 分の 3 より多くは与えられません。アナロジーは vSphere の limit です。

両者の間には 15 倍の開きがあり、これは意図的です。CPU が空いているときには Pod は多く使えますが、保証されているのはわずかだけなのです。

⚠️ **CPU とメモリは上限に達したときの振る舞いが異なり、それは見た目以上に重要です。** CPU の上限に達すると、アプリケーションは単に遅くなるだけです（スロットリング）。メモリの上限に達すると、カーネルはコンテナを殺します。ステータス `OOMKilled` が見え、Pod は作り直されます。前者は不快なだけですが、後者は障害です。vSphere でもメモリを超過することはできませんが、そこではゲストにスワップが与えられ、死ぬのではなく劣化します。

**さて、ここがこのラボの核心です。** HPA は負荷を、limit からでも、ノードの容量からでも、アプリケーションが自分の中で見ているコア数からでもなく計算します。**`requests` から**計算するのです。`requests: 20m` で 50% のしきい値は、レプリカあたり 10 ミリCPU を意味します。

ここから、初めて設定する人にとってオートスケーリングが動かない最もよくある原因が導かれます。**コンテナに `requests.cpu` が指定されていなければ、計算する相手がなく、HPA はまったく動きません。** エラーは出ません — 黙って `<unknown>` を表示し続けるだけです。

## ステップ 3. オートスケーリングを有効にする

`hpa.yaml` ファイルはフォルダーの中にあります。まず目を通してから適用しましょう。

<details>
<summary><b>詳しく見る: hpa.yaml の中身</b></summary>

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rickroll
```

`autoscaling/v2` は飾りではありません。古い `v1` では CPU のターゲットしか設定できず、増加の速度を制御できませんでした。`metrics` ブロックより下のすべては `v1` では使えません。ネット上で `autoscaling/v1` の例を見かけたら — それは致命的に古いわけではありませんが、必要なことの半分もカバーしてくれません。

```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rickroll
```

誰を見て、誰を回すか。HPA は Pod を直接管理しません — Deployment の `replicas` フィールドを変え、そこからは自己修復のラボと同じ連鎖が働きます。Deployment が数を ReplicaSet に渡し、ReplicaSet が足りないレプリカを作ります。

ここから実務的なルールが導かれます。**HPA が存在する限り、`replicas` を手で変えても無意味です。** あなたが 3 を設定しても、15 秒後には HPA が自分の値を設定します。1 つのフィールドに 2 つのメカニズムは常に言い争いになり、HPA が勝ちます。

```yaml
  minReplicas: 1
  maxReplicas: 6
```

回廊です。下限は「負荷がないから全部止めよう」を防ぎます — HPA はゼロまで縮小できません。上限は予算とノードを守ります。これがないと、突然のスパイク（あるいは CPU を食い尽くすアプリケーションのバグ）が、ノードに空きがなくなるまでレプリカを増やし続けてしまいます。

6 は学習用ノード `u1.medium` に合わせて選ばれました。それぞれ 20m の requests で 6 レプリカなら 120m — ノードは楽にさばけます。

```yaml
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

ルール: 全レプリカにわたる**平均**負荷を、その `requests` の 50%、つまりレプリカあたり 10m に保つ。

ここでは「平均」という語が鍵で、算術のすべてがそれに依存します。HPA はこう計算します。

```
replicas needed = ceil( current replicas × current load ÷ target load )
```

1 レプリカが 645% の負荷、ターゲット 50% なら、`ceil(1 × 645 / 50) = 13` です。13 は 6 より多いので、HPA は `maxReplicas` に張り付きます。

なぜターゲットが 80 ではなく 50 なのか。80% では、アプリケーションがすでに困り始めてからようやく増加が始まります。半分にしておけば、新しいレプリカが立ち上がるのにかかる時間の余裕が残ります。本番のサービスでは、この数字は起動に何秒かかるかに合わせて調整します。

```yaml
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 2
          periodSeconds: 15
```

増加の速度です。デフォルトでは、スケールアップの前に Kubernetes はある一定の窓にわたるメトリクス履歴を見て、ランダムなスパイクでガクッと反応しないようにします。ラボでは「何も起きていない」ように見えるので、この窓をゼロにします。ごく最初の測定に対して反応するようにするのです。

`Pods: 2 / 15s` — 15 秒ごとに 2 レプリカ以下しか追加しない。だから上りの道は階段状になります。1 → 3 → 5 → 6。

⚠️ **`policies` を指定すると、標準のものに追加するのではなく置き換えます。** 標準の増加ポリシー（15 秒ごとに倍増）はここではもう適用されません。

```yaml
    scaleDown:
      stabilizationWindowSeconds: 60
```

一方で、下向きには遅延が付きます。HPA は直近 1 分間に要求された数の最大値を見て、その全区間にわたって負荷が低かった場合にのみレプリカ数を減らします。さもないと、スパイクの合間のポーズごとにレプリカが消えたり再び現れたりし始めてしまいます。

ここでの標準値は **300 秒**、5 分です。ラボの中で戻りを見る時間が取れるよう、1 分に縮めています。本番では 5 分のほうが理にかなっています。

</details>

適用します。

```bash
# apply = "bring the cluster to what's described in the file." The HPA object will appear at once,
# but it won't start computing right away — that's what we'll trip over in the next step.
kubectl apply -f hpa.yaml
```

## ステップ 4. 通らない検査

何が得られたか見てみましょう。

```bash
# hpa is shorthand for horizontalpodautoscaler; kubectl understands both spellings.
# The TARGETS column reads as "current load / target," REPLICAS is how many
# replicas are requested right now.
kubectl get hpa rickroll
```

**見えるもの:**

```
NAME       REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: <unknown>/50%   1         6         1          10s
```

`TARGETS` 列には負荷の代わりに `<unknown>` があります。オートスケーリングはアプリケーションがどれだけ CPU を消費しているか分からず、だから判断の根拠がありません。

⚠️ **あるいは、いきなりパーセンテージが見えることもあります** — たとえば `cpu: 5%/50%`。それはあなたのところで何かが違うという意味ではありません。あなたのクラスターのメトリクス収集器はすでにしばらく動いていて、Pod をポーリングする時間があったのです。`<unknown>` は立ち上げたばかりのクラスターで現れます。すぐに数字が出た人も — 下の解説はやはり読んでおいてください。`<unknown>` の原因にはいつか出くわしますし、それが邪魔になる瞬間に学ぶより、前もって学んでおくほうがよいのです。

> **読み進める前に、立ち止まって考えてください。**
>
> マニフェストはエラーなく適用され、オブジェクトは作られ、コンテナには `requests` があります — さっき見たとおりです。ですから、記述に何かが欠けているわけではありません。
>
> ヒント: そもそもオートスケーリングは現在の負荷をどこから知るのでしょうか。誰かがその数字を報告しなければなりません — そしてその誰かは、Pod を絶え間なくではなく、数十秒に 1 回ポーリングします。

<details>
<summary><b>答えと、このエラーより広い教訓</b></summary>

時間が足りていないのです。1 分半から 2 分待って、もう一度見てください。

```bash
# The same command as above. We're looking at the same TARGETS column.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 0%/50%     1         6         1          2m
```

**これは故障ではなく、ここに直すものは何もありません。** Pod の負荷は別のサービス `metrics-server` が収集します。これはおよそ 15 秒に 1 回ノードをポーリングし、短い窓で結果を平均します。連続 2 回の測定が揃うまでは渡せるものがなく、HPA は正直に「分からない」と書きます。

メトリクスが実際に流れているかは直接確認できます。

```bash
# top = "how many resources these Pods are eating right now." The numbers come from
# the same metrics-server that feeds autoscaling: if top answers, then the
# data source is alive and it's only a matter of time.
kubectl top pods -l app=rickroll
```

```
NAME                        CPU(cores)   MEMORY(bytes)
rickroll-6f4b9c8d57-p9wqt   1m           4Mi
```

5 分たっても依然 `<unknown>` で、`kubectl top` が `error: Metrics API not available` と答えるなら — そのときは本当に故障で、原因は 2 つのうちのどちらかです。`metrics-server` がクラスターにインストールされていないか、コンテナに `requests.cpu` が設定されていないか（この場合 `kubectl top` は動くのに HPA はやはり計算できません — パーセンテージを取る相手がないのです）。

`metrics-server` はクラスターと一緒に自らインストールされます — 別途有効化する必要はありません。これは `cozy-monitoring` namespace に住んでいて、こう確認できます。

```bash
# -n = which namespace to look in. A namespace is a section of the cluster;
# by default kubectl looks in default and doesn't see the system Pods there.
# deploy is shorthand for deployment.
kubectl -n cozy-monitoring get deploy metrics-server
```

ラボ 0 の **Monitoring agents** チェックボックスと混同しないでください。あちらはメトリクスをストレージに集めてグラフにする担当（可観測性のラボ）で、`metrics-server` は `kubectl top` とオートスケーリングのための現在の数字を担当します。別々のメカニズムで、独立して存在します。

正確な原因は次で分かります。

```bash
# describe = the object's full card: all fields, events, and conditions,
# unlike get, which prints a few table columns.
kubectl describe hpa rickroll
```

いちばん下の `Conditions` に、人が読める説明の付いた `ScalingActive` の行があります。

**このエラーより広い教訓。** Kubernetes では「適用された」と「動いている」は時間的に切り離されています。`apply` コマンドはあなたの意図をクラスターに記録するだけです。そこからはコントローラーが拾い上げ、それぞれに固有のペースがあります。HPA は 15 秒に 1 回再計算し、メトリクスは 1 分遅れ、ガーベジコレクターは数分に 1 回巡回します。vCenter で身についた「ダイアログが閉じた、だから完了」という習慣は、ここでは裏切ります。見るべきはコマンドのリターンコードではなく、オブジェクトの `status` です。

</details>

## ステップ 5. 負荷生成ツールを立ち上げる

ノートPC から `port-forward` 経由でアプリケーションに負荷を掛けるのは無意味です。ボトルネックはアプリケーションではなく、あなたの自宅のインターネットとトンネルそのものになってしまいます。生成ツールはクラスターの内側、ターゲットの隣に置く必要があります。

`fortio.yaml` ファイルはフォルダーの中にあります。

<details>
<summary><b>詳しく見る: fortio.yaml の中身</b></summary>

```yaml
kind: Deployment
metadata:
  name: fortio
```

Fortio はクラスター内の普通のアプリケーションで、ほかのすべてと同じ Deployment でデプロイされます。ここには特別な「テスト用インフラ」はなく、それ自体が示唆に富んでいます。

```yaml
        - name: fortio
          image: fortio/fortio:latest
          args: ["server"]
```

Fortio のイメージは 2 つのモードで動けます。`fortio load ...` はコマンドラインからの 1 回きりの実行です。`fortio server` は Web インターフェイスを備えて動き続けるサービスで、ボタンで負荷を開始し、結果をその場でグラフとして見られます。私たちは 2 つ目を取ります。ワークショップでは、ターミナルで数字の列を読むより、ブラウザでレイテンシのヒストグラムを見るほうが分かりやすいからです。

⚠️ **マニフェストの `latest` タグは、本番でやってはいけないことです。** 今日は 1 つのイメージ、1 か月後には別のイメージになり、自分のテストを再現できなくなります。学習用の生成ツールなら許容できますが、それ以外では駄目です。

```yaml
          ports:
            - containerPort: 8080
              name: http
```

Fortio の Web インターフェイスは 8080 でリッスンし、パス `/fortio/` に住んでいます。`http` という名前は下の Service で必要になります。

```yaml
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: "1"
              memory: 256Mi
```

注目してください。生成ツールにはターゲットより多くが割り当てられています。`rickroll` の 20m に対して 100m の requests、300m に対して丸ごと 1 コアの上限です。

これは気前のよさではなく、正しいテストのための必須条件です。生成ツールが CPU 不足になれば、それ自身の上限に張り付き、あなたはアプリケーションではなく Fortio を測っていることになります。この間違いの症状は見分けがつきます。ターゲットの負荷はそのままなのにレイテンシが上がるのです。

```yaml
kind: Service
metadata:
  name: fortio
spec:
  ports:
    - port: 8080
      targetPort: http
```

Web インターフェイスのための安定したアドレスです。クラスターの内側からは今や `http://fortio:8080/` として到達でき、外側からは `port-forward` 経由で、これは次にやります。

</details>

適用して待ちます。

```bash
# There are two objects at once in the file: the Deployment with the generator and a Service — a
# stable address for its web interface.
kubectl apply -f fortio.yaml

# rollout status holds the terminal and prints progress until the replica is ready.
# We wait here on purpose: until the generator is up, there's nothing to drive load with.
kubectl rollout status deployment/fortio
```

## ステップ 6. ブラウザで Fortio を開く

📍 **ウィンドウ 1** — Fortio へのトンネル。ポート `8081` を選んだのは、ラボ 1 の `rickroll` へのトンネルをまだ開いている場合に `8080` と衝突しないようにするためです。

```bash
export KUBECONFIG=~/lab.kubeconfig

# port-forward runs a tunnel from your laptop into the cluster.
#   svc/fortio    what we connect to: the Service named fortio
#   8081:8080     reads as "port on your side : port in the cluster" — a request
#                 to localhost:8081 goes to port 8080 of this Service
kubectl port-forward svc/fortio 8081:8080
```

このコマンドは終了しません — トンネルを開いたまま保持します。動いている間に <http://localhost:8081/fortio/> を開いてください。

⚠️ **パス末尾のスラッシュは必須です。** スラッシュなしの `http://localhost:8081/fortio` では Fortio は 404 を返し、まるで起動していないように見えます。

## ステップ 7. 増加を観察するための 2 つ目のウィンドウを用意する

このラボの眼目は Fortio のレポートの数字ではなく、レプリカに何が起こるかです。これは負荷の後ではなく、負荷と同時に見る必要があります。

📍 **ウィンドウ 2** — ラボの最後まで開いたままにしておきます。

`-w`（watch）フラグで観察します。これは「画面をリフレッシュする」ではなく「変化があるたびに新しい行を印字する」という意味です。出力は表ではなくイベントログとして出てきます。これは `watch kubectl get pods` との重要な違いで、あちらでは「今」のスナップショットしか見えず、途中の状態を簡単に見逃してしまいます。

```bash
export KUBECONFIG=~/lab.kubeconfig

# We watch rickroll's replicas: each new line is a state change of one of them.
# The command doesn't finish; to exit, Ctrl+C — this has no effect on the replicas themselves.
kubectl get pods -l app=rickroll -w
```

3 つ目のウィンドウがあれば、そこにもこれを入れてください — そうすれば意思決定のプロセスそのものが見えます。

```bash
# The same watching, but of the autoscaling decisions: TARGETS shows how the load
# changes, REPLICAS shows how many replicas it requested in response.
kubectl get hpa rickroll -w
```

## ステップ 8. 負荷を掛ける

📍 **どこで:** ブラウザ、Fortio のタブで。

フォームを埋めます。

| フィールド | 値 | なぜそうするか |
|---|---|---|
| URL | `http://rickroll/` | Service 名。Fortio はクラスター内にあり、直接それを見られる |
| QPS | `1200` | 毎秒 1200 リクエスト |
| Duration | `90s` | 1 分半: 増加にも、それをやり切るのにも十分 |
| Connections | `80` | 80 本の並列接続 |

**Start** を押します。

⚠️ **お使いの Fortio のバージョンでフィールド名が違う場合**（たとえば接続数が `Threads` と表示されている場合）、意味で判断してください。URL、リクエストレート、継続時間、並列度です。同じ負荷はブラウザを介さずコマンドで掛けることもできます。

```bash
# exec runs a command inside an already-running Pod, not on your laptop.
#   deploy/fortio   in a Pod of this application; which Pod exactly — kubectl picks itself
#   --              everything after this separator is the command for the Pod
#   -qps 1200       twelve hundred requests per second
#   -c 80           eighty parallel connections
#   -t 90s          hold the load for a minute and a half
# The last argument is the target: the Service name of our application.
kubectl exec deploy/fortio -- fortio load -qps 1200 -c 80 -t 90s http://rickroll/
```

## ステップ 9. 何が起きるかを観察する

📍 **ウィンドウ 2**、開始からおよそ 20 秒後:

```
NAME                        READY   STATUS              AGE
rickroll-6f4b9c8d57-p9wqt   1/1     Running             22m
rickroll-6f4b9c8d57-mn4kd   0/1     Pending             0s
rickroll-6f4b9c8d57-mn4kd   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-t8zxc   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-mn4kd   1/1     Running             3s
rickroll-6f4b9c8d57-t8zxc   1/1     Running             3s
```

それからもう 2 つ、さらにもう 1 つ。1 分のうちに 6 レプリカになります。

📍 **HPA を見てください** — 何を見て、何を決めたか:

```bash
# TARGETS is the current average load against the target, REPLICAS is how many replicas are requested.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 645%/50%   1         6         6          8m
```

**645%。** このラボを試したテスト環境では、ちょうどこの値になりました。あなたのところでは桁の異なる数字になるでしょうが、間違いなく数百パーセントです。

この数字は、それが何から計算されているかを思い出すまではばかげて見えます。ノードの容量からではなく、レプリカの **request** から、そして私たちの request は 20m — コアの 100 分の 2 です。1 レプリカが要求の何倍も取っていて、それは許されています。`requests` は保証された最小値であって上限ではありません。上限は `limits` で、それはまだ遠くにあります。

一方でノードは空きにはほど遠く、`u1.medium` は 1 コアで、この 1 分間はアプリケーションのレプリカも負荷生成ツール自身もその上で動いています。高いパーセンテージは容量のあり余りから来るのではなく、小さな分母から来るのです。

**ここでは 100 を超えるパーセンテージは正常であって、警報ではありません。** これが vCenter から持ち込んだ直感を最も壊すところです。あちらで「CPU Usage 645%」なら惨事を意味します。パーセンテージが割り当てた量から計算されていたからです。ここでは要求された最小値から計算され、request と上限の間には 15 倍の開きがあります。

HPA の算術を自分で確かめてください。

```bash
# The consumption of each replica separately. CPU(cores) is printed in millicpu:
# 100m is a hundredth of a core, 1000m is a whole core.
kubectl top pods -l app=rickroll
```

レプリカにわたる平均こそ、HPA がしきい値と比べる数字そのものです。20m の request の 50%、つまり 10m です。全レプリカの合計はノードのコアに達し — そこで増加は止まります。それ以上負荷を上げても同じです。

📍 **一方でブラウザの Fortio タブでは**、レイテンシのヒストグラムが描かれています。実行を最後まで見届けてください。終わりに `Code 200 : 108000 (100.0 %)` のような行が現れます。エラーゼロ — アプリケーションは持ちこたえました。この行がどこにあるか覚えておいてください。ラボ 4 ではこれが主要な証拠になります。

## ステップ 10. レプリカが下りていくのを観察する

負荷は終わりました。何もせず、ウィンドウ 2 を見ていてください。

最初の 1 分半から 2 分は何も起きません。このポーズは 3 つの遅延から成ります。メトリクスがおよそ 1 分遅れること、`stabilizationWindowSeconds: 60` が直近 1 分の全区間で負荷が低いことを要求すること、そして HPA 自身が 15 秒に 1 回しか再計算しないことです。

それから行が一斉に流れ込みます。

```
rickroll-6f4b9c8d57-t8zxc   1/1     Terminating   4m
rickroll-6f4b9c8d57-mn4kd   1/1     Terminating   4m
...
```

5 レプリカが去り、1 つが残ります — `minReplicas` です。

**非対称性に注目してください。** 上りは 2 レプリカずつの階段で登りましたが、下りは一気の 1 手でした。これは設計どおりです。「レプリカが多すぎる」側に間違えても財布が痛むだけですが、「少なすぎる」側に間違えるとサービスを落とすことになります。だから増えるときは積極的に、減るときは慎重に、なのです。

## 検証

📍 **どこで:** ノートPC 上、`kubectl` で作業したのと同じターミナルウィンドウで。

このスクリプトはマニフェストが適用されたという事実ではなく、メカニズムが本当に生きていることを確認します。HPA が存在して正しい Deployment を対象にしていること、コンテナにパーセンテージを計算する `requests.cpu` があること、`metrics-server` が本当に数字を渡していること（`TARGETS` が `<unknown>` でないこと）、そして HPA のステータスにスケーリングがすでに発火したという印がまだ残っていることです。

⚠️ **クリーンアップの前に検査を実行してください** — HPA を削除してしまうと、検査するものが何もなくなります。

⚠️ **Windows ではスクリプトは PowerShell ではなく WSL から実行します** — インストール方法はラボ 0 の冒頭に書かれています。WSL がなくてもラボは完了できますが、レポートの成果物は残りません。

```bash
# ./ means "a file from the current folder," not a command from the system PATH.
# The script changes nothing in the cluster: it only reads and prints a report.
./check.sh
```

## クリーンアップ

**HPA を削除します。** ラボ 4 では負荷を掛けたまま新しいバージョンをロールアウトします。同時にレプリカ数を変える余分なメカニズムがあると、絵図が混乱するだけです。

```bash
# delete -f = "remove from the cluster what's described in this file." The application stays:
# only the HPA is described in the file. After deletion the replica count freezes at the current value.
kubectl delete -f hpa.yaml
```

**Fortio は残しておきます** — ラボ 4 で負荷源として必要になります。ラボ 4 をやる予定がないなら、これも取り除いてください。

```bash
# Removes both objects from the file — the generator's Deployment and its Service.
kubectl delete -f fortio.yaml
```

`rickroll` アプリケーションには触れないでください。

解放したものはすべて、コンテナが終わった瞬間にノードの共有プールへ戻りました。ここには「割り当てられたが返されていない」というものはありません — request は Pod が生きている間だけ、ぴったりそれだけ生きます。

## ここまでで、できるようになったこと

- `requests` と `limits` の違いを説明し、それぞれの上限に達したときに何が起こるかを予測できる
- HPA がなぜ `requests` からパーセンテージを計算するのか、そしてそれがなければなぜ動かないのかを理解している
- HPA の式を読み、いくつのレプリカを要求するかを前もって言える
- 「マニフェストが適用された」と「メカニズムが動き始めた」を見分け、status のどこを見ればよいか分かる
- ノートPC からではなく、クラスターの内側からアプリケーションに本物の負荷を掛けられる

## そして vSphere ではこうなる

vSphere でスケールアップするなら、動いているマシンへの CPU とメモリのホットアドです。人がスケジュールに従って、あるいはアラートに応じて行い、それで終わりです — vCenter はアプリケーションのインスタンスを増やせません。そのためにはロードバランサー、マシンテンプレート、そして誰かの手作業が必要です。DRS は別の問題を解きます。既存のマシンをホスト間で移動させますが、その数は変えません。

ここではレプリカの数は負荷の帰結であり、20 行ほどのテキストに記述されています。

**正直に言って、vSphere のほうが便利なところ。** 3 つあり、どれも重要です。

第一に、ホットアドはどんなアプリケーションでも効きます。2009 年に書かれ、単一インスタンスとしてのみ存在するものであっても。HPA はアプリケーションが一度に複数のレプリカで動けることを要求します。共有状態を持たず、ローカルファイルに書き込まず、セッションをインスタンスに固定しないこと。それができないなら、オートスケーリングはあなたには使えず、Kubernetes はこの問題を解いてはくれません — むき出しにするだけです。移行の本当の境界線はまさにここに走っており、マニフェストの中にではありません。

第二に、メトリクスです。vCenter は統計を何か月も保持し、「先週の火曜に何が起きたか」という問いにグラフで答えます。`metrics-server` は直近の数分を保持するだけで、それ以上はありません — まさに HPA に供給するために設計されています。履歴のためには Prometheus をセットアップしなければならず、それは別の仕事です（ラボ 14）。

第三に、コストの予測可能性です。4 コアのマシンは一定の額がかかり、それは前もって分かっています。オートスケーリングは、状態の悪い日には通常の日の 6 倍の消費になることを意味します。`maxReplicas` は細かな性能チューニングのつまみではなく、あなたのお金のヒューズであり、そう扱うべきものです。
