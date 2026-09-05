#!/usr/bin/env bash
# 实验 2 检查：自愈。
#
# 我们验证的不是「命令是否敲过」，而是实验之后集群的状态：应用重新
# 通过 Service 提供请求服务，返回它某个副本的名字，且该名字属于
# 一个真正在运行的 Pod。此外还查找副本被重建过的痕迹。
#
# 脚本不删除也不创建任何东西，只有一个一次性 Pod 用于从集群内部检查
# 服务可用性——它会自己清理掉。

LAB_NAME="02-selfheal"
LAB_TITLE="实验 2 · 杀掉一个 Pod，看看会发生什么"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# 把 kubectl 的 RFC3339（始终是带 Z 的 UTC）转换为 unix 秒。用 python3，因为
# macOS 上的 BSD date 和 Linux 上的 GNU date 解析日期的方式不同，而 python 在
# lib.sh 能运行的所有环境里都存在。
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- 应用到底存不存在 ------------------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "集群里没有应用 ${APP}" \
       "实验结束时你本应把它恢复回来：kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "namespace 里现有的内容" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "应用 ${APP} 已恢复：就绪副本 ${HAVE} / ${WANT}"
else
  fail "就绪副本 ${HAVE}，请求的是 ${WANT}" \
       "查看 kubectl describe deployment ${APP} 和 kubectl get pods -l app=${APP}"
fi
evidence "应用状态" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- 链路 Deployment -> ReplicaSet -> Pod ----------------------------------
# 本实验的要点在于副本是由 ReplicaSet 带回来的，而不是「集群大体上」带回来的。
# 如果 Pod 的属主原来不是 ReplicaSet，说明学员是手动把 Pod 起起来的，
# 那他就看不到自愈。
# 我们按名字逐个数 Pod，而不是去收集唯一的属主种类：对于没有 ownerReferences
# 的 Pod，jsonpath 返回空字符串，`sort -u` 会把它塌缩成一个不可见的元素，
# 只要有哪怕一个 Pod 由 ReplicaSet 管理，`*ReplicaSet*` 就会匹配。
# 正因如此，手动起的多余 Pod 会不被察觉地通过检查。
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
         "把应用带回来：kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "没有任何 ${APP} Pod 由 ReplicaSet 管理——不会发生自愈" \
         "看起来 Pod 是手动起的（kubectl run）。删掉它并应用 ../01-deploy/rickroll.yaml"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "标签 app=${APP} 被多余的 Pod 占用了：${PODS_TOTAL} 个中只有 ${PODS_BY_RS} 个由 ReplicaSet 管理" \
           "其余的会进入负载均衡并返回别人的响应——找出它们：kubectl get pods -l app=${APP} -o wide"
      evidence "Pod 的属主" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "副本由 ReplicaSet 管理——链路 Deployment → ReplicaSet → Pod 完整"
    evidence "谁是谁的属主" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- 副本被重建的痕迹 ------------------------------------------------------
# 集群不会保存「Pod 被杀过」的直接证据。有两条间接证据，二者都各自足够：
# Pod 明显比它的 Deployment 年轻，以及 ReplicaSet 的事件里出现不止一次创建。
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "副本比应用年轻 ${DELTA} 秒——说明旧的被清掉了，这个是顶替它新建的"
  else
    warn "副本几乎和应用同龄（差 ${DELTA} 秒）" \
         "如果你是在最后把整个应用重新恢复的——这是正常的；否则说明删除 Pod 那一步没做"
  fi
  evidence "对象年龄" "deployment 创建于: ${DEP_TS}
pod 创建于:        ${POD_TS}
差值:              ${DELTA} 秒"
else
  warn "无法比较 Pod 和应用的年龄" \
       "PATH 里需要 python3；这不影响本实验的通过"
fi

# 事件大约只保留一小时，所以它们缺失并不算失败，只是一个提醒。
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "集群事件里有 ${CREATES} 次副本创建——自愈确实触发过"
  evidence "副本创建事件" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "集群事件里只看到 ${CREATES} 次副本创建" \
       "事件大约只保留一小时，可能已经过期了"
fi

# 这两个迹象单独看谁都不是阻断性的：事件大约只活一小时，
# 而对于在实验结束时正当地把整个应用重新恢复的人，年龄也会一致。
# 但如果两者都不满足——说明副本根本没被删过，实验没做完。没有这个组合，
# 脚本会在实验 1 之后立刻打印「实验通过」，根本没等到任何一次删除。
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "没有找到自愈的痕迹：副本没被删过" \
       "删掉副本：kubectl delete pod -l app=${APP}——并在一小时内运行检查，趁事件还在"
fi

# --- 服务是否真的在提供服务 ------------------------------------------------
# 最主要的实质性检查：不是「对象存在」，而是「有一个页面通过 Service 返回
# 并且里面有一个活副本的名字」。
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} 没有从集群内部返回页面" \
       "检查端点：kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "页面返回了，但副本名字没有被替换进去" \
       "ConfigMap rickroll-conf 丢了：完整应用 ../01-deploy/rickroll.yaml"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "Service 的响应里没有副本名字" \
         "页面不是来自我们的应用——检查 kubectl get svc ${APP} -o yaml"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service 返回了页面，是由活副本 ${SERVED} 提供的"
    evidence "Service 响应（片段）" \
      "$(printf '%s' "$BODY" | grep -o "为您服务的 Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "页面是由副本 ${SERVED} 提供的，但集群里已经没有这个 Pod 了" \
         "等十来秒再运行一次检查——很可能副本正好在此刻发生变化"
  fi
fi

# --- 为下一个实验做好准备 --------------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "副本数量已恢复为一个——实验 3 将从一张白纸开始"
else
  warn "当前请求的副本数：${WANT}" \
       "在实验 3 之前把它恢复为一个：kubectl scale deployment ${APP} --replicas=1"
fi

finish
