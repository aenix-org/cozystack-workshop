#!/usr/bin/env bash
# ラボ3のチェック: オートスケーリング。
#
# 「hpa.yaml が適用されているか」ではなく、仕組みが生きていて判断を下せる状態かを確認する:
#   - コンテナに requests.cpu があること。なければパーセンテージを計算する基準がない;
#   - HPA が存在し、まさに我々の Deployment を対象にしていること;
#   - レンジが意味を持って設定されていること（maxReplicas が1より大きい、でなければ増える余地がない）;
#   - メトリクスが本当に収集されていること: ステータスに <unknown> ではなく数値があること;
#   - スケーリングが既に発動していること、つまり実際に負荷がかけられたこと。
#
# スクリプトは何も変更しない。使い捨ての Pod は、Fortio がクラスタ内部から
# 応答するかを確認するためだけに起動し、自分自身を削除する。
#
# VM上で、このラボのフォルダから、学習用クラスタ `lab` へのアクセスで実行する
# （管理クラスタ上のテナントに対してではない）:
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# ここでは COZY_TENANT 変数は不要: ラボ全体が `lab` クラスタ内部で進む。
#
# 後片付けの前に実行すること。一部のチェックは既に起きた成長の痕跡に依存しており、
# それらは HPA オブジェクトと一緒に存在する: HPA を削除すると、証明する材料がなくなる。

# レポートのヘッダーと、スクリプトの隣に置かれるファイル名 report-<ラボ>-<日付>.md に入る。
LAB_NAME="03-scale"
LAB_TITLE="ラボ3 · 負荷とオートスケーリング"
# 共通ライブラリ: ok / fail / warn / evidence / finish、クラスタ内部からのクエリ、
# レポートの書き出し。パスは現在のディレクトリではなく、スクリプト自身の場所から計算する。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG がないと kubectl はVM上でクラスタを探し、本当の原因が読み取れない単一の
# エラーですべてを落としてしまう。すぐに停止する。
need_kubeconfig

# アプリ名と HPA 名がこのラボで一致していることが、うっかり同じ名前を二度書いた
# ように見えないよう、名前を変数に切り出している。
APP=rickroll
HPA=rickroll

# --- スケーリング対象が所定の位置にあること -----------------------------------------
# ラボ1のアプリ — HPA が管理する対象。これがないと、以降のすべての
# チェックが連鎖的に失敗し、参加者は1つの明確なエラーの代わりに10個ものエラーを受け取る
# ため、ここがスクリプトが早期終了する唯一の場所。
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "アプリケーション ${APP} がクラスタにありません — スケールする対象がありません" \
       "デプロイしてください: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "アプリケーション ${APP} は所定の位置にあります"

# --- requests.cpu: これがないと HPA はパーセンテージを計算しない ------------------------
# 「HPA が動かない」の最も多い原因で、マニフェストからは見えない:
# オブジェクトは正常に作成されるが、TARGETS は永遠に <unknown> のまま。
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "コンテナに requests.cpu = ${REQ_CPU} が設定されています — パーセンテージを計算する基準があります"
  evidence "コンテナのリソース" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-未設定}"
else
  fail "コンテナ ${APP} に requests.cpu が設定されていません" \
       "Utilization ベースの HPA はこれなしでは動きません。../01-deploy/rickroll.yaml を再適用してください"
fi

# --- HPA そのもの ---------------------------------------------------------------
# オブジェクトの有無だけでなく、何を対象にしているかも確認する。scaleTargetRef に
# タイプミスがある HPA は正常に作成され、一覧では動作しているように見えるが、ラボ全体で
# 存在しないアプリケーションを管理してしまう。
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "クラスタに ${HPA} という名前の HorizontalPodAutoscaler がありません" \
       "適用してください: kubectl apply -f hpa.yaml （チェックは後片付けの前に実行）"
  evidence "オートスケーリング関連で存在するもの" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA} は Deployment/${APP} を対象にしています"
else
  fail "HPA ${HPA} は Deployment/${APP} ではなく ${TARGET_KIND}/${TARGET_NAME} を管理しています" \
       "hpa.yaml の scaleTargetRef を修正して再適用してください"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "レンジが設定されています: ${MINR} から ${MAXR} 個まで — 増える余地があります"
