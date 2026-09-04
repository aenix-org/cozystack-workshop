#!/usr/bin/env bash
# 实验 13 的检查：chart 和应用定义已准备好交接给管理员。
#
# 本检查是有意做成本地的。租户无法应用 ApplicationDefinition
#（该对象是 cluster-scoped 的），所以在集群里找它没有意义：
# 对象不存在并不是参与者的过错。我们检查他们应负责的部分：
# chart 能构建、schema 生效、定义能被解析并且与 chart 一致。
#
# 从实验目录运行：
#   cd labs/13-catalog && ./check.sh
# 不要求有集群：没有 KUBECONFIG 时会有两项检查以警告跳过，
# 而不是报错。

LAB_NAME="13-catalog"
LAB_TITLE="实验 13 · 把你自己的应用放进 Cozystack 目录"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- 工具 ------------------------------------------------------------------
# 没有 helm 就无从检查，所以脚本到这里直接停止，不再往下抛出一堆
# 相同的失败信息。
if ! command -v helm >/dev/null 2>&1; then
  fail "本机未安装 helm" \
       "请安装：brew install helm（macOS）或 https://helm.sh/docs/intro/install/ —— 没有它无法检查本实验"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm 已就绪（${HELM_VER}）"
evidence "helm 版本" "$HELM_VER"

# --- chart 是否存在 --------------------------------------------------------
# 要区分「chart 坏了」和「脚本从错误的目录运行」。后一种错误比前一种更常见，
# 它的提示信息应当单独给出。
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "在 ${CHART} 中未找到 chart" \
       "请从实验目录运行脚本：cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- 检查器 ----------------------------------------------------------------
# helm lint 把 chart 当作文本来读：它能发现模板里的拼写错误、缺失的 Chart.yaml
# 字段、对不存在的 values 的引用。这一步还不会触及集群。
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "chart 通过了 helm lint"
  evidence "helm lint" "$LINT_OUT"
else
  fail "chart 未通过 helm lint" \
       "阅读下面的输出并修复所指出的文件：helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- 渲染 ------------------------------------------------------------------
# 空输出和只有注释的输出都能骗过检查器，所以我们检查渲染结果中是否含有
# Deployment，并列出到底渲染出了什么。这里的重点不是「命令跑通了」，
# 而是「产出了真正的对象」。
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "chart 能渲染，产出对象：${KINDS}"
  evidence "chart 渲染出的内容" "$KINDS"
else
  fail "helm template 没有产出任何 Deployment" \
       "查看渲染错误：helm template main chart"
  evidence "helm template 输出" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- chart 被真实集群接受 --------------------------------------------------
# 这是整套实验中唯一一项把清单与真实集群 schema 而非文本进行比对的检查。
#
# `helm lint` 和 `helm template` 检查的是模板，但不检查 Kubernetes schema：
# 字段放错位置的清单能骗过它们，而集群会拒绝它。这是吃过亏才学到的 ——
# 一个被误放进 volumes 里的 securityContext 通过了两者，
# 却只在服务器上崩掉。这项检查在应用 chart 的地方才需要。
#
# 为什么 lint 和 template 不能取代它：
#   helm lint      看的是 chart 的结构：文件是否齐全、模板能否解析；
#   helm template  代入 values 并输出文本 —— 但那些字段是什么、这类对象
#                  能不能有它们，它不知道也无从知道；
#   apply --dry-run=server 把清单发送到 apiserver，由它把清单跑过类型 schema
#                  和准入控制，回答是否会接受，同时什么也不创建。于是就有了
#                  `unknown field` 和按策略的拒绝 —— 正是 chart 在客户现场
#                  绊倒的地方。
# --dry-run=client 标志给不出这项检查：它是在你的机器上解析清单。
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # 权限被拒和 schema 被拒是两回事，绝不能混淆。在租户访问下
  #（~/.kube/workshop）根本没有对 Deployment 和 ConfigMap 的权限，所以这里
  # 会飞来一个 Forbidden —— 而这对 chart 的质量什么也说明不了。只有用对
  # `lab` 集群的访问权限才能做有意义的检查，在那里你是完全的主人。
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "跳过服务端 chart 检查：当前访问权限不允许执行它" \
         "用对你自己集群的访问权限来运行它：KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "集群拒绝了渲染出的 chart" \
         "查看：helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "服务端拒绝" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "集群接受了渲染出的 chart —— 字段及其位置都正确"
  fi
