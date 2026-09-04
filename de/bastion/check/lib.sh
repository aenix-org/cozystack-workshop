#!/usr/bin/env bash
# Gemeinsame Bibliothek für die Prüfskripte der Übungen.
# Wird so eingebunden:  . "$(dirname "$0")/../../check/lib.sh"
#
# `set -e` wird bewusst NICHT verwendet: Das Skript muss alle Prüfungen durchlaufen
# und das vollständige Bild zeigen, statt bei der ersten Fehlschlag stehenzubleiben.
# Der Leser führt es genau dann aus, wenn er feststeckt — es auf halbem Weg
# abzubrechen hieße, die halbe Antwort zu verbergen.

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# Farben nur, wenn die Ausgabe in ein Terminal geht: in einer Datei und in CI werden
# die Escape-Sequenzen als Müll gelesen.
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- maschinenlesbares Ergebnis ----------------------------------------------
# result-<lab>.json wird parallel zum menschenlesbaren Bericht erstellt und enthält NUR
# die Prüfungs-Kennung und deren Ausgang. Formulierungen, Befehlsausgaben und Nachweise
# landen dort nicht: der Markdown-Bericht sammelt Enden von Container-Logs, externe
# Adressen von Loadbalancern, Adressen von Knoten und den Pfad zur Zugangsdatei zusammen
# mit dem Benutzernamen. Das mit regulären Ausdrücken zu bereinigen ist unzuverlässig —
# zuverlässig ist, es gar nicht erst zu erzeugen.
#
# Die Kennung wird automatisch abgeleitet: die laufende Nummer der Prüfung innerhalb der
# Übung plus ein kurzer Hash der Formulierung. Die Nummer gibt Stabilität, der Hash fängt
# eine unauffällige Änderung des Textes — wurde die Formulierung geändert, sieht der
# Dienst das und akzeptiert sie nicht stillschweigend als dieselbe Prüfung.
_checks=()
_seq=0
_record() {   # _record <Status> <Formulierung>
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

# fail "was ist falsch" "was dagegen zu tun ist"
fail() {
  _record fail "$1"
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - zu tun: $2")
}

warn() {
  _record warn "$1"
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - Hinweis: $2")
}

# evidence "Titel" "Wert" — geht in das Artefakt, wird nicht ins Terminal gedruckt.
# Nachweise sind nötig, damit der Bericht jemandem gezeigt werden kann und tatsächlich etwas bedeutet.
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# Frühe Abbrüche müssen dennoch einen Bericht hinterlassen: die README rät „kommen Sie in
# die Community und hängen Sie den Bericht des Skripts an“, und früher gab es bei
# unerreichbarem Cluster nichts anzuhängen — das heißt, der Bericht fehlte genau in dem
# Fall, für den er gebraucht wird.
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "die Variable KUBECONFIG ist nicht gesetzt" \
         "zuerst: export KUBECONFIG=~/lab.kubeconfig (in jedem neuen Terminalfenster)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "der Cluster antwortet nicht unter KUBECONFIG=${KUBECONFIG}" \
         "wenn kubectl get nodes ohne Antwort hängt — der Steuerungsserver des Clusters ist nicht hochgekommen; prüfen Sie den Status der Kubernetes-Anwendung im Dashboard und die Ereignisse des Mandanten auf Kontingentmangel (exceeded quota)"
    evidence "Zugangsdatei" "$KUBECONFIG"
    evidence "Antwort des Clusters" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s die Variable COZY_TENANT ist nicht gesetzt\n' "$_C_FAIL" "$_C_OFF"
    printf '         %szum Beispiel: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# Zeit ohne GNU-Erweiterungen: BSD date auf macOS versteht `-d` nicht.
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# Wohin die maschinenlesbaren Ergebnisse abgelegt werden. Außerhalb des Repos mit Absicht:
# innerhalb des Klons würde sie schon der erste `git pull` oder Branch-Wechsel löschen, und
# sie werden über Wochen gesammelt.
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # Cluster-Kennung — die uid des Namespace kube-system. Sie ist für alle Läufe auf einem
  # Cluster gleich und bei verschiedenen Personen unterschiedlich, und vor allem — sie kann
  # nicht „von Hand eingegeben“ werden, anders als der Mandantenname.
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
    verdict="LABOR BESTANDEN"
  else
    verdict="OFFENE PUNKTE VERBLEIBEN"
  fi

  _write_result_json "$([ "$_fail" -eq 0 ] && echo passed || echo failed)"

  printf '\n'
  printf 'Prüfungen: %d · bestanden: %d · fehlgeschlagen: %d · Warnungen: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# Bericht: ${LAB_TITLE}"
    echo
    echo "- Datum: $(_now)"
    echo "- Ergebnis: **${verdict}**"
    echo "- Prüfungen: ${total} (bestanden ${_pass}, fehlgeschlagen ${_fail}, Warnungen ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- Mandant: \`${COZY_TENANT}\`"
    echo
    echo "## Prüfungen"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## Nachweise"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "Bericht erstellt vom Skript \`check.sh\` aus den Cozystack-Übungen."
    echo "Geprüft wurde die tatsächliche Funktion, nicht die Tatsache, dass Manifeste angewendet wurden."
  } > "$report"

  printf 'Bericht: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# Die Version GENAU des Servers. `kubectl version -o json` gibt sowohl die Client- als auch
