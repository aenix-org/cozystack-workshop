#!/usr/bin/env bash
# Check for lab 1: the application is deployed and genuinely working.
#
# "Genuinely" here means: the page is actually served over HTTP, it has the pod
# name substituted into it, and that name matches the name of a really running replica.
# Checking that a Deployment object exists is pointless — it can exist and not work.
#
# Runs on the VM, from this lab's folder, using access to the training cluster `lab`
# (not to the tenant on the management cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/01-deploy && ./check.sh
# The COZY_TENANT variable is not needed here: the whole lab runs inside the `lab` cluster.
#
# The script changes nothing in the cluster — it only reads and sends HTTP requests.
# Run it before cleanup: after deleting the application there will be nothing to check.

# These two variables are picked up by lib.sh — they go into the report header and into the
# file name report-<lab>-<date>.md that the script writes next to itself.
LAB_NAME="01-deploy"
LAB_TITLE="Lab 1 · First application"
# The shared checks library: from here come ok / fail / warn / evidence / finish,
# the in-cluster page request and writing the report. The path is computed from where
# the script itself lives, so running from any directory works the same.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Stop immediately if KUBECONFIG is not set. Without it kubectl looks for a cluster
# on the VM itself, doesn't find one, and fails every check in a row with the same error
# that hides the real cause.
need_kubeconfig

# --- application object -----------------------------------------------------
# First line of defense: the application is actually set up and at least one replica reached readiness.
# We look at .status.readyReplicas, not at the mere existence of the Deployment: the object
# is created instantly and always successfully, whereas readiness means a replica came up,
# passed its readiness probe and is able to respond.
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # Special case: the object exists but zero replicas are requested for it. The message
    # "no replica is ready (0 needed)" would sound like nonsense.
    fail "application stopped — 0 replicas requested" \
         "bring a replica back: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "application deployed, ${READY} of ${DESIRED} replicas ready"
    # A stuck rollout doesn't take the service down: the old replica keeps working, and
    # readyReplicas stays at one. Without this check the participant leaves with a green
    # check mark and a deployment that is forever stuck in ErrImagePull.
    # We look at the replicas themselves, not only at ProgressDeadlineExceeded: the deadline
    # fires after ten minutes, while the script is run right away. The old replica keeps
    # working meanwhile, readyReplicas stays at one, and without this check the participant
    # leaves with a green check mark and a deployment stuck in ImagePullBackOff.
    STUCK="$(kubectl get pods -l app=rickroll \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="ImagePullBackOff" || $2=="ErrImagePull" || $2=="CrashLoopBackOff" || $2=="CreateContainerConfigError" {print $1" ("$2")"}')"
    PROG_REASON="$(kubectl get deployment rickroll \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null)"
    if [ -n "$STUCK" ] || [ "$PROG_REASON" = "ProgressDeadlineExceeded" ]; then
      fail "rollout is stuck: the new replica won't come up, only the old one is working" \
           "look at kubectl get pods -l app=rickroll — usually the image didn't pull; restore a working state: kubectl apply -f rickroll.yaml"
      evidence "Replicas that won't start" "${STUCK:-cause in Deployment status: $PROG_REASON}"
    fi
  else
    fail "application created, but no replica is ready (${DESIRED} needed)" \
         "look at kubectl get pods -l app=rickroll and kubectl describe deployment rickroll"
    evidence "Pod state" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "no Deployment named rickroll found" \
       "apply the manifest: kubectl apply -f rickroll.yaml"
fi

# --- settings and page ------------------------------------------------------
# Both ConfigMaps are created by the same file as the application, so they can only
# disappear together with it or from manual deletion. We check them separately so that when
# the page breaks the participant immediately sees exactly what is missing: without rickroll-conf
# nginx won't substitute the pod name, and without rickroll-page-v1 there is nothing to compare
# the second version against in lab 4 and nowhere to roll back to.
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "settings in place: ConfigMap ${cm}"
  else
    fail "ConfigMap ${cm} not found" \
         "it's created by the same file: kubectl apply -f rickroll.yaml"
  fi
done

