#!/usr/bin/env bash
# 랩 5 점검: 클러스터 상태는 Git에서 오며 리컨실리에이션으로 제자리에 유지된다.
#
# 여러분의 `lab` 클러스터에서, 랩 폴더에서, 여러분이 직접 실행한다:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# 아무것도 변경하지 않는다 — 살펴보고 보고서를 출력할 뿐이다: 무엇을 점검했는지, 무엇이 통과했는지,
# 무엇이 통과하지 못했는지, 그리고 첨부된 증거.
#
# 「Flux가 설치됨」이 아니라 「메커니즘이 동작함」을 점검한다: 소스가 읽히고, 적용된 것이
# Flux에 속하며, 서비스가 응답하고, 리컨실리에이션이 꺼져 있지 않다. 설치되어 있지만
# 일시 중지된 Flux는 랩의 핵심을 놓친 채 통과하는 가장 흔한 방법이다.

LAB_NAME="05-gitops"
LAB_TITLE="랩 5 · Git 안의 인프라"
# 모든 랩의 공용 래퍼: 여기서 ok / fail / warn / evidence / finish 와
# 환경 점검을 가져온다. 경로는 이 파일의 위치를 기준으로 계산되므로 스크립트를
# 어느 폴더에서든 실행할 수 있다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 클러스터 접근 파일이 없으면 점검할 것이 없다 — 명확한 이유와 함께 즉시 종료한다.
need_kubeconfig

# 랩이 생성하는 이름들. 한곳에 모아둔다: 참가자가 객체 이름을 다르게 지었다면
# 스크립트 전체에서 이름을 찾을 것이 아니라 여기서 수정한다.
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# 객체나 CRD가 없어도 실패하지 않고 객체의 필드를 읽는다.
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux 서비스 -----------------------------------------------------------
# 「파드가 존재함」이 아니라 「Ready 상태의 복제본이 최소 하나」를 본다: 파드는 노드에
# 메모리가 없어 Pending에 머무르면서도 get pods 출력에 나타날 수 있다.
# 두 서비스 모두 필수이며 역할을 나눈다: source-controller는 저장소를 내려받고,
# kustomize-controller는 내려받은 것을 적용한다. 두 번째가 없으면 아무것도 클러스터로 가지 않는다.
if ! kget namespace flux-system >/dev/null; then
  fail "클러스터에 flux-system 네임스페이스가 없습니다" \
       "Flux가 설치되지 않았습니다: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "Flux 서비스가 실행 중입니다: source-controller 및 kustomize-controller"
    evidence "Flux 파드" "$(kget pods -n flux-system -o wide)"
  else
    fail "Flux 서비스가 실행되지 않습니다:${FLUX_BAD}" \
         "kubectl get pods -n flux-system 을 확인하세요; 작은 노드에서는 메모리가 부족할 수 있습니다"
  fi
fi

# --- 소스: GitRepository ----------------------------------------------------
# 서로 다른 세 가지 결과이며 혼동해서는 안 된다: 객체가 아예 없다; 객체는 있지만 그 안에
# 주소 자리표시자가 남아 있다; 객체가 있고 주소도 진짜이지만 Flux가 저장소를 읽지
# 못했다. 각 경우마다 조언이 다르므로 분기도 다르다.
#
# 성공 신호는 status.conditions에서 가져온다 — 이는 Flux가 Git에 접근을 시도한 후
# 스스로에 대해 보고하는 것이며, 객체의 존재로 우리가 추측한 것이 아니다.
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "클러스터에 GitRepository 타입이 없습니다" \
       "Flux가 설치되지 않았거나 source-controller 없이 설치되었습니다"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "flux-system에서 이름이 ${GITREPO}인 GitRepository를 찾을 수 없습니다" \
         "자신의 저장소 주소를 넣어 flux/gitrepository.yaml을 적용하세요"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "GitRepository에 주소 자리표시자가 남아 있습니다" \
         "flux/gitrepository.yaml을 열어 자신의 GitHub 저장소 주소를 입력하세요"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux가 여러분의 저장소를 읽고 있습니다: ${GR_URL}"
    evidence "Git 안의 소스" "url: ${GR_URL}
