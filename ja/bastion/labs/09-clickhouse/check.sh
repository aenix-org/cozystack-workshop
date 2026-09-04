#!/usr/bin/env bash
# ラボ9のチェック: ClickHouse に入退場パスのログが格納され、それを基にレポートが計算される。
#
# 確認するのは「サービスが作成された」ことではなく、その本質: テーブルが存在し、行数が
# 100万を下回らず、データが多様で明確なピークを持ち、月次レポートがミリ秒で走り、
# 単一カラムへのクエリがテーブルのごく一部だけを読む — つまり、カラム型ストレージが
# 謳われているだけでなく実際に機能している、ということ。
#
# 実行方法(新しいターミナルウィンドウごとに変数を再設定する必要があります):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX の代わりに自分の番号
#   export CH_PASSWORD='analyst ユーザーのパスワード'
#   cd labs/09-clickhouse && ./check.sh
#
# パスワードは出力されず、レポートにも残りません。
# スクリプトは curl を積んだ使い捨ての Pod を起動するため、実行に約1分かかります。

# 名前とタイトルは共有ライブラリが必要とします: これらでレポート成果物に署名します。
# lib.sh には ok/fail/warn/evidence/finish と以下の環境チェックが入っています — 15 個の
# チェックスクリプトがそれぞれ独自にではなく、同じ形式で出力するためです。
LAB_NAME="09-clickhouse"
LAB_TITLE="ラボ9 · 100万行の分析"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# どちらのチェックも、クラスタアクセスファイルまたはテナント番号が未設定なら明確な
# メッセージでスクリプトを停止します。これらがないと、この先 kubectl のエラーが積み重なります。
need_kubeconfig
need_tenant

# 参加者は COZY_TENANT を `workshop07` のように設定しますが、namespace は
# `tenant-workshop07` という名前です。どちらの表記も受け付けます。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# デフォルトの名前はラボと同じです。${X:-値} という記法は「環境変数を取り、なければ
# その値を代入する」という意味です: アプリを別の名前にした場合は CH_APP=名前 ./check.sh
# として実行すれば、スクリプトを編集する必要はありません。
# アドレスはクラスタ内部からの内部アドレスです: 8123 は ClickHouse HTTP インターフェースのポートです。
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "ClickHouse のアドレス" "$CH_URL"

# --- 1. サービスがそもそも応答するか ---------------------------------------------
# /ping はパスワードを必要としないため、これが最初で最も安価なチェックです:
# 「接続なし」と「接続はあるがパスワードが違う」を切り分けます。
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse がテナントの内部アドレスで応答しています"
else
  fail "ClickHouse が ${CH_HOST} で応答しません" \
       "COZY_TENANT のテナント番号とアプリ名を確認してください(デフォルトは 'analytics'、それ以外は CH_APP=名前 ./check.sh);ダッシュボードでアプリが ready 状態である必要があります"
  finish
  exit $?
fi

# これ以降はすべてデータベースへのログインが必要です。パスワードがなければスクリプトは
# 推測も沈黙もせず、データベースの内容を確認していないと正直に伝え、レポートを終えます:
# さもないと参加者はチェックが通ったと思ってしまうからです。
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "CH_PASSWORD 変数が設定されていないため、データベースの内容を確認していません" \
       "export CH_PASSWORD='${CH_USER} ユーザーのパスワード' としてスクリプトを再実行してください;パスワードはダッシュボードの secret clickhouse-${CH_APP}-credentials で確認できます"
  finish
  exit $?
fi

# 標準入力から SQL を実行し、応答を返します。
# in_cluster_curl ではなく別の関数にしています: クエリは POST のボディとして送られ、
# ボディには標準入力が必要ですが、共有関数にはそれがありません。
# パスワードは引数ではなく、一時的な Secret から環境変数として Pod に渡されます:
# args に入るものは `get pods` 権限を持つ誰からも見え、etcd に残り、監査ログにも現れます。
# ラボ自体がまさにこの点についてのものです — 逆のことをするスクリプトでそれを確認するのは
# ダブルスタンダードでしょう。
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# JSON 形式の応答の statistics ブロックから数値を取り出します。
chstat() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
key = sys.argv[1]
src = d.get("statistics", {}) if key in ("elapsed",) else d
val = src.get(key, d.get("statistics", {}).get(key))
if val is None:
    sys.exit(1)
print(val)
' "$1" 2>/dev/null
}

# --- 2. テーブルが存在する --------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "テーブル ${CH_TABLE} が存在します"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse が ${CH_USER} ユーザーのパスワードを受け付けませんでした" \
         "ダッシュボードでパスワードを確認してください: アプリ ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "テーブル ${CH_TABLE} がありません" \
         "作成してください: ch < 01-schema.sql(スキーマの解説は README にあります)"
  fi
  finish
  exit $?
fi

# --- 3. データ量とその多様性 -------------------------
# 6 回ではなく 1 回のクエリで: ch_query の呼び出しごとに Pod が起動し、6 つの Pod を
# 連続で起動すると、意味もなくチェックが1分待ちになってしまいます。
STATS="$(ch_query <<SQL
SELECT
    (SELECT count() FROM ${CH_TABLE}),
    (SELECT uniqExact(entrance) FROM ${CH_TABLE}),
    (SELECT uniqExact(pass_type) FROM ${CH_TABLE}),
    (SELECT uniqExact(toStartOfMonth(created_at)) FROM ${CH_TABLE}),
    (SELECT max(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT min(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT sum(data_uncompressed_bytes) FROM system.columns
      WHERE database = currentDatabase() AND table = '${CH_TABLE}')
SQL
)"

ROWS="$(printf '%s' "$STATS" | awk 'NR==1{print $1}')"
UNIQ_ENT="$(printf '%s' "$STATS" | awk 'NR==1{print $2}')"
UNIQ_TYPE="$(printf '%s' "$STATS" | awk 'NR==1{print $3}')"
UNIQ_MONTH="$(printf '%s' "$STATS" | awk 'NR==1{print $4}')"
PEAK_MAX="$(printf '%s' "$STATS" | awk 'NR==1{print $5}')"
PEAK_MIN="$(printf '%s' "$STATS" | awk 'NR==1{print $6}')"
TABLE_BYTES="$(printf '%s' "$STATS" | awk 'NR==1{print $7}')"

for v in ROWS UNIQ_ENT UNIQ_TYPE UNIQ_MONTH PEAK_MAX PEAK_MIN TABLE_BYTES; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*) eval "$v=0" ;;
  esac
