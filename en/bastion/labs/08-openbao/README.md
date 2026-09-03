# Lab 8 · Secrets out of the manifest

| | |
|---|---|
| **Time** | 50 minutes, part of it spent waiting while the store comes up and you unseal it |
| **What it proves** | A password can be removed from Git for good and changed without touching a single file |
| **What you'll need** | The cluster from Lab 0 and `~/lab.kubeconfig`; access to your tenant's dashboard; a tenant number of the form `workshopXX` |

> ⚠️ **`workshopXX` is a placeholder, not a name.** Substitute your own tenant number,
> otherwise the command will go to someone else's tenant and you'll get an access-denied
> error — or worse, someone else's data. You were given your number together with your password.

> ⚠️ **A dense lab: eleven steps and an unfamiliar access model.**
> Plan it for an evening of its own.

## Why this matters

The Passes service works: an employee requests a pass for a guest, security sees the list.
The security team showed up for a routine audit and brought along a single line from your repository:

```yaml
- name: DB_PASSWORD
  value: "Propusk2019!"
```

The password for the passes database sits in a manifest. The manifest sits in Git. Git is visible
to twelve people across three teams, four more have left the company, and a full copy of the
repository lives on the VM of a contractor who did an integration last year.

The auditor's question sounds routine: **"change this password and show me who has read it over
the past month."** There's nothing to answer. Changing the password means finding every place it's
hardcoded; who has read it is unknown, because reading a file from Git is recorded nowhere.

In this lab we'll move the password into OpenBao, teach the application to fetch it from there,
change the password with a single command, and see what the system knows about it.

Along the way we'll settle a question almost everyone trips over: **how a Secret in Kubernetes
differs from a real secrets store.**

Every term in this lab is spelled out the first time it appears, and the next section is a glossary
of the ones already introduced.

## Glossary

| Term | What it is | Like… but |
|---|---|---|
| **Secret (Kubernetes)** | A cluster object holding data written in base64 | **A password file on a VM's disk**, but it looks protected and isn't — we take this apart below |
| **base64** | A way to write arbitrary bytes as printable characters | **uuencode, a MIME attachment**, but it isn't encryption. There's no key, and anyone can reverse it |
| **Secrets store** | A separate service: keeps secrets encrypted and hands them out by rule | **No direct analogue**, but it's not a "network folder full of passwords" — it's a service with policies, expiry, and a log |
| **OpenBao** | One such store. A fork of HashiCorp Vault, released under the MPL license | the commands and API match Vault; only the utility is named `bao` |
| **Root token** | An account with full access to everything | **root**, but you use it once during setup and then issue narrow tokens |

The rest of this lab's vocabulary — `sealed`, unseal key, policy, token, KV v2, rotation, audit log,
init container — is introduced as you go, in the step where each is first needed. There's no need to
memorize them now: divorced from the action, they won't stick anyway.

<details>
<summary><b>If you'd like the whole list up front</b></summary>

| Term | What it is | Like… but |
|---|---|---|
| **Sealed** | The service is running, but the master key isn't in memory: the data sits encrypted and the API refuses requests | **"The service came up, but the volume isn't mounted"**, but after every restart you have to unseal it again, by hand |
| **Unseal key** | A share of the master key that the store is unsealed with | **A key to a safe**, but there are several shares, and by default you must present more than one |
| **Policy** | A list of paths and what is allowed on them | **An ACL on a folder**, but the path is an address in the API, not a file on disk |
| **Token** | A temporary pass to the store | **A session**, but a token has a lifetime, expires on its own, and can be revoked |
| **KV v2** | A "key-value" engine with version history | **A folder of files with change history**, but it keeps every version and the timestamp of each write; the old value never disappears |
| **Rotation** | A scheduled replacement of a secret with a new one | **Changing a password on a schedule**, but here it's a single command, and the application picks it up on its next start |
| **Audit log** | A record of "who requested what, and when" | **An access log for a file share**, but a line is written for every API request, including failed ones and denials |
| **Secret zero** | The one secret an application uses to prove its right to all the others | it can't be removed entirely. It can be made short-lived, narrow, and single-use |
| **Init container** | A container that runs and finishes before the main one starts | **A startup script that runs before a service comes up**, but if it fails the main container doesn't start at all — which is exactly what you want |

</details>

## What's in the lab folder

You already have all the files — you got them with the repository. There's nothing to create or
retype: wherever the text below says `kubectl apply -f name.yaml`, the file comes from here.

```bash
cd labs/08-openbao
```

| File | What it is | When you'll use it |
|---|---|---|
| `openbao.yaml` | An order for a secrets store — the same as the button in the dashboard | you apply it **in the tenant**, not in the `lab` cluster |
| `secrets-demo-naive.yaml` | How the service looks today: the password right in the file. This is what the audit found | you apply it on your own `lab` cluster |
| `secrets-demo-secret.yaml` | The "naive fix": the password moved into a Secret — and why that isn't enough | you apply it to the same place |
| `secrets-demo.yaml` | The final version: the password is nowhere — not in plaintext, not in base64 | you apply it to the same place |
| `check.sh` | A check that the application gets its password from the store | you run it at the end of the lab |

## Step 1. See the problem with your own eyes

