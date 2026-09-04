#!/usr/bin/env bash
# 랩 13 검사: 차트와 애플리케이션 정의가 관리자에게 넘길 준비가 되었는지 확인한다.
#
# 이 검사는 의도적으로 로컬에서만 수행된다. 테넌트는 ApplicationDefinition을 적용할 수
# 없으므로(객체가 cluster-scoped) 클러스터에서 그것을 찾는 일은 무의미하다.
# 객체가 없는 것은 참가자의 잘못이 아니다. 참가자가 책임지는 부분을 검사한다:
# 차트가 빌드되고, 스키마가 동작하며, 정의가 파싱되고 차트와 일치하는지.
#
# 랩 폴더에서 실행:
#   cd labs/13-catalog && ./check.sh
# 클러스터는 필수가 아니다: KUBECONFIG가 없으면 두 개의 검사는 오류가 아니라
# 경고와 함께 건너뛴다.

LAB_NAME="13-catalog"
LAB_TITLE="랩 13 · Cozystack 카탈로그에 나만의 애플리케이션 올리기"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- 도구 ------------------------------------------------------------------
# helm 없이는 검사할 것이 없으므로, 아래에서 똑같은 실패를 수십 번 쏟아내는 대신
# 여기서 스크립트를 즉시 멈춘다.
if ! command -v helm >/dev/null 2>&1; then
  fail "이 머신에 helm이 설치되어 있지 않습니다" \
       "설치하세요: brew install helm (macOS) 또는 https://helm.sh/docs/intro/install/ — 없으면 랩을 검사할 수 없습니다"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm이 있습니다 (${HELM_VER})"
evidence "helm 버전" "$HELM_VER"

# --- 차트가 제자리에 -------------------------------------------------------
# "차트가 깨졌다"와 "스크립트를 잘못된 폴더에서 실행했다"를 구분한다. 두 번째 실수가
# 첫 번째보다 더 흔하며, 그에 대한 메시지는 별도여야 한다.
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "${CHART}에서 차트를 찾을 수 없습니다" \
       "랩 폴더에서 스크립트를 실행하세요: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- 린터 ------------------------------------------------------------------
# helm lint는 차트를 텍스트로 읽는다: 템플릿의 오타, 누락된 Chart.yaml 필드,
# 존재하지 않는 값에 대한 참조를 찾아낸다. 여기서 클러스터까지는 가지 않는다.
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "차트가 helm lint를 통과합니다"
  evidence "helm lint" "$LINT_OUT"
else
  fail "차트가 helm lint를 통과하지 못합니다" \
       "아래 출력을 읽고 지적된 파일을 고치세요: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- 렌더 ------------------------------------------------------------------
# 빈 출력이나 주석만 있는 출력은 린터를 통과해 버리므로, 렌더된 결과 중에
# Deployment가 있는지 확인하고 실제로 무엇이 생성되었는지 나열한다.
# 여기서 중요한 것은 "명령이 실행됐다"가 아니라 "진짜 객체가 나왔다"이다.
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "차트가 렌더되어 객체가 생성됩니다: ${KINDS}"
  evidence "차트가 렌더하는 것" "$KINDS"
else
  fail "helm template이 Deployment를 하나도 생성하지 못했습니다" \
       "렌더 오류를 보세요: helm template main chart"
  evidence "helm template 출력" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- 차트가 실제 클러스터에서 받아들여진다 ---------------------------------
