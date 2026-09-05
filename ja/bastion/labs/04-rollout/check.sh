#!/usr/bin/env bash
# ラボ4のチェック: 新バージョンのロールアウトとロールバック。
#
# 入力したコマンドではなく、実態を検証する:
#   - アプリケーションの履歴に複数のリビジョンがある、つまりバージョンが実際に変更された;
#   - 2番目のバージョンの ConfigMap が、最初のものを編集したのではなく別オブジェクトとしてクラスタにある;
#   - コンテナに readinessProbe がある — これがなければゼロダウンタイムは再現できない;
#   - ロールアウトが最後まで完了し、途中で止まっていない;
#   - Service が返すページが、spec が参照している ConfigMap と一致する。
#     これは「spec はロールバックされたのに、Pod が再作成されていない」ケースを捕捉する。
#
# スクリプトは何も変更しない。使い捨ての Pod は、クラスタ内部からページを取得するためだけに
# 必要で、自分自身を後始末する。
#
# VM 上で、このラボのフォルダから、学習クラスタ `lab` へのアクセスで実行する
# (管理クラスタ上のテナントではなく):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# ここでは COZY_TENANT 変数は不要: ラボ全体が `lab` クラスタ内で進む。
#
# 後始末の前、そしてロールバックが完了した後に実行すること: リビジョン履歴は
# Deployment とともに存在し、それとともに消える。

# レポートのヘッダーと、スクリプトの隣のファイル名 report-<ラボ>-<日付>.md に入る。
LAB_NAME="04-rollout"
LAB_TITLE="ラボ4 · 新バージョンのロールアウトとロールバック"
# 共通ライブラリ: ok / fail / warn / evidence / finish、クラスタ内部からのリクエスト、
# レポートの書き出し。パスはカレントディレクトリではなく、スクリプト自身の場所から計算される。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG がないと kubectl は VM 上にクラスタを探し、すべてを1つのエラーで落とす。
# その中では本当の原因を見分けられない。ここですぐに止める。
need_kubeconfig

APP=rickroll

# --- アプリケーションが所定の場所にあり、動作状態まで持ち込まれている ------------------
# アプリケーションがなければ検証するものがないので、ここが唯一の早期終了。
# この先は準備完了のコピー数だけでなく、Progressing 条件の理由も見る:
# NewReplicaSetAvailable はロールアウトが完了したことを意味する。準備完了のコピー
# だけでは不十分 — 更新が止まっていると旧バージョンが動き、カウンタは
# 期待した数を示すのに、新しいコピーは一度も立ち上がっていない。
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "アプリケーション ${APP} がクラスタにありません" \
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
  ok "ロールアウトが最後まで完了: 準備完了のコピー ${HAVE} / ${WANT}"
else
  fail "アプリケーションが完了状態にありません (準備完了 ${HAVE} / ${WANT}、理由: ${PROG_REASON:-なし})" \
       "ロールアウトが止まっているなら — ロールバックで抜けてください: kubectl rollout undo deployment/${APP}"
fi
evidence "アプリケーションの状態" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: ゼロダウンタイムの対価 -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "コンテナに readinessProbe があります (${PROBE}) — コピーの入れ替えは準備完了後にのみ行われる"
else
  fail "コンテナに readinessProbe がありません" \
       "これがないとクラスタは準備未完了のコピーにトラフィックを流します; ../01-deploy/rickroll.yaml を適用してください"
fi

# --- バージョンが別々のオブジェクトとして作られている --------------------------------------
# ページの両バージョンは、2つの別々の ConfigMap としてクラスタに存在しなければならない。
# 代わりに rickroll-page-v1 をその場で編集した人は、画面上に新しいページを見て
# ラボが済んだと判断する — しかしロールバックする先がどこにもなく、
# コピーの入れ替えもリビジョン履歴への記録も一切起こらない。
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2 が別オブジェクトとしてクラスタにあります"
else
  fail "クラスタに ConfigMap rickroll-page-v2 がありません" \
       "適用してください: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "ページの最初のバージョンも保存されています — ロールバックする先があります"
else
  warn "クラスタに ConfigMap rickroll-page-v1 が見つかりません" \
       "これなしでは最初のバージョンへのロールバックで Pod が立ち上がりません: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- リビジョン履歴 -------------------------------------------------------
