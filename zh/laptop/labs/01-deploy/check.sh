#!/usr/bin/env bash
# 实验 1 的检查：应用已部署并且确实正常工作。
#
# 这里的「确实」是指：页面真正通过 HTTP 被返回，其中替换进了 Pod 名称，
# 并且该名称与真正运行中的某个副本的名称一致。检查 Deployment 对象是否存在
# 毫无意义——它可以存在却不工作。
#
# 在笔记本上运行，从本实验的目录，凭借对学习集群 `lab` 的访问
#（不是对管理集群上某个租户的访问）：
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# 这里不需要 COZY_TENANT 变量：整个实验都在 `lab` 集群内进行。
#
# 脚本不会改动集群中的任何内容——它只读取并发送 HTTP 请求。
# 请在清理之前运行它：应用删除之后就没有什么可检查的了。

# 这两个变量由 lib.sh 读取——它们会进入报告头部，并进入脚本写在自己旁边的
# 文件名 report-<实验>-<日期>.md。
LAB_NAME="01-deploy"
LAB_TITLE="实验 1 · 你的第一个应用"
# 公共检查库：ok / fail / warn / evidence / finish 都来自这里，
# 还有集群内页面请求和报告写入。路径是从脚本自身所在位置计算的，
# 因此从任何目录运行都一样。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 如果没有设置 KUBECONFIG 就立即停止。没有它 kubectl 会在笔记本本身上
# 寻找集群，找不到，然后用同一个错误接连搞垮每一项检查，
# 让真正的原因被掩盖。
need_kubeconfig

# --- 应用对象 ------------------------------------------------------
# 第一道防线：应用确实存在，并且至少有一个副本已达到就绪状态。
# 我们看的是 .status.readyReplicas，而不是 Deployment 是否存在这个事实：对象
# 会即刻创建且总是成功，而就绪意味着某个副本已经启动、
# 通过了就绪检查、并且能够响应。
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # 特殊情况：对象存在，但请求的副本数为零。消息
    #「没有任何副本就绪（需要 0 个）」听起来会像胡话。
    fail "应用已停止——请求了 0 个副本" \
         "恢复一个副本：kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "应用已部署，就绪副本 ${READY} 个（共 ${DESIRED} 个）"
    # 卡住的滚动更新不会让服务宕掉：旧副本继续工作，而
    # readyReplicas 保持为一。没有这项检查，参与者会带着一个绿色
    # 勾和一个永远卡在 ErrImagePull 的 deployment 离开。
    # 我们看副本本身，而不仅仅看 ProgressDeadlineExceeded：截止时间
    # 会在十分钟后触发，而脚本是立刻运行的。旧副本此时
    # 仍在工作，readyReplicas 保持为一，没有这项检查参与者
    # 会带着一个绿色勾和一个卡在 ImagePullBackOff 的 deployment 离开。
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "滚动更新卡住了：新副本起不来，只有旧副本在工作" \
           "查看 kubectl get pods -l app=rickroll —— 通常是镜像没拉下来；恢复到可工作状态：kubectl apply -f rickroll.yaml"
      evidence "起不来的副本" "${STUCK:-原因在 Deployment 状态里：$PROG_REASON}"
    fi
  else
    fail "应用已创建，但没有任何副本就绪（需要 ${DESIRED} 个）" \
         "查看 kubectl get pods -l app=rickroll 和 kubectl describe deployment rickroll"
    evidence "Pod 状态" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "未找到名为 rickroll 的 Deployment" \
       "应用清单：kubectl apply -f rickroll.yaml"
fi

# --- 设置与页面 ---------------------------------------------------
# 两个 ConfigMap 都由与应用相同的文件创建，因此它们只能与应用一起消失
# 或者被手动删除。我们单独检查它们，这样当页面
# 出问题时，参与者能立即看到究竟缺了什么：没有 rickroll-conf
# nginx 就不会替换 Pod 名称，而没有 rickroll-page-v1 在实验 4 里就没有东西可以
# 对比第二个版本，也没有地方可以回滚。
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "设置就位：ConfigMap ${cm}"
  else
    fail "未找到 ConfigMap ${cm}" \
         "它由同一个文件创建：kubectl apply -f rickroll.yaml"
  fi
