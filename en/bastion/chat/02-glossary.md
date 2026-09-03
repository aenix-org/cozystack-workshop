## 2. A little glossary: what it's called on your side and what it's called here

**One message you can come back to**

Half the confusion at workshops isn't about the technology — it's about the words. Below is the
translation. Wherever the analogy is misleading, I say honestly where exactly: a wrong analogy is worse than
none at all.

| In vSphere | In Cozystack / Kubernetes | Where the analogy is misleading |
|---|---|---|
| Virtual machine | **VM Instance** | Nothing is misleading here — that's exactly what it is |
| VM disk | **VM Disk** | A separate object. There's no VM without a disk, so the disk is always created first |
| VM template | An image in the catalog | — |
| Application container | **Pod** | A Pod is disposable. You don't fix it — you delete it, and a new one is created |
| vApp | **Deployment** | — |
| Resource pool | **Tenant** with a quota | A tenant is also an access boundary: an outsider can't peek inside |
| vCenter | API server | The dashboard is a face for it, not the thing itself |
| HA | A **Deployment** keeps N copies | Not "brings a crashed one back up," but "always keeps as many as you asked for" |
| Load balancer pool | **Service** | — |
| Datastore | **Storage Class** | `replicated` — replicated across three nodes, `local` — without replication |
| A separate VM with Postgres | **Postgres from the catalog** | Comes with replication and backups, updates itself |
| A ticket to the IT department | *no analogy* | You do it yourself, in a minute |

⚠️ **Don't confuse the two "VMs".** On this path the word "VM" means the **bastion** —
the shared machine you logged into over SSH and from which you drive the cluster. And the machine
you'll spin up inside the cluster (the converter, then the app-VM) is a **VM Instance**, and we
call it "your machine" or "app-VM". The bastion is where you issue commands from; the app-VM is
what you create inside the cluster. You type `kubectl`/`virtctl` commands on the bastion, while
`netfix`, the database schema, and `psql` happen inside the app-VM (via `virtctl console`).

**One thing you'll have to get used to.** In vSphere you **create** an object: you click —
it appears, and from then on it lives on its own. Here you **describe the desired state**, and the
cluster constantly compares it with the actual state and eliminates the difference. So if you delete
something, it may come back — not because of a glitch, but because you never revoked the desire.
