#!/usr/bin/env bash
# ラボ2のチェック: 自己修復。
#
# 「コマンドを入力したか」ではなく、ラボ後のクラスタの状態を確認する: アプリが再び
# Service 経由でリクエストを処理し、自分のレプリカの名前を返し、その名前が
# 実際に稼働しているポッドのものであること。加えて、レプリカが再作成された痕跡を探す。
#
# このスクリプトは、クラスタ内部からサービスの到達性を確認するための使い捨てポッド
# 以外は何も削除も作成もしない — そのポッドは自分自身を片付ける。

LAB_NAME="02-selfheal"
LAB_TITLE="ラボ2 · ポッドを殺して何が起こるか見る"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# kubectl の RFC3339(常に UTC で Z 付き)を unix 秒に変換する。python3 を使うのは、
# macOS の BSD date と Linux の GNU date で日付の解釈が異なる一方、python は lib.sh が
# 動く環境にはどこにでもあるため。
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- そもそもアプリが存在するか --------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "アプリ ${APP} がクラスタに存在しません" \
       "ラボの最後に戻す必要がありました: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "namespace にあるもの" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "アプリ ${APP} が復旧しました: 準備完了のレプリカ ${HAVE}/${WANT}"
else
  fail "準備完了のレプリカは要求された ${WANT} のうち ${HAVE}" \
       "kubectl describe deployment ${APP} と kubectl get pods -l app=${APP} を確認してください"
fi
evidence "アプリの状態" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- チェーン Deployment -> ReplicaSet -> Pod -------------------------------
# このラボの要点は、レプリカを戻すのが「クラスタ全般」ではなく ReplicaSet だということ。
# ポッドの所有者が ReplicaSet でなければ、参加者が手動でポッドを立てたということであり、
# 自己修復を目にすることはない。
# 所有者の種類の一意な集合を取るのではなく、ポッドを名前ごとに数える: ownerReferences の
# ないポッドでは jsonpath が空文字列を返し、`sort -u` はそれを見えない要素に潰し、
# 少なくとも1つのポッドが ReplicaSet に管理されている限り `*ReplicaSet*` がマッチしてしまう。
# そのため、手動で立てた無関係なポッドが気づかれずにチェックを通過していた。
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "ラベル app=${APP} を持つポッドが1つもありません" \
         "アプリを戻してください: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "${APP} のポッドはどれも ReplicaSet に管理されていません — 自己修復は起きません" \
         "ポッドが手動で立てられたようです(kubectl run)。それを削除して ../01-deploy/rickroll.yaml を適用してください"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "ラベル app=${APP} を無関係なポッドが付けています: ${PODS_TOTAL} のうち ${PODS_BY_RS} が ReplicaSet に管理されています" \
           "残りはロードバランシングに入り、別物のレスポンスを返します — 見つけてください: kubectl get pods -l app=${APP} -o wide"
      evidence "ポッドの所有者" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "レプリカは ReplicaSet に管理されています — チェーン Deployment → ReplicaSet → Pod は無傷です"
    evidence "誰が誰の所有者か" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- レプリカ再作成の痕跡 --------------------------------------------------
# クラスタは「ポッドを殺した」という直接の証拠を保持しない。間接的なものが2つあり、どちらも十分だ:
# ポッドが自分の Deployment より明らかに若いこと、そして ReplicaSet のイベントに作成が2件以上あること。
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "レプリカはアプリより ${DELTA} 秒若い — つまり以前のものが削除され、代わりにこれが作成された"
  else
    warn "レプリカはアプリとほぼ同い年です(差 ${DELTA} 秒)" \
         "最後にアプリ全体を復旧したのであれば正常です。そうでなければ、ポッド削除のステップが実行されていません"
  fi
  evidence "オブジェクトの年齢" "deployment 作成: ${DEP_TS}
pod 作成:        ${POD_TS}
差:              ${DELTA} 秒"
else
  warn "ポッドとアプリの年齢を比較できませんでした" \
       "PATH に python3 が必要です。ラボの合格には影響しません"
fi

# イベントは約1時間で消えるため、存在しないことは失敗ではなく注意点である。
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "クラスタのイベントにレプリカ作成が ${CREATES} 件 — 自己修復は実際に発動しました"
  evidence "レプリカ作成のイベント" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "クラスタのイベントではレプリカ作成が ${CREATES} 回しか見えません" \
       "イベントは約1時間保持され、期限切れになった可能性があります"
fi

# 2つの兆候はどちらも単独ではブロッキングではない: イベントは約1時間しか生きず、
# ラボの最後にアプリ全体を正当に復旧した人では年齢が一致してしまう。
# だが、どちらも満たされない場合 — レプリカはまったく削除されておらず、ラボは未完了だ。この
# 組み合わせがないと、スクリプトはラボ1の直後に、削除を1回も待たずに「ラボ合格」と表示していた。
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "自己修復の痕跡が見つかりません: レプリカが削除されていません" \
       "レプリカを削除してください: kubectl delete pod -l app=${APP} — そしてイベントが生きている1時間以内にチェックを実行してください"
fi

# --- サービスが実際に応答する ----------------------------------------------
# 本質的な主チェック: 「オブジェクトが存在する」ではなく「Service 経由でページが来て
# その中に生きたレプリカの名前がある」こと。
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} はクラスタ内部からページを返しませんでした" \
       "エンドポイントを確認してください: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "ページは返されますが、レプリカ名が差し込まれていません" \
       "ConfigMap rickroll-conf が失われています: ../01-deploy/rickroll.yaml を丸ごと適用してください"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "Service のレスポンスにレプリカ名がありません" \
         "ページは私たちのアプリからのものではありません — kubectl get svc ${APP} -o yaml を確認してください"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service がページを返し、それを生きたレプリカ ${SERVED} が処理しました"
    evidence "Service のレスポンス(断片)" \
      "$(printf '%s' "$BODY" | grep -o "対応したPod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "ページはレプリカ ${SERVED} が返しましたが、そのようなポッドはもうクラスタに存在しません" \
         "10秒ほど待ってからチェックを再実行してください — おそらくレプリカがちょうど今入れ替わっていました"
  fi
fi

# --- 次のラボへの準備 ------------------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "レプリカ数が1に戻されました — ラボ3は白紙から始められます"
else
  warn "現在要求されているレプリカ数: ${WANT}" \
       "ラボ3の前に1つに戻してください: kubectl scale deployment ${APP} --replicas=1"
fi

finish