📍 **Where:** on the bastion, in the lab cluster.

Let's reproduce the audit's finding on our own turf: we'll bring up a small `secrets-demo` service
in the lab cluster with the password handed to it straight from its description. First we go through
the file, then we apply it.

<details>
<summary><b>A closer look: what's inside secrets-demo-naive.yaml</b></summary>

This is an ordinary `Deployment` — a description of an application: which image to take and how many
copies to keep running. **An image** is a ready-made snapshot of a filesystem with a program inside;
the closest analogue in vSphere is a VM template, only without the operating system.
**A container** is a running instance of an image. **A Pod** is the smallest unit of execution
in Kubernetes: one or more containers that always live and die together.
The Deployment makes sure the number of Pods running matches the number ordered.

```yaml
      containers:
        - name: app
          image: busybox:1.36
```

We won't touch the real Passes app that you built in Go in the lab about your own registry:
it works, and there's no reason to break it for the sake of an exercise. So we bring up a separate
small `secrets-demo` service alongside it — what interests us isn't the application but the path
by which the password reaches it. That's why in its place there's a tiny container that does the
single meaningful thing — once every ten seconds it writes to the log which password it's
working with.

```yaml
          env:
            - name: DB_PASSWORD
              value: "Propusk2019!"
```

This line is the whole point of the conversation. Environment variables are the most ordinary way
to pass configuration to an application: `env` in the manifest becomes a variable inside the
container. The mechanism is good; it's the **value sitting right in the file** that's bad.

```yaml
                  "$(printf %s "$DB_PASSWORD" | sha256sum | cut -c1-12)"
```

The application prints not the password but its **fingerprint** — the first twelve characters of
the sha256. The fingerprint shows that the password has changed, yet the password itself can't be
recovered from it. This is how logs should be written; we'll use it for the rest of the lab.

`resources.requests` is how much resource to reserve as a guarantee (the analogue of a reservation
in vSphere), `resources.limits` is the ceiling it isn't allowed to rise above (the analogue of a
limit). The values are deliberately tiny: the application does nothing.

</details>

**Apply it.**

```bash
# KUBECONFIG tells kubectl which cluster to talk to. Here it's the lab cluster
# from Lab 0; the tenant will be needed later, at the step where we order the store.
export KUBECONFIG=~/lab.kubeconfig
cd labs/08-openbao
# apply = "bring the cluster to what's described in the file". -f = take the description from the file.
# No object with this name exists yet, so it will be created.
kubectl apply -f secrets-demo-naive.yaml
```

**What you should see** — a line ending in the word `created`.

Let's look at what we got:

```bash
# logs = show what the application printed to its output. There's no separate log file.
#   deploy/secrets-demo  take the output from the Pod brought up by this description
#   --tail=2             only the last two lines, not everything since startup
kubectl logs deploy/secrets-demo --tail=2
```

**What you should see** — something like this:

```
08:14:31 connecting to passes-db.internal as passes_app, password fingerprint sha256:a609df223d57
```

The application works. The password is in a file, the file is in Git. This is exactly the situation
the audit found.

## Step 2. The naive fix: moving the password into a Secret

📍 **Where:** on the bastion, in the lab cluster.

The first thing any internet search suggests: "Kubernetes has a Secret for that." Let's do as
advised — and first look at what changes in the file.

<details>
<summary><b>What changed in the manifest</b></summary>

A separate object has appeared:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: passes-db
type: Opaque
data:
  password: UHJvcHVzazIwMTkh
```

A `Secret` is a cluster object meant for sensitive data. Values in the `data` field are written in
base64, so in the file, in place of `Propusk2019!`, there now stands `UHJvcHVzazIwMTkh`.

And in the Deployment, in place of the value, a reference has appeared:

```yaml
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: passes-db
                  key: password
