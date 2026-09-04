#!/usr/bin/env bash
# 랩 13 점검: 차트와 애플리케이션 정의가 관리자에게 넘길 준비가 되었는지.
#
# 이 점검은 의도적으로 로컬에서만 수행한다. 테넌트는 ApplicationDefinition을 적용할
# 수 없으므로(오브젝트가 cluster-scoped), 클러스터에서 그것을 찾는 일은 무의미하다:
# 오브젝트가 없는 것은 참가자의 잘못이 아니다. 참가자가 책임지는 것을 점검한다:
# 차트가 빌드되고, 스키마가 동작하며, 정의가 파싱되어 차트와 일치하는지.
#
# 랩 폴더에서 실행:
#   cd labs/13-catalog && ./check.sh
# 클러스터는 필수가 아니다: KUBECONFIG가 없으면 두 개의 점검은 오류가 아니라
# 경고와 함께 건너뛴다.

LAB_NAME="13-catalog"
LAB_TITLE="랩 13 · Cozystack 카탈로그에 나만의 애플리케이션"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- 도구 -----------------------------------------------------------
# helm이 없으면 점검할 것이 없으므로, 스크립트는 여기서 바로 멈추고 이후 본문에서
# 똑같은 실패를 수십 번 쏟아내지 않는다.
if ! command -v helm >/dev/null 2>&1; then
  fail "이 머신에 helm이 설치되어 있지 않습니다" \
       "설치하세요: brew install helm (macOS) 또는 https://helm.sh/docs/intro/install/ — 없으면 랩을 점검할 수 없습니다"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm이 있습니다 (${HELM_VER})"
evidence "helm 버전" "$HELM_VER"

# --- 차트가 있는지 ---------------------------------------------------------
# «차트가 깨졌다»와 «스크립트를 잘못된 폴더에서 실행했다»를 구분한다. 두 번째 실수가
# 첫 번째보다 흔하므로, 그에 대한 메시지는 별도여야 한다.
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "${CHART}에서 차트를 찾을 수 없습니다" \
       "랩 폴더에서 스크립트를 실행하세요: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- 린터 ----------------------------------------------------------------
# helm lint는 차트를 텍스트로 읽는다: 템플릿의 오타, 빠진 Chart.yaml 필드,
# 존재하지 않는 값에 대한 참조를 찾는다. 여기서 클러스터까지는 가지 않는다.
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "차트가 helm lint를 통과합니다"
  evidence "helm lint" "$LINT_OUT"
else
  fail "차트가 helm lint를 통과하지 못합니다" \
       "아래 출력을 읽고 지적된 파일을 고치세요: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- 렌더링 ----------------------------------------------------------------
# 빈 출력과 주석만 있는 출력은 린터를 통과하므로, 렌더링된 결과에 Deployment가
# 있는지 살피고, 실제로 무엇이 나왔는지 나열한다.
# 여기서 핵심은 «명령이 실행됐다»가 아니라 «진짜 오브젝트가 나왔다»이다.
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "차트가 렌더링되어 오브젝트가 생성됩니다: ${KINDS}"
  evidence "차트가 렌더링하는 것" "$KINDS"
else
  fail "helm template이 Deployment를 하나도 생성하지 못했습니다" \
       "렌더링 오류를 확인하세요: helm template main chart"
  evidence "helm template 출력" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- 차트가 진짜 클러스터에 의해 수용됨 ----------------------------------
