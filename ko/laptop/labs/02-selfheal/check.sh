#!/usr/bin/env bash
# 랩 2 검증: 자가 치유.
#
# 「명령어를 입력했는지」가 아니라 랩 이후의 클러스터 상태를 검증한다: 애플리케이션이 다시
# Service를 통해 요청을 처리하고, 자기 복제본의 이름을 반환하며, 그 이름이 실제로 실행 중인
# 파드에 속하는지. 더불어 복제본이 재생성된 흔적도 찾는다.
#
# 이 스크립트는 클러스터 내부에서 서비스 가용성을 확인하기 위한 일회성 파드 외에는
# 아무것도 삭제하거나 생성하지 않는다 — 그 파드는 스스로 정리한다.

LAB_NAME="02-selfheal"
LAB_TITLE="랩 2 · 파드를 죽이고 무슨 일이 일어나는지 지켜보기"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# kubectl의 RFC3339(항상 Z가 붙은 UTC)를 unix 초로 변환. python3를 쓰는 이유는
# macOS의 BSD date와 Linux의 GNU date가 날짜를 서로 다르게 파싱하지만, python은 lib.sh가
# 동작하는 모든 곳에 있기 때문이다.
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- 애플리케이션이 존재하는가 ---------------------------------------------
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
  fail "준비된 복제본이 요청한 ${WANT}개 중 ${HAVE}개입니다" \
       "kubectl describe deployment ${APP} 및 kubectl get pods -l app=${APP}를 확인하세요"
fi
evidence "애플리케이션 상태" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- Deployment -> ReplicaSet -> Pod 체인 ----------------------------------
# 이 랩의 핵심은 복제본을 되살리는 주체가 「클러스터 일반」이 아니라 ReplicaSet이라는 점이다.
# 파드의 소유자가 ReplicaSet이 아니라면, 참가자가 파드를 손으로 띄운 것이고
# 자가 치유를 볼 수 없다.
# 소유자 종류의 고유값을 모으는 대신 파드를 이름별로 센다: ownerReferences가 없는 파드는
# jsonpath가 빈 문자열을 반환하고, `sort -u`가 그것을 보이지 않는 원소로 뭉개버려,
# 파드 하나라도 ReplicaSet이 관리하는 한 `*ReplicaSet*`이 매치된다.
# 그 때문에 손으로 띄운 외부 파드가 눈에 띄지 않고 검사를 통과했다.
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "app=${APP} 레이블을 가진 파드가 하나도 없습니다" \
         "애플리케이션을 되돌리세요: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "${APP} 파드 중 어느 것도 ReplicaSet이 관리하지 않습니다 — 자가 치유가 일어나지 않습니다" \
         "파드를 손으로 띄운 것 같습니다(kubectl run). 삭제하고 ../01-deploy/rickroll.yaml을 적용하세요"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "app=${APP} 레이블을 외부 파드가 달고 있습니다: ${PODS_TOTAL}개 중 ${PODS_BY_RS}개만 ReplicaSet이 관리합니다" \
           "나머지는 로드 밸런싱에 포함되어 엉뚱한 응답을 반환합니다 — 찾으세요: kubectl get pods -l app=${APP} -o wide"
      evidence "파드 소유자" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "복제본을 ReplicaSet이 관리합니다 — Deployment → ReplicaSet → Pod 체인이 온전합니다"
    evidence "누가 누구의 소유자인지" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- 복제본 재생성의 흔적 ---------------------------------------------------
# 「파드가 죽었다」는 직접적인 증거는 클러스터가 보관하지 않는다. 간접 증거가 둘 있고, 각각으로 충분하다:
# 파드가 자기 Deployment보다 눈에 띄게 젊고, ReplicaSet 이벤트에 생성이 한 번보다 많다.
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "복제본이 애플리케이션보다 ${DELTA}초 젊습니다 — 이전 것은 제거되고 이것이 대신 생성됐다는 뜻입니다"
  else
    warn "복제본이 애플리케이션과 거의 동갑입니다(차이 ${DELTA}초)" \
         "랩 맨 마지막에 애플리케이션 전체를 복구했다면 정상입니다; 그렇지 않다면 파드 삭제 단계를 수행하지 않은 것입니다"
  fi
  evidence "객체의 나이" "deployment 생성: ${DEP_TS}
pod 생성:          ${POD_TS}
차이:              ${DELTA}초"
else
  warn "파드와 애플리케이션의 나이를 비교하지 못했습니다" \
       "PATH에 python3가 필요합니다; 랩 통과에는 영향이 없습니다"
fi

# 이벤트는 약 한 시간 정도 남아 있으므로, 이벤트가 없는 것은 실패가 아니라 참고 사항이다.
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "클러스터 이벤트에 복제본 생성이 ${CREATES}번 있습니다 — 자가 치유가 실제로 작동했습니다"
  evidence "복제본 생성 이벤트" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "클러스터 이벤트에 복제본 생성이 ${CREATES}번만 보입니다" \
       "이벤트는 약 한 시간 정도 보관되며 만료됐을 수 있습니다"
fi

# 두 징후 중 어느 하나만으로는 차단 요소가 아니다: 이벤트는 약 한 시간 정도 남고,
# 나이는 랩 마지막에 애플리케이션 전체를 정당하게 복구한 사람에게도 일치한다.
# 하지만 둘 다 없다면 — 복제본을 아예 삭제하지 않은 것이고, 랩을 하지 않은 것이다. 이 조합이 없으면
# 스크립트는 단 한 번의 삭제도 기다리지 않고 랩 1 직후에 「랩 통과」를 출력했다.
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "자가 치유의 흔적을 찾지 못했습니다: 복제본을 삭제하지 않았습니다" \
       "복제본을 삭제하세요: kubectl delete pod -l app=${APP} — 그리고 이벤트가 살아 있는 한 시간 이내에 검사를 실행하세요"
fi

# --- 서비스가 실제로 처리하는가 --------------------------------------------
# 본질적인 핵심 검증: 「객체가 존재한다」가 아니라 「Service를 통해 페이지가 오고
# 그 안에 살아 있는 복제본의 이름이 들어 있다」.
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP}이(가) 클러스터 내부에서 페이지를 반환하지 않았습니다" \
       "엔드포인트를 확인하세요: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "페이지는 제공되지만 복제본 이름이 그 안에 치환되지 않았습니다" \
       "ConfigMap rickroll-conf이 사라졌습니다: ../01-deploy/rickroll.yaml을 통째로 적용하세요"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "Service 응답에 복제본 이름이 없습니다" \
         "페이지가 우리 애플리케이션에서 오지 않았습니다 — kubectl get svc ${APP} -o yaml을 확인하세요"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service가 페이지를 제공하며, 살아 있는 복제본 ${SERVED}이(가) 처리했습니다"
    evidence "Service 응답(일부)" \
      "$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "복제본 ${SERVED}이(가) 페이지를 제공했지만, 클러스터에 그런 파드가 이미 없습니다" \
         "10초쯤 기다렸다가 검사를 다시 실행하세요 — 아마 지금 막 복제본이 바뀌던 중일 겁니다"
  fi
fi

# --- 다음 랩을 위한 준비 상태 ----------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "복제본 수가 하나로 되돌아왔습니다 — 랩 3은 깨끗한 상태에서 시작합니다"
else
  warn "현재 요청된 복제본 수: ${WANT}" \
       "랩 3 전에 하나로 되돌리세요: kubectl scale deployment ${APP} --replicas=1"
fi

finish
