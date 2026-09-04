#!/usr/bin/env bash
# 랩 6 검증: 애플리케이션이 자신만의 비공개 레지스트리에서 클러스터로 배포된다.
#
# 우리는 "Harbor가 생성되었다"가 아니라 전체 사슬을 확인한다: 레지스트리가 자신의 API로 응답하고,
# 매니페스트의 이미지가 바로 그 안에 존재하며, 클러스터가 같은 주소에 대한 자격 증명을 가지고 있고,
# 이 이미지를 가진 파드가 실제로 실행되며 응답하는지를 본다.
#
# 두 개의 클러스터, 그리고 바로 이것이 이 스크립트가 이웃 스크립트들보다 더 복잡해 보이는 주된 이유다:
# KUBECONFIG는 애플리케이션이 실행되는 여러분의 lab 클러스터이고, COZY_KUBECONFIG는
# 여러분의 테넌트 안에 managed Harbor 서비스가 사는 Cozystack 관리 클러스터다.
# 하나의 명령으로 둘 다 조회할 수 없으므로, 아래에는 kubectl을 호출하는 두 가지 다른 방법이 있다.
#
# 여러분이 랩 폴더에서 실행한다; 아무것도 바꾸지 않고, 오직 살펴보고 보고서를 출력한다:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/workshop
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="랩 6 · 나만의 비공개 이미지 레지스트리"
# 모든 랩의 공통 골격: ok / fail / warn / evidence / finish 및 환경 점검.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 클러스터 접근 파일이 없고 테넌트 번호가 없으면 확인할 것이 없다 — 즉시 종료한다.
need_kubeconfig
need_tenant

APP="passes-api"
# 관리 클러스터의 테넌트 네임스페이스: 이름은 접두사 tenant- 와 여러분의 번호로 조합된다,
# 즉 tenant-workshopXX. 번호는 환경에서 가져오므로,
# 스크립트 본문에 직접 손으로 넣을 필요가 없다.
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/workshop}"

# kubectl을 호출하는 두 가지 방법: kget은 여러분의 lab 클러스터로, cozy는 관리 클러스터로 간다.
# 오류는 의도적으로 억제된다: 여기서 객체가 없는 것은 장애가 아니라 예상된 결과 중 하나이며,
# 아래에서 명확한 조언과 함께 별도의 분기로 처리된다.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 관리 클러스터의 managed Harbor 서비스 ---------------------------
# 선택적 부분: 테넌트 kubeconfig 없이도 랩은 여전히 확인 가능하지만,
# 플랫폼 측에서 서비스를 볼 수는 없다.
#
# "명령이 동작하지 않은" 경우를 별도로 잡는다: 테넌트의 역할이 애플리케이션 조회를
# 허용하지 않을 수 있다. 이는 참가자의 잘못이 아니고 검증을 실패시킬 이유도 아니므로,
# 여기서는 fail("잘못했다")이 아니라 warn("보지 못했다")이다. 명령 오류와 빈 응답을
# 의도적으로 구분한다: 빈 목록은 Harbor가 아예 생성되지 않았음을 뜻한다.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "테넌트 kubeconfig ${COZY_KUBECONFIG} 를 찾을 수 없음 — Harbor 상태를 확인하지 않았습니다" \
       "경로를 지정하세요: export COZY_KUBECONFIG=~/.kube/workshop"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "테넌트 ${TENANT_NS} 에서 Harbor 애플리케이션을 조회할 수 없습니다" \
         "테넌트의 역할이 이 명령을 허용하지 않을 수 있습니다 — 이는 랩 오류가 아니며, 나머지는 모두 아래에서 확인됩니다"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "테넌트 ${TENANT_NS} 에 Harbor 애플리케이션이 하나도 없습니다" \
         "대시보드에서 생성하세요: 애플리케이션 생성 -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "managed Harbor 서비스 «${HARBOR_NAME}» 준비 완료"
    else
      warn "Harbor «${HARBOR_NAME}» 는 존재하지만 준비 완료를 보고하지 않습니다" \
           "대시보드에서 상태를 확인하세요; Harbor는 기동에 5-10분이 걸리며, 테넌트에 오브젝트 스토리지가 없으면 아예 기동되지 않습니다"
    fi
    evidence "테넌트의 Harbor 애플리케이션" "$HARBOR_LIST"
    # 자격 증명 시크릿은 읽으려 하지 않는다: 테넌트는 이 시크릿을 읽을 수 있지만,
    # 어차피 보고서에 비밀번호는 필요하지 않다.
  fi
fi

