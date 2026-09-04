#!/usr/bin/env bash
# Reúne los resultados de todas las labs en un único archivo para subirlo al sistema de certificación.
#
# Propiedad importante: el script NO REEJECUTA NADA. Toma lo que cada lab
# registró en el momento en que la entregaste. De lo contrario ocurriría esto: las
# propias labs te piden que recojas lo que dejaste, y la cuota del tenant no permite
# mantener todos los servicios activos durante semanas — así que una reverificación
# al final mostraría un fallo en un trabajo hecho honestamente hace tres semanas.
#
#   ./bundle.sh                 reunir todo lo que se encuentre
#   ./bundle.sh --rerun 07-redis  reejecutar una sola lab y actualizar su resultado
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?indica una lab, por ejemplo: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "no existe esa lab: $lab"; exit 1; }
  echo "reejecutando $lab…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "resultado actualizado, ahora ejecuta ./bundle.sh sin opciones"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
No se encontraron resultados.

Cada lab guarda su resultado cuando ejecutas ./check.sh en ella.
Completa al menos una y ejecuta la verificación — luego vuelve aquí.

Si hiciste las labs en otra máquina, copia desde allí la carpeta
~/.cozystack-labs/results o indica la ruta: COZY_LAB_RESULTS=/ruta ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# Cuántas labs existen en total — se cuentan por la presencia de un script de verificación.
# La decimosexta ("Qué hacer el lunes") no tiene script: es un ejercicio de
# texto y no cuenta para la nota.
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
        problems.append(f"{os.path.basename(path)}: no se puede leer ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: versión de formato desconocida")
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
    "cluster_uids": sorted(uids),          # más de uno — hechas en clústeres distintos
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# Lo mismo en texto plano — para que una persona vea lo que está enviando.
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Resultados de las labs de Cozystack\n")
    fh.write("Recopilado: %s\n\n" % bundle["generated_at"])
    fh.write("Aprobadas %d de %d labs\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "sin resultado"
        elif rec["verdict"] == "passed":
            mark = "aprobada"
            extra = "verificaciones: %d" % len(rec["checks"])
        else:
            mark = "no aprobada"
            extra = "fallidas: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\nClústeres: %d. Versiones de Kubernetes: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "sin determinar"))
    fh.write("\nAl archivo solo llegan los identificadores de las verificaciones y sus resultados.\n"
             "No contiene direcciones, ni nombres, ni contenido de logs.\n")

print("Aprobadas %d de %d labs." % (len(passed), len(all_labs)))
if failed:
    print("No aprobadas: %s" % ", ".join(failed))
if missing:
    print("Sin resultado: %s" % ", ".join(missing))
if len(uids) > 1:
    print("\nAtención: los resultados se tomaron de %d clústeres distintos. Está permitido, "
          "pero el conjunto se marcará al subirlo." % len(uids))
for p in problems:
    print("  problema: %s" % p)
print("\nArchivo para subir: %s" % out_path)
print("El mismo en texto plano:  %s" % txt)
print("Revisa el archivo de texto antes de enviarlo — muestra todo lo que se envía.")
PYEOF