# 전체 랩 세트에서 매니페스트를 텍스트가 아니라 진짜 클러스터 스키마와 대조하는
# 유일한 점검.
#
# `helm lint`와 `helm template`은 템플릿을 점검하지만 Kubernetes 스키마는 점검하지
# 않는다: 필드가 잘못된 위치에 있는 매니페스트도 이들을 통과하지만, 클러스터는 이를
# 거부한다. 직접 겪어 배웠다 — 실수로 volumes 안에 넣은 securityContext가 둘 다
# 통과했으나 서버에서만 무너졌다. 이 점검은 차트가 적용되는 곳에서 필요하다.
#
# lint와 template이 이를 대체하지 못하는 이유:
#   helm lint      차트의 구조를 본다: 파일이 있는지, 템플릿이 파싱되는지;
#   helm template  값을 대입하고 텍스트를 낸다 — 그러나 그 필드가 무엇인지, 그런
#                  오브젝트가 그것을 가질 수 있는지는 알지 못하고 알 수도 없다;
#   apply --dry-run=server 는 매니페스트를 apiserver로 보내고, apiserver는 이를 타입
#                  스키마와 admission 컨트롤을 통과시켜 수용할지 여부를 답하며,
#                  아무것도 만들지 않는다. 여기서 `unknown field`와 정책 거부가 나온다 —
#                  바로 차트가 고객 현장에서 걸려 넘어지는 지점이다.
# --dry-run=client 플래그는 이 점검을 주지 않는다: 매니페스트를 당신 머신에서 파싱한다.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # 권한 거부와 스키마 거부는 서로 다른 것이며, 혼동해서는 안 된다. 테넌트 접근
  # (~/.kube/workshop) 하에서는 Deployment와 ConfigMap에 대한 권한이 전혀 없으므로
  # 여기로 Forbidden이 날아온다 — 그리고 이는 차트의 품질에 대해 아무것도 말해주지
  # 않는다. 제대로 된 점검은 당신이 완전한 소유자인 `lab` 클러스터 접근으로만 가능하다.
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "서버 측 차트 점검을 건너뜁니다: 현재 접근으로는 수행할 수 없습니다" \
         "자신의 클러스터 접근으로 실행하세요: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "클러스터가 렌더링된 차트를 거부합니다" \
         "확인: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "서버 거부" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "클러스터가 렌더링된 차트를 수용합니다 — 필드와 그 위치가 올바릅니다"
  fi
else
  warn "클러스터 대상 차트 점검을 건너뜁니다: 접근 불가" \
       "helm template을 kubectl apply --dry-run=server로 통과시키려면 KUBECONFIG를 설정하세요"
fi

# --- 파라미터가 실제로 매니페스트까지 도달함 -------------------------
# 차트가 빌드되고 렌더링되더라도 파라미터가 어디에도 대입되지 않을 수 있다 —
# 예를 들어 값이 템플릿에 숫자로 하드코딩된 경우다. 그래서 각 파라미터를 실제로
# 시험한다: 일부러 특이한 값을 지정하고 완성된 매니페스트에서 그것을 찾는다.
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "replicas 파라미터가 매니페스트까지 도달합니다 (--set replicas=5 가 replicas: 5 를 만듭니다)"
else
  fail "replicas 파라미터가 매니페스트까지 도달하지 않습니다" \
       "templates/deployment.yaml 에 replicas: {{ .Values.replicas }} 가 있어야 합니다"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "external 파라미터가 Service 타입을 LoadBalancer로 전환합니다"
else
  warn "external 파라미터가 Service 타입을 전환하지 않습니다" \
       "차트 결함은 아니지만 Cozystack 카탈로그 관례입니다: 애플리케이션의 external 필드는 바로 외부 접근을 의미합니다"
fi

# --- 스키마가 실제로 보호함 ------------------------------------------
# 아무것도 거부하지 않는 스키마는 쓸모없다. 스키마가 거부하는지 점검한다.
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "값 스키마가 명백히 잘못된 값을 거부하지 않습니다 (replicas=abc 가 통과됨)" \
       "values.schema.json 이 values.yaml 옆에 있고 replicas를 integer로 선언했는지 확인하세요"
else
  ok "값 스키마가 잘못된 타입을 거부합니다 (replicas=abc 가 통과하지 못함)"
fi

# --- ApplicationDefinition: 필수 필드 ------------------------------
# 참가자는 정의를 적용할 수 없으므로 apiserver의 거부도 보지 못한다. 그래서 필수
# 필드를 여기서 세어본다: 그중 하나라도 없으면 관리자가 자기 쪽에서 거부를 받게 되고,
# 그 원인을 파악하는 것은 파일 작성자의 몫이 된다.
if [ ! -f "$APPDEF" ]; then
  fail "찾을 수 없음: ${APPDEF}" \
       "파일은 차트 옆에 있어야 합니다; 랩 저장소에서 가져오세요"
