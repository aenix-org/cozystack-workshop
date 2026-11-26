#!/usr/bin/env bash
# Collects the results of all labs into a single file for upload to the certification system.
#
# Important property: the script DOES NOT RE-RUN ANYTHING. It takes what each lab
# recorded at the moment you submitted it. Otherwise you would get this: the labs
# themselves tell you to clean up after yourself, and the tenant quota won't let you
# keep all the services running for weeks — so a final re-check would show a failure
# for work honestly done three weeks ago.
#
#   ./bundle.sh                 collect everything found
#   ./bundle.sh --rerun 07-redis  re-run a single lab and update its result
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?specify a lab, for example: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "no such lab: $lab"; exit 1; }
  echo "re-running $lab…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "result updated, now run ./bundle.sh without options"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
No results found.

Each lab saves its result when you run ./check.sh in it.
Complete at least one and run the check — then come back here.

If you ran the labs on a different machine, copy the folder
~/.cozystack-labs/results from there or specify the path: COZY_LAB_RESULTS=/path ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# How many labs exist at all — counted by the presence of a check script.
# The sixteenth one ("What to do on Monday") has no script: it is a text
# exercise, and it does not count toward the grade.
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
        problems.append(f"{os.path.basename(path)}: cannot be read ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: unknown format version")
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
    "cluster_uids": sorted(uids),          # more than one — done on different clusters
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# The same thing in plain text — so a person can see what they are sending.
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Cozystack lab results\n")
    fh.write("Collected: %s\n\n" % bundle["generated_at"])
    fh.write("Passed %d of %d labs\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "no result"
        elif rec["verdict"] == "passed":
            mark = "passed"
            extra = "checks: %d" % len(rec["checks"])
        else:
            mark = "not passed"
            extra = "failed: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\nClusters: %d. Kubernetes versions: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "not determined"))
    fh.write("\nOnly check identifiers and their outcomes go into the file.\n"
             "No addresses, no names, no log contents are in it.\n")

print("Passed %d of %d labs." % (len(passed), len(all_labs)))
if failed:
    print("Not passed: %s" % ", ".join(failed))
if missing:
    print("No result: %s" % ", ".join(missing))
if len(uids) > 1:
    print("\nWarning: results were taken from %d different clusters. This is allowed, "
          "but the set will be flagged on upload." % len(uids))
for p in problems:
    print("  problem: %s" % p)
print("\nFile for upload: %s" % out_path)
print("Same as plain text:  %s" % txt)
print("Review the text file before sending — it shows everything that goes out.")
PYEOF
