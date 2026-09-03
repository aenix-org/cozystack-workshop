# Lab 0 · Your own Kubernetes cluster

| | |
|---|---|
| **Time** | 15 minutes, 10 of them spent waiting |
| **What it proves** | A cluster is a line item in a catalog, not a quarter-long project |
| **What you'll need** | Access to the tenant dashboard; `kubectl` on the bastion (already installed) |

## Why this matters

Later on you'll be deploying applications, breaking them, fixing them and scaling them. For all of that you need a place where you are the full owner and where a mistake costs nothing.

In vSphere such a place would be handed to you. Here you take it yourself, in ten minutes, and you delete it yourself just as easily when you're done.

## Mini-glossary

Seven words that will come up in every lab from here on. The third column names the thing from vSphere the term resembles — and, right away, where it differs: the analogies here help you understand, but not one of them matches completely, and knowing exactly where an analogy breaks matters more than the analogy itself.

| Term | What it is | Like… but |
|---|---|---|
| **Kubernetes cluster** | Several machines plus a management program that spreads applications across them. You hand it an application and don't tell it which machine to run it on — it decides for itself | **An ESXi cluster**, but DRS both places and then continuously rebalances virtual machines, moving them between hosts. Here the unit is a container, and its placement is chosen once, at startup, plus again when a node fails; the cluster does not reshuffle what is already running on its own |
| **Control plane** | The cluster's management layer: it takes your commands, stores the desired state and hands out work to the nodes | **vCenter**, but it isn't a separate server with a web UI — it's a handful of processes; in Cozystack they live in the platform, not on your nodes |
| **Node** | The machine your applications ultimately run on | **An ESXi host**, but here it's a VM, not hardware, and it's created in minutes |
| **Node group** | A description of a group of identical nodes: how many, and what size | **A cluster of hosts**, but the group can add and remove nodes by itself according to load |
| **Kubeconfig** | A file holding the cluster's address and your access to it. Without it, `kubectl` doesn't know where to reach | **The vCenter address together with an account**, but this is a plain text file on your disk, not a setting in a client |
| **Tenant** | Your slice of the platform: your own quota, your own permissions, your own objects | **A resource pool plus permissions on a folder**, but it's also a visibility boundary — a neighbor won't peek into your tenant |
| **Namespace** | A section inside the cluster where objects are placed | **A folder in the vCenter inventory**, but the separation is stricter: objects in different namespaces don't find each other by short names |

Containers deserve a word of their own, because this is the main departure from the world you're used to. A container is a running application together with everything it needs to work, packed into a single image file. It differs from a virtual machine in that it has no operating system of its own inside: a container uses the kernel of the machine it runs on. Hence the difference in scale — a VM takes a minute to start and weighs gigabytes, a container starts in a second and weighs tens of megabytes. That is exactly why the cluster thinks nothing of restarting them by the batch, which is what you'll be doing in the labs ahead.

## If you're on Windows — read this first

The commands in the labs are written for the Linux and macOS command line. In plain PowerShell some of them won't work: PowerShell has different syntax and a different set of commands.

The fix is **WSL** — a Linux subsystem inside Windows. It installs with a single command in PowerShell run as Administrator:

```powershell
# installs the Linux subsystem inside Windows: the kernel, the service and the default
# Ubuntu distribution. After installation Windows will ask you to reboot.
wsl --install
```

After the reboot you'll have an Ubuntu console — and from there you work in it like everyone else. Inside WSL you'll need a `kubectl` of your own — the command you use to reach the cluster:

```bash
# snap is Ubuntu's package manager. --classic installs the package without isolation:
# in isolated mode kubectl won't see the access file in your home folder.
sudo snap install kubectl --classic
```

Windows drives are visible from WSL under the path `/mnt/c/...`, so files downloaded with an ordinary browser are available inside too — there's no need to copy them anywhere. This comes in handy a little later, when you get the cluster's access file: if you save it on Windows, from WSL it will sit at a path like `/mnt/c/Users/Ivan/Downloads/filename`.

⚠️ **If WSL is blocked by security policy** — a common thing on a corporate bastion — the labs can still be done: everything performed in the dashboard is independent of the operating system. The only things you won't be able to run are the check scripts and a few steps made up entirely of commands. Those places are marked separately.

## What's in the lab folder

All the files are already yours — you took them along with the repository. There's nothing to create or type out again: wherever it says `kubectl apply -f name.yaml` below, the file is taken from here.