# 전체 랩 세트에서 매니페스트를 텍스트가 아니라 실제 클러스터 스키마와 대조하는
# 유일한 검사이다.
#
# `helm lint`와 `helm template`은 템플릿을 검사하지만 Kubernetes 스키마는 검사하지 않는다:
# 필드가 엉뚱한 곳에 있는 매니페스트도 그들은 통과시키지만 클러스터는 거부한다. 직접 겪어봤다 —
# 실수로 volumes 안에 넣은 securityContext가 둘 다 통과했고 서버에서야 무너졌다.
# 이 검사는 차트가 실제로 적용되는 곳에서 필요하다.
#
# lint와 template이 이를 대체하지 못하는 이유:
#   helm lint      차트의 구조를 본다: 파일이 제자리에 있는지, 템플릿이 파싱되는지;
#   helm template  값을 대입해 텍스트를 만든다 — 그러나 그 필드가 무엇인지, 그런 객체에
#                  그런 필드가 있기나 한지는 알지 못하며 알 수도 없다;
#   apply --dry-run=server는 매니페스트를 apiserver로 보내고, apiserver는 타입 스키마와
#                  admission 제어를 거쳐 받아들일지 여부를 답하되 아무것도 생성하지 않는다.
#                  바로 여기서 `unknown field`와 정책에 의한 거부가 나온다 — 고객사에서
#                  차트가 걸려 넘어지는 바로 그것이다.
# --dry-run=client 플래그는 이 검사를 제공하지 않는다: 매니페스트를 당신의 머신에서 파싱한다.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # 권한 거부와 스키마 거부는 다른 것이며 혼동해선 안 된다. 테넌트 접근(~/.kube/config)에서는
  # Deployment와 ConfigMap에 대한 권한이 아예 없으므로 여기로 Forbidden이 온다 — 그리고 그것은
  # 차트의 품질에 대해 아무것도 말해주지 않는다. 본질적인 검사는 당신이 완전한 소유자인
  # `lab` 클러스터에 접근할 때만 가능하다.
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "서버 측 차트 검사를 건너뜁니다: 현재 접근 권한으로는 실행할 수 없습니다" \
         "자신의 클러스터 접근으로 실행하세요: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "클러스터가 렌더된 차트를 거부합니다" \
         "보세요: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "서버 거부" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "클러스터가 렌더된 차트를 받아들입니다 — 필드와 그 위치가 올바릅니다"
  fi
else
  warn "클러스터에서의 차트 검사를 건너뜁니다: 접근 권한 없음" \
       "KUBECONFIG를 지정해 helm template을 kubectl apply --dry-run=server로 실행하세요"
fi

# --- 파라미터가 실제로 매니페스트까지 도달한다 -----------------------------
# 차트가 빌드되고 렌더되면서도 파라미터가 아무 데도 대입되지 않을 수 있다 —
# 예를 들어 값을 템플릿에 숫자 리터럴로 적어 넣은 경우다. 그래서 각 파라미터를 실제로 검사한다:
# 일부러 특이한 값을 지정하고 완성된 매니페스트에서 그것을 찾는다.
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "replicas 파라미터가 매니페스트까지 도달합니다 (--set replicas=5가 replicas: 5를 만듭니다)"
else
  fail "replicas 파라미터가 매니페스트까지 도달하지 않습니다" \
       "templates/deployment.yaml에 replicas: {{ .Values.replicas }}가 있어야 합니다"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "external 파라미터가 Service 타입을 LoadBalancer로 전환합니다"
else
  warn "external 파라미터가 Service 타입을 전환하지 않습니다" \
       "차트가 깨진 것은 아니지만 Cozystack 카탈로그의 관례입니다: 애플리케이션의 external 필드는 바로 외부 접근을 의미합니다"
fi

# --- 스키마가 실제로 보호한다 ----------------------------------------------
# 아무것도 거부하지 않는 스키마는 쓸모없다. 스키마가 거부하는지 확인한다.
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "값 스키마가 명백히 잘못된 값을 거부하지 않습니다 (replicas=abc가 통과했습니다)" \
       "values.yaml 옆에 values.schema.json이 있고 그 안에서 replicas가 integer로 선언되어 있는지 확인하세요"
else
  ok "값 스키마가 잘못된 타입을 거부합니다 (replicas=abc가 통과하지 못합니다)"
fi

# --- ApplicationDefinition: 필수 필드 --------------------------------------
# 참가자는 정의를 적용할 수 없으므로 apiserver의 거부를 보지 못한다.
# 그래서 필수 필드를 여기서 헤아린다: 그중 하나라도 없으면 관리자가 자기 쪽에서 거부를 받게 되고,
# 파일 작성자가 그것을 풀어야 한다.
if [ ! -f "$APPDEF" ]; then
  fail "${APPDEF}를 찾을 수 없습니다" \
       "이 파일은 차트 옆에 있어야 합니다; 랩 저장소에서 가져오세요"
