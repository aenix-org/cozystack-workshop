#!/usr/bin/env bash
# 实验检查脚本的公共库。
# 这样引入:  . "$(dirname "$0")/../../check/lib.sh"
#
# 故意不使用 `set -e`: 脚本必须跑完每一项检查并展示完整全貌,而不是在第一次失败时
# 就停下。读者恰恰是在卡住的时候才运行它 —— 半路截断它就等于隐藏了一半的答案。

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# 只有当输出送往终端时才用颜色: 在文件里和 CI 中,转义序列会被当成乱码读取。
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- 机器可读的结果 ----------------------------------------------------------
# result-<lab>.json 与人类可读报告并行生成,只包含检查的标识符及其结果。措辞、命令
# 输出和证据都不会进入其中: markdown 报告里会积累容器日志的尾部、负载均衡器的外部
# 地址、节点地址,以及访问文件的路径连同用户名。用正则表达式清洗这些内容并不可靠 ——
# 可靠的办法是压根不生成它。
#
# 标识符是自行推导出来的: 该检查在实验中的序号,加上措辞的短哈希。序号提供稳定性,
# 哈希则能抓住对文本的悄悄改动 —— 如果措辞被改了,服务端会发现,而不会默默地把它当成
# 同一项检查接受。
_checks=()
_seq=0
_record() {   # _record <状态> <措辞>
  _seq=$((_seq + 1))
  local h
  h="$(printf '%s' "$2" | shasum -a 256 2>/dev/null | cut -c1-8)"
  [ -n "$h" ] || h="00000000"
  _checks+=("$(printf '%s-%02d-%s:%s' "$LAB_NAME" "$_seq" "$h" "$1")")
}

ok() {
  _pass=$((_pass + 1))
  _record ok "$1"
  printf '%s[  OK  ]%s %s\n' "$_C_OK" "$_C_OFF" "$1"
  _lines+=("- **OK** — $1")
}

# fail "哪里不对" "该怎么处理"
fail() {
  _record fail "$1"
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - 该怎么做: $2")
}

warn() {
  _record warn "$1"
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - 备注: $2")
}

# evidence "标题" "值" —— 进入产物文件,不打印到终端。
# 证据的存在是为了让报告可以展示给别人看,并且确实有意义。
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# 提前退出也必须留下报告: README 建议「带着脚本的报告来社区」,可是以前当集群不可达时
# 却没有任何东西可以附上 —— 也就是说,恰恰在报告最需要存在的那种情况下,报告反而没有。
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "未设置 KUBECONFIG 变量" \
         "先执行: export KUBECONFIG=~/lab.kubeconfig (在每个新的终端窗口里都要执行)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "集群在 KUBECONFIG=${KUBECONFIG} 下没有响应" \
         "如果 kubectl get nodes 一直挂着没有响应 —— 说明集群控制平面没有起来; 在仪表盘里查看 Kubernetes 应用的状态,并检查租户事件里是否有配额超限 (exceeded quota)"
    evidence "访问文件" "$KUBECONFIG"
    evidence "集群响应" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s 未设置 COZY_TENANT 变量\n' "$_C_FAIL" "$_C_OFF"
    printf '         %s例如: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# 不依赖 GNU 扩展的时间: macOS 上的 BSD date 不认识 `-d`。
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# 机器可读结果的存放位置。故意放在仓库之外: 在克隆目录内,第一次 `git pull` 或切换
# 分支就会把它们抹掉,而它们是要跨越数周积累的。
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # 集群标识符 —— kube-system 命名空间的 uid。它对同一集群上的所有运行都相同,在不同
  # 人之间则不同,而最关键的是: 它无法像租户名那样「用手敲进去」。
  local cluster_uid=""
  cluster_uid="$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  local kver=""
  kver="$(server_version 2>/dev/null || true)"
  CHECKS_LIST="$(printf '%s\n' "${_checks[@]:-}")" \
  LAB="$LAB_NAME" VERDICT="$1" P="$_pass" F="$_fail" W="$_warn" \
  CUID="$cluster_uid" KVER="$kver" TEN="${COZY_TENANT:-}" WHEN="$(_now)" \
  python3 - "$LAB_RESULTS_DIR/result-${LAB_NAME}.json" <<'PYEOF'
import json, os, sys
checks = []
for line in os.environ.get("CHECKS_LIST", "").split("\n"):
    line = line.strip()
    if not line or ":" not in line:
        continue
    cid, status = line.rsplit(":", 1)
    checks.append({"id": cid, "status": status})
doc = {
    "schema_version": 1,
    "lab": os.environ["LAB"],
    "verdict": os.environ["VERDICT"],
    "finished_at": os.environ["WHEN"],
    "totals": {"pass": int(os.environ["P"]), "fail": int(os.environ["F"]),
               "warn": int(os.environ["W"])},
    "env": {"kubernetes_server_version": os.environ.get("KVER") or None,
            "cluster_uid": os.environ.get("CUID") or None,
            "tenant": os.environ.get("TEN") or None},
    "checks": checks,
}
with open(sys.argv[1], "w") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=1)
PYEOF
}

