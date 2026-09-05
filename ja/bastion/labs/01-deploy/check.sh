#!/usr/bin/env bash
# ラボ1のチェック: アプリケーションがデプロイされ、実質的に動作していること。
#
# ここでの「実質的に」とは、ページが実際にHTTPで配信され、そこにPod名が
# 差し込まれ、その名前が実際に稼働しているレプリカの名前と一致すること。
# Deploymentオブジェクトの存在を確認するのは無意味 — 存在していても動作しないことがある。
#
# 仮想マシン上で、このラボのフォルダから、学習クラスタ `lab` へのアクセスで実行する
# （管理クラスタ上のテナントではない）:
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# ここではCOZY_TENANT変数は不要: ラボ全体がクラスタ `lab` の内部で動く。
#
# スクリプトはクラスタ内で何も変更しない — 読み取りとHTTPリクエスト送信のみ。
# クリーンアップ前に実行すること: アプリケーション削除後は確認するものがなくなる。

# この2つの変数はlib.shが拾う — レポートのヘッダーと、スクリプトが自身の隣に置く
# ファイル名 report-<ラボ>-<日付>.md に入る。
LAB_NAME="01-deploy"
LAB_TITLE="ラボ1 · 最初のアプリケーション"
# 共通チェックライブラリ: ここから ok / fail / warn / evidence / finish、
# クラスタ内部からのページリクエスト、レポート書き込みが来る。パスはスクリプト自身が
# 置かれている場所から計算されるので、どのディレクトリから実行しても同じように動く。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIGが設定されていなければ即座に停止する。設定がないとkubectlは仮想マシン
# 自身の上でクラスタを探し、見つからず、同じエラーで全チェックを次々に落とす。
# そのエラーからは本当の原因が見えない。
need_kubeconfig

# --- アプリケーションオブジェクト --------------------------------------------
# 第一の防衛線: アプリケーションが実際に作成され、少なくとも1つのレプリカが準備完了に達したこと。
# Deploymentの単なる存在ではなく .status.readyReplicas を見る: オブジェクトは
# 即座に、常に成功して作成されるが、準備完了はレプリカが立ち上がり、
# 準備完了プローブを通過し、応答できることを意味する。
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # 特殊なケース: オブジェクトは存在するが、要求されたレプリカ数がゼロ。
    # 「準備完了のレプリカが1つもない（0が必要）」というメッセージは無意味に聞こえる。
    fail "アプリケーションが停止中 — 要求レプリカ数が0" \
         "レプリカを戻す: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "アプリケーションがデプロイ済み、準備完了レプリカ ${READY} / ${DESIRED}"
    # 詰まったロールアウトはサービスを落とさない: 古いレプリカが動き続け、
    # readyReplicasは1のまま。このチェックがないと、参加者は緑のチェックマークと
    # 永久にErrImagePullで詰まったデプロイメントを持って去っていく。
    # ProgressDeadlineExceededだけでなくレプリカ自体を見る: デッドラインは
    # 10分後に発火するが、スクリプトはすぐに実行される。その間も古いレプリカは
    # 動き続け、readyReplicasは1のまま。このチェックがないと参加者は緑のチェックマークと
    # ImagePullBackOffで詰まったデプロイメントを持って去っていく。
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "ロールアウトが詰まっている: 新しいレプリカが立ち上がらず、古いものだけが動いている" \
           "kubectl get pods -l app=rickroll を見る — たいていイメージが取得できていない; 動作状態に戻す: kubectl apply -f rickroll.yaml"
      evidence "起動しないレプリカ" "${STUCK:-原因はDeploymentのステータス内: $PROG_REASON}"
    fi
  else
    fail "アプリケーションは作成されたが、準備完了のレプリカが1つもない（${DESIRED} が必要）" \
         "kubectl get pods -l app=rickroll と kubectl describe deployment rickroll を見る"
    evidence "Podの状態" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "rickroll という名前のDeploymentが見つからない" \
       "マニフェストを適用する: kubectl apply -f rickroll.yaml"
fi

# --- 設定とページ ------------------------------------------------------------
# 両方のConfigMapはアプリケーションと同じファイルで作成されるので、消えるのは
# アプリケーションと一緒か、手動削除のときだけ。それぞれ別々にチェックするのは、
# ページが壊れたときに参加者がすぐに何が欠けているかを見られるようにするため:
# rickroll-conf がないとnginxはPod名を差し込まず、rickroll-page-v1 がないと
# ラボ4で第2バージョンと比較するものがなく、ロールバックする先もない。
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "設定が揃っている: ConfigMap ${cm}"
  else
    fail "ConfigMap ${cm} が見つからない" \
         "同じファイルで作成される: kubectl apply -f rickroll.yaml"
  fi