else
  fail "レンジの上限が ${MAXR:-未設定} です — 増える余地がありません" \
       "hpa.yaml では maxReplicas が1より大きくなければなりません"
fi

# --- メトリクスのターゲット -------------------------------------------------------
# ここは fail ではなく warn: AverageValue の方式（しきい値をミリコアで指定）も動作するもので、
# ラボは2つのうち片方だけを扱う。これで不合格にするのは正しくない。
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "しきい値が設定されています: requests.cpu の ${TGT_VAL}% (${REQ_CPU:-?})"
else
  warn "しきい値が requests に対するパーセンテージで設定されていません（タイプ: ${TGT_TYPE:-なし}）" \
       "ラボは Utilization 方式を扱います。動作には影響しません"
fi

# --- 最重要: メトリクスが本当に収集されていること -----------------------------------
# まさにここで「オブジェクトが作成された」と「仕組みが動いている」の違いが見える。
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "メトリクスが収集されています: 現在の負荷は requests の ${CUR_UTIL}%、HPA は判断を下しています"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA は判断を下しています（ScalingActive=True）。現在のメトリクス値はまだ報告されていません"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA がメトリクスを受け取っていません — TARGETS は <unknown> になり、判断する材料がありません" \
       "apply 後の最初の2分間はこれが正常です。待ってから再試行してください。解消しない場合は kubectl top pods と kubectl describe hpa ${HPA}"
  evidence "HPA がアクティブでない理由" "${REASON:-ステータスに理由が示されていません}"
fi

evidence "HPA の状態" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server が直接応答すること --------------------------------------
# 前のチェックを別の側面から重ねて確認し、2つの異なる故障を切り分ける:
# 「クラスタ全体にメトリクスがない」と「メトリクスはあるが HPA が到達できていない」。
# 前者はクラスタ管理者が、後者は参加者が自分のマニフェストで直す。
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` は Pod がないと「No resources found」を出力して 0 を返す —
# 空の明示的なチェックがないと、メトリクスが全くない場合でも緑になっていた。
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top が Pod の消費量を返しません" \
       "クラスタに動作する metrics-server がありません — これなしでは CPU ベースのオートスケーリングは不可能です"
  evidence "kubectl top の応答" "$TOP"
else
  ok "metrics-server が ${APP} Pod の消費量を返しています"
  evidence "各コピーの消費量" "$TOP"
fi

# --- スケーリングが実際に発動したこと ------------------------------------------------
# lastScaleTime は HPA 自身と同じだけ存続するため、このチェックはクラスタのイベントが
# 失効したかどうかに依存しない。
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# タイムスタンプ1つでは不十分: これはスケールダウン時にも設定される、つまり
# レプリカを手で増やして HPA に余分を削除させた人にも現れる。我々が探すのは
# まさに負荷による成長 — しきい値を超えたイベント。
#
# その逆に: タイムスタンプ自体が常に残るわけではない。1時間前に負荷をかけた
# クラスタでは、lastScaleTime が空でイベントがまだ生きていることがある — そのため
# イベントを先にチェックする、でなければ完了したラボが誤って不合格になる。
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA は負荷のためにコピー数を増やしました — しきい値超過のイベントが所定の位置にあります"
  evidence "スケーリング" "スケールアップのイベント数: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-なし}
currentReplicas: ${CUR_REPL:-不明}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA はコピー数を変更しました（最後: ${LAST_SCALE}）"
  evidence "スケーリングのタイムスタンプ" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-不明}"
else
  fail "オートスケーリングが動作した痕跡がありません" \
       "Fortio から負荷をかけてください: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: ラボ4で必要 ------------------------------------------------
# ラボ3自体にはもう関係ないため、fail ではなく warn。狙いは、参加者が
# ジェネレーターの不在を負荷をかけた展開の途中ではなくここで知ること。途中で
# 停止して展開するのは都合が悪いため。
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "負荷ジェネレーター Fortio は動作し、クラスタ内部から応答しています"
  else
    warn "Fortio はデプロイされていますが、Web インターフェイスが応答しませんでした" \
         "確認してください: kubectl rollout status deployment/fortio と kubectl logs deploy/fortio"
  fi
else
  warn "Fortio がクラスタにありません" \
       "ラボ4を行う予定なら、そこで必要になります: kubectl apply -f fortio.yaml"
fi

finish
