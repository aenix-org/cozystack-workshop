#!/usr/bin/env bash
# Provision Lab 12 publishing (Service + Ingress) into workshop tenants — one run for all,
# instead of clicking it per tenant. Idempotent (kubectl apply); safe to re-run.
#
# Usage:
#   ./provision-spravochnik.sh --context <kube-context> --from 1 --to 70
#   ./provision-spravochnik.sh --context admin@workshop --tenants "04 05 06"
#   ./provision-spravochnik.sh --context admin@workshop --from 1 --to 70 --dry-run
#
# Assumes tenant namespaces are named tenant-workshopNN (zero-padded to 2) and the domain is
# spravochnik.workshopNN.workshop.aenix.io. Adjust DOMAIN_SUFFIX if your stand differs.
set -euo pipefail
CTX=""; FROM=""; TO=""; TENANTS=""; DRYRUN=""
MANIFEST="$(dirname "$0")/spravochnik-publish.yaml"
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2;;
    --from) FROM="$2"; shift 2;;
    --to) TO="$2"; shift 2;;
    --tenants) TENANTS="$2"; shift 2;;
    --dry-run) DRYRUN="--dry-run=server"; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$CTX" ] || { echo "--context is required" >&2; exit 2; }
if [ -z "$TENANTS" ]; then
  [ -n "$FROM" ] && [ -n "$TO" ] || { echo "give --tenants or --from/--to" >&2; exit 2; }
  TENANTS="$(seq -w "$FROM" "$TO")"
fi
ok=0; skip=0
for n in $TENANTS; do
  nn="$(printf '%02d' "$((10#$n))")"
  ns="tenant-workshop${nn}"
  if ! kubectl --context "$CTX" get ns "$ns" >/dev/null 2>&1; then
    echo "[skip] $ns — namespace not found"; skip=$((skip+1)); continue
  fi
  sed -e "s/__NS__/${ns}/g" -e "s/__N__/${nn}/g" "$MANIFEST" \
    | kubectl --context "$CTX" apply $DRYRUN -f - >/dev/null
  echo "[ ok ] $ns — spravochnik-http + spravochnik (spravochnik.workshop${nn}.workshop.aenix.io)"
  ok=$((ok+1))
done
echo "done: applied=$ok skipped=$skip"
