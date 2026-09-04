#!/usr/bin/env bash
# 실습 검사 스크립트를 위한 공용 라이브러리.
# 다음과 같이 불러옵니다:  . "$(dirname "$0")/../../check/lib.sh"
#
# `set -e`는 의도적으로 사용하지 않습니다: 스크립트는 모든 검사를 끝까지 수행하여
# 전체 그림을 보여줘야 하며, 첫 실패에서 멈추면 안 됩니다. 독자는 막혔을 때 바로
# 이 스크립트를 실행하므로, 중간에 끊는 것은 답의 절반을 감추는 것과 같습니다.

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# 색상은 출력이 터미널로 갈 때만 사용합니다: 파일이나 CI에서는 escape 시퀀스가
# 쓰레기 문자로 읽힙니다.
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- 기계가 읽을 수 있는 결과 ------------------------------------------------
# result-<실습>.json은 사람이 읽는 리포트와 함께 생성되며 검사 식별자와 그 결과만
# 담습니다. 문구, 명령 출력, 증거는 여기에 들어가지 않습니다: markdown 리포트에는
# 컨테이너 로그 꼬리, 외부 로드밸런서 주소, 노드 주소, 그리고 사용자 이름과 함께
# 접근 파일 경로가 쌓입니다. 이를 정규식으로 씻어내는 것은 미덥지 않습니다 —
# 미더운 방법은 애초에 만들지 않는 것입니다.
#
# 식별자는 스스로 도출됩니다: 실습 내 검사의 순번에 문구의 짧은 해시를 더한 것입니다.
# 순번은 안정성을 주고, 해시는 텍스트의 은밀한 수정을 잡아냅니다 — 문구가 바뀌면
# 서비스가 이를 알아채고 같은 검사로 조용히 인정하지 않습니다.
_checks=()
_seq=0
_record() {   # _record <상태> <문구>
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

# fail "무엇이 잘못됐는지" "그것을 어떻게 할지"
fail() {
  _record fail "$1"
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - 할 일: $2")
}

warn() {
  _record warn "$1"
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - 참고: $2")
}

# evidence "제목" "값" — 산출물에 들어가며 터미널에는 출력되지 않습니다.
# 증거는 리포트를 누군가에게 보여줬을 때 그것이 실제로 의미를 갖도록 존재합니다.
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# 조기 종료도 반드시 리포트를 남겨야 합니다: README는 "커뮤니티에 스크립트 리포트를
# 첨부해서 오라"고 안내하지만, 예전에는 클러스터에 접근할 수 없을 때 첨부할 것이
# 없었습니다 — 즉 리포트가 필요한 바로 그 경우에 리포트가 없었던 것입니다.
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "KUBECONFIG 변수가 설정되지 않았습니다" \
         "먼저: export KUBECONFIG=~/lab.kubeconfig (새 터미널 창마다)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "KUBECONFIG=${KUBECONFIG}로 클러스터가 응답하지 않습니다" \
         "kubectl get nodes가 응답 없이 멈춘다면 — 클러스터 컨트롤 플레인이 올라오지 않은 것입니다; 대시보드에서 Kubernetes 애플리케이션 상태와 쿼터 초과(exceeded quota)에 대한 테넌트 이벤트를 확인하세요"
    evidence "접근 파일" "$KUBECONFIG"
    evidence "클러스터 응답" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s COZY_TENANT 변수가 설정되지 않았습니다\n' "$_C_FAIL" "$_C_OFF"
    printf '         %s예: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# GNU 확장 없는 시간 처리: macOS의 BSD date는 `-d`를 이해하지 못합니다.
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# 기계가 읽는 결과가 저장되는 위치. 의도적으로 저장소 밖에 둡니다: 클론 안에 두면
# 첫 `git pull`이나 브랜치 전환에 지워지는데, 이 결과들은 여러 주에 걸쳐 모입니다.
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # 클러스터 식별자 — kube-system 네임스페이스의 uid. 한 클러스터의 모든 실행에서
  # 동일하고 사람마다 다르며, 무엇보다 테넌트 이름과 달리 "손으로 입력"할 수 없습니다.
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
    verdict="실습 통과"
  else
    verdict="미해결 항목 있음"
  fi

  _write_result_json "$([ "$_fail" -eq 0 ] && echo passed || echo failed)"

  printf '\n'
  printf '검사: %d · 통과: %d · 실패: %d · 경고: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# 리포트: ${LAB_TITLE}"
    echo
    echo "- 날짜: $(_now)"
    echo "- 결과: **${verdict}**"
    echo "- 검사: ${total} (통과 ${_pass}, 실패 ${_fail}, 경고 ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- 테넌트: \`${COZY_TENANT}\`"
    echo
    echo "## 검사"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## 증거"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "이 리포트는 Cozystack 실습의 \`check.sh\` 스크립트가 생성했습니다."
    echo "매니페스트가 적용됐다는 사실이 아니라 실제 동작을 본질적으로 검증했습니다."
  } > "$report"

  printf '리포트: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# 정확히 서버 버전. `kubectl version -o json`은 클라이언트와 서버 버전을 모두
