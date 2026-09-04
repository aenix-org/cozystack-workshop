#!/usr/bin/env bash
# Check for lab 11: the Android build ran to completion, and the APK reached the bucket.
#
# We check not "Job created", but three different claims, and they are not equal to each other:
#   1) the Job finished successfully,
#   2) an APK was actually built inside it (BUILD SUCCESSFUL),
#   3) the file actually reached object storage (the APK-UPLOADED marker).
# A Job can finish successfully and build nothing — if someone edited the script.
#
# Runs on the laptop, from this lab's folder, using access to the training cluster `lab`
# (not the tenant on the management cluster — the build runs in the cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/11-android && ./check.sh
#
# The script changes nothing in the cluster — it only reads and sends HTTP requests.
# Run it before cleanup: deleting the Job also deletes its logs, and without the logs
# there is nothing left to confirm two of the three claims above.

# These two variables are picked up by lib.sh — they go into the report header and into the
# file name report-<lab>-<date>.md, which the script places next to itself.
LAB_NAME="11-android"
LAB_TITLE="Lab 11 · Building a mobile app in the cluster"
# Shared checks library: from here come ok / fail / warn / evidence / finish,
# the in-cluster request and writing the report. The path is resolved from where the
# script itself lives, so running from any directory works the same way.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Stop right away if KUBECONFIG is not set. Without it kubectl looks for a cluster
# on the laptop itself, doesn't find one, and fails every check in a row with the same error,
# from which the real cause is not visible.
need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# The value of a secret key. base64 -d is not the same everywhere (BSD vs GNU),
# so we decode with python — it is already needed by the checks library.
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- secret with access to the bucket -------------------------------------
# We check not the existence of the secret, but that all four fields in it are filled in.
# The secret is created by hand, with four --from-literal in a row, and the most common trouble is
# an empty or missing value: the object is created successfully, but the build fails
# at the last step, once the build has already gone through. Cheaper to find out now.
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "secret ${SECRET} is in place, all four keys are filled in"
    # The key values do not go into the report — only the field names.
    evidence "Fields of secret ${SECRET}" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <hidden>
secretKey: <hidden>"
  else
    fail "in secret ${SECRET} the following fields are not filled in:${MISSING}" \
         "recreate the secret with the command from the README, the values are taken in the dashboard: Bucket -> builds -> Secrets"
  fi
else
  fail "there is no secret ${SECRET} in the cluster" \
       "create the secret: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (four fields)"
fi

# --- is storage reachable from inside the cluster --------------------------
# The most common cause of "the Job failed at step five" is not the keys, but that
# storage cannot be reached from the cluster. We check this separately from the build.
# The request goes from a pod, not from the laptop: the laptop has its own network and routes,
# and a successful response from it would say nothing about whether the build can reach there.
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  # No -k on purpose: the build talks to storage with certificate verification, and the check
  # must fail in the same place the Job would fail, not report green on an expired cert.
CODE="$(in_cluster_curl "https://${EP}/" "-o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "storage ${EP} responds from inside the cluster (HTTP ${CODE})"
      evidence "Storage response" "GET https://${EP}/ -> HTTP ${CODE}
Codes 403 and 404 are normal here: an anonymous request to the S3 root should be rejected."
      ;;
    5*)
      warn "storage ${EP} responds with error HTTP ${CODE}" \
           "the build may pass, but the APK upload won't; tell the instructor"
      ;;
    *)
      fail "storage ${EP} does not respond from inside the cluster" \
           "check the endpoint field in the secret: it must be WITHOUT https:// and without a trailing slash"
      ;;
  esac
else
  warn "not checking storage availability" \
       "first you need the secret ${SECRET} with the endpoint field"
fi

# --- the Job itself --------------------------------------------------------
# We look at .status.succeeded, not at the fact the Job exists: the object is created
# instantly and always successfully, while the task's success means the pod finished with code 0.
# The pod's state is examined separately, because "still running" and "stuck in Pending" are
# different news for a human: the first means wait, the second means waiting is pointless
# and the node needs to be scaled up.
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "there is no Job ${JOB} in the cluster" \
       "start the build: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} finished successfully"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
finished: ${DURATION:-unknown}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "the build pod is stuck in Pending — it has not started and won't start on its own" \
         "look at the reason: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; on Insufficient memory scale the node up to u1.large — how to do it is written in the README"
    evidence "Build pod events" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} finished with an error (failed attempts: ${FAILED})" \
         "look at the last log lines: kubectl logs job/${JOB} --tail=40"
    evidence "Tail of the failed build log" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} has not finished yet (pod state: ${POD_PHASE:-unknown})" \
         "the first build takes from a couple of minutes to a quarter of an hour, depending on the connection; watch: kubectl logs -f job/${JOB}"
  fi

  # --- what exactly happened inside ---------------------------------------
  # A successful Job by itself proves nothing beyond a zero return code.
  # So we open up the log and look in it for two different pieces of evidence: BUILD SUCCESSFUL —
  # that compilation ran to completion, and the marker line APK-UPLOADED, which the script prints
  # only after copying the file to the bucket. The second is stronger than the first: the APK may
  # be built and left lying inside the pod, which is about to disappear.
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "build logs are unavailable" \
         "the build pod is deleted or not yet created; without logs it's impossible to confirm the APK was actually built"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "the APK was actually built (${GRADLE_LINE})"
    else
      fail "there is no BUILD SUCCESSFUL line in the logs — compilation did not run to completion" \
           "look for the first line with FAILURE: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "the APK reached the bucket: ${UPLOADED}"
      evidence "Bucket contents after the build" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "the APK was built, but did not reach the bucket" \
           "look at the tail of the log: kubectl logs job/${JOB} --tail=20; most often bucketName is to blame — it needs the long name from the dashboard, not 'builds'"
    fi
  fi
fi

# --- does the node have enough room for a build like this -------------------
# Not a verdict, but an explanation: if the Job didn't fit, the cause is almost always here.
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "the largest node offers ${BIGGEST_H} of memory — enough for the build"
      else
        warn "the largest node offers only ${BIGGEST_H} of memory" \
             "the build asks for 4Gi in requests alone; if the Job is stuck in Pending, scale the node type up to u1.large — how, is written in the README"
      fi
      ;;
    *)
      warn "the nodes have less than a gigabyte of available memory (${BIGGEST_H})" \
           "an Android build won't fit there, scale the node type up — how, is written in the README"
      ;;
  esac
  evidence "Node resources" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
