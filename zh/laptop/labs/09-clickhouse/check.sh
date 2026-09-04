#!/usr/bin/env bash
# 实验 9 的检查：ClickHouse 中存放着通行记录日志，并据此计算报表。
#
# 我们检查的不是「服务已创建」，而是实质：表存在，行数不少于一百万，
# 数据多样且具有明显的峰值，按月报表在毫秒级完成，
# 而针对单列的查询只读取表的一小部分——也就是说
# 列式存储确实在工作，而不只是声称如此。
#
# 运行（每开一个新终端窗口，都需要重新设置变量）：
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # 用你自己的编号替换 XX
#   export CH_PASSWORD='analyst 用户的密码'
#   cd labs/09-clickhouse && ./check.sh
#
# 密码不会被打印，也不会进入报表。
# 脚本会拉起带 curl 的一次性 Pod，因此运行约需一分钟。

# 名称和标题供公共库使用：它会用它们给报表产物署名。
# lib.sh 中包含 ok/fail/warn/evidence/finish 以及下面的环境检查——
# 好让十五个检查脚本打印格式统一，而不是各行其是。
LAB_NAME="09-clickhouse"
LAB_TITLE="实验 9 · 百万行之上的分析"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 若未设置集群访问文件或租户编号，这两项检查都会以清晰的提示终止脚本。
# 没有它们，后面会接连报出 kubectl 错误。
need_kubeconfig
need_tenant

# 参与者把 COZY_TENANT 设为 `workshop07`，而命名空间叫
# `tenant-workshop07`。两种写法我们都接受。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 默认名称与实验中的一致。写法 ${X:-值} 的意思是「取环境
# 变量，若不存在则代入该值」：如果你给应用取了别的名字——
# 就用 CH_APP=名字 ./check.sh 运行，无需改脚本。
# 地址是内部的，来自集群自身：8123——ClickHouse HTTP 接口的端口。
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "ClickHouse 地址" "$CH_URL"

# --- 1. 服务到底是否响应 -----------------------------------------------------
# /ping 不需要密码，因此这是第一项也是最廉价的检查：
# 它把「没有连接」和「有连接、但密码不对」区分开。
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse 在租户的内部地址上有响应"
else
  fail "ClickHouse 在 ${CH_HOST} 上没有响应" \
       "检查 COZY_TENANT 中的租户编号以及应用名称（默认 'analytics'；否则 CH_APP=名字 ./check.sh）；在仪表盘中应用应处于就绪状态"
  finish
  exit $?
fi

# 后面的一切都需要登录数据库。没有密码时脚本不会去猜、也不会沉默，
# 而是如实告知数据库内容未经检查，并结束报表：否则参与者会
# 以为检查已通过。
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "未设置 CH_PASSWORD 变量，数据库内容未经检查" \
       "export CH_PASSWORD='${CH_USER} 用户的密码' 然后重新运行脚本；密码可在仪表盘中查看，密钥 clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# 从标准输入执行 SQL 并返回响应。
# 这是单独的函数，而非 in_cluster_curl：查询作为 POST 正文发送，而正文
# 需要标准输入，公共函数没有这个。
# 密码通过临时 Secret 以环境变量方式进入 Pod，而非作为参数：
# 凡是进入 args 的东西，任何有 `get pods` 权限的人都能看到，会存进 etcd，并出现在 audit
# log 中。实验本身讲的正是这一点——用一个反其道而行的脚本去检查它，
# 就成了双重标准。
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# 从 JSON 格式响应的 statistics 块中取出一个数字。
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

# --- 2. 表是否存在 ----------------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "表 ${CH_TABLE} 存在"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse 拒绝了用户 ${CH_USER} 的密码" \
         "在仪表盘中核对密码：应用 ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "表 ${CH_TABLE} 不存在" \
         "创建它：ch < 01-schema.sql（模式讲解见 README）"
  fi
  finish
  exit $?
fi

