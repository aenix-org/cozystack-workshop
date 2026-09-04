#!/usr/bin/env bash
# 实验 5 检查：集群状态从 Git 而来，并由持续调和保持不变。
#
# 在你的 `lab` 集群上运行，从实验目录、由你本人执行：
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# 它不改动任何东西——只查看并打印报告：检查了什么、通过了什么、
# 没通过什么，以及附上的证据。
#
# 我们检查的不是「Flux 已安装」，而是「机制是否运转」：源被读取、已应用的内容
# 归属于 Flux、服务能响应、调和没有被关闭。已安装但被暂停的 Flux，
# 是通过实验却错过其要义的最常见方式。

LAB_NAME="05-gitops"
LAB_TITLE="实验 5 · 基础设施存于 Git"
# 所有实验共用的框架：ok / fail / warn / evidence / finish 以及环境检查都来自它。
# 路径是相对于本文件的位置解析的，因此脚本可以从任意目录运行。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 没有集群访问文件就无从检查——立即退出并给出清晰的原因。
need_kubeconfig

# 本实验创建的名称。集中放在一处：如果参与者给对象起了不同的名字，
# 在这里修改即可，而不必满脚本地找名字。
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# 读取对象的某个字段，若对象或 CRD 不存在也不报错退出。
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux 服务 -----------------------------------------------------------
# 我们检查的不是「Pod 存在」，而是「至少有一个副本处于 Ready」：Pod 可能因节点上
# 内存不足而卡在 Pending，却仍然出现在 get pods 的输出里。
# 两个服务都是必需的，并分工协作：source-controller 下载仓库，
# kustomize-controller 应用下载到的内容。没有第二个，任何东西都到不了集群。
if ! kget namespace flux-system >/dev/null; then
  fail "集群中没有 flux-system 命名空间" \
       "Flux 未安装：flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "Flux 服务正在运行：source-controller 和 kustomize-controller"
    evidence "Flux Pod" "$(kget pods -n flux-system -o wide)"
  else
    fail "Flux 服务未运行：${FLUX_BAD}" \
         "查看 kubectl get pods -n flux-system；在小节点上它们可能内存不足"
  fi
fi

# --- 源：GitRepository ------------------------------------------------
# 三种不同的结局，绝不能混淆：对象根本不存在；对象存在但里面仍是占位地址；
# 对象存在且地址是真实的，但 Flux 无法读取仓库。每种情况的建议都不同，
# 所以分支也不同。
#
# 成功的标志取自 status.conditions——那是 Flux 在尝试访问 Git 之后对自身状态的
# 汇报，而不是我们凭对象是否存在所作的猜测。
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "集群中没有 GitRepository 类型" \
       "Flux 未安装，或安装时缺少 source-controller"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "在 flux-system 中未找到名为 ${GITREPO} 的 GitRepository" \
         "应用 flux/gitrepository.yaml，并替换为你自己仓库的地址"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "GitRepository 里仍是占位地址" \
         "打开 flux/gitrepository.yaml，填入你自己在 GitHub 上仓库的地址"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux 正在读取你的仓库：${GR_URL}"
    evidence "Git 中的源" "url: ${GR_URL}
revision: ${GR_REV:-未知}"
  else
    fail "Flux 无法读取仓库 ${GR_URL}" \
         "查看 flux get sources git；最常见的原因是地址拼写错误、私有仓库或分支不对"
    evidence "源错误" "${GR_MSG:-无消息}"
  fi
fi

# --- 应用：Kustomization ----------------------------------------------
# 这里检查的不是「是否应用」这一事实，而是机制的三个属性，缺了它们实验就失去意义：
# 已应用的修订与 Git 一致、调和没有被暂停、并且启用了对从仓库中消失内容的清理。
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "集群中没有 Kustomization 类型" \
       "Flux 安装时缺少 kustomize-controller——请带上两个组件重新安装"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "在 flux-system 中未找到名为 ${KUSTOMIZATION} 的 Kustomization" \
         "应用 flux/kustomization.yaml"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux 已应用来自 Git 的状态，修订 ${KS_REV}"
    evidence "已应用的修订" "$KS_REV"
  else
    fail "Flux 无法应用来自 Git 的状态" \
         "查看 flux get kustomizations 以及 kubectl describe kustomization ${KUSTOMIZATION} -n flux-system"
    evidence "应用错误" "${KS_MSG:-无消息}"
  fi

  # 被暂停的 Flux 看起来已安装，却什么也不做。这是「通过」实验却得不到它
  # 任何一点好处的主要方式。
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "调和已被暂停（suspend: true）——Flux 没有在盯着集群" \
         "重新开启：flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "调和处于活动状态：与 Git 的偏差会自行被纠正，间隔 ${KS_INTERVAL:-默认}"
  fi

  # 这是 warn，不是 fail：没有 prune，集群仍由 Git 管理，实验算通过。
  # 但描述会变得片面——删除文件并不会在集群里删除任何东西。
  if [ "$KS_PRUNE" = "true" ]; then
    ok "已启用对从 Git 中消失内容的清理（prune）"
  else
    warn "prune 已关闭——从仓库中移除的内容会继续在集群里运行" \
         "在 flux/kustomization.yaml 中设置 prune: true，否则 Git 只描述了状态的一半"
  fi