```bash
# the path is counted from the repository root — you fetch it in the next step
cd labs/00-cluster
```

| File | What it is | When you'll need it |
|---|---|---|
| `cluster.yaml` | Description of the lab cluster: version, nodes, monitoring | you apply it on the management cluster in the first step |
| `check.sh` | A check that the cluster came up and you connected to it | you run it at the end of the lab |

## Step 0. The materials are already on the bastion

📍 **Where:** on the bastion (in the bastion terminal).

The manifests — files describing what to create in the cluster — and the check scripts already sit in your home folder, in the `~/workshop` directory, and your tenant number is already substituted into them. There's nothing to clone — we go in and look at what's inside:

```bash
cd ~/workshop
ls manifests scripts labs
```

From here on, every path in the labs is counted from this folder (`~/workshop`).

## Getting access to the platform

📍 **Where:** in the browser, then on the bastion.

Everything you order from the platform lives on the **management cluster** — the same place as your tenant. To reach it with commands, you need an access file. On this bastion it is **already set up** — `~/.kube/config`. Access is token-based, so the browser doesn't open when you work with the cluster and Keycloak asks you nothing.

This path is used in every lab. Let's check that access works:

```bash
# Ask the management cluster for the list of your Kubernetes clusters.
# --kubeconfig explicitly points to the access file (here it's the default file too).
kubectl --kubeconfig ~/.kube/config get kubernetes.apps.cozystack.io -n tenant-workshopXX
```

**What you should see:** either an empty list, or the line `No resources found` — you haven't created any clusters yet. What matters is something else: the cluster itself answered, not an error message.

⚠️ **Your tenant number is the login you sign in to the dashboard with:** `workshop03`, `workshop07` and so on. Your tenant's namespace is made of the word `tenant-` and this number: `tenant-workshop03`. Everywhere below that says `workshopXX`, substitute your own.

## Step 1. Creating the cluster

📍 **Where:** in the browser, in the Cozystack dashboard.

Tenant → **Create application** → `Kubernetes`.

Fill in:

| Field | Value | Why so |
|---|---|---|
| Name | `lab` | short — you'll have to type it in commands |
| Version | leave the one offered | it's the latest stable |
| Control plane replicas | **1** | the default is two; one is enough for a lab testbed |
| Node group: name | `md0` | this name ends up in the node name — you'll see it later in the output of `kubectl get nodes` |
| Node group: min replicas | **1** | we start with one node |
| Node group: max replicas | **3** | the ceiling the group may grow to by itself; the default is 10, and the scaling lab is built on that ceiling |
| Node group: instance type | `u1.medium` | 1 processor, 4 GB |
| Node group: disk | `20Gi` | |
| Storage class | `replicated` | the data lands in three copies on different nodes |
| Addons → **Monitoring agents** | **enable** | otherwise metrics won't accumulate, and in the charts lab there'll be nothing to look at |

Click create.

⚠️ **Enable `Monitoring agents` right away.** Metrics collection can't be switched on after the fact: if you tick the box a week later, everything that happened before then is lost forever. The charts lab relies on data that accumulates starting today.

⚠️ **If someone next to you is doing the same thing — stagger by a couple of minutes.** Several simultaneous creations load the internal installer, and both clusters will take three times as long to come up. The labs go at their own pace; there's no need to rush.

### A closer look: what's inside cluster.yaml

This isn't a fallback for when the dashboard is down. The button in the dashboard assembles exactly this same file and sends it to the cluster — that is, the text is primary here, and the mouse is a layer on top of it. Working with text is where we're heading: a description that lives in a file can be reviewed, put in Git and rolled back, whereas a button press cannot.

The file sits in this lab's folder: **`labs/00-cluster/cluster.yaml`**. There's nothing to open or type out again — it's already yours, if you took the repository at the start of the lab. Here it is in full, so we can go through it field by field.

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Kubernetes
metadata:
  name: lab
  namespace: tenant-workshopXX
spec:
  version: v1.35
  storageClass: replicated
  controlPlane:
    replicas: 1
  addons:
    monitoringAgents:
      enabled: true
  nodeGroups:
    md0:
      minReplicas: 1
      maxReplicas: 3
      instanceType: u1.medium
      diskSize: 20Gi
      storageClass: replicated