else
  warn "跳过对集群的 chart 检查：无访问权限" \
       "设置 KUBECONFIG，以便用 kubectl apply --dry-run=server 跑一遍 helm template"
fi

# --- 参数确实传到了清单 ----------------------------------------------------
# chart 可能能构建、能渲染，而某个参数却没有被代入任何地方 ——
# 例如把该值当作数字硬编码进了模板。所以我们对每个参数都动真格地测试：
# 设一个明显不寻常的值，然后在成品清单里找它。
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "replicas 参数传到了清单（--set replicas=5 得到 replicas: 5）"
else
  fail "replicas 参数没有传到清单" \
       "templates/deployment.yaml 中应当写 replicas: {{ .Values.replicas }}"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "external 参数把 Service 类型切换为 LoadBalancer"
else
  warn "external 参数没有切换 Service 类型" \
       "这不是 chart 的缺陷，而是 Cozystack 目录的约定：应用的 external 字段就是指对外访问"
fi

# --- schema 确实起到防护作用 -----------------------------------------------
# 一个什么都不拒绝的 schema 毫无用处。我们检查它是否会拒绝。
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "values schema 没有拒绝一个明显无效的值（replicas=abc 通过了）" \
       "检查 values.schema.json 是否与 values.yaml 放在一起，且其中把 replicas 声明为 integer"
else
  ok "values schema 拒绝了错误的类型（replicas=abc 没通过）"
fi

# --- ApplicationDefinition：必填字段 ---------------------------------------
# 参与者无法应用该定义，因此也看不到 apiserver 的拒绝。所以我们在这里清点
# 必填字段：缺少其中任何一个，管理员都会在自己那边收到拒绝，而要去排查的
# 是文件的作者。
if [ ! -f "$APPDEF" ]; then
  fail "未找到：${APPDEF}" \
       "该文件应当与 chart 放在一起；从实验仓库里取用它"
else
  MISSING=""
  # 我们逐行查找键，而不解析 YAML：不是每台机器都装了 PyYAML，
  # 仅为检查一个文件而引入依赖不值得。
  check_key() {
    grep -Eq "$1" "$APPDEF" || MISSING="$MISSING $2"
  }
  check_key '^kind:[[:space:]]+ApplicationDefinition[[:space:]]*$' 'kind: ApplicationDefinition'
  check_key '^apiVersion:[[:space:]]+cozystack\.io/v1alpha1[[:space:]]*$' 'apiVersion: cozystack.io/v1alpha1'
  check_key '^[[:space:]]{4}kind:[[:space:]]+\S+' 'application.kind'
  check_key '^[[:space:]]{4}plural:[[:space:]]+\S+' 'application.plural'
  check_key '^[[:space:]]{4}singular:[[:space:]]+\S+' 'application.singular'
  check_key '^[[:space:]]{4}openAPISchema:' 'application.openAPISchema'
  check_key '^[[:space:]]{4}prefix:[[:space:]]+\S+' 'release.prefix'
  check_key '^[[:space:]]{6}kind:[[:space:]]+(OCIRepository|HelmChart|ExternalArtifact)' 'release.chartRef.kind'
  check_key '^[[:space:]]{4}category:[[:space:]]+\S+' 'dashboard.category'
  check_key '^[[:space:]]{4}icon:[[:space:]]+\S+' 'dashboard.icon'

  if [ -z "$MISSING" ]; then
    ok "ApplicationDefinition 中所有必填字段都在"
  else
    fail "ApplicationDefinition 缺少字段：${MISSING}" \
         "对照 README 中的讲解 —— 缺少其中任何一个，管理员在应用时都会收到拒绝"
  fi

  # --- 定义中的 schema 能解析并与 chart 的 schema 一致 --------------------
  # 这是同一样东西的两份独立副本，两者之间没有任何关联。
  # 一旦分道扬镳，dashboard 表单就会显示出 chart 并不期待的字段。
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "ApplicationDefinition 中的 openAPISchema 为空" \
         "把 chart/values.schema.json 的内容作为单行填进去"
  else
    CMP="$(SCHEMA_LINE="$SCHEMA_LINE" python3 - "$CHART/values.schema.json" <<'PY' 2>&1
