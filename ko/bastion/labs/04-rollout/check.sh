#!/usr/bin/env bash
# 랩 4 검사: 새 버전 배포와 롤백.
#
# 입력한 명령이 아니라 실제 결과를 확인합니다:
#   - 애플리케이션 히스토리에 여러 리비전이 있다, 즉 버전을 실제로 바꿨다;
#   - 두 번째 버전의 ConfigMap이 첫 번째를 수정한 것이 아니라 별도 객체로 클러스터에 존재한다;
#   - 컨테이너에 readinessProbe가 있다 — 그것 없이는 무중단이 재현되지 않는다;
#   - 배포가 멈추지 않고 끝까지 완료되었다;
#   - Service가 제공하는 페이지가 spec이 참조하는 ConfigMap과 일치한다.
#     이는 "spec은 롤백했지만 파드는 재생성되지 않은" 경우를 잡아냅니다.
#
# 스크립트는 아무것도 바꾸지 않습니다. 일회성 파드는 클러스터 내부에서 페이지를
# 가져오기 위해서만 필요하며 스스로를 제거합니다.
#
# 가상머신에서, 이 랩 폴더에서, 학습 클러스터 `lab`에 대한 접근으로 실행합니다
# (관리 클러스터의 테넌트가 아님):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# 여기서 COZY_TENANT 변수는 필요 없습니다: 랩 전체가 `lab` 클러스터 안에서 진행됩니다.
#
# 정리 전에, 그리고 롤백이 끝난 후에 실행하세요: 리비전 히스토리는 Deployment와
# 함께 존재하며, 그것과 함께 사라집니다.

# 보고서 제목과, 스크립트 옆의 report-<랩>-<날짜>.md 파일 이름에 들어갑니다.
LAB_NAME="04-rollout"
LAB_TITLE="랩 4 · 새 버전 배포와 롤백"
# 공용 라이브러리: ok / fail / warn / evidence / finish, 클러스터 내부 요청,
# 보고서 기록. 경로는 현재 디렉터리가 아니라 스크립트 자신의 위치를 기준으로 계산됩니다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG 없이는 kubectl이 가상머신에서 클러스터를 찾다가 모든 것을 하나의 오류로
# 무너뜨리는데, 그 안에서는 진짜 원인을 알아볼 수 없습니다. 즉시 멈춥니다.
need_kubeconfig

APP=rickroll

# --- 애플리케이션이 존재하고 동작 상태로 만들어졌다 ------------------
# 애플리케이션이 없으면 확인할 것이 없으므로, 여기가 유일한 조기 종료 지점입니다.
# 이후로는 준비된 복제본 수뿐 아니라 Progressing 조건의 이유도 봅니다:
# NewReplicaSetAvailable은 배포가 완료되었음을 의미합니다. 준비된 복제본 수만으로는
# 부족합니다 — 업데이트가 멈춘 경우 옛 버전이 돌아가고, 카운터는 필요한 수를
# 보여주지만 새 복제본은 한 번도 올라오지 못한 상태일 수 있습니다.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "애플리케이션 ${APP}이(가) 클러스터에 없습니다" \
       "배포하세요: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "배포가 끝까지 완료되었습니다: 준비된 복제본 ${WANT}개 중 ${HAVE}개"
else
  fail "애플리케이션이 완료 상태가 아닙니다 (${WANT}개 중 ${HAVE}개 준비됨, 이유: ${PROG_REASON:-없음})" \
       "배포가 멈췄다면 롤백으로 빠져나오세요: kubectl rollout undo deployment/${APP}"
fi
evidence "애플리케이션 상태" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: 무중단의 대가 -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "컨테이너에 readinessProbe가 있습니다 (${PROBE}) — 복제본 교체는 준비된 후에만 진행됩니다"
else
  fail "컨테이너에 readinessProbe가 없습니다" \
       "그것 없이는 클러스터가 준비되지 않은 복제본으로 트래픽을 보냅니다; ../01-deploy/rickroll.yaml을 적용하세요"
fi

# --- 버전을 별도 객체로 만들었다 --------------------------------------
# 페이지의 두 버전 모두 클러스터에 두 개의 별도 ConfigMap으로 존재해야 합니다.
# 대신 rickroll-page-v1을 제자리에서 수정한 사람은 화면에서 새 페이지를 보고
# 랩을 끝냈다고 판단하겠지만 — 롤백할 곳이 없으며,
# 복제본 교체도 리비전 히스토리 기록도 전혀 일어나지 않습니다.
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2가 클러스터에 별도 객체로 존재합니다"
else
  fail "클러스터에 ConfigMap rickroll-page-v2가 없습니다" \
       "적용하세요: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "페이지의 첫 번째 버전도 보존되어 있습니다 — 롤백할 곳이 있습니다"
else
  warn "클러스터에서 ConfigMap rickroll-page-v1을 찾을 수 없습니다" \
       "그것 없이 첫 번째 버전으로 롤백해도 파드가 올라오지 않습니다: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- 리비전 히스토리 -------------------------------------------------------
