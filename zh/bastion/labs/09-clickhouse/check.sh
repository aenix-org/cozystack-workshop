#!/usr/bin/env bash
# 实验 9 的检查：ClickHouse 中存放着通行记录日志，并据此计算报表。
#
# 我们检查的不是“服务已创建”，而是实质：表存在、行数不少于一百万、
# 数据多样且有明显的峰值、按月报表能在毫秒级完成，而对单列的查询只读取表的
# 一小部分——也就是说，列式存储是真的在工作，而不只是声称如此。
#
# 运行（每开一个新终端窗口都要重新设置这些变量）：
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # 用你的编号替换 XX
#   export CH_PASSWORD='analyst 用户的密码'
#   cd labs/09-clickhouse && ./check.sh
#
# 密码不会被打印，也不会出现在报表里。
# 脚本会拉起带 curl 的一次性 Pod，因此大约需要一分钟。

# 名称和标题是共享库需要的：它用它们为报表产物签名。
# lib.sh 里有 ok/fail/warn/evidence/finish 以及下面的环境检查——好让
# 十五个检查脚本以相同的方式打印，而不是各写各的。
LAB_NAME="09-clickhouse"
LAB_TITLE="实验 9 · 百万行之上的分析"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 如果没有设置集群访问文件或租户编号，这两个检查会用清晰的消息停止脚本。
# 没有它们，下面会不断堆积 kubectl 错误。
need_kubeconfig
need_tenant

# 参与者把 COZY_TENANT 设为 `workshop07`，而 namespace 叫
# `tenant-workshop07`。两种写法我们都接受。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 默认名称与实验中的相同。写法 ${X:-值} 表示“取环境变量，如果它
# 不存在，就代入这个值”：如果你给应用起了别的名字——就用
# CH_APP=名字 ./check.sh 运行，无需改脚本。
# 地址是内部的，来自集群自身：8123 是 ClickHouse HTTP 接口的端口。
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "ClickHouse 地址" "$CH_URL"

# --- 1. 服务到底有没有响应 ---------------------------------------------
# /ping 不需要密码，所以这是第一个也是最廉价的检查：
# 它把“没有连接”和“连接是通的、只是密码不对”区分开来。
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse 在租户的内部地址上有响应"
else
  fail "ClickHouse 在 ${CH_HOST} 上没有响应" \
       "检查 COZY_TENANT 中的租户编号和应用名称（默认为 'analytics'；否则用 CH_APP=名字 ./check.sh）；在仪表盘中应用必须处于就绪状态"
  finish
  exit $?
fi

# 下面的一切都需要登录数据库。没有密码时脚本不会去猜、也不会沉默，
# 而是如实地说数据库内容未被检查，并结束报表：否则参与者会以为检查
# 已经通过。
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "未设置 CH_PASSWORD 变量，数据库内容未被检查" \
       "执行 export CH_PASSWORD='${CH_USER} 用户的密码' 后再次运行脚本；密码可在仪表盘中查看，位于 secret clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# 从标准输入执行 SQL 并返回响应。
# 单独一个函数，而不是 in_cluster_curl：查询作为 POST 的 body 发送，而 body
# 需要标准输入，共享函数没有这个。
# 密码作为环境变量从临时 Secret 进入 Pod，而不是作为参数：凡是进入 args 的东西，
# 任何有 `get pods` 权限的人都能看到，它存在 etcd 里，还会出现在 audit log 中。
# 实验讲的正是这一点——用一个反其道而行的脚本去检查它，就成了双重标准。
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

# --- 2. 表存在 --------------------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "表 ${CH_TABLE} 存在"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse 未接受 ${CH_USER} 用户的密码" \
         "在仪表盘中核对密码：应用 ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "表 ${CH_TABLE} 不存在" \
         "创建它：ch < 01-schema.sql（schema 讲解见 README）"
  fi
  finish
  exit $?
fi

# --- 3. 数据有多少、有多样 -------------------------
# 用一个查询代替六个：每次调用 ch_query 都会拉起一个 Pod，连续六个 Pod
# 会无缘无故地把检查变成一分钟的等待。
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
  ok "数据很多样：入口 ${UNIQ_ENT} 个、通行类型 ${UNIQ_TYPE} 种、月份 ${UNIQ_MONTH} 个"
else
  fail "数据很单调：入口 ${UNIQ_ENT} 个、类型 ${UNIQ_TYPE} 种、月份 ${UNIQ_MONTH} 个" \
       "在这样的数据上报表什么都显示不出来；重新生成：TRUNCATE TABLE ${CH_TABLE}，然后 ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "数据有明显的按小时峰值（最繁忙的小时相对最安静的小时——至少多一倍）"
  evidence "按小时分布" "每小时最大值：${PEAK_MAX}
每小时最小值：${PEAK_MIN}"
else
  warn "看不出按小时的峰值：最大值 ${PEAK_MAX}，最小值 ${PEAK_MIN}" \
       "在这样的数据上“峰值何时出现”的报表毫无意义；检查生成器是否完整跑完"
fi

# --- 4. 按月报表计算得很快 -----------------------------------
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
       "手动运行它：ch < 03-report.sql 并查看错误文本"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # 阈值我们保持贴近实验所承诺的。此前的五秒会把一个四秒的报表
  # 算作成功——尽管实验开头写着“毫秒级完成”。
  # 脚本不该确认它没有检查过的东西。
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "按月报表在 ${MS} 毫秒内算完，读取行数：${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "按月报表算了 ${MS} 毫秒——这不是实验所讲的那个数量级" \
         "在空闲的环境上一百万行应在几十毫秒内完成；检查服务是否被相邻负载占用，然后重试"
  else
    warn "按月报表在 ${MS} 毫秒内算完——比预期慢，但在合理范围内" \
         "在繁忙的环境上会这样；在空闲的环境上这样的报表应在几十毫秒内完成"
  fi
  evidence "按月报表" "时间：${MS} 毫秒
读取行数：${READ_ROWS}"
fi

# --- 5. 列式存储是真的在工作，而不只是声称 --------------------------------
# 查询只触及一个很小的列。如果存储是列式的，读取的量
# 会明显小于整张表的体量。
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# 两个数值都是“未压缩的”：查询统计里的 `bytes_read` 是解压后的
# 体量，而从 system.columns 里取的是 `data_uncompressed_bytes`。与
# `data_compressed_bytes` 比较得到的是相对磁盘大小的占比，会给参与者
# 打印出一个错误的数字——在压缩良好的表上它可能超过百分之百。
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "读取单列" "读取字节数：${NARROW_BYTES}
整张表未压缩，字节数：${TABLE_BYTES}
占比：${SHARE}%"
  # 是阈值，而不只是“小于整表”。七列中的一个窄列应给出个位数
  # 的百分比；“99% 而非 100%”形式上更小，却证明不了什么——而这
  # 恰恰是实验放在标题里的论断。
  if [ "$SHARE" -le 25 ]; then
    ok "单列查询读取了表数据的 ${SHARE}%——列式存储在工作"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "单列查询读取了表数据的 ${SHARE}%——小于整表，但收益比预期的更有限" \
         "预期为个位数的百分比；检查查询是否访问的是一个窄列，而不是若干列"
  else
    warn "单列查询读取的量不少于整张表" \
         "在非常小的表上会这样；检查是否真的有一百万行"
  fi
else
  warn "无法测量窄查询读取了多少" \
       "手动执行：SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON 并查看 bytes_read"
fi

# finish 打印总结并把报表产物存入文件；如果至少有一个检查失败，
# 返回码为非零。
finish
