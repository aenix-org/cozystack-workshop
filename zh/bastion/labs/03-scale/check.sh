#!/usr/bin/env bash
# 实验 3 检查：自动扩缩容。
#
# 我们验证的不是「hpa.yaml 已应用」，而是机制是否活着、是否能够做出决策：
#   - 容器设置了 requests.cpu，否则百分比无从计算；
#   - HPA 存在，并且正好指向我们的 Deployment；
#   - 区间设置得有意义（maxReplicas 大于一，否则没有增长的空间）；
#   - 指标确实在被采集：状态里有具体数值，而不是 <unknown>；
#   - 扩缩容已经触发过，也就是确实施加过负载。
#
# 脚本不改动任何东西。只会拉起一个一次性 Pod，仅用于检查
# Fortio 是否能从集群内部响应，用完后自行清理。
#
# 在虚拟机上、在本实验目录下运行，使用对教学集群 `lab` 的访问
# （不是管理集群上的租户）：
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# 这里不需要 COZY_TENANT 变量：整个实验都在 `lab` 集群内部进行。
#
# 请在清理之前运行。部分检查依赖于已经发生过的增长留下的痕迹，
# 而这些痕迹与 HPA 对象共存亡：删掉它，就再也没有东西可以证明了。

# 这些会进入报告标题以及脚本旁边的文件名 report-<实验>-<日期>.md。
LAB_NAME="03-scale"
LAB_TITLE="实验 3 · 负载与自动扩缩容"
# 公共库：ok / fail / warn / evidence / finish、集群内部查询、
# 写入报告。路径按脚本自身所在位置计算，而不是按当前目录。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 没有 KUBECONFIG 时，kubectl 会在虚拟机上找集群，并用一条错误把所有东西一起搞挂，
# 从中根本看不出真正的原因。我们立刻停止。
need_kubeconfig

# 名称被提取到变量中，这样本实验里应用名与 HPA 名的一致
# 就不会看起来像同一个名字被偶然写了两遍。
APP=rickroll
HPA=rickroll

# --- 扩缩容目标就位 --------------------------------------------------------
# 实验 1 里的应用 —— 就是 HPA 所管理的对象。如果它不存在，后续所有
# 检查都会连锁失败，参与者会得到一堆错误而不是一条清晰的错误，
# 所以这里是脚本唯一提前退出的地方。
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "集群中没有应用 ${APP} —— 没有可扩缩的对象" \
       "部署它：kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "应用 ${APP} 就位"

# --- requests.cpu：没有它 HPA 无法计算百分比 -------------------------------
# 「HPA 不工作」最常见的原因，而且从清单里看不出来：
# 对象创建成功，但 TARGETS 永远停留在 <unknown>。
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "容器设置了 requests.cpu = ${REQ_CPU} —— 有了计算百分比的依据"
  evidence "容器资源" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-未设置}"
else
  fail "容器 ${APP} 未设置 requests.cpu" \
       "没有它基于 Utilization 的 HPA 无法工作；请重新应用 ../01-deploy/rickroll.yaml"
fi

# --- HPA 本身 --------------------------------------------------------------
# 我们不仅检查对象是否存在，还检查它指向谁。scaleTargetRef 里有拼写错误的
# HPA 同样能创建成功，在列表里看起来也像正常的，但整个实验它
# 管理的都是一个不存在的应用。
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "集群中没有名为 ${HPA} 的 HorizontalPodAutoscaler" \
       "应用它：kubectl apply -f hpa.yaml（请在清理之前运行检查）"
  evidence "现有的自动扩缩容对象" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA} 指向 Deployment/${APP}"
else
  fail "HPA ${HPA} 管理的是对象 ${TARGET_KIND}/${TARGET_NAME}，而不是 Deployment/${APP}" \
       "修正 hpa.yaml 里的 scaleTargetRef 并重新应用"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "区间已设置：从 ${MINR} 到 ${MAXR} 个副本 —— 有增长的空间"
else
  fail "区间的上界为 ${MAXR:-未设置} —— 没有增长的空间" \
       "hpa.yaml 里的 maxReplicas 必须大于一"
