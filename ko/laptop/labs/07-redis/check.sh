#!/usr/bin/env bash
# 랩 7 검증: 캐시가 실제로 속도를 높이며, 그 수치가 이를 보여준다.
#
# 여기서의 핵심 검증은 구조적이 아니라 동작 기반이다. 스크립트는 사용되지 않은
# 식별자를 골라 두 번 요청하고 관찰한다: 첫 번째는 수백 밀리초의 미스여야 하고,
# 두 번째는 한 자릿수의 히트여야 한다. 올바른 환경 변수가 담긴 매니페스트라도
# 캐시가 실제로 응답하지 않으면 이 검증을 통과하지 못한다.
#
# 두 개의 클러스터: KUBECONFIG — 여러분의 lab 클러스터, COZY_KUBECONFIG — 관리형
# Redis 서비스가 있는 Cozystack 관리 클러스터.

# LAB_NAME과 LAB_TITLE은 보고서 헤더에 들어간다. 그다음 공용 검증 라이브러리가
# 로드된다: 여기서 ok / warn / fail / evidence / finish를 가져오며, 무엇보다
# in_cluster_curl — 클러스터 내부에 curl이 담긴 일회성 파드를 띄운다. 노트북이 아니라
# 내부에서: 랩 서비스는 외부로 노출되지 않으며, passes-api는 클러스터 내부에서만
# 이름으로 접근할 수 있다. need_kubeconfig와 need_tenant는 접근 권한이나 테넌트 번호가
# 지정되지 않았으면 스크립트를 미리 멈춘다 — 그렇지 않으면 모든 검증이 한꺼번에 실패하고
# 보고서로 원인을 알 수 없게 된다.
LAB_NAME="07-redis"
LAB_TITLE="랩 7 · 느린 백엔드 앞의 캐시"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# 전체 검증이 바라보는 이름과 주소는 한곳에 모아 두었다: 스크립트 본문에서 찾아다닐
# 필요가 없다. 테넌트 접근 권한이 기본 위치가 아닌 곳에 있다면 COZY_KUBECONFIG는
# 외부에서 재정의할 수 있다.
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# 스크립트 전체에서 쓰는 두 가지 단축 함수: kget은 lab 클러스터(KUBECONFIG에 있는 것)에,
# cozy는 Cozystack 관리 클러스터에 접근한다. 오류 메시지는 의도적으로 억제한다:
# 여기서 객체가 없는 것은 정상적인 상황이며, 스크립트가 kubectl의 남의 텍스트가 아니라
# 자기 말과 힌트로 설명해 준다.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# JSON에서 필드 하나를 꺼낸다. jq 없이: 순정 macOS에는 jq가 없지만, 나머지 검증
# 라이브러리가 동작하는 곳이면 어디나 python3는 있다.
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- 관리 클러스터의 관리형 Redis 서비스 -------------------------------------
# Redis는 여러분의 lab 클러스터가 아니라 관리 클러스터의 테넌트에 있다: 관리형
# 서비스이며 플랫폼이 스스로 운영을 유지한다. 테넌트 권한은 사람마다 다르므로
# 접근 거부도 kubeconfig 부재도 랩을 실패시키지 않는다 — 캐시 동작은 아래에서
# 직접 실제 요청으로 검증하며, 그것이 진짜 증거다.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "테넌트 kubeconfig ${COZY_KUBECONFIG}를 찾을 수 없음 — Redis 상태를 확인하지 않음" \
       "경로를 지정하세요: export COZY_KUBECONFIG=~/.kube/workshop"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "테넌트 ${TENANT_NS}에서 Redis 애플리케이션을 볼 수 없음" \
         "테넌트 역할이 이 명령을 허용하지 않을 수 있음 — 랩 오류가 아님; 캐시는 아래에서 직접 검증함"
  elif [ -z "$REDIS_LIST" ]; then
    fail "테넌트 ${TENANT_NS}에 Redis 애플리케이션이 하나도 없음" \
         "대시보드에서 생성하세요: 애플리케이션 생성 -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "관리형 Redis «${R_NAME}» 준비 완료, 데이터 복제본: ${R_REPLICAS:-기본값}"
    else
      warn "Redis «${R_NAME}»는 있으나 준비 상태를 알리지 않음" \
           "대시보드에서 상태를 확인하세요; 기동에 3~5분 걸립니다"
    fi
    evidence "테넌트의 Redis" "$REDIS_LIST"
  fi
fi

# --- 느린 디렉터리가 제자리에 있고 실제로 느린지 ------------------------------
# 이 검증이 없으면 「전과 후」 비교는 아무 의미가 없다: 디렉터리가 즉시 응답하면
# 속도를 높일 것이 없고 캐시로 측정할 것도 없다.
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "디렉터리 ${HR}가 동작하지 않음" \
       "hr-legacy.yaml을 적용하고 kubectl describe pod -l app=hr-legacy를 확인하세요"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "디렉터리가 ${HR_MS} ms에 응답함 — 속도를 높일 여지가 있음"
    evidence "디렉터리 지연" "/employee 요청당 ${HR_MS} ms"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "디렉터리 ${HR}가 요청에 응답하지 않음" \
         "kubectl logs -l app=hr-legacy를 확인하세요"
  else
    warn "디렉터리가 ${HR_MS} ms에 응답함, 측정하기에 너무 빠름" \
         "hr-legacy.yaml에 MODE=hr와 HR_DELAY=800ms가 설정되어 있는지 확인하세요"
  fi
fi

