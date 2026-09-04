#!/usr/bin/env bash
# ラボ 10 のチェック: MongoDB にはさまざまな形のパスが入っており、それで検索します。
#
# チェックするのは「サービスが作成された」ではなく本質です: コレクションに 4 つすべての
# 形のドキュメントがあり、ネストしたフィールドやリスト内での検索が動作し、まれな
# フィールドにスパースインデックスが構築され、スキーマバリデータが有効で、タイプのない
# ドキュメントが残っていないこと。
#
# 実行（新しいターミナルウィンドウごとに変数を設定し直します）:
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX の代わりに自分の番号を
#   export MONGO_PASSWORD='passapp ユーザーのパスワード'
#   cd labs/10-mongodb && ./check.sh
#
# パスワードは印字されず、レポートにも入りません。
# スクリプトは使い捨ての Pod を起動するため、約 1 分かかります。

# 名前とタイトルは共有ライブラリが必要とします: それらでレポートアーティファクトに署名します。
# lib.sh には ok/fail/warn/evidence/finish と下記の環境チェックが入っています。15 個の
# チェックスクリプトが各自バラバラではなく同じように印字するためです。
LAB_NAME="10-mongodb"
LAB_TITLE="ラボ 10 · ドキュメントストア"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 両方のチェックは、クラスタアクセスファイルまたはテナント番号が設定されていない場合、
# 明確なメッセージでスクリプトを停止します。それらがないと、この先で kubectl のエラーが山積みになります。
need_kubeconfig
need_tenant

# 参加者は COZY_TENANT を `workshop07` として設定しますが、namespace は
# `tenant-workshop07` と呼ばれます。両方の書き方を受け付けます。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# デフォルトの名前はラボと同じです。${X:-値} という書き方は「環境変数を取り、
# それがなければ値を代入する」という意味です: アプリに別の名前を付けた場合は
# MONGO_APP=名前 ./check.sh として実行してください。スクリプトを編集する必要はありません。
# アドレスは内部、クラスタ自身からのものです。名前の中の rs0 はレプリカセットで、
# その中に私たちの唯一のコピーが存在します。
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "MongoDB アドレス" "$MONGO_HOST"

# --- 1. そもそもポートへの接続性があるか -----------------------------------------
# MongoDB は自分のポートで、ブラウザではなくドライバでアクセスするものだという
# 明確なフレーズで HTTP リクエストに応答します。これは「名前が解決しない / ポートが閉じている」を
# 「接続性はあるが認証情報が違う」と区別するのに十分です。
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB はテナントの内部アドレスで応答します"
else
  fail "アドレス ${MONGO_HOST} で MongoDB に接続できません" \
       "COZY_TENANT のテナント番号とアプリ名を確認してください（デフォルトは 'passes'。異なる場合は MONGO_APP=名前 ./check.sh）。ダッシュボードでアプリが ready 状態である必要があります"
  finish
  exit $?
fi

# この先のすべてはデータベースへのログインを必要とします。パスワードがなければ、スクリプトは
# 推測も沈黙もせず、データベースの内容が確認されていないと正直に伝え、レポートを終了します:
# さもないと参加者はチェックが通ったと判断してしまうからです。
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "MONGO_PASSWORD 変数が設定されていないため、データベースの内容は確認されていません" \
       "export MONGO_PASSWORD='${MONGO_USER} ユーザーのパスワード' を実行してスクリプトを再度実行してください"
  finish
  exit $?
fi

# パスワードはパーセントエンコードされます: その中の @ : / ? # % という文字は、そうしないと
# 接続文字列を壊し、人は「パスワードが違う」ではなく不明瞭な解析エラーを受け取ることになります。
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ 接続文字列はパスワードを含み、Pod の引数として渡されます。これは意図的な
# トレードオフです: check/lib.sh の `in_cluster_with_secrets` を参照 — 安全な方法はありますが、
# 過度に複雑にせずに複数行の --eval と両立しません。Pod は数秒だけ生き、自ら
# 後片付けします。パスワードはレポートに入りません。本番スクリプトではこうしないでください。
#
# すべてのチェックを 1 回のパスで: 各呼び出しは Pod を起動し、10 個の Pod を連続で
# 起動すると、意味もなくチェックを数分待ちに変えてしまうでしょう。
# 外へは 1 行の JSON が出力され、その後 python がそれを解析します。
# `--overrides` に securityContext を: それがないと `restricted` プロファイルの
# クラスタでは Pod が作成されず、参加者に関係のない理由でラボが失敗します。
# `--command --` は残ります: kubectl はそれを、セキュリティフィールドだけが
# 設定された override とマージします。
# mongosh 用のプログラム。その中の二重引用符は安全です: テキストは python を通して
# 外へ出て、python 自身がそれを引用符で囲み、データベース名とコレクション名は
# 下記のマーカーで置換されます。
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