```

`valueFrom` instead of `value` means: "take the value not from here, but from that object over
there." Kubernetes will substitute the contents of the `password` key from the `passes-db` secret
into the `DB_PASSWORD` variable when the container starts.

This is the right technique in itself — to reference a secret rather than write the value in.
The question is what lies at the other end of the reference.

</details>

**Apply it.**

```bash
# The same apply. The file holds two objects — a Secret and the changed Deployment; the cluster will
# compare what's described against what it already has and bring the two into line.
kubectl apply -f secrets-demo-secret.yaml
```

Let's confirm the application still works:

```bash
# rollout status waits until the new version of the application has fully replaced the old one, and only
# then returns control. Without it you might read the logs of the old Pod.
kubectl rollout status deploy/secrets-demo
kubectl logs deploy/secrets-demo --tail=2
```

The fingerprint is the same — `sha256:a609df223d57`. The application got the same password by a
different path.

**Problem solved?** The password is no longer written in the Deployment. An unintelligible string
sits in the file. Let's check.

## A predictable failure · "Secret" doesn't mean "encrypted"

Try to satisfy yourself that all is well now. Ask the cluster what's inside the secret:

```bash
# get … -o yaml = "show the object in full, exactly as the cluster stores it".
# Look at the data field — that's the secret's contents.
kubectl get secret passes-db -o yaml
```

You'll see the same string `UHJvcHVzazIwMTkh`. It looks unintelligible, and therefore safe.

Now one command:

```bash
#   -o jsonpath='{.data.password}'  pull exactly one field out of the object, without the wrapper
#   | base64 -d                     pass it along and decode it: d = decode
#   ; echo                          print a trailing newline, otherwise the result runs into
#                                   the next terminal prompt
kubectl get secret passes-db -o jsonpath='{.data.password}' | base64 -d; echo
```

> **Stop and think before reading on.**
>
> What exactly did you just do to get the password? What key did you need? Who else is able to run
> this command?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

The output is `Propusk2019!`. In plaintext.

**base64 is not encryption, it's encoding.** It was invented to carry arbitrary bytes over channels
built for text: email attachments, data in JSON, binaries in config files. There's no key in it,
because there's no protection in it either. Anyone can reverse it — any person, any browser, any
decoder website.

Kubernetes uses base64 in a Secret for exactly this reason: you can't put arbitrary bytes
(a certificate or a key, say) into YAML, but you can put them in base64. The word "Secret" in the
object's name means "sensitive things go here," not "they're protected here."

What this means in practice:

| Claim | True? |
|---|---|
| A Secret is encrypted in the cluster | No. In the cluster's data store it sits in near-plaintext, unless an administrator has separately turned on encryption at rest |
| A Secret can be committed to Git | No. That's the same as putting the password there |
| You can see who has read a Secret | No. An ordinary read of the object is recorded nowhere |
| A Secret can't be read without permissions | True, and this is the only real protection. Permissions in the cluster do limit access |
| A Secret changes itself on a schedule | No. You change it, by hand, in every place at once |

**A lesson broader than this error.** And the main point. Even if all of this were solved, the
auditor's question remains: **show me who has read the password over the past month.** Kubernetes
has no answer to it at all — not because it's poorly built, but because it isn't its job. Storing
secrets is a separate task, and there's a separate service for it.

By the way, your role in the Cozystack tenant does **not** let you read secrets via `kubectl` —
try it and you'll be denied. But the lab cluster from Lab 0 is entirely yours, and there you're the
administrator. That's precisely why the command above worked.

</details>

## Step 3. Order OpenBao

📍 **Where:** in the browser, in the Cozystack dashboard, in your tenant.

Tenant → **Create application** → `OpenBAO`.

| Field | Value | Why |
|---|---|---|
| Name | `secrets` | short, and you'll have to type it into addresses later |
| Replicas | **1** | a training testbed. At two or more the chart enables Raft replication, and that's already a different storage mode |
| Size | `2Gi` | secrets take up kilobytes; the space is for internal data |
| Storage class | `replicated` | the data will be placed in three copies across different nodes |
| Resources preset | `t1.small` | 1 CPU, 512 MB |
| UI | enabled | the web interface inside the cluster |
| External | disabled | we don't expose it outward |

⚠️ **Switching between one copy and several is not a checkbox.** One copy stores data in a file,
several store it in Raft. Changing the mode requires migrating the data, so in production the
decision is made before installation, not after.

### The same thing as text — and a walk through the fields

The lab folder contains `openbao.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: OpenBAO
metadata:
  name: secrets
  namespace: tenant-workshopXX
spec:
  replicas: 1
  size: 2Gi
  storageClass: replicated
  resourcesPreset: t1.small
  ui: true
  external: false
```

`apiVersion: apps.cozystack.io/v1alpha1` is the Cozystack catalog itself, just seen from the side
where it looks like an API. When you press the button, the dashboard assembles exactly this object
and sends it to the cluster. The button is a layer on top of the text, not an alternative to it.

`kind: OpenBAO` is the position in the catalog. Mind the case: `OpenBAO`, not `OpenBao`. The cluster
is fussy about case.

`namespace: tenant-workshopXX` — **managed services live in your tenant on the management cluster,
not in the lab cluster from Lab 0.** These are two different clusters, and it's important to keep
this in mind for the rest of the lab: the application will be in one, the store in the other.

`replicas`, `size`, `storageClass`, `resourcesPreset` — the same things you filled in with the mouse.

`ui: true` — bring up the web interface. `external: false` — don't give the service an external
address; from inside the cluster it's reachable anyway.

This file is applied **not to the lab cluster** but to the tenant:

```bash
# --kubeconfig names the access file explicitly and overrides the KUBECONFIG variable.
# So the order goes to the tenant on the management cluster, not to the lab cluster.
kubectl --kubeconfig ~/.kube/config apply -f openbao.yaml
```

Management access to the tenant is already set up on this bastion — the file `~/.kube/config`
(token-based, no browser opens). There's nothing to fetch or save.

For the rest of the text we barely use this file: services are ordered with the mouse, and working
with OpenBao itself goes through its own API.

Wait until the application reaches a ready state. That's a minute or two.

## Step 4. Set up a working Pod and check connectivity

📍 **Where:** on the bastion, in the lab cluster.

Here we need to stop and understand the layout.

**OpenBao lives in your tenant on the management cluster.** Your role in the tenant lets you order
and delete services, but not run your own Pods there or connect to services by port-forwarding.
This isn't a defect, it's a boundary: the tenant is a place for managed services, not a workbench.

**Your workbench is the lab cluster from Lab 0.** There you're the administrator. From there we'll
reach OpenBao — over the internal address that every service has:

```
openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
```

Let's break the name into parts:

| Part | What it means |
|---|---|
| `openbao-` | a prefix the catalog adds to the name. You named the application `secrets`; the objects got names like `openbao-secrets…` |
| `secrets` | the name you gave in the dashboard |
| `tenant-workshopXX` | your tenant. Substitute your own number |
| `svc.cozy.local` | the internal name zone of the management cluster |
| `8200` | the OpenBao API port |

Let's bring up a working Pod. Inside it will be the `bao` utility — that's what we'll command the
store with, and you won't have to install it on the bastion. Substitute your own tenant number:

```bash
# run creates a single Pod from the given image — a disposable little machine inside the cluster.
#   --image          where to take the contents from: the official OpenBao image with the bao utility
#   --restart=Never  don't bring it up again once the command inside finishes
#   --env            the Pod's environment variable: any command inside it will see it
#   --command --     everything after the two dashes is the command the Pod will run
# sleep 86400 = "do nothing for a day": we need the Pod only as a workspace.
kubectl run bao-workbench \
  --image=openbao/openbao:2.5.1 \
  --restart=Never \
  --env=BAO_ADDR=http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200 \
  --command -- sleep 86400
