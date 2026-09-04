#!/usr/bin/env bash
# 랩 10 검증: MongoDB에 다양한 형태의 출입증이 저장되어 있고 이를 기준으로 검색한다.
#
# «서비스가 생성됨»이 아니라 본질을 검증한다: 컬렉션에 네 가지 형태의 문서가 모두
# 있고, 중첩 필드 및 리스트 내부 검색이 동작하며, 드문 필드에 희소 인덱스가
# 구축되어 있고, 스키마 검증기가 켜져 있으며, 타입이 없는 문서가 남아 있지 않다.
#
# 실행 (새 터미널 창마다 변수를 다시 설정한다):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # XX 대신 자신의 번호
#   export MONGO_PASSWORD='passapp 사용자의 비밀번호'
#   cd labs/10-mongodb && ./check.sh
#
# 비밀번호는 출력되지 않으며 보고서에 포함되지 않는다.
# 스크립트는 일회용 파드를 띄우므로 약 1분 정도 걸린다.

# 이름과 제목은 공용 라이브러리에 필요하다: 이를 사용해 보고서 아티팩트에 서명한다.
# lib.sh에는 ok/fail/warn/evidence/finish와 아래의 환경 검사가 들어 있다 — 열다섯 개의
# 검증 스크립트가 제각각이 아니라 동일하게 출력하도록.
LAB_NAME="10-mongodb"
LAB_TITLE="랩 10 · 문서 저장소"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# 두 검사 모두 클러스터 접근 파일이나 테넌트 번호가 설정되지 않으면 명확한 메시지와
# 함께 스크립트를 중단한다. 이것들이 없으면 이후 kubectl 오류가 쏟아진다.
need_kubeconfig
need_tenant

# 참가자는 COZY_TENANT를 `workshop07`로 설정하지만 namespace는
# `tenant-workshop07`이다. 두 표기 모두 허용한다.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# 기본 이름은 랩과 동일하다. ${X:-값} 표기는 «환경 변수를 취하고, 없으면 값을
# 대입»한다는 의미다: 애플리케이션을 다르게 이름 지었다면 MONGO_APP=이름 ./check.sh로
# 실행하면 되고, 스크립트를 수정할 필요는 없다.
# 주소는 내부용으로 클러스터 자체에서 사용한다; 이름의 rs0은 우리의 유일한 복사본이
# 사는 레플리카 셋이다.
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "MongoDB 주소" "$MONGO_HOST"

# --- 1. 포트까지 연결이 되는지 ---------------------------------------------
# MongoDB는 자신의 포트에서 HTTP 요청에 대해 여기는 브라우저가 아니라 드라이버로
# 접근한다는 명확한 문구로 응답한다. «이름이 해석되지 않음 / 포트가 닫힘»과
# «연결은 되지만 자격 증명이 틀림»을 구분하기에 이것으로 충분하다.
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB가 테넌트의 내부 주소로 응답합니다"
else
  fail "주소 ${MONGO_HOST}로 MongoDB에 연결되지 않음" \
       "COZY_TENANT의 테넌트 번호와 애플리케이션 이름을 확인하세요 (기본값 'passes'; 그 외에는 MONGO_APP=이름 ./check.sh); 대시보드에서 애플리케이션이 준비 상태여야 합니다"
  finish
  exit $?
fi

# 이후의 모든 것은 데이터베이스 로그인이 필요하다. 비밀번호가 없으면 스크립트는
# 추측하거나 침묵하지 않고, 데이터베이스 내용이 검증되지 않았다고 정직하게 말하고
# 보고서를 마무리한다: 그렇지 않으면 참가자가 검증을 통과했다고 판단할 것이다.
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "MONGO_PASSWORD 변수가 설정되지 않아 데이터베이스 내용이 검증되지 않았습니다" \
       "export MONGO_PASSWORD='${MONGO_USER} 사용자의 비밀번호' 후 스크립트를 다시 실행하세요"
  finish
  exit $?
fi

