#!/usr/bin/env bash
# Check for lab 5: the cluster state arrives from Git and is held in place by reconciliation.
#
# Runs against your `lab` cluster, from the lab folder, by you:
#     export KUBECONFIG=~/lab.kubeconfig
#     ./check.sh
# It changes nothing — it only looks and prints a report: what was checked, what passed,
# what did not, and the attached evidence.
#
# We check not "Flux is installed" but "the mechanism works": the source is read, what is
# applied belongs to Flux, the service responds, reconciliation is not turned off. An installed
# but suspended Flux is the most common way to pass the lab while missing its point.

LAB_NAME="05-gitops"
LAB_TITLE="Lab 5 · Infrastructure in Git"
# The shared harness for all labs: it provides ok / fail / warn / evidence / finish and
# the environment checks. The path is resolved from the location of this file, so the script
# can be run from any folder.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Without a cluster access file there is nothing to check — exit right away with a clear reason.
need_kubeconfig

# The names that the lab creates. Gathered in one place: if the participant named the objects
# differently, fix them here instead of hunting for names across the whole script.
NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# Read a field of an object without failing if the object or the CRD is missing.
kget() { kubectl get "$@" 2>/dev/null; }

# --- Flux services ---------------------------------------------------------
# We check not "the pods exist" but "at least one replica is Ready": a pod can hang in
# Pending with no memory on the node and still show up in the get pods output.
# Both services are required and split the work: source-controller downloads the repository,
# kustomize-controller applies what was downloaded. Without the second one nothing reaches the cluster.
if ! kget namespace flux-system >/dev/null; then
  fail "the cluster has no flux-system namespace" \
       "Flux is not installed: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "Flux services are running: source-controller and kustomize-controller"
    evidence "Flux pods" "$(kget pods -n flux-system -o wide)"
  else
    fail "Flux services are not running:${FLUX_BAD}" \
         "see kubectl get pods -n flux-system; on a small node they may be short on memory"
  fi
fi

# --- source: GitRepository ------------------------------------------------
# Three different outcomes, and they must not be confused: the object does not exist at all;
# the object exists but still holds the placeholder address; the object exists with a real
# address, but Flux could not read the repository. The advice differs in each case, so the branches differ.
#
# We take the success signal from status.conditions — that is what Flux reports about itself
# after trying to reach Git, not our guess based on the object's presence.
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "the cluster has no GitRepository type" \
       "Flux is not installed, or installed without source-controller"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "no GitRepository named ${GITREPO} found in flux-system" \
         "apply flux/gitrepository.yaml, substituting your own repository address"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "the GitRepository still holds the placeholder address" \
         "open flux/gitrepository.yaml and enter the address of your own GitHub repository"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux reads your repository: ${GR_URL}"
    evidence "Source in Git" "url: ${GR_URL}
revision: ${GR_REV:-unknown}"
  else
    fail "Flux cannot read the repository ${GR_URL}" \
         "see flux get sources git; most often it is a typo in the address, a private repository, or a different branch"
    evidence "Source error" "${GR_MSG:-no message}"
  fi
fi

# --- application: Kustomization ----------------------------------------------
# Here we check not the fact of application, but three properties of the mechanism without
# which the lab loses its meaning: the applied revision matches Git, reconciliation is not
# suspended, and pruning of what disappeared from the repository is enabled.
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "the cluster has no Kustomization type" \
       "Flux is installed without kustomize-controller — reinstall with both components"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "no Kustomization named ${KUSTOMIZATION} found in flux-system" \
         "apply flux/kustomization.yaml"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux applied the state from Git, revision ${KS_REV}"
    evidence "Applied revision" "$KS_REV"
  else
    fail "Flux could not apply the state from Git" \
         "see flux get kustomizations and kubectl describe kustomization ${KUSTOMIZATION} -n flux-system"
    evidence "Apply error" "${KS_MSG:-no message}"
  fi

  # A suspended Flux looks installed and does nothing. This is the main way to "pass"
  # the lab without gaining a single one of its benefits.
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "reconciliation is suspended (suspend: true) — Flux is not watching the cluster" \
         "turn it back on: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "reconciliation is active: drift from Git will be corrected on its own, interval ${KS_INTERVAL:-default}"
  fi

  # This is a warn, not a fail: without prune the cluster is still managed from Git, the lab is passed.
  # But the description becomes one-sided — deleting a file deletes nothing in the cluster.
  if [ "$KS_PRUNE" = "true" ]; then
    ok "pruning of what disappeared from Git is enabled (prune)"
  else
    warn "prune is off — what was removed from the repository keeps running in the cluster" \
         "set prune: true in flux/kustomization.yaml, otherwise Git describes only half of the state"
  fi
