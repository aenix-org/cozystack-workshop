#!/usr/bin/env bash
# 랩 11 확인: Android 빌드가 끝까지 실행되었고, APK가 버킷에 도달했는지.
#
# 우리는 "Job 생성됨"이 아니라 서로 다른 세 가지 주장을 확인하며, 그것들은 서로 같지 않다:
#   1) Job이 성공적으로 완료되었다,
#   2) 그 안에서 실제로 APK가 빌드되었다 (BUILD SUCCESSFUL),
#   3) 파일이 실제로 오브젝트 스토리지에 도달했다 (APK-UPLOADED 마커).
# 누군가 스크립트를 수정했다면 — Job은 성공적으로 완료되고도 아무것도 빌드하지 않을 수 있다.
#
# 노트북에서, 이 랩의 폴더에서, 학습용 클러스터 `lab`에 대한 접근으로 실행된다
# (관리 클러스터의 테넌트가 아니라 — 빌드는 클러스터 안에서 진행된다):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# 스크립트는 클러스터에서 아무것도 변경하지 않는다 — 읽기만 하고 HTTP 요청만 보낸다.
# 정리하기 전에 실행하라: Job을 삭제하면 그 로그도 함께 삭제되고, 로그가 없으면
# 위의 세 주장 중 두 개를 확인할 방법이 남지 않는다.

# 이 두 변수는 lib.sh가 가져간다 — 보고서 헤더와, 스크립트가 자신 옆에 놓는
# report-<랩>-<날짜>.md 파일 이름에 들어간다.
LAB_NAME="11-android"
LAB_TITLE="랩 11 · 클러스터에서 모바일 앱 빌드하기"
# 공통 확인 라이브러리: 여기서 ok / fail / warn / evidence / finish,
# 클러스터 내부 요청과 보고서 기록이 온다. 경로는 스크립트 자신이 있는 위치에서
# 계산되므로, 어느 디렉터리에서 실행해도 동일하게 작동한다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG이 설정되어 있지 않으면 즉시 멈춘다. 그것이 없으면 kubectl은 노트북
# 자체에서 클러스터를 찾다가 찾지 못하고, 모든 확인을 똑같은 오류로 연달아 실패시키며,
# 거기서는 진짜 원인이 보이지 않는다.
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# 시크릿 키의 값. base64 -d는 어디서나 같지 않다 (BSD 대 GNU),
# 그래서 파이썬으로 디코딩한다 — 그것은 이미 확인 라이브러리에 필요하다.
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- 버킷 접근 시크릿 -------------------------------------------
# 우리는 시크릿의 존재가 아니라, 그 안의 네 개 필드가 모두 채워졌는지를 확인한다.
# 시크릿은 손으로, 네 개의 --from-literal을 연달아 써서 만들고, 가장 흔한 문제는
# 비어 있거나 누락된 값이다: 이때 오브젝트는 성공적으로 생성되지만, 빌드는 마지막
# 단계에서, 빌드가 이미 지나간 뒤에 실패한다. 지금 알아내는 편이 더 싸다.
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "시크릿 ${SECRET}이(가) 제자리에 있고, 네 개 키가 모두 채워져 있습니다"
    # 키 값은 보고서에 들어가지 않는다 — 필드 이름만.
    evidence "시크릿 ${SECRET}의 필드" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <숨김>
secretKey: <숨김>"
  else
    fail "시크릿 ${SECRET}에서 다음 필드가 채워지지 않았습니다:${MISSING}" \
         "README의 명령으로 시크릿을 다시 만드세요, 값은 대시보드에서 가져옵니다: Bucket -> builds -> Secrets"
  fi
else
  fail "클러스터에 시크릿 ${SECRET}이(가) 없습니다" \
       "시크릿을 만드세요: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (네 개 필드)"
fi

# --- 클러스터 내부에서 스토리지에 도달 가능한가 --------------------------------
# "Job이 다섯 번째 단계에서 실패했다"의 가장 흔한 원인은 키가 아니라, 클러스터에서
# 스토리지에 도달할 수 없다는 것이다. 이것을 빌드와 별도로 확인한다.
# 요청은 노트북이 아니라 파드에서 나간다: 노트북에는 자기만의 네트워크와 경로가 있고,
# 그것의 성공적인 응답은 빌드가 거기에 도달할 수 있는지에 대해 아무것도 말해주지 않는다.
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # -k를 일부러 쓰지 않음: 빌드는 인증서 검증과 함께 스토리지에 접속하고, 확인은
  # Job이 실패할 바로 그 지점에서 실패해야 하며, 만료된 인증서에 초록불을 내지 않아야 한다.
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "스토리지 ${EP}이(가) 클러스터 내부에서 응답합니다 (HTTP ${CODE})"
      evidence "스토리지 응답" "GET https://${EP}/ -> HTTP ${CODE}
