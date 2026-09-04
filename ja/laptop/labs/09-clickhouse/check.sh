#!/usr/bin/env bash
# ラボ9の検証: ClickHouse に入退場パスのログが入っており、それを基にレポートを計算する。
#
# 検証するのは「サービスが作成された」ことではなく本質: テーブルが存在し、行数が100万以上あり、
# データが多様で顕著なピークを持ち、月次レポートがミリ秒で実行され、
# 単一カラムのクエリがテーブルのごく一部だけを読む — つまり
# カラム型ストレージが機能している、単に主張されているだけではない、ということ。
#
# 実行(新しいターミナルウィンドウごとに変数は再設定する):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX の代わりに自分の番号を
#   export CH_PASSWORD='analyst ユーザーのパスワード'
#   cd labs/09-clickhouse && ./check.sh
#
# パスワードは出力されず、レポートにも残らない。
# スクリプトは curl の使い捨て Pod を起動するため、実行に約1分かかる。

# 名前とタイトルは共通ライブラリが必要とする: それらでレポート成果物に署名する。
# lib.sh には ok/fail/warn/evidence/finish と以下の環境チェックが入っている — こうして
# 15個の検証スクリプトが各自バラバラではなく統一された形で出力する。
LAB_NAME="09-clickhouse"
LAB_TITLE="ラボ9 · 100万行の分析"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# どちらのチェックも、クラスターアクセスファイルまたはテナント番号が未設定なら
# 分かりやすいメッセージでスクリプトを止める。これがないと以降 kubectl のエラーが続く。
need_kubeconfig
need_tenant

# 参加者は COZY_TENANT を `workshop07` として設定するが、namespace は
# `tenant-workshop07` と呼ばれる。どちらの書き方も受け付ける。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# デフォルト名はラボと同じもの。${X:-値} という記法は「環境変数を取り、
# なければ値を代入する」という意味: アプリを別の名前にしたなら
# CH_APP=名前 ./check.sh として実行すればよく、スクリプトを編集する必要はない。
# アドレスは内部のもの、クラスター内部から: 8123 は ClickHouse の HTTP インターフェースのポート。
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "ClickHouse アドレス" "$CH_URL"

# --- 1. サービスがそもそも応答するか ---------------------------------------------
# /ping はパスワード不要なので、これが最初で最も安価なチェック:
# 「接続なし」と「接続はあるがパスワードが違う」を切り分ける。
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse がテナントの内部アドレスで応答している"
else
  fail "ClickHouse が ${CH_HOST} で応答しない" \
       "COZY_TENANT のテナント番号とアプリ名を確認(デフォルトは 'analytics'、それ以外なら CH_APP=名前 ./check.sh)。ダッシュボードでアプリが ready 状態になっている必要がある"
  finish
  exit $?
fi

# これ以降はすべてデータベースへのログインが必要。パスワードがなければスクリプトは推測も沈黙もせず、
# データベースの内容は未検証だと正直に告げてレポートを終える: そうしないと
# 参加者はチェックに合格したと思い込んでしまう。
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "CH_PASSWORD 変数が未設定のため、データベースの内容は未検証" \
       "export CH_PASSWORD='${CH_USER} ユーザーのパスワード' としてスクリプトを再実行。パスワードはダッシュボードで見える、シークレット clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# 標準入力から SQL を実行し、応答を返す。
# in_cluster_curl ではなく専用関数: クエリは POST のボディで送られ、ボディには
# 標準入力が必要だが、共通関数にはそれがない。
# パスワードは引数ではなく一時 Secret から環境変数として Pod に渡される:
# args に入るものはすべて `get pods` を持つ誰にでも見え、etcd に残り、audit
# log に現れる。ラボ自体がこれについて語っている — それと逆のことをするスクリプトで検証するのは
# ダブルスタンダードになる。
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# JSON 形式の応答の statistics ブロックから数値を取り出す。
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
  ok "テーブル ${CH_TABLE} が存在する"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse がユーザー ${CH_USER} のパスワードを拒否した" \
         "ダッシュボードでパスワードを確認: アプリ ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "テーブル ${CH_TABLE} が存在しない" \
         "作成する: ch < 01-schema.sql(スキーマの解説は README に)"
  fi
  finish
  exit $?
fi

