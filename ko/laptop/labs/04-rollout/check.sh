#!/usr/bin/env bash
# 랩 4 점검: 새 버전 배포와 롤백.
#
# 입력한 명령어가 아니라 본질을 점검한다:
#   - 애플리케이션 히스토리에 여러 리비전이 있다, 즉 버전이 실제로 변경되었다;
#   - 두 번째 버전의 ConfigMap이 첫 번째를 수정한 것이 아니라 클러스터에 별도 객체로 존재한다;
#   - 컨테이너에 readinessProbe가 있다 — 이것 없이는 무중단을 재현할 수 없다;
#   - 배포가 중간에 멈추지 않고 끝까지 완료되었다;
#   - Service가 반환하는 페이지가 스펙이 참조하는 ConfigMap과 일치한다.
#     이것은 "스펙은 롤백했는데 파드는 재생성되지 않은" 경우를 잡아낸다.
#
# 스크립트는 아무것도 변경하지 않는다. 일회성 파드는 클러스터 내부에서 페이지를
# 가져오기 위해서만 필요하며 스스로를 정리한다.
#
# 노트북에서, 이 랩 폴더에서, 학습용 클러스터 `lab`에 대한 접근으로 실행한다
# (관리 클러스터의 테넌트가 아님):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# 여기서 COZY_TENANT 변수는 필요 없다: 랩 전체가 `lab` 클러스터 안에서 진행된다.
#
# 정리 전에, 그리고 롤백이 완료된 후에 실행한다: 리비전 히스토리는 Deployment와
# 함께 존재하며, 그것과 함께 사라진다.

# 보고서 헤더와 스크립트 옆의 report-<랩>-<날짜>.md 파일 이름에 들어간다.
LAB_NAME="04-rollout"
LAB_TITLE="랩 4 · 새 버전 배포와 롤백"
# 공용 라이브러리: ok / fail / warn / evidence / finish, 클러스터 내부에서의 요청,
# 보고서 기록. 경로는 현재 디렉터리가 아니라 스크립트 자신의 위치를 기준으로 계산한다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG가 없으면 kubectl은 노트북에서 클러스터를 찾다가 모든 것을 하나의 에러로
# 실패시키고, 그 안에서 진짜 원인을 알아볼 수 없다. 즉시 중단한다.
need_kubeconfig

APP=rickroll

# --- 애플리케이션이 제자리에 있고 동작 상태까지 완성되었다 ------------------
# 애플리케이션이 없으면 점검할 것이 없으므로, 여기가 유일한 조기 종료다.
# 이후에는 준비된 복제본 수뿐 아니라 Progressing 컨디션의 이유도 본다:
# NewReplicaSetAvailable은 배포가 완료되었음을 의미한다. 준비된 복제본만으로는
# 부족하다 — 업데이트가 멈춰 있으면 이전 버전이 동작하고, 카운터는 원하는 수를
# 보여주지만, 새 복제본은 한 번도 뜨지 못했을 수 있다.
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
  ok "배포가 끝까지 완료됨: 준비된 복제본 ${WANT}개 중 ${HAVE}개"
else
  fail "애플리케이션이 완료 상태가 아님 (${WANT}개 중 ${HAVE}개 준비됨, 이유: ${PROG_REASON:-없음})" \
       "배포가 멈췄다면 롤백으로 복구하세요: kubectl rollout undo deployment/${APP}"
fi
evidence "애플리케이션 상태" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: 무중단의 대가로 지불한 것 -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "컨테이너에 readinessProbe가 있음 (${PROBE}) — 복제본 교체는 준비된 후에만 진행됨"
else
  fail "컨테이너에 readinessProbe가 없음" \
       "이것 없이는 클러스터가 준비되지 않은 복제본으로 트래픽을 보냅니다; ../01-deploy/rickroll.yaml을 적용하세요"
fi

# --- 버전들이 별도 객체로 만들어졌다 --------------------------------------
# 페이지의 두 버전은 클러스터에 두 개의 별도 ConfigMap으로 존재해야 한다.
# 그렇게 하지 않고 rickroll-page-v1을 제자리에서 고친 사람은 화면에서 새 페이지를
# 보고 랩을 다 했다고 판단하겠지만 — 롤백할 곳이 없고,
# 복제본 교체나 리비전 히스토리 기록도 전혀 일어나지 않는다.
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2가 클러스터에 별도 객체로 존재함"
else
  fail "클러스터에 ConfigMap rickroll-page-v2가 없음" \
       "적용하세요: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "첫 번째 페이지 버전도 보존됨 — 롤백할 곳이 있음"
else
  warn "클러스터에서 ConfigMap rickroll-page-v1을 찾지 못함" \
       "이것 없이는 첫 번째 버전으로의 롤백이 파드를 띄우지 못합니다: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- 리비전 히스토리 -------------------------------------------------------