```

⚠️ The commands below run **on the management cluster** — with the access you were given along with the tenant. There is no access file for the `lab` cluster itself yet: it appears only after the cluster comes up.

```bash
# move into the lab folder — from here on all files are taken from here
cd labs/00-cluster
# before applying, substitute your own tenant number in the file in place of XX.
# apply = "bring the cluster to what's described in the file". The command doesn't bring
# the cluster up itself — it hands the order to the platform, which decides what to
# create and in what order.
#   -f   take the description from the file
kubectl apply -f cluster.yaml
# get = "show what's there". kubernetes.apps.cozystack.io is the full name of the object
# type, the very one described in the file (kind: Kubernetes), lab is the name of your order.
#   -n   which namespace to look in; without the flag kubectl looks in the default namespace
#   -w   watch and print changes. To exit — Ctrl+C, the installation won't be interrupted by it
# Wait until True appears in the READY column.
kubectl -n tenant-workshopXX get kubernetes.apps.cozystack.io lab -w
```

## Step 2. Waiting, and watching what it's assembled from

📍 **Where:** in the browser, in the dashboard.

The status will turn to `Ready`, usually within five to ten minutes.

⚠️ **If more than twenty minutes have passed and the status isn't changing — the cause may not be your cluster.** Installation of all applications on the platform is driven by a shared queue, and if someone's long operation is standing in it, your cluster waits its turn. To see whether it's been picked up for work:

```bash
# Look at the order itself and at what the platform writes about it.
# The status.conditions section at the end of the output is its report: whether it's been
# picked up for work, what's blocking, what it's waiting for.
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX \
  get kubernetes.apps.cozystack.io lab -o yaml
```

If nothing there is clear either — look at the tenant's events. This is a log of what the platform did with your objects:

```bash
# events = a log of incidents. We sort by time so the freshest is at the bottom.
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX \
  get events --sort-by=.lastTimestamp | tail -20
```

The most common find here is the line `exceeded quota: tenant-quota`. It means the cluster is short of the resource share allotted to your tenant, and it won't get out of this state on its own: you need to free up space or expand the quota.

While the installation runs, look in the dashboard at what exactly appears in your tenant.

**The control plane** deployed as several ordinary applications. There is no separate machine playing "the vCenter of this cluster": the management layer is processes that run alongside everything else.

**A node** — now that is a virtual machine. A perfectly ordinary one, just like those you migrate: with its own disk, its own memory and its own address, and it lives in your tenant.

From this follows something important: **Kubernetes here does not replace virtualization — it lives on top of it.** You don't have to choose between "we run VMs" and "we run containers" — both work, on the same hardware and in the same interface.

## Step 3. Getting access to the new cluster

📍 **Where:** on the bastion; the file itself is fetched with a command or from the dashboard.

**What we're fetching.** The kubeconfig of the `lab` cluster — a text file recording the address of its API server and your access data for it. Without such a file, `kubectl` doesn't know where to reach or whom to present itself as. You create the file on your bastion yourself, under the name `~/lab.kubeconfig`; `~` in paths is your home folder: `/Users/name` on macOS, `/home/name` on Linux and WSL.

⚠️ **This is a second access file, not a replacement for the first.** The one you were given along with the tenant (in the labs it sits at the path `~/.kube/config`) leads to the management cluster — where you order applications and where you just created `lab`. The new file leads inside the `lab` cluster itself. These are two different clusters with different addresses, and from here you need both: orders to the platform go through the first file, work inside your own cluster through the second.

**Where it sits.** The platform put it in the Secret `kubernetes-lab-admin-kubeconfig` in your tenant. A Secret is a cluster object where passwords, keys and access files are kept. The key you need inside the Secret is `admin.conf`.

⚠️ **There are four keys in the Secret, and you want exactly `admin.conf`.** Next to it sits `admin.svc` — the same thing but with an internal address visible only from inside the cluster; you can't connect over it from the bastion. The `super-admin.*` pair grants rights that bypass the configured restrictions and is meant for post-incident work, not for everyday use.

**The primary way — with a command.** Cozystack sets up on your cluster a separate access rule allowing exactly this Secret to be read and nothing more. The command runs **on the management cluster**, with the access you were given along with the tenant, and the result is put into a file on the bastion:

```bash
# get secret = show the Secret; -o go-template — don't print it whole,
# but pull one field out of it and output it as text:
#   index .data "admin.conf"   take the admin.conf key from the Secret
#   base64decode               the contents of Secrets are stored base64-encoded,
#                              this function returns the original text
#   > ~/lab.kubeconfig         write the output to a file instead of the screen
kubectl -n tenant-workshopXX get secret kubernetes-lab-admin-kubeconfig \
  -o go-template='{{ printf "%s\n" (index .data "admin.conf" | base64decode) }}' > ~/lab.kubeconfig
