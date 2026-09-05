#!/usr/bin/env bash
# 랩 11 점검: Android 빌드가 끝까지 실행됐고, APK가 버킷까지 도달했는지 확인한다.
#
# 우리는 "Job이 생성됐다"가 아니라, 서로 다른 세 가지 주장을 검증한다. 이들은 서로 같지 않다:
#   1) Job이 성공적으로 끝났다,
#   2) 그 안에서 실제로 APK가 빌드됐다 (BUILD SUCCESSFUL),
#   3) 파일이 실제로 오브젝트 스토리지로 갔다 (APK-UPLOADED 마커).
# 누군가 스크립트를 고쳤다면 — Job이 성공적으로 끝나고도 아무것도 빌드하지 않을 수 있다.
#
# VM에서, 이 랩의 폴더에서, 학습용 클러스터 `lab` 접근으로 실행된다
# (관리 클러스터의 테넌트가 아니라 — 빌드는 클러스터 안에서 돌아간다):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# 스크립트는 클러스터에서 아무것도 바꾸지 않는다 — 읽기만 하고 HTTP 요청을 보낼 뿐이다.
# 정리 전에 실행하라: Job을 지우면 그 로그도 함께 지워지고, 로그가 없으면
# 위 세 주장 중 둘을 확인할 방법이 남지 않는다.

# 이 두 변수는 lib.sh가 가져간다 — 보고서 헤더와, 스크립트가 자기 옆에 놓는
# 파일 이름 report-<랩>-<날짜>.md 에 들어간다.
LAB_NAME="11-android"
LAB_TITLE="랩 11 · 클러스터에서 모바일 앱 빌드하기"
# 공용 점검 라이브러리: ok / fail / warn / evidence / finish, 클러스터 내부 요청,
# 보고서 기록이 모두 여기서 온다. 경로는 스크립트 자체가 있는 위치를 기준으로 계산하므로,
# 어느 디렉터리에서 실행해도 동일하게 동작한다.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# KUBECONFIG가 설정되지 않았으면 즉시 멈춘다. 그것 없이는 kubectl이 VM 자체에서
# 클러스터를 찾으려다 못 찾고, 모든 점검을 같은 오류로 줄줄이 실패시키는데,
# 거기서는 진짜 원인이 보이지 않는다.
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# 시크릿 키의 값. base64 -d 는 어디서나 같지 않다 (BSD 대 GNU),
# 그래서 python으로 디코딩한다 — 점검 라이브러리가 이미 그것을 필요로 한다.
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- 버킷 접근용 시크릿 -------------------------------------------
# 시크릿의 존재가 아니라, 그 안의 네 필드가 모두 채워졌는지를 점검한다.
# 시크릿은 --from-literal 네 개를 연달아 써서 손으로 만들며, 가장 흔한
# 문제는 값이 비었거나 빠지는 것이다: 그래도 객체는 성공적으로 생성되지만, 빌드가
# 이미 통과한 뒤 마지막 단계에서 실패한다. 지금 알아두는 편이 싸다.
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "시크릿 ${SECRET} 이(가) 제자리에 있고, 네 키가 모두 채워졌다"
    # 키 값은 보고서에 들어가지 않는다 — 필드 이름만 들어간다.
    evidence "시크릿 ${SECRET} 의 필드" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <숨김>
secretKey: <숨김>"
  else
    fail "시크릿 ${SECRET} 에 채워지지 않은 필드가 있다:${MISSING}" \
         "README의 명령으로 시크릿을 다시 만드세요. 값은 대시보드에서 가져옵니다: Bucket -> builds -> Secrets"
  fi
else
  fail "클러스터에 시크릿 ${SECRET} 이(가) 없다" \
       "시크릿을 만드세요: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (네 필드)"
fi

# --- 클러스터 내부에서 스토리지에 도달 가능한가 --------------------------------
# "Job이 다섯 번째 단계에서 실패" 하는 가장 흔한 이유는 키가 아니라, 클러스터에서
# 스토리지에 닿지 못하는 것이다. 이것을 빌드와 분리해서 점검한다.
# 요청은 VM이 아니라 파드에서 나간다: VM은 자기만의 네트워크와 경로를 가지며,
# VM의 성공 응답은 빌드가 거기에 닿을지에 대해 아무것도 말해주지 않는다.
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # 의도적으로 -k 없이: 빌드는 인증서 검증과 함께 스토리지로 가고, 점검은
  # Job이 실패하는 바로 그 지점에서 실패해야 하며, 만료된 인증서에 초록불을 주면 안 된다.
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "스토리지 ${EP} 이(가) 클러스터 내부에서 응답한다 (HTTP ${CODE})"
      evidence "스토리지 응답" "GET https://${EP}/ -> HTTP ${CODE}
