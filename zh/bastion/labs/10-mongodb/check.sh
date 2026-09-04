#!/usr/bin/env bash
# 实验 10 的检查：MongoDB 中存放着不同形态的通行证，并针对它们进行查询。
#
# 我们检查的不是「服务已创建」，而是实质：集合中包含全部四种形态的文档，
# 按嵌套字段以及深入列表内部的查询可用，在一个稀有字段上
# 建立了稀疏索引，模式校验器已启用，并且没有遗留缺少类型的文档。
#
# 运行（在每个新的终端窗口中都要重新设置变量）：
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # 用你自己的编号代替 XX
#   export MONGO_PASSWORD='passapp 用户的密码'
#   cd labs/10-mongodb && ./check.sh
#
# 密码不会被打印，也不会进入报告。
# 脚本会启动一次性的 Pod，因此运行大约需要一分钟。

# 名称和标题供公共库使用：它用它们来为报告工件署名。
# lib.sh 中包含 ok/fail/warn/evidence/finish 以及下面的环境检查 —— 这样
# 十五个检查脚本打印的方式都一致，而不是各行其是。
LAB_NAME="10-mongodb"
LAB_TITLE="实验 10 · 文档存储"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 如果没有设置集群访问文件或租户编号，这两个检查会以清晰的消息停止脚本。
# 没有它们，后面 kubectl 的错误会不断累积。
need_kubeconfig
need_tenant

# 参与者把 COZY_TENANT 设置为 `workshop07`，而命名空间叫做
# `tenant-workshop07`。两种写法我们都接受。
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 默认名称与实验中的相同。写法 ${X:-值} 的意思是「取环境变量，
# 如果它不存在，则代入这个值」：如果你给应用起了别的名字 ——
# 用 MONGO_APP=名字 ./check.sh 运行，不需要改脚本。
# 这个地址是内部的，从集群自身内部访问；名字中的 rs0 是副本集，
# 我们唯一的那份副本就住在其中。
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "MongoDB 地址" "$MONGO_HOST"

# --- 1. 端口到底通不通 ------------------------------------------------------
# MongoDB 在自己的端口上会用一句清楚的话回应 HTTP 请求，说明这里应当用驱动
# 而不是浏览器来访问。这足以区分
# 「名字无法解析 / 端口关闭」和「连接是通的，只是凭据不对」。
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB 在租户的内部地址上有响应"
else
  fail "在地址 ${MONGO_HOST} 上连不上 MongoDB" \
       "检查 COZY_TENANT 中的租户编号和应用名称（默认 'passes'；否则 MONGO_APP=名字 ./check.sh）；在仪表盘中应用必须处于就绪状态"
  finish
  exit $?
fi

# 后面的一切都需要登录数据库。没有密码时脚本不会去猜也不会保持沉默，
# 而是老实说数据库内容未经检查，并结束报告：否则
# 参与者会以为检查通过了。
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "未设置变量 MONGO_PASSWORD，数据库内容未经检查" \
       "export MONGO_PASSWORD='${MONGO_USER} 用户的密码' 然后再次运行脚本"
  finish
  exit $?
fi

# 密码要做百分号编码：其中的字符 @ : / ? # % 否则会破坏连接字符串，
# 人就会得到一个含糊的解析错误，而不是「密码错误」。
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ 连接字符串包含密码，并作为 Pod 参数传入。这是一个有意识的
# 折衷：见 check/lib.sh 中的 `in_cluster_with_secrets` —— 安全的路径是有的，但
# 它在不过度复杂化的前提下无法与多行的 --eval 兼容。Pod 只存活几秒钟并
# 自我删除；密码不会进入报告。在生产脚本中不要这样做。
#
# 所有检查一次完成：每次调用都会启动一个 Pod，而连续十个 Pod
# 会平白无故地把检查变成好几分钟的等待。
# 对外只输出一行 JSON，之后由 python 解析它。
# `--overrides` 带 securityContext：没有它，在带 `restricted` 配置的集群中
# Pod 无法创建，实验就会因为一个与参与者无关的原因失败。
# `--command --` 保留：kubectl 会把它与 override 合并，override 中只设置了
# 安全字段。
# 给 mongosh 的程序。其中的双引号是安全的：文本经由 python 输出，
# python 会自己给它加引号，而数据库名和集合名会通过下面的标记
# 代入。
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

