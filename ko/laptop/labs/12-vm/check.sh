#!/usr/bin/env bash
# 랩 12 검증: 마이그레이션된 가상머신이 플랫폼의 ingress와 도메인을 통해 외부로 게시된다 —
# 컨테이너 애플리케이션과 정확히 똑같은 방식으로.
#
# "객체가 생성되었는지"가 아니라 실제로 동작하는지를 검증한다:
#   1) 테넌트 도메인 이름으로 HTTP 200이 오고 그것이 직원 명부 페이지인지,
#   2) 가상머신 자체가 실행 중인지(Ready),
#   3) 머신을 게시하는 Ingress가 제자리에 있는지.
# 첫 번째 항목이 핵심이다: 그것이 바로 명부가 외부에서 보인다는 증거다.
#
# 노트북에서, 이 랩 폴더에서 실행한다. 테넌트 접근 권한과 테넌트 번호가 필요하다:
#     export KUBECONFIG=~/.kube/workshop
#     export COZY_TENANT=workshopXX
#     cd labs/12-vm && ./check.sh
# 도메인 검증은 테넌트 접근 없이도 동작한다 — curl만 있으면 충분하다. 테넌트 접근이 없어도
# 스크립트는 실패하지 않는다: 테넌트 쪽 검증을 건너뛰고 그렇다고 알려준다.
#
# 스크립트는 아무것도 변경하지 않는다 — 읽고 HTTP 요청만 보낸다. 정리 작업 전에 실행하라:
# 머신을 삭제한 뒤에는 검증할 것이 남아 있지 않다.

# 이 두 변수는 lib.sh가 가져간다 — 보고서 헤더와 스크립트가 자기 옆에 놓는
# report-<랩>-<날짜>.md 파일 이름에 들어간다.
LAB_NAME="12-vm"
LAB_TITLE="랩 12 · 컨테이너 옆의 가상머신"
# 공통 검증 라이브러리: ok / fail / warn / evidence / finish 가 여기서 온다.
# 경로는 스크립트 자신이 위치한 곳을 기준으로 계산되므로, 어느 디렉터리에서 실행해도
# 동일하게 동작한다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 테넌트 번호는 필수다: 그것으로 namespace 이름과, 명부가 게시된 도메인 이름이 모두
# 만들어진다. 없으면 검증할 것이 없다.
need_tenant

# 우리가 검증하는 이름들. VM 은 머신에 대한 주문(ORDER), 즉 VMInstance 객체의 이름이다.
# `kubectl get vminstance` 도 이 이름으로 물어본다. 실제로 실행되는 인스턴스는 이름이
# 다르다: 플랫폼은 주문을 `vm-instance` 차트로 배포하고, 차트 이름이 릴리스 이름에
# 붙어서 vm-instance-spravochnik 가 된다.
VM=spravochnik
NS="tenant-${COZY_TENANT}"
# 진행자가 미리 Ingress를 통해 명부를 게시해 둔 도메인. 브라우저에서 여는 것과 같은 주소다.
HOST="spravochnik.${COZY_TENANT}.workshop.aenix.io"
URL="http://${HOST}"

# 테넌트 접근은 필수가 아니다: 도메인은 일반 curl로 검증한다. KUBECONFIG가 설정되어 있고
# 테넌트가 응답하면 — 머신 상태와 Ingress 검증을 추가한다.
TENANT_OK=0
if [ -n "${KUBECONFIG:-}" ] && kubectl -n "$NS" get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- 핵심: 명부가 도메인을 통해 외부에서 보인다 ---------------------------
# 응답 코드와 본문을 따로 가져온다: 코드는 "아직 ingress 뒤에 아무도 없음"(503)을
# "엉뚱한 곳으로 연결됨"(404)과 "도메인이 아예 없음"(000)과 구분해 주고, 본문은 응답하는
# 것이 임의의 대체 페이지가 아니라 바로 명부라는 것을 확인해 준다.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
BODY="$(curl -s --max-time 10 "$URL" 2>/dev/null)"

