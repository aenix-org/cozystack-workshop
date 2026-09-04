#!/usr/bin/env bash
# Biblioteca común para los scripts de comprobación de laboratorios.
# Se incluye así:  . "$(dirname "$0")/../../check/lib.sh"
#
# Deliberadamente NO se usa `set -e`: el script debe ejecutar todas las comprobaciones y
# mostrar el panorama completo, no detenerse en el primer fallo. El lector lo ejecuta
# justo cuando está atascado — cortarlo a mitad de camino oculta la mitad de la respuesta.

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# Colores solo cuando la salida va a un terminal: en un archivo y en CI las secuencias
# de escape se leen como basura.
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- resultado legible por máquina -------------------------------------------
# result-<lab>.json se construye junto al informe humano y contiene SOLO el
# identificador de la comprobación y su resultado. Las formulaciones, la salida de los
# comandos y las evidencias no van ahí: en el informe markdown se acumulan colas de logs
# de contenedores, direcciones externas de balanceadores, direcciones de nodos y la ruta
# al archivo de acceso junto con el nombre de usuario. Limpiar eso con expresiones
# regulares es poco fiable — lo fiable es no generarlo.
#
# El identificador se deriva solo: el número de orden de la comprobación en el laboratorio
# más un hash corto de la formulación. El número da estabilidad, el hash detecta una
# edición imperceptible del texto — si se cambió la formulación, el servicio lo verá y no
# la aceptará en silencio como la misma comprobación.
_checks=()
_seq=0
_record() {   # _record <estado> <formulación>
  _seq=$((_seq + 1))
  local h
  h="$(printf '%s' "$2" | shasum -a 256 2>/dev/null | cut -c1-8)"
  [ -n "$h" ] || h="00000000"
  _checks+=("$(printf '%s-%02d-%s:%s' "$LAB_NAME" "$_seq" "$h" "$1")")
}

ok() {
  _pass=$((_pass + 1))
  _record ok "$1"
  printf '%s[  OK  ]%s %s\n' "$_C_OK" "$_C_OFF" "$1"
  _lines+=("- **OK** — $1")
}

# fail "qué está mal" "qué hacer al respecto"
fail() {
  _record fail "$1"
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - qué hacer: $2")
}

warn() {
  _record warn "$1"
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - nota: $2")
}

# evidence "título" "valor" — va al artefacto, no se imprime en el terminal.
# Las evidencias existen para que el informe pueda mostrarse a alguien y signifique algo.
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# Las salidas tempranas deben dejar igualmente un informe: el README aconseja «venga a la
# comunidad y adjunte el informe del script», pero antes, cuando el clúster estaba inaccesible,
# no había nada que adjuntar — es decir, no había informe precisamente en el caso para el que existe.
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "no está definida la variable KUBECONFIG" \
         "primero: export KUBECONFIG=~/lab.kubeconfig (en cada nueva ventana de terminal)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "el clúster no responde con KUBECONFIG=${KUBECONFIG}" \
         "si kubectl get nodes se queda colgado sin respuesta — el servidor de control del clúster no arrancó; revise el estado de la aplicación Kubernetes en el dashboard y los eventos del tenant en busca de cuota excedida (exceeded quota)"
    evidence "Archivo de acceso" "$KUBECONFIG"
    evidence "Respuesta del clúster" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s no está definida la variable COZY_TENANT\n' "$_C_FAIL" "$_C_OFF"
    printf '         %spor ejemplo: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# Tiempo sin extensiones GNU: BSD date en macOS no entiende `-d`.
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# Dónde se guardan los resultados legibles por máquina. Fuera del repositorio a propósito:
# dentro de un clon el primer `git pull` o cambio de rama los borraría, y se recopilan
# durante semanas.
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # Identificador del clúster — el uid del namespace kube-system. Es el mismo para todas
  # las ejecuciones en un mismo clúster y distinto entre personas, y sobre todo no se puede
  # «escribir a mano», a diferencia del nombre del tenant.
  local cluster_uid=""
  cluster_uid="$(kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  local kver=""
  kver="$(server_version 2>/dev/null || true)"
  CHECKS_LIST="$(printf '%s\n' "${_checks[@]:-}")" \
  LAB="$LAB_NAME" VERDICT="$1" P="$_pass" F="$_fail" W="$_warn" \
  CUID="$cluster_uid" KVER="$kver" TEN="${COZY_TENANT:-}" WHEN="$(_now)" \
  python3 - "$LAB_RESULTS_DIR/result-${LAB_NAME}.json" <<'PYEOF'
import json, os, sys
checks = []
for line in os.environ.get("CHECKS_LIST", "").split("\n"):
    line = line.strip()
    if not line or ":" not in line:
        continue
    cid, status = line.rsplit(":", 1)
    checks.append({"id": cid, "status": status})
doc = {
    "schema_version": 1,
    "lab": os.environ["LAB"],
    "verdict": os.environ["VERDICT"],
    "finished_at": os.environ["WHEN"],
    "totals": {"pass": int(os.environ["P"]), "fail": int(os.environ["F"]),
               "warn": int(os.environ["W"])},
    "env": {"kubernetes_server_version": os.environ.get("KVER") or None,
            "cluster_uid": os.environ.get("CUID") or None,
            "tenant": os.environ.get("TEN") or None},
    "checks": checks,
}
with open(sys.argv[1], "w") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=1)
PYEOF
}

