#!/usr/bin/env bash
# Check for lab 10: MongoDB holds passes of different shapes and queries run against them.
#
# We check not "the service is created", but the substance: the collection has documents of all four
# shapes, search by a nested field and inside a list works, a sparse index is
# built on a rare field, the schema validator is enabled, and no documents without a type
# remain.
#
# Run (in every new terminal window the variables are set again):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # your number instead of XX
#   export MONGO_PASSWORD='password of the passapp user'
#   cd labs/10-mongodb && ./check.sh
#
# The password is not printed and does not end up in the report.
# The script spins up disposable pods, so it takes about a minute.

# The name and title are needed by the shared library: it signs the report artifact with them.
# lib.sh holds ok/fail/warn/evidence/finish and the environment checks below — so that
# fifteen check scripts print the same way, not each in its own fashion.
LAB_NAME="10-mongodb"
LAB_TITLE="Lab 10 · Document store"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Both checks stop the script with a clear message if the cluster access file
# or the tenant number is not set. Without them kubectl errors would pile up further down.
need_kubeconfig
need_tenant

# The participant sets COZY_TENANT as `workshop07`, while the namespace is called
# `tenant-workshop07`. We accept both spellings.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# The default names are the same as in the lab. The notation ${X:-value} means "take
# the environment variable, and if it is absent, substitute the value": if you named the app
# differently — run it as MONGO_APP=name ./check.sh, no need to edit the script.
# The address is internal, from within the cluster itself; rs0 in the name is the replica set in which
# our single copy lives.
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "MongoDB address" "$MONGO_HOST"

# --- 1. is there connectivity to the port at all ---------------------------
# MongoDB on its port answers an HTTP request with a clear phrase about the fact that
# you should reach it with a driver, not a browser. That is enough to tell
# "the name does not resolve / the port is closed" from "there is connectivity, the credentials are wrong".
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB responds at the tenant's internal address"
else
  fail "no connectivity to MongoDB at address ${MONGO_HOST}" \
       "check the tenant number in COZY_TENANT and the app name (default 'passes'; otherwise MONGO_APP=name ./check.sh); in the dashboard the app must be in a ready state"
  finish
  exit $?
fi

# Everything further requires logging into the database. Without a password the script does not guess and does not stay silent,
# but honestly says that the database contents were not checked, and finishes the report: otherwise
# the participant would decide that the check passed.
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "the MONGO_PASSWORD variable is not set, the database contents were not checked" \
       "export MONGO_PASSWORD='password of the ${MONGO_USER} user' and run the script again"
  finish
  exit $?
fi

# The password is percent-encoded: the characters @ : / ? # % in it would otherwise break up the connection
# string, and the person gets an unclear parse error instead of "wrong password".
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ The connection string contains the password and is passed as a pod argument. This is a deliberate
# compromise: see `in_cluster_with_secrets` in check/lib.sh — a safe path exists, but
# it is incompatible with a multi-line --eval without over-complication. The pod lives for seconds and
# removes itself; the password does not end up in the report. Do not do this in production scripts.
#
# All checks in one go: each call spins up a pod, and ten pods in a row
# would turn the check into a multi-minute wait for no reason.
# A single JSON line is emitted, and python parses it afterward.
# `--overrides` with securityContext: without it the pod would not be created in a cluster with the
# `restricted` profile, and the lab would fail for a reason unrelated to the participant.
# `--command --` stays: kubectl merges it with the override, where only the
# security fields are set.
# The program for mongosh. Double quotes inside it are safe: the text goes out
# through python, which quotes it itself, and the database and collection names are substituted
# via the markers below.
MONGO_EVAL=$(cat <<'JSEOF'

var out = {};
try {
  var c = db.getSiblingDB("__DB__").getCollection("__COLL__");
  out.ok = 1;
  out.total = c.countDocuments({});
  out.types = c.distinct("type").length;
  out.withCar = c.countDocuments({ "car.plate": { $exists: true } });
  out.withArray = c.countDocuments({
    $or: [ { entrances: { $exists: true } }, { members: { $exists: true } } ]
  });
  out.nested = c.countDocuments({ "members.name": { $exists: true } });
  out.typeless = c.countDocuments({ type: { $exists: false } });
  var idx = c.getIndexes();
  out.indexes = idx.map(function (i) { return i.name; });
  out.sparse = idx.filter(function (i) {
    return i.sparse === true || i.partialFilterExpression !== undefined;
  }).map(function (i) { return i.name; });
  var info = db.getSiblingDB("__DB__").getCollectionInfos({ name: "__COLL__" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
JSEOF
)
MONGO_EVAL="${MONGO_EVAL//__DB__/$MONGO_DB}"
MONGO_EVAL="${MONGO_EVAL//__COLL__/$MONGO_COLL}"

# The container command is placed INSIDE the override, rather than left outside in `--command --`.
# kubectl applies the override as a JSON merge patch, and in it the containers array is replaced
# wholesale: the `--command` set outside would not reach the pod, and instead of mongosh the
# image's default process would have started — that is, the database itself. It is done the same way in check/lib.sh.
MONGO_SC="$(python3 - "$MONGO_URI" "$MONGO_EVAL" <<'PYEOF'
import json, sys
uri, script = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {
  "securityContext": {"runAsNonRoot": True, "runAsUser": 999,
                      "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "mongo-check", "image": "mongo:8.0", "stdin": True,
                  "securityContext": {"allowPrivilegeEscalation": False,
                                      "capabilities": {"drop": ["ALL"]}},
                  "command": ["mongosh", "--quiet", uri, "--eval", script]}]}}))
