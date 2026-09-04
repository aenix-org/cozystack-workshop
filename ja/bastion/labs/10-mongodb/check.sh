#!/usr/bin/env bash
# ラボ10のチェック: MongoDB にはさまざまな形の通行証が入っており、それを検索する。
#
# 「サービスが作成された」ではなく本質をチェックする: コレクションには四つの形すべての
# ドキュメントがあり、ネストしたフィールドやリスト内部への検索が動作し、まれなフィールドに
# スパースインデックスが構築され、スキーマバリデータが有効で、型のないドキュメントが
# 残っていないこと。
#
# 実行方法（新しいターミナルウィンドウごとに変数を設定し直す）:
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX の代わりに自分の番号
#   export MONGO_PASSWORD='passapp ユーザーのパスワード'
#   cd labs/10-mongodb && ./check.sh
#
# パスワードは表示されず、レポートにも入らない。
# スクリプトは使い捨てのポッドを起動するので、約1分かかる。

# 名前とタイトルは共通ライブラリが必要とする: それらでレポートアーティファクトに署名する。
# lib.sh には ok/fail/warn/evidence/finish と下記の環境チェックが入っている ——
# 十五個のチェックスクリプトがそれぞれ独自にではなく、同じように出力するために。
LAB_NAME="10-mongodb"
LAB_TITLE="ラボ10 · ドキュメントストア"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# クラスタアクセスファイルかテナント番号が未設定の場合、どちらのチェックも明快なメッセージで
# スクリプトを停止する。それらがないと、この先で kubectl のエラーが積み重なってしまう。
need_kubeconfig
need_tenant

# 参加者は COZY_TENANT を `workshop07` として設定するが、namespace は
# `tenant-workshop07` と呼ばれる。両方の表記を受け入れる。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# デフォルトの名前はラボと同じ。${X:-値} という記法は「環境変数を取り、
# それがなければ値を代入する」という意味: アプリに別の名前を付けたなら ——
# MONGO_APP=名前 ./check.sh として実行し、スクリプトを編集する必要はない。
# アドレスは内部、クラスタ自身の中からのもの; 名前の中の rs0 は、我々の唯一のコピーが
# 生きているレプリカセットのこと。
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "MongoDB のアドレス" "$MONGO_HOST"

# --- 1. そもそもポートへの接続があるか -------------------------------------
# MongoDB は自分のポートで、HTTP リクエストに対して、ここへはブラウザではなく
# ドライバでアクセスすべきだという明快なフレーズで応答する。これは「名前が解決しない /
# ポートが閉じている」を「接続はある、認証情報が違う」から区別するのに十分だ。
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB がテナントの内部アドレスで応答している"
else
  fail "アドレス ${MONGO_HOST} で MongoDB への接続がない" \
       "COZY_TENANT のテナント番号とアプリ名を確認してください（デフォルトは 'passes'; それ以外は MONGO_APP=名前 ./check.sh）; ダッシュボードでアプリは ready 状態でなければならない"
  finish
  exit $?
fi

# この先すべてはデータベースへのログインを必要とする。パスワードがなければスクリプトは推測もせず
# 黙りもせず、データベースの内容がチェックされなかったと正直に言い、レポートを終える: さもなくば
# 参加者はチェックが通ったと判断してしまうだろう。
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "MONGO_PASSWORD 変数が未設定、データベースの内容はチェックされていない" \
       "export MONGO_PASSWORD='${MONGO_USER} ユーザーのパスワード' としてスクリプトを再実行してください"
  finish
  exit $?
fi

