#!/usr/bin/env bash
# Shared library for the lab check scripts.
# Sourced like this:  . "$(dirname "$0")/../../check/lib.sh"
#
# `set -e` is deliberately NOT used: the script must run every check and show
# the full picture, not stop at the first failure. The reader runs it exactly
# when they are stuck — cutting it off halfway hides half the answer.

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# Colors only when output goes to a terminal: in a file and in CI the escape
# sequences read as garbage.
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

# --- machine-readable result -------------------------------------------------
# result-<lab>.json is built alongside the human report and contains ONLY the
# check identifier and its outcome. The wording, command output, and evidence do
# not go there: the markdown report accumulates container log tails, external
# load balancer addresses, node addresses, and the path to the access file along
# with the user name. Scrubbing that with regexes is unreliable — the reliable
# way is not to produce it.
#
# The identifier derives itself: the check's ordinal number in the lab plus a
# short hash of the wording. The number gives stability, the hash catches a
# silent edit of the text — if the wording was changed, the service will see it
# and will not silently accept it as the same check.
_checks=()
_seq=0
_record() {   # _record <status> <message>
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

# fail "what is wrong" "what to do about it"
fail() {
  _record fail "$1"
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - what to do: $2")
}

warn() {
  _record warn "$1"
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - note: $2")
}

# evidence "title" "value" — goes into the artifact, is not printed to the terminal.
# Evidence exists so the report can be shown to someone and actually mean something.
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

# Early exits must still leave a report: the README advises "come to the community
# and attach the script's report", yet before, when the cluster was unreachable there
# was nothing to attach — that is, there was no report precisely in the case it exists for.
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "the KUBECONFIG variable is not set" \
         "first: export KUBECONFIG=~/lab.kubeconfig (in every new terminal window)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "the cluster does not respond with KUBECONFIG=${KUBECONFIG}" \
         "if kubectl get nodes hangs with no response — the cluster control plane did not come up; check the Kubernetes application status in the dashboard and the tenant events for an exceeded quota"
    evidence "Access file" "$KUBECONFIG"
    evidence "Cluster response" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s the COZY_TENANT variable is not set\n' "$_C_FAIL" "$_C_OFF"
    printf '         %sfor example: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# Time without GNU extensions: BSD date on macOS does not understand `-d`.
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

# Where machine-readable results are stored. Outside the repo on purpose: inside
# a clone the first `git pull` or branch switch would wipe them, and they are
# collected over weeks.
LAB_RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"

_write_result_json() {
  mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || return 0
  # Cluster identifier — the uid of the kube-system namespace. It is the same for
  # all runs on one cluster and different across people, and crucially it cannot
  # be "typed in by hand", unlike the tenant name.
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
    verdict="LAB PASSED"
  else
    verdict="OPEN ITEMS REMAIN"
  fi

  _write_result_json "$([ "$_fail" -eq 0 ] && echo passed || echo failed)"

  printf '\n'
  printf 'checks: %d · passed: %d · failed: %d · warnings: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# Report: ${LAB_TITLE}"
    echo
    echo "- Date: $(_now)"
    echo "- Result: **${verdict}**"
    echo "- Checks: ${total} (passed ${_pass}, failed ${_fail}, warnings ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- Tenant: \`${COZY_TENANT}\`"
    echo
    echo "## Checks"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## Evidence"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "This report was produced by the \`check.sh\` script from the Cozystack labs."
    echo "It verified real functionality on the merits, not the mere fact that manifests were applied."
  } > "$report"

  printf 'report: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# The SERVER version specifically. `kubectl version -o json` prints both the client
# and the server one; a naive grep on gitVersion takes the first match — the client
# one — and the report starts lying about the cluster version. It is easy to get this
# wrong, so it is moved into the library.
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# Human-readable size: Kubernetes reports allocatable sometimes in Ki, sometimes in
# bare bytes, and "3258002390" in the report tells the reader nothing.
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

# Run a command in a throwaway pod, passing secrets through environment variables
# set from a temporary Secret rather than command-line arguments.
#
# Why this way. Everything that goes into a pod's args is visible to anyone with
# `get pods`, sits in etcd, ends up in the audit log, and shows up in `ps` on the
# node. The database labs separately explain that a password on the command line
# is bad practice; checking them with a script that does exactly that would be a
# double standard.
#
# Usage:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c 'command that reads $KEY1'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # The Secret is created from stdin, so the values do not end up in kubectl arguments.
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # securityContext is also mandatory here: without it the pod will not be created
  # in a cluster with the `restricted` profile, and the checks for the database labs
  # will not run.
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

# Build an override with a securityContext that passes the `restricted` profile.
# Broken out separately: the same add-on is needed by every throwaway pod, and
# without it the check scripts do not work in strict clusters.
# The command arguments are passed EACH SEPARATELY, and the JSON is assembled by
# python: hand-escaping quotes in bash has already led to a broken override and a
# silent failure of the pod — with the error swallowed by 2>/dev/null.
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

# Run a command in a throwaway pod and return its output.
# Needed where service reachability from inside the cluster is checked: from the
# laptop the ClusterIP is not visible. The pod cleans up after itself in any case.
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext is mandatory: in a cluster with the `restricted` profile a pod
  # without it will not be created, and the participant will not be able to check
  # the lab at all.
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` deletes the pod only while the client stays attached: a disconnect, a
  # timeout, or Ctrl+C leaves it hanging. The explicit delete keeps the script from
  # littering the cluster.
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# Collect responses from SEVERAL requests in a row, one per line.
#
# A single request with several replicas behind a service is a lottery: a stray pod
# with the same label gets into the load balancing, but a single sample may miss it,
# and the check happily turns green on substituted content. Verified: eight of twenty
# requests went to the impostor, and the check said "passed" four times in a row.
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
