#!/bin/bash
# Stage 1, on the platform: tenant, access, cluster, switch VM and dashboard route
# for each participant. Tenants are created strictly one at a time: creating many
# at once starves the Flux helm-controller and the installs time out.
# usage: KCTX=admin@workshop ./provision-platform.sh dallas01 dallas02 ...
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
k() { kubectl --context "${KCTX:?set KCTX}" "$@"; }
for u in "$@"; do
  echo "== $u: tenant"
  cat <<YAML | k apply -f -
apiVersion: apps.cozystack.io/v1alpha1
kind: Tenant
metadata: {name: $u, namespace: tenant-root}
spec: {etcd: false, gateway: false, host: "", ingress: false, monitoring: false, seaweedfs: false,
       resourceQuotas: {cpu: "40", memory: 48Gi}}
YAML
  for _ in $(seq 1 60); do
    [ "$(k -n tenant-root get tenant "$u" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] &&
      k get ns "tenant-$u" >/dev/null 2>&1 && break
    sleep 5
  done
  echo "== $u: access, cluster, switch VM, dashboard route"
  for f in access cluster switch-vm dashboard-ingress; do
    sed "s/dallasXX/$u/g" "$here/$f.yaml" | k apply -f - || echo "!! $u: $f failed"
  done
done
