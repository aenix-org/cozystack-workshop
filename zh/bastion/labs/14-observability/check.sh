#!/usr/bin/env bash
# 实验 14 检查：可观测性确实生效。
#
# 「学员看了某张图表」是无法验证的，假装可以验证是不诚实的。
# 所以我们检查让图表成为可能的前提条件：
#   1) 指标采集代理在集群中运行，
#   2) 它把采集到的数据发送到你的租户，而不是发进虚空，
#   3) 日志采集同样在工作——没有它，实验有一半就失去了意义，
#   4) 集群中留有实验 3 的负载痕迹，可以在图表中找到它。

LAB_NAME="14-observability"
LAB_TITLE="实验 14 · 可观测性：在图表中找到你自己的那次尖峰"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- 采集所在的 namespace ---------------------------------------------------
# namespace 本身什么也证明不了：平台也会把 metrics-server 放在那里，
# 它会安装到任何带 etcd 的集群上，与该扩展无关。我们检查它是否存在，
# 只是为了把「集群不可达」和「采集被关闭」区分开。
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "集群中没有 namespace ${MON_NS}——集群的响应与预期不符" \
       "启用该扩展：仪表盘 -> Kubernetes -> lab -> 编辑 -> Addons -> Monitoring agents。请注意：记录只会从此刻起才开始出现"
  finish
  exit $?
fi

# --- 指标代理 ---------------------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "指标采集代理正在运行（vmagent pod 数：${VMAGENT_RUNNING}）"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "指标采集代理存在，但没有运行（${VMAGENT_TOTAL} 个中有 ${VMAGENT_RUNNING} 个处于 Running）" \
       "查看原因：kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "${MON_NS} 中没有任何 vmagent pod——Monitoring agents 扩展被关闭了" \
       "启用它：仪表盘 -> Kubernetes -> lab -> 编辑 -> Addons -> Monitoring agents。记录只会从此刻起才开始积累，过去的数据无法找回"
fi
evidence "${MON_NS} 中的采集 pod" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- 指标究竟发往何处 -------------------------------------------------------
# 一个把数据写进虚空的正常代理，看起来和真正工作的代理一模一样。
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "指标正在发送到租户${TARGET_NS:+（${TARGET_NS}）}"
      ;;
    *)
      warn "指标正在发送到一个看起来不像租户的地址" \
           "如果主讲人配置了共享存储，这也可能是正常的；该地址见证据"
      ;;
  esac
  evidence "指标发往何处" "$RW_URL"
else
  warn "无法读取指标的发送地址" \
       "手动查看：kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- 日志采集 ---------------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "日志采集在所有节点上都工作正常（${FB_READY}/${FB_DESIRED}）"
elif [ -n "$FB_DESIRED" ]; then
  fail "日志采集并未在所有节点上运行（${FB_DESIRED} 个中有 ${FB_READY:-0} 个）" \
       "查看：kubectl -n ${MON_NS} get pods | grep fluent-bit——没有它，按日志检索的步骤将无法完成"
else
  warn "未找到 fluent-bit 日志采集器" \
       "Grafana 中的 vlogs-generic 数据源将是空的；按日志检索的步骤将无法完成"
fi

# --- 图表里是否有东西可找 ---------------------------------------------------
# 指标可能采集得完美无缺，但如果当时没有负载，也就无从可找。
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "负载痕迹存在：自动扩缩容触发过（最近一次 ${LAST_SCALE}）"
    evidence "自动扩缩容状态" "$(kubectl get hpa rickroll 2>/dev/null)
最近一次触发：${LAST_SCALE}
当前副本数：${CUR:-?}，期望副本数：${DES:-?}"
  else
    warn "自动扩缩容已配置，但从未触发过" \
         "你将找不到副本增长的台阶；用 fortio 生成器重复实验 3 的负载"
  fi
else
  warn "集群中没有名为 rickroll 的 HorizontalPodAutoscaler" \
       "本实验中的图表步骤依赖实验 3；没有它，你只能找到 CPU 尖峰，而找不到台阶"
fi

# --- 应用自身的指标 ---------------------------------------------------------
# 间接但关键：如果应用 pod 还活着，它们的资源消耗就会出现在图表中。
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "应用 pod 都在（${APP_PODS} 个）——它们的资源消耗在图表中可见"
  evidence "应用 pod" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "集群中没有 rickroll 应用的 pod" \
       "实验 3 期间的历史指标仍然保留着；只需在 Grafana 中设置对应的时间范围即可"
fi

# --- 在哪里找 Grafana -------------------------------------------------------
# 这不是检查，而是帮助：Grafana 地址是学员们找得最久的东西。
: "${COZY_KUBECONFIG:=$HOME/.kube/config}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "查看你的指标的 Grafana：https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
租户 ${TNS} 的指标存储在 namespace ${MON_TARGET} 中"
    else
      warn "你的租户的监控位于 ${MON_TARGET}，但无法读取 Grafana 地址" \
           "如果 ${MON_TARGET} 不是你的 namespace，那么 Grafana 是共享的：向主讲人询问地址"
      evidence "租户监控" "带监控的 namespace：${MON_TARGET}"
    fi
  else
    warn "无法确定租户 ${TNS} 的指标发往何处" \
         "向主讲人询问 Grafana 地址，或在仪表盘中查找：Monitoring 应用 -> Ingress"
  fi
else
  warn "未能确定 Grafana 地址" \
       "设置 COZY_TENANT 和 COZY_KUBECONFIG，脚本就会自行找到它；这不影响实验的通过"
fi

finish
