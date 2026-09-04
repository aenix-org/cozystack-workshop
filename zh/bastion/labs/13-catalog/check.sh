#!/usr/bin/env bash
# 实验 13 检查：图表与应用定义已准备好交付给管理员。
#
# 这项检查是有意本地化的。租户无法应用 ApplicationDefinition
#（该对象是集群级别的），所以在集群里查找它毫无意义：
# 对象不存在并不是参与者的过错。我们检查的是他所负责的部分：
# 图表能构建、schema 能工作、定义能被解析并与图表保持一致。
#
# 从实验目录中运行：
#   cd labs/13-catalog && ./check.sh
# 不一定需要集群：没有 KUBECONFIG 时，两项检查会以警告方式跳过，
# 而不是报错。

LAB_NAME="13-catalog"
LAB_TITLE="实验 13 · 在 Cozystack 目录中发布你自己的应用"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- 工具 ------------------------------------------------------------------
# 没有 helm 就没什么可检查的，所以脚本在此立即停止，而不是在后面的文本里
# 抛出一大堆相同的失败信息。
if ! command -v helm >/dev/null 2>&1; then
  fail "这台机器上没有安装 helm" \
       "请安装：brew install helm（macOS）或 https://helm.sh/docs/intro/install/ —— 没有它就无法检查本实验"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm 已就位（${HELM_VER}）"
evidence "helm 版本" "$HELM_VER"

# --- 图表就位 --------------------------------------------------------------
# 我们区分「图表损坏」和「脚本从错误的目录运行」。后一种错误比前者更常见，
# 因此它的提示信息应当单独给出。
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "在 ${CHART} 中没有找到图表" \
       "请从实验目录中运行脚本：cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- 检查器 ----------------------------------------------------------------
# helm lint 把图表当作文本来读：它能发现模板中的拼写错误、Chart.yaml 中缺失的
# 字段、对不存在的值的引用。它在这里根本不会接触到集群。
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "图表通过了 helm lint"
  evidence "helm lint" "$LINT_OUT"
else
  fail "图表未通过 helm lint" \
       "请阅读下面的输出并修复所指出的文件：helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- 渲染 ------------------------------------------------------------------
# 空输出和只含注释的输出都能骗过检查器，所以我们检查渲染结果里是否有
# Deployment，并列出实际产生了什么。
# 这里的关键不是「命令跑通了」，而是「产生了真正的对象」。
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "图表能渲染，产生的对象：${KINDS}"
  evidence "图表渲染出的内容" "$KINDS"
else
  fail "helm template 没有产生任何一个 Deployment" \
       "请查看渲染错误：helm template main chart"
  evidence "helm template 输出" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- 图表被真实集群接受 ----------------------------------------------------
# 整套实验里唯一一项把清单与真实集群 schema 而非文本进行比对的检查。
#
# `helm lint` 和 `helm template` 检查模板，但不检查 Kubernetes schema：字段放错
# 位置的清单能骗过它们，但集群会拒绝。这是吃过亏才明白的 —— 一个被误插到 volumes
# 里的 securityContext 通过了两者，只在服务器上才崩溃。这项检查正是需要放在真正
# 应用图表的地方。
#
# 为什么 lint 和 template 无法替代它：
#   helm lint      看的是图表的构造：文件是否就位、模板能否解析；
#   helm template  代入值并产生文本 —— 但这些字段是什么、这样的对象是否会有它们，
#                  它并不知道也无法知道；
#   apply --dry-run=server 把清单发送给 apiserver，后者让它经过类型 schema 和
#                  admission 控制，回答是否会接受，而不创建任何东西。`unknown field`
#                  和策略拒绝正来自这里 —— 恰是图表在客户处会绊倒的地方。
# --dry-run=client 标志给不出这项检查：它在你的机器上解析清单。
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # 权限拒绝和 schema 拒绝是两回事，不能混淆。在租户访问（~/.kube/config）下，
  # 对 Deployment 和 ConfigMap 根本没有权限，因此这里飞来的会是 Forbidden ——
  # 而这与图表质量毫无关系。只有用对 `lab` 集群的访问权限（在那里你是完全的主人）
  # 才可能做出实质性的检查。
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "服务器端图表检查被跳过：当前访问权限不允许执行它" \
         "请用你自己集群的访问权限来运行它：KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "集群拒绝了渲染出的图表" \
         "请查看：helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "服务器拒绝" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "集群接受了渲染出的图表 —— 字段及其位置都正确"
  fi
else
  warn "跳过在集群上的图表检查：无访问权限" \
       "请设置 KUBECONFIG，以便通过 kubectl apply --dry-run=server 运行 helm template"
fi

# --- 参数确实抵达清单 ------------------------------------------------------
# 图表可以既能构建又能渲染，而参数却哪里都没被代入 ——
# 例如把值以字面数字写进了模板。所以我们对每个参数都动真格地检查：
# 设置一个明显不寻常的值，并在生成好的清单里查找它。
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "replicas 参数抵达了清单（--set replicas=5 得到 replicas: 5）"
else
  fail "replicas 参数没有抵达清单" \
       "templates/deployment.yaml 里应当写有 replicas: {{ .Values.replicas }}"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "external 参数把 Service 类型切换为 LoadBalancer"
