#!/usr/bin/env bash
# 랩 3 검사: 오토스케일링.
#
# "hpa.yaml이 적용되었다"가 아니라, 메커니즘이 살아 있고 결정을 내릴 수 있는지를 검증한다:
#   - 컨테이너에 requests.cpu가 있어야 한다. 없으면 퍼센트를 계산할 기준이 없다;
#   - HPA가 존재하고 정확히 우리 Deployment를 대상으로 삼는다;
#   - 범위가 의미 있게 설정되어 있다 (maxReplicas가 1보다 커야 하며, 그렇지 않으면 늘어날 여지가 없다);
#   - 메트릭이 실제로 수집되고 있다: 상태에 <unknown>이 아니라 숫자가 들어 있다;
#   - 스케일링이 이미 발동했다. 즉 부하가 실제로 가해졌다.
#
# 스크립트는 아무것도 바꾸지 않는다. 일회용 파드는 Fortio가 클러스터 내부에서
# 응답하는지 확인하기 위해서만 띄워지며, 스스로를 제거한다.
#
# 가상머신에서, 이 랩 폴더에서, 학습용 클러스터 `lab`에 접근하여 실행한다
# (관리 클러스터의 테넌트가 아님):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# 여기서 COZY_TENANT 변수는 필요 없다: 랩 전체가 `lab` 클러스터 내부에서 진행된다.
#
# 정리 전에 실행할 것. 일부 검사는 이미 일어난 증가의 흔적에 의존하며,
# 그 흔적은 HPA 객체와 함께 존재한다: 그것을 지우면 증명할 것이 아무것도 남지 않는다.

# 보고서 헤더와 스크립트 옆의 파일명 report-<랩>-<날짜>.md에 들어간다.
LAB_NAME="03-scale"
LAB_TITLE="랩 3 · 부하와 오토스케일링"
# 공용 라이브러리: ok / fail / warn / evidence / finish, 클러스터 내부 쿼리,
# 보고서 기록. 경로는 현재 디렉터리가 아니라 스크립트 자체 위치를 기준으로 계산한다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG 없이 kubectl은 가상머신에서 클러스터를 찾다가 모든 것을 하나의 오류로 실패시키는데,
# 그 오류에서 진짜 원인은 알아볼 수 없다. 곧바로 멈춘다.
need_kubeconfig

# 이름을 변수로 빼낸 이유는, 이 랩에서 애플리케이션 이름과 HPA 이름이 일치하는 것이
# 같은 이름을 실수로 두 번 쓴 것처럼 보이지 않게 하기 위함이다.
APP=rickroll
HPA=rickroll

# --- 스케일링 대상이 제자리에 있는지 ----------------------------------------
# 랩 1의 애플리케이션 — HPA가 관리하는 대상이다. 이것이 없으면 이후의 모든
# 검사가 연쇄적으로 실패하고 참가자는 하나의 명확한 오류 대신 열 개의 오류를 받게 되므로,
# 여기가 스크립트가 조기 종료하는 유일한 지점이다.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "애플리케이션 ${APP}이(가) 클러스터에 없음 — 스케일링할 대상이 없음" \
       "배포하세요: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "애플리케이션 ${APP}이(가) 제자리에 있음"

# --- requests.cpu: 없으면 HPA가 퍼센트를 계산하지 못한다 -------------------
# "HPA가 동작하지 않는다"의 가장 흔한 원인이며, 매니페스트에서는 보이지 않는다:
# 객체는 정상적으로 생성되지만 TARGETS는 영원히 <unknown>으로 남는다.
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "컨테이너에 requests.cpu = ${REQ_CPU}이(가) 설정됨 — 퍼센트를 계산할 기준이 있음"
  evidence "컨테이너 리소스" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-설정 안 됨}"
else
  fail "컨테이너 ${APP}에 requests.cpu가 설정되지 않음" \
       "Utilization 기반 HPA는 이것 없이 동작하지 않음; ../01-deploy/rickroll.yaml을 다시 적용하세요"
fi

# --- HPA 자체 -------------------------------------------------------------
# 객체의 존재뿐 아니라 무엇을 대상으로 삼는지도 검사한다. scaleTargetRef에 오타가 있는
# HPA는 정상적으로 생성되어 목록에서는 동작하는 것처럼 보이지만, 랩 내내
# 존재하지 않는 애플리케이션을 관리한다.
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "클러스터에 ${HPA} 이름을 가진 HorizontalPodAutoscaler가 없음" \
       "적용하세요: kubectl apply -f hpa.yaml (검사는 정리 전에 실행)"
  evidence "오토스케일링 관련으로 존재하는 것" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA}이(가) Deployment/${APP}을(를) 대상으로 함"
else
  fail "HPA ${HPA}이(가) Deployment/${APP}이 아니라 ${TARGET_KIND}/${TARGET_NAME} 객체를 관리함" \
       "hpa.yaml의 scaleTargetRef를 고치고 다시 적용하세요"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "범위가 설정됨: ${MINR}개부터 ${MAXR}개 복제본까지 — 늘어날 여지가 있음"
