#!/usr/bin/env bash
# 랩 5 확인: 클러스터 상태는 Git에서 오고, 리컨실레이션(reconciliation)이 그 상태를 유지한다.
#
# 여러분의 `lab` 클러스터에서, 랩 폴더 안에서, 여러분이 직접 실행합니다:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# 아무것도 변경하지 않습니다 — 살펴보기만 하고 리포트를 출력합니다: 무엇을 확인했는지, 무엇이 통과했는지,
# 무엇이 실패했는지, 그리고 첨부된 증거.
#
# 우리는 「Flux가 설치되었는가」가 아니라 「메커니즘이 동작하는가」를 확인합니다: 소스가 읽히고, 적용된 것이
# Flux에 속하며, 서비스가 응답하고, 리컨실레이션이 꺼져 있지 않다. 설치되어 있지만
# 일시정지된 Flux는 랩의 핵심을 놓친 채 통과하는 가장 흔한 방법입니다.

LAB_NAME="05-gitops"
LAB_TITLE="랩 5 · Git 속 인프라"
# 모든 랩의 공통 하네스: 여기서 ok / fail / warn / evidence / finish 와
# 환경 점검을 가져옵니다. 경로는 이 파일의 위치를 기준으로 계산되므로, 스크립트는
# 어느 폴더에서든 실행할 수 있습니다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 클러스터 접근 파일이 없으면 확인할 것이 없습니다 — 명확한 이유와 함께 즉시 종료합니다.
need_kubeconfig

# 랩이 생성하는 이름들. 한곳에 모아 둡니다: 참가자가 객체 이름을 다르게 지었다면,
# 스크립트 전체에서 이름을 찾아다니지 말고 여기서 고치세요.
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# 객체나 CRD가 없어도 실패하지 않고 객체의 필드를 읽습니다.
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux 서비스 -----------------------------------------------------------
# 우리는 「파드가 존재하는가」가 아니라 「Ready 상태의 복제본이 최소 하나는 있는가」를 봅니다: 파드는
# 노드에 메모리가 없어 Pending에 걸려 있으면서도 get pods 출력에는 나타날 수 있습니다.
# 두 서비스 모두 필수이며 역할을 나눕니다: source-controller는 리포지토리를 내려받고,
# kustomize-controller는 내려받은 것을 적용합니다. 두 번째가 없으면 아무것도 클러스터에 반영되지 않습니다.
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
    ok "Flux 서비스가 동작 중입니다: source-controller 와 kustomize-controller"
    evidence "Flux 파드" "$(kget pods -n flux-system -o wide)"
  else
    fail "Flux 서비스가 동작하지 않습니다:${FLUX_BAD}" \
         "kubectl get pods -n flux-system 를 보세요; 작은 노드에서는 메모리가 부족할 수 있습니다"
  fi
fi

# --- 소스: GitRepository ------------------------------------------------
# 세 가지 서로 다른 결과가 있으며 혼동하면 안 됩니다: 객체가 아예 없다; 객체는 있으나 그 안에
# 주소 자리표시자가 남아 있다; 객체가 있고 주소도 진짜지만 Flux가 리포지토리를 읽지 못했다.
# 각 경우마다 조언이 다르므로 분기도 다릅니다.
#
# 성공 신호는 status.conditions 에서 가져옵니다 — 이것은 Flux가 Git에 다녀온 뒤
# 스스로에 대해 보고하는 것이며, 객체의 존재만으로 우리가 추측하는 것이 아닙니다.
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
    fail "flux-system 에 ${GITREPO} 라는 이름의 GitRepository를 찾을 수 없습니다" \
         "flux/gitrepository.yaml 을 여러분 리포지토리의 주소로 바꿔 적용하세요"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "GitRepository에 자리표시자 주소가 그대로 남아 있습니다" \
         "flux/gitrepository.yaml 을 열고 여러분의 GitHub 리포지토리 주소를 입력하세요"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux가 여러분의 리포지토리를 읽고 있습니다: ${GR_URL}"
    evidence "Git 속 소스" "url: ${GR_URL}