else
  MISSING=""
  # YAML을 파싱하지 않고 키를 한 줄씩 찾는다: PyYAML이 모든 머신에 있는 것은 아니며,
  # 파일 하나 검사하려고 의존성을 끌어들일 가치는 없다.
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
    ok "ApplicationDefinition에 모든 필수 필드가 있습니다"
  else
    fail "ApplicationDefinition에 필드가 빠져 있습니다:${MISSING}" \
         "README의 설명과 대조하세요 — 그중 하나라도 없으면 관리자가 적용 시 거부를 받습니다"
  fi

  # --- 정의 안의 스키마가 파싱되고 차트의 스키마와 일치한다 ----------------
  # 이것은 같은 것의 별개 복사본 두 개이며, 둘 사이에 어떤 연결도 전혀 없다.
  # 어긋나면 대시보드의 폼이 차트가 기대하는 것과 다른 필드를 보여준다.
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "ApplicationDefinition의 openAPISchema가 비어 있습니다" \
         "그 안에 chart/values.schema.json의 내용을 한 줄로 붙여 넣으세요"
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
    print("DIFF 정의에만: %s | 차트에만: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "정의 안의 스키마가 파싱되고 차트의 스키마와 일치합니다 (${CMP#SAME })"
        evidence "애플리케이션 파라미터" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "정의 안의 스키마가 차트의 스키마와 어긋났습니다: ${CMP#DIFF }" \
             "둘을 일치시키세요: openAPISchema의 내용은 chart/values.schema.json을 한 줄로 넣은 것입니다"
        ;;
      BADJSON*)
        fail "openAPISchema가 JSON으로 파싱되지 않습니다: ${CMP#BADJSON }" \
             "스키마는 'openAPISchema: |-' 아래에 올바른 JSON 한 줄이어야 합니다"
        ;;
      *)
        warn "스키마를 대조할 수 없습니다 (${CMP})" \
             "openAPISchema가 chart/values.schema.json과 일치하는지 직접 확인하세요"
        ;;
    esac
  fi

  # --- 아이콘 ---------------------------------------------------------------
  # 대시보드는 base64로 감싼 SVG를 기대하며 이미지를 가지러 어디로도 가지 않는다. 여기서의 오류는
  # 조용하다: 매니페스트는 적용되지만 카탈로그에서 아이콘 자리가 비어 있게 된다. 그래서 문자열을
  # 디코드하고 안에 정말 SVG가 있는지 본다.
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "아이콘이 base64에서 디코드되어 SVG로 확인됩니다"
        evidence "아이콘 시작 부분" "$ICON_HEAD"
        ;;
      "")
        fail "아이콘이 base64에서 디코드되지 않습니다" \
             "문자열을 다시 만드세요: base64 -i icon.svg | tr -d '\\n' (Linux에서는: base64 -w0 icon.svg)"
        ;;
      *)
        fail "아이콘이 디코드되지만 SVG가 아닙니다" \
             "대시보드는 정확히 SVG를 기대합니다; 래스터 이미지는 깨진 문자로 보여줍니다"
        ;;
    esac
  fi
fi

# --- 권한: 여기서의 거부는 예상된 것 ---------------------------------------
# 이것은 참가자에 대한 검사가 아니라 플랫폼이 어떻게 만들어졌는지에 대한 확인이다. 그래서
# `no`라는 답은 성공이고, `yes`는 기뻐할 일이 아니라 놀랄 일이다.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "확인됨: ApplicationDefinition을 적용할 권한이 없습니다 (can-i -> no)"
      evidence "ApplicationDefinition 권한" \
        "kubectl auth can-i create applicationdefinitions -> no
객체가 cluster-scoped이며 모든 테넌트의 카탈로그를 바꾸므로, 그것을 적용하는 것은 플랫폼 관리자입니다."
      ;;
    yes)
      warn "당신에게 ApplicationDefinition을 적용할 권한이 있습니다 (can-i -> yes)" \
           "즉 당신은 테넌트 계정이 아니라 관리자 계정으로 작업 중입니다; 이 랩은 테넌트 계정을 대상으로 합니다"
      ;;
    *)
      warn "클러스터에 권한을 물어볼 수 없습니다" \
           "랩 통과에는 영향이 없습니다: 검사는 로컬이며 여기서 클러스터는 필요하지 않습니다"
      ;;
  esac
else
  warn "클러스터를 조회하지 않았습니다 (KUBECONFIG가 지정되지 않았거나 응답하지 않음)" \
       "검사는 로컬이며 여기서 클러스터는 필요하지 않습니다. 권한 거부를 보려면: export KUBECONFIG=~/.kube/config"
fi

finish
