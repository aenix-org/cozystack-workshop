#!/usr/bin/env bash
# 랩 9 검증: ClickHouse에 출입 통과 기록이 저장되고 그것으로 보고서를 계산한다.
#
# 우리가 확인하는 것은 "서비스가 생성되었다"가 아니라 본질이다: 테이블이 존재하고, 행이
# 백만 개 이상이며, 데이터가 다양하고 뚜렷한 피크가 있으며, 월별 보고서가 밀리초 단위로
# 실행되고, 단일 컬럼에 대한 쿼리가 테이블의 작은 일부만 읽는다 — 즉 컬럼 지향 저장이
# 선언만 된 게 아니라 실제로 작동한다는 것이다.
#
# 실행 (새 터미널 창마다 변수를 다시 설정해야 한다):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX 대신 자신의 번호
#   export CH_PASSWORD='analyst 사용자의 비밀번호'
#   cd labs/09-clickhouse && ./check.sh
#
# 비밀번호는 출력되지 않으며 보고서에도 들어가지 않는다.
# 스크립트가 curl로 일회성 파드를 띄우므로 약 1분 걸린다.

# 이름과 제목은 공유 라이브러리에 필요하다: 라이브러리가 이것으로 보고서 아티팩트에 서명한다.
# lib.sh에는 ok/fail/warn/evidence/finish와 아래의 환경 검사가 들어 있다 — 열다섯 개의
# 검증 스크립트가 각자 제멋대로가 아니라 동일하게 출력하도록.
LAB_NAME="09-clickhouse"
LAB_TITLE="랩 9 · 백만 행 위에서의 분석"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 두 검사 모두 클러스터 접근 파일이나 테넌트 번호가 설정되지 않았으면 명확한 메시지와 함께
# 스크립트를 중단한다. 이것들이 없으면 이후로 kubectl 오류가 계속 쏟아질 것이다.
need_kubeconfig
need_tenant

# 참가자는 COZY_TENANT를 `workshop07`로 설정하지만, 네임스페이스 이름은
# `tenant-workshop07`이다. 두 표기 모두 받아들인다.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 기본 이름은 랩에서와 동일하다. ${X:-값} 형태는 "환경 변수를 취하되, 없으면 값을 대입한다"는
# 뜻이다: 앱을 다르게 이름 지었다면 — CH_APP=이름 ./check.sh 로 실행하면 되고, 스크립트를
# 수정할 필요는 없다.
# 주소는 클러스터 내부에서 접근하는 내부 주소다: 8123은 ClickHouse HTTP 인터페이스 포트다.
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "ClickHouse 주소" "$CH_URL"

# --- 1. 서비스가 응답이라도 하는가 -------------------------------------------
# /ping은 비밀번호가 필요 없으므로 이것이 가장 먼저이자 가장 저렴한 검사다:
# "연결 없음"과 "연결은 됨, 비밀번호가 틀림"을 구분해 준다.
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse가 테넌트 내부 주소로 응답한다"
else
  fail "ClickHouse가 ${CH_HOST} 주소로 응답하지 않는다" \
       "COZY_TENANT의 테넌트 번호와 앱 이름을 확인하세요(기본값 'analytics'; 아니면 CH_APP=이름 ./check.sh); 대시보드에서 앱이 준비 완료 상태여야 합니다"
  finish
  exit $?
fi

# 이 아래의 모든 것은 데이터베이스 로그인이 필요하다. 비밀번호가 없으면 스크립트는 추측하지도
# 침묵하지도 않고, 데이터베이스 내용을 검사하지 못했다고 정직하게 말하고 보고서를 마친다:
# 그렇지 않으면 참가자는 검사가 통과됐다고 판단할 것이다.
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "CH_PASSWORD 변수가 설정되지 않아 데이터베이스 내용을 검사하지 못했다" \
       "export CH_PASSWORD='${CH_USER} 사용자의 비밀번호' 후 스크립트를 다시 실행하세요; 비밀번호는 대시보드의 시크릿 clickhouse-${CH_APP}-credentials 에서 볼 수 있습니다"
  finish
  exit $?
fi

