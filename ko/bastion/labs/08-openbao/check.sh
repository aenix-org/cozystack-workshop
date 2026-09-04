#!/usr/bin/env bash
# 랩 8 검사: 비밀번호가 매니페스트에서 OpenBao로 옮겨졌고 규칙에 따라 관리되는지 확인한다.
#
# "객체가 생성되었는가"가 아니라 본질을 검사한다: 볼트가 봉인 해제되었고, 토큰으로
# 시크릿을 읽을 수 있으며, 버전이 하나보다 많고(즉 실제로 로테이션이 있었다는 뜻),
# 감사가 활성화되어 있으며, 적용된 애플리케이션 매니페스트에 평문 비밀번호가 없는지.
#
# 어떤 시크릿도 리포트에 들어가지 않는다. 값은 어디에도 출력되지 않는다.
#
# 스크립트는 curl이 들어간 일회용 파드를 띄우므로 실행에 약 1분 걸린다.

# LAB_NAME과 LAB_TITLE은 리포트 헤더로 들어간다. 아래에서 공통 검사 라이브러리를
# 로드한다: 여기서 ok / warn / fail / evidence / finish와 클러스터 안에서 일회용 파드를
# 띄우는 함수들을 가져온다. need_kubeconfig와 need_tenant는 접근 권한이나 테넌트 번호가
# 지정되지 않았으면 스크립트를 미리 중단한다: 그렇지 않으면 모든 게 한꺼번에 실패해서
# 리포트만 봐서는 원인을 알 수 없게 된다.
LAB_NAME="08-openbao"
LAB_TITLE="랩 8 · 매니페스트에 없는 시크릿"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- 어디를 볼 것인가 ---------------------------------------------------------
# 참가자는 COZY_TENANT를 `workshop07`로 지정하지만, 네임스페이스는
# `tenant-workshop07`로 불린다. 두 표기를 모두 받아들인다: 여기서 실수하기 쉽고,
# 오류 메시지도 모호했을 것이다("서비스가 응답하지 않음").
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 무엇을 어디서 찾는가. BAO_APP은 테넌트 안 OpenBao 애플리케이션의 이름이고, 볼트의
# 내부 주소에 포함된다: 애플리케이션 이름을 다르게 지었다면 검사를
# BAO_APP=이름 ./check.sh 로 실행하라. SECRET_PATH는 랩이 데이터베이스 비밀번호를
# 넣어 두는 볼트 내부 경로다.
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "볼트 주소" "$BAO_URL"

# 표준 입력의 JSON에서 키 체인을 따라 값을 꺼낸다.
# 경로가 없거나 JSON이 아니면 1을 반환한다 — 이렇게 해서 호출자가
# "그런 키 없음"과 "빈 값"을 구별할 수 있다.
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1:]:
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        sys.exit(1)
print("" if d is None else d)
' "$@" 2>/dev/null
}


# OpenBao로 보내는 요청. 토큰은 임시 Secret에서 온 환경 변수로 전달하고, 인자에
# 헤더로 넣지 않는다: 파드의 인자는 `get pods` 권한이 있는 누구에게나 보이고, etcd에
# 저장되며 감사 로그로 간다. 여기서 그것은 볼트의 root 토큰 — 이 랩 전체가 바로 그
# 유출에 맞서 쓰였다.
#
# 정의는 첫 호출 전에 놓는다: else 분기 안에 있었을 때, 가장 첫 검사가 존재하지 않는
# 함수를 호출해서 랩이 절대 통과할 수 없었다.
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. 볼트가 응답한다 -------------------------------------------------
# 첫 요청이 두 가지 질문에 한꺼번에 답한다: 애플리케이션이 떴는가, 그리고 테넌트 번호가
# 맞는가. 봉인 상태를 물어본다 — 이것은 OpenBao가 토큰 없이 제공하는 유일한 엔드포인트다.
# 이후 빈 응답은 "연결 없음"을 의미하고, 모든 내용 검사는 의미를 잃는다.
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao가 ${BAO_URL} 주소로 응답하지 않습니다" \
       "COZY_TENANT의 테넌트 번호와 애플리케이션 이름을 확인하세요(기본값 'secrets'; 아니면 BAO_APP=이름 ./check.sh); 대시보드에서 애플리케이션이 준비 상태여야 합니다"
else
  ok "OpenBao가 테넌트 내부 주소로 응답합니다"
fi

# --- 2. 초기화됨 --------------------------------------------------------
# 초기화는 볼트가 마스터 키와 첫 토큰을 만드는 일회성 작업이다. 이것을 하기 전에는
# 안에 아무것도 없다: 시크릿도, 그것을 넣을 자리도 없다.
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "볼트가 초기화되었습니다"
elif [ -n "$SEAL" ]; then
  fail "볼트가 초기화되지 않았습니다" \
       "실행: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 그리고 출력을 저장하세요"
fi

