#!/usr/bin/env bash
# ラボ3のチェック: オートスケーリング。
#
# 「hpa.yaml が適用された」ことではなく、仕組みが生きていて判断を下せる状態かを検証する:
#   - コンテナに requests.cpu があること。なければパーセントを計算する基準がない;
#   - HPA が存在し、まさに我々の Deployment を対象にしていること;
#   - レンジが意味のある形で設定されていること（maxReplicas が1より大きいこと。さもなければ増える余地がない）;
#   - メトリクスが実際に収集されていること: ステータスに <unknown> ではなく数値が入っていること;
#   - スケーリングがすでに発動していること。つまり負荷が実際にかけられたこと。
#
# スクリプトは何も変更しない。使い捨ての Pod は、Fortio がクラスタ内部から応答するかを
# 確認するためだけに起動し、自分自身を後片付けする。
#
# ノートPC上で、このラボのフォルダから、学習クラスタ `lab` へのアクセスを使って実行する
# （管理クラスタ上のテナントではない）:
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# ここでは COZY_TENANT 変数は不要: ラボ全体が `lab` クラスタ内部で進行する。
#
# 後片付けの前に実行すること。一部のチェックはすでに起きた増加の痕跡に依存しており、
# それらは HPA オブジェクトとともに存在する: それを削除すると、証明する手段がなくなる。

# レポートのヘッダーと、スクリプトの隣のファイル名 report-<lab>-<date>.md に入る。
LAB_NAME="03-scale"
LAB_TITLE="ラボ3 · 負荷とオートスケーリング"
# 共通ライブラリ: ok / fail / warn / evidence / finish、クラスタ内部からのクエリ、
# レポートの書き込み。パスはカレントディレクトリではなく、スクリプト自身の場所から計算される。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG がないと kubectl はノートPC上のクラスタを探し、すべてを1つのエラーにまとめて吐き出す。
# そのエラーからは本当の原因が読み取れない。すぐに停止する。
need_kubeconfig

# アプリ名と HPA 名がこのラボで一致していることが、うっかり同じ名前を2回書いたように
# 見えないよう、名前を変数に切り出している。
APP=rickroll
HPA=rickroll

# --- スケーリング対象が存在する -----------------------------------------
# ラボ1のアプリが HPA の管理対象。これが無いと、以降のチェックが連鎖して崩れ、
# 参加者は1つの明快なエラーの代わりに十数個のエラーを受け取る。
# そのため、ここがスクリプトが早期終了する唯一の場所。
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "アプリ ${APP} がクラスタに存在しない — スケールする対象がない" \
       "デプロイしてください: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "アプリ ${APP} は存在する"

# --- requests.cpu: これが無いと HPA はパーセントを計算できない ------------------------
# 「HPA が動かない」の最も多い原因で、マニフェストからは見えない:
# オブジェクトは正常に作られるが、TARGETS が永遠に <unknown> のまま。
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "コンテナに requests.cpu = ${REQ_CPU} が設定されている — パーセントを計算する基準がある"
  evidence "コンテナのリソース" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-未設定}"
else
  fail "コンテナ ${APP} に requests.cpu が設定されていない" \
       "Utilization ベースの HPA はこれ無しでは動作しない; ../01-deploy/rickroll.yaml を再適用してください"
fi

# --- HPA そのもの ---------------------------------------------------------------
# オブジェクトの存在だけでなく、何を対象にしているかも確認する。scaleTargetRef に
# タイプミスがある HPA は正常に作成され、一覧上は動作しているように見えるが、
# ラボ全体を通して存在しないアプリを管理してしまう。
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "クラスタに名前 ${HPA} の HorizontalPodAutoscaler が存在しない" \
       "適用してください: kubectl apply -f hpa.yaml （チェックは後片付けの前に実行）"
  evidence "オートスケーリング関連で存在するもの" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA} は Deployment/${APP} を対象にしている"
else
  fail "HPA ${HPA} は Deployment/${APP} ではなく ${TARGET_KIND}/${TARGET_NAME} を管理している" \
       "hpa.yaml の scaleTargetRef を修正して再適用してください"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "レンジが設定されている: ${MINR} から ${MAXR} 個まで — 増える余地がある"