# 표준 입력으로 SQL을 실행하고 응답을 반환한다.
# in_cluster_curl이 아니라 별도 함수인 이유: 쿼리가 POST 본문으로 나가는데, 본문에는
# 표준 입력이 필요하지만 공유 함수에는 그것이 없기 때문이다.
# 비밀번호는 인자가 아니라 임시 Secret에서 온 환경 변수로 파드에 들어간다:
# args에 들어가는 것은 `get pods` 권한이 있는 누구에게나 보이고, etcd에 남으며, 감사
# 로그에도 노출된다. 랩 자체가 바로 이것을 다룬다 — 반대로 하는 스크립트로 그것을 검증한다면
# 이중 잣대가 될 것이다.
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# JSON 형식 응답의 statistics 블록에서 숫자를 뽑아낸다.
chstat() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
key = sys.argv[1]
src = d.get("statistics", {}) if key in ("elapsed",) else d
val = src.get(key, d.get("statistics", {}).get(key))
if val is None:
    sys.exit(1)
print(val)
' "$1" 2>/dev/null
}

# --- 2. 테이블이 존재한다 ---------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "테이블 ${CH_TABLE} 이(가) 존재한다"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse가 ${CH_USER} 사용자의 비밀번호를 받아들이지 않았다" \
         "대시보드에서 비밀번호를 확인하세요: 앱 ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "테이블 ${CH_TABLE} 이(가) 없다" \
         "생성하세요: ch < 01-schema.sql (스키마 설명 — README 참조)"
  fi
  finish
  exit $?
fi

# --- 3. 데이터가 얼마나 많고 얼마나 다양한가 -------------------------------
# 여섯 개 대신 한 개의 쿼리로: ch_query 호출마다 파드를 띄우므로, 여섯 개의 파드를 연달아
# 띄우면 아무 이유 없이 검사가 1분짜리 대기로 변할 것이다.
STATS="$(ch_query <<SQL
SELECT
    (SELECT count() FROM ${CH_TABLE}),
    (SELECT uniqExact(entrance) FROM ${CH_TABLE}),
    (SELECT uniqExact(pass_type) FROM ${CH_TABLE}),
    (SELECT uniqExact(toStartOfMonth(created_at)) FROM ${CH_TABLE}),
    (SELECT max(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT min(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT sum(data_uncompressed_bytes) FROM system.columns
      WHERE database = currentDatabase() AND table = '${CH_TABLE}')
SQL
)"

ROWS="$(printf '%s' "$STATS" | awk 'NR==1{print $1}')"
UNIQ_ENT="$(printf '%s' "$STATS" | awk 'NR==1{print $2}')"
UNIQ_TYPE="$(printf '%s' "$STATS" | awk 'NR==1{print $3}')"
UNIQ_MONTH="$(printf '%s' "$STATS" | awk 'NR==1{print $4}')"
PEAK_MAX="$(printf '%s' "$STATS" | awk 'NR==1{print $5}')"
PEAK_MIN="$(printf '%s' "$STATS" | awk 'NR==1{print $6}')"
TABLE_BYTES="$(printf '%s' "$STATS" | awk 'NR==1{print $7}')"

for v in ROWS UNIQ_ENT UNIQ_TYPE UNIQ_MONTH PEAK_MAX PEAK_MIN TABLE_BYTES; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*) eval "$v=0" ;;
  esac
done

if [ "$ROWS" -ge 1000000 ]; then
  ok "테이블에 ${ROWS} 행이 있다 — 백만 개가 생성되었다"
else
  fail "테이블에 ${ROWS} 행이 있으며, 백만 개가 기대되었다" \
       "생성기를 실행하세요: ch < 02-generate.sql (생성기 설명 — README 참조)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "데이터가 다양하다: 출입구 ${UNIQ_ENT}, 통과권 유형 ${UNIQ_TYPE}, 월 ${UNIQ_MONTH}"
else
  fail "데이터가 단조롭다: 출입구 ${UNIQ_ENT}, 유형 ${UNIQ_TYPE}, 월 ${UNIQ_MONTH}" \
       "이런 데이터로는 보고서가 아무것도 보여주지 못합니다; 재생성하세요: TRUNCATE TABLE ${CH_TABLE} 후 ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "데이터에 뚜렷한 시간대별 피크가 있다 (가장 붐비는 시간 대 가장 한산한 시간 — 최소 두 배)"
  evidence "시간대별 분포" "시간당 최대: ${PEAK_MAX}
시간당 최소: ${PEAK_MIN}"
else
  warn "시간대별 피크가 보이지 않는다: 최대 ${PEAK_MAX}, 최소 ${PEAK_MIN}" \
       "이런 데이터로는 '언제가 피크인가' 보고서가 무의미합니다; 생성기가 끝까지 완료됐는지 확인하세요"