# --- 3. データがどれだけあり、どれだけ多様か -------------------------
# 6回ではなく1回のクエリで: ch_query の呼び出しごとに Pod が起動するので、6つの
# Pod を続けて起動すると、何の理由もなく検証が1分待ちになってしまう。
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
  ok "テーブルに ${ROWS} 行 — 100万行が生成された"
else
  fail "テーブルに ${ROWS} 行、100万行が期待された" \
       "ジェネレーターを実行: ch < 02-generate.sql(ジェネレーターの解説は README に)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "データは多様: 入口 ${UNIQ_ENT}、パス種別 ${UNIQ_TYPE}、月 ${UNIQ_MONTH}"
else
  fail "データが単調: 入口 ${UNIQ_ENT}、種別 ${UNIQ_TYPE}、月 ${UNIQ_MONTH}" \
       "こうしたデータではレポートは何も示さない。再生成する: TRUNCATE TABLE ${CH_TABLE}、その後 ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "データに時間ごとの顕著なピークがある(最も混む時間帯が最も静かな時間帯の2倍以上)"
  evidence "時間ごとの分布" "時間あたり最大: ${PEAK_MAX}
時間あたり最小: ${PEAK_MIN}"
else
  warn "時間ごとのピークが見えない: 最大 ${PEAK_MAX}、最小 ${PEAK_MIN}" \
       "こうしたデータでは「ピークはいつか」レポートは意味をなさない。ジェネレーターが最後まで動いたか確認する"
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
  fail "月次レポートが実行されなかった" \
       "手動で実行する: ch < 03-report.sql してエラーテキストを見る"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # しきい値はラボが約束する値の近くに保つ。以前の5秒は、4秒のレポートを
  # 成功として数えていた — ラボのヘッダーには「ミリ秒で計算される」と
  # 書かれているのに。スクリプトは検証していないことを是認してはならない。
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "月次レポートは ${MS} ミリ秒で計算された、読んだ行数: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "月次レポートの計算に ${MS} ミリ秒 — これはラボが扱う桁ではない" \
         "空いているスタンドでの100万行は数十ミリ秒に収まる。サービスが隣接する負荷で忙しくないか確認して再試行する"
  else
    warn "月次レポートは ${MS} ミリ秒で計算された — 期待より遅いが妥当な範囲内" \
         "混んでいるスタンドではこうなる。空いていればこのレポートは数十ミリ秒に収まる"
  fi
  evidence "月次レポート" "時間: ${MS} ミリ秒
読んだ行数: ${READ_ROWS}"
fi

# --- 5. カラム型ストレージが機能している、単に主張されているだけではない --------------------------------
# クエリは1つの小さなカラムに触れる。ストレージがカラム型なら、読まれる量は
# テーブル全体の重さより顕著に少なくなる。
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# 両方の値は非圧縮: クエリ統計の `bytes_read` は展開後のボリュームで、
# system.columns からは `data_uncompressed_bytes` を取る。`data_compressed_bytes`
# と比較すると、ディスク上のサイズに対する割合になり、参加者に誤った数字を出力していた —
# よく圧縮されたテーブルでは100パーセントを超えることもあった。
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "単一カラムの読み取り" "読んだバイト数: ${NARROW_BYTES}
非圧縮のテーブル全体、バイト: ${TABLE_BYTES}
割合: ${SHARE}%"
  # 単なる「全体より少ない」ではなくしきい値。7つのうち1つの狭いカラムなら1桁パーセントに
  # なるはず。「100%ではなく99%」は形式的には少ないが何も証明しない — そしてまさに
  # それがラボがタイトルに掲げる主張だ。
  if [ "$SHARE" -le 25 ]; then
    ok "単一カラムのクエリはテーブルのデータの ${SHARE}% を読んだ — カラム型ストレージが機能している"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "単一カラムのクエリはテーブルのデータの ${SHARE}% を読んだ — 全体より少ないが、利得は期待より控えめ" \
         "1桁パーセントが期待された。クエリが複数ではなく1つの狭いカラムを対象にしているか確認する"
  else
    warn "単一カラムのクエリがテーブル全体以上を読んだ" \
         "非常に小さなテーブルではこうなる。本当に100万行あるか確認する"
  fi
else
  warn "狭いクエリがどれだけ読んだか測定できなかった" \
       "手動で実行する: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON して bytes_read を見る"
fi

# finish は総括を出力し、レポート成果物をファイルに書き出す。少なくとも1つの
# チェックが失敗していれば終了コードは非ゼロになる。
finish