else
  fail "レンジの上限が ${MAXR:-未設定} — 増える余地がない" \
       "hpa.yaml の maxReplicas は1より大きくする必要がある"
fi

# --- メトリクスによる目標 -------------------------------------------------------
# ここは fail ではなく warn: AverageValue の方式（しきい値をミリコアで指定）も有効で、
# ラボは2つのうち片方だけを扱う。それで不合格にするのは事実に反する。
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "しきい値が設定されている: requests.cpu (${REQ_CPU:-?}) の ${TGT_VAL}%"
else
  warn "しきい値が requests のパーセントで設定されていない（タイプ: ${TGT_TYPE:-なし}）" \
       "ラボは Utilization の方式を扱う; これは動作には影響しない"
fi

# --- 最重要: メトリクスが実際に収集されている -----------------------------------
# まさにここで「オブジェクトが作られた」と「仕組みが動いている」の違いが見える。
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "メトリクスが収集されている: 現在の負荷は requests の ${CUR_UTIL}%、HPA は判断を下している"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA は判断を下している (ScalingActive=True)、現在のメトリクス値はまだ報告されていない"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA がメトリクスを受け取っていない — TARGETS は <unknown> になり、判断する材料がない" \
       "apply 後の最初の2分間は正常なので、待ってから再試行してください; それでも通らなければ — kubectl top pods と kubectl describe hpa ${HPA}"
  evidence "HPA がアクティブでない理由" "${REASON:-ステータスに理由が記載されていない}"
fi

evidence "HPA の状態" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server が直接応答する --------------------------------------
# 前のチェックを別の角度から二重に行い、2つの異なる障害を切り分ける:
# 「クラスタ全体にメトリクスが無い」と「メトリクスはあるが HPA が届いていない」。
# 前者はクラスタ管理者が、後者は参加者が自分のマニフェストで直す。
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` は Pod が無いとき "No resources found" を出力して 0 を返す —
# 空かどうかの明示的なチェックがないと、メトリクスが全く無い状態でも緑になっていた。
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top が Pod の消費量を返さない" \
       "クラスタに動作している metrics-server が無い — これ無しでは CPU ベースのオートスケーリングは不可能"
  evidence "kubectl top の出力" "$TOP"
else
  ok "metrics-server が ${APP} Pod の消費量を返している"
  evidence "レプリカの消費量" "$TOP"
fi

# --- スケーリングが実際に発動した --------------------------------------
# lastScaleTime は HPA 自体と同じだけ存在するので、このチェックは
# クラスタのイベントが期限切れになったかどうかに依存しない。
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# タイムスタンプ1つでは不十分: これはスケールダウン時にも設定される。つまり
# レプリカを手で増やして HPA に余分を削らせた人にも付く。我々が探すのは
# まさに負荷によって駆動された増加 — しきい値を超えたイベント。
#
# 逆に: タイムスタンプ自体が常に存在するとは限らない。1時間前に負荷をかけた
# クラスタでは、lastScaleTime が空でもイベントはまだ生きていることがある — だから
# イベントを先にチェックする。さもなければ完了したラボが誤って不合格になる。
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA は負荷のためにレプリカ数を増やした — しきい値超過のイベントが存在する"
  evidence "スケーリング" "増加イベント: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-なし}
currentReplicas: ${CUR_REPL:-不明}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA はレプリカ数を変更した（最後: ${LAST_SCALE}）"
  evidence "スケーリングのタイムスタンプ" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-不明}"
else
  fail "オートスケーリングが動作した痕跡がない" \
       "Fortio から負荷をかけてください: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: ラボ4で必要 ------------------------------------------------
# ラボ3そのものにはもう関係しないので fail ではなく warn。狙いは、参加者が
# 負荷をかけている最中の展開の途中ではなく、ここでジェネレータの喪失に気づくこと。
# 負荷中に手を止めてデプロイするのは都合が悪いため。
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "負荷ジェネレータ Fortio は動作し、クラスタ内部から応答している"
  else
    warn "Fortio はデプロイされているが、Web インターフェースが応答しなかった" \
         "確認してください: kubectl rollout status deployment/fortio と kubectl logs deploy/fortio"
  fi
else
  warn "Fortio がクラスタに無い" \
       "ラボ4を行う予定なら、そこで必要になる: kubectl apply -f fortio.yaml"
fi

finish
