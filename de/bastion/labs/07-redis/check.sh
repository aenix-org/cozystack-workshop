#!/usr/bin/env bash
# Check for lab 7: the cache really speeds things up, and it shows in the numbers.
#
# The main check here is behavioral, not structural. The script itself takes an unused
# identifier, requests it twice and watches: the first time should be a miss of hundreds
# of milliseconds, the second — a hit of single-digit milliseconds. A manifest with the right
# environment variables will not pass this check if the cache does not actually respond.
#
# Two clusters: KUBECONFIG — your lab cluster, COZY_KUBECONFIG — the Cozystack management
# cluster, where the managed Redis service lives.

# LAB_NAME and LAB_TITLE go into the report header. Next, the shared checks library is
# sourced: from it come ok / warn / fail / evidence / finish and, most importantly,
# in_cluster_curl — it spins up a one-off pod with curl INSIDE the cluster. From the inside,
# not from the VM: the lab services are not exposed outward, and passes-api is reachable by
# name only from within the cluster. need_kubeconfig and need_tenant stop the script early
# if access or the tenant number are not set, — otherwise all checks would fail at once
# and you would not be able to tell the reason from the report.
LAB_NAME="07-redis"
LAB_TITLE="Lab 7 · Cache in front of a slow backend"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# The names and addresses the whole check looks at are gathered in one place: you will not
# have to search for them through the script text. COZY_KUBECONFIG can be overridden from
# outside if your tenant access is not in the default location.
APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# Two shortcuts for the whole script: kget talks to the lab cluster (the one in KUBECONFIG),
# cozy — to the Cozystack management cluster. Error messages are suppressed on purpose:
# a missing object here is a normal situation, which the script will describe in its own words
# and with a hint, rather than with someone else's text from kubectl.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# Extract a field from JSON. Without jq: it is not on a bare macOS, but python3 is everywhere
# the rest of the checks library works.
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- managed Redis service on the management cluster -------------------------
# Redis lives not in your lab cluster, but in a tenant on the management cluster: it is a
# managed service, the platform keeps it running itself. Rights in the tenant differ for
# everyone, so neither an access denial nor a missing kubeconfig fail the lab — the cache's
# work below is checked directly, with live requests, and that is the real proof.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "tenant kubeconfig ${COZY_KUBECONFIG} not found — Redis state was not checked" \
       "set the path: export COZY_KUBECONFIG=~/.kube/config"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "could not view Redis applications in tenant ${TENANT_NS}" \
         "your tenant role may not allow this command — this is not a lab error; the cache's work is checked directly below"
  elif [ -z "$REDIS_LIST" ]; then
    fail "tenant ${TENANT_NS} has no Redis application at all" \
         "create it in the dashboard: Create application -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis «${R_NAME}» is ready, data copies: ${R_REPLICAS:-default}"
    else
      warn "Redis «${R_NAME}» exists, but does not report readiness" \
           "check its state in the dashboard; it comes up in three-to-five minutes"
    fi
    evidence "Redis in the tenant" "$REDIS_LIST"
  fi
fi

# --- the slow directory is in place and actually slow ------------------------
# Without this check the «before and after» comparison means nothing: if the directory
# responds instantly, there is nothing to speed up and nothing for the cache to measure.
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "directory ${HR} is not running" \
       "apply hr-legacy.yaml and check kubectl describe pod -l app=hr-legacy"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "the directory responds in ${HR_MS} ms — there is something to speed up"
    evidence "Directory latency" "${HR_MS} ms per /employee request"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "directory ${HR} did not respond to the request" \
         "check kubectl logs -l app=hr-legacy"
  else
    warn "the directory responds in ${HR_MS} ms, that is too fast to measure" \
         "make sure hr-legacy.yaml sets MODE=hr and HR_DELAY=800ms"
  fi
fi

# --- the application is configured for caching -------------------------------
# We parse the container's environment with python, not jsonpath: jsonpath filters over
# nested lists behave differently in different kubectl versions, and it matters to us that
# the check works the same for everyone.
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

# The complaints are handled in order — from the most general to the most specific: no
# application, no variable, a placeholder left instead of an address. The order here is not
# cosmetic: otherwise a participant would get the advice «fill in the Redis address» at a
# moment when the service itself is not yet deployed, and would look for the error in the
# wrong place.
if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "the lab cluster has no application ${APP}" \
       "apply passes-api.yaml, filling in your Harbor address"
elif [ -z "$REDIS_ADDR" ]; then
  fail "the REDIS_ADDR variable is not set in ${APP} — the cache is off" \
       "apply the patch: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "the placeholder address REDIS-ADDR is still in the patch" \
       "fill in your Redis address, for example rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "the application is configured for the cache at ${REDIS_ADDR}, entry lifetime ${TTL:-default} s"
fi

# We only look at whether the variable name is present, we do not read or print its value
# anywhere. People forward the lab report to each other and attach it to tickets — a password
# that ends up there will stay there forever.
if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "the Redis password reaches the application (value: <hidden>)"
else
  fail "the REDIS_PASSWORD variable is not set in ${APP}" \
       "Redis requires authentication; create the redis-password secret and apply cache-patch.yaml"
fi

# A missing secret is a warning, not a failure: the password can be delivered to the pod
# another way too. The property checked here is different — the manifest holds a reference,
# not a value.
if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "the redis-password secret with the Redis password exists"
else
  warn "there is no redis-password secret in the cluster" \
       "create it: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- the main check: the cache really speeds things up -----------------------
# We take a deliberately new identifier so that the first request is guaranteed to be a miss.
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "service ${APP} did not return the expected JSON" \
       "check kubectl logs -l app=passes-api; make sure the image is built from this lab's app/ (tag v2)"
  evidence "What the service responded" "first request: ${R1:-empty}
second request: ${R2:-empty}"
elif [ "$MODE" != "redis" ]; then
  fail "the application reports that the cache is off (cache: ${MODE})" \
       "the REDIS_ADDR variable did not reach the running pods — check kubectl rollout status deployment/${APP}"
elif [ "$C1" = "True" ]; then
  warn "the first request already came from the cache — nothing to compare with" \
       "an unlikely identifier collision; run the check again"
elif [ "$C2" != "True" ]; then
  fail "the second request for the same identifier missed the cache again" \
       "the application cannot write to Redis: check kubectl logs -l app=passes-api, usually there is NOAUTH or a timeout there"
  evidence "Service responses" "first:  ${R1}
second: ${R2}"
else
  ok "the cache works: miss ${T1} ms, hit ${T2} ms"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "more than 1000")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "Measurement on a live service" "identifier: ${PROBE_ID}
first request (miss):   ${T1} ms
second request (hit): ${T2} ms
gain: roughly ${SPEEDUP}x
entry lifetime: ${TTL:-default} s"

  # The strict part: the hit must be an order of magnitude faster than the miss. Otherwise
  # «the cache works» only means the key was written, but there is no benefit.
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "the gain is measurable: the hit is roughly ${SPEEDUP}x faster than the miss"
  else
    warn "the cache hit gives no noticeable gain (${T1} ms versus ${T2} ms)" \
         "make sure the directory is really slow, and Redis is not on the same pod"
  fi
fi

# --- how many copies of the service share one cache --------------------------
# The cache is shared across all copies — this is worth seeing in the report: the hit could
# have come from a different pod than the miss, and that is correct.
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "copies of the service running: ${API_PODS} (they share the cache)"
  evidence "Service copies" "$(kget pods -l app=passes-api -o wide)"
else
  fail "not a single running copy of ${APP}" \
       "check kubectl describe pod -l app=passes-api"
fi

finish
