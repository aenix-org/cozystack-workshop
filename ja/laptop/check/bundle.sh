#!/usr/bin/env bash
# すべてのラボの結果を1つのファイルにまとめ、認定システムへのアップロード用にする。
#
# 重要な性質: このスクリプトは何も再実行しない。各ラボがあなたが提出した時点で
# 記録した内容をそのまま取り出す。そうしないと次のようなことが起きる: ラボ自体が
# 後片付けをするよう指示し、テナントのクォータは全サービスを何週間も維持させて
# くれない — そのため最後の再チェックでは、3週間前に誠実にやり終えた作業が
# 失敗と表示されてしまう。
#
#   ./bundle.sh                 見つかったすべてを収集する
#   ./bundle.sh --rerun 07-redis  1つのラボをやり直して結果を更新する
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?ラボを指定してください、例: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "そのようなラボはありません: $lab"; exit 1; }
  echo "$lab をやり直しています…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "結果を更新しました。オプションなしで ./bundle.sh を実行してください"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
結果が見つかりません。

各ラボは、その中で ./check.sh を実行したときに結果を保存します。
少なくとも1つを完了してチェックを実行してから、ここに戻ってきてください。

別のマシンでラボを実施した場合は、そこから
~/.cozystack-labs/results フォルダをコピーするか、パスを指定してください: COZY_LAB_RESULTS=/パス ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# ラボが全部でいくつあるか — チェックスクリプトの有無で数える。
# 16番目（「月曜日に何をするか」）にはスクリプトがない: これはテキストの
# 演習であり、得点には含まれない。
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
        problems.append(f"{os.path.basename(path)}: 読み取れません ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: 不明なフォーマットバージョン")
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
    "cluster_uids": sorted(uids),          # 複数ある場合 — 異なるクラスターで実施した
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# 同じ内容をプレーンテキストで — 人が何を送っているか見えるように。
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Cozystack ラボ結果\n")
    fh.write("収集日時: %s\n\n" % bundle["generated_at"])
    fh.write("%d / %d ラボ 合格\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "結果なし"
        elif rec["verdict"] == "passed":
            mark = "合格"
            extra = "チェック数: %d" % len(rec["checks"])
        else:
            mark = "不合格"
            extra = "失敗: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\nクラスター数: %d。Kubernetes バージョン: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "不明"))
    fh.write("\nファイルに入るのはチェックの識別子とその結果だけです。\n"
             "アドレスも、名前も、ログの内容も含まれていません。\n")

print("%d / %d ラボ 合格。" % (len(passed), len(all_labs)))
if failed:
    print("不合格: %s" % ", ".join(failed))
if missing:
    print("結果なし: %s" % ", ".join(missing))
if len(uids) > 1:
    print("\n注意: 結果は %d 個の異なるクラスターから取得されました。これは許容されますが、"
          "アップロード時にこのセットはフラグ付けされます。" % len(uids))
for p in problems:
    print("  問題: %s" % p)
print("\nアップロード用ファイル: %s" % out_path)
print("同じ内容のプレーンテキスト:  %s" % txt)
print("送信する前にテキストファイルを確認してください — 送られる内容がすべて見えます。")
PYEOF