여기서 코드 403과 404는 정상입니다: S3 루트에 대한 익명 요청은 거부되어야 마땅합니다."
      ;;
    5*)
      warn "스토리지 ${EP}이(가) 오류 HTTP ${CODE}로 응답합니다" \
           "빌드는 통과할 수 있지만, APK 업로드는 안 됩니다; 진행자에게 알리세요"
      ;;
    *)
      fail "스토리지 ${EP}이(가) 클러스터 내부에서 응답하지 않습니다" \
           "시크릿의 endpoint 필드를 확인하세요: https:// 없이, 끝에 슬래시 없이 이어야 합니다"
      ;;
  esac
else
  warn "스토리지 가용성을 확인하지 않습니다" \
       "먼저 endpoint 필드가 있는 시크릿 ${SECRET}이(가) 필요합니다"
fi

# --- Job 자체 --------------------------------------------------------------
# 우리는 Job이 존재한다는 사실이 아니라 .status.succeeded를 본다: 오브젝트는 즉시,
# 항상 성공적으로 생성되지만, 작업의 성공은 파드가 코드 0으로 완료되었음을 뜻한다.
# 파드의 상태는 별도로 살핀다, 왜냐하면 "아직 진행 중"과 "Pending에 걸림"은 사람에게는
# 서로 다른 소식이기 때문이다: 전자는 기다리라는 뜻이고, 후자는 기다려도 소용없으며
# 노드를 키워야 한다는 뜻이다.
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "클러스터에 Job ${JOB}이(가) 없습니다" \
       "빌드를 시작하세요: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB}이(가) 성공적으로 완료되었습니다"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
완료됨: ${DURATION:-알 수 없음}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "빌드 파드가 Pending에 걸려 있습니다 — 시작되지 않았고 스스로 시작되지도 않습니다" \
         "원인을 보세요: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; Insufficient memory인 경우 노드를 u1.large로 키우세요 — 방법은 README에 적혀 있습니다"
    evidence "빌드 파드 이벤트" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB}이(가) 오류로 완료되었습니다 (실패한 시도: ${FAILED})" \
         "로그의 마지막 줄을 보세요: kubectl logs job/${JOB} --tail=40"
    evidence "실패한 빌드 로그의 끝부분" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB}이(가) 아직 완료되지 않았습니다 (파드 상태: ${POD_PHASE:-알 수 없음})" \
         "첫 빌드는 회선에 따라 몇 분에서 15분 정도 걸립니다; 지켜보세요: kubectl logs -f job/${JOB}"
  fi

  # --- 내부에서 정확히 무슨 일이 일어났는가 ----------------------------------------
  # 성공한 Job 자체는 반환 코드가 0이라는 것 외에 아무것도 증명하지 않는다.
  # 그래서 로그를 열어 그 안에서 서로 다른 두 증거를 찾는다: BUILD SUCCESSFUL —
  # 컴파일이 끝까지 실행되었다는 것과, 스크립트가 파일을 버킷에 복사한 뒤에만 출력하는
  # 마커 줄 APK-UPLOADED. 후자가 전자보다 강하다: APK는 빌드되고도 곧 사라질 파드
  # 안에 그대로 남아 있을 수 있다.
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "빌드 로그를 사용할 수 없습니다" \
         "빌드 파드가 삭제되었거나 아직 생성되지 않았습니다; 로그가 없으면 APK가 실제로 빌드되었는지 확인할 수 없습니다"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK가 실제로 빌드되었습니다 (${GRADLE_LINE})"
    else
      fail "로그에 BUILD SUCCESSFUL 줄이 없습니다 — 컴파일이 끝까지 실행되지 않았습니다" \
           "FAILURE가 있는 첫 줄을 찾으세요: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK가 버킷에 도달했습니다: ${UPLOADED}"
      evidence "빌드 후 버킷 내용" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK는 빌드되었지만 버킷에 도달하지 않았습니다" \
           "로그의 끝부분을 보세요: kubectl logs job/${JOB} --tail=20; 대개는 bucketName이 원인입니다 — 거기에는 'builds'가 아니라 대시보드의 긴 이름이 필요합니다"
    fi
  fi
fi

# --- 노드에 이런 빌드를 위한 공간이 충분한가 --------------------------------
# 판결이 아니라 설명: Job이 들어가지 못했다면, 원인은 거의 항상 여기에 있다.
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "가장 큰 노드가 ${BIGGEST_H}의 메모리를 제공합니다 — 빌드에 충분합니다"
      else
        warn "가장 큰 노드가 겨우 ${BIGGEST_H}의 메모리만 제공합니다" \
             "빌드는 requests만으로 4Gi를 요구합니다; Job이 Pending에 걸려 있으면 노드 유형을 u1.large로 키우세요 — 방법은 README에 적혀 있습니다"
      fi
      ;;
    *)
      warn "노드에 사용 가능한 메모리가 1기가바이트 미만입니다 (${BIGGEST_H})" \
           "Android 빌드는 거기에 들어가지 않습니다, 노드 유형을 키우세요 — 방법은 README에 적혀 있습니다"
      ;;
  esac
  evidence "노드 리소스" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