done

if [ "$ROWS" -ge 1000000 ]; then
  ok "テーブルに ${ROWS} 行あります — 100万行が生成されました"
else
  fail "テーブルに ${ROWS} 行しかありません。100万行が期待されます" \
       "ジェネレータを実行してください: ch < 02-generate.sql(ジェネレータの解説は README にあります)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "データは多様です: 入口 ${UNIQ_ENT}、パス種別 ${UNIQ_TYPE}、月数 ${UNIQ_MONTH}"
else
  fail "データが単調です: 入口 ${UNIQ_ENT}、種別 ${UNIQ_TYPE}、月数 ${UNIQ_MONTH}" \
       "このようなデータではレポートは何も示しません;再生成してください: TRUNCATE TABLE ${CH_TABLE} の後 ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "データには時間帯ごとの明確なピークがあります(最も混雑した時間と最も静かな時間の比が2倍以上)"
  evidence "時間帯別分布" "1時間あたり最大: ${PEAK_MAX}
1時間あたり最小: ${PEAK_MIN}"
else
  warn "時間帯ごとのピークが見られません: 最大 ${PEAK_MAX}、最小 ${PEAK_MIN}" \
       "このようなデータでは「ピークはいつか」のレポートは無意味です;ジェネレータが最後まで実行されたか確認してください"
fi

# --- 4. 月次レポートが高速に計算される -----------------------------------
REPORT="$(ch_query <<SQL
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM ${CH_TABLE}
GROUP BY month
ORDER BY month
FORMAT JSON
SQL
)"

ELAPSED="$(printf '%s' "$REPORT" | chstat elapsed)"
READ_ROWS="$(printf '%s' "$REPORT" | chstat rows_read)"

if [ -z "$ELAPSED" ]; then
  fail "月次レポートが実行されませんでした" \
       "手動で実行してください: ch < 03-report.sql してエラーテキストを確認してください"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # しきい値はラボが約束する値に近づけています。以前の5秒は、4秒のレポートを成功として
  # 数えていました — ラボの冒頭に「ミリ秒で計算される」と書かれているにもかかわらず。
  # スクリプトは確認していないことを承認してはなりません。
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "月次レポートは ${MS} ミリ秒で計算され、読み取り行数: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "月次レポートの計算に ${MS} ミリ秒かかりました — ラボが対象とする桁ではありません" \
         "空いているスタンドでは100万行は数十ミリ秒に収まります;サービスが隣接する負荷でふさがっていないか確認して、再試行してください"
  else
    warn "月次レポートは ${MS} ミリ秒で計算されました — 期待より遅いですが、許容範囲内です" \
         "混雑したスタンドではこうなることがあります;空いていればこのようなレポートは数十ミリ秒に収まります"
  fi
  evidence "月次レポート" "時間: ${MS} ミリ秒
読み取り行数: ${READ_ROWS}"
fi

# --- 5. カラム型ストレージが謳われているだけでなく機能している --------------------------------
# クエリは1つの小さなカラムに触れます。ストレージがカラム型なら、読み取り量は
# テーブル全体の重さよりも明らかに少なくなります。
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# どちらの値も非圧縮です: クエリ統計の `bytes_read` は展開後のボリュームで、
# system.columns からは `data_uncompressed_bytes` を取ります。`data_compressed_bytes` と
# 比較すると、ディスク上のサイズに対する割合になり、参加者に誤った数値を表示してしまいます —
# よく圧縮されたテーブルでは100パーセントを超えることもあり得ます。
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "単一カラムの読み取り" "読み取りバイト数: ${NARROW_BYTES}
テーブル全体(非圧縮)のバイト数: ${TABLE_BYTES}
割合: ${SHARE}%"
  # 単なる「全体より少ない」ではなく、しきい値です。7 つのうち 1 つの狭いカラムは
  # 一桁パーセントを与えるはずです;「100% ではなく 99%」は形式上は少ないですが、
  # 何も証明しません — そしてそれこそがラボがタイトルに掲げる主張です。
  if [ "$SHARE" -le 25 ]; then
    ok "単一カラムのクエリはテーブルデータの ${SHARE}% を読みました — カラム型ストレージが機能しています"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "単一カラムのクエリはテーブルデータの ${SHARE}% を読みました — 全体より少ないですが、効果は期待より控えめです" \
         "一桁パーセントが期待されます;クエリが複数ではなく1つの狭いカラムを対象にしているか確認してください"
  else
    warn "単一カラムのクエリがテーブル全体を下回らない量を読みました" \
         "非常に小さいテーブルではこうなります;本当に100万行あるか確認してください"
  fi
else
  warn "狭いクエリがどれだけ読んだか計測できませんでした" \
       "手動で実行してください: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON して bytes_read を確認してください"
fi

# finish は総括を出力し、レポート成果物をファイルに保存します;チェックが1つでも失敗すれば
# 戻りコードは非ゼロになります。
finish