# --- 애플리케이션이 이미지를 어디서 가져오는가 ------------------------------------------
# 랩의 요점은 이미지가 인터넷이 아니라 여러분의 레지스트리에서 왔다는 것이다. 이것은
# 매니페스트의 이미지 이름으로 확인한다: 슬래시 앞까지의 이름 첫 부분이 레지스트리 주소다.
# 거기에 점도 콜론도 없으면 주소가 전혀 없는 것이고, 클러스터는 조용히 Docker Hub로
# 이미지를 가지러 갔을 것이다 — 바로 보안이 금지한 그곳으로.
# HARBOR-HOST 자리표시자와 알려진 공개 레지스트리는 별도의 분기로 잡는다:
# 형식적으로는 주소가 있지만 랩 요구 사항은 충족되지 않았고, 조언은 각 경우마다 다르다.
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "lab 클러스터에 애플리케이션 ${APP} 이 없습니다" \
       "자신의 Harbor 주소를 넣은 passes.yaml 을 적용하세요"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # 레지스트리 주소처럼 보임
    *) REGISTRY="" ;;          # 주소 없음 — 이미지가 Docker Hub에서 당겨진다는 뜻
  esac

  if [ -z "$REGISTRY" ]; then
    fail "이미지 ${IMAGE} 가 여러분의 것이 아닌 공개 레지스트리에서 당겨집니다" \
         "이미지 이름은 여러분의 Harbor 주소로 시작해야 합니다"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "매니페스트에 자리표시자 주소 HARBOR-HOST 가 그대로 남아 있습니다" \
         "여러분의 Harbor 주소를 넣으세요: sed -i 's|HARBOR-HOST|harbor.여러분도메인|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "이미지가 공개 레지스트리 ${REGISTRY} 에서 당겨집니다" \
         "보안이 비공개 레지스트리를 요구했습니다 — 이미지를 빌드해서 자신의 Harbor로 푸시하세요"
  else
    ok "애플리케이션이 여러분의 레지스트리에서 시작됩니다: ${REGISTRY}"
    evidence "애플리케이션 이미지" "$IMAGE"
  fi
fi

# --- 레지스트리가 실제로 동작한다 ------------------------------------------
# 매니페스트의 주소가 올바르게 적혀 있어도 그 주소에 레지스트리가 없을 수 있다: Harbor는
# 즉시 기동되지 않으며, 도메인의 오타도 똑같이 보인다. 그래서 우리는 그 API를
# 두드리고 "pong" 응답을 기다린다 — 이것은 그곳에 있는 것이 다른 사이트나 로드밸런서
# 스텁이 아니라 바로 Harbor임을 확인해 준다.
if [ -z "$REGISTRY" ]; then
  : # 이미 위에서 보고함
elif ! command -v curl >/dev/null 2>&1; then
  warn "curl 유틸리티가 없음 — 레지스트리 가용성을 확인하지 않았습니다" \
       "브라우저에서 https://${REGISTRY} 를 여세요, 거기에 Harbor 인터페이스가 있어야 합니다"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","알 수 없음"))' 2>/dev/null)"
    ok "레지스트리가 API로 응답합니다: https://${REGISTRY} (Harbor ${VER:-버전 알 수 없음})"
    evidence "레지스트리" "https://${REGISTRY}
API ping: ${PING}
Harbor 버전: ${VER:-알 수 없음}"
  else
    fail "레지스트리 https://${REGISTRY} 가 /api/v2.0/ping 요청에 응답하지 않습니다" \
         "주소와 대시보드의 Harbor 애플리케이션 상태를 확인하세요"
  fi
fi

# --- 클러스터가 접근 자격 증명을 가지고 있다 -------------------------------------------
# 시크릿이 매니페스트에 참조되어 있는 것만으로는 충분하지 않다 — 중요한 것은 그것이 이미지가
# 당겨지는 바로 그 레지스트리에 대한 자격 증명을 가지고 있는가이다. 가장 흔한 랩 실수는
# 정상처럼 보인다: 시크릿이 생성되었고 매니페스트에 이름이 지정되었지만, 그 안의 주소가 틀려서
# (불필요한 https://, 포트, 다른 호스트 이름), kubelet이 그것을 적용하지 않는다.
# 그래서 시크릿 내용을 풀어서 이름이 아니라 주소를 비교한다.
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # 애플리케이션 없음, 위에서 보고함
elif [ -z "$PULL_SECRETS" ]; then
  fail "매니페스트 ${APP} 에 imagePullSecret 이 하나도 지정되어 있지 않습니다" \
       "비공개 레지스트리의 이미지는 자격 증명 없이는 다운로드되지 않습니다: imagePullSecrets 를 추가하세요, passes.yaml 참고"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # 설정은 python으로 파싱한다: base64 -d 는 macOS와 Linux에서 다르게 동작하며,
    # 비밀번호는 보고서에 출력하면 안 되므로 — 주소 목록만 가져온다.
    SERVERS="$(kget secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' \
      | python3 -c 'import sys,json,base64