# wait holds the terminal until the condition is met.
#   --for=condition=Ready  the Pod has started and is ready to accept commands
#   --timeout=120s         give up after two minutes and return an error
kubectl wait --for=condition=Ready pod/bao-workbench --timeout=120s
```

`BAO_ADDR` is the variable the `bao` utility takes the store's address from. Set once when the Pod
is created, it spares us `-address=…` in every command.

The Pod is a disposable workbench, nothing to feel sorry for: at the end of the lab we'll delete it
with one command.

Let's check that the tenant is visible from the lab cluster:

```bash
# exec = run a command inside an already-running Pod; the command itself comes after --.
# bao status asks the store about its state: whether it's sealed, whether it's initialized.
# Here it doubles as a connectivity check: a reply arrived at all — so the tenant is visible.
kubectl exec bao-workbench -- bao status
```

**What you should see** — a status table. The values `Initialized false` and
`Sealed true` are correct here: the store is running, but not yet set up and closed:

```
Key                Value
---                -----
Seal Type          shamir
Initialized        false
Sealed             true
Total Shares       0
Threshold          0
Version            2.5.0
Storage Type       file
```

⚠️ **The command will return a non-zero exit code — 2, and that isn't an error.** For `bao status`
the exit code means the store's state, not the command's success: 0 — unsealed,
2 — sealed. If your shell highlights a non-zero code or you see the note
`command terminated with exit code 2` — don't be alarmed, everything is going as it should.

⚠️ **If the command fails with `connection refused`, `no such host`, or `i/o timeout` —**
there's no point going further; connectivity first. Common causes, in decreasing order of likelihood:
you didn't substitute your own number for `workshopXX`; the application in the dashboard isn't ready
yet; a typo in the name. The name is built by the rule `openbao-<application name>`: you named the
application `secrets`, so the address contains `openbao-secrets`, not `secrets`.

## A predictable failure · The store refuses to serve

There's connectivity, so we can store the password. Try it:

```bash
# bao kv put = place a record in the store.
#   secret/passes/db  the path where it will live
#   password=…        the record's contents: a "field name = value" pair
kubectl exec bao-workbench -- bao kv put secret/passes/db password=Propusk2026
```

**What you'll see** — instead of a write confirmation, a refusal:

```
Error making API request.
Code: 503. Errors:
* Vault is sealed
```

> **Stop and think before reading on.**
>
> The service is running, the port answers, yet the store refuses to work. Why might a running
> service deliberately not serve requests? And why is that most likely the right thing?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

Look more closely at the `bao status` output from the previous step:

```
Sealed             true
Initialized        false
```

**A sealed store is the normal state of a freshly installed OpenBao.** The data on disk is encrypted
with the master key, and the master key isn't in the process's memory. Until it's placed there, the
service can neither read nor write anything, and it honestly refuses everything.

Throughout the rest of the lab, "to unseal" means exactly one thing: to present the store with shares
of the master key so it puts the key into its memory. The word has nothing to do with printing on paper.

Why it's built this way. If the master key sat next to the encrypted data, the encryption would mean
nothing: whoever stole the disk would get both. So the key lives **only in RAM** and gets there when
a person or an external system presents it.

From this follows a consequence worth accepting straight away: **after every restart of the Pod,
OpenBao is sealed again.** A node rebooted, a version upgraded, the cluster relocated the Pod — and
the store stops answering again until it's unsealed. In production this is handled with auto-unseal
through an external module (a cloud KMS, a hardware HSM), and that's a project of its own. In the lab
we'll unseal by hand and see the mechanism live.

**A lesson broader than this error.** **A managed service took installation, upgrades, replication,
and backups off your plate, but it didn't take the operational decisions.** Cozystack brought up the
OpenBao process for you in two minutes. Where to keep the unseal keys, who is allowed to unseal, what
to do at three in the morning when a node has rebooted — these are still your questions, and it's a
good thing the platform didn't quietly answer them for you.

</details>

## Step 5. Initialize and unseal

📍 **Where:** on the bastion, in the lab cluster.

**What's about to happen:** OpenBao will generate a master key, cut it into shares, and hand them to
us along with a root token. This will never happen a second time — the keys are shown exactly once.

```bash
# operator init runs once in the life of the store: it creates the master key and prints
# its shares together with a root token. No one will show these values again.
#   -key-shares=1     how many shares to cut the master key into
#   -key-threshold=1  how many shares must be presented to reassemble it
kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1
```

**What you should see:**

```
Unseal Key 1: 8kJq…=
Initial Root Token: s.7Yx…
```

⚠️ **Copy both values into a file on the bastion right now** — say into
`~/openbao-lab.txt`, and not just to the clipboard. No one will show them again. Lose the
unseal key and you lose every secret in the store — recovering them is impossible by design.

You'll need both more than once, and here's when:

- **the unseal key** — every time the store's Pod restarts. On restart it's sealed again, and every
  command starts replying `Code: 503 ... * Vault is sealed`.
  The cure is to unseal again with the same command, from the same spot where you left off;
- **the root token** — at the end of the lab, for the check script. Almost the whole lab will pass
  between these two moments, and by then you'll most likely have closed the terminal.

<details>
<summary><b>What `-key-shares` and `-key-threshold` mean, and why production is different</b></summary>

The master key isn't handed out whole. It's cut into `key-shares` shares, and to reassemble it you
must present `key-threshold` of them. The scheme is called Shamir's Secret Sharing.

The point is that **no single person can do the unsealing**. The classic production setup is five
shares with a threshold of three: the shares are handed to five holders in different departments, and
to bring the store up after a reboot you need to gather any three. One administrator who leaves
doesn't carry access away with them, and one dishonest administrator doesn't get it single-handedly.

We set one share and a threshold of one, because in the lab you're on your own and we want the
mechanism, not the procedure. **You must not do this in production**, and that isn't a formality: a
single share means a single point from which everything can leak.

</details>

Unseal it. Substitute your own unseal key:

```bash
# unseal hands the store one share of the master key. Once the shares reach the threshold,
# the key ends up in the process's memory and the store starts serving requests.
kubectl exec bao-workbench -- bao operator unseal <your-unseal-key>
# We repeat status to see the changed state.
kubectl exec bao-workbench -- bao status
```

**What you should see** — `Sealed  false` and `Initialized  true`.

Now we log in with the root token. It will be remembered inside the working Pod, and the following
commands won't ask for the token:

```bash
# login exchanges the entered token for an entry in a file inside the Pod — from then on the utility
# takes the token from there itself, and you won't have to type it into every command.
# -it gives the Pod a terminal: without it the utility has nowhere to print its prompt and nowhere to take input.
kubectl exec -it bao-workbench -- bao login
```

The utility will ask for the token and **won't show it as you type** — that's by design. Paste the
Initial Root Token from the `init` output.

⚠️ **If `bao login` complains that it can't write the token file**, pass the token as an environment
variable in every command:
`kubectl exec bao-workbench -- env BAO_TOKEN='your-token' bao status`.
It works, but the token ends up in your command history — tolerable in the lab, not in production.

## Step 6. Enable the engine and store the password

📍 **Where:** on the bastion, in the lab cluster.

A fresh OpenBao is empty: there isn't a single place in it to put anything. Secrets engines are
enabled explicitly.

```bash
# secrets enable turns on an engine — a part of the store that knows one kind of work.
#   -path=secret  which path to hang it on: from here on everything is written as secret/…
#   kv-v2         which engine exactly: "key-value" with version history
kubectl exec bao-workbench -- bao secrets enable -path=secret kv-v2
```

<details>
<summary><b>What a secrets engine is, and why there's more than one</b></summary>

OpenBao isn't a single store but a set of engines, each of which knows its own job and is mounted on
its own path:

| Engine | What it does |
|---|---|
| `kv-v2` | stores what you put into it, with version history. An ordinary "key-value" |
| database engines | **themselves** create a temporary user in PostgreSQL or MongoDB for two hours and delete it themselves |
| PKI | issues certificates on demand, instead of a once-a-year request to the security department |
| transit | encrypts data on demand without storing it: the key never leaves the store |

`-path=secret` — which path to mount it on. From here on all access to this engine goes through
`secret/…`.

We take `kv-v2` — the simplest case: we have a ready password that needs to be stored. The database
engines are far more interesting: they do away with the permanent password as a phenomenon, issuing
the application a temporary account for each run. That's the next level, and one has to grow into it;
it makes sense to start here.

</details>

Store the password:

```bash
# kv put writes a whole new version: the listed fields become its contents.
# There can be any number of fields; here there are two — the password and the database username.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026 username=passes_app
```

**What you should see** — a little table with `version  1` and a creation time.

Let's check that it reads back:

```bash
# kv get reads the record and prints its fields as a table. We're still reading with the root token — that is,
# we're checking that the record landed, not that the application will have enough permissions.
kubectl exec bao-workbench -- bao kv get secret/passes/db
```

## Step 7. Grant the application access — to exactly one line

📍 **Where:** on the bastion, in the lab cluster.

You mustn't give the application the root token: with it you can do anything, including reading
others' secrets and deleting the store. The application needs read access to just one path.

Let's write a policy:

```bash
# policy write saves a named list of permissions in the store.
#   passes-read  the policy's name; it's later granted to a token by this name
#   -            take the policy text from standard input rather than from a file
#   -i           in kubectl exec: forward that input into the Pod
# <<'HCL' … HCL is a way to pass multi-line text straight into the command, without a file.
kubectl exec -i bao-workbench -- bao policy write passes-read - <<'HCL'
path "secret/data/passes/db" {
  capabilities = ["read"]
}
path "secret/metadata/passes/db" {
  capabilities = ["read"]
}
HCL
```

<details>
<summary><b>Reading the policy</b></summary>

A policy is a list of paths and what is allowed on them. Anything not explicitly allowed is denied;
there's no need to write a separate "deny".

```hcl
path "secret/data/passes/db" {
  capabilities = ["read"]
}
```

`secret/data/passes/db` is a path **in the API**, not in the filesystem. In the `kv-v2` engine it's
structured like this: `secret` — where the engine is mounted, `data` — the engine's own internal
prefix, `passes/db` — what you specified in the `kv put` command.

⚠️ **This `data` prefix is the source of half of all baffling denials.** On the command line you
write `secret/passes/db`, but in the policy — `secret/data/passes/db`. The `bao kv` utility inserts
`data` for you; the policy does not.

`capabilities = ["read"]` — read only. Not write, not delete, not list neighboring paths.

The second block, `secret/metadata/passes/db`, is access to version information: when it was written,
how many versions there are, which is current. Read only as well.

`bao policy write passes-read -` — the trailing dash means "read the contents from standard input".
That's why the command runs with `kubectl exec -i`: the `-i` flag forwards input into the Pod.

</details>

Issue a token with this policy:

```bash
# token create issues a new token and binds a set of permissions to it.
#   -policy=passes-read  which permissions: the policy written above
#   -ttl=24h             lifetime; after a day the token stops working on its own
#   -field=token         print only the token value, without the table around it —
#                        that way it's easy to copy and pass along
kubectl exec bao-workbench -- \
  bao token create -policy=passes-read -ttl=24h -field=token