revision: ${GR_REV:-알 수 없음}"
  else
    fail "Flux가 저장소 ${GR_URL}을(를) 읽을 수 없습니다" \
         "flux get sources git 을 확인하세요; 대개는 주소 오타, 비공개 저장소, 또는 다른 브랜치입니다"
    evidence "소스 오류" "${GR_MSG:-메시지 없음}"
  fi
fi

# --- 적용: Kustomization ----------------------------------------------------
# 여기서는 적용 사실이 아니라 메커니즘의 세 가지 속성을 점검한다. 이것들이 없으면 랩은
# 의미를 잃는다: 적용된 리비전이 Git과 일치하고, 리컨실리에이션이 일시 중지되지 않았으며,
# 저장소에서 사라진 것의 삭제가 활성화되어 있다.
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "클러스터에 Kustomization 타입이 없습니다" \
       "Flux가 kustomize-controller 없이 설치되었습니다 — 두 컴포넌트를 모두 포함해 재설치하세요"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "flux-system에서 이름이 ${KUSTOMIZATION}인 Kustomization을 찾을 수 없습니다" \
         "flux/kustomization.yaml을 적용하세요"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux가 Git의 상태를 적용했습니다, 리비전 ${KS_REV}"
    evidence "적용된 리비전" "$KS_REV"
  else
    fail "Flux가 Git의 상태를 적용하지 못했습니다" \
         "flux get kustomizations 및 kubectl describe kustomization ${KUSTOMIZATION} -n flux-system 을 확인하세요"
    evidence "적용 오류" "${KS_MSG:-메시지 없음}"
  fi

  # 일시 중지된 Flux는 설치된 것처럼 보이지만 아무것도 하지 않는다. 이것은 랩의 이점을
  # 하나도 얻지 못한 채 「통과」하는 주된 방법이다.
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "리컨실리에이션이 일시 중지되었습니다 (suspend: true) — Flux가 클러스터를 감시하지 않습니다" \
         "다시 켜세요: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "리컨실리에이션이 활성 상태입니다: Git과의 차이는 스스로 해소됩니다, 간격 ${KS_INTERVAL:-기본값}"
  fi

  # 이것은 fail이 아니라 warn이다: prune 없이도 클러스터는 여전히 Git으로 관리되며 랩은 통과된다.
  # 그러나 기술이 한쪽으로 치우친다 — 파일을 삭제해도 클러스터에서는 아무것도 삭제되지 않는다.
  if [ "$KS_PRUNE" = "true" ]; then
    ok "Git에서 사라진 것의 삭제(prune)가 활성화되어 있습니다"
  else
    warn "prune이 꺼져 있습니다 — 저장소에서 삭제된 것이 클러스터에서 계속 실행됩니다" \
         "flux/kustomization.yaml에 prune: true를 설정하세요, 그렇지 않으면 Git이 상태의 절반만 기술합니다"
  fi
fi

# --- 클러스터의 객체는 손으로 적용된 것이 아니라 Flux에 속한다 -------------
# 이것은 랩의 핵심 점검이며, 존재가 아니라 출처에 관한 것이다. 애플리케이션은
# 두 경우 모두 클러스터에 존재한다: Flux가 가져왔을 때, 그리고 참가자가 같은 파일을
# kubectl apply로 손수 적용했을 때. 겉으로는 구분할 수 없다 — Deployment가 동일하다.
# 소유자 레이블이 이를 구분한다: kustomize-controller가 저장소 내용을 적용할 때만
# 이를 설정한다. 손으로 적용된 객체는 그 레이블을 얻지 못한다.
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "${NS_APP} 네임스페이스에 passes 애플리케이션이 없습니다" \
       "자신의 저장소 apps 폴더에 app/*.yaml을 넣고 push한 뒤 리컨실리에이션을 기다리세요"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "클러스터의 애플리케이션은 손으로 적용된 것이 아니라 Flux에 속합니다"