case "$CODE" in
  200)
    case "$BODY" in
      *"직원 명부"*)
        ok "명부 게시됨: ${URL} 이 200으로 응답하고 명부 페이지를 제공한다"
        evidence "도메인 응답" "요청: ${URL}
응답 코드: ${CODE}
$(printf '%s' "$BODY" | head -3)"
        ;;
      *)
        fail "${URL} 이 200을 반환하지만 명부 페이지가 아니다" \
             "도메인 뒤에서 다른 무언가가 응답하고 있다; 머신 내부 8080 포트에서 바로 명부가 수신 대기하는지 확인하라"
        ;;
    esac
    ;;
  503)
    fail "도메인 ${URL} 이 503으로 응답한다 — 아직 Ingress 뒤에 응답할 대상이 없다" \
         "머신이 아직 부팅 중이거나 8080의 명부 서비스가 올라오지 않았다; vminstance가 Ready가 될 때까지 기다리고 머신 콘솔을 들여다보라"
    ;;
  000)
    fail "도메인 ${URL} 이 전혀 응답하지 않는다" \
         "네트워크를 확인하라; 이 호스트의 Ingress는 진행자가 만든다 — 도메인이 아예 없으면 진행자에게 물어보라"
    ;;
  *)
    fail "도메인 ${URL} 이 200이 아니라 ${CODE} 로 응답한다" \
         "404는 Ingress가 엉뚱한 서비스로 연결됨을 뜻하고, 5xx는 백엔드가 응답할 준비가 안 됨을 뜻한다"
    ;;
esac

# --- 테넌트 쪽: 머신 자체와 그 게시 --------------------------
if [ "$TENANT_OK" -eq 0 ]; then
  warn "테넌트 쪽 검증을 건너뛴다: KUBECONFIG로 테넌트에 접근할 수 없다" \
       "테넌트 접근을 지정하라: export KUBECONFIG=~/.kube/workshop"
else
  # "객체가 존재하는지"가 아니라 Ready 조건을 물어본다: 머신 주문은 1초 만에 생성되지만
  # 게스트는 3~5분에 걸쳐 올라오고, 그동안 내내 머신은 존재하지만 명부는 아직 응답하지
  # 않는다.
  if ! kubectl -n "$NS" get vminstance "$VM" >/dev/null 2>&1; then
    fail "테넌트 ${NS} 에 가상머신 ${VM} 이 없다" \
         "대시보드에서 VM Disk와 VM Instance를 만들거나 staff-directory-vm.yaml 을 적용하라"
  else
    VM_READY="$(kubectl -n "$NS" get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "가상머신 ${VM} 이 실행 중이다"
    elif [ -n "$VM_READY" ]; then
      fail "가상머신 ${VM} 은 있지만 준비되지 않았다 (Ready=${VM_READY})" \
           "대시보드에서 머신 카드를 보라; 최초 부팅은 3-5분 걸린다"
    else
      warn "가상머신 ${VM} 은 존재하지만 상태를 읽을 수 없었다" \
           "대시보드에서 직접 눈으로 확인하라: 켜져 있어야 한다"
    fi
    evidence "테넌트의 가상머신들" "$(kubectl -n "$NS" get vminstance 2>/dev/null)"
  fi

  # Ingress는 참가자가 아니라 진행자가 만든다. 도메인이 이미 200으로 응답한다면 — 제자리에
  # 있는 것이다; 503/404일 때 게시가 아예 있는지 바로 보이도록 따로 검증한다.
  if kubectl -n "$NS" get ingress spravochnik >/dev/null 2>&1; then
    ok "Ingress spravochnik 이 제자리에 있다 — 명부가 테넌트에 게시되었다"
    evidence "테넌트 Ingress" "$(kubectl -n "$NS" get ingress spravochnik 2>/dev/null)"
  else
    warn "테넌트 ${NS} 에서 Ingress spravochnik 을 찾을 수 없다" \
         "이것은 진행자가 만든다; 도메인이 이미 200으로 응답한다면 걱정할 것 없고, 그렇지 않으면 진행자에게 문의하라"
  fi
fi

finish
