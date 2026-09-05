#!/usr/bin/env bash
# ラボ4のチェック: 新しいバージョンのロールアウトとロールバック。
#
# 入力されたコマンドではなく、本質をチェックする:
#   - アプリの履歴に複数のリビジョンがある、つまりバージョンが実際に変更された;
#   - 2つ目のバージョンのConfigMapが、1つ目を編集したものではなく、別オブジェクトとしてクラスタに存在する;
#   - コンテナにreadinessProbeがある — これがないとゼロダウンタイムは再現できない;
#   - ロールアウトが最後まで完了しており、途中で止まっていない;
#   - Serviceが返すページが、仕様(spec)が参照するConfigMapと一致する。
#     これは「仕様はロールバックしたが、Podが再作成されなかった」ケースを捕らえる。
#
# スクリプトは何も変更しない。使い捨てのPodはクラスタ内部からページを取得するためだけに
# 必要で、自分自身を削除する。
#
# ノートPC上で、このラボのフォルダから、学習用クラスタ `lab` へのアクセスを使って実行する
# (管理クラスタ上のテナントではない):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# ここではCOZY_TENANT変数は不要: ラボ全体がクラスタ `lab` の内部で進行する。
#
# クリーンアップの前、かつロールバックが完了した後に実行すること: リビジョン履歴は
# Deploymentと共に存在し、それと共に消える。

# これらはレポートのヘッダーと、スクリプトの隣のファイル名 report-<ラボ>-<日付>.md に入る。
LAB_NAME="04-rollout"
LAB_TITLE="ラボ4 · 新しいバージョンのロールアウトとロールバック"
# 共通ライブラリ: ok / fail / warn / evidence / finish、クラスタ内部からのリクエスト、
# レポートの書き込み。パスは現在のディレクトリではなく、スクリプト自身の場所から解決される。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIGがないとkubectlはノートPC上のクラスタを探し、本当の原因が見えない一つのエラーで
# すべてを失敗させる。すぐに停止する。
need_kubeconfig

APP=rickroll

# --- アプリが存在し、動作状態に達している ------------------
# アプリがなければチェックするものがないので、ここが唯一の早期終了となる。
# この先は、準備完了レプリカの数だけでなく、Progressing条件の理由も見る:
# NewReplicaSetAvailable はロールアウトが完了したことを意味する。準備完了レプリカ
# だけでは不十分 — 更新が止まっていると古いバージョンが動き、カウンタは期待した数を
# 示すが、新しいレプリカは一度も起動していない。
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "アプリ ${APP} がクラスタにありません" \
       "デプロイしてください: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "ロールアウトが完了しました: 準備完了レプリカ ${WANT} 中 ${HAVE}"
else
  fail "アプリが完了状態にありません (${WANT} 中 ${HAVE} が準備完了、理由: ${PROG_REASON:-なし})" \
       "ロールアウトが止まっている場合はロールバックで復旧してください: kubectl rollout undo deployment/${APP}"
fi
evidence "アプリの状態" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: ゼロダウンタイムの代償として支払うもの -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "コンテナにreadinessProbeがあります (${PROBE}) — レプリカの入れ替えは準備完了後にのみ行われます"
else
  fail "コンテナにreadinessProbeがありません" \
       "これがないとクラスタは準備できていないレプリカにトラフィックを流します; ../01-deploy/rickroll.yaml を適用してください"
fi

# --- バージョンが別々のオブジェクトとして作られている --------------------------------------
# ページの両バージョンは、2つの別々のConfigMapとしてクラスタに存在しなければならない。
# 代わりに rickroll-page-v1 をその場で編集した人は、画面に新しいページを見て
# ラボが完了したと判断する — しかしロールバックする先がなく、
# レプリカの入れ替えもリビジョン履歴への記録も一切起こらない。
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2 が別オブジェクトとしてクラスタに存在します"
else
  fail "クラスタに ConfigMap rickroll-page-v2 がありません" \
       "適用してください: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "1つ目のページバージョンも保持されています — ロールバックする先があります"
else
  warn "ConfigMap rickroll-page-v1 がクラスタに見つかりません" \
       "これがないと1つ目のバージョンへのロールバックはPodを起動できません: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- リビジョン履歴 -------------------------------------------------------