# パスワードはパーセントエンコードされる: その中の @ : / ? # % という文字は、さもなくば
# 接続文字列を壊してしまい、人は「パスワードが違う」ではなく不明瞭なパースエラーを受け取る。
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ 接続文字列はパスワードを含み、ポッドの引数として渡される。これは意図的な
# 妥協だ: check/lib.sh の `in_cluster_with_secrets` を参照 —— 安全な経路はあるが、
# 過剰に複雑化せずには複数行の --eval と両立しない。ポッドは数秒生きて自ら
# 削除される; パスワードはレポートに入らない。本番のスクリプトではこうしないこと。
#
# すべてのチェックを一度に: 各呼び出しがポッドを起動し、十個のポッドを連続で起動すれば
# 何の理由もなくチェックが数分待ちに変わってしまう。
# 外部へは一行の JSON が出力され、その後 python がそれを解析する。
# `--overrides` に securityContext を付ける: それがないと `restricted` プロファイルの
# クラスタではポッドが作成されず、参加者とは無関係な理由でラボが失敗してしまう。
# `--command --` は残る: kubectl はそれを、セキュリティフィールドだけが設定された
# override とマージする。
# mongosh 用のプログラム。その中のダブルクォートは安全だ: テキストは python を通して
# 外部へ出て行き、python がそれ自身でクォートし、データベース名とコレクション名は
# 下記のマーカーで置換される。
MONGO_EVAL=$(cat <<'JSEOF'

var out = {};
try {
  var c = db.getSiblingDB("__DB__").getCollection("__COLL__");
  out.ok = 1;
  out.total = c.countDocuments({});
  out.types = c.distinct("type").length;
  out.withCar = c.countDocuments({ "car.plate": { $exists: true } });
  out.withArray = c.countDocuments({
    $or: [ { entrances: { $exists: true } }, { members: { $exists: true } } ]
  });
  out.nested = c.countDocuments({ "members.name": { $exists: true } });
  out.typeless = c.countDocuments({ type: { $exists: false } });
  var idx = c.getIndexes();
  out.indexes = idx.map(function (i) { return i.name; });
  out.sparse = idx.filter(function (i) {
    return i.sparse === true || i.partialFilterExpression !== undefined;
  }).map(function (i) { return i.name; });
  var info = db.getSiblingDB("__DB__").getCollectionInfos({ name: "__COLL__" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
JSEOF
)
MONGO_EVAL="${MONGO_EVAL//__DB__/$MONGO_DB}"
MONGO_EVAL="${MONGO_EVAL//__COLL__/$MONGO_COLL}"

# コンテナのコマンドは override の外側の `--command --` に残すのではなく、override の中に置く。
# kubectl は override を JSON merge patch として適用し、その中では containers 配列が
# 丸ごと置き換わる: 外側で設定した `--command` はポッドに届かず、mongosh の代わりに
# イメージのデフォルトプロセス —— つまりデータベース自身が起動してしまう。check/lib.sh でも同じようにしている。
MONGO_SC="$(python3 - "$MONGO_URI" "$MONGO_EVAL" <<'PYEOF'
import json, sys
uri, script = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {
  "securityContext": {"runAsNonRoot": True, "runAsUser": 999,
                      "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "mongo-check", "image": "mongo:8.0", "stdin": True,
                  "securityContext": {"allowPrivilegeEscalation": False,
                                      "capabilities": {"drop": ["ALL"]}},
                  "command": ["mongosh", "--quiet", uri, "--eval", script]}]}}))
PYEOF
)"

SUMMARY="$(kubectl run "mongo-check" --rm -i --restart=Never --quiet \
  --pod-running-timeout=90s --overrides="$MONGO_SC" \
  --image=mongo:8.0 </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

# mongosh が出力した JSON の行からフィールドを取り出す。リストはカンマで連結し、
# 参加者にそのまま見せられるようにする。
mget() {
  printf '%s' "$SUMMARY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v if not isinstance(v, list) else ", ".join(str(x) for x in v))
' "$1" 2>/dev/null
}