# 容器命令放在 override 内部，而不是留在外面的 `--command --` 里。
# kubectl 把 override 当作 JSON merge patch 来应用，其中 containers 数组会被
# 整个替换：在外面设置的 `--command` 到不了 Pod，于是启动的会是镜像的默认
# 进程，而不是 mongosh —— 也就是数据库本身。check/lib.sh 中也是这样做的。
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

# 从 mongosh 打印的 JSON 行中取出一个字段。列表用逗号拼接，
# 以便原样展示给参与者。
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

# 同上，但针对数字：任何意外的值都变成 0，否则下面的比较
# 会以算术错误告终，而不是给出清楚的 FAIL。
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# 如果根本没有响应，或者 mongosh 报告了错误 —— 后面就没什么可检查的了。
# 认证失败与其他错误分开处理：它有自己常见的原因 ——
# 忘记了 authSource=admin，而提示应当正好指向它。
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB 未接受 ${MONGO_USER} 用户的凭据" \
           "检查密码，以及连接字符串中是否有 authSource=admin：用户是在 admin 数据库中创建的，而权限是在 ${MONGO_DB} 中授予的" ;;
    *)
      fail "无法对 ${MONGO_DB} 数据库执行查询${ERR:+: $ERR}" \
           "手动检查：kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "以 ${MONGO_USER} 用户身份连接到 ${MONGO_DB} 数据库可用"

# --- 2. 文档存在 ------------------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "${MONGO_COLL} 集合中的文档数：${TOTAL}"
else
  fail "${MONGO_COLL} 集合中只有 ${TOTAL} 个文档，预期至少四个" \
       "加载通行证：mo < passes.js（文件的详解在 README 中）"
fi

# --- 3. 形态确实各不相同 ----------------------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "集合中有 ${TYPES} 种不同类型的通行证"
else
  fail "不同类型的通行证只有 ${TYPES} 种，预期四种" \
       "检查 passes.js 是否完整加载：db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "存在带嵌套对象（car.plate）的文档：${WITH_CAR}"
else
  fail "没有任何一个带嵌套对象 car 的文档" \
       "车辆通行证未加载；重新执行 mo < passes.js"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "存在带列表（entrances 和 members）的文档：${WITH_ARRAY}"
else
  fail "带列表的文档有 ${WITH_ARRAY} 个，预期至少两个" \
       "周通行证和团体通行证未加载；重新执行 mo < passes.js"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "深入对象列表内部的查询（members.name）能找到文档"
else
  fail "按 members.name 的查询什么也没找到" \
       "带成员列表的团体通行证未加载；重新执行 mo < passes.js"
fi

evidence "集合构成" "文档数：${TOTAL}
不同类型的通行证：${TYPES}
带嵌套对象 car 的：${WITH_CAR}
带列表的：${WITH_ARRAY}"

# --- 4. 稀有字段上的索引 ----------------------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "已建立稀疏（或部分）索引：${SPARSE}"
  evidence "集合索引" "全部：${IDX}
稀疏：${SPARSE}"
else
  fail "没有稀疏索引 —— 按车牌号的查询是全表扫描" \
       "创建一个：db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "集合索引" "全部：${IDX}"
fi

# --- 5. 模式校验器已启用 ----------------------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "模式校验器已启用（违规时的动作：${ACTION:-默认})"
  if [ "$ACTION" = "warn" ]; then
    warn "校验器只发出警告，但仍然接受文档" \
         "生产集合需要 validationAction: error"
  fi
else
  fail "模式校验器未启用 —— 字段名的拼写错误会悄无声息地通过" \
       "启用它：mo < validator.js（可预测失败的详解见 README）"
fi

# --- 6. 已清除损坏的文档 ----------------------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "没有遗留缺少 type 字段的文档"
else
  fail "集合中有 ${TYPELESS} 个缺少 type 字段的文档 —— 门卫看不到它们" \
       "找到并清除它们：db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish 打印总结并把报告工件存入文件；如果至少有一个检查失败，
# 返回码为非零。
finish
