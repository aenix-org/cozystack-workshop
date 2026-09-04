#!/usr/bin/env bash
# Check for lab 14: observability actually works.
#
# "The participant looked at a graph" cannot be checked, and pretending it can be is dishonest.
# So we check what makes a graph possible in the first place:
#   1) the metrics collection agent is running in the cluster,
#   2) it sends what it collects to your tenant, not into the void,
#   3) log collection works too — without it half the lab is pointless,
#   4) there is a trace of the load from lab 3 in the cluster that can be found in the graphs.

LAB_NAME="14-observability"
LAB_TITLE="Lab 14 · Observability: find your own spike in the graphs"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- collection namespace ---------------------------------------------------
# The namespace by itself proves nothing: the platform also puts metrics-server there,
# which is installed on any cluster with etcd and does not depend on the addon. We check
# its presence only to tell "cluster unreachable" apart from "collection is off".
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "the cluster has no namespace ${MON_NS} — the cluster responded not as expected" \
       "enable the addon: dashboard -> Kubernetes -> lab -> edit -> Addons -> Monitoring agents. Note: records will appear only from this moment on"
  finish
  exit $?
fi

# --- metrics agent ----------------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "the metrics collection agent is running (vmagent pods: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "the metrics collection agent exists but is not running (${VMAGENT_RUNNING} of ${VMAGENT_TOTAL} in Running)" \
       "look at the cause: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "there is not a single vmagent pod in ${MON_NS} — the Monitoring agents addon is off" \
       "enable it: dashboard -> Kubernetes -> lab -> edit -> Addons -> Monitoring agents. Records start accumulating only from this moment on, the past cannot be brought back"
fi
evidence "Collection pods in ${MON_NS}" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- where exactly the metrics go -------------------------------------------
# A working agent that writes into the void looks exactly like a working one.
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "metrics are being sent to the tenant${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "metrics are being sent to an address that does not look like a tenant one" \
           "this may be fine if the host set up shared storage; the address is in the evidence"
      ;;
  esac
  evidence "Where metrics are sent" "$RW_URL"
else
  warn "could not read the metrics send address" \
       "look by hand: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- log collection ---------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "log collection works on all nodes (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "log collection is not running on all nodes (${FB_READY:-0} of ${FB_DESIRED})" \
       "look: kubectl -n ${MON_NS} get pods | grep fluent-bit — without it the log-search step will not work"
else
  warn "the fluent-bit log collector was not found" \
       "the vlogs-generic source in Grafana will be empty; the log-search step cannot be completed"
fi

# --- is there anything to look for in the graphs ----------------------------
# Metrics may be collected perfectly, but if there was no load, there is nothing to find.
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "there is a trace of load: autoscaling fired (last time ${LAST_SCALE})"
    evidence "Autoscaling state" "$(kubectl get hpa rickroll 2>/dev/null)
last fired: ${LAST_SCALE}
now replicas: ${CUR:-?}, desired: ${DES:-?}"
  else
    warn "autoscaling is configured but never fired" \
         "you will not find the replica-growth step; repeat the load from lab 3 with the fortio generator"
  fi
else
  warn "the cluster has no HorizontalPodAutoscaler named rickroll" \
       "the graph steps in this lab rely on lab 3; without it you will only find the CPU spike, not the step"
fi

# --- the application's own metrics ------------------------------------------
# Indirect but essential: if the application pods are alive, their consumption is in the graphs.
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "the application pods are in place (${APP_PODS} of them) — their consumption is visible in the graphs"
  evidence "Application pods" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "there are no rickroll application pods in the cluster" \
       "the historical metrics from the time of lab 3 are still preserved; just set that time range in Grafana"
fi

# --- where to find Grafana --------------------------------------------------
# Not a check but a help: the Grafana address is what participants search for the longest.
: "${COZY_KUBECONFIG:=$HOME/.kube/config}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "Grafana for your metrics: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
metrics of tenant ${TNS} are stored in namespace ${MON_TARGET}"
    else
      warn "your tenant's monitoring lives in ${MON_TARGET}, but the Grafana address could not be read" \
           "if ${MON_TARGET} is not your namespace, then Grafana is shared: ask the host for the address"
      evidence "Tenant monitoring" "namespace with monitoring: ${MON_TARGET}"
    fi
  else
    warn "could not determine where the metrics of tenant ${TNS} go" \
         "ask the host for the Grafana address or find it in the dashboard: Monitoring application -> Ingress"
  fi
else
  warn "the Grafana address is not determined" \
       "set COZY_TENANT and COZY_KUBECONFIG and the script will find it itself; this does not affect passing the lab"
fi

finish