else
  warn "external 参数没有切换 Service 类型" \
       "这不是图表的故障，而是 Cozystack 目录的约定：应用上的 external 字段恰恰意味着外部访问"
fi

# --- schema 确实起到保护作用 ----------------------------------------------
# 什么都不拒绝的 schema 毫无用处。我们检查它是否会拒绝。
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "值 schema 没有拒绝一个明显无效的值（replicas=abc 通过了）" \
       "请检查 values.schema.json 是否与 values.yaml 放在一起，且其中把 replicas 声明为 integer"
else
  ok "值 schema 拒绝了错误的类型（replicas=abc 没有通过）"
fi

# --- ApplicationDefinition：必填字段 --------------------------------------
# 参与者无法应用该定义，因此也看不到 apiserver 的拒绝。
# 所以我们在这里逐一核对必填字段：缺少其中任何一个，管理员在自己那边就会收到拒绝，
# 而需要去弄清楚的将是文件的作者。
if [ ! -f "$APPDEF" ]; then
  fail "没有找到 ${APPDEF}" \
       "该文件应当与图表放在一起；请从实验仓库中取用它"
else
  MISSING=""
  # 我们逐行查找键，而不解析 YAML：并非每台机器上都有 PyYAML，
  # 而为了检查一个文件就引入一个依赖并不值得。
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
    ok "ApplicationDefinition 中所有必填字段都已就位"
  else
    fail "ApplicationDefinition 中缺少字段：${MISSING}" \
         "请对照 README 中的讲解核对 —— 缺少其中任何一个，管理员在应用时都会收到拒绝"
  fi

  # --- 定义中的 schema 能被解析并与图表的 schema 一致 ----------------------
  # 这是同一样东西的两份独立副本，它们之间没有任何关联。
  # 一旦分叉，仪表盘里的表单就会显示与图表所期望不同的字段。
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "ApplicationDefinition 中的 openAPISchema 为空" \
         "请把 chart/values.schema.json 的内容作为单行粘贴进去"
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
    print("DIFF 仅在定义中: %s | 仅在图表中: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "定义中的 schema 能被解析并与图表的 schema 一致（${CMP#SAME }）"
        evidence "应用参数" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "定义中的 schema 与图表的 schema 已分叉：${CMP#DIFF }" \
             "请让它们保持一致：openAPISchema 的内容就是 chart/values.schema.json 的单行形式"
        ;;
      BADJSON*)
        fail "openAPISchema 无法解析为 JSON：${CMP#BADJSON }" \
             "schema 必须是 'openAPISchema: |-' 之下一整行合法的 JSON"
        ;;
      *)
        warn "无法比对 schema（${CMP}）" \
             "请手动检查 openAPISchema 与 chart/values.schema.json 是否一致"
        ;;
    esac
  fi

  # --- 图标 ------------------------------------------------------------------
  # 仪表盘期望一个打包成 base64 的 SVG，并且不会去别处取图。这里的错误是无声的：
  # 清单会被应用，而目录里图标的位置将是空的。所以我们把字符串解码出来，
  # 看看里面是否真的是 SVG。
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "图标从 base64 解码后确实是一个 SVG"
        evidence "图标开头" "$ICON_HEAD"
        ;;
      "")
        fail "图标无法从 base64 解码" \
             "请重新生成该字符串：base64 -i icon.svg | tr -d '\\n'（在 Linux 上：base64 -w0 icon.svg）"
        ;;
      *)
        fail "图标能解码，但它不是 SVG" \
             "仪表盘期望的正是 SVG；位图它会显示成乱码"
        ;;
    esac
  fi
fi

# --- 权限：这里预期会被拒绝 ------------------------------------------------
# 这不是对参与者的检查，而是对平台构造方式的确认。所以
# 回答 `no` 是成功，而 `yes` 才是让人惊讶、而非高兴的理由。
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "已确认：你无权应用 ApplicationDefinition（can-i -> no）"
      evidence "ApplicationDefinition 权限" \
        "kubectl auth can-i create applicationdefinitions -> no
该对象是集群级别的，会为所有租户改变目录，因此由平台管理员来应用它。"
      ;;
    yes)
      warn "你拥有应用 ApplicationDefinition 的权限（can-i -> yes）" \
           "这意味着你是在管理员账户下工作，而非租户账户；本实验是为租户账户设计的"
      ;;
    *)
      warn "无法向集群询问权限" \
           "不影响实验的完成：这项检查是本地的，这里不需要集群"
      ;;
  esac
else
  warn "未查询集群（KUBECONFIG 未设置或无响应）" \
       "这项检查是本地的，这里不需要集群。若要看到权限拒绝：export KUBECONFIG=~/.kube/config"
fi

finish