```

**What you should see** — a single line with the token.

Copy the token — you'll need it in a moment.

The lifetime here isn't a formality. The token slipped into a log, ended up in a backup, leaked with
the bastion — the day after tomorrow it's useless. A password in a manifest has no such property.

## Step 8. Put the token into the cluster and remove the password from the manifest

📍 **Where:** on the bastion, in the lab cluster.

The application needs something to prove to OpenBao that it is who it claims to be. The token is that
something.

```bash
# create secret generic creates a Secret object directly in the cluster, bypassing a file on disk.
#   passes-bao-token      the object's name; the application's description will reference the secret by it
#   --from-literal=name=…  set the value as a string from the command line
#                          (there's also --from-file, when the value is in a file)
kubectl create secret generic passes-bao-token \
  --from-literal=token='paste-the-token-from-the-previous-step'
```

**Note: a command, not a file.** The token is created directly in the cluster and never makes it
into Git — there's no file for it to make it into.

<details>
<summary><b>Secret zero: an honest word about what we didn't beat</b></summary>

A reasonable objection: we removed the database password but put a token into the cluster. Haven't we
just swapped one problem for another?

We haven't, and here's how the token differs from the password:

| | Password in a manifest | Token in the cluster |
|---|---|---|
| Sits in Git | yes, forever, throughout the commit history | no, it was created by a command |
| Lifetime | eternal | a day, then dead on its own |
| What it grants | full access to the passes database | reading one line in the store |
| Revocation | change the password everywhere it's written | one command, instantly |
| You can see who used it | no | yes, in the audit log |

But this doesn't fully close the problem, and pretending it does would be dishonest. **There is
always one secret with which the application proves its right to the rest.** It even has a name —
secret zero. Removing it is impossible: you have to identify yourself with something.

What grown-up systems do with it:

- **Kubernetes authentication.** OpenBao verifies the Pod's service token against Kubernetes itself
  and issues its own in exchange. Then "secret zero" becomes the Pod's identity, granted by the
  cluster, rather than a string a human put there
- **Single-use tokens (response wrapping).** An operator issues a token that can be used once. If the
  application gets an "already used" denial, the token was intercepted — and that's visible
  immediately

Both approaches exist and work, but in this lab they would take us far afield. Keep in mind that a
path exists, and that the goal isn't "zero secrets" but "one short-lived, narrow, revocable secret
instead of a dozen eternal ones".

</details>

Now we apply the clean manifest. First, substitute your own tenant number:

```bash
# sed edits text by the pattern s/what-to-replace/with-what/g; g = in every place on the line,
# not just the first. -i means "edit the file itself" rather than print the result
# to the screen. In place of workshop03 from the example, substitute your own number.

