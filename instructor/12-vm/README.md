# Lab 12 (VM) — instructor setup

Lab 12 publishes each participant's VM on the tenant domain via a `Service` (`spravochnik-http`)
and an `Ingress` (`spravochnik`). Participants are told **not** to create these — they must
already exist in every tenant. This directory provisions them for the whole stand in one run,
so the setup is reproducible from the repo instead of being clicked per tenant.

## Provision all tenants

```bash
./provision-spravochnik.sh --context <kube-context> --from 1 --to 70
# or a subset:
./provision-spravochnik.sh --context <kube-context> --tenants "04 05 06"
# preview without applying:
./provision-spravochnik.sh --context <kube-context> --from 1 --to 70 --dry-run
```

Idempotent (`kubectl apply`) — safe to re-run before each cohort. Assumes tenant namespaces
`tenant-workshopNN` and domain `spravochnik.workshopNN.workshop.aenix.io`; edit
`spravochnik-publish.yaml` / the script if your stand differs.

The `Service` selector matches the pods KubeVirt labels for a VMInstance named `spravochnik`,
so endpoints stay empty until the participant's VM answers on `:8080` — which is the exact
`503 → page` transition Lab 12, Step 2 teaches.