finish() {
  local total=$((_pass + _fail + _warn))
  local report="report-${LAB_NAME}-$(_stamp).md"
  local verdict

  if [ "$_fail" -eq 0 ]; then
    verdict="LABORATORIO APROBADO"
  else
    verdict="QUEDAN PUNTOS PENDIENTES"
  fi

  _write_result_json "$([ "$_fail" -eq 0 ] && echo passed || echo failed)"

  printf '\n'
  printf 'comprobaciones: %d · aprobadas: %d · fallidas: %d · advertencias: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# Informe: ${LAB_TITLE}"
    echo
    echo "- Fecha: $(_now)"
    echo "- Resultado: **${verdict}**"
    echo "- Comprobaciones: ${total} (aprobadas ${_pass}, fallidas ${_fail}, advertencias ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- Tenant: \`${COZY_TENANT}\`"
    echo
    echo "## Comprobaciones"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## Evidencias"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "Informe generado por el script \`check.sh\` de los laboratorios de Cozystack."
    echo "Se comprobó el funcionamiento real en lo esencial, no el mero hecho de aplicar los manifiestos."
  } > "$report"

  printf 'informe: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# La versión del SERVIDOR específicamente. `kubectl version -o json` imprime tanto la del
# cliente como la del servidor; un grep ingenuo sobre gitVersion toma la primera coincidencia
# — la del cliente — y el informe empieza a mentir sobre la versión del clúster. Es fácil
# equivocarse aquí, por eso se ha movido a la biblioteca.
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# Tamaño legible para humanos: Kubernetes reporta allocatable a veces en Ki, a veces en
# bytes puros, y «3258002390» en el informe no le dice nada al lector.
human_bytes() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, re
v = sys.argv[1].strip()
m = re.fullmatch(r'(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|K|M|G|T)?', v)
if not m:
    print(v); raise SystemExit
n = float(m.group(1))
mult = {'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4,
        'K':1000,'M':1000**2,'G':1000**3,'T':1000**4}.get(m.group(2), 1)
b = n * mult
for unit, size in (('Gi',1024**3), ('Mi',1024**2), ('Ki',1024)):
    if b >= size:
        print(f"{b/size:.1f}{unit}"); break
else:
    print(f"{int(b)}B")
PY
}

# Ejecuta un comando en un pod desechable, pasando los secretos a través de variables de
# entorno definidas a partir de un Secret temporal, en lugar de argumentos de línea de comandos.
#
# Por qué así. Todo lo que va a los args de un pod es visible para cualquiera que tenga
# `get pods`, queda en etcd, termina en el audit log y aparece en `ps` en el nodo. Los
# laboratorios de bases de datos explican aparte que una contraseña en la línea de comandos
# es una mala práctica; comprobarlos con un script que hace exactamente eso sería un doble
# estándar.
#
# Uso:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c 'comando que lee $KEY1'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # El Secret se crea desde stdin, así que los valores no acaban en los argumentos de kubectl.
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # El securityContext también es obligatorio aquí: sin él el pod no se creará en un clúster
  # con el perfil `restricted`, y las comprobaciones de los laboratorios de bases de datos no
  # se ejecutarán.
  local cmd_json
  cmd_json="$(printf '%s\n' "$@" | python3 -c 'import sys,json;print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image="$image" --pod-running-timeout=90s \
    --overrides="{\"spec\":{\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65532,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"$name\",\"image\":\"$image\",\"stdin\":true,\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}},\"envFrom\":[{\"secretRef\":{\"name\":\"$sec\"}}],\"command\":$cmd_json}]}}" \
    2>/dev/null
  local rc=$?

  kubectl delete secret "$sec" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# Construir un override con un securityContext que pase el perfil `restricted`.
# Separado aparte: el mismo añadido lo necesita cada pod desechable, y sin él los scripts
# de comprobación no funcionan en clústeres estrictos.
# Los argumentos del comando se pasan CADA UNO POR SEPARADO, y el JSON lo ensambla python:
# escapar comillas a mano en bash ya ha provocado un override roto y un fallo silencioso del
# pod — con el error silenciado por 2>/dev/null.
_restricted_overrides() {
  local name="$1" image="$2"; shift 2
  python3 - "$name" "$image" "$@" <<'PYJSON'
import sys, json
name, image, *cmd = sys.argv[1:]
print(json.dumps({"spec": {
    "securityContext": {"runAsNonRoot": True, "runAsUser": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": name, "image": image, "stdin": True,
                    "securityContext": {"allowPrivilegeEscalation": False,
                                        "capabilities": {"drop": ["ALL"]}},
                    "command": cmd}]}}))
PYJSON
}

# Ejecuta un comando en un pod desechable y devuelve su salida.
# Necesario donde se comprueba la accesibilidad de un servicio desde dentro del clúster:
# desde el portátil el ClusterIP no es visible. El pod se elimina solo en cualquier caso.
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # El securityContext es obligatorio: en un clúster con el perfil `restricted` un pod sin él
  # no se creará, y el participante no podrá comprobar el laboratorio en absoluto.
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` elimina el pod solo mientras el cliente sigue conectado: una desconexión, un
  # timeout o Ctrl+C lo dejan colgado. La eliminación explícita evita que el script deje
  # basura en el clúster.
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# Recoge respuestas de VARIAS peticiones seguidas, una por línea.
#
# Una sola petición con varias réplicas detrás de un servicio es una lotería: un pod ajeno
# con la misma etiqueta entra en el balanceo, pero una muestra única puede no alcanzarlo, y
# la comprobación se pone verde alegremente con contenido sustituido. Comprobado: ocho de
# veinte peticiones fueron al impostor, y la comprobación dijo «aprobado» cuatro veces seguidas.
in_cluster_curl_many() {
  local url="$1" times="${2:-8}"
  local name="check-$$-$RANDOM"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      sh -c "for i in \$(seq 1 $times); do curl -s --max-time 10 '$url'; echo; done")" \
    2>/dev/null
  local rc=$?
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}