else
  fail "passes 애플리케이션이 있지만 Flux가 만든 것이 아닙니다" \
       "이를 제거하고(kubectl delete ns ${NS_APP}) Flux가 Git에서 다시 배포하도록 하세요"
fi

# --- 애플리케이션이 실제로 응답한다 --------------------------------------
# 클러스터의 객체와 동작하는 서비스는 별개다: Deployment는 생성되어 있는데
# 파드는 반복해서 죽을 수 있다. 그래서 클러스터 안으로 들어가 서비스를 그 내부
# 이름으로 요청한다 — 이웃 애플리케이션이 접근할 때와 똑같은 경로로.
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q '출입증'; then
  ok "«출입증» 서비스가 클러스터 내부에서 HTTP로 응답합니다 (실행 중인 복제본: ${PODS_READY})"
else
  fail "«출입증» 서비스가 passes.${NS_APP}.svc.cluster.local 주소에서 응답하지 않습니다" \
       "kubectl get pods -n ${NS_APP} 및 kubectl logs -n ${NS_APP} deploy/passes 를 확인하세요"
fi

# 페이지의 파드 이름은 실제로 실행 중인 복제본과 일치해야 한다: 그래야 우리가
# 클러스터에서 보는 바로 그 파드가 응답하는 것이지, 캐시된 응답이나 우연히 같은
# 이름을 차지한 다른 서비스가 아님을 알 수 있다. 불일치는 fail이 아니라 warn이다:
# 복제본이 두 요청 사이에 재생성되었을 수 있으며, 이는 참가자의 잘못이 아니다.
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "페이지를 실제로 존재하는 파드 ${SERVED_POD}이(가) 제공했습니다"
  evidence "서비스 복제본" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "응답의 파드 ${SERVED_POD}을(를) 실행 중인 것들에서 찾을 수 없습니다" \
       "복제본이 두 요청 사이에 재생성되었을 가능성이 큽니다 — 점검을 다시 실행하세요"
fi

# --- 여러분의 저장소 클론에서의 변경 이력 ----------------------------
# 선택적 부분: 스크립트는 알려주기 전까지 클론이 어디 있는지 모른다.
# 여기서 점검하는 것은 롤백 방법이다. kubectl rollout undo로도 클러스터는 이전
# 버전으로 돌아가지만, Git은 이를 알지 못하고 바로 다음 리컨실리에이션이 나쁜
# 변경을 다시 되돌린다. 그래서 이력에서 revert를 찾는다 — 롤백은 진실이 사는 곳에서
# 이루어진다. 그리고 클러스터에 적용된 리비전이 여러분의 HEAD와 일치하는지 확인한다:
# 커밋하고 push를 잊는 것은 흔한 일이며, 밖에서 보면 「Flux가 멈췄다」처럼 보인다.
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "저장소 이력을 점검하지 않았습니다: LAB_REPO 변수가 설정되지 않았습니다" \
       "이력도 점검하려면: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "${REPO}에 저장소 클론이 없습니다" \
       "git clone을 실행한 폴더를 지정하세요"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "이력에 git revert를 통한 롤백이 있습니다 — 나쁜 변경이 진실이 사는 곳에서 취소되었습니다"
    evidence "변경 이력" "$LOG"
  else
    fail "최근 커밋에 revert가 하나도 없습니다" \
         "나쁜 변경을 kubectl rollout undo가 아니라 git revert --no-edit HEAD로 롤백하고 push하세요"
  fi

  # 클러스터에 적용된 것은 브랜치의 마지막 커밋과 일치해야 한다.
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "클러스터에서 여러분의 브랜치에 있는 것과 정확히 같은 것이 실행됩니다 (커밋 ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "클러스터의 커밋(${KS_REV:-알 수 없음})이 로컬 HEAD(${HEAD_SHA})와 다릅니다" \
         "로컬 커밋이 전송되었는지(git push) 확인하고 리컨실리에이션 간격을 기다리세요"
  fi
fi

finish
