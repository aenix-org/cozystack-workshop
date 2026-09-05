#!/usr/bin/env bash
# ラボ1のチェック: アプリケーションがデプロイされ、実質的に動作していること。
#
# ここでの「実質的に」とは: ページが実際にHTTPで配信され、そこにPod名が
# 差し込まれ、その名前が本当に実行中のコピーの名前と一致していること、を意味する。
# Deploymentオブジェクトの存在確認は無意味である — 存在していても動作していない
# 場合があるからだ。
#
# ノートPC上で、このラボのフォルダから、学習用クラスタ `lab` へのアクセスで実行する
# (管理クラスタ上のテナントに対してではない):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# ここでは COZY_TENANT 変数は不要: ラボ全体が `lab` クラスタ内で完結する。
#
# スクリプトはクラスタ内を一切変更しない — 読み取りとHTTPリクエストの送信のみを行う。
# 後片付けの前に実行すること: アプリケーションを削除した後ではチェックする対象がなくなる。

# この2つの変数は lib.sh が拾い上げる — レポートのヘッダーと、スクリプトが自身の
# 隣に置くファイル名 report-<ラボ>-<日付>.md に反映される。
LAB_NAME="01-deploy"
LAB_TITLE="ラボ1 · はじめてのアプリケーション"
# 共通チェックライブラリ: ok / fail / warn / evidence / finish はここから来る。
# クラスタ内からのページ取得とレポート書き込みも同様。パスはスクリプト自身の
# 置き場所から計算されるため、どのディレクトリから実行しても同じように動く。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG が設定されていなければ直ちに停止する。設定がないと kubectl は
# ノートPC自体でクラスタを探し、見つけられず、同じエラーですべてのチェックを
# 次々と倒してしまい、本当の原因が見えなくなる。
need_kubeconfig

# --- アプリケーションオブジェクト ------------------------------------------------------
# 最初の関門: アプリケーションがそもそも作成され、少なくとも1つのコピーが準備完了に
# 達していること。Deploymentの存在ではなく .status.readyReplicas を見る: オブジェクトは
# 瞬時に作成され常に成功するが、準備完了はコピーが起動し、準備完了チェックを通過し、
# 応答できる状態になったことを意味する。
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # 特別なケース: オブジェクトは存在するが、要求コピー数がゼロ。「準備完了のコピーが
    # 1つもない (必要数0)」というメッセージはナンセンスに聞こえてしまう。
    fail "アプリケーションが停止しています — 要求コピー数が0です" \
         "コピーを戻してください: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "アプリケーションはデプロイ済み、準備完了のコピーは ${DESIRED} 中 ${READY}"
    # 詰まったロールアウトはサービスを落とさない: 古いコピーが動き続け、readyReplicas は
    # 1のまま。このチェックがないと、参加者は緑のチェックマークと、永遠に ErrImagePull で
    # 詰まったデプロイメントを抱えたまま去ってしまう。
    # ProgressDeadlineExceeded だけでなくコピー自体を見る: デッドラインは10分後に
    # 発火するが、スクリプトはすぐに実行される。その間も古いコピーは動き、readyReplicas は
    # 1のままなので、このチェックがないと参加者は緑のチェックマークと、ImagePullBackOff で
    # 詰まったデプロイメントを抱えたまま去ってしまう。
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "ロールアウトが詰まっています: 新しいコピーが起動せず、古いコピーだけが動いています" \
           "kubectl get pods -l app=rickroll を確認してください — 通常はイメージが取得できていません。動作状態に戻すには: kubectl apply -f rickroll.yaml"
      evidence "起動しないコピー" "${STUCK:-理由は Deployment のステータスにあります: $PROG_REASON}"
    fi
  else
    fail "アプリケーションは作成されましたが、準備完了のコピーが1つもありません (必要数 ${DESIRED})" \
         "kubectl get pods -l app=rickroll と kubectl describe deployment rickroll を確認してください"
    evidence "Podの状態" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "rickroll という名前の Deployment が見つかりません" \
       "マニフェストを適用してください: kubectl apply -f rickroll.yaml"
fi

# --- 設定とページ ---------------------------------------------------
# どちらの ConfigMap もアプリケーションと同じファイルで作成されるため、失われるのは
# アプリケーションと一緒か、手動削除の場合だけである。ページが壊れたときに参加者が
# 何が足りないのかをすぐ分かるよう、個別にチェックする: rickroll-conf がないと nginx は
# Pod名を差し込めず、rickroll-page-v1 がないとラボ4で第2バージョンと比較する対象がなく、
# ロールバックする先もない。
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "設定は所定の場所にあります: ConfigMap ${cm}"
  else
    fail "ConfigMap ${cm} が見つかりません" \
         "これは同じファイルで作成されます: kubectl apply -f rickroll.yaml"
  fi