# 히스토리의 줄 수가 아니라 마지막 리비전의 번호를 봅니다. 롤백은 새 ReplicaSet을
# 추가하지 않고 — 옛것을 재사용하며 그 번호를 올립니다.
# 따라서 롤백 후에도 히스토리의 줄 수는 그대로이고 번호만 커집니다.
#   1 — spec을 한 번도 바꾸지 않았다
#   2 — 버전을 전환했다
#   3 이상 — 전환했다가 되돌렸다
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "애플리케이션의 마지막 리비전은 ${REV_MAX}입니다: 버전을 전환했다가 되돌렸습니다"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "마지막 리비전은 2입니다: 배포는 되었으나 롤백은 아직입니다" \
       "첫 번째 버전을 복원하세요: kubectl rollout undo deployment/${APP}"
else
  fail "마지막 리비전은 ${REV_MAX}입니다: 애플리케이션 spec을 한 번도 바꾸지 않았습니다" \
       "랩의 패치로 볼륨을 두 번째 버전으로 전환한 다음 롤백하세요"
fi
evidence "리비전 히스토리" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- spec이 어느 버전을 가리키는가 --------------------------------------
# 랩의 패치는 볼륨을 인덱스로 지정하지만, 우리는 볼륨을 page라는 이름으로 찾습니다.
# 바로 그 차이가 여기서 잡힙니다: 패치가 잘못된 리스트 요소로 갔다면 page 이름은
# 이전 ConfigMap을 가리키거나 사라지고, 참가자는 이상한 nginx 오류가 아니라
# 말로 그것을 알게 됩니다.
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "애플리케이션 spec이 페이지의 첫 번째 버전으로 롤백되었습니다"
    ;;
  rickroll-page-v2)
    warn "애플리케이션 spec이 페이지의 두 번째 버전을 가리킵니다" \
         "랩은 롤백으로 끝납니다; 의도한 것이라면 문제없지만, 아니라면: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "spec에 page라는 이름의 볼륨이 없습니다" \
         "패치가 엉뚱한 곳에 들어간 것 같습니다 (인덱스로 지정!); ../01-deploy/rickroll.yaml을 다시 적용하세요"
    ;;
  *)
    fail "볼륨 page가 랩이 만들지 않은 ConfigMap ${VOL_CM}을(를) 가리킵니다" \
         "롤백하세요: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- 클라이언트에게 실제로 무엇이 제공되는가 ------------------------------------
# 가장 핵심적인 검사: spec과 사용자가 보는 것을 대조합니다.
# 여기서의 불일치는 파드가 새 spec으로 재생성되지 않았음을 의미합니다.
# 요청은 하나가 아니라 여덟 번. 서비스 뒤에는 복제본이 셋 있습니다; 배포가 완전히
# 수렴하지 않았다면 단일 요청은 3분의 1 확률로 맞는 버전에 걸려 불일치를 감춥니다.
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP}이(가) 클러스터 내부에서 페이지를 반환하지 않았습니다" \
       "엔드포인트를 확인하세요: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # 두 버전 모두 각자의 마커로 긍정적으로 판별합니다. "v2가 아니면 v1"이라는 분기는
  # 무엇이든 첫 번째 버전으로 셌습니다: 기본 nginx 페이지, 404, 남의 애플리케이션,
  # 쓰레기 — 확인된 바, 쓰레기에서도 스크립트가 "랩 통과"를 출력했습니다.
  if printf '%s' "$BODY" | grep -q '버전 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "서비스 주소에서 애플리케이션 페이지가 아닌 다른 것이 제공됩니다" \
         "응답에 아는 마커가 하나도 없습니다 — 원본을 복원하세요: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "페이지 대신 반환된 것" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "클라이언트에게 spec에 기록된 바로 그 버전이 제공됩니다 (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "spec은 ${VOL_CM}을(를) 가리키는데 클라이언트에게는 ${SERVED_VER}이(가) 제공됩니다" \
         "복제본이 새 spec으로 재생성되지 않았습니다: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "복제본 이름이 페이지에 치환되지 않습니다" \
         "ConfigMap rickroll-conf가 사라졌습니다: ../01-deploy/rickroll.yaml을 통째로 적용하세요"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "살아 있는 복제본 ${SERVED_POD}이(가) 페이지를 제공했습니다"
    else
      warn "페이지의 이름을 동작 중인 복제본과 대조하지 못했습니다" \
           "검사 중에 복제본이 바뀌었을 가능성이 큽니다 — 스크립트를 다시 실행하세요"
    fi
  fi

  evidence "제공된 페이지 (일부)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "요청을 처리한 Pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- 다음 랩을 위한 준비 상태 ------------------------------------------
# 이 랩은 교체를 하나씩 보이게 하려고 복제본을 셋으로 늘렸습니다. 남겨진 세 복제본은
# 아무것도 망가뜨리지 않으므로 — fail이 아니라 warn입니다 — 다만 학습 노드의 공간을
# 차지하는데, 이후 이웃 랩들이 그 공간을 감당하지 못하게 됩니다.
if [ "$WANT" = "1" ]; then
  ok "복제본 수가 하나로 되돌아왔습니다"
else
  warn "현재 요청된 복제본 수: ${WANT}" \
       "랩이 끝나면 하나로 되돌리는 것이 좋습니다: kubectl scale deployment ${APP} --replicas=1"
fi

finish