# 履歴の行数ではなく、最新リビジョンの番号を見る。ロールバックは
# 新しいReplicaSetを追加しない — 古いものを再利用してその番号を上げるので、
# ロールバック後も履歴の行数は同じだが、番号は増える。
#   1 — 仕様は一度も変更されていない
#   2 — バージョンが切り替えられた
#   3以上 — 切り替えて元に戻した
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "アプリの最新リビジョンは ${REV_MAX}: バージョンを切り替えて元に戻しました"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "最新リビジョンは 2: ロールアウトは完了、ロールバックはまだ" \
       "1つ目のバージョンに戻してください: kubectl rollout undo deployment/${APP}"
else
  fail "最新リビジョンは ${REV_MAX}: アプリの仕様が一度も変更されていません" \
       "ラボのパッチでボリュームを2つ目のバージョンに切り替え、その後ロールバックしてください"
fi
evidence "リビジョン履歴" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- 仕様がどのバージョンを指しているか --------------------------------------
# ボリュームは名前 page で探す。ラボのパッチはそれを番号(インデックス)で指定するのだが。
# 違いはまさにここで捕らえられる: パッチがリストの間違った要素に当たった場合、page という名前は
# 以前のConfigMapを指すか消えてしまい、参加者はそれを奇妙なnginxエラーではなく
# 言葉で知ることになる。
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "アプリの仕様が1つ目のページバージョンに戻されました"
    ;;
  rickroll-page-v2)
    warn "アプリの仕様が2つ目のページバージョンを指しています" \
         "ラボはロールバックで終わります; 意図的ならば問題ありません、そうでなければ: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "仕様に page という名前のボリュームがありません" \
         "パッチが間違った場所に当たったようです(番号による指定!); ../01-deploy/rickroll.yaml を再度適用してください"
    ;;
  *)
    fail "ボリューム page が、ラボが作成していない ConfigMap ${VOL_CM} を指しています" \
         "ロールバックしてください: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- 実際にクライアントに返されるもの ------------------------------------------
# 最も内容のあるチェック: 仕様とユーザーが見るものを突き合わせる。
# ここでの不一致は、Podが新しい仕様に合わせて再作成されなかったことを意味する。
# 1つではなく8つのリクエスト。Serviceの背後には3つのレプリカがある; ロールアウトが
# 完全には収束していない場合、1つのリクエストは3分の1の確率で正しいバージョンに当たり、不一致を隠す。
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP} がクラスタ内部からページを返しませんでした" \
       "エンドポイントを確認してください: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # 両バージョンを、それぞれ独自のマーカーで肯定的に判定する。「v2でなければv1」という
  # 分岐は、どんなものでも1つ目のバージョンとして数えてしまった: デフォルトのnginxページ、404、他人の
  # アプリ、ゴミ — 検証済み、ゴミに対してスクリプトは「ラボ合格」を出していた。
  if printf '%s' "$BODY" | grep -q 'バージョン2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "サービスのアドレスがアプリのページ以外のものを返しています" \
         "応答に見覚えのあるマーカーが一つもありません — 元に戻してください: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "ページの代わりに返ってきたもの" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "クライアントには、仕様に記録されているまさにそのバージョンが返されています (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "仕様は ${VOL_CM} を指していますが、クライアントには ${SERVED_VER} が返されています" \
         "レプリカが新しい仕様に合わせて再作成されていません: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "レプリカ名がページに埋め込まれていません" \
         "ConfigMap rickroll-conf が失われています: ../01-deploy/rickroll.yaml 全体を適用してください"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "ページは稼働中のレプリカ ${SERVED_POD} が返しました"
    else
      warn "ページ内の名前を稼働中のレプリカと対応付けられませんでした" \
           "おそらくチェック中にレプリカが入れ替わっていました — スクリプトをもう一度実行してください"
    fi
  fi

  evidence "返されたページ(抜粋)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "対応したPod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- 次のラボへの準備 ------------------------------------------
# ラボはレプリカを3つまで増やし、入れ替えが1つずつ見えるようにした。残された3つの
# レプリカは何も壊さない — だから fail ではなく warn — が、学習用ノードの場所を占有する。
# その場所はこの先、隣接するラボには足りなくなる。
if [ "$WANT" = "1" ]; then
  ok "レプリカ数が1に戻されました"
else
  warn "現在要求されているレプリカ数: ${WANT}" \
       "ラボの後は1に戻すとよいです: kubectl scale deployment ${APP} --replicas=1"
fi

finish
