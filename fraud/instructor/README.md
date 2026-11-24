# Preparing the fraud detection workshop

What the host creates before the session, for each participant `dallasNN`. Replace the `dallas` prefix with the city of your session.

| File | Where it goes | What it creates |
|---|---|---|
| `access.yaml` | platform, tenant namespace | service account and tenant roles for the bastion, plus the right to live-migrate VMs (Step 7) |
| `cluster.yaml` | platform | the participant's Kubernetes cluster `fraud` (one `u1.2xmedium` worker, autoscaler up to two) |
| `switch-vm.yaml` | platform | the switch VM on `replicated` storage, and the Service `switch` the cluster reaches it by |
| `dashboard-ingress.yaml` | platform | `https://fraud.dallasNN.workshop.aenix.io`, routed to NodePort 30080 of the cluster's workers |
| `terminals.yaml` | the participant's cluster | namespace `fraud`, service addresses, and the terminals already sending payments |

`provision-platform.sh` applies the first four for a list of participants:

```bash
KCTX=admin@workshop ./provision-platform.sh dallas01 dallas02 dallas03
```

It creates tenants strictly one at a time. Many tenants at once starve the Flux helm-controller, and the installs time out.

After a cluster is ready (its machine is `Running`), each participant gets on the bastion:

* a user with the dashboard password, and `~/workshop` with `README.md`, `manifests/` and `app/`, where `tenant-dallasXX` and `dallasXX` in `manifests/` are replaced with the participant's own name;
* `~/.kube/config` with two contexts: `tenant` (the service account token, namespace `tenant-dallasNN`) and `fraud` (the cluster's admin credentials; server `https://kubernetes-fraud.tenant-dallasNN.svc.cozy.local:6443` with `tls-server-name: kubernetes-fraud.tenant-dallasNN.svc`, because the API certificate does not include the `cozy.local` name);
* `terminals.yaml` applied with the `fraud` context.

## Things that bite

* **The Ubuntu 24.04 image is 20 GiB**: a VM disk cloned from it must be at least that big, or the DataVolume stays `Pending` with `CloneValidationFailed`.
* **`cx1.*` instance types need hugepages**; worker VMs of that type stay `Scheduling` on nodes without them. `u1.*` types work.
* **The `ubuntu` instance profile needs 2 GiB of memory**: `u1.small` or bigger.
* **Kafka advertises its brokers by short names** (`…tenant-dallasNN.svc`). Pods in the participant's cluster resolve them because every workload has `dnsConfig.searches: [cozy.local]`. The switch VM resolves them through its own DNS search list.
* The **monitor** in [`../../instructor/monitor`](../../instructor/monitor) records every participant's bastion terminal for the host.

## Step 7: keep the migration guard running

On the workshop cluster, kube-ovn v1.15 skips preparing the VM port for a live migration while the target node is still unknown, so the port then flaps between the two nodes and the migration hangs or the VM loses its network. Start [`migration-guard.sh`](migration-guard.sh) before the session and leave it running until the end:

```bash
KCTX=admin@workshop ./migration-guard.sh
```

It marks the port of every migrating VM in `tenant-dallas*` as bound to both nodes as soon as the target pod is placed, which is what kube-ovn should have done; kube-ovn resets the options when the migration ends. With it, a migration takes about fifteen seconds and the terminals repeat a few dozen authorizations, none of them fail.

Before the session, also apply [`prepull.yaml`](prepull.yaml) in each participant cluster: the llama.cpp image takes several minutes to download on first use.

After a dry run, [`reset-participant.sh`](reset-participant.sh) returns an environment to its starting state.
