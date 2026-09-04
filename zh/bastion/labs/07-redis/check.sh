#!/usr/bin/env bash
# 实验 7 检查：缓存确实提升了速度，而且能从数字上看出来。
#
# 这里的主要检查是行为层面的，而非结构层面的。脚本自己取一个未使用过的
# 标识符，请求它两次并观察：第一次应当是几百毫秒的未命中，第二次是个位数
# 毫秒的命中。就算清单里配好了正确的环境变量，只要缓存实际上没有响应，
# 也通不过这项检查。
#
# 两个集群：KUBECONFIG 是你的 lab 集群，COZY_KUBECONFIG 是 Cozystack
# 管理集群，托管的 Redis 服务就运行在那里。

# LAB_NAME 和 LAB_TITLE 会写入报告表头。接着引入公共检查库：ok / warn /
# fail / evidence / finish 都来自它，最重要的还有 in_cluster_curl —— 它会在
# 集群内部拉起一个一次性的带 curl 的 pod。是从内部，而不是从虚拟机：实验
# 的服务没有对外暴露，passes-api 只能在集群内部通过名字访问。need_kubeconfig
# 和 need_tenant 会在访问权限或租户编号未设置时提前中止脚本，—— 否则所有
# 检查会一次性全部失败，从报告里也就无法判断原因。
LAB_NAME="07-redis"
LAB_TITLE="实验 7 · 在慢后端前面加缓存"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# 整个检查关注的名字和地址都集中在一处：不必在脚本正文里到处查找它们。
# 如果你的租户访问权限不在默认位置，COZY_KUBECONFIG 可以从外部覆盖。
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# 整个脚本用到的两个简写：kget 访问 lab 集群（也就是 KUBECONFIG 里的那个），
# cozy 访问 Cozystack 管理集群。错误信息被有意抑制：这里对象缺失是正常情况，
# 脚本会用自己的话并附带提示来说明，而不是搬用 kubectl 的别人的文本。
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# 从 JSON 里取出一个字段。不用 jq：光装的 macOS 上没有它，而 python3 在检查库
# 其余部分能运行的地方到处都有。
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- 管理集群上托管的 Redis 服务 --------------------------------------------
# Redis 不在你的 lab 集群里，而在管理集群的某个租户中：它是托管服务，由平台
# 自己维持运行。每个人在租户里的权限各不相同，所以无论是访问被拒绝还是缺少
# kubeconfig 都不会让实验失败 —— 缓存是否工作我们在下面直接用实时请求检查，
# 这才是真正的证据。
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "未找到租户 kubeconfig ${COZY_KUBECONFIG} —— 未检查 Redis 状态" \
       "指定路径：export COZY_KUBECONFIG=~/.kube/config"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "无法查看租户 ${TENANT_NS} 中的 Redis 应用" \
         "你在租户里的角色可能不允许这条命令 —— 这不是实验的错误；缓存是否工作在下面直接检查"
  elif [ -z "$REDIS_LIST" ]; then
    fail "租户 ${TENANT_NS} 中一个 Redis 应用都没有" \
         "在仪表盘里创建它：创建应用 -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "托管 Redis «${R_NAME}» 已就绪，数据副本数：${R_REPLICAS:-默认}"
    else
      warn "Redis «${R_NAME}» 存在，但未报告就绪状态" \
           "在仪表盘里查看它的状态；启动需要三到五分钟"
    fi
    evidence "租户中的 Redis" "$REDIS_LIST"
  fi
fi

# --- 慢速目录服务在位且确实很慢 ---------------------------------------------
# 没有这项检查，「之前与之后」的对比就毫无意义：如果目录服务瞬间就响应，
# 那就没什么可加速的，缓存也无从测量。
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "目录服务 ${HR} 没有运行" \
       "应用 hr-legacy.yaml 并查看 kubectl describe pod -l app=hr-legacy"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "目录服务用了 ${HR_MS} 毫秒响应 —— 有可加速的空间"
    evidence "目录服务延迟" "每次 /employee 请求 ${HR_MS} 毫秒"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "目录服务 ${HR} 未对请求作出响应" \
         "查看 kubectl logs -l app=hr-legacy"
  else
    warn "目录服务用了 ${HR_MS} 毫秒响应，这太快了，无法测量" \
         "确认 hr-legacy.yaml 里设置了 MODE=hr 和 HR_DELAY=800ms"
  fi
fi

