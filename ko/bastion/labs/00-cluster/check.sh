#!/usr/bin/env bash
# 랩 0 점검: 학습용 클러스터가 올라왔고 여러분이 접속했는지 확인합니다.
#
# "객체가 생성됨"이 아니라 클러스터가 실질적으로 동작하는지를 점검합니다:
#   1) lab 클러스터가 여러분의 접속 파일로 응답하는지(KUBECONFIG=~/lab.kubeconfig),
#   2) 최소 한 개의 노드가 Ready 상태인지,
#   3) 노드에 앞으로 실행할 애플리케이션을 위한 여유 리소스가 있는지.
# COZY_TENANT가 설정되어 있으면 — 추가로 관리 클러스터에서 Kubernetes/lab 주문이
# Ready에 도달했는지, 그리고 메트릭 수집이 켜져 있는지(없으면 랩 14가 비어 있음) 확인합니다.
#
# 가상 머신에서, 이 랩 폴더에서 실행합니다:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # 테넌트 측 점검용 (선택 사항)
#     cd labs/00-cluster && ./check.sh
#
# 스크립트는 읽기만 합니다 — 클러스터 상태를 변경하지 않습니다.
LAB_NAME="00-cluster"
LAB_TITLE="랩 0 · 나만의 Kubernetes 클러스터"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# lab 클러스터 자체에 접근하지 못하면 점검할 것이 없습니다 — 이것이 랩의 핵심
# 증거입니다. need_kubeconfig는 KUBECONFIG가 설정되지 않았거나 클러스터가 응답하지
# 않으면 명확한 힌트와 함께 스크립트를 멈춥니다.
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) lab 클러스터 접속 ----------------------------------------------------
# need_kubeconfig가 이미 서버가 응답함을 확인했습니다. 이를 별도 결과로
# 기록하고 서버 버전을 보고서에 넣습니다.
KVER="$(server_version)"
ok "lab 클러스터가 응답합니다 — 접속 파일이 정상 동작합니다"
[ -n "$KVER" ] && evidence "lab 클러스터 서버 버전" "$KVER"

# --- 2) 노드 가동 상태 -------------------------------------------------------
# Ready 상태인 노드가 몇 개인지 셉니다. 목록이 비어 있으면 클러스터는
# 올라왔지만 md0 노드 그룹이 아직 배포 중이라는 뜻입니다.
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "노드 가동 상태: ${TOTAL_NODES}개 중 ${READY_NODES}개가 Ready 상태"
  [ -n "$NODES_WIDE" ] && evidence "클러스터 노드" "$NODES_WIDE"
else
  fail "Ready 상태인 노드가 하나도 없습니다 (전체 노드 수: ${TOTAL_NODES:-0})" \
       "md0 노드 그룹이 배포될 때까지 몇 분 기다리세요; 상태는 lab 애플리케이션의 대시보드에서, 또는: kubectl get nodes"
  evidence "클러스터 노드" "${NODES_WIDE:-노드 없음}"
fi

# --- 3) 앞으로 실행할 애플리케이션을 위한 공간이 있는가 ----------------------
# 첫 번째 노드의 allocatable: 리소스가 없으면 이후 아무것도 실행되지 않습니다.
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "노드에 애플리케이션용 리소스가 있습니다 (노드당: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "노드 여유 리소스 (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "노드 여유 리소스를 읽지 못했습니다" \
       "보통 일시적입니다 — 1분 후 다시 시도하세요"
fi

# --- 4) 관리 클러스터 측 (테넌트가 설정된 경우) ------------------------------
# 랩 0에는 필수가 아닙니다: 위에서 클러스터 자체에 접속한 것으로 이미 모든 것이 증명되었습니다.
# 하지만 테넌트 접근이 있다면 — 주문을 확인하고 메트릭 수집을 점검합니다.
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "테넌트 접근 ${COZY_KUBECONFIG}를 찾을 수 없습니다 — 관리 클러스터의 클러스터 주문은 점검하지 않았습니다" \
         "랩 실패가 아닙니다; 경로는 다음으로 지정합니다: export COZY_KUBECONFIG=~/.kube/config"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "관리 클러스터에서 Kubernetes/lab 주문이 Ready 상태입니다"
    elif [ -n "$LAB_READY" ]; then
      warn "Kubernetes/lab 주문이 아직 Ready가 아닙니다 (현재: ${LAB_READY})" \
           "클러스터는 이미 응답하며, 플랫폼이 아직 원하는 상태로 조정 중입니다; 확인: kubectl --kubeconfig ~/.kube/config -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "테넌트 ${TENANT_NS}에서 Kubernetes/lab 주문을 찾지 못했습니다" \
           "클러스터 이름을 다르게 지었다면 — 본인의 이름으로 바꾸세요; 또는 테넌트에서의 역할이 이 명령을 허용하지 않습니다 (랩 오류 아님)"
    fi
    # 메트릭 수집: 랩 14는 활성화된 시점부터 쌓이는 데이터에 의존합니다.
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "메트릭 수집이 켜져 있습니다 (랩 14에서 필요)"
    elif [ -n "$LAB_READY" ]; then
      warn "메트릭 수집이 꺼져 있습니다 — 랩 14가 데이터 없이 남습니다" \
           "켜기: 대시보드 → lab 애플리케이션 → Addons → Monitoring agents (지난 메트릭은 소급 생성되지 않습니다)"
    fi
  fi
else
  warn "COZY_TENANT가 설정되지 않았습니다 — 관리 클러스터 측 점검을 건너뜁니다" \
       "랩 0에는 필수가 아닙니다; 켜려면: export COZY_TENANT=workshopXX"
fi

finish
