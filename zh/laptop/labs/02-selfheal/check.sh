#!/usr/bin/env bash
# 实验 2 的检查：自愈。
#
# 我们检查的不是「命令是否敲过」，而是实验之后的集群状态：应用重新
# 通过 Service 提供请求服务，返回其副本的名字，并且这个名字属于
# 一个真正在运行的 Pod。此外我们还查找副本被重建过的痕迹。
#
# 脚本不删除也不创建任何东西，除了一个一次性的 Pod 用于从集群内部
# 检查服务可用性 —— 它会自行清除自己。

LAB_NAME="02-selfheal"
LAB_TITLE="实验 2 · 杀掉一个 Pod，看看会发生什么"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# 把 kubectl 的 RFC3339（始终是带 Z 的 UTC）转成 unix 秒。用 python3，因为
# macOS 上的 BSD date 和 Linux 上的 GNU date 解析日期的方式不同，而只要 lib.sh
# 能工作的地方，python 都在。
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- 应用到底存不存在 ------------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "应用 ${APP} 不在集群里" \
       "在实验的最后本该把它恢复回来：kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "namespace 里现有什么" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "应用 ${APP} 已恢复：就绪副本 ${HAVE} / ${WANT}"
else
  fail "就绪副本 ${HAVE}，而请求的是 ${WANT}" \
       "查看 kubectl describe deployment ${APP} 以及 kubectl get pods -l app=${APP}"
fi
evidence "应用状态" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- Deployment -> ReplicaSet -> Pod 链条 -------------------------------
# 这个实验的要点在于：副本是由 ReplicaSet 恢复回来的，而不是「集群笼统地」恢复的。
# 如果 Pod 的属主结果不是 ReplicaSet，说明参与者是手工拉起的 Pod，
# 那他就看不到自愈。
# 我们按名字逐个数 Pod，而不是去收集唯一的属主种类：没有
# ownerReferences 的 Pod 会让 jsonpath 返回空字符串，`sort -u` 会把它折叠成一个不可见的
# 元素，只要有哪怕一个 Pod 由 ReplicaSet 管理，`*ReplicaSet*` 就会匹配上。
# 正因如此，一个手工拉起的外来 Pod 会不被察觉地通过检查。
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "没有任何带标签 app=${APP} 的 Pod" \
         "恢复应用：kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "没有任何 ${APP} 的 Pod 由 ReplicaSet 管理 —— 不会有自愈" \
         "看起来 Pod 是手工拉起的（kubectl run）。删掉它并应用 ../01-deploy/rickroll.yaml"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "标签 app=${APP} 被外来 Pod 占用：${PODS_TOTAL} 个里只有 ${PODS_BY_RS} 个由 ReplicaSet 管理" \
           "其余的会进入负载均衡并返回别人的响应 —— 找出它们：kubectl get pods -l app=${APP} -o wide"
      evidence "Pod 的属主" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "副本由 ReplicaSet 管理 —— Deployment → ReplicaSet → Pod 链条完整"
    evidence "谁是谁的属主" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- 副本被重建的痕迹 ----------------------------------------------
# 集群不保存「Pod 被杀过」的直接证据。有两个间接的，而且各自都足够：
# Pod 明显比它的 Deployment 年轻，以及 ReplicaSet 事件里创建次数不止一次。
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "副本比应用年轻 ${DELTA} 秒 —— 说明先前那个被清除了，这个是顶替它创建的"
  else
    warn "副本几乎和应用同龄（相差 ${DELTA} 秒）" \
         "如果你是在最后把整个应用整体恢复的 —— 那是正常的；否则删除 Pod 的那一步没有做"
  fi
  evidence "对象的年龄" "deployment 创建于：${DEP_TS}
pod 创建于：        ${POD_TS}
相差：              ${DELTA} 秒"
else
  warn "无法比较 Pod 和应用的年龄" \
       "需要 PATH 里有 python3；这不影响实验的通过"
fi

# 事件只存活约一个小时，所以它们的缺失不是失败，而是一个提示。
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "集群事件里有 ${CREATES} 次副本创建 —— 自愈确实触发过"
  evidence "副本创建事件" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "集群事件里只见到副本创建 ${CREATES} 次" \
       "事件只保存约一个小时，可能已经过期了"
fi

# 这两个迹象单独看都不是阻断性的：事件只存活约一个小时，
# 而对于在实验最后合法地把整个应用整体恢复的人来说，年龄是吻合的。
# 但如果两个都不成立 —— 副本根本没被删过，实验就没做。没有这个
# 组合判断，脚本会在实验 1 之后立刻就打印「实验通过」，一次删除都不等。
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "没有找到自愈的痕迹：副本没有被删过" \
       "删掉副本：kubectl delete pod -l app=${APP} —— 并在一小时内、趁事件还在时运行检查"
fi

# --- 服务是否真的在提供服务 --------------------------------------------
# 最主要的实质检查：不是「对象存在」，而是「通过 Service 能拿到一个页面
# 并且里面有一个活着的副本的名字」。
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} 没有从集群内部返回页面" \
       "检查端点：kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "页面返回了，但副本名字没有被替换进去" \
       "ConfigMap rickroll-conf 丢失了：完整应用 ../01-deploy/rickroll.yaml"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "Service 的响应里没有副本名字" \
         "页面不是来自我们的应用 —— 检查 kubectl get svc ${APP} -o yaml"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service 返回了页面，是活着的副本 ${SERVED} 提供的"
    evidence "Service 的响应（片段）" \
      "$(printf '%s' "$BODY" | grep -o "为您服务的 Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "页面由副本 ${SERVED} 提供，但集群里已经没有这个 Pod 了" \
         "等十来秒再运行一次检查 —— 副本很可能正好在这会儿发生变化"
  fi
fi

# --- 为下一个实验做好准备 -------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "副本数已恢复为一个 —— 实验 3 将从一张白纸开始"
else
  warn "现在请求的副本数：${WANT}" \
       "在实验 3 之前恢复为一个：kubectl scale deployment ${APP} --replicas=1"
fi

finish