import os, sys, json
try:
    inline = json.loads(os.environ["SCHEMA_LINE"])
except Exception as e:
    print("BADJSON %s" % e); raise SystemExit
try:
    chart = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOCHART %s" % e); raise SystemExit
a = sorted((inline.get("properties") or {}).keys())
b = sorted((chart.get("properties") or {}).keys())
if a == b:
    print("SAME %s" % ",".join(a))
else:
    only_def = sorted(set(a) - set(b))
    only_chart = sorted(set(b) - set(a))
    print("DIFF 仅在定义中: %s | 仅在 chart 中: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "定义中的 schema 能解析并与 chart 的 schema 一致（${CMP#SAME }）"
        evidence "应用参数" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "定义中的 schema 与 chart 的 schema 出现分歧：${CMP#DIFF }" \
             "让它们保持一致：openAPISchema 的内容就是单行的 chart/values.schema.json"
        ;;
      BADJSON*)
        fail "openAPISchema 无法解析为 JSON：${CMP#BADJSON }" \
             "schema 必须是 'openAPISchema: |-' 下的单行合法 JSON"
        ;;
      *)
        warn "无法比对两份 schema（${CMP}）" \
             "手动检查 openAPISchema 是否与 chart/values.schema.json 一致"
        ;;
    esac
  fi

  # --- 图标 ------------------------------------------------------------------
  # dashboard 期待一个打包进 base64 的 SVG，并且不会为这张图去别处取。这里
  # 的错误是无声的：清单能应用，而目录里图标的位置却是空的。所以我们把该字符串
  # 解码，看看里面是否真的是 SVG。
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "图标从 base64 解码出来，结果是一个 SVG"
        evidence "图标开头" "$ICON_HEAD"
        ;;
      "")
        fail "图标无法从 base64 解码" \
             "重新生成该字符串：base64 -i icon.svg | tr -d '\\n'（Linux 上：base64 -w0 icon.svg）"
        ;;
      *)
        fail "图标能解码，但它不是 SVG" \
             "dashboard 期待的正是 SVG；位图它会显示成乱码"
        ;;
    esac
  fi
fi

# --- 权限：这里被拒是预期之中 ----------------------------------------------
# 这不是对参与者的检查，而是对平台如何构建的确认。所以答案 `no`
# 是成功，而 `yes` 是该惊讶而非高兴的理由。
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "已确认：你无权应用 ApplicationDefinition（can-i -> no）"
      evidence "ApplicationDefinition 上的权限" \
        "kubectl auth can-i create applicationdefinitions -> no
该对象是 cluster-scoped 的，会改变所有租户的目录，所以由平台管理员来应用它。"
      ;;
    yes)
      warn "你有权限应用 ApplicationDefinition（can-i -> yes）" \
           "这意味着你是以管理员账号在工作，而非租户账号；本实验面向的是租户账号"
      ;;
    *)
      warn "无法向集群询问权限" \
           "不影响本实验的完成：检查是本地的，这里不需要集群"
      ;;
  esac
else
  warn "未查询集群（KUBECONFIG 未设置或无响应）" \
       "检查是本地的，这里不需要集群。若想看到权限被拒：export KUBECONFIG=~/.kube/workshop"
fi

finish