# --- stable address ---------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # A Service without endpoints is a typical and unnoticed breakage: the object exists,
  # but the labels on the pods didn't match the selector, and behind the address it's empty.
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "stable address works, replicas behind it: ${EPS_N}"
    evidence "Addresses behind the service" "$EPS"
  else
    fail "Service rickroll exists, but there is no replica behind it" \
         "usually the cause is that the pod labels didn't match the service selector — check app: rickroll"
  fi
else
  fail "no Service named rickroll found" \
       "it's created by the same file: kubectl apply -f rickroll.yaml"
fi

# --- the main thing: the page is actually served ----------------------------
# This is the check everything was set up for. All the previous ones only say that the objects
# in the cluster are described correctly; this one — that the user gets the page. The request goes
# FROM INSIDE the cluster, with a one-off pod: from outside the rickroll address doesn't exist, and
# port-forward here would test your VM, not the cluster.
# We request several times: with several replicas behind the service a single sample
# may miss the substituted one, and the check goes green on someone else's content.
BODY="$(in_cluster_curl_many 'http://rickroll/' 8)"
# The marker must appear EXACTLY ONCE per page, otherwise the response counter lies:
# "Never Gonna Give You Up" is in both <title> and <h1>, and gave a doubling.
ANSWERS="$(printf '%s' "$BODY" | grep -c 'вас обслужил под')"
TOTAL_LINES="$(printf '%s' "$BODY" | grep -c '<title>')"
if [ "${ANSWERS:-0}" -ge 1 ] && [ "${ANSWERS:-0}" -eq "${TOTAL_LINES:-0}" ]; then
  ok "application responds over HTTP and serves its page (${ANSWERS} requests checked)"
elif [ "${ANSWERS:-0}" -ge 1 ]; then
  fail "not only your application responds behind the service: your page came back ${ANSWERS} times out of ${TOTAL_LINES}" \
       "someone else carries the label app=rickroll — look at kubectl get pods -l app=rickroll and remove the extras"
else
  fail "the application did not serve the expected page" \
       "check manually: kubectl port-forward svc/rickroll 8080:80, then open http://localhost:8080"
  evidence "What came back instead of the page" "$(printf '%s' "$BODY" | head -20)"
fi

# --- pod name substitution --------------------------------------------------
# This is what the lab was made for: the name in the page must match the real pod.
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
# We take the pods managed by the application's ReplicaSet, and NOT everything that carries the
# label app=rickroll. Otherwise a foreign pod with such a label ends up in the list of "real" ones
# and confirms itself — verified, an impostor passed the check that way.
REAL_PODS="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
STRAY="$(kubectl get pods -l app=rickroll \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | awk '$2!="ReplicaSet" {print $1}')"
if [ -n "$STRAY" ]; then
  fail "foreign pods carry the label app=rickroll — they will be included in load balancing" \
       "remove the extras: $(printf '%s' "$STRAY" | tr '\n' ' ')"
  evidence "Foreign pods under the application's label" "$STRAY"
fi

if [ -z "$SERVED_BY" ]; then
  fail "the page has no pod name" \
       "check that the ConfigMap rickroll-conf was substituted — it has the line sub_filter '__POD__' '\$hostname'"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "the pod name wasn't substituted — the placeholder __POD__ is left in the page" \
       "nginx didn't apply sub_filter: check that the settings volume is mounted at /etc/nginx/conf.d"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "the pod name is substituted and matches a really running replica: ${SERVED_BY}"
  evidence "Who served the request" "$SERVED_BY"
  evidence "Running replicas" "$REAL_PODS"
else
  fail "the page names the pod \"${SERVED_BY}\", but there is no such pod in the cluster" \
       "the replica may have been recreated between the request and the check — run the script again"
fi

# --- readiness probe is configured ------------------------------------------
# Without it the lab about version rollout will have downtime, and the participant will decide we lied.
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "readiness probe is configured (${PROBE_PATH}) — the update will proceed without downtime"
else
  warn "the application has no readiness probe" \
       "lab 4 about zero-downtime updates will produce errors on such an application — restore readinessProbe from rickroll.yaml"
fi

finish
