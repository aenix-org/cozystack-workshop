#!/usr/bin/env bash
# Check for lab 4: rolling out a new version and rolling back.
#
# We verify the substance, not the commands typed:
#   - the application history has several revisions, i.e. the version was actually changed;
#   - the second version's ConfigMap sits in the cluster as a separate object, not an edit of the first;
#   - the container has a readinessProbe — without it zero downtime is not reproducible;
#   - the rollout ran to completion and did not get stuck;
#   - the page served by the Service matches the ConfigMap that the spec
#     references. This catches the case "the spec was rolled back, but the pods weren't recreated".
#
# The script changes nothing. The one-off pod is only needed to fetch the page
# from inside the cluster and it removes itself.
#
# Runs on the VM, from this lab's folder, using access to the training cluster `lab`
# (not to the tenant on the management cluster):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/04-rollout && ./check.sh
# The COZY_TENANT variable is not needed here: the whole lab runs inside the `lab` cluster.
#
# Run it BEFORE cleanup and after the rollback has finished: the revision history lives
# together with the Deployment, and disappears together with it.

# These go into the report header and into the file name report-<lab>-<date>.md next to the script.
LAB_NAME="04-rollout"
LAB_TITLE="Lab 4 · Rolling out a new version and rolling back"
# Shared library: ok / fail / warn / evidence / finish, in-cluster requests,
# writing the report. The path is computed from the script's own location, not the current directory.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Without KUBECONFIG kubectl looks for a cluster on the VM and fails everything with a single error
# in which the real cause is impossible to make out. We stop right away.
need_kubeconfig

APP=rickroll

# --- application is in place and brought to a working state ------------------
# Without the application there is nothing to check, so this is the only early exit.
# Further on we look not only at the number of ready copies, but also at the reason in the
# Progressing condition: NewReplicaSetAvailable means the rollout is COMPLETE. Ready copies
# alone are not enough — with a stuck update the old version is running, the counter
# shows the expected number, yet the new copy never came up even once.
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "application ${APP} is not in the cluster" \
       "deploy it: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "rollout ran to completion: ${HAVE} of ${WANT} copies ready"
else
  fail "application is not in a completed state (${HAVE} of ${WANT} ready, reason: ${PROG_REASON:-none})" \
       "if the rollout is stuck — get out via rollback: kubectl rollout undo deployment/${APP}"
fi
evidence "Application state" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: what pays for zero downtime -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "the container has a readinessProbe (${PROBE}) — copies are replaced only after they are ready"
else
  fail "the container has no readinessProbe" \
       "without it the cluster sends traffic to a not-ready copy; apply ../01-deploy/rickroll.yaml"
fi

# --- versions made as separate objects --------------------------------------
# Both versions of the page must live in the cluster as two separate ConfigMaps.
# Whoever edited rickroll-page-v1 in place instead will see the new page on screen
# and decide the lab is done — but there will be nowhere to roll back to,
# and no copy replacement or revision-history entry will happen at all.
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2 sits in the cluster as a separate object"
else
  fail "there is no ConfigMap rickroll-page-v2 in the cluster" \
       "apply it: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "the first version of the page is also preserved — there is somewhere to roll back to"
else
  warn "ConfigMap rickroll-page-v1 not found in the cluster" \
       "a rollback to the first version without it will not bring the pods up: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- revision history -------------------------------------------------------
# We look at the NUMBER of the latest revision, not the number of lines in the history. A rollback
# does not add a new ReplicaSet — it reuses the old one and bumps its number,
# so after a rollback there are just as many lines in the history, while the number grows.
#   1 — the spec was never changed
#   2 — the version was switched
#   3 and more — switched and rolled back
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "the application's latest revision is ${REV_MAX}: the version was switched and rolled back"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "latest revision is 2: the rollout is done, the rollback is not yet" \
       "restore the first version: kubectl rollout undo deployment/${APP}"
else
  fail "latest revision is ${REV_MAX}: the application's spec was never changed" \
       "switch the volume to the second version with the patch from the lab, then roll back"
fi
evidence "Revision history" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- which version the spec points at --------------------------------------
# We look up the volume BY THE NAME page, even though the patch in the lab addresses it by index.
# The difference is exactly what gets caught here: if the patch went to the wrong list element,
# the name page will point at the previous ConfigMap or disappear, and the participant will learn
# about it in words, rather than through a strange nginx error.
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "the application spec has been rolled back to the first version of the page"
    ;;
  rickroll-page-v2)
    warn "the application spec points at the second version of the page" \
         "the lab ends with a rollback; if this is intended — nothing to worry about, otherwise: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "the spec has no volume named page" \
         "looks like the patch landed in the wrong place (addressing by index!); apply ../01-deploy/rickroll.yaml again"
    ;;
  *)
    fail "volume page points at ConfigMap ${VOL_CM}, which the lab did not create" \
         "roll back: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- what is actually served to the client ------------------------------------
# The most substantive check: we compare the spec with what the user sees.
# A mismatch here means the pods were not recreated for the new spec.
# Eight requests, not one. There are three copies behind the service; if the rollout did not fully converge,
# a single request has a one-in-three chance of hitting the right version and hiding the mismatch.
BODIES="$(in_cluster_curl_many "http://${APP}/" 8)"
BODY="$BODIES"

if [ -z "$BODY" ]; then
  fail "Service ${APP} did not return a page from inside the cluster" \
       "check the endpoints: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  # We detect both versions POSITIVELY, each by its own marker. The "if not v2, then
  # v1" branch counted anything as the first version: the default nginx page, a 404, someone else's
  # application, garbage — verified, on garbage the script would print "LAB PASSED".
  if printf '%s' "$BODY" | grep -q 'VERSION 2'; then
    SERVED_VER="rickroll-page-v2"
  elif printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
    SERVED_VER="rickroll-page-v1"
  else
    SERVED_VER=""
    fail "the service address serves something other than the application page" \
         "not a single familiar marker in the response — restore the original: kubectl apply -f ../01-deploy/rickroll.yaml"
    evidence "What was returned instead of the page" "$(printf '%s' "$BODY" | head -12)"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "the client is served exactly the version recorded in the spec (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "the spec points at ${VOL_CM}, but the client is served ${SERVED_VER}" \
         "the copies were not recreated for the new spec: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "the copy name is not substituted into the page" \
         "ConfigMap rickroll-conf is lost: apply ../01-deploy/rickroll.yaml in full"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "the page was served by a live copy ${SERVED_POD}"
    else
      warn "could not match the name from the page with a running copy" \
           "the copies were probably changing during the check itself — run the script again"
    fi
  fi

  evidence "Served page (fragment)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "served by pod<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- readiness for the next labs ------------------------------------------
# The lab scaled the copies up to three so the replacement could be seen one by one. The three
# leftover copies break nothing — hence a warn, not a fail — but they take up space on the training
# node, which the neighboring labs will run short of further on.
if [ "$WANT" = "1" ]; then
  ok "the number of copies has been returned to one"
else
  warn "currently requested copies: ${WANT}" \
       "after the lab it is worth returning to one: kubectl scale deployment ${APP} --replicas=1"
fi

finish
