#!/usr/bin/env bash
# 랩 0 점검: 학습용 클러스터가 올라왔고 여러분이 거기에 연결되어 있다.
#
# 「객체가 생성됨」이 아니라, 클러스터가 실질적으로 동작하는지를 확인한다:
#   1) lab 클러스터가 여러분의 접속 파일로 응답한다 (KUBECONFIG=~/lab.kubeconfig),
#   2) 최소 한 개의 노드가 Ready 상태다,
#   3) 노드에 앞으로 쓸 애플리케이션을 위한 여유 리소스가 있다.
# COZY_TENANT가 설정되어 있으면 — 추가로 관리(management) 클러스터 쪽에서 Kubernetes/lab
# 주문이 Ready에 도달했는지, 메트릭 수집이 켜져 있는지(없으면 랩 14가 빈 채로 남는다) 본다.
#
# 가상 머신에서, 이 랩의 폴더에서 실행:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # 테넌트 쪽 점검용 (선택 사항)
#     cd labs/00-cluster && ./check.sh
#
# 스크립트는 읽기만 한다 — 클러스터 상태를 바꾸지 않는다.
LAB_NAME="00-cluster"
LAB_TITLE="랩 0 · 나만의 Kubernetes 클러스터"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# lab 클러스터 자체에 접근하지 못하면 점검할 것이 없다 — 이것이 바로 랩의 핵심
# 증거다. KUBECONFIG가 설정되지 않았거나 클러스터가 응답하지 않으면
# need_kubeconfig가 명확한 힌트와 함께 스크립트를 멈춘다.
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) lab 클러스터 연결 -----------------------------------------------------
# need_kubeconfig가 이미 서버 응답을 확인했다. 이것을 별도 결과로 기록하고
# 서버 버전을 보고서에 담는다.
KVER="$(server_version)"
ok "lab 클러스터가 응답한다 — 접속 파일이 정상이다"
[ -n "$KVER" ] && evidence "lab 클러스터 서버 버전" "$KVER"

# --- 2) 노드 가동 상태 -------------------------------------------------------
# Ready 상태인 노드 수를 센다. 목록이 비어 있으면 클러스터는 올라왔지만
# md0 노드 그룹이 아직 배포 중이라는 뜻이다.
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "노드 가동 중: ${TOTAL_NODES} 중 ${READY_NODES} 개가 Ready 상태"
  [ -n "$NODES_WIDE" ] && evidence "클러스터 노드" "$NODES_WIDE"
else
  fail "Ready 상태인 노드가 하나도 없다 (전체 노드 수: ${TOTAL_NODES:-0})" \
       "md0 노드 그룹이 배포될 때까지 몇 분 기다리세요; 상태는 lab 애플리케이션의 대시보드에서, 또는: kubectl get nodes"
  evidence "클러스터 노드" "${NODES_WIDE:-노드 없음}"
fi

# --- 3) 앞으로 쓸 애플리케이션을 위한 여유 공간이 있는가 ----------------------
# 첫 번째 노드의 allocatable: 리소스가 없으면 이후 아무것도 실행되지 않는다.
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "노드에 애플리케이션용 리소스가 있다 (노드 기준: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "노드 여유 리소스 (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "노드의 여유 리소스를 읽지 못했다" \
       "보통 일시적입니다 — 1분 뒤 다시 시도하세요"
fi

# --- 4) 관리 클러스터 쪽에서 (테넌트가 설정된 경우) --------------------------
# 랩 0에는 필수가 아니다: 위에서 클러스터 자체에 연결한 것으로 이미 모두 증명됐다.
# 다만 테넌트 접근이 있으면 — 주문을 확인하고 메트릭 수집을 점검한다.
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "테넌트 접근 ${COZY_KUBECONFIG} 을(를) 찾을 수 없다 — 관리 쪽 클러스터 주문은 점검하지 않았다" \
         "랩 실패는 아닙니다; 경로 지정: export COZY_KUBECONFIG=~/.kube/workshop"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "관리 클러스터에서 Kubernetes/lab 주문이 Ready 상태다"
    elif [ -n "$LAB_READY" ]; then
      warn "Kubernetes/lab 주문이 아직 Ready가 아니다 (현재: ${LAB_READY})" \
           "클러스터는 이미 응답합니다, 플랫폼이 아직 원하는 상태로 조정 중입니다; 확인: kubectl --kubeconfig ~/.kube/workshop -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "테넌트 ${TENANT_NS} 에서 Kubernetes/lab 주문을 찾지 못했다" \
           "클러스터를 다른 이름으로 지었다면 — 자신의 이름으로 바꾸세요; 또는 테넌트 내 역할이 이 명령을 허용하지 않습니다 (랩 오류 아님)"
    fi
    # 메트릭 수집: 랩 14는 켜진 시점부터 쌓이는 데이터에 의존한다.
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "메트릭 수집이 켜져 있다 (랩 14에서 필요함)"
    elif [ -n "$LAB_READY" ]; then
      warn "메트릭 수집이 꺼져 있다 — 랩 14가 데이터 없이 남는다" \
           "켜기: 대시보드 → lab 애플리케이션 → Addons → Monitoring agents (메트릭은 소급해서 생기지 않습니다)"
    fi
  fi
else
  warn "COZY_TENANT가 설정되지 않았다 — 관리 클러스터 쪽 점검은 건너뛴다" \
       "랩 0에는 필수가 아닙니다; 켜려면: export COZY_TENANT=workshopXX"
fi

finish