revision: ${GR_REV:-알 수 없음}"
  else
    fail "Flux가 리포지토리 ${GR_URL} 를 읽지 못합니다" \
         "flux get sources git 를 보세요; 대부분 주소의 오타, 비공개 리포지토리, 또는 다른 브랜치가 원인입니다"
    evidence "소스 오류" "${GR_MSG:-메시지 없음}"
  fi
fi

# --- 적용: Kustomization ----------------------------------------------
# 여기서는 적용 여부 자체가 아니라, 그것이 없으면 랩이 의미를 잃는 메커니즘의 세 가지 속성을
# 확인합니다: 적용된 리비전이 Git과 일치하고, 리컨실레이션이 일시정지되지 않았으며,
# 리포지토리에서 사라진 것의 제거(prune)가 켜져 있다.
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "클러스터에 Kustomization 타입이 없습니다" \
       "Flux가 kustomize-controller 없이 설치되었습니다 — 두 컴포넌트를 모두 넣어 재설치하세요"
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
    fail "flux-system 에 ${KUSTOMIZATION} 라는 이름의 Kustomization을 찾을 수 없습니다" \
         "flux/kustomization.yaml 을 적용하세요"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux가 Git의 상태를 적용했습니다, 리비전 ${KS_REV}"
    evidence "적용된 리비전" "$KS_REV"
  else
    fail "Flux가 Git의 상태를 적용하지 못했습니다" \
         "flux get kustomizations 와 kubectl describe kustomization ${KUSTOMIZATION} -n flux-system 를 보세요"
    evidence "적용 오류" "${KS_MSG:-메시지 없음}"
  fi

  # 일시정지된 Flux는 설치된 것처럼 보이지만 아무 일도 하지 않습니다. 이것이 랩의 이점을
  # 하나도 얻지 못한 채 「통과」하는 주된 방법입니다.
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "리컨실레이션이 일시정지되었습니다 (suspend: true) — Flux가 클러스터를 감시하지 않습니다" \
         "다시 켜세요: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "리컨실레이션이 활성 상태입니다: Git과의 차이는 스스로 교정됩니다, 간격 ${KS_INTERVAL:-기본값}"
  fi

  # 이것은 fail이 아니라 warn입니다: prune이 없어도 클러스터는 여전히 Git에서 관리되며 랩은 통과됩니다.
  # 다만 설명이 반쪽이 됩니다 — 파일을 지워도 클러스터에서는 아무것도 지워지지 않습니다.
  if [ "$KS_PRUNE" = "true" ]; then
    ok "Git에서 사라진 것의 제거(prune)가 켜져 있습니다"
  else
    warn "prune이 꺼져 있습니다 — 리포지토리에서 삭제된 것이 클러스터에서 계속 동작합니다" \
         "flux/kustomization.yaml 에 prune: true 를 넣으세요, 그렇지 않으면 Git이 상태의 절반만 기술합니다"
  fi
fi

# --- 클러스터의 객체는 손으로 적용된 것이 아니라 Flux에 속한다 ---------
# 이것이 랩의 핵심 확인이며, 존재 여부가 아니라 출처에 관한 것입니다. 두 경우 모두 애플리케이션은
# 클러스터에 있습니다: Flux가 가져왔든, 참가자가 같은 파일을 kubectl apply로 손수 적용했든.
# 겉으로는 구별되지 않습니다 — Deployment는 동일합니다.
# 소유자 레이블이 이 둘을 구분합니다: 이 레이블은 kustomize-controller가 리포지토리의 내용을 적용할 때만
# 붙입니다. 손으로 적용된 객체는 그 레이블을 얻지 못합니다.
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "네임스페이스 ${NS_APP} 에 passes 애플리케이션이 없습니다" \
       "app/*.yaml 을 여러분 리포지토리의 apps 폴더에 넣고, push한 뒤 리컨실레이션을 기다리세요"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "클러스터의 애플리케이션은 손으로 적용된 것이 아니라 Flux에 속합니다"
