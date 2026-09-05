#!/usr/bin/env bash
# 랩 1 검증: 애플리케이션이 배포되었고 실질적으로 동작한다.
#
# 여기서 "실질적으로"란: 페이지가 실제로 HTTP로 제공되고, 그 안에 파드 이름이
# 치환되어 있으며, 그 이름이 실제로 실행 중인 복제본의 이름과 일치한다는 뜻이다.
# Deployment 객체의 존재 여부를 확인하는 것은 무의미하다 — 객체는 존재하면서도 동작하지 않을 수 있다.
#
# VM에서, 이 랩의 폴더에서, 학습용 클러스터 `lab`에 대한 접근으로 실행한다
# (관리 클러스터의 테넌트가 아니라):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# 여기서 COZY_TENANT 변수는 필요 없다: 랩 전체가 `lab` 클러스터 안에서 진행된다.
#
# 스크립트는 클러스터에서 아무것도 변경하지 않는다 — 읽기와 HTTP 요청만 보낸다.
# 정리 작업 전에 실행하라: 애플리케이션을 삭제한 뒤에는 확인할 것이 없다.

# 이 두 변수는 lib.sh가 가져간다 — 보고서 헤더와, 스크립트가 자기 옆에 기록하는
# report-<랩>-<날짜>.md 파일 이름에 들어간다.
LAB_NAME="01-deploy"
LAB_TITLE="랩 1 · 첫 애플리케이션"
# 공용 검증 라이브러리: 여기서 ok / fail / warn / evidence / finish,
# 클러스터 내부에서의 페이지 요청, 보고서 기록이 온다. 경로는 스크립트 자신이
# 위치한 곳을 기준으로 계산되므로, 어느 디렉터리에서 실행해도 동일하게 동작한다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG가 설정되지 않았으면 즉시 중단한다. 없으면 kubectl은 VM 자체에서
# 클러스터를 찾으려 하고, 찾지 못한 채 모든 검증을 똑같은 오류로 연달아 실패시켜
# 진짜 원인을 가려 버린다.
need_kubeconfig

# --- 애플리케이션 객체 ------------------------------------------------------
# 첫 번째 방어선: 애플리케이션이 실제로 구성되었고 최소한 한 복제본이 준비 상태에 도달했다.
# Deployment의 단순한 존재가 아니라 .status.readyReplicas를 본다: 객체는
# 즉시, 그리고 항상 성공적으로 생성되지만, 준비됨은 복제본이 올라와서
# 준비성 프로브를 통과하고 응답할 수 있다는 것을 의미한다.
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # 특수한 경우: 객체는 있지만 요청된 복제본이 0개다.
    # "준비된 복제본이 없음 (0개 필요)"라는 메시지는 말이 되지 않는다.
    fail "애플리케이션이 중지됨 — 요청된 복제본이 0개" \
         "복제본을 되살리세요: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "애플리케이션 배포됨, 준비된 복제본 ${DESIRED}개 중 ${READY}개"
    # 멈춘 롤아웃은 서비스를 다운시키지 않는다: 기존 복제본이 계속 동작하고
    # readyReplicas는 1로 유지된다. 이 검증이 없으면 참가자는 초록색 체크와
    # ErrImagePull에 영원히 멈춘 디플로이먼트를 안고 떠난다.
    # ProgressDeadlineExceeded만이 아니라 복제본 자체를 본다: 데드라인은
    # 10분 뒤에 발동하는데 스크립트는 곧바로 실행된다. 그동안 기존 복제본은
    # 동작하고 readyReplicas는 1로 유지되며, 이 검증이 없으면 참가자는 초록색
    # 체크와 ImagePullBackOff에 멈춘 디플로이먼트를 안고 떠난다.
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "롤아웃이 멈춤: 새 복제본이 올라오지 않고, 기존 것만 동작 중" \
           "kubectl get pods -l app=rickroll 를 보세요 — 보통 이미지가 받아지지 않은 것입니다; 정상 상태로 되돌리기: kubectl apply -f rickroll.yaml"
      evidence "시작되지 않는 복제본" "${STUCK:-원인은 Deployment 상태에: $PROG_REASON}"
    fi
  else
    fail "애플리케이션은 생성되었지만 준비된 복제본이 하나도 없음 (${DESIRED}개 필요)" \
         "kubectl get pods -l app=rickroll 와 kubectl describe deployment rickroll 를 보세요"
    evidence "파드 상태" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "rickroll 이라는 이름의 Deployment를 찾을 수 없음" \
       "매니페스트를 적용하세요: kubectl apply -f rickroll.yaml"
fi

# --- 설정과 페이지 ---------------------------------------------------------
# 두 ConfigMap 모두 애플리케이션과 같은 파일로 생성되므로, 애플리케이션과 함께
# 또는 수동 삭제로만 사라질 수 있다. 페이지가 깨졌을 때 참가자가 정확히 무엇이
# 빠졌는지 바로 볼 수 있도록 이들을 따로 검증한다: rickroll-conf 없이는 nginx가
# 파드 이름을 치환하지 못하고, rickroll-page-v1 없이는 랩 4에서 두 번째 버전을
# 비교할 대상도, 롤백할 곳도 없다.
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "설정이 제자리에 있음: ConfigMap ${cm}"
  else
    fail "ConfigMap ${cm} 를 찾을 수 없음" \
         "이것은 같은 파일로 생성됩니다: kubectl apply -f rickroll.yaml"
  fi
