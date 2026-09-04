#!/usr/bin/env bash
# Check for lab 12: the migrated virtual machine is published externally through the
# platform's ingress and domain — exactly like the containerized application.
#
# We verify not "objects created", but real, substantive operation:
#   1) the tenant's domain name returns HTTP 200 and it is the directory page,
#   2) the virtual machine itself is running (Ready),
#   3) the Ingress that publishes the machine is in place.
# The first item is the main one: it is the proof that the directory is visible externally.
#
# Runs on the VM, from this lab's folder. Requires tenant access and the tenant number:
#     export KUBECONFIG=~/.kube/config
#     export COZY_TENANT=workshopXX
#     cd labs/12-vm && ./check.sh
# The domain check works even without tenant access — curl is enough for it. Without tenant
# access the script does not fail: it skips the tenant-side checks and says so.
#
# The script changes nothing — it only reads and sends HTTP requests. Run it before cleanup:
# once the machine is deleted there is nothing left to check.

# These two variables are picked up by lib.sh — they go into the report header and into the
# name of the report-<lab>-<date>.md file that the script writes next to itself.
LAB_NAME="12-vm"
LAB_TITLE="Lab 12 · A virtual machine next to containers"
# Shared check library: ok / fail / warn / evidence / finish come from here.
# The path is resolved relative to where the script itself lives, so running from any
# directory works the same way.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# The tenant number is required: both the namespace name and the domain name under which the
# directory is published are built from it. Without it there is nothing to check.
need_tenant

# The names we check. VM is the name of the machine ORDER, i.e. the VMInstance object;
# `kubectl get vminstance` is queried by it. The actually running instance is named
# differently: the platform deploys the order with the `vm-instance` chart, the chart name
# is glued to the release name, and you get vm-instance-spravochnik.
VM=spravochnik
NS="tenant-${COZY_TENANT}"
# The domain on which the host published the directory in advance through Ingress. The same
# address you open in the browser.
HOST="spravochnik.${COZY_TENANT}.workshop.aenix.io"
URL="http://${HOST}"

# Tenant access is not mandatory: the domain is checked with a plain curl. If KUBECONFIG is
# set and the tenant responds — we add checks for the machine state and Ingress.
TENANT_OK=0
if [ -n "${KUBECONFIG:-}" ] && kubectl -n "$NS" get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- the main thing: the directory is visible externally by domain ---------
# We take the response code and the body separately: the code distinguishes "nobody behind
# ingress yet" (503) from "points to the wrong place" (404) and "no domain at all" (000),
# while the body confirms that it is the directory answering, not a random stub.
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL" 2>/dev/null)"
BODY="$(curl -s --max-time 10 "$URL" 2>/dev/null)"

case "$CODE" in
  200)
    case "$BODY" in
      *"Справочник сотрудников"*)
        ok "directory published: ${URL} responds 200 and serves the directory page"
        evidence "Domain response" "request: ${URL}
response code: ${CODE}
$(printf '%s' "$BODY" | head -3)"
        ;;
      *)
        fail "${URL} returns 200, but this is not the directory page" \
             "something else is answering behind the domain; check that the directory is what listens on port 8080 inside the machine"
        ;;
    esac
    ;;
  503)
    fail "domain ${URL} responds 503 — there is no one behind the Ingress to answer yet" \
         "the machine is still booting or the directory service on 8080 has not come up; wait for the vminstance to be Ready and look at the machine console"
    ;;
  000)
    fail "domain ${URL} does not respond at all" \
         "check the network; the Ingress with this host is created by the host — if there is no domain at all, ask them"
    ;;
  *)
    fail "domain ${URL} responds ${CODE}, not 200" \
         "404 means the Ingress points to the wrong service; 5xx means the backend is not ready to answer"
    ;;
esac

# --- tenant side: the machine itself and its publication -------------------
if [ "$TENANT_OK" -eq 0 ]; then
  warn "tenant-side checks skipped: tenant not reachable via KUBECONFIG" \
       "provide tenant access: export KUBECONFIG=~/.kube/config"
else
  # We ask not "does the object exist", but the Ready condition: the machine order is created
  # in a second, but the guest comes up in three to five minutes, and all that time the
  # machine exists but the directory does not answer yet.
  if ! kubectl -n "$NS" get vminstance "$VM" >/dev/null 2>&1; then
    fail "there is no virtual machine ${VM} in tenant ${NS}" \
         "create a VM Disk and VM Instance in the dashboard or apply staff-directory-vm.yaml"
  else
    VM_READY="$(kubectl -n "$NS" get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "virtual machine ${VM} is running"
    elif [ -n "$VM_READY" ]; then
      fail "virtual machine ${VM} exists, but is not ready (Ready=${VM_READY})" \
           "look at the machine card in the dashboard; the first power-on takes 3-5 minutes"
    else
      warn "virtual machine ${VM} exists, but its state could not be read" \
           "look at it in the dashboard: it should be powered on"
    fi
    evidence "Tenant virtual machines" "$(kubectl -n "$NS" get vminstance 2>/dev/null)"
  fi

  # The Ingress is created by the host, not the participant. If the domain already responds
  # 200 — it is in place; we check it separately so that on 503/404 it is immediately clear
  # whether there is any publication at all.
  if kubectl -n "$NS" get ingress spravochnik >/dev/null 2>&1; then
    ok "Ingress spravochnik is in place — the directory is published in the tenant"
    evidence "Tenant Ingress" "$(kubectl -n "$NS" get ingress spravochnik 2>/dev/null)"
  else
    warn "Ingress spravochnik not found in tenant ${NS}" \
         "it is created by the host; if the domain already responds 200 there is nothing to worry about, otherwise contact the host"
  fi
fi

finish
