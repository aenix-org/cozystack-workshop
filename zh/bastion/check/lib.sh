#!/usr/bin/env bash
# 实验检查脚本的公共库。
# 引入方式：  . "$(dirname "$0")/../../check/lib.sh"
#
# 刻意不使用 `set -e`：脚本必须跑完所有检查并展示完整画面，而不是在第一个失败处
# 就停下。读者恰恰是在卡住的时候运行它——中途打断它就等于隐藏了一半答案。

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# 只有当输出送往终端时才使用颜色：在文件和 CI 中转义序列会被当成乱码读出。
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- 机器可读的结果 ------------------------------------------------
# result-<lab>.json 与人类可读报告并行生成，只包含检查的标识符及其结果。表述、命令
# 输出和证据都不写入其中：markdown 报告里会堆积容器日志的尾部、负载均衡器的外部地址、
# 节点地址，以及访问文件的路径连同用户名。用正则去清洗这些不可靠——可靠的做法是压根
# 不生成它们。
#
# 标识符是自动派生的：检查在实验中的序号，加上表述的短哈希。序号提供稳定性，哈希则能
# 捕获对文本的不易察觉的改动——如果表述被改了，服务端会看到，不会默默地把它当作同一项
# 检查接受。
_checks=()
_seq=0
_record() {   # _record <状态> <表述>
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

# evidence "标题" "值" — 写入产物，不打印到终端。
# 需要证据，是为了让报告可以拿给别人看，并且确实有意义。
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# 提前退出也必须留下报告：README 建议「带着脚本的报告来社区」，而之前当集群不可达时
# 却无报告可带——也就是说，恰恰在最需要报告的那种情况下，报告是缺失的。
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "未设置 KUBECONFIG 变量" \
         "先执行: export KUBECONFIG=~/lab.kubeconfig (每开一个新终端窗口都要执行)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "集群在 KUBECONFIG=${KUBECONFIG} 下没有响应" \
         "如果 kubectl get nodes 一直挂起没有响应——说明集群的控制面服务器没有起来；在仪表盘里查看 Kubernetes 应用的状态，以及租户事件中是否有配额不足 (exceeded quota)"
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

# 不使用 GNU 扩展的时间：macOS 上的 BSD date 不认识 `-d`。
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# 机器可读的结果存放位置。刻意放在仓库之外：放在克隆目录内，第一次 `git pull` 或切换
# 分支就会把它们抹掉，而它们是要连续收集好几周的。
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # 集群标识符——kube-system 命名空间的 uid。它对同一集群的所有运行都相同，对不同的人
  # 则不同，而最重要的是——它无法「手工输入」，这一点和租户名不一样。
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
    echo "- 结论: **${verdict}**"
    echo "- 检查项: ${total} (通过 ${_pass}，失败 ${_fail}，警告 ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- 租户: \`${COZY_TENANT}\`"
    echo
    echo "## 检查项"
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
    echo "检查的是功能上是否真正可用，而不是清单是否被应用过。"
  } > "$report"

  printf '报告: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# 专指服务端的版本。`kubectl version -o json` 会同时打印客户端和服务端版本；对
# gitVersion 做朴素的 grep 会取到碰上的第一个——也就是客户端——于是报告就会谎报集群
# 版本。这里很容易出错，所以抽到库里。
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# 人类可读的大小：Kubernetes 报告 allocatable 时有时用 Ki，有时用裸字节，而报告里的
# 「3258002390」对读者毫无意义。
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

# 在一次性 Pod 中运行命令，通过来自临时 Secret 的环境变量传递密钥，而不是通过命令行参数。
#
# 为什么这样做。凡是落入 Pod args 的东西，任何拥有 `get pods` 权限的人都能看到，会存进
# etcd、进入审计日志，并在节点上的 `ps` 里露出来。数据库相关的实验会专门讲解命令行里
# 放密码是不好的做法；用一个恰恰这么干的脚本去检查它们，就成了双重标准。
#
# 用法:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c '读取 $KEY1 的命令'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # Secret 从 stdin 创建，因此这些值不会进入 kubectl 的参数。
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # 这里 securityContext 同样是必需的：没有它，Pod 在启用 `restricted` 配置的集群里
  # 不会被创建，数据库实验的检查也就跑不起来。
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

# 构造一个带 securityContext 的 override，使其能通过 `restricted` 配置。
# 单独抽出：同一份附加设置每个一次性 Pod 都需要，没有它，检查脚本在严格集群里就无法工作。
# 命令的各个参数都是分开传入的，JSON 由 python 组装：在 bash 里手工转义引号，已经导致
# 过 override 损坏和 Pod 静默失败——而错误又被 2>/dev/null 吞掉了。
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

# 在一次性 Pod 中执行命令并返回它的输出。
# 在需要从集群内部检查服务可达性时用到：从笔记本上看不到 ClusterIP。无论如何 Pod 都会
# 自我清理。
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext 是必需的：在启用 `restricted` 配置的集群里，没有它的 Pod 不会被
  # 创建，参与者也就根本无法检查这个实验。
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` 只在客户端处于 attach 状态时删除 Pod：断连、超时或 Ctrl+C 都会让它挂在那里。
  # 显式删除——是为了让脚本不在集群里留下垃圾。
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# 连续收集来自多个请求的响应，每行一个。
#
# 当服务后面有多个副本时，单次请求就是一场抽签：一个带相同标签的杂散 Pod 会被纳入负载
# 均衡，而单次采样可能碰不到它，于是检查就在被替换的内容上高高兴兴地变绿。已经验证过：
# 二十个请求里有八个落到了冒名者身上，而检查连续四次都说「通过」。
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