# macOS: the empty quotes after -i are mandatory — otherwise sed will take the next word
# as a backup-file extension and replace nothing
sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
# Linux
sed -i 's/tenant-workshopXX/tenant-workshop03/g' secrets-demo.yaml
```

<details>
<summary><b>A closer look: what's inside secrets-demo.yaml</b></summary>

Let's start with the main thing: **find the password in this file.** It isn't there — not in
plaintext, not in base64, not as a reference to an object it would sit in.

```yaml
      volumes:
        - name: secrets
          emptyDir:
            medium: Memory
            sizeLimit: 1Mi
```

`emptyDir` is a temporary folder that lives as long as the Pod and disappears along with it.
`medium: Memory` means it isn't a file on disk but a region of RAM. The password won't reach the
node's disk, nor a volume snapshot, nor a backup.

```yaml
      initContainers:
        - name: fetch-secret
          image: openbao/openbao:2.5.1
```

An init container is a container that runs **before** the main one and must finish successfully.
If it fails, the main one won't start at all. For fetching a secret this is exactly the behavior you
want: the application shouldn't start with an empty password and then fail on its first request to
the database.

```yaml
              bao kv get -field=password secret/passes/db \
                | tr -d '\n' > /secrets/db_password
              chmod 0400 /secrets/db_password
