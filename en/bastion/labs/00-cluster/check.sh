#!/usr/bin/env bash
# Check for lab 0: the training cluster is up and you have connected to it.
#
# We check not "the object was created", but that the cluster essentially works:
#   1) the lab cluster responds via your access file (KUBECONFIG=~/lab.kubeconfig),
#   2) at least one node is in the Ready state,
#   3) the nodes have free resources for future applications.
# If COZY_TENANT is set — additionally check on the MANAGEMENT cluster that the
# Kubernetes/lab order reached Ready and that metrics collection is enabled (without it lab 14 is empty).
#
# Run it on the VM, from this lab's folder:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # for tenant-side checks (optional)
#     cd labs/00-cluster && ./check.sh
#
# The script is read-only — it does not change the cluster state.
LAB_NAME="00-cluster"
LAB_TITLE="Lab 0 · Your own Kubernetes cluster"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Without access to the lab cluster itself there is nothing to check — this is the main
# proof of the lab. need_kubeconfig stops the script with a clear hint
# if KUBECONFIG is not set or the cluster does not respond.
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) Connection to the lab cluster ----------------------------------------
# need_kubeconfig already made sure the server responds. We record this as a separate
# result and put the server version into the report.
KVER="$(server_version)"
ok "lab cluster responds — the access file works"
[ -n "$KVER" ] && evidence "lab cluster server version" "$KVER"

# --- 2) Nodes in service -----------------------------------------------------
# Count how many nodes are in the Ready state. An empty list means the cluster
# is up, but the md0 node group is still deploying.
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "nodes in service: ${READY_NODES} of ${TOTAL_NODES} in Ready state"
  [ -n "$NODES_WIDE" ] && evidence "Cluster nodes" "$NODES_WIDE"
else
  fail "no node is in Ready state (nodes in total: ${TOTAL_NODES:-0})" \
       "wait a couple of minutes for the md0 node group to deploy; the status is in the dashboard on the lab application, or: kubectl get nodes"
  evidence "Cluster nodes" "${NODES_WIDE:-no nodes}"
fi

# --- 3) Is there room for future applications -------------------------------
# allocatable of the first node: if there are no resources, nothing will start further.
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "the nodes have resources for applications (on the node: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "Free node resources (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "could not read the free node resources" \
       "usually this is temporary — retry in a minute"
fi

# --- 4) From the management cluster side (if a tenant is set) -----------------
# Not required for lab 0: the connection to the cluster itself above already proved everything.
# But if tenant access is available — we confirm the order and check metrics collection.
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "tenant access ${COZY_KUBECONFIG} not found — the cluster order on the management cluster was not checked" \
         "this is not a lab failure; the path is set with: export COZY_KUBECONFIG=~/.kube/config"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "on the management cluster the Kubernetes/lab order is in Ready state"
    elif [ -n "$LAB_READY" ]; then
      warn "the Kubernetes/lab order is not Ready yet (currently: ${LAB_READY})" \
           "the cluster already responds, the platform is still reconciling it to the desired state; look at: kubectl --kubeconfig ~/.kube/config -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "could not find the Kubernetes/lab order in tenant ${TENANT_NS}" \
           "if you named the cluster differently — substitute your own name; or the role in the tenant does not allow this command (not a lab error)"
    fi
    # Metrics collection: lab 14 relies on data that accumulates from the moment it is enabled.
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "metrics collection is enabled (needed in lab 14)"
    elif [ -n "$LAB_READY" ]; then
      warn "metrics collection is disabled — lab 14 will be left without data" \
           "to enable: dashboard → lab application → Addons → Monitoring agents (metrics will not appear retroactively)"
    fi
  fi
else
  warn "COZY_TENANT is not set — management-cluster-side checks are skipped" \
       "not required for lab 0; to enable: export COZY_TENANT=workshopXX"
fi

finish
