#!/usr/bin/env bash
# Reúne los resultados de todas las labs en un solo archivo para subirlo al sistema de certificación.
#
# Propiedad importante: el script NO REINICIA NADA. Toma lo que cada lab
# registró en el momento en que la entregaste. De lo contrario ocurriría esto: las labs
# mismas te piden que limpies lo que dejas atrás, y la cuota del tenant no permite
# mantener todos los servicios funcionando durante semanas — así que una recomprobación
# final mostraría un fallo en un trabajo hecho honestamente hace tres semanas.
#
#   ./bundle.sh                 reunir todo lo encontrado
#   ./bundle.sh --rerun 07-redis  rehacer una sola lab y actualizar su resultado
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?indica una lab, por ejemplo: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "no existe tal lab: $lab"; exit 1; }
  echo "rehaciendo $lab…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "resultado actualizado, ahora ejecuta ./bundle.sh sin opciones"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
No se encontraron resultados.

Cada lab guarda su resultado cuando ejecutas ./check.sh dentro de ella.
Completa al menos una y ejecuta la comprobación — luego vuelve aquí.

Si hiciste las labs en otra máquina, copia desde allí la carpeta
~/.cozystack-labs/results o indica una ruta: COZY_LAB_RESULTS=/ruta ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# Cuántas labs existen en total — se cuenta por la presencia del script de comprobación.
# La decimosexta ("Qué hacer el lunes") no tiene script: es un ejercicio
# de texto, y no cuenta para la puntuación.
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
        problems.append(f"{os.path.basename(path)}: ilegible ({exc})")
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

# Lo mismo en texto plano — para que una persona pueda ver lo que envía.
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
            extra = "comprobaciones: %d" % len(rec["checks"])
        else:
            mark = "no aprobada"
            extra = "fallidas: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\nClústeres: %d. Versiones de Kubernetes: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "sin determinar"))
    fh.write("\nAl archivo solo llegan los identificadores de las comprobaciones y sus resultados.\n"
             "No hay direcciones, ni nombres, ni contenido de logs en él.\n")

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
print("Mira el archivo de texto antes de enviar — muestra todo lo que sale.")
PYEOF
