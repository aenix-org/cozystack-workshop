#!/usr/bin/env bash
# 모든 랩의 결과를 인증 시스템에 업로드할 하나의 파일로 모읍니다.
#
# 중요한 특성: 이 스크립트는 아무것도 다시 실행하지 않습니다. 각 랩이 제출한
# 시점에 기록해 둔 내용을 그대로 가져옵니다. 그렇지 않으면 이렇게 됩니다: 랩들은
# 스스로 뒷정리를 하라고 요구하고, 테넌트 쿼터는 모든 서비스를 몇 주씩 켜 두도록
# 허용하지 않습니다 — 그래서 마지막에 다시 검사하면 3주 전에 정직하게 완료한
# 작업이 실패로 나올 것입니다.
#
#   ./bundle.sh                 발견된 모든 것을 모으기
#   ./bundle.sh --rerun 07-redis  하나의 랩을 다시 진행하고 결과를 갱신
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?랩을 지정하세요, 예: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "그런 랩이 없습니다: $lab"; exit 1; }
  echo "$lab 다시 진행 중…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "결과가 갱신되었습니다, 이제 옵션 없이 ./bundle.sh 를 실행하세요"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
결과를 찾을 수 없습니다.

각 랩은 그 안에서 ./check.sh 를 실행할 때 결과를 저장합니다.
최소한 하나를 완료하고 검사를 실행하세요 — 그런 다음 여기로 돌아오세요.

다른 컴퓨터에서 랩을 진행했다면, 그곳에서 폴더
~/.cozystack-labs/results 를 복사하거나 경로를 지정하세요: COZY_LAB_RESULTS=/경로 ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# 랩이 전부 몇 개인지 — 검사 스크립트가 있는지로 셉니다.
# 열여섯 번째("월요일에 무엇을 할 것인가")에는 스크립트가 없습니다: 이것은 텍스트
# 연습 문제이고, 성적에는 반영되지 않습니다.
all_labs = sorted(
    os.path.basename(os.path.dirname(p))
    for p in glob.glob(os.path.join(repo, "labs", "*", "check.sh"))
)

labs, uids, versions, problems = [], set(), set(), []
for path in sorted(glob.glob(os.path.join(results_dir, "result-*.json"))):
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception as exc:
        problems.append(f"{os.path.basename(path)}: 읽을 수 없음 ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: 알 수 없는 형식 버전")
        continue
    labs.append(d)
    if d.get("env", {}).get("cluster_uid"):
        uids.add(d["env"]["cluster_uid"])
    if d.get("env", {}).get("kubernetes_server_version"):
        versions.add(d["env"]["kubernetes_server_version"])

passed = sorted(d["lab"] for d in labs if d["verdict"] == "passed")
failed = sorted(d["lab"] for d in labs if d["verdict"] != "passed")
missing = [l for l in all_labs if l not in {d["lab"] for d in labs}]

bundle = {
    "schema_version": 1,
    "kind": "cozystack-labs-bundle",
    "generated_at": datetime.datetime.now(datetime.timezone.utc)
                      .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "labs_total": len(all_labs),
    "labs_passed": len(passed),
    "cluster_uids": sorted(uids),          # 하나보다 많으면 — 서로 다른 클러스터에서 진행함
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# 같은 내용을 일반 텍스트로 — 사람이 무엇을 보내는지 볼 수 있도록.
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Cozystack 랩 결과\n")
    fh.write("수집됨: %s\n\n" % bundle["generated_at"])
    fh.write("%d개 랩 중 %d개 통과\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "결과 없음"
        elif rec["verdict"] == "passed":
            mark = "통과"
            extra = "검사: %d" % len(rec["checks"])
        else:
            mark = "미통과"
            extra = "실패: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\n클러스터: %d개. Kubernetes 버전: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "확인되지 않음"))
    fh.write("\n파일에는 검사 식별자와 그 결과만 들어갑니다.\n"
             "주소도, 이름도, 로그 내용도 이 파일에는 없습니다.\n")

print("%d개 랩 중 %d개 통과." % (len(passed), len(all_labs)))
if failed:
    print("미통과: %s" % ", ".join(failed))
if missing:
    print("결과 없음: %s" % ", ".join(missing))
if len(uids) > 1:
    print("\n주의: 결과가 %d개의 서로 다른 클러스터에서 수집되었습니다. 이것은 허용되지만, "
          "업로드 시 이 세트에 표시가 붙습니다." % len(uids))
for p in problems:
    print("  문제: %s" % p)
print("\n업로드할 파일: %s" % out_path)
print("동일한 내용의 일반 텍스트:  %s" % txt)
print("보내기 전에 텍스트 파일을 살펴보세요 — 나가는 모든 내용이 그 안에 보입니다.")
PYEOF
