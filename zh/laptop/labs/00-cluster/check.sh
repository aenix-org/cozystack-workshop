#!/usr/bin/env bash
# 实验 0 检查：教学集群已启动且你已连接到它。
#
# 我们验证的不是「对象已创建」，而是集群在本质上是否正常工作：
#   1) lab 集群通过你的访问文件响应（KUBECONFIG=~/lab.kubeconfig），
#   2) 至少有一个节点处于 Ready 状态，
#   3) 节点上有供未来应用使用的空闲资源。
# 如果设置了 COZY_TENANT —— 还会在「管理」集群上检查 Kubernetes/lab 订单
# 是否已达到 Ready，以及是否启用了指标采集（没有它，实验 14 就是空的）。
#
# 在虚拟机上运行，从本实验的目录中：
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # 用于从租户侧进行检查（可选）
#     cd labs/00-cluster && ./check.sh
#
# 脚本只读 —— 不会改变集群状态。
LAB_NAME="00-cluster"
LAB_TITLE="实验 0 · 你自己的 Kubernetes 集群"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 如果无法访问 lab 集群本身，就没有什么可检查的 —— 这正是本实验最主要的
# 证明。如果没有设置 KUBECONFIG 或集群没有响应，need_kubeconfig 会用清晰的
# 提示停止脚本。
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) 连接到 lab 集群 ------------------------------------------------------
# need_kubeconfig 已经确认服务器有响应。我们把它作为单独的结果记录下来，
# 并把服务器版本放进报告。
KVER="$(server_version)"
ok "lab 集群有响应 —— 访问文件可用"
[ -n "$KVER" ] && evidence "lab 集群服务器版本" "$KVER"

# --- 2) 节点在岗 -------------------------------------------------------------
# 统计有多少节点处于 Ready 状态。空列表意味着集群已经启动，但 md0 节点组
# 仍在部署中。
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "节点在岗：${TOTAL_NODES} 个中有 ${READY_NODES} 个处于 Ready 状态"
  [ -n "$NODES_WIDE" ] && evidence "集群节点" "$NODES_WIDE"
else
  fail "没有任何节点处于 Ready 状态（节点总数：${TOTAL_NODES:-0}）" \
       "请等待几分钟，让 md0 节点组完成部署；状态见 lab 应用上的仪表盘，或运行：kubectl get nodes"
  evidence "集群节点" "${NODES_WIDE:-无节点}"
fi

# --- 3) 是否有供未来应用使用的空间 -------------------------------------------
# 第一个节点的 allocatable：如果没有资源，后续什么都跑不起来。
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "节点上有供应用使用的资源（在该节点上：${ALLOC_CPU} CPU，$(human_bytes "$ALLOC_MEM") RAM）"
  evidence "节点空闲资源（allocatable）" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "无法读取节点的空闲资源" \
       "通常这是暂时的 —— 请一分钟后重试"
fi

# --- 4) 从管理集群一侧（如果设置了租户） -------------------------------------
# 对实验 0 而言不是必需的：上面对集群本身的连接已经证明了一切。
# 但如果有租户访问权限 —— 我们会确认订单并检查指标采集。
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "未找到租户访问 ${COZY_KUBECONFIG} —— 未在管理侧检查集群订单" \
         "这不算实验失败；用以下命令设置路径：export COZY_KUBECONFIG=~/.kube/workshop"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "在管理集群上，Kubernetes/lab 订单处于 Ready 状态"
    elif [ -n "$LAB_READY" ]; then
      warn "Kubernetes/lab 订单尚未 Ready（当前：${LAB_READY}）" \
           "集群已经有响应，平台仍在把它调和到期望状态；查看：kubectl --kubeconfig ~/.kube/workshop -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "在租户 ${TENANT_NS} 中未找到 Kubernetes/lab 订单" \
           "如果你给集群起了别的名字 —— 请替换成你自己的名字；或者你在该租户中的角色不允许执行此命令（不算实验错误）"
    fi
    # 指标采集：实验 14 依赖于从启用那一刻起累积的数据。
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "指标采集已启用（实验 14 会用到）"
    elif [ -n "$LAB_READY" ]; then
      warn "指标采集已关闭 —— 实验 14 将没有数据" \
           "启用方法：仪表盘 → lab 应用 → Addons → Monitoring agents（指标不会追溯生成）"
    fi
  fi
else
  warn "未设置 COZY_TENANT —— 已跳过从管理集群一侧的检查" \
       "对实验 0 而言不是必需的；如需启用：export COZY_TENANT=workshopXX"
fi

finish