done

# --- 固定アドレス ------------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # エンドポイントのないServiceは典型的で気づきにくい故障: オブジェクトは存在するが、
  # Podのラベルがセレクタと一致せず、アドレスの後ろは空っぽ。
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "固定アドレスが機能している、後ろのレプリカ数: ${EPS_N}"
    evidence "サービスの後ろのアドレス" "$EPS"
  else
    fail "Service rickroll は存在するが、後ろにレプリカが1つもない" \
         "たいていの原因はPodのラベルがサービスのselectorと一致しないこと — app: rickroll を照合する"
  fi
else
  fail "rickroll という名前のServiceが見つからない" \
       "同じファイルで作成される: kubectl apply -f rickroll.yaml"
fi

# --- 本題: ページが実際に配信される ------------------------------------------
# すべてはこのチェックのために仕込まれた。これまでのチェックは、クラスタ内の
# オブジェクトが正しく記述されていることを言うだけ; このチェックは、ユーザーが
# ページを受け取ることを言う。リクエストはクラスタの内部から、使い捨てPodで行う:
# 外部からはrickrollのアドレスは存在せず、port-forwardはクラスタではなく
# あなたの仮想マシンのチェックになってしまう。
# 複数回リクエストする: サービスの後ろに複数のレプリカがあると、単一のサンプルでは
# 差し替えられたものに当たらず、他人のコンテンツでチェックが緑になることがある。
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# マーカーはページごとにちょうど1回だけ現れなければならない、さもないと応答カウンタが嘘をつく:
# 「Never Gonna Give You Up」は <title> にも <h1> にもあり、二重カウントを起こしていた。
ANSWERS="$(printf '%s' "$BODY" | grep -c '対応したPod')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "アプリケーションがHTTPで応答し、自分のページを配信している（${ANSWERS} 件のリクエストを確認）"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "サービスの後ろで応答しているのはあなたのアプリケーションだけではない: 自分のページは ${TOTAL_LINES} 件中 ${ANSWERS} 件返ってきた" \
       "誰か他の人が app=rickroll ラベルを付けている — kubectl get pods -l app=rickroll を見て余分なものを削除する"
else
  fail "アプリケーションが期待したページを配信しなかった" \
       "手動で確認する: kubectl port-forward svc/rickroll 8080:80、その後 http://localhost:8080 を開く"
  evidence "ページの代わりに返ってきたもの" "$(printf '%s' "$BODY" | head -20)"
fi

# --- Pod名の差し込み ---------------------------------------------------------
# このラボが作られた目的: ページ内の名前が実際のPodと一致しなければならない。
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# アプリケーションのReplicaSetが管理するPodを取る、app=rickroll ラベルを付けた
# すべてではない。さもないとそのラベルを付けた無関係なPodが「本物」のリストに入り、
# 自分自身を裏付けてしまう — 検証済み、偽物がそうやってチェックを通過した。
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "無関係なPodが app=rickroll ラベルを付けている — それらはロードバランシングに含まれる" \
       "余分なものを削除する: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "アプリケーションのラベルを付けた無関係なPod" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "ページにPod名がない" \
       "ConfigMap rickroll-conf が差し込まれたか確認する — その中に sub_filter '__POD__' '\$hostname' の行がある"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "Pod名が差し込まれなかった — ページにプレースホルダ __POD__ が残っている" \
       "nginxがsub_filterを適用しなかった: 設定のボリュームが /etc/nginx/conf.d にマウントされているか確認する"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "Pod名が差し込まれ、実際に稼働しているレプリカと一致している: ${SERVED_BY}"
  evidence "誰がリクエストを処理したか" "$SERVED_BY"
  evidence "稼働中のレプリカ" "$REAL_PODS"
else
  fail "ページはPodを「${SERVED_BY}」と呼んでいるが、クラスタにそのようなPodは存在しない" \
       "リクエストとチェックの間にレプリカが再作成された可能性がある — スクリプトをもう一度実行する"
fi

# --- 準備完了プローブが設定されている ----------------------------------------
# これがないとバージョンのロールアウトについてのラボでダウンタイムが発生し、参加者は我々が嘘をついたと判断する。
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "準備完了プローブが設定されている（${PROBE_PATH}）— 更新はダウンタイムなしで進む"
else
  warn "アプリケーションに準備完了プローブがない" \
       "ゼロダウンタイム更新についてのラボ4はこのようなアプリケーションではエラーを出す — rickroll.yaml から readinessProbe を戻す"
fi

finish