else
  fail "범위 상한이 ${MAXR:-설정 안 됨}임 — 늘어날 여지가 없음" \
       "hpa.yaml에는 maxReplicas가 1보다 커야 함"
fi

# --- 메트릭 목표 ----------------------------------------------------------
# 여기서는 fail이 아니라 warn이다: AverageValue 방식(임계값을 밀리코어로 지정)도 동작하며,
# 랩은 둘 중 하나만 다룬다. 그것으로 실패시키는 것은 사실이 아니다.
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "임계값이 설정됨: requests.cpu의 ${TGT_VAL}% (${REQ_CPU:-?})"
else
  warn "임계값이 requests 대비 퍼센트로 설정되지 않음 (타입: ${TGT_TYPE:-없음})" \
       "랩은 Utilization 방식을 다룸; 동작에는 영향 없음"
fi

# --- 핵심: 메트릭이 실제로 수집되고 있는지 ---------------------------------
# 바로 여기서 "객체 생성됨"과 "메커니즘 동작함"의 차이가 드러난다.
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "메트릭이 수집되고 있음: 현재 부하는 requests의 ${CUR_UTIL}%, HPA가 결정을 내리고 있음"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA가 결정을 내리고 있음 (ScalingActive=True), 현재 메트릭 값은 아직 보고되지 않음"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA가 메트릭을 받지 못함 — TARGETS에 <unknown>이 표시되고, 결정할 근거가 없음" \
       "apply 후 처음 2분간은 정상이니 기다렸다가 다시 시도하세요; 그래도 안 되면 — kubectl top pods 및 kubectl describe hpa ${HPA}"
  evidence "HPA가 활성화되지 않은 이유" "${REASON:-상태에 원인이 명시되지 않음}"
fi

evidence "HPA 상태" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server가 직접 응답하는지 -------------------------------------
# 앞의 검사를 반대쪽에서 중복 확인하며, 서로 다른 두 고장을 구분한다:
# "클러스터 전체에 메트릭이 없음"과 "메트릭은 있지만 HPA가 도달하지 못함".
# 전자는 클러스터 관리자가, 후자는 참가자가 자신의 매니페스트에서 고친다.
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top`은 파드가 없을 때 "No resources found"를 출력하고 0을 반환한다 —
# 명시적인 빈 값 검사 없이는 메트릭이 전혀 없는 곳에서도 초록불이 켜졌다.
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top이 파드 소비량을 보고하지 않음" \
       "클러스터에 동작 중인 metrics-server가 없음 — 그것 없이는 CPU 기반 오토스케일링이 불가능"
  evidence "kubectl top 응답" "$TOP"
else
  ok "metrics-server가 ${APP} 파드의 소비량을 보고함"
  evidence "복제본 소비량" "$TOP"
fi

# --- 스케일링이 실제로 발동했는지 -----------------------------------------
# lastScaleTime은 HPA 자체와 같은 기간 동안 유지되므로, 이 검사는
# 클러스터 이벤트가 만료되었는지 여부에 의존하지 않는다.
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# 타임스탬프 하나만으로는 부족하다: 그것은 복제본 축소 때도 설정되므로, 즉
# 복제본을 손으로 늘린 뒤 HPA가 여분을 제거하도록 둔 경우에도 나타난다. 우리가 찾는 것은
# 정확히 부하에 의한 증가 — 임계값 초과 이벤트다.
#
# 반대로: 타임스탬프 자체가 항상 남는 것은 아니다. 한 시간 전에 부하를 가한 클러스터에서는
# lastScaleTime이 비어 있는데 이벤트는 아직 살아 있을 수 있으므로 — 이벤트를
# 먼저 검사한다. 그러지 않으면 완료된 랩이 잘못 실패한다.
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA가 부하 때문에 복제본 수를 늘림 — 임계값 초과 이벤트가 제자리에 있음"
  evidence "스케일링" "증가 이벤트: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-없음}
currentReplicas: ${CUR_REPL:-알 수 없음}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA가 복제본 수를 변경함 (마지막: ${LAST_SCALE})"
  evidence "스케일링 타임스탬프" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-알 수 없음}"
else
  fail "오토스케일링 동작의 흔적이 없음" \
       "Fortio에서 부하를 가하세요: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: 랩 4에서 필요함 ----------------------------------------------
# 랩 3 자체와는 이제 관련이 없으므로 fail이 아니라 warn이다. 요점은 참가자가
# 생성기가 사라진 것을 부하를 걸어 롤아웃하는 도중이 아니라 여기서 알게 하는 것이다.
# 그때 멈추고 배포하는 것은 곤란하기 때문이다.
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "Fortio 부하 생성기가 동작하며 클러스터 내부에서 응답함"
  else
    warn "Fortio는 배포되었으나 웹 인터페이스가 응답하지 않음" \
         "확인하세요: kubectl rollout status deployment/fortio 및 kubectl logs deploy/fortio"
  fi
else
  warn "클러스터에 Fortio가 없음" \
       "랩 4를 할 예정이라면 거기서 필요함: kubectl apply -f fortio.yaml"
fi

finish