```

**The same thing with the mouse.** This same Secret is visible in the dashboard on the `lab` application's page, in its list of secrets — look by the name `kubernetes-lab-admin-kubeconfig`. Copy the value of the `admin.conf` key, open any text editor, paste what you copied, and save the file under the name `lab.kubeconfig` in your home folder.

## Step 4. Connecting

📍 **Where:** on the bastion (in the bastion terminal).

**What's about to happen:** we tell `kubectl` which access file to use, and ask the cluster for the list of its nodes.

macOS and Linux:

```bash
# KUBECONFIG is the variable from which kubectl learns which access file to take.
# export makes it visible to all commands run further in this terminal window.
export KUBECONFIG=~/lab.kubeconfig
# nodes are the cluster's nodes, the very virtual machines your applications will run on.
# The answer also proves the access file works.
kubectl get nodes
```

Windows PowerShell — only if you couldn't install WSL:

```powershell
# in PowerShell environment variables are set via $env: and live until the window closes
$env:KUBECONFIG="$HOME\lab.kubeconfig"
kubectl get nodes
```

**What you should see** — a single line with your node and the status `Ready`:

```
NAME                        STATUS   ROLES    AGE   VERSION
kubernetes-lab-md0-xxxxx    Ready    <none>   3m    v1.35.6
```

⚠️ **`TLS handshake timeout` and `context deadline exceeded` are a refusal on the cluster's side, not an error in the command.** The management part of your cluster runs in a single copy, and when the platform is under load it stops responding for a few tens of seconds. The command fails, you repeat it half a minute later — and it goes through. If this happened in the middle of an `apply`, repeat it: the command brings the cluster to the state described in the file rather than adding something new, so nothing gets created twice.

⚠️ **The `KUBECONFIG` variable has to be set in every new terminal window.** Forget it, and `kubectl` will go to some other cluster or say there's nothing to connect to. This is the single most common cause of "everything's broken for me" across all the labs. If something behaves oddly — the first thing to check is `echo $KUBECONFIG`.

## The check

📍 **Where:** on the bastion, in the same terminal window where you were working with `kubectl`.

```bash
# the script runs from the lab folder: it looks for files next to itself
cd labs/00-cluster
# ./ before the name means "run the file right from here"; without it the shell
# will look for the check.sh command among the system folders and won't find it
./check.sh
```

⚠️ **On Windows the script runs from WSL**, not from PowerShell — how to install it is written at the start of this lab. Without WSL the lab can be completed, but there'll be no report artifact.

The script makes sure the cluster answers, the nodes are in order and there's room on them for future applications. A report file appears next to it — you can attach it anywhere as proof the lab is done.

## Cleanup

You'll need the cluster in labs 1–5 and beyond. Don't delete it now.

When you're done with all the labs — delete the `lab` application through the dashboard.

The deletion itself takes a few minutes: the platform shuts down the node VM, removes the management components and releases the disks. If the installation queue is busy with someone's long operation at that moment, the wait can be longer — then the same trick with the `reconcile.fluxcd.io/requestedAt` annotation, described earlier in the lab, helps.

What matters is something else: **what's freed returns to the quota in full and by itself.** There's no need to ask anyone or explain why you took it.

## What we can now do

- Spin up a Kubernetes cluster for ourselves, without going to anyone
- Understand that the control plane is processes, and a node is a virtual machine
- Fetch access and connect from the bastion
- Know where to look for the cause when `kubectl` behaves oddly

## And in vSphere this would be

Kubernetes in vSphere is a separate product, a separate license and a rollout project with the vendor involved. Here it's a line in a catalog and ten minutes.

**Where vSphere is more convenient, honestly.** If all you need is virtual machines and nothing else, vCenter gives you more ready-made tools for managing them: templates, clones, guest-OS customization, permissions at the level of a single folder. Cozystack can do VMs, but the ecosystem around them here is younger. The gain appears where you need both VMs and everything else at once — databases, queues, clusters, registries — in one place and through one API.