# 비밀번호는 퍼센트 인코딩된다: @ : / ? # % 문자가 없으면 연결 문자열을 망가뜨려서,
# 사람은 «잘못된 비밀번호» 대신 알 수 없는 파싱 오류를 받게 된다.
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ 연결 문자열은 비밀번호를 포함하며 파드 인자로 전달된다. 이는 의도적인 절충이다:
# check/lib.sh의 `in_cluster_with_secrets`를 참고 — 안전한 경로는 있지만, 과도한
# 복잡화 없이는 여러 줄 --eval과 호환되지 않는다. 파드는 몇 초간 살아 있다가
# 스스로 삭제된다; 비밀번호는 보고서에 포함되지 않는다. 운영 스크립트에서는 이렇게 하지 마세요.
#
# 모든 검사를 한 번에: 각 호출은 파드를 띄우므로, 열 개의 파드를 연달아 띄우면
# 검증이 아무 이유 없이 몇 분씩 기다리게 된다.
# 밖으로는 하나의 JSON 줄이 나가고, 이후 python이 이를 파싱한다.
# securityContext가 있는 `--overrides`: 이것이 없으면 `restricted` 프로파일을 가진
# 클러스터에서 파드가 생성되지 않고, 랩은 참가자와 무관한 이유로 실패한다.
# `--command --`는 유지된다: kubectl은 이를 보안 필드만 설정된 override와 결합한다.
# mongosh용 프로그램. 그 안의 큰따옴표는 안전하다: 텍스트는 python을 통해 밖으로
# 나가고 python이 스스로 따옴표 처리하며, 데이터베이스와 컬렉션 이름은 아래 마커로
# 대입된다.
MONGO_EVAL=$(cat <<'JSEOF'

var out = {};
try {
  var c = db.getSiblingDB("__DB__").getCollection("__COLL__");
  out.ok = 1;
  out.total = c.countDocuments({});
  out.types = c.distinct("type").length;
  out.withCar = c.countDocuments({ "car.plate": { $exists: true } });
  out.withArray = c.countDocuments({
    $or: [ { entrances: { $exists: true } }, { members: { $exists: true } } ]
  });
  out.nested = c.countDocuments({ "members.name": { $exists: true } });
  out.typeless = c.countDocuments({ type: { $exists: false } });
  var idx = c.getIndexes();
  out.indexes = idx.map(function (i) { return i.name; });
  out.sparse = idx.filter(function (i) {
    return i.sparse === true || i.partialFilterExpression !== undefined;
  }).map(function (i) { return i.name; });
  var info = db.getSiblingDB("__DB__").getCollectionInfos({ name: "__COLL__" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
JSEOF
)
MONGO_EVAL="${MONGO_EVAL//__DB__/$MONGO_DB}"
MONGO_EVAL="${MONGO_EVAL//__COLL__/$MONGO_COLL}"

# 컨테이너 명령은 `--command --`에 밖에 남지 않고 override 안에 넣는다.
# kubectl은 override를 JSON merge patch로 적용하며, 그 안에서 containers 배열은 통째로
# 교체된다: 밖에서 설정한 `--command`는 파드에 도달하지 못하고, mongosh 대신 이미지의
# 기본 프로세스 — 즉 데이터베이스 자체가 실행될 것이다. check/lib.sh에서도 같은 방식으로 되어 있다.
MONGO_SC="$(python3 - "$MONGO_URI" "$MONGO_EVAL" <<'PYEOF'
import json, sys
uri, script = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {
  "securityContext": {"runAsNonRoot": True, "runAsUser": 999,
                      "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "mongo-check", "image": "mongo:8.0", "stdin": True,
                  "securityContext": {"allowPrivilegeEscalation": False,
                                      "capabilities": {"drop": ["ALL"]}},
                  "command": ["mongosh", "--quiet", uri, "--eval", script]}]}}))
PYEOF
)"

SUMMARY="$(kubectl run "mongo-check" --rm -i --restart=Never --quiet \
  --pod-running-timeout=90s --overrides="$MONGO_SC" \
  --image=mongo:8.0 </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

# mongosh가 출력한 JSON 문자열에서 필드를 꺼낸다. 리스트는 참가자에게 있는 그대로
# 보여줄 수 있도록 쉼표로 연결된다.
mget() {
  printf '%s' "$SUMMARY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v if not isinstance(v, list) else ", ".join(str(x) for x in v))
' "$1" 2>/dev/null
}