# コンテナのコマンドは `--command --` として外に残さず、override の中に入れます。
# kubectl は override を JSON merge patch として適用し、その中では containers 配列が
# 丸ごと置き換えられます: 外で設定した `--command` は Pod に届かず、mongosh の代わりに
# イメージのデフォルトプロセス、つまりデータベース自身が起動してしまいます。check/lib.sh でも同じようにしています。
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

# mongosh が印字した JSON 文字列からフィールドを取り出します。リストはカンマで
# 連結され、参加者にそのまま見せられるようにします。
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

# 同じですが数値用です: 予期しない値はすべて 0 に変換されます。さもないと下記の比較が
# 明確な FAIL の代わりに算術エラーで落ちてしまうからです。
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# 答えがまったくないか、mongosh がエラーを報告した場合 — これ以上チェックするものはありません。
# 認証拒否は他のエラーと分けられています: それには固有のよくある原因 —
# authSource=admin の付け忘れ — があり、ヒントはまさにそれを指すべきです。
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB がユーザー ${MONGO_USER} の認証情報を受け付けませんでした" \
           "パスワードと、接続文字列に authSource=admin があることを確認してください: ユーザーは admin データベースに作成され、権限は ${MONGO_DB} で付与されています" ;;
    *)
      fail "データベース ${MONGO_DB} へのクエリを実行できませんでした${ERR:+: $ERR}" \
           "手動で確認してください: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "ユーザー ${MONGO_USER} でのデータベース ${MONGO_DB} への接続は動作しています"

# --- 2. ドキュメントが存在する ------------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "コレクション ${MONGO_COLL} のドキュメント数: ${TOTAL}"
else
  fail "コレクション ${MONGO_COLL} にはドキュメントが ${TOTAL} 件しかありません。少なくとも 4 件が必要です" \
       "パスをロードしてください: mo < passes.js（ファイルの内訳は README を参照）"
fi

# --- 3. 形が本当に異なる -----------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "コレクションには ${TYPES} 種類の異なるパスタイプがあります"
else
  fail "異なるパスタイプが ${TYPES} 種類しかありません。4 種類が必要です" \
       "passes.js が完全にロードされたか確認してください: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "ネストしたオブジェクト（car.plate）を持つドキュメントがあります: ${WITH_CAR}"
else
  fail "ネストした car オブジェクトを持つドキュメントが 1 件もありません" \
       "車両パスがロードされませんでした。mo < passes.js を再実行してください"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "リスト（entrances と members）を持つドキュメントがあります: ${WITH_ARRAY}"
else
  fail "リストを持つドキュメントは ${WITH_ARRAY} 件です。少なくとも 2 件が必要です" \
       "週間パスとグループパスがロードされませんでした。mo < passes.js を再実行してください"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "オブジェクトのリスト内（members.name）の検索でドキュメントが見つかります"
else
  fail "members.name による検索で何も見つかりませんでした" \
       "参加者リストを持つグループパスがロードされませんでした。mo < passes.js を再実行してください"
fi

evidence "コレクションの構成" "ドキュメント数: ${TOTAL}
異なるパスタイプ: ${TYPES}
ネストした car オブジェクトを持つ: ${WITH_CAR}
リストを持つ: ${WITH_ARRAY}"

# --- 4. まれなフィールドへのインデックス ----------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "スパース（または部分）インデックスが構築されています: ${SPARSE}"
  evidence "コレクションのインデックス" "すべて: ${IDX}
スパース: ${SPARSE}"
else
  fail "スパースインデックスがありません。車両ナンバーによる検索は全件スキャンになります" \
       "作成してください: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "コレクションのインデックス" "すべて: ${IDX}"
fi

# --- 5. スキーマバリデータが有効 --------------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "スキーマバリデータが有効です（違反時の動作: ${ACTION:-デフォルト}）"
  if [ "$ACTION" = "warn" ]; then
    warn "バリデータは警告するだけでドキュメントを受け入れます" \
         "本番コレクションには validationAction: error が必要です"
  fi
else
  fail "スキーマバリデータが有効になっていません。フィールド名のタイプミスが黙って通過します" \
       "有効にしてください: mo < validator.js（予測可能な失敗の解説は README を参照）"
fi

# --- 6. 破損したドキュメントが除去されている ---------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "type フィールドを持たないドキュメントは残っていません"
else
  fail "コレクションに type フィールドを持たないドキュメントが ${TYPELESS} 件あります。警備が見落とします" \
       "見つけて削除してください: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish は結果を印字し、レポートアーティファクトをファイルに保存します。少なくとも 1 つの
# チェックが失敗した場合、リターンコードは 0 以外になります。
finish