```

We take one field and write it to a file. `tr -d '\n'` strips the newline, should one appear: a
password with an extra character on the end won't work for the database, and tracking that down is
unpleasant. `chmod 0400` — only the owner can read it.

```yaml
          env:
            - name: BAO_ADDR
              value: http://openbao-secrets.tenant-workshopXX.svc.cozy.local:8200
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: passes-bao-token
                  key: token
```

The store's address and the token. The token comes by reference to the object you created with a
command. The file holds only the object's name, and a name is not a secret.

```yaml
      securityContext:
        runAsNonRoot: true
        runAsUser: 100
        runAsGroup: 1000
        fsGroup: 1000
```

Everything runs as non-root. `fsGroup` is needed so that both containers — the one that writes the
file and the one that reads it — have access to the folder. Without it the init container will write
a file the main one can't open, and you'll spend half an hour wondering where you went wrong.

```yaml
          volumeMounts:
            - name: secrets
              mountPath: /secrets
              readOnly: true
```

The folder is given to the main container read-only. The application can neither corrupt the password
nor swap it out.

</details>

**Apply it.** The Deployment will roll over to a new version: the init container will go to the store,
place the password into the Pod's memory, and only then will the application itself start.

```bash
kubectl apply -f secrets-demo.yaml
# We wait until the new version has fully replaced the old one. If the init container can't fetch
# the password, the wait won't finish — and that's exactly the behavior we want.
kubectl rollout status deploy/secrets-demo
```

## Step 9. Verify the application got its password from the store

📍 **Where:** on the bastion, in the lab cluster.

First let's look at what the init container said:

```bash
# -c selects a container inside the Pod. There are two here, and without -c kubectl can't guess which
# one you mean. fetch-secret is the one that ran before the application started.
kubectl logs deploy/secrets-demo -c fetch-secret
```

**What you should see:**

```
password fetched from OpenBao, not present in the manifest
```

Now the service itself:

```bash
# The main container: it reads the file the init container placed.
kubectl logs deploy/secrets-demo -c app --tail=2
```

The fingerprint has **changed** — it used to be `sha256:a609df223d57`, now it's different. The
application is working with a new password that isn't in any file in the repository.

Let's remove the naive secret; it's no longer needed and only gets in the way:

```bash
# delete removes the object from the cluster. The application no longer references it,
# so the deletion won't break anything.
kubectl delete secret passes-db
```

## Step 10. Rotation: change the password without touching a single file

📍 **Where:** on the bastion, in the lab cluster.

Back to the auditor's first demand: "change the password." Before, that meant finding every place
it's written, fixing them, committing, rolling out, and hoping nothing was missed.

Now:

```bash
# The same kv put. The previous version of the record isn't erased — a second one appears alongside it.
kubectl exec bao-workbench -- \
  bao kv put secret/passes/db password=Propusk2026-осень username=passes_app
