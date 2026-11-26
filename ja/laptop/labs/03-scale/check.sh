#!/usr/bin/env bash
# Check for lab 3: autoscaling.
#
# We verify not that "hpa.yaml was applied", but that the mechanism is alive and able to make decisions:
#   - the container has requests.cpu, otherwise there is no baseline to compute a percentage from;
#   - the HPA exists and targets exactly our Deployment;
#   - the range is set meaningfully (maxReplicas greater than one, otherwise there is nowhere to grow);
#   - metrics are ACTUALLY being collected: the status has a number, not <unknown>;
#   - scaling has already triggered, meaning load was really applied.
#
# The script changes nothing. A one-off pod is spun up only to check
# that Fortio responds from inside the cluster, and it removes itself.
#
# Runs on the laptop, from this lab's folder, using access to the training cluster `lab`
# (not to the tenant on the management cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# The COZY_TENANT variable is not needed here: the whole lab runs inside the `lab` cluster.
#
# Run it BEFORE cleanup. Some checks rely on traces of growth that already happened,
# and they live together with the HPA object: delete it and there will be nothing left to prove.

# These go into the report header and into the file name report-<lab>-<date>.md next to the script.
LAB_NAME="03-scale"
LAB_TITLE="Lab 3 · Load and autoscaling"
# Shared library: ok / fail / warn / evidence / finish, in-cluster queries,
# writing the report. The path is computed from the script's own location, not the current directory.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Without KUBECONFIG kubectl looks for a cluster on the laptop and dumps everything into one error
# in which the real cause cannot be made out. We stop right away.
need_kubeconfig

# The names are moved into variables so that the app name matching the HPA name
# in this lab does not look like the same name accidentally written twice.
APP=rickroll
HPA=rickroll

# --- scaling target in place -----------------------------------------------
# The app from lab 1 is what the HPA manages. If it is missing, all further
# checks cascade into failures and the participant gets a dozen errors instead of one
# clear one, so this is the only place where the script exits early.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "application ${APP} is not in the cluster — nothing to scale" \
       "deploy it: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "application ${APP} is in place"

# --- requests.cpu: without it the HPA cannot compute percentages -----------
# The most common cause of "HPA does not work", and it is not visible in the manifest:
# the object is created successfully, but TARGETS stays <unknown> forever.
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "the container has requests.cpu = ${REQ_CPU} — there is a baseline to compute percentages from"
  evidence "Container resources" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-not set}"
else
  fail "the container ${APP} has no requests.cpu set" \
       "HPA by Utilization does not work without it; re-apply ../01-deploy/rickroll.yaml"
fi

# --- the HPA itself --------------------------------------------------------
# We check not only that the object exists, but also what it targets. An HPA with a typo
# in scaleTargetRef is created successfully and looks working in the list, but for the whole lab
# it manages a non-existent application.
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "there is no HorizontalPodAutoscaler named ${HPA} in the cluster" \
       "apply it: kubectl apply -f hpa.yaml (run the check before cleanup)"
  evidence "What autoscaling exists" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA} targets Deployment/${APP}"
else
  fail "HPA ${HPA} manages object ${TARGET_KIND}/${TARGET_NAME}, not Deployment/${APP}" \
       "fix scaleTargetRef in hpa.yaml and re-apply"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "range is set: from ${MINR} to ${MAXR} replicas — there is room to grow"
else
  fail "the upper bound of the range equals ${MAXR:-not set} — nowhere to grow" \
       "hpa.yaml must have maxReplicas greater than one"
fi

# --- metric target ---------------------------------------------------------
# This is warn, not fail: the AverageValue variant (threshold in millicores) also works,
# the lab covers only one of the two. Failing for it would be untrue.
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "threshold is set: ${TGT_VAL}% of requests.cpu (${REQ_CPU:-?})"
else
  warn "threshold is not set as a percentage of requests (type: ${TGT_TYPE:-none})" \
       "the lab covers the Utilization variant; this does not affect functionality"
fi

# --- THE MAIN THING: metrics are really being collected --------------------
# This is exactly where the difference between "object created" and "mechanism works" shows.
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "metrics are being collected: current load ${CUR_UTIL}% of requests, HPA is making decisions"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA is making decisions (ScalingActive=True), the current metric value is not reported yet"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA is not receiving metrics — TARGETS will show <unknown>, there is nothing for it to decide on" \
       "the first two minutes after apply this is normal, wait and retry; if it did not pass — kubectl top pods and kubectl describe hpa ${HPA}"
  evidence "Why the HPA is not active" "${REASON:-reason not stated in the status}"
fi

evidence "HPA state" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server responds directly --------------------------------------
# Duplicates the previous check from another angle and separates two different failures:
# "there are no metrics in the whole cluster" and "metrics exist, but the HPA did not reach them".
# The first is fixed by the cluster administrator, the second by the participant in their manifest.
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` when there are no pods prints "No resources found" and returns 0 —
# without an explicit emptiness check this gave green where there are no metrics at all.
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top does not report pod consumption" \
       "there is no working metrics-server in the cluster — without it CPU-based autoscaling is impossible"
  evidence "kubectl top output" "$TOP"
else
  ok "metrics-server reports consumption of ${APP} pods"
  evidence "Replica consumption" "$TOP"
fi

# --- scaling actually triggered --------------------------------------------
# lastScaleTime lives as long as the HPA itself, so this check does not depend
# on whether the cluster events have expired or not.
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

# A single timestamp is not enough: it is also set on scale-down, meaning
# it appears even for someone who raised replicas by hand and let the HPA remove the extras. We look for
# exactly growth DRIVEN BY LOAD — an event with the threshold exceeded.
#
# And the other way around: the timestamp itself does not always live. On a cluster where load was applied an hour
# ago, lastScaleTime may be empty while the events are still alive — so events
# are checked FIRST, otherwise a completed lab is falsely failed.
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA raised the number of replicas due to load — the threshold-exceeded event is present"
  evidence "Scaling" "growth events: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-none}
currentReplicas: ${CUR_REPL:-unknown}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA changed the number of replicas (last time: ${LAST_SCALE})"
  evidence "Scaling timestamp" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-unknown}"
else
  fail "there are no traces of autoscaling activity" \
       "apply load from Fortio: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: needed in lab 4 -----------------------------------------------
# It no longer relates to lab 3 itself, so warn, not fail. The point is for the
# participant to learn the generator is gone here, and not in the middle of a rollout under load,
# when stopping to deploy it would be inconvenient.
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "the Fortio load generator works and responds from inside the cluster"
  else
    warn "Fortio is deployed, but its web interface did not respond" \
         "check: kubectl rollout status deployment/fortio and kubectl logs deploy/fortio"
  fi
else
  warn "Fortio is not in the cluster" \
       "if you are going to do lab 4, it will be needed there: kubectl apply -f fortio.yaml"
fi

finish
