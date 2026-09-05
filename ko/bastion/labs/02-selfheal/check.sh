#!/usr/bin/env bash
# 랩 2 확인: 자가 치유.
#
# 「명령을 입력했는지」가 아니라 랩 이후의 클러스터 상태를 확인합니다: 애플리케이션이 다시
# Service를 통해 요청을 처리하고, 자기 복제본의 이름을 반환하며, 그 이름이 실제로 동작 중인
# 파드에 속하는지. 그리고 복제본이 재생성되었다는 흔적을 찾습니다.
#
# 스크립트는 클러스터 내부에서 서비스 가용성을 확인하기 위한 일회용 파드를 제외하고는 아무것도
# 삭제하거나 생성하지 않습니다 — 그 파드는 스스로 사라집니다.

LAB_NAME="02-selfheal"
LAB_TITLE="랩 2 · 파드를 죽이고 무슨 일이 일어나는지 보기"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# kubectl이 주는 RFC3339(항상 Z가 붙은 UTC)를 unix 초로 변환. python3로 하는 이유는
# macOS의 BSD date와 Linux의 GNU date가 날짜를 서로 다르게 파싱하지만, python은 lib.sh가
# 동작하는 어디에나 있기 때문입니다.
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- 애플리케이션이 아예 존재하는가 ----------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "애플리케이션 ${APP}이(가) 클러스터에 없습니다" \
       "랩 마지막에 되돌려 놓았어야 합니다: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "namespace에 있는 것" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "애플리케이션 ${APP} 복구됨: 준비된 복제본 ${WANT}개 중 ${HAVE}개"
else
  fail "준비된 복제본 ${WANT}개 중 ${HAVE}개" \
       "kubectl describe deployment ${APP} 및 kubectl get pods -l app=${APP}를 보세요"
fi
evidence "애플리케이션 상태" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- 체인 Deployment -> ReplicaSet -> Pod ----------------------------------
# 이 랩의 핵심은 복제본을 되살리는 것이 「클러스터 일반」이 아니라 ReplicaSet이라는 점입니다.
# 파드의 소유자가 ReplicaSet이 아니라면, 참가자가 파드를 손으로 띄운 것이며, 자가 치유를
# 보지 못하게 됩니다.
# 소유자 종류의 고유값을 모으는 대신 파드를 이름별로 셉니다: ownerReferences가 없는 파드의
# 경우 jsonpath는 빈 문자열을 반환하고, `sort -u`는 그것을 보이지 않는 요소로 합쳐 버리며,
# 적어도 하나의 파드가 ReplicaSet에 관리되는 한 `*ReplicaSet*`이 매칭됩니다.
# 이 때문에 손으로 띄운 외부 파드가 눈에 띄지 않고 검사를 통과했습니다.
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "label app=${APP}을(를) 가진 파드가 하나도 없습니다" \
         "애플리케이션을 되돌리세요: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "어떤 ${APP} 파드도 ReplicaSet에 관리되지 않습니다 — 자가 치유가 일어나지 않습니다" \
         "파드가 손으로 띄워진 것으로 보입니다(kubectl run). 삭제하고 ../01-deploy/rickroll.yaml을 적용하세요"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "label app=${APP}을(를) 외부 파드가 달고 있습니다: ${PODS_TOTAL}개 중 ${PODS_BY_RS}개만 ReplicaSet에 관리됨" \
           "나머지는 로드 밸런싱에 끼어들어 남의 응답을 반환하게 됩니다 — 찾으세요: kubectl get pods -l app=${APP} -o wide"
      evidence "파드 소유자" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "복제본은 ReplicaSet에 관리됩니다 — 체인 Deployment → ReplicaSet → Pod가 온전합니다"
    evidence "누가 누구의 소유자인가" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- 복제본 재생성의 흔적 --------------------------------------------------