else
  fail "passes 애플리케이션은 있으나 Flux가 만든 것이 아닙니다" \
       "그것을 지우고(kubectl delete ns ${NS_APP}) Flux가 Git에서 다시 배포하도록 하세요"
fi

# --- 애플리케이션이 실제로 응답한다 --------------------------------------
# 클러스터의 객체와 동작하는 서비스는 다른 것입니다: Deployment는 생성되어 있어도
# 파드가 반복해서 크래시할 수 있습니다. 그래서 클러스터 내부로 들어가 서비스를 그 내부 이름으로
# 요청합니다 — 이웃 애플리케이션이 그것에 접근할 때와 같은 경로로.
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q '출입증'; then
  ok "「출입증」 서비스가 클러스터 내부에서 HTTP로 응답합니다 (동작 중인 복제본: ${PODS_READY})"
else
  fail "「출입증」 서비스가 passes.${NS_APP}.svc.cluster.local 에서 응답하지 않습니다" \
       "kubectl get pods -n ${NS_APP} 와 kubectl logs -n ${NS_APP} deploy/passes 를 보세요"
fi

# 페이지에 표시된 파드 이름은 실제로 실행 중인 복제본과 일치해야 합니다: 이는 응답이
# 우리가 클러스터에서 보는 바로 그 파드에서 온 것이며, 캐시된 답이나 우연히 같은 이름을
# 차지한 다른 서비스가 아님을 보여줍니다. 불일치는 fail이 아니라 warn입니다: 복제본이
# 두 요청 사이에 재생성되었을 수 있고, 이는 참가자의 잘못이 아니기 때문입니다.
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "페이지는 실제로 존재하는 파드 ${SERVED_POD} 가 제공했습니다"
  evidence "서비스 복제본" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "응답에 있는 파드 ${SERVED_POD} 가 실행 중인 것들 사이에서 발견되지 않습니다" \
       "복제본이 두 요청 사이에 재생성되었을 가능성이 높습니다 — 확인을 다시 실행하세요"
fi

# --- 여러분의 리포지토리 클론에 있는 변경 이력 ----------------------------
# 선택 사항: 스크립트는 알려주기 전까지 클론이 어디 있는지 모릅니다.
# 여기서 확인하는 것은 롤백 방법입니다. kubectl rollout undo 로도 클러스터는 이전 버전으로
# 돌아가지만, Git은 그 사실을 모르고, 바로 다음 리컨실레이션이 나쁜 변경을 다시 되돌려 놓습니다.
# 그래서 이력에서 revert를 찾습니다 — 롤백은 진실이 사는 곳에서 이루어집니다. 그리고 클러스터에
# 적용된 리비전이 여러분의 HEAD와 일치하는지 확인합니다:
# 커밋해 놓고 push를 잊는 일은 흔하며, 밖에서 보면 「Flux가 멈췄다」처럼 보입니다.
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "리포지토리 이력을 확인하지 않았습니다: LAB_REPO 변수가 설정되지 않았습니다" \
       "이력까지 확인하려면: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "${REPO} 에 리포지토리 클론이 없습니다" \
       "git clone 을 한 폴더를 지정하세요"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "이력에 git revert 를 통한 롤백이 있습니다 — 나쁜 변경이 진실이 사는 곳에서 취소되었습니다"
    evidence "변경 이력" "$LOG"
  else
    fail "최근 커밋들에 revert가 하나도 없습니다" \
         "나쁜 변경을 kubectl rollout undo 가 아니라 git revert --no-edit HEAD 로 되돌리고 push하세요"
  fi

  # 클러스터에 적용된 것은 브랜치의 최신 커밋과 일치해야 합니다.
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "클러스터에서는 여러분의 브랜치에 있는 바로 그것이 동작합니다 (커밋 ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "클러스터의 커밋(${KS_REV:-알 수 없음})이 로컬 HEAD(${HEAD_SHA})와 다릅니다" \
         "로컬 커밋이 push되었는지 확인하고(git push), 리컨실레이션 간격을 기다리세요"
  fi
fi

finish
