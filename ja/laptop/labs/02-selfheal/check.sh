#!/usr/bin/env bash
# ラボ2のチェック: 自己修復。
#
# 「コマンドを入力したか」ではなく、ラボ後のクラスタ状態をチェックする。アプリが再び
# Service 経由でリクエストを処理し、自分のレプリカ名を返し、その名前が
# 実際に稼働している Pod のものであること。加えて、レプリカが再作成された痕跡も探す。
#
# このスクリプトは何も削除せず、何も作成しない。ただしクラスタ内部からサービスの
# 到達性を確認するための使い捨て Pod だけは例外で、それは自分自身を後始末する。

LAB_NAME="02-selfheal"
LAB_TITLE="ラボ2 · Podを削除して何が起きるか見る"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# kubectl の RFC3339（常に Z 付きの UTC）を unix 秒に変換する。python3 を使うのは、
# macOS の BSD date と Linux の GNU date で日付の解釈が異なる一方、python は lib.sh が
# 動く環境ならどこにでもあるため。
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- そもそもアプリが存在するか --------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "アプリ ${APP} がクラスタにありません" \
       "ラボの最後に復元する必要がありました: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "namespace にあるもの" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "アプリ ${APP} は復元されました: 準備完了レプリカ ${WANT} 中 ${HAVE}"
else
  fail "準備完了レプリカは要求された ${WANT} 中 ${HAVE}" \
       "kubectl describe deployment ${APP} と kubectl get pods -l app=${APP} を見てください"
fi
evidence "アプリの状態" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- Deployment -> ReplicaSet -> Pod のチェーン -----------------------------
# このラボの要点は、レプリカを取り戻すのが ReplicaSet であって「クラスタ一般」ではないこと。
# Pod のオーナーが ReplicaSet でなければ、参加者は Pod を手動で立てたということであり、
# 自己修復を目にすることはない。
# Pod は名前ごとに数える。オーナー種別のユニーク集合を集めるのではない。ownerReferences の
# ない Pod では jsonpath が空文字列を返し、`sort -u` がそれを見えない要素にまとめてしまい、
# 少なくとも1つの Pod が ReplicaSet に管理されていれば `*ReplicaSet*` がマッチしてしまう。
# そのせいで、手動で立てた無関係な Pod が気づかれずにチェックを通過していた。
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "ラベル app=${APP} を持つ Pod が1つもありません" \
         "アプリを復元してください: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "${APP} の Pod がどれも ReplicaSet に管理されていません — 自己修復は起きません" \
         "Pod が手動で立てられたようです（kubectl run）。削除して ../01-deploy/rickroll.yaml を適用してください"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "ラベル app=${APP} を無関係な Pod が持っています: ${PODS_TOTAL} 中 ${PODS_BY_RS} が ReplicaSet に管理されています" \
           "残りはロードバランシングに入り、他人のレスポンスを返します — 見つけてください: kubectl get pods -l app=${APP} -o wide"
      evidence "Pod のオーナー" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "レプリカは ReplicaSet に管理されています — Deployment → ReplicaSet → Pod のチェーンは無傷です"
    evidence "誰が誰のオーナーか" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- レプリカ再作成の痕跡 --------------------------------------------------
# 「Pod を殺した」という直接の証拠をクラスタは保持しない。間接的なものが2つあり、どちらも十分:
# Pod が自分の Deployment よりも明らかに新しいこと、そして ReplicaSet のイベントに作成が複数あること。
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "レプリカはアプリより ${DELTA} 秒新しい — つまり以前のものは削除され、これが代わりに作成されました"
  else
    warn "レプリカはアプリとほぼ同い年です（差 ${DELTA} 秒）" \
         "アプリ全体を一番最後に復元したのなら正常です。そうでなければ Pod 削除のステップが実行されていません"
  fi
  evidence "オブジェクトの年齢" "deployment 作成: ${DEP_TS}
pod 作成:          ${POD_TS}
差:                ${DELTA} 秒"
else
  warn "Pod とアプリの年齢を比較できませんでした" \
       "PATH に python3 が必要です。ラボの合格には影響しません"
fi

# イベントは約1時間しか生きないため、無いことは不合格ではなく指摘にとどめる。
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "クラスタのイベントにレプリカ作成が ${CREATES} 回あります — 自己修復は実際に発動しました"
  evidence "レプリカ作成イベント" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "クラスタのイベントにレプリカ作成は ${CREATES} 回しか見えません" \
       "イベントは約1時間保持され、失効した可能性があります"
fi

# 2つの兆候はどちらも単独では致命的ではない: イベントは約1時間生き、
# 年齢はラボの最後にアプリ全体を正当に復元した人でも一致する。
# しかしどちらも成立しなければ — レプリカは全く削除されておらず、ラボは未達成。この
# 組み合わせがないと、スクリプトはラボ1直後に、1度の削除も待たずに「ラボ合格」を印字していた。
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "自己修復の痕跡が見つかりません: レプリカが削除されていません" \
       "レプリカを削除してください: kubectl delete pod -l app=${APP} — そしてイベントが生きている1時間以内にチェックを実行してください"
fi

# --- サービスが実際に処理しているか ----------------------------------------
# 本質的な主チェック: 「オブジェクトが存在する」ではなく「Service 経由でページが届き、
# その中に生きたレプリカの名前がある」こと。
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} はクラスタ内部からページを返しませんでした" \
       "エンドポイントを確認してください: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "ページは返っていますが、レプリカ名がそこに差し込まれていません" \
       "ConfigMap rickroll-conf が失われています: ../01-deploy/rickroll.yaml をまるごと適用してください"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "Service のレスポンスにレプリカ名がありません" \
         "ページは私たちのアプリからではありません — kubectl get svc ${APP} -o yaml を確認してください"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service はページを返し、それを生きたレプリカ ${SERVED} が処理しました"
    evidence "Service のレスポンス（断片）" \
      "$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "ページはレプリカ ${SERVED} が処理しましたが、その Pod はもうクラスタに存在しません" \
         "10秒ほど待ってからチェックを再実行してください — おそらくレプリカがちょうど入れ替わっていました"
  fi
fi

# --- 次のラボへの準備 ------------------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "レプリカ数が1に戻りました — ラボ3はまっさらな状態から始まります"
else
  warn "現在要求されているレプリカ数: ${WANT}" \
       "ラボ3の前に1に戻してください: kubectl scale deployment ${APP} --replicas=1"
fi

finish