# --- 3. 봉인 해제됨 --------------------------------------------------------
# 봉인된 볼트는 파드 재시작 후의 정상 상태다: 데이터는 디스크에 있지만, unseal 키를
# 입력하기 전에는 그것을 읽을 방법이 없다. 그래서 객체의 존재가 아니라 동작을 검사하라는
# 요구가 나온다: "애플리케이션 준비됨"과 "시크릿이 제공됨"은 서로 다른 두 진술이고,
# 후자는 전자로부터 따라오지 않는다.
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "볼트가 봉인 해제되어 요청을 처리하고 있습니다"
  evidence "볼트 상태" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "볼트가 봉인되어 있습니다 — 어떤 요청에도 503 거부로 응답합니다" \
       "실행: kubectl exec bao-workbench -- bao operator unseal <당신의-unseal-키>"
  evidence "볼트 상태" "$SEAL"
fi

# --- 4. 시크릿이 제자리에 있고 읽힌다 -----------------------------------------
# 다음으로 토큰이 필요하다. 없으면 검사할 것이 없지만, 조용히 넘어가서도 안 된다:
# 독자는 무엇이 빠졌는지 봐야 한다.
if [ -z "$SEAL" ]; then
  # 연결이 없다 — 내용 검사는 무의미하다. 위에서 이미 밝힌 같은 원인 하나에서 비롯된
  # 네 개의 실패로 리포트를 채우지 않도록 침묵한다.
  warn "볼트 내용을 검사하지 않았습니다: OpenBao로 연결이 없습니다" \
       "연결 문제를 해결한 다음 스크립트를 다시 실행하세요"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "BAO_TOKEN 변수가 설정되지 않아 볼트 내용을 검사하지 않았습니다" \
       "export BAO_TOKEN='볼트를 처음 봉인 해제할 때 출력된 root 토큰' 후 스크립트를 다시 실행하세요"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "시크릿 secret/${SECRET_PATH}이(가) 토큰으로 읽히고, password 필드가 비어 있지 않습니다"
    # 리포트에는 값이 아니라 버전 번호를 넣는다.
    evidence "시크릿" "경로: secret/${SECRET_PATH}
password 필드: 있음(값 숨김)
현재 버전: ${DATA_VERSION:-알 수 없음}"
  else
    fail "secret/${SECRET_PATH} 경로에 password 필드가 없습니다" \
         "넣으세요: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; 엔진이 아직 활성화되지 않았다면 — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. 로테이션이 실제로 있었다 --------------------------------------
  # 시크릿의 버전이 단 하나라는 것은 한 번 넣고 잊었다는 뜻이다. 로테이션이야말로 볼트를
  # 두는 이유다: 매니페스트를 뒤져 찾는 대신 한 곳에서 비밀번호를 바꾼다. 약속이 아니라
  # 버전을 센다: 그 수는 볼트가 스스로 관리한다.
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "시크릿이 변경되었습니다: 버전 ${CUR_VER}개, 즉 로테이션이 말뿐이 아니라 실제로 일어났습니다"
    evidence "시크릿 버전 이력" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "시크릿에 버전이 하나뿐입니다 — 로테이션을 하지 않았습니다" \
         "비밀번호를 바꾸세요: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<새-값> 그리고 애플리케이션을 재시작하세요"
  fi

  # --- 6. 정책이 좁고 "무엇이든 가능"이 아니다 ---------------------------------
  # 정책은 "토큰을 손에 넣은 사람이 무엇을 할 수 있는가"에 대한 답이다. 그래서 그것의
  # 존재 여부가 아니라 내용을 본다: 볼트 전체가 아니라 특정 경로에 부여되었는지, 그리고
  # 읽기 전용인지.
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "passes-read 정책이 존재합니다"
    evidence "passes-read 정책" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "정책이 볼트 전체가 아니라 특정 경로에 부여되었습니다"
    else
      warn "정책은 있지만, 그 안에 secret/data/${SECRET_PATH} 경로가 보이지 않습니다" \
           "정책에 data 접두사가 지정되어 있는지 확인하세요: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "정책이 읽기만이 아니라 그 이상을 허용합니다" \
           "애플리케이션에는 read로 충분합니다; 불필요한 권한은 제거하는 것이 좋습니다"
    fi
  else
    fail "passes-read 정책을 찾을 수 없습니다" \
         "만드세요: kubectl exec -i bao-workbench -- bao policy write passes-read - < 당신의 정책 파일(정책 해설은 README에)"
  fi

  # --- 7. 감사가 활성화됨 ----------------------------------------------------
  # 감사 로그가 없으면 "누가 언제 이 시크릿을 읽었는가"라는 질문에 답할 것이 없다 — 그리고
  # 이것은 사고 후 가장 먼저 나오는 질문이다. 연결된 로깅 장치를 센다: 적어도 하나는 있어야
  # 한다.
  AUD="$(bao_get "/v1/sys/audit")"
  AUD_COUNT="$(printf '%s' "$AUD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
