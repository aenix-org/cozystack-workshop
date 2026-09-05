#!/usr/bin/env bash
# 实验 4 检查：发布新版本并回滚。
#
# 我们检查的是实质，而不是敲了哪些命令：
#   - 应用的历史里有多个修订版本，即版本确实被改过；
#   - 第二个版本的 ConfigMap 作为独立对象存在于集群中，而不是在第一个上直接修改；
#   - 容器带有 readinessProbe——没有它就无法复现零停机；
#   - 发布跑到了完成，而不是卡住；
#   - Service 提供的页面与描述所引用的 ConfigMap 一致。这能捕捉到
#     “描述已回滚，但 Pod 没有被重建”的情况。
#
# 脚本不会修改任何东西。那个一次性 Pod 只是用来从集群内部取回页面，
# 并且会自行清理。
#
# 在虚拟机上运行，从本实验的目录，使用对学习集群 `lab` 的访问权限
# （不是管理集群上的租户）：
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# 这里不需要 COZY_TENANT 变量：整个实验都在 `lab` 集群内部进行。
#
# 在清理之前、并在回滚完成之后运行：修订历史与 Deployment 一同存在，
# 也随它一同消失。

# 这些会进入报告标题，以及脚本旁边的文件名 report-<实验>-<日期>.md。
LAB_NAME="04-rollout"
LAB_TITLE="实验 4 · 发布新版本并回滚"
# 公共库：ok / fail / warn / evidence / finish，从集群内部发起请求，
# 写入报告。路径按脚本自身的位置计算，而不是当前目录。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 没有 KUBECONFIG，kubectl 会在虚拟机上找集群，并用一个错误把所有东西一起搞挂，
# 从中根本看不出真正的原因。我们立刻停下。
need_kubeconfig

APP=rickroll

# --- 应用就位并已进入工作状态 ------------------
# 没有应用就没什么可检查的，所以这里是唯一的提前退出。
# 再往后我们不仅看就绪副本的数量，还看 Progressing 条件中的原因：
# NewReplicaSetAvailable 表示发布已经完成。仅有就绪副本还不够——更新卡住时
# 运行的是旧版本，计数器显示了预期的数字，而新副本却一次都没起来过。
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "应用 ${APP} 不在集群中" \
       "部署它：kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "发布跑到了完成：${WANT} 个副本中已就绪 ${HAVE} 个"
else
  fail "应用未处于完成状态（${WANT} 个中就绪 ${HAVE} 个，原因：${PROG_REASON:-无}）" \
       "如果发布卡住了——用回滚脱身：kubectl rollout undo deployment/${APP}"
fi
evidence "应用状态" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe：为零停机付出的代价 -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "容器带有 readinessProbe（${PROBE}）——副本只有在就绪之后才会被替换"
else
  fail "容器没有 readinessProbe" \
       "没有它，集群会把流量发给未就绪的副本；请应用 ../01-deploy/rickroll.yaml"
fi

# --- 版本被做成了独立的对象 --------------------------------------
# 页面的两个版本都必须作为两个独立的 ConfigMap 存在于集群中。
# 那些改成就地修改 rickroll-page-v1 的人，会在屏幕上看到新页面，
# 并认为实验做完了——但他将无处可回滚，
# 副本替换和修订历史记录也根本不会发生。
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2 作为独立对象存在于集群中"
else
  fail "集群中没有 ConfigMap rickroll-page-v2" \
       "请应用它：kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "页面的第一个版本也被保留了——有地方可以回滚"
else
  warn "集群中未找到 ConfigMap rickroll-page-v1" \
       "没有它，回滚到第一个版本不会把 Pod 起来：kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- 修订历史 -------------------------------------------------------
# 我们看的是最新修订版本的编号，而不是历史里的行数。回滚
# 不会新增 ReplicaSet——它复用旧的并提升其编号，
# 所以回滚后历史里的行数不变，而编号在增长。
#   1 — 描述从未被改过
#   2 — 版本被切换了
#   3 及以上 — 切换了又回滚了
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "应用的最新修订版本是 ${REV_MAX}：版本被切换过又回滚过"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "最新修订版本是 2：发布做了，回滚还没做" \
       "恢复第一个版本：kubectl rollout undo deployment/${APP}"
else
  fail "最新修订版本是 ${REV_MAX}：应用的描述从未被改过" \
       "用实验里的补丁把卷切换到第二个版本，然后回滚"
fi
evidence "修订历史" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- 描述指向的是哪个版本 --------------------------------------
# 我们按名称 page 来查找卷，尽管实验里的补丁是按索引寻址它的。
# 差别恰好在这里被捕捉：如果补丁打到了列表里错误的元素上，
# 名称 page 会指向之前的 ConfigMap 或者消失，参与者会用文字得知这一点，
# 而不是通过一个奇怪的 nginx 错误。
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "应用描述已回滚到页面的第一个版本"
    ;;
  rickroll-page-v2)
    warn "应用描述指向页面的第二个版本" \
         "实验以回滚结束；如果这是有意为之——无需担心，否则：kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "描述里没有名为 page 的卷" \
         "看起来补丁打错了地方（按索引寻址！）；请重新应用 ../01-deploy/rickroll.yaml"
    ;;
  *)
    fail "卷 page 指向 ConfigMap ${VOL_CM}，而这个实验并未创建它" \
         "回滚：kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- 实际提供给客户端的是什么 ------------------------------------
# 最有实质意义的检查：把描述与用户看到的内容做对比。
# 这里出现不一致，意味着 Pod 没有为新描述而被重建。
# 是八个请求，而不是一个。服务后面有三个副本；如果发布没有完全收敛，
# 单个请求有三分之一的概率打到正确的版本，从而掩盖不一致。
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP} 没有从集群内部返回页面" \
       "检查端点：kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # 我们对两个版本都做肯定式判定，各按自己的标记。“如果不是 v2，就是
  # v1” 那种分支会把任何东西都算成第一个版本：nginx 默认页、404、别人的
  # 应用、垃圾内容——已验证，遇到垃圾内容时脚本会打印 “实验通过”。
  if printf '%s' "$BODY" | grep -q '版本 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "服务地址上提供的不是应用页面" \
         "响应里没有一个熟悉的标记——恢复原样：kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "返回的不是页面而是什么" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "提供给客户端的正是描述中记录的那个版本（${SERVED_VER}）"
  elif [ -n "$VOL_CM" ]; then
    fail "描述指向 ${VOL_CM}，而提供给客户端的是 ${SERVED_VER}" \
         "副本没有为新描述而被重建：kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "副本名称没有被填入页面" \
         "丢失了 ConfigMap rickroll-conf：完整应用 ../01-deploy/rickroll.yaml"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "页面由一个存活的副本 ${SERVED_POD} 提供"
    else
      warn "无法把页面里的名称与一个运行中的副本对应起来" \
           "很可能副本正好在检查过程中发生了变化——请再运行一次脚本"
    fi
  fi

  evidence "所提供的页面（片段）" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "为您服务的 Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- 为后续实验做好准备 ------------------------------------
# 本实验把副本扩到三个，好让替换能一个一个地看清楚。剩下的三个
# 副本不会弄坏任何东西——所以是 warn 而不是 fail——但它们会占用学习节点上的空间，
# 而后续相邻的实验会不够用。
if [ "$WANT" = "1" ]; then
  ok "副本数量已恢复到一个"
else
  warn "当前请求的副本数：${WANT}" \
       "实验之后最好恢复到一个：kubectl scale deployment ${APP} --replicas=1"
fi

finish