else
  MISSING=""
  # YAML을 파싱하지 않고 키를 줄 단위로 찾는다: PyYAML은 모든 머신에 있지 않으며,
  # 파일 하나 점검하려고 의존성을 끌어오는 것은 그럴 가치가 없다.
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
    fail "ApplicationDefinition에 누락된 필드가 있습니다:${MISSING}" \
         "README의 설명과 대조하세요 — 그중 하나라도 없으면 관리자가 적용 시 거부를 받습니다"
  fi

  # --- 정의 안의 스키마가 파싱되고 차트 스키마와 일치함 ---------
  # 이 둘은 같은 것의 별개 복사본이며, 서로 아무 연결도 없다.
  # 서로 어긋나면 대시보드 폼은 차트가 기대하지 않는 필드를 보여준다.
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "ApplicationDefinition의 openAPISchema가 비어 있습니다" \
         "그 자리에 chart/values.schema.json의 내용을 한 줄로 넣으세요"
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
        ok "정의 안의 스키마가 파싱되고 차트 스키마와 일치합니다 (${CMP#SAME })"
        evidence "애플리케이션 파라미터" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "정의 안의 스키마가 차트 스키마와 어긋났습니다: ${CMP#DIFF }" \
             "서로 일치시키세요: openAPISchema 내용은 chart/values.schema.json을 한 줄로 넣은 것입니다"
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
  # 대시보드는 base64로 담긴 SVG를 기대하며, 이미지를 어디서도 가져오지 않는다. 여기서의
  # 오류는 조용하다: 매니페스트는 적용되지만 카탈로그의 아이콘 자리는 비어 있게 된다. 그래서
  # 문자열을 디코드하여 그 안이 정말로 SVG인지 살핀다.
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "아이콘이 base64에서 디코드되며 SVG로 확인됩니다"
        evidence "아이콘 시작 부분" "$ICON_HEAD"
        ;;
      "")
        fail "아이콘이 base64에서 디코드되지 않습니다" \
             "문자열을 다시 만드세요: base64 -i icon.svg | tr -d '\\n' (Linux에서는: base64 -w0 icon.svg)"
        ;;
      *)
        fail "아이콘이 디코드되지만 SVG가 아닙니다" \
             "대시보드는 바로 SVG를 기대합니다; 래스터 이미지는 깨진 문자로 보여줍니다"
        ;;
    esac
  fi
fi

# --- 권한: 여기서의 거부는 예상된 것 --------------------------------------
# 이것은 참가자에 대한 점검이 아니라 플랫폼이 어떻게 구성되어 있는지에 대한 확인이다.
# 그래서 `no`라는 답은 성공이고, `yes`는 기뻐할 일이 아니라 놀랄 일이다.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "확인됨: 당신은 ApplicationDefinition을 적용할 수 없습니다 (can-i -> no)"
      evidence "ApplicationDefinition에 대한 권한" \
        "kubectl auth can-i create applicationdefinitions -> no
오브젝트가 cluster-scoped이며 모든 테넌트의 카탈로그를 바꾸므로, 플랫폼 관리자가 적용합니다."
      ;;
    yes)
      warn "당신에게 ApplicationDefinition을 적용할 권한이 있습니다 (can-i -> yes)" \
           "이는 당신이 테넌트 계정이 아니라 관리자 계정으로 작업 중임을 뜻합니다; 이 랩은 테넌트 계정을 대상으로 합니다"
      ;;
    *)
      warn "클러스터에 권한을 물어볼 수 없었습니다" \
           "랩 통과를 막지 않습니다: 점검은 로컬이며 여기서 클러스터는 필요 없습니다"
      ;;
  esac
else
  warn "클러스터에 질의하지 않았습니다 (KUBECONFIG가 설정되지 않았거나 응답하지 않음)" \
       "점검은 로컬이며 여기서 클러스터는 필요 없습니다. 권한 거부를 보려면: export KUBECONFIG=~/.kube/workshop"
fi

finish
