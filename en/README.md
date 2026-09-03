# Migrating from VMware to Cozystack: workshop and labs

Materials for people who administer VMware and want to understand what Cozystack is —
not from a slide deck, but hands-on. You don't need to know Kubernetes: everything is
explained as you go, through what you already know from vSphere.

## Two ways to take it — pick yours

The same workshop comes in two variants. They differ only in **where you work with the
cluster from**. The instructor will tell you which one is yours.

| | [`laptop/`](laptop/) — from your own laptop | [`bastion/`](bastion/) — through the bastion |
|---|---|---|
| **Tools** | you install them yourself: `kubectl`, `virtctl`, `kubelogin` | already installed on the bastion |
| **Cluster access** | kubeconfig from the dashboard, sign in through the browser | you log in over SSH, access already set up |
| **Tenant number in the files** | you fill it in yourself | filled in ahead of time |
| **Checking the app** | `virtctl port-forward` + `localhost:8080` | by domain name `app.<number>.workshop.aenix.io` |
| **For whom** | those without a shared bastion | a prepared testbed with a bastion |

Inside each folder is a self-contained set: its own `README.md` (the route), `chat/`
(the chat messages for each step), `manifests/`, `scripts/`. Open the README for your path
and follow it.

## Labs

Both folders contain `labs/` — sixteen standalone labs you work through at your own pace,
at home or during breaks. Each comes with its own check script (`check/`). The whole set is
about nine hours, not meant for a single sitting: take one per evening.

| Lab | About | Time |
|---|---|---|
| 0 · Your own cluster | get yourself a Kubernetes in ten minutes | 15 min |
| 1 · First application | deploy an application with one file and one command | 25 min |
| 2 · Self-healing | delete a replica and see what happens | 25 min |
| 3 · Scaling | apply load and watch the replicas grow | 30 min |
| 4 · Rollout and rollback | change the version under load, with no downtime | 30 min |
| 5 · Infrastructure in Git | describe everything in a repository and ship it with a push | 40 min |
| 6 · Your own registry | Harbor, building a Go service, deploying from your own registry | 45 min |
| 7 · Cache | Redis in front of a slow backend, the gain in numbers | 50 min |
| 8 · Secrets | move a password out of the manifest into OpenBao | 50 min |
| 9 · Analytics | a million rows and a report in milliseconds | 45 min |
| 10 · Documents | MongoDB where records have different shapes | 45 min |
| 11 · Mobile build | build an APK in the cluster, drop it into a bucket | 40 min |
| 12 · A VM alongside | legacy doesn't need to be containerized to move over | 30 min |
| 13 · Your own in the catalog | package an application as a Cozystack app | 40 min |
| 14 · Observability | find the traces of your own load in the graphs | 30 min |
| 15 · What to do on Monday | which system to start with and what to promise management | 20 min |

Links to the labs are in the README for your path: [`laptop/labs/`](laptop/labs/) or
[`bastion/labs/`](bastion/labs/).

## Housekeeping

* [`CONVENTIONS.md`](CONVENTIONS.md) — how the materials are written (for authors).
* [`REQUIREMENTS.md`](REQUIREMENTS.md) — what you need to bring up the testbed (for those
  preparing the workshop: quotas, the order in which tenants are created, the platform version).
