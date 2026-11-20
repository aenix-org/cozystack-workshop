# Preparing the fraud detection workshop

What the host creates before the session, for each participant `dallasNN`.
Replace the `dallas` prefix with the city of your session.

| File | Where it goes | What it creates |
|---|---|---|
| `access.yaml` | platform, tenant namespace | service account and tenant roles for the bastion, plus the right to live-migrate VMs (Lab 7) |
| `cluster.yaml` | platform | the participant's Kubernetes cluster `fraud` (one `u1.2xmedium` worker, autoscaler up to two) |
| `switch-vm.yaml` | platform | the switch VM on `replicated` storage, and the Service `switch` the cluster reaches it by |
| `dashboard-ingress.yaml` | platform | `https://fraud.dallasNN.workshop.aenix.io`, routed to NodePort 30080 of the cluster's workers |
| `terminals.yaml` | the participant's cluster | namespace `fraud`, service addresses, and the terminals already sending payments |

`provision-platform.sh` applies the first four for a list of participants:

```bash
KCTX=admin@workshop ./provision-platform.sh dallas01 dallas02 dallas03
```

It creates tenants strictly one at a time. Many tenants at once starve the Flux
helm-controller, and the installs time out.

After a cluster is ready (its machine is `Running`), each participant gets on the
bastion:

* a user with the dashboard password, and `~/workshop` with `README.md`,
  `manifests/` and `app/`, where `tenant-dallasXX` and `dallasXX` in
  `manifests/` are replaced with the participant's own name;
* `~/.kube/config` with two contexts: `platform` (the service account token,
  namespace `tenant-dallasNN`) and `fraud` (the cluster's admin credentials;
  server `https://kubernetes-fraud.tenant-dallasNN.svc.cozy.local:6443` with
  `tls-server-name: kubernetes-fraud.tenant-dallasNN.svc`, because the API
  certificate does not include the `cozy.local` name);
* `terminals.yaml` applied with the `fraud` context.

## Things that bite

* **The Ubuntu 24.04 image is 20 GiB**: a VM disk cloned from it must be at least that
  big, or the DataVolume stays `Pending` with `CloneValidationFailed`.
* **`cx1.*` instance types need hugepages**; worker VMs of that type stay `Scheduling`
  on nodes without them. `u1.*` types work.
* **The `ubuntu` instance profile needs 2 GiB of memory**: `u1.small` or bigger.
* **Kafka advertises its brokers by short names** (`…tenant-dallasNN.svc`). Pods in
  the participant's cluster resolve them because every workload has
  `dnsConfig.searches: [cozy.local]`. The switch VM resolves them through its own DNS
  search list.
* The **monitor** in [`../../instructor/monitor`](../../instructor/monitor) records
  every participant's bastion terminal for the host.

## Lab 7: the live migration demo

Run it from a host account on the bastion (for example `dallas00`, prepared like a
participant), with its dashboard on the projector:

```bash
kubectl --context platform get vmi vm-instance-switch -o wide
kubectl --context platform create -f demo-migration.yaml
kubectl --context platform get vmim -w
```

Edit the target node in [`demo-migration.yaml`](demo-migration.yaml) first: it must
be a different node from the one in `get vmi`, with at least 2 GiB of free memory.
On the workshop cluster, kube-ovn v1.15 skips the migration port setup while the
target node is still unknown, so the VM port flaps between the two nodes and a
migration may hang in `Scheduling` or leave the VM without network for about ten
seconds. The terminals repeat unanswered authorizations, so no payment fails, and
the dashboard shows how many were repeated.
