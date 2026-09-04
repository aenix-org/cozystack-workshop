#!/usr/bin/env bash
# Check for lab 2: self-healing.
#
# We check not "the commands were typed", but the cluster state after the lab: the app again
# serves requests through the Service, returns the name of its replica, and that name belongs
# to a really running pod. Plus we look for traces that replicas were recreated.
#
# The script deletes and creates nothing, except a one-off pod to check
# service availability from inside the cluster — it removes itself.

LAB_NAME="02-selfheal"
LAB_TITLE="Lab 2 · Kill a pod and see what happens"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# RFC3339 from kubectl (always UTC with Z) into unix seconds. Via python3, because
# BSD date on macOS and GNU date on Linux parse dates differently, and python is everywhere
# lib.sh works.
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- the app exists at all -------------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "app ${APP} is not in the cluster" \
       "at the end of the lab it had to be restored: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "What is in the namespace" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "app ${APP} restored: ready replicas ${HAVE} of ${WANT}"
else
  fail "replicas ready ${HAVE} of the requested ${WANT}" \
       "see kubectl describe deployment ${APP} and kubectl get pods -l app=${APP}"
fi
evidence "App state" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- the Deployment -> ReplicaSet -> Pod chain -----------------------------
# The point of the lab is that the replica is brought back by the ReplicaSet, not "the cluster in general".
# If the pod's owner turns out not to be a ReplicaSet, the participant created the pod by hand,
# and won't see self-healing.
# We count pods by name, rather than collecting unique owner kinds: a pod without
# ownerReferences makes jsonpath return an empty string, `sort -u` collapses it into an invisible
# element, and `*ReplicaSet*` matches as long as at least one pod is managed by a ReplicaSet.
# Because of that a foreign pod, created by hand, passed the check unnoticed.
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "there is no pod with the label app=${APP}" \
         "restore the app: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "no ${APP} pod is managed by a ReplicaSet — there will be no self-healing" \
         "looks like the pod was created by hand (kubectl run). Delete it and apply ../01-deploy/rickroll.yaml"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "the label app=${APP} is worn by foreign pods: ${PODS_BY_RS} of ${PODS_TOTAL} are managed by a ReplicaSet" \
           "the rest will end up in load balancing and serve a foreign response — find them: kubectl get pods -l app=${APP} -o wide"
      evidence "Pod owners" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "replicas are managed by a ReplicaSet — the Deployment → ReplicaSet → Pod chain is intact"
    evidence "Who owns whom" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- traces of replica recreation ------------------------------------------
# The cluster keeps no direct evidence that "the pod was killed". There are two indirect ones, both sufficient:
# the pod is noticeably younger than its Deployment, and in the ReplicaSet events there is more than one creation.
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "the replica is ${DELTA}s younger than the app — so the previous one was removed and this one created instead"
  else
    warn "the replica is almost the same age as the app (difference ${DELTA}s)" \
         "if you restored the whole app at the very end — that's fine; otherwise the pod-deletion step wasn't done"
  fi
  evidence "Object ages" "deployment created: ${DEP_TS}
pod created:        ${POD_TS}
difference:         ${DELTA}s"
else
  warn "couldn't compare the pod and app ages" \
       "python3 is needed in PATH; this doesn't affect passing the lab"
fi

# Events live about an hour, so their absence is not a failure but a remark.
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "cluster events show ${CREATES} replica creations — self-healing really did fire"
  evidence "Replica creation events" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "cluster events show replica creation only ${CREATES} time(s)" \
       "events are kept about an hour and may have expired"
fi

# Neither of the two signs is blocking on its own: events live about an hour,
# and the age matches for someone who legitimately restored the whole app at the end of the lab.
# But if NEITHER holds — the replica wasn't deleted at all, and the lab isn't done. Without this
# pairing the script printed "LAB PASSED" right after lab 1, without waiting for a single deletion.
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "no traces of self-healing found: the replica wasn't deleted" \
       "delete the replica: kubectl delete pod -l app=${APP} — and run the check within an hour, while events are alive"
fi

# --- the service actually serves -------------------------------------------
# The main substantive check: not "the object exists", but "through the Service a page arrives
# and it contains the name of a live replica".
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} did not return a page from inside the cluster" \
       "check the endpoints: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "the page is served, but the replica name wasn't substituted into it" \
       "the ConfigMap rickroll-conf is lost: apply ../01-deploy/rickroll.yaml in full"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "the Service response has no replica name" \
         "the page came not from our app — check kubectl get svc ${APP} -o yaml"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "the Service serves a page, it was served by the live replica ${SERVED}"
    evidence "Service response (fragment)" \
      "$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "the page was served by replica ${SERVED}, but there is no such pod in the cluster anymore" \
         "wait ten seconds or so and run the check again — the replica was probably changing right now"
  fi
fi

# --- readiness for the next lab --------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "the replica count is back to one — lab 3 will start from a clean slate"
else
  warn "currently requested replicas: ${WANT}" \
       "before lab 3 restore one: kubectl scale deployment ${APP} --replicas=1"
fi

finish
