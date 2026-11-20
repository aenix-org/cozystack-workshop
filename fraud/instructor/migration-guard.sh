#!/bin/bash
# Works around a kube-ovn race on the workshop cluster: when a VM migration starts,
# kube-ovn skips preparing the VM port because the target node is not known yet,
# and the port then flaps between the two nodes. This loop does that preparation:
# as soon as the migration target pod is placed on a node, it marks the VM port as
# bound to both nodes (requested-chassis=src,dst, activation-strategy=rarp).
# kube-ovn resets the options itself when the migration ends.
# It only touches migrations in the workshop tenants (tenant-dallas*).
# Run it on the host's machine for the whole session:
#   KCTX=admin@workshop ./migration-guard.sh
set -uo pipefail
k() { kubectl --context "${KCTX:?set KCTX}" --request-timeout=20s "$@"; }
done_uids=" "
while true; do
  while read -r ns name uid phase vmi; do
    [ -n "$uid" ] || continue
    case "$ns" in tenant-dallas*) ;; *) continue ;; esac
    case "$phase" in Succeeded|Failed) continue ;; esac
    case "$done_uids" in *" $uid "*) continue ;; esac
    dst=$(k -n "$ns" get pods -l "kubevirt.io/migrationJobUID=$uid" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
    [ -n "$dst" ] || continue
    src=$(k -n "$ns" get vmi "$vmi" -o jsonpath='{.status.nodeName}')
    [ -n "$src" ] && [ "$src" != "$dst" ] || continue
    lsp="$vmi.$ns"
    # Only the OVN northbound leader accepts writes, so try every ovn-central pod.
    ok=""
    for pod in $(k -n cozy-kubeovn get pods -l app=ovn-central -o name); do
      if k -n cozy-kubeovn exec "$pod" -c ovn-central -- \
          ovn-nbctl lsp-set-options "$lsp" "requested-chassis=$src,$dst" activation-strategy=rarp 2>/dev/null; then
        ok=1; break
      fi
    done
    if [ -n "$ok" ]; then
      done_uids="$done_uids$uid "
      echo "$(date +%T) $ns/$name: port $lsp prepared for $src -> $dst"
    fi
  done < <(k get vmim -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.metadata.uid} {.status.phase} {.spec.vmiName}{"\n"}{end}' 2>/dev/null)
  sleep 1
done