data = d.get("data", d)
print(len([k for k in data if isinstance(data.get(k), dict)]))
' 2>/dev/null)"
  case "$AUD_COUNT" in
    ''|*[!0-9]*) AUD_COUNT=0 ;;
  esac
  if [ "$AUD_COUNT" -ge 1 ]; then
    ok "감사 로그가 활성화되었습니다(장치: ${AUD_COUNT}개)"
    evidence "감사 장치" "$AUD"
  else
    fail "감사 로그가 활성화되지 않았습니다 — 누가 시크릿을 읽었는지 답할 것이 없습니다" \
         "활성화하세요: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. 랩 클러스터의 애플리케이션 ---------------------------------
# 지금까지는 관리 클러스터의 볼트를 검사했다. 다음은 애플리케이션 자체가 사는 당신의 lab
# 클러스터다. 여기서 중요한 것은 Deployment가 생성되었다는 사실이 아니라 준비된 복제본의
# 존재다: 비밀번호를 가져오지 못한 init 컨테이너는 파드를 뜨지 못하게 하고, 바로 이 상태를
# "다 좋음"과 구별해야 한다.
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "랩 클러스터에 애플리케이션 ${APP_DEPLOY}이(가) 없습니다" \
       "적용하세요: kubectl apply -f secrets-demo.yaml (당신의 테넌트 번호를 넣는 것을 잊지 마세요)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "애플리케이션 ${APP_DEPLOY}이(가) 실행 중입니다(준비된 복제본: ${READY}개)"
  else
    fail "애플리케이션 ${APP_DEPLOY}은(는) 있지만, 준비된 복제본이 하나도 없습니다" \
         "kubectl describe deploy/${APP_DEPLOY} 와 kubectl logs deploy/${APP_DEPLOY} -c fetch-secret 를 보세요 — 보통 init 컨테이너가 볼트에 도달하지 못했거나 토큰으로 거부당한 것입니다"
  fi

  # --- 9. 매니페스트에 평문 비밀번호가 없다 -------------------------
  # 디스크의 파일이 아니라 적용된 객체를 본다: 무엇이든 적용되었을 수 있다.
  LEAKS="$(kubectl get deploy "$APP_DEPLOY" -o json 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
suspicious = re.compile(r"(?i)pass|secret|token|key|cred")
spec = d.get("spec", {}).get("template", {}).get("spec", {})
found = []
for c in list(spec.get("initContainers", [])) + list(spec.get("containers", [])):
    for e in c.get("env", []):
        if "value" in e and suspicious.search(e.get("name", "")):
            found.append("%s / env %s이(가) 참조가 아니라 값으로 지정되었습니다" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "애플리케이션 매니페스트에 비밀번호가 값으로 지정된 변수가 없습니다"
  else
    fail "애플리케이션 매니페스트에 여전히 민감한 값이 평문으로 남아 있습니다" \
         "제거하세요: 값은 볼트에서 와야 하고, 매니페스트에는 참조만 있어야 합니다. secrets-demo.yaml 참고"
    evidence "매니페스트에서 발견된 것" "$LEAKS"
  fi

  # --- 10. 애플리케이션이 실제로 시크릿을 받았다 ------------------------
  # 마지막 증거는 객체 설명이 아니라 로그에서 가져온다. 매니페스트가 완벽해도 비밀번호가
  # 파드에 끝내 도착하지 않을 수 있다. 두 가지를 한꺼번에 본다: init 컨테이너가 볼트에
  # 다녀왔다고 알렸고, 애플리케이션이 지문을 출력한다 — 즉 받은 비밀번호로 실제로 동작한다.
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init 컨테이너가 볼트에서 시크릿을 가져왔습니다"
    evidence "init 컨테이너 로그" "$INIT_LOG"
  else
    fail "init 컨테이너가 볼트에서 시크릿을 가져온 흔적이 보이지 않습니다" \
         "kubectl logs deploy/${APP_DEPLOY} -c fetch-secret 를 확인하세요; 그런 컨테이너가 없다면 — 오래된 매니페스트가 적용된 것입니다"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "애플리케이션이 받은 비밀번호로 동작합니다(로그에는 값이 아니라 지문이 기록됩니다)"
    evidence "애플리케이션 로그" "$APP_LOG"
  else
    fail "애플리케이션 로그에 비밀번호 지문이 없습니다" \
         "kubectl logs deploy/${APP_DEPLOY} -c app 를 확인하세요 — 컨테이너가 시작하지 못했을 수 있습니다"
  fi
fi

# --- 11. 순진한 시크릿이 제거됨 ----------------------------------------------
# 랩을 실제로 했을 때만 "제거됨"으로 인정한다: 깨끗한 클러스터에는 시크릿이 애초에 없었고,
# 리포트가 일어나지도 않은 정리에 대해 참가자를 칭찬했을 것이다.
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "클러스터에 순진한 단계의 passes-db 시크릿이 남아 있습니다" \
       "더 이상 필요 없고 오래된 비밀번호를 담고 있습니다: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "순진한 passes-db 시크릿이 제거되었습니다"
fi

finish
