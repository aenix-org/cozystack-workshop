#!/usr/bin/env bash
# 랩 14 검증: 관측 가능성이 실제로 동작하는지 확인.
#
# 「참가자가 그래프를 봤다」는 검증할 수 없고, 검증할 수 있는 척하는 것은 정직하지 않다.
# 그래서 그래프가 가능하려면 반드시 있어야 하는 것을 확인한다:
#   1) 메트릭 수집 에이전트가 클러스터에서 동작하고 있는지,
#   2) 수집한 것을 허공이 아니라 여러분의 테넌트로 보내고 있는지,
#   3) 로그 수집도 동작하는지 — 이것이 없으면 랩의 절반이 무의미하다,
#   4) 그래프에서 찾을 수 있는 랩 3의 부하 흔적이 클러스터에 있는지.

LAB_NAME="14-observability"
LAB_TITLE="랩 14 · 관측 가능성: 그래프에서 나의 급증 찾기"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- 수집 namespace --------------------------------------------------------
# Namespace 자체는 아무것도 증명하지 못한다: 플랫폼은 같은 곳에 metrics-server도 두는데,
# 이것은 etcd가 있는 모든 클러스터에 설치되며 애드온과 무관하다. 그 존재를 확인하는 것은
# 「클러스터 접근 불가」와 「수집이 꺼짐」을 구분하기 위함일 뿐이다.
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "클러스터에 namespace ${MON_NS}가 없습니다 — 클러스터가 예상과 다르게 응답했습니다" \
       "애드온을 켜세요: 대시보드 -> Kubernetes -> lab -> 편집 -> Addons -> Monitoring agents. 유의: 기록은 지금 이 순간부터만 생깁니다"
  finish
  exit $?
fi

# --- 메트릭 에이전트 -----------------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "메트릭 수집 에이전트가 동작 중입니다 (vmagent 파드: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "메트릭 수집 에이전트는 있지만 동작하지 않습니다 (${VMAGENT_TOTAL}개 중 ${VMAGENT_RUNNING}개만 Running)" \
       "원인을 확인하세요: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "${MON_NS}에 vmagent 파드가 하나도 없습니다 — Monitoring agents 애드온이 꺼져 있습니다" \
       "켜세요: 대시보드 -> Kubernetes -> lab -> 편집 -> Addons -> Monitoring agents. 기록은 지금 이 순간부터만 쌓이며, 과거는 되돌릴 수 없습니다"
fi
evidence "${MON_NS}의 수집 파드" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- 메트릭이 정확히 어디로 가는가 -------------------------------------------
# 허공에 쓰는 동작 중인 에이전트는 정상 동작하는 것과 똑같아 보인다.
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "메트릭이 테넌트로 전송됩니다${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "메트릭이 테넌트 주소처럼 보이지 않는 곳으로 전송됩니다" \
           "진행자가 공용 저장소를 설정했다면 정상일 수 있습니다; 주소는 증거에 있습니다"
      ;;
  esac
  evidence "메트릭이 전송되는 곳" "$RW_URL"
else
  warn "메트릭 전송 주소를 읽지 못했습니다" \
       "직접 확인하세요: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- 로그 수집 -------------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "로그 수집이 모든 노드에서 동작합니다 (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "로그 수집이 모든 노드에서 실행되고 있지 않습니다 (${FB_DESIRED}개 중 ${FB_READY:-0}개)" \
       "확인하세요: kubectl -n ${MON_NS} get pods | grep fluent-bit — 이것이 없으면 로그 검색 단계가 동작하지 않습니다"
else
  warn "fluent-bit 로그 수집기를 찾지 못했습니다" \
       "Grafana의 vlogs-generic 소스가 비어 있게 됩니다; 로그 검색 단계를 완료할 수 없습니다"
fi

# --- 그래프에서 찾을 것이 있는가 -----------------------------------------
# 메트릭이 완벽히 수집되더라도 부하가 없었다면 찾을 것이 없다.
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "부하의 흔적이 있습니다: 오토스케일링이 작동했습니다 (마지막 ${LAST_SCALE})"
    evidence "오토스케일링 상태" "$(kubectl get hpa rickroll 2>/dev/null)
마지막 작동: ${LAST_SCALE}
현재 복제본: ${CUR:-?}, 필요: ${DES:-?}"
  else
    warn "오토스케일링은 구성되어 있지만 한 번도 작동하지 않았습니다" \
         "복제본 증가 계단을 찾을 수 없습니다; fortio 생성기로 랩 3의 부하를 다시 실행하세요"
  fi
else
  warn "클러스터에 rickroll라는 이름의 HorizontalPodAutoscaler가 없습니다" \
       "이 랩의 그래프 단계는 랩 3에 의존합니다; 그것 없이는 CPU 급증만 찾을 수 있고 계단은 찾을 수 없습니다"
fi

# --- 애플리케이션 자체의 메트릭 ----------------------------------------------
# 간접적이지만 본질적: 애플리케이션 파드가 살아 있으면 그 소비량이 그래프에 나타난다.
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "애플리케이션 파드가 제자리에 있습니다 (${APP_PODS}개) — 그 소비량이 그래프에 보입니다"
  evidence "애플리케이션 파드" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "클러스터에 rickroll 애플리케이션 파드가 없습니다" \
       "랩 3 당시의 과거 메트릭은 그대로 보존되어 있습니다; Grafana에서 해당 시간 범위만 설정하면 됩니다"
fi

# --- Grafana를 어디서 찾는가 -----------------------------------------------
# 검증이 아니라 도움: Grafana 주소는 참가자들이 가장 오래 찾는 것이다.
: "${COZY_KUBECONFIG:=$HOME/.kube/config}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "여러분의 메트릭용 Grafana: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
테넌트 ${TNS}의 메트릭은 namespace ${MON_TARGET}에 저장됩니다"
    else
      warn "여러분 테넌트의 모니터링은 ${MON_TARGET}에 있지만 Grafana 주소를 읽지 못했습니다" \
           "${MON_TARGET}가 여러분의 namespace가 아니라면 Grafana는 공용입니다: 진행자에게 주소를 물어보세요"
      evidence "테넌트 모니터링" "모니터링이 있는 namespace: ${MON_TARGET}"
    fi
  else
    warn "테넌트 ${TNS}의 메트릭이 어디로 가는지 확인하지 못했습니다" \
         "Grafana 주소를 진행자에게 묻거나 대시보드에서 찾으세요: Monitoring 애플리케이션 -> Ingress"
  fi
else
  warn "Grafana 주소를 확인하지 못했습니다" \
       "COZY_TENANT와 COZY_KUBECONFIG를 설정하면 스크립트가 스스로 찾습니다; 랩 통과에는 영향이 없습니다"
fi

finish