fi

# --- 4. 월별 보고서가 빠르게 계산된다 --------------------------------------
REPORT="$(ch_query <<SQL
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM ${CH_TABLE}
GROUP BY month
ORDER BY month
FORMAT JSON
SQL
)"

ELAPSED="$(printf '%s' "$REPORT" | chstat elapsed)"
READ_ROWS="$(printf '%s' "$REPORT" | chstat rows_read)"

if [ -z "$ELAPSED" ]; then
  fail "월별 보고서가 실행되지 않았다" \
       "수동으로 실행하세요: ch < 03-report.sql 후 오류 텍스트를 보세요"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # 임계값을 랩이 약속하는 것에 가깝게 유지한다. 기존의 5초는 4초짜리 보고서를 성공으로
  # 쳤다 — 랩 머리말에는 "밀리초 단위로 계산된다"고 쓰여 있는데도. 스크립트는 검사하지
  # 않은 것을 확인해 주어서는 안 된다.
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "월별 보고서가 ${MS} ms 만에 계산되었고, 읽은 행: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "월별 보고서가 ${MS} ms 걸렸다 — 랩이 말하는 자릿수가 아니다" \
         "여유 있는 스탠드에서는 백만 행이 수십 밀리초 안에 들어갑니다; 서비스가 옆의 부하로 바쁘지 않은지 확인하고 재시도하세요"
  else
    warn "월별 보고서가 ${MS} ms 만에 계산되었다 — 예상보다 느리지만 합리적 범위 안이다" \
         "바쁜 스탠드에서는 이런 일이 있습니다; 여유 있는 스탠드에서는 이런 보고서가 수십 밀리초 안에 들어갑니다"
  fi
  evidence "월별 보고서" "시간: ${MS} ms
읽은 행: ${READ_ROWS}"
fi

# --- 5. 컬럼 지향 저장이 선언만 된 게 아니라 실제로 작동한다 ----------------
# 쿼리가 작은 컬럼 하나만 건드린다. 저장이 컬럼 지향이라면, 읽은 양이 전체 테이블 크기보다
# 눈에 띄게 적을 것이다.
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# 두 값 모두 비압축이다: 쿼리 통계의 `bytes_read`는 압축 해제된 용량이고, system.columns에서는
# `data_uncompressed_bytes`를 취한다. `data_compressed_bytes`와 비교하면 디스크상 크기 대비
# 비율이 나와서 참가자에게 잘못된 숫자를 출력했다 — 잘 압축된 테이블에서는 그것이 백 퍼센트를
# 넘길 수도 있었다.
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "단일 컬럼 읽기" "읽은 바이트: ${NARROW_BYTES}
전체 테이블 비압축, 바이트: ${TABLE_BYTES}
비율: ${SHARE}%"
  # 그냥 "전체보다 적음"이 아니라 임계값이다. 일곱 개 중 좁은 컬럼 하나는 한 자릿수 퍼센트가
  # 나와야 한다; "100% 대신 99%"는 형식적으로는 적지만 아무것도 증명하지 못한다 — 그리고
  # 바로 그것이 랩이 제목에 내세우는 주장이다.
  if [ "$SHARE" -le 25 ]; then
    ok "단일 컬럼 쿼리가 테이블 데이터의 ${SHARE}%를 읽었다 — 컬럼 지향 저장이 작동한다"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "단일 컬럼 쿼리가 테이블 데이터의 ${SHARE}%를 읽었다 — 전체보다는 적지만 이득이 예상보다 소박하다" \
         "한 자릿수 퍼센트가 기대되었습니다; 쿼리가 여러 컬럼이 아니라 좁은 컬럼 하나에 접근하는지 확인하세요"
  else
    warn "단일 컬럼 쿼리가 전체 테이블 이상을 읽었다" \
         "아주 작은 테이블에서는 이런 일이 있습니다; 정말로 백만 행이 있는지 확인하세요"
  fi
else
  warn "좁은 쿼리가 얼마나 읽었는지 측정할 수 없었다" \
       "수동으로 실행하세요: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON 후 bytes_read를 보세요"
fi

# finish는 요약을 출력하고 보고서 아티팩트를 파일에 저장한다; 검사 중 하나라도 실패하면
# 반환 코드는 0이 아니다.
finish