여기서 403과 404 코드는 정상이다: S3 루트에 대한 익명 요청은 마땅히 거부되어야 한다."
      ;;
    5*)
      warn "스토리지 ${EP} 이(가) 오류 HTTP ${CODE} 로 응답한다" \
           "빌드는 통과할 수 있지만 APK 업로드는 안 됩니다; 진행자에게 알리세요"
      ;;
    *)
      fail "스토리지 ${EP} 이(가) 클러스터 내부에서 응답하지 않는다" \
           "시크릿의 endpoint 필드를 확인하세요: https:// 없이, 끝에 슬래시 없이여야 합니다"
      ;;
  esac
else
  warn "스토리지 가용성을 점검하지 않음" \
       "먼저 endpoint 필드가 있는 시크릿 ${SECRET} 이(가) 필요합니다"
fi

# --- Job 자체 ---------------------------------------------------------------
# Job의 존재 여부가 아니라 .status.succeeded 를 본다: 객체는 즉시 그리고 항상
# 성공적으로 생성되지만, 작업 성공은 파드가 코드 0으로 끝났음을 뜻한다.
# 파드 상태는 따로 살핀다. "아직 실행 중" 과 "Pending에 걸림" 은 사람에게
# 서로 다른 소식이기 때문이다: 전자는 기다리라는 뜻, 후자는 기다려도 소용없으니
# 노드를 키워야 한다는 뜻이다.
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "클러스터에 Job ${JOB} 이(가) 없다" \
       "빌드를 시작하세요: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} 이(가) 성공적으로 끝났다"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
완료됨: ${DURATION:-알 수 없음}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "빌드 파드가 Pending에 걸려 있다 — 시작되지 않았고 스스로 시작하지도 않는다" \
         "원인을 보세요: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; Insufficient memory 라면 노드를 u1.large 로 키우세요 — 방법은 README에 적혀 있습니다"
    evidence "빌드 파드 이벤트" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} 이(가) 오류로 끝났다 (실패한 시도: ${FAILED})" \
         "로그의 마지막 줄들을 보세요: kubectl logs job/${JOB} --tail=40"
    evidence "실패한 빌드 로그의 끝부분" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} 이(가) 아직 끝나지 않았다 (파드 상태: ${POD_PHASE:-알 수 없음})" \
         "첫 빌드는 회선에 따라 몇 분에서 15분 정도 걸립니다; 지켜보세요: kubectl logs -f job/${JOB}"
  fi

  # --- 안에서 정확히 무슨 일이 있었나 ----------------------------------------
  # 성공한 Job은 그 자체로 반환 코드 0 말고는 아무것도 증명하지 않는다.
  # 그래서 로그를 열어 서로 다른 두 증거를 찾는다: BUILD SUCCESSFUL —
  # 컴파일이 끝까지 갔다는 것, 그리고 마커 줄 APK-UPLOADED — 스크립트가
  # 파일을 버킷에 복사한 뒤에만 출력하는 것. 두 번째가 첫 번째보다 강하다: APK는
  # 빌드되고도 곧 사라질 파드 안에 그대로 남아 있을 수 있다.
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "빌드 로그를 사용할 수 없음" \
         "빌드 파드가 삭제됐거나 아직 생성되지 않았습니다; 로그 없이는 APK가 실제로 빌드됐음을 확인할 수 없습니다"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK가 실제로 빌드됐다 (${GRADLE_LINE})"
    else
      fail "로그에 BUILD SUCCESSFUL 줄이 없다 — 컴파일이 끝까지 가지 못했다" \
           "FAILURE가 있는 첫 줄을 찾으세요: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK가 버킷으로 갔다: ${UPLOADED}"
      evidence "빌드 후 버킷 내용" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 APK를 버킷에 업로드 중/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK는 빌드됐지만 버킷으로 가지 않았다" \
           "로그 끝부분을 보세요: kubectl logs job/${JOB} --tail=20; 대개 bucketName 이 원인입니다 — 'builds' 가 아니라 대시보드의 긴 이름이 필요합니다"
    fi
  fi
fi

# --- 노드가 이런 빌드를 담을 자리가 충분한가 --------------------------------
# 판결이 아니라 설명이다: Job이 들어가지 못했다면, 원인은 거의 언제나 여기에 있다.
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "가장 큰 노드가 메모리 ${BIGGEST_H} 를 제공한다 — 빌드에 충분하다"
      else
        warn "가장 큰 노드가 메모리를 ${BIGGEST_H} 밖에 제공하지 않는다" \
             "빌드는 requests만으로 4Gi를 요구합니다; Job이 Pending에 걸리면 노드 타입을 u1.large 로 키우세요 — 방법은 README에 적혀 있습니다"
      fi
      ;;
    *)
      warn "노드의 가용 메모리가 1기가바이트 미만이다 (${BIGGEST_H})" \
           "Android 빌드는 거기에 들어가지 않습니다, 노드 타입을 키우세요 — 방법은 README에 적혀 있습니다"
      ;;
  esac
  evidence "노드 리소스" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