finish() {
  local total=$((_pass + _fail + _warn))
  local report="report-${LAB_NAME}-$(_stamp).md"
  local verdict

  if [ "$_fail" -eq 0 ]; then
    verdict="实验通过"
  else
    verdict="仍有未完成项"
  fi

  _write_result_json "$([ "$_fail" -eq 0 ] && echo passed || echo failed)"

  printf '\n'
  printf '检查项: %d · 通过: %d · 失败: %d · 警告: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# 报告: ${LAB_TITLE}"
    echo
    echo "- 日期: $(_now)"
    echo "- 结果: **${verdict}**"
    echo "- 检查项: ${total} (通过 ${_pass}, 失败 ${_fail}, 警告 ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- 租户: \`${COZY_TENANT}\`"
    echo
    echo "## 检查"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## 证据"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "本报告由 Cozystack 实验中的 \`check.sh\` 脚本生成。"
    echo "它检验的是实质上的可用性,而不是清单是否被应用这一事实。"
  } > "$report"

  printf '报告: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# 专门取服务端的版本。`kubectl version -o json` 会同时打印客户端和服务端两者;
# 对 gitVersion 做简单的 grep 会取到第一个匹配 —— 也就是客户端的 —— 于是报告就开始
# 谎报集群版本。这里很容易出错,所以挪进了库里。
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# 人类可读的大小: Kubernetes 报告 allocatable 时有时用 Ki,有时用裸字节,
# 而报告里的「3258002390」对读者毫无意义。
human_bytes() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, re
v = sys.argv[1].strip()
m = re.fullmatch(r'(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|K|M|G|T)?', v)
if not m:
    print(v); raise SystemExit
n = float(m.group(1))
mult = {'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4,
        'K':1000,'M':1000**2,'G':1000**3,'T':1000**4}.get(m.group(2), 1)
b = n * mult
for unit, size in (('Gi',1024**3), ('Mi',1024**2), ('Ki',1024)):
    if b >= size:
        print(f"{b/size:.1f}{unit}"); break
else:
    print(f"{int(b)}B")
PY
}

# 在一次性 Pod 里运行命令,把密钥通过环境变量传入 —— 这些环境变量来自一个临时 Secret,
# 而不是命令行参数。
#
# 为什么这么做。进入 Pod args 的一切,对任何拥有 `get pods` 的人都是可见的,会落在
# etcd 里,进入 audit log,并出现在节点上的 `ps` 中。数据库相关的实验会专门讲解,把
# 密码放在命令行里是坏做法; 而用一个恰恰这么做的脚本去检查它们,那就是双重标准。
#
# 用法:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c '读取 $KEY1 的命令'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # Secret 从 stdin 创建,因此这些值不会进入 kubectl 的参数。
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # 这里 securityContext 同样是必需的: 没有它,在启用了 `restricted` profile 的集群里
  # Pod 无法被创建,数据库相关实验的检查就跑不起来。
  local cmd_json
  cmd_json="$(printf '%s\n' "$@" | python3 -c 'import sys,json;print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image="$image" --pod-running-timeout=90s \
    --overrides="{\"spec\":{\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65532,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"$name\",\"image\":\"$image\",\"stdin\":true,\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}},\"envFrom\":[{\"secretRef\":{\"name\":\"$sec\"}}],\"command\":$cmd_json}]}}" \
    2>/dev/null
  local rc=$?

  kubectl delete secret "$sec" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# 构造一个带有能通过 `restricted` profile 的 securityContext 的 override。
# 单独抽出来: 每个一次性 Pod 都需要同一套附加设置,没有它,检查脚本在严格集群里
# 就无法工作。
# 命令参数是逐个分别传入的,JSON 由 python 组装: 在 bash 里手工转义引号已经导致过
# 损坏的 override 和 Pod 的静默失败 —— 而错误还被 2>/dev/null 吞掉了。
_restricted_overrides() {
  local name="$1" image="$2"; shift 2
  python3 - "$name" "$image" "$@" <<'PYJSON'
import sys, json
name, image, *cmd = sys.argv[1:]
print(json.dumps({"spec": {
    "securityContext": {"runAsNonRoot": True, "runAsUser": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": name, "image": image, "stdin": True,
                    "securityContext": {"allowPrivilegeEscalation": False,
                                        "capabilities": {"drop": ["ALL"]}},
                    "command": cmd}]}}))
PYJSON
}

# 在一次性 Pod 里执行命令并返回它的输出。
# 在需要从集群内部检查服务可达性的地方用得上: 从笔记本上看不到 ClusterIP。
# 无论如何,Pod 都会自己清理掉。
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext 是必需的: 在启用了 `restricted` profile 的集群里,没有它的 Pod
  # 无法被创建,参与者就根本没法检查这个实验。
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` 只在客户端保持挂接期间才删除 Pod: 断开、超时或 Ctrl+C 都会让它悬着。
  # 显式删除是为了让脚本不在集群里留下垃圾。
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# 连续从「多个」请求中收集响应,每行一个。
#
# 当一个服务后面有多个副本时,单次请求就是一场碰运气: 带着相同标签的野生 Pod 会被
# 纳入负载均衡,而单次采样可能没碰上它,于是检查就在被替换的内容上高高兴兴地变绿。
# 已验证: 二十个请求里有八个落到了冒名者身上,而检查连续四次都说「通过」。
in_cluster_curl_many() {
  local url="$1" times="${2:-8}"
  local name="check-$$-$RANDOM"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      sh -c "for i in \$(seq 1 $times); do curl -s --max-time 10 '$url'; echo; done")" \
    2>/dev/null
  local rc=$?
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}