fi

# --- the objects in the cluster belong to Flux, not applied by hand ---------
# This is the key check of the lab, and it is about origin, not presence. The application
# is in the cluster in both cases: whether Flux brought it in, or the participant applied
# the same files by hand via kubectl apply. Externally they are indistinguishable — the Deployment is identical.
# The owner label tells them apart: only kustomize-controller sets it, when it applies
# the contents of the repository. An object applied by hand will not get that label.
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "namespace ${NS_APP} has no passes application" \
       "put app/*.yaml into the apps folder of your repository, push, and wait for reconciliation"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "the application in the cluster belongs to Flux, not applied by hand"
else
  fail "the passes application exists, but Flux did not create it" \
       "remove it (kubectl delete ns ${NS_APP}) and let Flux deploy it from Git anew"
fi

# --- the application actually responds --------------------------------------
# An object in the cluster and a working service are different things: a Deployment may be
# created while the pods crash in a loop. So we go inside the cluster and request the service
# by its internal name — the same path a neighboring application would use to reach it.
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Guest Pass'; then
  ok "the «Guest Pass» service responds over HTTP inside the cluster (running replicas: ${PODS_READY})"
else
  fail "the «Guest Pass» service does not respond at passes.${NS_APP}.svc.cluster.local" \
       "see kubectl get pods -n ${NS_APP} and kubectl logs -n ${NS_APP} deploy/passes"
fi

# The pod name on the page must match a really running replica: this shows that the response
# comes from exactly the pod we see in the cluster, and not a cached answer or some other
# service that happened to take the same name. A mismatch is a warn, not a fail: a replica
# could have been recreated between the two requests, and that is not the participant's fault.
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "the page was served by a really existing pod ${SERVED_POD}"
  evidence "Service replicas" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "the pod ${SERVED_POD} from the response was not found among the running ones" \
       "most likely the replica was recreated between the two requests — run the check again"
fi

# --- the change history in your clone of the repository ----------------------------
# An optional part: the script does not know where the clone lives until it is told.
# What is checked here is the way of rolling back. With kubectl rollout undo the cluster also
# returns to the previous version, but Git will not know about it, and the very next reconciliation
# will bring the bad change back. So we look for a revert in the history — the rollback is made
# where the truth lives. And we verify that the revision applied in the cluster matches your HEAD:
# committing and forgetting to push is common, and from the outside it looks like "Flux is stuck".
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "the repository history was not checked: the LAB_REPO variable is not set" \
       "to check it too: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "there is no clone of the repository in ${REPO}" \
       "specify the folder into which you did git clone"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "the history has a rollback via git revert — the bad change was undone where the truth lives"
    evidence "Change history" "$LOG"
  else
    fail "there is no single revert in the recent commits" \
         "roll back the bad change with git revert --no-edit HEAD and push, not with kubectl rollout undo"
  fi

  # What is applied in the cluster must match the latest commit in the branch.
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "the cluster runs exactly what is in your branch (commit ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "the commit in the cluster (${KS_REV:-unknown}) differs from the local HEAD (${HEAD_SHA})" \
         "check that the local commits are pushed (git push), and wait for the reconciliation interval"
  fi
fi

finish