# 同じだが数値用: 予期しない値はすべて 0 に変える。さもなくば下記の比較が明快な FAIL の
# 代わりに算術エラーで落ちてしまう。
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# 応答がまったくないか、mongosh がエラーを報告した場合 —— これ以上チェックするものはない。
# 認証失敗は他のエラーから分けてある: それには独自のよくある原因 —— authSource=admin の
# 付け忘れがあり、ヒントはまさにそこへ導くべきだ。
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB が ${MONGO_USER} ユーザーの認証情報を受け付けなかった" \
           "パスワードと、接続文字列に authSource=admin があることを確認してください: ユーザーは admin データベースに作成され、権限は ${MONGO_DB} に付与されています" ;;
    *)
      fail "${MONGO_DB} データベースへのクエリを実行できなかった${ERR:+: $ERR}" \
           "手動で確認してください: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "${MONGO_USER} ユーザーとしての ${MONGO_DB} データベースへの接続は動作している"

# --- 2. ドキュメントが存在する ---------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "${MONGO_COLL} コレクションのドキュメント数: ${TOTAL}"
else
  fail "${MONGO_COLL} コレクションにはドキュメントが ${TOTAL} 件しかなく、少なくとも四件が期待されていた" \
       "通行証を読み込んでください: mo < passes.js（ファイルの解説は README にある）"
fi

# --- 3. 形が本当に異なる ---------------------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "コレクションには ${TYPES} 種類の異なる通行証タイプがある"
else
  fail "異なる通行証タイプは ${TYPES} 種類しかなく、四種類が期待されていた" \
       "passes.js が丸ごと読み込まれたか確認してください: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "ネストしたオブジェクト（car.plate）を持つドキュメントがある: ${WITH_CAR}"
else
  fail "ネストした car オブジェクトを持つドキュメントが一件もない" \
       "車両通行証が読み込まれていない; mo < passes.js を繰り返してください"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "リスト（entrances と members）を持つドキュメントがある: ${WITH_ARRAY}"
else
  fail "リストを持つドキュメントは ${WITH_ARRAY} 件で、少なくとも二件が期待されていた" \
       "週次通行証とグループ通行証が読み込まれていない; mo < passes.js を繰り返してください"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "オブジェクトのリスト内部（members.name）への検索がドキュメントを見つける"
else
  fail "members.name による検索が何も見つけられなかった" \
       "参加者リストを持つグループ通行証が読み込まれていない; mo < passes.js を繰り返してください"
fi

evidence "コレクションの構成" "ドキュメント数: ${TOTAL}
異なる通行証タイプ: ${TYPES}
ネストした car オブジェクトを持つもの: ${WITH_CAR}
リストを持つもの: ${WITH_ARRAY}"

# --- 4. まれなフィールドへのインデックス -----------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "スパース（または部分）インデックスが構築されている: ${SPARSE}"
  evidence "コレクションのインデックス" "すべて: ${IDX}
スパース: ${SPARSE}"
else
  fail "スパースインデックスがない —— 車番号による検索は全走査になる" \
       "作成してください: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "コレクションのインデックス" "すべて: ${IDX}"
fi

# --- 5. スキーマバリデータが有効 -------------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "スキーマバリデータが有効（違反時の動作: ${ACTION:-デフォルト}）"
  if [ "$ACTION" = "warn" ]; then
    warn "バリデータは警告するだけで、ドキュメントは受け入れてしまう" \
         "本番コレクションには validationAction: error が必要"
  fi
else
  fail "スキーマバリデータが有効になっていない —— フィールド名のタイプミスが黙って通ってしまう" \
       "有効にしてください: mo < validator.js（予測可能な失敗の解説は README を参照）"
fi

# --- 6. 壊れたドキュメントが取り除かれている -------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "type フィールドのないドキュメントは残っていない"
else
  fail "コレクションには type フィールドのないドキュメントが ${TYPELESS} 件ある —— 警備はそれらを見ない" \
       "見つけて取り除いてください: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish は合計を出力してレポートアーティファクトをファイルに保存する; 少なくとも一つのチェックが
# 失敗した場合、終了コードは非ゼロになる。
finish