done

# --- 固定地址 -------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # 没有 endpoint 的 Service 是一种典型且不易察觉的故障：对象存在，
  # 但 Pod 上的标签没有匹配上 selector，地址后面空无一物。
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "固定地址可用，其后有副本：${EPS_N} 个"
    evidence "服务后面的地址" "$EPS"
  else
    fail "Service rickroll 存在，但其后没有任何副本" \
         "通常原因是 Pod 标签没有匹配上 service selector —— 请核对 app: rickroll"
  fi
else
  fail "未找到名为 rickroll 的 Service" \
       "它由同一个文件创建：kubectl apply -f rickroll.yaml"
fi

# --- 关键：页面真正被返回 -------------------------------------
# 这才是整件事的目的所在。之前所有的检查只说明集群中的对象
# 描述正确；这一项说明用户拿到了页面。请求是从集群
# 内部发出的，用一个一次性 Pod：从外部看 rickroll 这个地址并不存在，而
# 在这里 port-forward 检查的会是你的笔记本，而不是集群。
# 我们请求多次：当服务后面有多个副本时，单次抽样
# 可能碰不到被替换过的那个，检查就会因为别人的内容而变绿。
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# 这个标记每个页面必须恰好出现一次，否则响应计数器会说谎：
#「Never Gonna Give You Up」同时出现在 <title> 和 <h1> 里，曾导致重复计数。
ANSWERS="$(printf '%s' "$BODY" | grep -c '为您服务的 Pod')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "应用通过 HTTP 响应并返回自己的页面（已验证 ${ANSWERS} 次请求）"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "服务后面响应的不只是你的应用：你自己的页面在 ${TOTAL_LINES} 次中出现了 ${ANSWERS} 次" \
       "还有别人带着标签 app=rickroll —— 查看 kubectl get pods -l app=rickroll 并删除多余的"
else
  fail "应用没有返回预期的页面" \
       "手动检查：kubectl port-forward svc/rickroll 8080:80，然后打开 http://localhost:8080"
  evidence "返回的不是页面而是" "$(printf '%s' "$BODY" | head -20)"
fi

# --- Pod 名称替换 -------------------------------------------------
# 这正是本实验的目的：页面中的名称必须与真实的 Pod 一致。
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# 我们取由应用的 ReplicaSet 管理的 Pod，而不是所有带有标签
# app=rickroll 的东西。否则一个带该标签的外来 Pod 会进入「真实」列表
# 并自我确认——已验证，冒名者曾这样通过检查。
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "有外来 Pod 带着标签 app=rickroll —— 它们会进入负载均衡" \
       "删除多余的：$(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "带着应用标签的外来 Pod" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "页面中没有 Pod 名称" \
       "检查 ConfigMap rickroll-conf 是否被替换进去——其中有一行 sub_filter '__POD__' '\$hostname'"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "Pod 名称没有被替换——页面里还留着占位符 __POD__" \
       "nginx 没有应用 sub_filter：检查设置卷是否挂载在 /etc/nginx/conf.d"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "Pod 名称被替换进去，并且与一个真正运行中的副本一致：${SERVED_BY}"
  evidence "谁处理了这个请求" "$SERVED_BY"
  evidence "运行中的副本" "$REAL_PODS"
else
  fail "页面称 Pod 为「${SERVED_BY}」，但集群中没有这样的 Pod" \
       "该副本可能在请求与检查之间被重建了——请再运行一次脚本"
fi

# --- 就绪检查已配置 ------------------------------------------
# 没有它，版本滚动更新那个实验会出现停机，参与者会觉得我们撒了谎。
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "就绪检查已配置（${PROBE_PATH}）—— 更新将无停机进行"
else
  warn "应用没有就绪检查" \
       "关于无停机更新的实验 4 在这样的应用上会产生错误——请从 rickroll.yaml 恢复 readinessProbe"
fi

finish