# --- 3. 数据有多少、有多丰富 ------------------------------------------------
# 用一条查询代替六条：每次调用 ch_query 都会拉起一个 Pod，连续六个
# Pod 会无谓地把检查变成一分钟的等待。
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
  ok "表中有 ${ROWS} 行——已生成一百万"
else
  fail "表中有 ${ROWS} 行，预期为一百万" \
       "运行生成器：ch < 02-generate.sql（生成器讲解见 README）"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "数据多样：入口 ${UNIQ_ENT} 个，通行类型 ${UNIQ_TYPE} 种，月份 ${UNIQ_MONTH} 个"
else
  fail "数据单一：入口 ${UNIQ_ENT} 个，类型 ${UNIQ_TYPE} 种，月份 ${UNIQ_MONTH} 个" \
       "这样的数据报表什么也显示不出；请重新生成：TRUNCATE TABLE ${CH_TABLE}，然后 ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "数据中存在明显的按小时峰值（最繁忙时段相对最清闲时段——不少于两倍）"
  evidence "按小时的分布" "每小时最大值：${PEAK_MAX}
每小时最小值：${PEAK_MIN}"
else
  warn "看不到按小时的峰值：最大 ${PEAK_MAX}，最小 ${PEAK_MIN}" \
       "「峰值何时出现」的报表在这样的数据上没有意义；请检查生成器是否完整跑完"
fi

# --- 4. 按月报表计算得很快 --------------------------------------------------
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
  fail "按月报表没有跑起来" \
       "手动运行：ch < 03-report.sql 并查看错误文本"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # 阈值保持贴近实验所承诺的。此前的五秒会把耗时四秒的报表
  # 算作成功——尽管实验开头写着
  # 「在毫秒级完成」。脚本不应确认它没有检查过的东西。
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "按月报表在 ${MS} 毫秒内算完，读取行数：${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "按月报表算了 ${MS} 毫秒——这不是实验所讲的那个数量级" \
         "空闲台架上一百万行会落在几十毫秒内；请检查服务是否被相邻负载占用，然后重试"
  else
    warn "按月报表在 ${MS} 毫秒内算完——比预期慢，但在合理范围内" \
         "在繁忙的台架上会这样；空闲时这样的报表会落在几十毫秒内"
  fi
  evidence "按月报表" "时间：${MS} 毫秒
读取行数：${READ_ROWS}"
fi

# --- 5. 列式存储确实在工作，而不只是声称如此 --------------------------------
# 查询只触及一个小列。如果存储是列式的，读取的量
# 会明显少于整张表的体量。
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# 两个量都是未压缩的：查询统计中的 `bytes_read` 是解压后的
# 体量，而从 system.columns 取的是 `data_uncompressed_bytes`。与
# `data_compressed_bytes` 比较得到的是相对磁盘大小的占比，会给参与者
# 打印出一个错误的数字——在压缩良好的表上它可能超过百分之百。
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "单列读取" "读取字节：${NARROW_BYTES}
整张表未压缩，字节：${TABLE_BYTES}
占比：${SHARE}%"
  # 用阈值，而不只是「小于整体」。七列中的一个窄列应给出个位数
  # 百分比；「99% 而非 100%」形式上更小，却什么也证明不了——而这
  # 恰恰是实验写进标题的论断。
  if [ "$SHARE" -le 25 ]; then
    ok "针对单列的查询读取了表数据的 ${SHARE}%——列式存储在工作"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "针对单列的查询读取了表数据的 ${SHARE}%——小于整体，但收益比预期更微薄" \
         "预期为个位数百分比；请检查查询是否只访问一个窄列，而非多列"
  else
    warn "针对单列的查询读取的量不少于整张表" \
         "在非常小的表上会这样；请检查是否确实有一百万行"
  fi
else
  warn "无法测量窄查询读取了多少" \
       "手动执行：SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON 并查看 bytes_read"
fi

# finish 打印总结并把报表产物写入文件；若至少有一项检查失败，
# 返回码为非零。
finish