# rollout restart recreates the application's Pods without changing a single line in its description.
# This is what it was all for: the new password is picked up on the next start.
kubectl rollout restart deploy/secrets-demo
kubectl rollout status deploy/secrets-demo
# The fingerprint in the log will show that the password changed, without showing the password itself.
kubectl logs deploy/secrets-demo -c app --tail=2
```

**What you should see** — the fingerprint has changed again. Two commands, zero changed files, zero
commits.

⚠️ **The application picks up the new value on restart, not instantly.** We fetch the secret with an
init container at startup — a simple, reliable approach, but updating requires a restart. If a
service needs to pick up a secret on the fly, you add a sidecar container that re-reads the value on
a timer and updates the file. That's more complex, and it's not where you should start.

Let's look at the history:

```bash
# kv metadata get shows not the values but information about the record's versions: how many there are,
# when each was created, and which is current now.
kubectl exec bao-workbench -- bao kv metadata get secret/passes/db
```

**What you should see** — both versions with their creation times. The old value hasn't vanished: if
the new password turns out not to suit the database, there's somewhere to roll back to.

You can also read the previous value in full:

```bash
# -version=1 reads the first version written instead of the current one.
kubectl exec bao-workbench -- bao kv get -version=1 secret/passes/db
```

This is what **rotation** is: replacing a secret with a new one by plan, not after a leak has
happened. A rule like "service-account passwords are changed once a quarter" goes from unachievable
to a line in a schedule.

## Step 11. The audit log: who asked for what

📍 **Where:** on the bastion, in the lab cluster.

The auditor's second demand — "show me who read the password." Let's turn on the log:

```bash
# audit enable turns on an audit device.
#   file              the device type: write records as text
#   file_path=stdout  instead of a file on disk — to the Pod's standard output, from where
#                     the platform collects the logs
kubectl exec bao-workbench -- bao audit enable file file_path=stdout
# audit list lists the enabled devices — a check that the command above went through.
kubectl exec bao-workbench -- bao audit list
```

**What you should see** — a table with one enabled device of type `file`.

<details>
<summary><b>What goes into the audit log, and how it differs from an ordinary log</b></summary>

From this moment OpenBao writes a record **for every API request**: who asked (which token, which
policy), what exactly, when, from what address, and what was answered. There are two records per
request — the request itself and the response to it.

Three differences from a familiar application log:

**Denials are written too.** An attempt to read someone else's path leaves a trace exactly as a
successful read does. It's the denials that interest the security team: successful reads are work,
while a series of denials is reconnaissance.

**Secret values don't get into the log.** Paths, names, and tokens are hashed; the secrets themselves
aren't written. The log can be handed outside without handing over its contents along with it.

**If there's nowhere to write the log, OpenBao stops working.** This is a deliberate decision: a
store that serves requests while unable to record them is worse than one that's down. Hence a
practical corollary — don't point your only audit device at a file on a disk that can fill up.

⚠️ **You won't be allowed to read this log in the lab, and that has to be said plainly.** We directed
it to the standard output of the OpenBao Pod, and your role can't read the logs of Pods in the
tenant — the tenant hands you management of services, but not access to their internals. In a real
installation the platform's log collector picks the log up and puts it where the security team looks
at it, not you via `kubectl`.

What you can still see yourself is the version history from the previous step
(`bao kv metadata get`): who **wrote**, and when, down to the second. It's not a full audit, but it
answers the question "when was the password last changed".

</details>

## The check

📍 **Where:** on the bastion, in the same terminal window where you worked with `kubectl`.

```bash
cd labs/08-openbao
# The script reads these three environment variables, so you must set them before running it
# and in the same terminal window.
export KUBECONFIG=~/lab.kubeconfig     # which cluster to check
export COZY_TENANT=workshop03          # your tenant number
export BAO_TOKEN='your-root-token'     # the one bao operator init printed
./check.sh
```

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to set it up is written at
the start of Lab 0. You can complete the lab without WSL, but there'll be no report artifact.

The script checks not the fact that manifests were applied, but the substance of the work: the store
is unsealed, the secret reads back with the token, there's more than one version (so a rotation
happened), auditing is on, and there isn't a single plaintext password in the application's manifest.

A report file will appear alongside. **Not a single secret goes into the report** — only versions,
names, and fingerprints.

## Cleanup

```bash
# delete -f = "remove from the cluster everything described in this file".
kubectl delete -f secrets-demo.yaml
# What was created by a command rather than a file is deleted by name.
kubectl delete secret passes-bao-token
kubectl delete pod bao-workbench
```

OpenBao itself is deleted in the dashboard: the `secrets` application → delete.

Why this is cheap. A secrets store in a classic installation is a project: a server, clustering,
certificates, an unsealing procedure, monitoring integration. Here you got it in two minutes and gave
it back in ten seconds, and the space it took is freed.

⚠️ **Deleting it removes every secret inside.** The unseal key and root token of a deleted store turn
into useless strings. If you put something real in there — retrieve it first.

## What we can now do

- Explain to a colleague why a Secret in Kubernetes isn't "encrypted," and back it up with a single
  command
- Order OpenBao, initialize it, and unseal it, understanding what's happening
- Put a secret into the store and grant the application access to exactly one path with a short-lived
  token
- Change a password without touching a single file in the repository, and see the version history
- Answer the question "who read this password" clearly — and understand where the answer comes from

## And in vSphere this would be

There's no direct analogue, and that's the honest answer. In classic infrastructure, service-account
passwords live in three places at once: in a config file on a VM, in the department's password
manager, and in the head of whoever set it up. Rotation means a trip through all three, which is why
it isn't done. The question "who read it" has no answer, because no one records the reading of a file.

There's the vSphere Credential Store, there's Windows Credential Manager, there are corporate
password managers — they all solve the problem of "it's convenient for a person to store passwords."
The problem of "an application gets the password itself, by policy, for a limited time, and on the
record" they don't solve.

**Where vSphere is more convenient, honestly.** In none of the above — but convenience comes at a
price, and here's what it is.

A password in a file on a VM is **always available**: the host rebooted, the machine came up, the
service read the file and started working. Nobody has to be woken at three in the morning. OpenBao
after a restart is sealed, and until it's unsealed the applications don't start. This adds a new
point of failure and a new procedure to your infrastructure — with on-call staff, with key holders,
with a documented process. Auto-unseal through an external KMS removes this problem, but adds a
dependency on that very external KMS.

And second. A file on disk is understood by any administrator at a glance. Paths, policies, tokens,
TTLs, the `data` prefix in the middle of a path — this is a separate model the team will have to
learn, and for the first couple of months it will be a source of baffling denials.

The gain still outweighs it, but it isn't free, and you should plan the migration with this cost in
mind.