# 히스토리의 줄 수가 아니라 마지막 리비전의 번호를 본다. 롤백은 새 ReplicaSet을
# 추가하지 않는다 — 이전 것을 재사용하며 그 번호를 올린다.
# 따라서 롤백 후에도 히스토리의 줄 수는 같지만 번호는 커진다.
#   1 — 스펙을 한 번도 바꾸지 않음
#   2 — 버전을 전환함
#   3 이상 — 전환했다가 되돌림
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "애플리케이션의 마지막 리비전은 ${REV_MAX}: 버전을 전환했다가 되돌림"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "마지막 리비전은 2: 배포는 됐지만 롤백은 아직" \
       "첫 번째 버전을 복원하세요: kubectl rollout undo deployment/${APP}"
else
  fail "마지막 리비전은 ${REV_MAX}: 애플리케이션 스펙이 한 번도 바뀌지 않음" \
       "랩의 패치로 볼륨을 두 번째 버전으로 전환한 다음 롤백하세요"
fi
evidence "리비전 히스토리" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- 스펙이 어느 버전을 가리키는가 --------------------------------------
# 랩의 패치는 볼륨을 인덱스로 지정하지만, 여기서는 page라는 이름으로 볼륨을 찾는다.
# 바로 이 차이가 잡힌다: 패치가 잘못된 리스트 요소로 갔다면 page 이름이 이전
# ConfigMap을 가리키거나 사라질 것이고, 참가자는 이상한 nginx 에러가 아니라
# 명확한 말로 그 사실을 알게 된다.
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "애플리케이션 스펙이 첫 번째 페이지 버전으로 되돌려짐"
    ;;
  rickroll-page-v2)
    warn "애플리케이션 스펙이 두 번째 페이지 버전을 가리킴" \
         "랩은 롤백으로 끝납니다; 의도한 것이라면 문제 없지만, 아니라면: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "스펙에 page라는 이름의 볼륨이 없음" \
         "패치가 엉뚱한 곳에 들어간 것 같습니다 (인덱스로 지정!); ../01-deploy/rickroll.yaml을 다시 적용하세요"
    ;;
  *)
    fail "page 볼륨이 랩에서 만들지 않은 ConfigMap ${VOL_CM}을(를) 가리킴" \
         "롤백하세요: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- 실제로 클라이언트에게 반환되는 것 ------------------------------------
# 가장 의미 있는 점검: 스펙과 사용자가 보는 것을 대조한다.
# 여기서 불일치가 나오면 파드가 새 스펙으로 재생성되지 않았다는 뜻이다.
# 하나가 아니라 여덟 번의 요청. Service 뒤에는 복제본 세 개가 있다; 배포가 끝까지
# 수렴하지 않았다면 단일 요청은 1/3 확률로 올바른 버전에 도달해 불일치를 감춘다.
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP}이(가) 클러스터 내부에서 페이지를 반환하지 않음" \
       "엔드포인트를 확인하세요: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # 두 버전 모두 각자의 마커로 긍정적으로 식별한다. "v2가 아니면 곧 v1"이라는
  # 분기는 무엇이든 첫 번째 버전으로 쳤다: 기본 nginx 페이지, 404, 남의 애플리케이션,
  # 쓰레기 — 확인된바, 쓰레기에서도 스크립트가 "랩 합격"을 냈다.
  if printf '%s' "$BODY" | grep -q 'ВЕРСИЯ 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "서비스 주소에서 애플리케이션 페이지가 아닌 것이 반환됨" \
         "응답에 익숙한 마커가 하나도 없습니다 — 원본을 복원하세요: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "페이지 대신 반환된 것" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "클라이언트에게 스펙에 기록된 바로 그 버전이 반환됨 (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "스펙은 ${VOL_CM}을(를) 가리키는데 클라이언트에게는 ${SERVED_VER}이(가) 반환됨" \
         "복제본이 새 스펙으로 재생성되지 않았습니다: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "복제본 이름이 페이지에 치환되지 않음" \
         "ConfigMap rickroll-conf가 사라졌습니다: ../01-deploy/rickroll.yaml을 통째로 적용하세요"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "살아있는 복제본 ${SERVED_POD}이(가) 페이지를 반환함"
    else
      warn "페이지의 이름을 동작 중인 복제본과 대응시키지 못함" \
           "점검 도중에 복제본이 바뀌고 있었을 가능성이 큽니다 — 스크립트를 다시 실행하세요"
    fi
  fi

  evidence "반환된 페이지 (일부)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- 다음 랩들을 위한 준비 상태 ------------------------------------------
# 랩은 교체를 하나씩 볼 수 있도록 복제본을 세 개까지 늘렸다. 남겨진 세 개의
# 복제본은 아무것도 망가뜨리지 않지만 — 그래서 fail이 아니라 warn이다 — 학습
# 노드의 공간을 차지하고, 그 공간은 이후 이웃 랩들에 부족해진다.
if [ "$WANT" = "1" ]; then
  ok "복제본 수가 하나로 되돌려짐"
else
  warn "현재 요청된 복제본 수: ${WANT}" \
       "랩이 끝나면 하나로 되돌리는 것이 좋습니다: kubectl scale deployment ${APP} --replicas=1"
fi

finish