done

# --- 고정 주소 -------------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # 엔드포인트가 없는 Service는 전형적이고 눈에 띄지 않는 고장이다: 객체는 있지만
  # 파드의 레이블이 셀렉터와 일치하지 않아, 주소 뒤가 비어 있다.
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "고정 주소가 동작함, 그 뒤의 복제본: ${EPS_N}"
    evidence "서비스 뒤의 주소" "$EPS"
  else
    fail "Service rickroll 는 있지만 그 뒤에 복제본이 하나도 없음" \
         "보통 파드 레이블이 서비스 셀렉터와 일치하지 않는 것이 원인입니다 — app: rickroll 을 확인하세요"
  fi
else
  fail "rickroll 이라는 이름의 Service를 찾을 수 없음" \
       "이것은 같은 파일로 생성됩니다: kubectl apply -f rickroll.yaml"
fi

# --- 핵심: 페이지가 실제로 제공된다 ----------------------------------------
# 이 검증을 위해 모든 것이 준비되었다. 앞선 검증들은 클러스터 안 객체가 올바르게
# 기술되어 있다는 것만 말한다; 이 검증은 사용자가 페이지를 받는다는 것을 말한다.
# 요청은 클러스터 내부에서, 일회용 파드로 나간다: 외부에서는 rickroll 주소가
# 존재하지 않으며, 여기서 port-forward는 클러스터가 아니라 당신의 VM을 검증하게 된다.
# 여러 번 요청한다: 서비스 뒤에 복제본이 여럿이면 단일 샘플이 치환된 복제본을
# 놓칠 수 있고, 검증이 남의 콘텐츠 위에서 초록색이 될 수 있다.
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# 마커는 페이지당 정확히 한 번만 나타나야 한다, 그렇지 않으면 응답 카운터가 거짓말을 한다:
# "Never Gonna Give You Up" 은 <title> 에도 <h1> 에도 있어서 중복을 일으켰다.
ANSWERS="$(printf '%s' "$BODY" | grep -c '요청을 처리한 Pod')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "애플리케이션이 HTTP로 응답하고 자신의 페이지를 제공함 (${ANSWERS}개 요청 확인됨)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "서비스 뒤에서 당신의 애플리케이션만 응답하는 것이 아님: 자신의 페이지가 ${TOTAL_LINES}번 중 ${ANSWERS}번 돌아옴" \
       "다른 누군가가 app=rickroll 레이블을 달고 있습니다 — kubectl get pods -l app=rickroll 를 보고 불필요한 것을 제거하세요"
else
  fail "애플리케이션이 예상한 페이지를 제공하지 않음" \
       "수동으로 확인하세요: kubectl port-forward svc/rickroll 8080:80, 그다음 http://localhost:8080 을 여세요"
  evidence "페이지 대신 돌아온 것" "$(printf '%s' "$BODY" | head -20)"
fi

# --- 파드 이름 치환 --------------------------------------------------------
# 이것이 랩이 만들어진 이유다: 페이지의 이름이 실제 파드와 일치해야 한다.
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# app=rickroll 레이블을 단 모든 것이 아니라, 애플리케이션의 ReplicaSet이 관리하는
# 파드를 가져온다. 그렇지 않으면 그런 레이블을 단 외부 파드가 "진짜" 목록에 들어가
# 자기 자신을 확인해 버린다 — 실제로 사칭 파드가 그렇게 검증을 통과했다.
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "외부 파드가 app=rickroll 레이블을 달고 있음 — 이들은 로드 밸런싱에 포함됩니다" \
       "불필요한 것을 제거하세요: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "애플리케이션 레이블을 단 외부 파드" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "페이지에 파드 이름이 없음" \
       "ConfigMap rickroll-conf 가 치환되었는지 확인하세요 — 그 안에 sub_filter '__POD__' '\$hostname' 라인이 있습니다"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "파드 이름이 치환되지 않음 — 페이지에 자리표시자 __POD__ 가 남아 있음" \
       "nginx가 sub_filter를 적용하지 않았습니다: 설정 볼륨이 /etc/nginx/conf.d 에 마운트되었는지 확인하세요"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "파드 이름이 치환되었고 실제로 실행 중인 복제본과 일치함: ${SERVED_BY}"
  evidence "요청을 처리한 주체" "$SERVED_BY"
  evidence "실행 중인 복제본" "$REAL_PODS"
else
  fail "페이지는 파드를 «${SERVED_BY}» 라고 부르지만, 클러스터에 그런 파드가 없음" \
       "요청과 검증 사이에 복제본이 재생성되었을 수 있습니다 — 스크립트를 다시 실행하세요"
fi

# --- 준비성 프로브가 구성됨 ------------------------------------------------
# 이것이 없으면 버전 롤아웃 랩에서 다운타임이 생기고, 참가자는 우리가 거짓말했다고 여긴다.
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "준비성 프로브가 구성됨 (${PROBE_PATH}) — 업데이트가 다운타임 없이 진행됩니다"
else
  warn "애플리케이션에 준비성 프로브가 없음" \
       "무중단 업데이트에 관한 랩 4는 그런 애플리케이션에서 오류를 냅니다 — rickroll.yaml 의 readinessProbe를 되돌리세요"
fi

finish
