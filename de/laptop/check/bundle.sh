#!/usr/bin/env bash
# Sammelt die Ergebnisse aller Labs in einer einzigen Datei zum Hochladen in das Zertifizierungssystem.
#
# Wichtige Eigenschaft: Das Skript STARTET NICHTS NEU. Es nimmt das, was jedes Lab
# in dem Moment aufgezeichnet hat, als Sie es eingereicht haben. Andernfalls würde Folgendes passieren:
# Die Labs selbst fordern Sie auf, hinter sich aufzuräumen, und das Tenant-Kontingent lässt es nicht zu,
# alle Dienste wochenlang laufen zu lassen — und eine abschließende Neuprüfung würde einen Fehlschlag für
# Arbeit anzeigen, die vor drei Wochen ehrlich erledigt wurde.
#
#   ./bundle.sh                 alles Gefundene sammeln
#   ./bundle.sh --rerun 07-redis  ein einzelnes Lab erneut durchführen und sein Ergebnis aktualisieren
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?geben Sie ein Lab an, zum Beispiel: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "kein solches Lab: $lab"; exit 1; }
  echo "führe $lab erneut durch…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "Ergebnis aktualisiert, führen Sie nun ./bundle.sh ohne Optionen aus"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
Keine Ergebnisse gefunden.

Jedes Lab speichert sein Ergebnis, wenn Sie darin ./check.sh ausführen.
Schließen Sie mindestens eines ab und führen Sie die Prüfung aus — dann kommen Sie hierher zurück.

Wenn Sie die Labs auf einem anderen Rechner durchgeführt haben, kopieren Sie den Ordner
~/.cozystack-labs/results von dort, oder geben Sie einen Pfad an: COZY_LAB_RESULTS=/pfad ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# Wie viele Labs es überhaupt gibt — gezählt anhand des Vorhandenseins eines Prüfskripts.
# Das sechzehnte ("Was am Montag zu tun ist") hat kein Skript: Es ist eine Text-
# übung und zählt nicht zur Wertung.
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
        problems.append(f"{os.path.basename(path)}: nicht lesbar ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: unbekannte Formatversion")
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
    "cluster_uids": sorted(uids),          # mehr als eins — auf verschiedenen Clustern durchgeführt
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# Dasselbe in reinem Text — damit ein Mensch sehen kann, was er sendet.
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Cozystack-Lab-Ergebnisse\n")
    fh.write("Gesammelt: %s\n\n" % bundle["generated_at"])
    fh.write("%d von %d Labs bestanden\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "kein Ergebnis"
        elif rec["verdict"] == "passed":
            mark = "bestanden"
            extra = "Prüfungen: %d" % len(rec["checks"])
        else:
            mark = "nicht bestanden"
            extra = "fehlgeschlagen: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\nCluster: %d. Kubernetes-Versionen: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "nicht ermittelt"))
    fh.write("\nNur Prüfungs-Identifikatoren und ihre Ergebnisse gelangen in die Datei.\n"
             "Keine Adressen, keine Namen, keine Log-Inhalte sind darin enthalten.\n")

print("%d von %d Labs bestanden." % (len(passed), len(all_labs)))
if failed:
    print("Nicht bestanden: %s" % ", ".join(failed))
if missing:
    print("Kein Ergebnis: %s" % ", ".join(missing))
if len(uids) > 1:
    print("\nAchtung: Ergebnisse wurden von %d verschiedenen Clustern erfasst. Das ist zulässig, "
          "aber der Satz wird beim Hochladen markiert." % len(uids))
for p in problems:
    print("  Problem: %s" % p)
print("\nDatei zum Hochladen: %s" % out_path)
print("Dasselbe in reinem Text:  %s" % txt)
print("Sehen Sie sich die Textdatei vor dem Senden an — sie zeigt alles, was hinausgeht.")
PYEOF