fi

# --- 指标目标 --------------------------------------------------------------
# 这里用 warn 而不是 fail：AverageValue 方案（阈值以毫核计）同样可行，
# 本实验只讲其中一种。因为它而判不通过并不符合事实。
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "阈值已设置：requests.cpu 的 ${TGT_VAL}%（${REQ_CPU:-?}）"
else
  warn "阈值不是按 requests 的百分比设置的（类型：${TGT_TYPE:-无}）" \
       "本实验讲的是 Utilization 方案；这不影响可用性"
fi

# --- 关键：指标确实在被采集 ------------------------------------------------
# 正是在这里能看出「对象已创建」和「机制在工作」之间的区别。
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "指标在被采集：当前负载为 requests 的 ${CUR_UTIL}%，HPA 正在做决策"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA 正在做决策（ScalingActive=True），当前指标值尚未上报"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA 收不到指标 —— TARGETS 里会是 <unknown>，它没有决策的依据" \
       "apply 后的头两分钟这是正常的，稍等再重试；如果没有恢复 —— kubectl top pods 以及 kubectl describe hpa ${HPA}"
  evidence "HPA 为何不活跃" "${REASON:-状态里未说明原因}"
fi

evidence "HPA 状态" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server 直接响应 -----------------------------------------------
# 从另一个角度重复上一项检查，并区分两种不同的故障：
# 「整个集群都没有指标」和「有指标，但 HPA 没取到」。
# 前者由集群管理员修复，后者由参与者在自己的清单里修复。
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# 当没有 Pod 时，`kubectl top` 会打印「No resources found」并返回 0 ——
# 没有显式的空值检查，这在完全没有指标的情况下也会给出绿色通过。
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top 未报告 Pod 的资源消耗" \
       "集群中没有可用的 metrics-server —— 没有它就无法基于 CPU 做自动扩缩容"
  evidence "kubectl top 的响应" "$TOP"
else
  ok "metrics-server 报告了 ${APP} 各 Pod 的资源消耗"
  evidence "各副本的资源消耗" "$TOP"
fi

# --- 扩缩容确实触发过 ------------------------------------------------------
# lastScaleTime 与 HPA 本身共存亡，所以这项检查不依赖于
# 集群事件是否已过期。
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# 仅有一个时间戳还不够：缩减副本时它也会被设置，也就是说
# 哪怕有人手动增加了副本、再让 HPA 移除多余的，它也会出现。我们要找的
# 正是由负载引起的增长 —— 一个超过阈值的事件。
#
# 反过来也一样：时间戳本身未必总能留存。在一小时前施加过负载的集群上，
# lastScaleTime 可能为空，而事件还活着 —— 所以先检查事件，
# 否则一个已完成的实验会被误判为不通过。
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA 因负载增加过副本数 —— 超过阈值的事件就在那里"
  evidence "扩缩容" "扩容事件数：${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-无}
currentReplicas: ${CUR_REPL:-未知}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA 改变过副本数（最近一次：${LAST_SCALE}）"
  evidence "扩缩容时间戳" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-未知}"
else
  fail "没有自动扩缩容工作过的痕迹" \
       "用 Fortio 施加负载：URL http://${APP}/，QPS 1200，Connections 80，Duration 90s"
fi

# --- Fortio：实验 4 需要 ---------------------------------------------------
# 它对实验 3 本身已经无关紧要，所以用 warn 而不是 fail。目的是让
# 参与者在这里就得知负载生成器缺失，而不是在负载下发布的中途才发现，
# 那时停下来去部署它会很不合时宜。
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "Fortio 负载生成器工作正常，并能从集群内部响应"
  else
    warn "Fortio 已部署，但它的 Web 界面没有响应" \
         "检查：kubectl rollout status deployment/fortio 以及 kubectl logs deploy/fortio"
  fi
else
  warn "集群中没有 Fortio" \
       "如果你打算做实验 4，那里会需要它：kubectl apply -f fortio.yaml"
fi

finish