# --- 应用已配置为使用缓存 ----------------------------------------------------
# 我们用 python 而不是 jsonpath 来解析容器的环境变量：jsonpath 对嵌套列表的
# 过滤在不同 kubectl 版本里表现不一致，而我们在意的是这项检查对每个人都一样地
# 工作。
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

# 各种问题按顺序处理 —— 从最一般到最具体：没有应用、没有变量、地址处还留着
# 占位符。这里的顺序不是装饰性的：否则参与者会在服务本身尚未部署的时刻，
# 收到「填上 Redis 地址」的建议，从而在错误的地方找问题。
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "lab 集群里没有应用 ${APP}" \
       "应用 passes-api.yaml，并填入你自己的 Harbor 地址"
elif [ -z "$REDIS_ADDR" ]; then
  fail "${APP} 中未设置 REDIS_ADDR 变量 —— 缓存已关闭" \
       "应用补丁：kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "补丁里仍留着占位地址 REDIS-ADDR" \
       "填入你自己的 Redis 地址，例如 rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "应用已配置为使用地址 ${REDIS_ADDR} 处的缓存，条目存活时间 ${TTL:-默认} 秒"
fi

# 我们只看变量名是否存在，任何地方都不读取也不打印它的值。人们会把实验报告
# 互相转发并附到工单上 —— 一旦密码进到那里面，就会永远留在那里。
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "Redis 密码已传入应用（值：<已隐藏>）"
else
  fail "${APP} 中未设置 REDIS_PASSWORD 变量" \
       "Redis 需要身份认证；创建 redis-password 密文并应用 cache-patch.yaml"
fi

# 缺少密文是警告，而不是失败：密码也可以用别的方式送入 pod。这里检查的属性
# 不一样 —— 清单里放的是一个引用，而不是值。
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "带有 Redis 密码的 redis-password 密文存在"
else
  warn "集群里没有 redis-password 密文" \
       "创建它：read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- 主要检查：缓存确实提升了速度 -------------------------------------------
# 我们故意取一个全新的标识符，好让第一次请求必定是未命中。
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "服务 ${APP} 没有返回预期的 JSON" \
       "查看 kubectl logs -l app=passes-api；确认镜像是从本实验的 app/ 构建的（标签 v2）"
  evidence "服务返回了什么" "第一次请求：${R1:-空}
第二次请求：${R2:-空}"
elif [ "$MODE" != "redis" ]; then
  fail "应用报告缓存已关闭（cache: ${MODE}）" \
       "REDIS_ADDR 变量没有到达正在运行的 pod —— 查看 kubectl rollout status deployment/${APP}"
elif [ "$C1" = "True" ]; then
  warn "第一次请求就已经来自缓存 —— 没有可对比的对象" \
       "标识符发生了不太可能的碰撞；请再运行一次检查"
elif [ "$C2" != "True" ]; then
  fail "对同一标识符的第二次请求又一次未命中缓存" \
       "应用无法写入 Redis：查看 kubectl logs -l app=passes-api，那里通常是 NOAUTH 或超时"
  evidence "服务的响应" "第一次：${R1}
第二次：${R2}"
else
  ok "缓存工作正常：未命中 ${T1} 毫秒，命中 ${T2} 毫秒"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "超过 1000")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "在实时服务上的测量" "标识符：${PROBE_ID}
第一次请求（未命中）：  ${T1} 毫秒
第二次请求（命中）：${T2} 毫秒
提速：大约 ${SPEEDUP} 倍
条目存活时间：${TTL:-默认} 秒"

  # 严格的部分：命中必须比未命中快一个数量级。否则「缓存工作正常」只意味着
  # 键被写入了，但并没有带来收益。
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "收益是可测量的：命中大约比未命中快 ${SPEEDUP} 倍"
  else
    warn "缓存命中没有带来明显收益（${T1} 毫秒 对比 ${T2} 毫秒）" \
         "确认目录服务确实很慢，并且 Redis 不在同一个 pod 上"
  fi
fi

# --- 有多少份服务副本共享同一个缓存 -----------------------------------------
# 缓存被所有副本共享 —— 这一点值得在报告里看到：命中可能来自与未命中不同的
# pod，而这是正确的。
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "正在运行的服务副本数：${API_PODS}（它们共享缓存）"
  evidence "服务副本" "$(kget pods -l app=passes-api -o wide)"
else
  fail "${APP} 没有一份正在运行的副本" \
       "查看 kubectl describe pod -l app=passes-api"
fi

finish
