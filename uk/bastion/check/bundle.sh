#!/usr/bin/env bash
# Збирає результати всіх лаб в один файл для завантаження в систему сертифікації.
#
# Важлива властивість: скрипт НІЧОГО НЕ ПЕРЕЗАПУСКАЄ. Він бере те, що кожна лаба
# записала в момент, коли ви її здавали. Інакше вийшло б ось що: лаби самі
# велять прибирати за собою, а квота тенанта не дає тримати всі сервіси тижнями —
# і перевірка наприкінці показала б відмову по роботі, чесно зробленій три тижні
# тому.
#
#   ./bundle.sh                 зібрати все, що знайдено
#   ./bundle.sh --rerun 07-redis  пройти повторно одну лабу і оновити її результат
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?вкажіть лабу, наприклад: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "немає такої лаби: $lab"; exit 1; }
  echo "проходжу повторно $lab…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "результат оновлено, тепер запустіть ./bundle.sh без ключів"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
Результатів не знайдено.

Кожна лаба зберігає свій результат, коли ви запускаєте в ній ./check.sh.
Пройдіть хоча б одну і запустіть перевірку — потім повертайтеся сюди.

Якщо ви проходили лаби на іншій машині, скопіюйте звідти теку
~/.cozystack-labs/results або вкажіть шлях: COZY_LAB_RESULTS=/шлях ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# Скільки лаб взагалі існує — рахуємо за наявністю скрипта перевірки.
# У шістнадцятої ("Що робити в понеділок") скрипта немає: це текстова
# вправа, і в залік вона не йде.
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
        problems.append(f"{os.path.basename(path)}: не читається ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: невідома версія формату")
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
    "cluster_uids": sorted(uids),          # більше одного — проходили на різних кластерах
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# Те саме звичайним текстом — щоб людина бачила, що надсилає.
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Результати лабораторних Cozystack\n")
    fh.write("Зібрано: %s\n\n" % bundle["generated_at"])
    fh.write("Здано %d з %d лаб\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "результату немає"
        elif rec["verdict"] == "passed":
            mark = "здана"
            extra = "перевірок: %d" % len(rec["checks"])
        else:
            mark = "не здана"
            extra = "провалено: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\nКластерів: %d. Версії Kubernetes: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "не визначені"))
    fh.write("\nУ файл потрапляють лише ідентифікатори перевірок та їхні результати.\n"
             "Ні адрес, ні імен, ні вмісту логів у ньому немає.\n")

print("Здано %d з %d лаб." % (len(passed), len(all_labs)))
if failed:
    print("Не здано: %s" % ", ".join(failed))
if missing:
    print("Немає результату: %s" % ", ".join(missing))
if len(uids) > 1:
    print("\nУвага: результати зняті з %d різних кластерів. Це допустимо, "
          "але під час завантаження набір буде позначено." % len(uids))
for p in problems:
    print("  проблема: %s" % p)
print("\nФайл для завантаження: %s" % out_path)
print("Він же звичайним текстом:  %s" % txt)
print("Перегляньте текстовий файл перед надсиланням — у ньому видно все, що йде.")
PYEOF
