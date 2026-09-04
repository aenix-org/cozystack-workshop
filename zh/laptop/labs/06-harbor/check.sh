#!/usr/bin/env bash
# 实验 6 检查：应用从它自己的私有镜像仓库部署到集群。
#
# 我们检查的不是「Harbor 已创建」，而是整条链路：仓库通过它的 API 响应，
# 清单里的镜像确实存放在其中，集群拥有针对同一地址的凭据，
# 且使用该镜像的 Pod 确实在运行并响应。
#
# 两个集群，这也是本脚本看起来比相邻脚本更复杂的主要原因：
# KUBECONFIG 是你的 lab 集群，应用在其中运行；COZY_KUBECONFIG 是
# Cozystack 管理集群，托管的 Harbor 服务在你的租户里运行。
# 无法用一条命令同时查询二者，所以下面有两种不同的调用 kubectl 的方式。
#
# 由你运行，从实验目录执行；它不改变任何东西，只查看并打印报告：
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/workshop
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="实验 6 · 你自己的私有镜像仓库"
# 所有实验的通用框架：ok / fail / warn / evidence / finish 以及环境检查。
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 没有集群访问文件、也没有租户编号，就没什么可检查的 —— 立即退出。
need_kubeconfig
need_tenant

APP="passes-api"
# 管理集群上的租户命名空间：名称由前缀 tenant- 和你的编号拼成，
# 也就是 tenant-workshopXX。编号取自环境变量，
# 无需手动把它填入脚本文本。
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# 两种调用 kubectl 的方式：kget 访问你的 lab 集群，cozy 访问管理集群。
# 错误被刻意屏蔽：这里对象不存在不是故障，而是预期结果之一，
# 由下面一个单独的分支配合清晰的建议来处理。
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 管理集群上托管的 Harbor 服务 --------------------------------------------
# 可选部分：没有租户 kubeconfig，实验仍然可检查，
# 但我们就看不到平台侧的这个服务。
#
# 我们单独捕获「命令没有生效」的情况：租户中的角色可能不允许
# 查看应用。这不是参与者的过错，也不是让检查失败的理由，所以
# 这里用 warn ——「没看到」，而不是 fail ——「做错了」。我们刻意区分命令
# 错误与空响应：空列表意味着 Harbor 根本没有被创建。
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "未找到租户 kubeconfig ${COZY_KUBECONFIG} —— 未检查 Harbor 状态" \
       "设置路径：export COZY_KUBECONFIG=~/.kube/workshop"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "无法查看租户 ${TENANT_NS} 中的 Harbor 应用" \
         "租户中的角色可能不允许此命令 —— 这不是实验错误；其余部分都会在下面检查"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "租户 ${TENANT_NS} 中没有任何 Harbor 应用" \
         "在仪表盘中创建它：创建应用 -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "托管的 Harbor 服务「${HARBOR_NAME}」已就绪"
    else
      warn "Harbor「${HARBOR_NAME}」存在，但未报告就绪" \
           "在仪表盘中查看它的状态；Harbor 启动需要 5-10 分钟，而租户中没有对象存储时它根本起不来"
    fi
    evidence "租户中的 Harbor 应用" "$HARBOR_LIST"
    # 我们不尝试读取凭据 secret：租户可以读取这个 secret，
    # 但我们在报告里终究不需要密码。
  fi
fi

# --- 应用从哪里拉取镜像 -----------------------------------------------------
# 实验的要点是镜像来自你的仓库，而不是来自互联网。这通过
# 清单中的镜像名来检查：名称中斜杠之前的第一部分就是仓库地址。
# 如果其中既没有点也没有冒号，那里根本没有地址，集群就会悄悄地
# 去 Docker Hub 拉取镜像 —— 也就是安全部门明令禁止的地方。
# 我们用单独的分支捕获 HARBOR-HOST 占位符和已知的公共仓库：
# 形式上地址在位，但实验要求未满足，而且每种情况的建议各不相同。
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "lab 集群中没有应用 ${APP}" \
       "应用 passes.yaml，并把你的 Harbor 地址填入其中"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # 看起来像仓库地址
    *) REGISTRY="" ;;          # 没有地址 —— 意味着镜像从 Docker Hub 拉取
  esac

  if [ -z "$REGISTRY" ]; then
    fail "镜像 ${IMAGE} 从公共仓库拉取，而不是从你的仓库" \
         "镜像名的第一部分应当是你的 Harbor 地址"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "清单中仍保留着占位地址 HARBOR-HOST" \
         "填入你自己的 Harbor 地址：sed -i 's|HARBOR-HOST|harbor.你的域名|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "镜像从公共仓库 ${REGISTRY} 拉取" \
         "安全部门要求私有仓库 —— 请构建镜像并推送到你自己的 Harbor"
  else
    ok "应用从你的仓库启动：${REGISTRY}"
    evidence "应用镜像" "$IMAGE"
  fi
fi

# --- 仓库确实在工作 ---------------------------------------------------------
# 清单中的地址可能写得正确，但对应地址上却没有仓库：Harbor
# 不是瞬间起来的，而域名里的拼写错误看起来一模一样。所以我们
# 敲它的 API 并等待「pong」响应 —— 这确认那里正是 Harbor，
# 而不是别人的网站，也不是负载均衡器的占位页。
if [ -z "$REGISTRY" ]; then
  : # 上面已经报告过
