#!/usr/bin/env bash
# 将所有实验的结果汇总到一个文件中，以便上传到认证系统。
#
# 重要特性：本脚本不会重新运行任何东西。它只采集每个实验在你提交时所记录的内容。
# 否则会出现这种情况：实验本身要求你清理干净，而租户配额也不允许你把所有服务持续运行
# 数周——于是最后的复查就会把三周前你诚实完成的工作判为失败。
#
#   ./bundle.sh                 收集找到的所有结果
#   ./bundle.sh --rerun 07-redis  重做单个实验并更新其结果
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?请指定一个实验，例如：./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "没有这个实验：$lab"; exit 1; }
  echo "正在重做 $lab…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "结果已更新，现在请不带参数运行 ./bundle.sh"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
未找到任何结果。

每个实验会在你运行其中的 ./check.sh 时保存自己的结果。
请至少完成一个实验并运行检查——然后再回到这里。

如果你是在另一台机器上完成的实验，请从那里复制
~/.cozystack-labs/results 文件夹，或指定路径：COZY_LAB_RESULTS=/path ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# 总共存在多少个实验——通过是否存在检查脚本来统计。
# 第十六个（“周一该做什么”）没有脚本：它是一个文本
# 练习，不计入成绩。
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
        problems.append(f"{os.path.basename(path)}: 无法读取 ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: 未知的格式版本")
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
    "cluster_uids": sorted(uids),          # 多于一个——在不同的集群上完成
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# 同样的内容以纯文本形式呈现——好让人能看清自己要发送的是什么。
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Cozystack 实验结果\n")
    fh.write("收集于：%s\n\n" % bundle["generated_at"])
    fh.write("在 %d 个实验中通过了 %d 个\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "无结果"
        elif rec["verdict"] == "passed":
            mark = "已通过"
            extra = "检查项：%d" % len(rec["checks"])
        else:
            mark = "未通过"
            extra = "失败：%d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\n集群数：%d。Kubernetes 版本：%s\n"
             % (len(uids), ", ".join(sorted(versions)) or "无法确定"))
    fh.write("\n文件中只包含检查项的标识符及其结果。\n"
             "其中没有任何地址、名称或日志内容。\n")

print("在 %d 个实验中通过了 %d 个。" % (len(passed), len(all_labs)))
if failed:
    print("未通过：%s" % ", ".join(failed))
if missing:
    print("无结果：%s" % ", ".join(missing))
if len(uids) > 1:
    print("\n注意：结果采集自 %d 个不同的集群。这是允许的，"
          "但上传时该结果集会被标记。" % len(uids))
for p in problems:
    print("  问题：%s" % p)
print("\n待上传文件：%s" % out_path)
print("同一内容的纯文本：  %s" % txt)
print("发送前请查看该文本文件——其中显示了所有将要发出的内容。")
PYEOF