# 履歴の行数ではなく、最新リビジョンの番号を見る。ロールバックは
# 新しい ReplicaSet を追加せず、古いものを再利用して番号を上げるため、
# ロールバック後も履歴の行数は同じで、番号だけが増える。
#   1 — spec が一度も変更されていない
#   2 — バージョンが切り替えられた
#   3 以上 — 切り替えて戻された
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "アプリケーションの最新リビジョンは ${REV_MAX}: バージョンを切り替えて戻しました"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "最新リビジョンは 2: ロールアウトは済み、ロールバックはまだ" \
       "最初のバージョンを戻してください: kubectl rollout undo deployment/${APP}"
else
  fail "最新リビジョンは ${REV_MAX}: アプリケーションの spec が一度も変更されていません" \
       "ラボのパッチでボリュームを2番目のバージョンに切り替え、その後ロールバックしてください"
fi
evidence "リビジョン履歴" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- spec がどのバージョンを指しているか --------------------------------------
# ラボのパッチはインデックスで指定するにもかかわらず、ボリュームは名前 page で探す。
# その違いがまさにここで捕捉される: パッチがリストの間違った要素に入った場合、
# 名前 page は以前の ConfigMap を指すか消えており、参加者はそれを不可解な nginx の
# エラーではなく言葉で知ることになる。
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "アプリケーションの spec がページの最初のバージョンにロールバックされました"
    ;;
  rickroll-page-v2)
    warn "アプリケーションの spec がページの2番目のバージョンを指しています" \
         "ラボはロールバックで終わります; 意図的ならば — 問題ありません、そうでなければ: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "spec に名前 page のボリュームがありません" \
         "パッチが間違った場所に入ったようです (インデックスによる指定!); ../01-deploy/rickroll.yaml を再度適用してください"
    ;;
  *)
    fail "ボリューム page が、ラボが作成していない ConfigMap ${VOL_CM} を指しています" \
         "ロールバックしてください: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- 実際にクライアントへ返されるもの ------------------------------------------
# 最も内容のあるチェック: spec とユーザーが見るものを突き合わせる。
# ここでの不一致は、Pod が新しい spec に合わせて再作成されていないことを意味する。
# 1回ではなく8回リクエストする。Service の背後には3つのコピーがある; ロールアウトが
# 完全に収束していない場合、1回のリクエストは3分の1の確率で正しいバージョンに当たり不一致を隠す。
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP} がクラスタ内部からページを返しませんでした" \
       "エンドポイントを確認してください: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # 両バージョンを、それぞれ固有のマーカーで肯定的に判定する。「v2 でなければ
  # v1」という分岐は、何でも最初のバージョンとして数えていた: デフォルトの nginx ページ、404、他人の
  # アプリケーション、ゴミ — 検証済みで、ゴミに対してもスクリプトは「ラボ合格」と表示していた。
  if printf '%s' "$BODY" | grep -q 'バージョン2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "Service のアドレスでアプリケーションのページ以外が返されています" \
         "応答に見覚えのあるマーカーが1つもありません — 元に戻してください: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "ページの代わりに返されたもの" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "spec に記録されたのとまさに同じバージョンがクライアントに返されています (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "spec は ${VOL_CM} を指しているのに、クライアントには ${SERVED_VER} が返されています" \
         "コピーが新しい spec に合わせて再作成されていません: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "コピー名がページに埋め込まれていません" \
         "ConfigMap rickroll-conf が失われています: ../01-deploy/rickroll.yaml を丸ごと適用してください"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "ページは稼働中のコピー ${SERVED_POD} が返しました"
    else
      warn "ページの名前を稼働中のコピーと対応付けられませんでした" \
           "おそらくチェック中にコピーが入れ替わっていました — スクリプトをもう一度実行してください"
    fi
  fi

  evidence "返されたページ (抜粋)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "対応したPod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- 次のラボへの準備 ------------------------------------------
# ラボは入れ替えを1つずつ見えるようにコピーを3つまで増やした。残った3つの
# コピーは何も壊さない — だから fail ではなく warn — が、学習用ノードの場所を
# 占有し、その先で隣のラボがそれを使い切れなくなる。
if [ "$WANT" = "1" ]; then
  ok "コピー数が1つに戻されました"
else
  warn "現在要求されているコピー数: ${WANT}" \
       "ラボの後は1つに戻すとよいでしょう: kubectl scale deployment ${APP} --replicas=1"
fi

finish