# --- 애플리케이션이 캐시를 사용하도록 구성됨 ----------------------------------
# 컨테이너 환경은 jsonpath가 아니라 python으로 파싱한다: 중첩 리스트에 대한 jsonpath
# 필터는 kubectl 버전마다 동작이 다른데, 우리는 검증이 모두에게 동일하게 동작하기를
# 바라기 때문이다.
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

# 문제는 순서대로 처리된다 — 가장 일반적인 것부터 가장 구체적인 것까지: 애플리케이션
# 없음, 변수 없음, 주소 대신 남은 플레이스홀더. 여기서 순서는 겉치레가 아니다:
# 그렇지 않으면 참가자는 서비스 자체가 아직 배포되지 않은 시점에 「Redis 주소를
# 입력하라」는 조언을 받고 엉뚱한 곳에서 오류를 찾게 된다.
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "lab 클러스터에 애플리케이션 ${APP}가 없음" \
       "자신의 Harbor 주소를 입력하여 passes-api.yaml을 적용하세요"
elif [ -z "$REDIS_ADDR" ]; then
  fail "${APP}에 REDIS_ADDR 변수가 설정되지 않음 — 캐시가 꺼져 있음" \
       "패치를 적용하세요: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "패치에 플레이스홀더 주소 REDIS-ADDR가 남아 있음" \
       "자신의 Redis 주소를 입력하세요, 예: rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "애플리케이션이 주소 ${REDIS_ADDR}의 캐시를 사용하도록 구성됨, 항목 수명 ${TTL:-기본값} s"
fi

# 변수 이름의 존재 여부만 확인하고 그 값은 어디에서도 읽거나 출력하지 않는다.
# 랩 보고서는 사람들이 서로 전달하고 티켓에 첨부한다 — 거기에 들어간 비밀번호는
# 영원히 남는다.
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "Redis 비밀번호가 애플리케이션에 전달됨 (값: <숨김>)"
else
  fail "${APP}에 REDIS_PASSWORD 변수가 설정되지 않음" \
       "Redis는 인증을 요구합니다; redis-password 시크릿을 생성하고 cache-patch.yaml을 적용하세요"
fi

# 시크릿 부재는 실패가 아니라 경고다: 비밀번호는 다른 방법으로도 파드에 전달할 수
# 있다. 여기서 검증하는 속성은 다른 것이다 — 매니페스트에는 값이 아니라 참조가
# 담겨 있다.
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "Redis 비밀번호가 담긴 redis-password 시크릿이 존재함"
else
  warn "클러스터에 redis-password 시크릿이 없음" \
       "생성하세요: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- 핵심 검증: 캐시가 실제로 속도를 높이는지 --------------------------------
# 첫 요청이 확실히 미스가 되도록 일부러 새로운 식별자를 고른다.
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "서비스 ${APP}가 기대한 JSON을 반환하지 않음" \
       "kubectl logs -l app=passes-api를 확인하세요; 이미지가 이 랩의 app/에서 빌드되었는지(태그 v2) 확인하세요"
  evidence "서비스가 응답한 내용" "첫 번째 요청: ${R1:-비어 있음}
두 번째 요청: ${R2:-비어 있음}"
elif [ "$MODE" != "redis" ]; then
  fail "애플리케이션이 캐시가 꺼져 있다고 보고함 (cache: ${MODE})" \
       "REDIS_ADDR 변수가 실행 중인 파드에 전달되지 않음 — kubectl rollout status deployment/${APP}를 확인하세요"
elif [ "$C1" = "True" ]; then
  warn "첫 요청이 이미 캐시에서 옴 — 비교할 대상이 없음" \
       "식별자 충돌로 보기 어려운 우연; 검증을 다시 실행하세요"
elif [ "$C2" != "True" ]; then
  fail "같은 식별자에 대한 두 번째 요청이 또 캐시에 적중하지 못함" \
       "애플리케이션이 Redis에 쓰지 못함: kubectl logs -l app=passes-api를 확인하세요, 보통 NOAUTH 또는 타임아웃임"
  evidence "서비스 응답" "첫 번째:  ${R1}
두 번째: ${R2}"
else
  ok "캐시 동작함: 미스 ${T1} ms, 히트 ${T2} ms"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "1000배 이상")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "실제 서비스에서의 측정" "식별자: ${PROBE_ID}
첫 번째 요청 (미스):   ${T1} ms
두 번째 요청 (히트): ${T2} ms
이득: 약 ${SPEEDUP}배
항목 수명: ${TTL:-기본값} s"

  # 엄격한 부분: 히트는 미스보다 한 자릿수 빨라야 한다. 그렇지 않으면
  # 「캐시 동작함」은 키가 쓰였다는 것만 의미하고 이득은 없다.
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "이득이 측정 가능함: 히트가 미스보다 약 ${SPEEDUP}배 빠름"
  else
    warn "캐시 히트가 눈에 띄는 이득을 주지 못함 (${T1} ms 대 ${T2} ms)" \
         "디렉터리가 실제로 느린지, 그리고 Redis가 같은 파드에 있지 않은지 확인하세요"
  fi
fi

# --- 서비스 복제본 몇 개가 하나의 캐시를 공유하는지 ---------------------------
# 캐시는 모든 복제본이 공유한다 — 이는 보고서에서 볼 만하다: 히트가 미스와 다른
# 파드에서 왔을 수 있으며, 그것이 정상이다.
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "동작 중인 서비스 복제본: ${API_PODS} (캐시를 공유함)"
  evidence "서비스 복제본" "$(kget pods -l app=passes-api -o wide)"
else
  fail "${APP}의 동작 중인 복제본이 하나도 없음" \
       "kubectl describe pod -l app=passes-api를 확인하세요"
fi

finish