# 같지만 숫자용: 예상치 못한 값은 0으로 바뀐다, 그렇지 않으면 아래 비교가 명확한
# FAIL 대신 산술 오류로 실패한다.
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# 응답이 전혀 없거나 mongosh가 오류를 보고했다면 — 더 검증할 것이 없다.
# 인증 거부는 다른 오류와 분리된다: 그 흔한 원인은 authSource=admin을 잊은 것이며,
# 힌트는 바로 그것을 가리켜야 한다.
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB가 ${MONGO_USER} 사용자의 자격 증명을 수락하지 않았습니다" \
           "비밀번호와 연결 문자열에 authSource=admin이 있는지 확인하세요: 사용자는 admin 데이터베이스에 생성되어 있고, 권한은 ${MONGO_DB}에 부여되어 있습니다" ;;
    *)
      fail "${MONGO_DB} 데이터베이스에 대한 쿼리를 실행하지 못했습니다${ERR:+: $ERR}" \
           "수동으로 확인하세요: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "${MONGO_USER} 사용자로 ${MONGO_DB} 데이터베이스에 연결이 동작합니다"

# --- 2. 문서가 존재한다 -----------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "${MONGO_COLL} 컬렉션의 문서 수: ${TOTAL}"
else
  fail "${MONGO_COLL} 컬렉션에 문서가 ${TOTAL}개뿐이며, 최소 네 개가 예상되었습니다" \
       "출입증을 로드하세요: mo < passes.js (파일 설명은 README에)"
fi

# --- 3. 형태가 실제로 다르다 ------------------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "컬렉션에 ${TYPES}가지의 서로 다른 출입증 타입이 있습니다"
else
  fail "서로 다른 출입증 타입이 ${TYPES}가지뿐이며, 네 가지가 예상되었습니다" \
       "passes.js가 전부 로드되었는지 확인하세요: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "중첩 객체(car.plate)가 있는 문서가 있습니다: ${WITH_CAR}"
else
  fail "중첩 car 객체가 있는 문서가 하나도 없습니다" \
       "차량 출입증이 로드되지 않았습니다; mo < passes.js를 다시 실행하세요"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "리스트(entrances 및 members)가 있는 문서가 있습니다: ${WITH_ARRAY}"
else
  fail "리스트가 있는 문서가 ${WITH_ARRAY}개이며, 최소 두 개가 예상되었습니다" \
       "주간 및 그룹 출입증이 로드되지 않았습니다; mo < passes.js를 다시 실행하세요"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "객체 리스트 내부 검색(members.name)이 문서를 찾습니다"
else
  fail "members.name 검색이 아무것도 찾지 못했습니다" \
       "참가자 리스트가 있는 그룹 출입증이 로드되지 않았습니다; mo < passes.js를 다시 실행하세요"
fi

evidence "컬렉션 구성" "문서: ${TOTAL}
서로 다른 출입증 타입: ${TYPES}
중첩 car 객체 포함: ${WITH_CAR}
리스트 포함: ${WITH_ARRAY}"

# --- 4. 드문 필드의 인덱스 --------------------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "희소(또는 부분) 인덱스가 구축되었습니다: ${SPARSE}"
  evidence "컬렉션 인덱스" "전체: ${IDX}
희소: ${SPARSE}"
else
  fail "희소 인덱스가 없습니다 — 차량 번호 검색이 전체 스캔으로 진행됩니다" \
       "생성하세요: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "컬렉션 인덱스" "전체: ${IDX}"
fi

# --- 5. 스키마 검증기가 켜져 있다 ------------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "스키마 검증기가 켜져 있습니다 (위반 시 동작: ${ACTION:-기본값})"
  if [ "$ACTION" = "warn" ]; then
    warn "검증기가 경고만 하고 문서는 수락합니다" \
         "운영 컬렉션에는 validationAction: error가 필요합니다"
  fi
else
  fail "스키마 검증기가 켜져 있지 않습니다 — 필드 이름의 오타가 조용히 통과됩니다" \
       "켜세요: mo < validator.js (예측 가능한 실패의 설명은 README를 참고)"
fi

# --- 6. 손상된 문서 제거됨 --------------------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "type 필드가 없는 문서가 남아 있지 않습니다"
else
  fail "컬렉션에 type 필드가 없는 문서가 ${TYPELESS}개 있습니다 — 경비가 이를 보지 못합니다" \
       "찾아서 제거하세요: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish는 결과를 출력하고 보고서 아티팩트를 파일에 저장한다; 검사 중 하나라도
# 실패하면 반환 코드는 0이 아니다.
finish