elif ! command -v curl >/dev/null 2>&1; then
  warn "没有 curl 工具 —— 未检查仓库可用性" \
       "在浏览器中打开 https://${REGISTRY}，那里应当有 Harbor 界面"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","未知"))' 2>/dev/null)"
    ok "仓库通过 API 响应：https://${REGISTRY}（Harbor ${VER:-版本未知}）"
    evidence "仓库" "https://${REGISTRY}
API ping: ${PING}
Harbor 版本：${VER:-未知}"
  else
    fail "仓库 https://${REGISTRY} 对 /api/v2.0/ping 请求没有响应" \
         "检查地址以及仪表盘中 Harbor 应用的状态"
  fi
fi

# --- 集群拥有访问凭据 -------------------------------------------------------
# 仅仅在清单中引用了 secret 还不够 —— 重要的是它拥有针对
# 镜像所拉取的那个仓库的凭据。最常见的实验错误看起来
# 是正确的：secret 已创建，在清单中命名了，但它内部的地址不对
# （多了 https://、端口、或不同的主机名），kubelet 不会应用它。
# 所以我们解开 secret 的内容，比较地址而不是名称。
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # 没有应用，上面已报告
elif [ -z "$PULL_SECRETS" ]; then
  fail "清单 ${APP} 中未指定任何 imagePullSecret" \
       "没有凭据，来自私有仓库的镜像下载不下来：添加 imagePullSecrets，参见 passes.yaml"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # 我们用 python 解析配置：base64 -d 在 macOS 和 Linux 上行为不同，
    # 而密码不能打印到报告里 —— 我们只取地址列表。
    SERVERS="$(kget secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' \
      | python3 -c 'import sys,json,base64
raw = sys.stdin.read().strip()
try:
    cfg = json.loads(base64.b64decode(raw))
    print(" ".join(cfg.get("auths", {}).keys()))
except Exception:
    pass' 2>/dev/null)"
    if [ -n "$REGISTRY" ] && printf '%s' "$SERVERS" | grep -q "$REGISTRY"; then
      SECRET_OK="$s"
      break
    fi
  done

  if [ -n "$SECRET_OK" ]; then
    ok "集群在 secret ${SECRET_OK} 中拥有针对 ${REGISTRY} 的凭据（密码：<已隐藏>）"
  else
    fail "指定的 secret（${PULL_SECRETS}）中没有一个包含针对 ${REGISTRY:-你的仓库} 的凭据" \
         "这样创建：kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-地址} --docker-username=admin --docker-password=..."
  fi
fi

# --- Pod 确实启动了 ---------------------------------------------------------
# 我们单独处理 ImagePullBackOff 和 ErrImagePull 状态：这正是
# 实验刻意展示的失败，让参与者一眼认出它很重要，而不是
# 得到笼统的「Pod 不工作」。我们把真正的原因作为证据打印 ——
# 在仓库故障和镜像名拼写错误两种情况下，Pod 的状态是一样的。
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "正在运行的应用副本数：${RUNNING}"
  evidence "应用 Pod" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "镜像下载不下来：${BADSTATE}" \
       "这是仓库访问被拒绝或镜像名拼写错误；真正的原因由 kubectl describe pod -l app=passes-api 显示"
  evidence "失败原因" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "没有任何正在运行的应用副本（状态：${BADSTATE:-没有 Pod}）" \
       "查看 kubectl describe pod -l app=passes-api"
fi

# 针对最难诊断的实验错误的单独检查：镜像是为 ARM 构建的，
# 而集群节点是 x86。一切看起来都正确 —— 镜像构建出来了、推送
# 到了仓库、下载到了节点上 —— 但进程起不来。周围没有任何东西提示
# 处理器架构，唯一的线索藏在 Pod 日志里，所以
# 我们用单独的检查查看它们，并直接点出原因。
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "镜像是为另一种处理器架构构建的" \
       "带标志重新构建：docker build --platform linux/amd64 -t ${IMAGE} app/ 然后重新推送"
fi

# --- 应用给出实质性的响应 ---------------------------------------------------
# 一个正在运行的 Pod 还不意味着一个正在工作的服务。我们进入集群内部，按内部
# 名称请求应用，并从响应中读取 Pod 名称。如果它与真正
# 运行中的 Pod 匹配 —— 那么响应者正是我们部署的那个应用，而不是
# 别的碰巧占用了这个地址的东西。不匹配是 warn 而非 fail：
# 副本可能在两次请求之间被重建了，这并非参与者的过错。
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "没有名为 ${APP} 的 Service" \
       "它在 passes.yaml 中有描述 —— 请应用整个文件，而不只是 Deployment"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "服务 ${APP} 没有返回预期的 JSON" \
         "查看 kubectl logs -l app=passes-api，并确认 Service 中的端口与应用端口一致"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "服务返回了 JSON，响应来自真正运行中的 Pod ${SERVED_POD}"
    evidence "服务响应" "$BODY"
  else
    warn "服务以 Pod ${SERVED_POD} 的名义响应，而它不在运行中的 Pod 之列" \
         "很可能副本在两次请求之间被重建了 —— 请再运行一次检查"
  fi
fi

finish