done

# --- 恒久的なアドレス -------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # エンドポイントのない Service は典型的で気づきにくい故障である: オブジェクトは
  # 存在するが、Pod のラベルがセレクタと一致せず、アドレスの背後には何もない。
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "恒久的なアドレスは機能しています、その背後のコピー数: ${EPS_N}"
    evidence "サービスの背後のアドレス" "$EPS"
  else
    fail "Service rickroll は存在しますが、その背後にコピーが1つもありません" \
         "通常の原因は Pod のラベルがサービスのセレクタと一致しないことです — app: rickroll を確認してください"
  fi
else
  fail "rickroll という名前の Service が見つかりません" \
       "これは同じファイルで作成されます: kubectl apply -f rickroll.yaml"
fi

# --- 肝心なこと: ページが実際に配信される -------------------------------------
# このチェックのためにすべてを行ってきた。これまでのチェックはすべて、クラスタ内の
# オブジェクトが正しく記述されていることを言うにすぎない。このチェックは、ユーザーが
# ページを受け取れることを言う。リクエストはクラスタの内側から、使い捨ての Pod で行う:
# 外からは rickroll のアドレスは存在せず、ここで port-forward を使うのはクラスタではなく
# あなたのノートPC のチェックになってしまう。
# 複数回リクエストする: サービスの背後に複数のコピーがある場合、1回のサンプリングでは
# 差し込まれたコピーに当たらず、他人のコンテンツでチェックが緑になることがある。
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# マーカーはページごとに厳密に1回だけ現れなければならない。さもないと応答カウンタが
# 嘘をつく: 「Never Gonna Give You Up」は <title> にも <h1> にもあり、二重計上を招いた。
ANSWERS="$(printf '%s' "$BODY" | grep -c '対応したPod')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "アプリケーションは HTTP で応答し、自身のページを配信しています (${ANSWERS} 件のリクエストで確認)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "サービスの背後で応答しているのはあなたのアプリケーションだけではありません: 自身のページが ${TOTAL_LINES} 回中 ${ANSWERS} 回届きました" \
       "誰か他の者が app=rickroll ラベルを付けています — kubectl get pods -l app=rickroll を確認し、余分なものを削除してください"
else
  fail "アプリケーションが期待されるページを配信しませんでした" \
       "手動で確認してください: kubectl port-forward svc/rickroll 8080:80、その後 http://localhost:8080 を開いてください"
  evidence "ページの代わりに返ってきたもの" "$(printf '%s' "$BODY" | head -20)"
fi

# --- Pod名の差し込み -------------------------------------------------------
# このラボはまさにこのために作られた: ページ内の名前が実際の Pod と一致しなければならない。
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# app=rickroll ラベルを付けたすべてではなく、アプリケーションの ReplicaSet が管理する
# Pod を取る。さもないと、そのラベルを持つ外部の Pod が「本物」のリストに入り込み、
# 自分自身を裏付けてしまう — 検証済み、詐称者がこの方法でチェックを通過した。
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "外部の Pod が app=rickroll ラベルを付けています — それらは負荷分散に入り込みます" \
       "余分なものを削除してください: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "アプリケーションのラベルを持つ外部の Pod" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "ページに Pod 名がありません" \
       "ConfigMap rickroll-conf が差し込まれたか確認してください — その中に sub_filter '__POD__' '\$hostname' の行があります"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "Pod 名が差し込まれませんでした — ページにプレースホルダ __POD__ が残っています" \
       "nginx が sub_filter を適用しませんでした: 設定ボリュームが /etc/nginx/conf.d にマウントされているか確認してください"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "Pod 名が差し込まれ、実際に実行中のコピーと一致しています: ${SERVED_BY}"
  evidence "リクエストに応答したのは誰か" "$SERVED_BY"
  evidence "実行中のコピー" "$REAL_PODS"
else
  fail "ページは Pod「${SERVED_BY}」を名乗っていますが、そのような Pod はクラスタに存在しません" \
       "リクエストとチェックの間にコピーが再作成された可能性があります — スクリプトをもう一度実行してください"
fi

# --- 準備完了チェックが設定されている ------------------------------------------
# これがないと、バージョンのロールアウトを扱うラボで停止が発生し、参加者は我々が嘘を
# ついたと判断してしまう。
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "準備完了チェックが設定されています (${PROBE_PATH}) — 更新は無停止で行われます"
else
  warn "アプリケーションに準備完了チェックがありません" \
       "無停止更新を扱うラボ4は、このようなアプリケーションではエラーになります — rickroll.yaml から readinessProbe を戻してください"
fi

finish