PYEOF
)"

SUMMARY="$(kubectl run "mongo-check" --rm -i --restart=Never --quiet \
  --pod-running-timeout=90s --overrides="$MONGO_SC" \
  --image=mongo:8.0 </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

# Pull a field out of the JSON line printed by mongosh. Lists are joined with a
# comma so they can be shown to the participant as-is.
mget() {
  printf '%s' "$SUMMARY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v if not isinstance(v, list) else ", ".join(str(x) for x in v))
' "$1" 2>/dev/null
}

# Same, but for numbers: any unexpected value turns into 0, otherwise the comparison
# below would fail with an arithmetic error instead of a clear FAIL.
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# If there is no response at all or mongosh reported an error — there is nothing further to check.
# An authentication failure is separated from other errors: it has its own common cause —
# a forgotten authSource=admin, and the hint should lead exactly to it.
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB did not accept the credentials of the ${MONGO_USER} user" \
           "check the password and that the connection string has authSource=admin: the user is created in the admin database, while the privileges are granted in ${MONGO_DB}" ;;
    *)
      fail "could not run the query against the ${MONGO_DB} database${ERR:+: $ERR}" \
           "check manually: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "connection to the ${MONGO_DB} database as the ${MONGO_USER} user works"

# --- 2. documents exist -----------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "documents in the ${MONGO_COLL} collection: ${TOTAL}"
else
  fail "the ${MONGO_COLL} collection has only ${TOTAL} documents, at least four were expected" \
       "load the passes: mo < passes.js (the file walkthrough is in the README)"
fi

# --- 3. the shapes really are different -------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "the collection has ${TYPES} different pass types"
else
  fail "only ${TYPES} different pass types, four were expected" \
       "check that passes.js loaded in full: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "there are documents with a nested object (car.plate): ${WITH_CAR}"
else
  fail "not a single document with a nested car object" \
       "the vehicle pass did not load; repeat mo < passes.js"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "there are documents with lists (entrances and members): ${WITH_ARRAY}"
else
  fail "documents with lists: ${WITH_ARRAY}, at least two were expected" \
       "the weekly and group passes did not load; repeat mo < passes.js"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "search inside a list of objects (members.name) finds documents"
else
  fail "search by members.name found nothing" \
       "the group pass with a list of members did not load; repeat mo < passes.js"
fi

evidence "Collection composition" "documents: ${TOTAL}
different pass types: ${TYPES}
with a nested car object: ${WITH_CAR}
with lists: ${WITH_ARRAY}"

# --- 4. index on a rare field ----------------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "a sparse (or partial) index is built: ${SPARSE}"
  evidence "Collection indexes" "all: ${IDX}
sparse: ${SPARSE}"
else
  fail "no sparse index — the search by car number is a full scan" \
       "create one: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "Collection indexes" "all: ${IDX}"
fi

# --- 5. the schema validator is enabled ------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "the schema validator is enabled (action on violation: ${ACTION:-default})"
  if [ "$ACTION" = "warn" ]; then
    warn "the validator only warns but still accepts documents" \
         "a production collection needs validationAction: error"
  fi
else
  fail "the schema validator is not enabled — a typo in a field name would pass silently" \
       "enable it: mo < validator.js (see the walkthrough of the predictable failure in the README)"
fi

# --- 6. corrupted documents removed ----------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "no documents without a type field remain"
else
  fail "the collection has ${TYPELESS} documents without a type field — security will not see them" \
       "find and remove them: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish prints the total and stores the report artifact in a file; the exit code is non-zero
# if at least one check failed.
finish