raw = sys.stdin.read().strip()
try:
    cfg = json.loads(base64.b64decode(raw))
    print(" ".join(cfg.get("auths", {}).keys()))
except Exception:
    pass' 2>/dev/null)"
    if [ -n "$REGISTRY" ] && printf '%s' "$SERVERS" | grep -q "$REGISTRY"; then
      SECRET_OK="$s"
      break
    fi
  done

  if [ -n "$SECRET_OK" ]; then
    ok "클러스터가 시크릿 ${SECRET_OK} 안에 ${REGISTRY} 에 대한 자격 증명을 가지고 있습니다 (비밀번호: <숨김>)"
  else
    fail "지정된 시크릿 중 (${PULL_SECRETS}) 어느 것도 ${REGISTRY:-여러분의 레지스트리} 에 대한 자격 증명을 담고 있지 않습니다" \
         "이렇게 생성하세요: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-주소} --docker-username=admin --docker-password=..."
  fi
fi

# --- 파드가 실제로 시작되었다 -----------------------------------------------
# ImagePullBackOff 및 ErrImagePull 상태를 별도로 처리한다: 이것은 랩이 의도적으로 보여주는
# 바로 그 실패이며, 참가자가 일반적인 "파드가 동작하지 않음" 대신 그것을 눈으로 알아보는 것이
# 중요하다. 실제 원인은 증거로 출력한다 —
# 레지스트리 장애와 이미지 이름의 오타에서 파드 상태는 동일하다.
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "실행 중인 애플리케이션 복제본: ${RUNNING}"
  evidence "애플리케이션 파드" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "이미지가 다운로드되지 않습니다: ${BADSTATE}" \
       "이것은 레지스트리 접근 거부이거나 이미지 이름의 오타입니다; 실제 원인은 kubectl describe pod -l app=passes-api 가 보여줍니다"
  evidence "실패 원인" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "실행 중인 애플리케이션 복제본이 하나도 없습니다 (상태: ${BADSTATE:-파드 없음})" \
       "kubectl describe pod -l app=passes-api 를 확인하세요"
fi

# 가장 진단하기 어려운 랩 오류에 대한 별도 점검: 이미지가 ARM용으로 빌드되었는데
# 클러스터 노드가 x86인 경우. 모든 것이 올바르게 보인다 — 이미지가 빌드되고 레지스트리로
# 푸시되어 노드에 다운로드되었지만 — 프로세스가 시작되지 않는다. 주변의 그 무엇도 프로세서
# 아키텍처를 암시하지 않으며, 유일한 단서는 파드 로그에 있으므로,
# 별도 점검으로 그것을 살펴보고 원인을 직접 지목한다.
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "이미지가 다른 프로세서 아키텍처용으로 빌드되었습니다" \
       "플래그를 붙여 다시 빌드하세요: docker build --platform linux/amd64 -t ${IMAGE} app/ 후 다시 푸시하세요"
fi

# --- 애플리케이션이 실질적으로 응답한다 ----------------------------------------
# 실행 중인 파드가 곧 동작하는 서비스를 의미하지는 않는다. 우리는 클러스터 내부로 들어가,
# 애플리케이션을 그 내부 이름으로 요청하고 응답에서 파드 이름을 읽는다. 실제로 실행 중인
# 파드와 일치하면 — 응답하는 것이 우연히 이 주소를 차지한 다른 무언가가 아니라 바로 우리가
# 배포한 애플리케이션이라는 뜻이다. 불일치는 fail이 아니라 warn이다:
# 복제본이 두 요청 사이에 재생성되었을 수 있으며, 이는 참가자의 잘못이 아니다.
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "${APP} 이름의 Service 가 없습니다" \
       "그것은 passes.yaml 에 기술되어 있습니다 — Deployment만이 아니라 파일 전체를 적용하세요"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "서비스 ${APP} 가 예상한 JSON을 반환하지 않았습니다" \
         "kubectl logs -l app=passes-api 를 확인하고 Service의 포트가 애플리케이션 포트와 일치하는지 확인하세요"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "서비스가 JSON으로 응답하며, 응답은 실제로 실행 중인 파드 ${SERVED_POD} 에서 왔습니다"
    evidence "서비스 응답" "$BODY"
  else
    warn "서비스가 실행 중이지 않은 파드 ${SERVED_POD} 의 이름으로 응답했습니다" \
         "복제본이 요청 사이에 재생성되었을 가능성이 높습니다 — 점검을 다시 실행하세요"
  fi
fi

finish