# die Server-Version aus; ein naiver grep auf gitVersion nimmt die erste, die es findet —
# die des Clients — und der Bericht fängt an, über die Cluster-Version zu lügen. Das ist
# leicht falsch zu machen, deshalb ist es in die Bibliothek ausgelagert.
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# Menschenlesbare Größe: Kubernetes meldet allocatable mal in Ki, mal in rohen Bytes, und
# „3258002390“ im Bericht sagt dem Leser nichts.
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

# Einen Befehl in einem Wegwerf-Pod ausführen und Secrets über Umgebungsvariablen
# übergeben, die aus einem temporären Secret gesetzt werden, statt über
# Kommandozeilenargumente.
#
# Warum so. Alles, was in die args eines Pods gelangt, ist für jeden sichtbar, der
# `get pods` hat, liegt in etcd, geht in das Audit-Log und taucht in `ps` auf dem Knoten
# auf. Die Datenbank-Übungen erklären gesondert, dass ein Passwort auf der Kommandozeile
# schlechte Praxis ist; sie mit einem Skript zu prüfen, das genau das tut, wäre ein
# doppelter Standard.
#
# Verwendung:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c 'Befehl, der $KEY1 liest'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # Das Secret wird aus stdin erstellt, daher landen die Werte nicht in den kubectl-Argumenten.
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # securityContext ist auch hier zwingend: ohne ihn wird der Pod in einem Cluster mit dem
  # Profil `restricted` nicht erstellt, und die Prüfungen der Datenbank-Übungen laufen nicht.
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

# Ein override mit einem securityContext bauen, der das Profil `restricted` besteht.
# Separat ausgelagert: dieselbe Ergänzung wird von jedem Wegwerf-Pod gebraucht, und ohne
# sie funktionieren die Prüfskripte in strengen Clustern nicht.
# Die Befehlsargumente werden JEWEILS EINZELN übergeben, und das JSON wird von python
# zusammengebaut: manuelles Escapen von Anführungszeichen in bash hat bereits zu einem
# kaputten override und einem stillen Pod-Fehler geführt — und der Fehler wurde von
# 2>/dev/null verschluckt.
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

# Einen Befehl in einem Wegwerf-Pod ausführen und dessen Ausgabe zurückgeben.
# Nötig dort, wo die Erreichbarkeit eines Dienstes von innerhalb des Clusters geprüft wird:
# vom Laptop aus ist die ClusterIP nicht sichtbar. Der Pod räumt in jedem Fall hinter sich auf.
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext ist zwingend: in einem Cluster mit dem Profil `restricted` wird ein Pod
  # ohne ihn nicht erstellt, und der Teilnehmer kann die Übung überhaupt nicht prüfen.
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` löscht den Pod nur, solange der Client angehängt ist: eine Trennung, ein Timeout
  # oder Ctrl+C lassen ihn hängen. Explizites Löschen — damit das Skript den Cluster nicht
  # vermüllt.
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# Antworten von MEHREREN Anfragen hintereinander sammeln, eine pro Zeile.
#
# Eine einzelne Anfrage bei mehreren Kopien hinter dem Dienst ist eine Lotterie: ein fremder
# Pod mit demselben Label gerät in die Lastverteilung, aber eine einzelne Stichprobe trifft
# ihn womöglich nicht, und die Prüfung wird fröhlich grün auf untergeschobenem Inhalt.
# Geprüft: acht von zwanzig Anfragen gingen an den Hochstapler, während die Prüfung viermal
# hintereinander „bestanden“ sagte.
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