# 출력하는데, gitVersion에 대한 순진한 grep은 첫 번째로 걸리는 것 — 클라이언트 —
# 을 가져가고 리포트가 클러스터 버전에 대해 거짓말을 하기 시작합니다. 여기서
# 실수하기 쉬우므로 라이브러리로 빼냈습니다.
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# 사람이 읽을 수 있는 크기: Kubernetes는 allocatable을 Ki로 줄 때도, 순수 바이트로
# 줄 때도 있으며, 리포트의 "3258002390"은 독자에게 아무것도 말해주지 않습니다.
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

# 일회용 파드에서 명령을 실행하되, 비밀 값을 명령줄 인자가 아니라 임시 Secret에서
# 설정한 환경 변수를 통해 전달합니다.
#
# 왜 이렇게 하는가. 파드의 args에 들어가는 것은 `get pods` 권한이 있는 누구에게나
# 보이고, etcd에 저장되며, audit log로 들어가고, 노드의 `ps`에 드러납니다. 데이터베이스
# 실습들은 명령줄의 비밀번호가 나쁜 관행이라고 따로 설명합니다; 바로 그 짓을 하는
# 스크립트로 그것을 검사한다면 이중 잣대가 될 것입니다.
#
# 사용법:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c '$KEY1을 읽는 명령'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # Secret은 stdin에서 생성되므로 값이 kubectl 인자에 들어가지 않습니다.
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # 여기서도 securityContext는 필수입니다: 없으면 `restricted` 프로파일의 클러스터에서
  # 파드가 생성되지 않고, 데이터베이스 실습의 검사가 동작하지 않습니다.
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

# `restricted` 프로파일을 통과하는 securityContext가 포함된 override를 만듭니다.
# 따로 빼낸 이유: 동일한 부가 설정이 모든 일회용 파드에 필요하며, 이것이 없으면
# 검사 스크립트가 엄격한 클러스터에서 동작하지 않습니다.
# 명령 인자는 각각 개별적으로 전달되고 JSON은 python이 조립합니다:
# bash에서 따옴표를 수동으로 이스케이프하다가 이미 override가 깨지고 파드가 조용히
# 실패한 적이 있으며 — 그 오류는 2>/dev/null이 삼켜버렸습니다.
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

# 일회용 파드에서 명령을 실행하고 그 출력을 반환합니다.
# 클러스터 내부에서 서비스 도달 가능성을 검사하는 곳에서 필요합니다: 노트북에서는
# ClusterIP가 보이지 않습니다. 파드는 어떤 경우에도 스스로 정리됩니다.
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext는 필수입니다: `restricted` 프로파일의 클러스터에서는 이것이 없는
  # 파드가 생성되지 않으며, 참가자가 실습을 아예 검사할 수 없습니다.
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm`은 클라이언트가 붙어 있는 동안에만 파드를 삭제합니다: 연결 끊김, 타임아웃,
  # Ctrl+C는 파드를 남겨둡니다. 명시적 삭제는 스크립트가 클러스터를 어지럽히지
  # 않도록 하기 위함입니다.
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# 여러 요청의 응답을 연달아, 한 줄에 하나씩 모읍니다.
#
# 서비스 뒤에 복제본이 여러 개일 때 요청 하나는 복권과 같습니다: 같은 레이블을 가진
# 엉뚱한 파드가 로드 밸런싱에 끼어들지만, 단일 표본은 그것을 놓칠 수 있고, 검사는
# 바꿔치기된 콘텐츠에서 신나게 초록불이 됩니다. 확인됨: 스무 번 중 여덟 번의 요청이
# 사칭 파드로 갔고, 검사는 네 번 연속 "통과"라고 말했습니다.
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