# 클러스터는 「파드를 죽였다」는 직접 증거를 보관하지 않습니다. 간접 증거가 두 개 있고,
# 둘 다 충분합니다: 파드가 자기 Deployment보다 눈에 띄게 젊고, ReplicaSet 이벤트에
# 생성이 한 번보다 많습니다.
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "복제본이 애플리케이션보다 ${DELTA}초 젊습니다 — 즉 이전 것은 제거되고 이것이 대신 생성됨"
  else
    warn "복제본이 애플리케이션과 거의 동갑입니다(차이 ${DELTA}초)" \
         "맨 마지막에 애플리케이션 전체를 복구했다면 정상입니다; 아니라면 파드 삭제 단계를 수행하지 않은 것입니다"
  fi
  evidence "객체 나이" "deployment 생성: ${DEP_TS}
pod 생성:          ${POD_TS}
차이:              ${DELTA}초"
else
  warn "파드와 애플리케이션의 나이를 비교할 수 없었습니다" \
       "PATH에 python3이 필요합니다; 랩 통과에는 영향이 없습니다"
fi

# 이벤트는 약 한 시간 동안 살아 있으므로, 그 부재는 실패가 아니라 참고 사항입니다.
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "클러스터 이벤트에 복제본 생성이 ${CREATES}번 — 자가 치유가 실제로 작동했습니다"
  evidence "복제본 생성 이벤트" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "클러스터 이벤트에 복제본 생성이 ${CREATES}번만 보입니다" \
       "이벤트는 약 한 시간 보관되며 만료되었을 수 있습니다"
fi

# 두 징후 중 어느 하나만으로는 차단 사유가 아닙니다: 이벤트는 약 한 시간 살아 있고,
# 랩 마지막에 애플리케이션 전체를 정당하게 복구한 사람은 나이가 일치합니다.
# 하지만 둘 다 충족되지 않으면 — 복제본을 아예 삭제하지 않은 것이고, 랩은 완료되지 않았습니다.
# 이 조합이 없으면 스크립트는 삭제 한 번도 기다리지 않고 랩 1 직후에 「랩 통과」를 출력했습니다.
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "자가 치유의 흔적을 찾지 못했습니다: 복제본을 삭제하지 않았습니다" \
       "복제본을 삭제하세요: kubectl delete pod -l app=${APP} — 그리고 이벤트가 살아 있는 동안 한 시간 안에 검사를 실행하세요"
fi

# --- 서비스가 실제로 처리한다 ----------------------------------------------
# 핵심적인 본질 검사: 「객체가 존재한다」가 아니라 「Service를 통해 페이지가 오고
# 그 안에 살아 있는 복제본의 이름이 들어 있다」.
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP}이(가) 클러스터 내부에서 페이지를 반환하지 않았습니다" \
       "엔드포인트를 확인하세요: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "페이지는 반환되지만, 복제본 이름이 그 안에 채워지지 않았습니다" \
       "ConfigMap rickroll-conf를 잃었습니다: ../01-deploy/rickroll.yaml을 전체로 적용하세요"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "Service 응답에 복제본 이름이 없습니다" \
         "페이지가 우리 애플리케이션에서 온 것이 아닙니다 — kubectl get svc ${APP} -o yaml을 확인하세요"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service가 페이지를 반환하고, 살아 있는 복제본 ${SERVED}이(가) 그것을 처리했습니다"
    evidence "Service 응답(일부)" \
      "$(printf '%s' "$BODY" | grep -o "요청을 처리한 Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "페이지를 복제본 ${SERVED}이(가) 반환했지만, 그런 파드는 클러스터에 이미 없습니다" \
         "십여 초 기다렸다가 검사를 다시 실행하세요 — 아마 복제본이 바로 지금 바뀌고 있었을 것입니다"
  fi
fi

# --- 다음 랩 준비 상태 ------------------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "복제본 수가 하나로 되돌아왔습니다 — 랩 3은 깨끗한 상태에서 시작합니다"
else
  warn "현재 요청된 복제본 수: ${WANT}" \
       "랩 3 전에 하나로 되돌리세요: kubectl scale deployment ${APP} --replicas=1"
fi

finish