fi

# --- 集群中的对象归属于 Flux，而非手工应用 ---------
# 这是本实验的关键检查，它关乎来源，而非是否存在。两种情况下应用都在集群里：
# 无论是 Flux 引入的，还是参与者用 kubectl apply 手工应用了同样的文件。
# 从外部看无法区分——Deployment 是一模一样的。
# 归属标签才能分辨它们：只有 kustomize-controller 在应用仓库内容时才会打上它。
# 手工应用的对象不会获得该标签。
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "命名空间 ${NS_APP} 中没有 passes 应用" \
       "把 app/*.yaml 放进你仓库的 apps 目录，push，然后等待调和"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "集群中的应用归属于 Flux，而非手工应用"
else
  fail "passes 应用存在，但不是 Flux 创建的" \
       "移除它（kubectl delete ns ${NS_APP}），让 Flux 从 Git 重新部署它"
fi

# --- 应用确实能响应 --------------------------------------
# 集群中的对象和一个正常工作的服务是两回事：Deployment 可能已创建，
# 而 Pod 却在不断崩溃重启。所以我们进入集群内部，按服务的内部名称请求它——
# 走的正是相邻应用访问它时所走的路径。
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Пропуск'; then
  ok "«Пропуск» 服务在集群内部通过 HTTP 响应（运行中的副本数：${PODS_READY}）"
else
  fail "«Пропуск» 服务在 passes.${NS_APP}.svc.cluster.local 上没有响应" \
       "查看 kubectl get pods -n ${NS_APP} 以及 kubectl logs -n ${NS_APP} deploy/passes"
fi

# 页面上的 Pod 名称必须与真正运行的副本一致：这样才能表明响应正来自
# 我们在集群里看到的那个 Pod，而不是缓存的回答，也不是恰好占用了同名的
# 别的服务。不一致是 warn，不是 fail：副本可能在两次请求之间被重建了，
# 这不是参与者的过错。
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "页面由真实存在的 Pod ${SERVED_POD} 提供"
  evidence "服务副本" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "响应中的 Pod ${SERVED_POD} 未在运行中的 Pod 里找到" \
       "很可能副本在两次请求之间被重建了——请再运行一次检查"
fi

# --- 你本地仓库克隆中的变更历史 ----------------------------
# 可选部分：在被告知之前，脚本并不知道克隆在哪里。
# 这里检查的是回滚的方式。用 kubectl rollout undo 集群也会回到上一个版本，
# 但 Git 对此一无所知，紧接着的下一次调和就会把坏的变更又带回来。所以我们
# 在历史里查找 revert——回滚要做在真相所在之处。并且我们核对集群里已应用的
# 修订与你的 HEAD 是否一致：提交后忘了 push 是常事，而从外面看这就像「Flux 卡住了」。
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "未检查仓库历史：未设置 LAB_REPO 变量" \
       "要连它一起检查：export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "${REPO} 中没有仓库克隆" \
       "请指定你执行 git clone 的那个目录"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "历史中有一次通过 git revert 的回滚——坏的变更在真相所在之处被撤销了"
    evidence "变更历史" "$LOG"
  else
    fail "最近的提交里没有一次 revert" \
         "用 git revert --no-edit HEAD 回滚坏的变更并 push，而不要用 kubectl rollout undo"
  fi

  # 集群里已应用的内容必须与分支上最新的提交一致。
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "集群中运行的正是你分支里的内容（提交 ${HEAD_SHA}）"
  elif [ -n "$HEAD_SHA" ]; then
    warn "集群中的提交（${KS_REV:-未知}）与本地 HEAD（${HEAD_SHA}）不同" \
         "检查本地提交是否已 push（git push），并等待调和间隔"
  fi
fi

finish
