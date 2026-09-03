# Lab 12 · A VM next to the containers

| | |
|---|---|
| **Time** | 30 minutes, of which 5–10 are spent waiting for the machine to boot |
| **What it proves** | Legacy doesn't have to be containerized to move: a migrated VM is published to the outside world by the same ingress and domain as a containerized application |
| **What you'll need** | Access to the tenant dashboard, the tenant `~/.kube/workshop`, `kubectl`, `virtctl` |

## Why this matters

The staff directory is the oldest part of "Propusk". A 2011 application, written by a contractor who is no longer around. It runs on Windows Server and on a version of .NET that was never updated, because "it works". There are no sources, no documentation — just a four-page recovery guide with a step that reads "call Sergei".

Inside, it's a small web application: it serves an HTTP page listing employees and their phone numbers. People open it in a browser; other services query it for data.

This directory is not moving into a container. Not "not yet" — never: you physically cannot containerize an application that no one can rebuild. And that is no reason to skip the move. The answer to "what do we do with the things that won't port?" is: bring them over as they are, as a virtual machine.

But moving is not enough: the directory has to be visible from the outside, just as before. In this lab we'll stand up a virtual machine next to the containers and publish it to the outside world **the same way as a containerized application** — through the platform's ingress and domain name. To the platform, the VM is just another workload behind a domain, and it has no need to care whether there's a container behind it or a whole OS.

## Mini-glossary

| Term | What it is | Like… but |
|---|---|---|
| **VMInstance** | A virtual machine as a cluster object | **A virtual machine**, but described as text and created with the same `kubectl` as the applications |
| **VMDisk** | A disk that exists separately from the machine | **A vmdk**, but a separate object: it outlives the machine and can be attached to another one |
| **Instance type** | A ready-made machine size from the platform's list: so many vCPU, so much memory | closer to cloud instance types than to hand-tuning vCPU/RAM |
| **Instance profile** | A set of devices and drivers for the guest OS | **Guest OS type**, but it affects which controllers the guest will see |
| **cloud-init** | A first-boot provisioning script that runs the first time the machine is powered on | **Customization Specification**, but plain YAML inside the manifest rather than a wizard in the UI |
| **Service** | One stable address for a group of Pods inside the cluster | **A load-balancer pool**, but the platform keeps the membership list current itself, by label |
| **Ingress** | A rule: which domain routes to which Service, together with HTTPS | **A reverse proxy in front of a farm** (nginx, HAProxy), but described as an object, with the domain and certificate issued by the platform |
| **domain** | A permanent name by which the service is visible from the outside over HTTP | **A DNS name behind a corporate load balancer**, but there's no ticket to file with DNS or for a certificate |
| **KubeVirt** | The mechanism by which Kubernetes runs VMs | **A hypervisor**, but it isn't a second hypervisor: underneath it's the same QEMU/KVM that any Linux uses |

## What's in the lab folder

You already have all the files — you got them along with the repository. There's nothing to create or retype: wherever it says `kubectl apply -f name.yaml` below, the file comes from here.

```bash
cd labs/12-vm
```

| File | What it is | When you'll need it |
|---|---|---|
| `staff-directory-vm.yaml` | The virtual machine for the legacy staff directory | you apply it **in the tenant** |
| `check.sh` | A check that the directory is published and answers on its domain | you run it at the end of the lab |

📍 **The ingress is created by the instructor, not the participant, and in advance.** Each tenant already contains a `Service spravochnik-http` (it forwards port 80 to 8080 and selects the Pods of your machine) and an `Ingress spravochnik` with the host `spravochnik.workshopXX.workshop.aenix.io`. You don't need to set them up and you don't need to keep their files yourself — all you need is to bring up a virtual machine named `spravochnik`, and the publication will pick it up on its own.

## Step 1. Bring up the VM

📍 **Where:** in the browser, in the tenant dashboard.

The VM is a Cozystack managed service; it lives in your tenant. It's created in two moves, and that's worth understanding right away.

### The disk first

Tenant → **Create application** → `VM Disk`.

| Field | Value | Why so |
|---|---|---|
| Name | `spravochnik` | this is what the machine will be called too |
| Source | `Image` → `ubuntu-22.04` | taken from the platform's ready-made image collection |
| Storage | `20Gi` | the `ubuntu-22.04` image unpacks to 20Gi; you can't set less |
| Storage class | `replicated` | three copies of the data on different nodes |

**Why the disk is a separate object, not a field inside the machine.** Because the disk outlives the machine. You can delete the whole machine, recreate it with a different type, a different network, a different name — and attach the same disk. In vSphere you do the same thing when you detach a vmdk from one VM and attach it to another; here it's spelled out explicitly in the model.

⚠️ **The disk cannot be smaller than the source image.** The platform's `ubuntu-22.04` unpacks to 20Gi, and the platform will reject a request for a 10Gi disk: there's nowhere to clone the image into a smaller volume. Undersizing here costs more than oversizing: you can grow a disk later, but you can't shrink one.

Wait for the disk to fill up: the platform downloads and unpacks the image, which takes a minute or two.

### Then the machine

Tenant → **Create application** → `VM Instance`.

| Field | Value | Why so |
|---|---|---|
| Name | `spravochnik` | |
| Instance type | `u1.medium` | 1 CPU, 4 GB — the same size list as the cluster nodes use |
| Instance profile | `ubuntu` | the set of devices for the guest OS |
| Run strategy | `Always` | keep it running; if it shuts itself down, it will be started again |
| Disks | `spravochnik` | the disk you created |
| Cloud init | see below | brings up the directory on port 8080 |

In the cloud-init field:

```yaml
#cloud-config
password: ubuntu
chpasswd: { expire: false }
ssh_pwauth: true
write_files:
  - path: /opt/directory/index.html
    content: |
      <!doctype html><html lang="ru"><head><meta charset="utf-8"><title>Справочник</title></head><body><h1>Справочник сотрудников</h1><ul><li>Иванов И. — 101</li><li>Петров П. — 102</li></ul></body></html>
  - path: /etc/systemd/system/directory.service
    content: |
      [Unit]
      Description=Staff directory
      After=network.target
      [Service]
      ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /opt/directory
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd: [ "systemctl daemon-reload", "systemctl enable --now directory" ]
```

This cloud-init turns the directory into a server: it drops in an HTML page with the list of employees and sets up a service that serves it over HTTP on port 8080. `python3` is already in the Ubuntu image, so there's nothing to install and no internet required. Port 8080 wasn't chosen at random: it's exactly the port that the `Service spravochnik-http`, created by the instructor in advance, is looking at.

⚠️ **A plaintext password — for the lab only.** On a real machine there would be `sshKeys` here and no password at all. We're taking the short path so as not to spend workshop time exchanging keys.

**The same thing as text.** Both objects, the disk and the machine, are in one file, `staff-directory-vm.yaml`, and are created with a single command: the disk first, then the machine. Before applying, open the file and replace the `tenant-workshopXX` placeholder in it with the name of your own tenant — otherwise the objects will end up in the wrong place.

```bash
# KUBECONFIG is the variable kubectl reads the cluster address and login data from.
# Here you need the TENANT access file: the VM lives in the tenant on the management cluster.
export KUBECONFIG=~/.kube/workshop
# apply = "bring the cluster to what's written in the file". No objects — it creates them,
# objects present — it brings them to the described state.
#   -f   read the description from a file
kubectl apply -f staff-directory-vm.yaml
```

**What you should see:** two lines with `created` — one for the disk and one for the machine.

<details>
<summary><b>A closer look: what's inside staff-directory-vm.yaml</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
```

The same API group that buckets, databases and queues live in. Here the virtual machine is not a separate subsystem with its own interface, but a catalog object just like Redis. This is the substance behind the phrase "in one interface and through one API".

```yaml
spec:
  source:
    image:
      name: ubuntu-22.04
  storage: 20Gi
```

An image name from the platform's shared collection, not a URL: the collection is shared across the whole cluster, and the image is downloaded once. `storage` cannot be smaller than the image itself — `ubuntu-22.04` unpacks to 20Gi. If you need your own image, that same place has `source.http` with a link and `source.disk` for cloning an existing disk.

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
```

The machine size is taken from a ready-made list, not dialed in with vCPU and RAM fields. `u1.medium` is 1 CPU and 4 GB. The same list is used when you order a node for a Kubernetes cluster, and that's no coincidence: a cluster node is a VMInstance just the same.

```yaml
  instanceProfile: ubuntu
```

The guest OS profile: which controllers, drivers and devices to hand the machine so the guest recognizes them. The closest analog is "Guest OS type" when creating a VM in vSphere, and the consequences are the same: the wrong profile gives you a machine that boots but can't see its disk.

```yaml
  runStrategy: Always
```

The desired power state. `Always` — keep it running: if the guest shuts down from inside, the machine is started again. `Halted` — powered off. `Manual` — left as is, nobody intervenes. Note the wording, it's the same as `replicas` in a Deployment: not "power it on", but "keep it powered on".

```yaml
  disks:
    - name: spravochnik
```

A list of disks by VMDisk object name. A second disk for data is added right here, as a second line.

```yaml
  cloudInit: |
    #cloud-config
    write_files:
      - path: /opt/directory/index.html
      - path: /etc/systemd/system/directory.service
    runcmd: [ "systemctl daemon-reload", "systemctl enable --now directory" ]
```

cloud-init is the standard first-boot provisioning mechanism that every cloud Linux image understands. It runs once, on the first power-on. Here it does three things: drops in the directory's HTML page, sets up a systemd service that serves that page over HTTP on port 8080, and starts the service. It's the analog of a Customization Specification in vSphere, only it's text inside the manifest rather than a wizard in the UI — which means it lives in Git and gets reviewed along with everything else.

It's precisely because of this block that the directory becomes visible from the outside: the `Ingress` the instructor created in advance routes the domain to `Service spravochnik-http`, and that in turn to port 8080 inside the machine. As soon as the service on 8080 comes up, the publication picks it up on its own.

### What this manifest doesn't have, and won't

**A `replicas` field.** `VMInstance` doesn't have one. A virtual machine is a single object; if you need two machines, you create two objects with different names.

This is a fundamental difference from a `Deployment`, and it isn't a shortcoming. Copies in a Deployment are interchangeable: any of them will serve any request, and losing one is no big deal. Virtual machines are not interchangeable — each has its own state on its own disk, and "make another one just like it" means something entirely different than it does for a container.

The practical consequence: **the self-healing you saw in the Pod-deletion lab does not exist for a VM.** Delete a Pod and the cluster creates a new one in seconds. Delete a VMInstance and the machine is gone, and the only way to bring it back is by hand, by attaching the surviving disk. Here you're in exactly the same place you were in vSphere, and that's worth knowing up front rather than discovering along the way.

</details>

The first power-on takes 3–5 minutes: cloud-init expands the filesystem across the whole disk and brings up the directory service. We won't sit on our hands waiting for it — in the next step we'll check exactly what's happening with the publication while the machine is still booting.

## Step 2. Knocking on the domain while the machine boots

📍 **Where:** on your laptop, in a separate terminal window. Or right in the browser.

The instructor has published the directory in advance: your tenant already has an `Ingress spravochnik` with the host `spravochnik.workshopXX.workshop.aenix.io` and a `Service spravochnik-http` that routes to port 8080 inside the machine. The publication is ready to receive the directory the moment it starts answering. Let's check it right now, without waiting for the machine to finish loading.

```bash
# curl — "go to the address and show the response". Replace XX with your own tenant number.
#   --max-time 5   give up after 5 seconds instead of waiting a long time
curl --max-time 5 http://spravochnik.workshopXX.workshop.aenix.io
```

**What you'll see:**

```
<html><head><title>503 Service Temporarily Unavailable</title></head>
<body><center><h1>503 Service Temporarily Unavailable</h1></center></body></html>
```

> **Stop and think before you read on.**
>
> The instructor created the ingress, the domain is configured, and you brought the machine up.
> Why does the domain answer `503` rather than the directory page?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

Because the directory inside the machine isn't listening yet.

`503` doesn't mean "the ingress is broken". The ingress is in place and knows where to route the traffic: to `Service spravochnik-http`, which selects the Pods of your machine and forwards the request to port 8080. But while cloud-init is expanding the filesystem and setting up the service, nobody is answering on 8080 inside the machine yet — the service has not a single ready backend. And that's exactly what the ingress reports: the route exists, but there's no one to answer on it yet.

The response code here is the diagnosis itself:

| What you see | What it means |
|---|---|
| `503` | the ingress is in place, but there's no ready backend behind it |
| `404` | the ingress exists, but the rule routes to the wrong service |
| no response, timeout | no ingress with this host was created at all |

**The lesson is broader than this error.** A `503` from an ingress is about backend readiness, not about the ingress itself. You'll get the same `503` if the application behind the domain crashes or its Pod hasn't passed its readiness check yet. Publishing to the outside and workload readiness are two different things: the domain is set up in advance and is empty for a while, filling in exactly when someone ready to answer appears behind it. For a VM that's "when the service on 8080 came up"; for a container it's "when the Pod passed readiness". The mechanism is the same, and that is the meaning of the phrase "a VM is published the same way as a containerized application".

</details>

## Step 3. Getting into the machine

📍 **Where:** in the dashboard, on the `spravochnik` machine's card.

The card has a console — it's the same screen as "Open Console" in vSphere. Open it. Login `ubuntu`, password `ubuntu`.

⚠️ **If the console shows a black screen and a blinking cursor — wait.** cloud-init isn't finished yet, and the prompt will appear on its own. Don't reboot the machine: a reboot in the middle of cloud-init leaves it half-configured.

**The same login from the terminal.** `virtctl` is a separate command for working with virtual machines: console, port forwarding, powering on and off. It installs as a single file; exactly how is written in `workshop/README.md`.

One quirk of its syntax is worth going over in advance, or your very first command will come back denied. The target for `virtctl` is given not as a bare name but with a type prefix: `vmi/<name>`. `vmi` is virtual machine instance, the **running instance** of the machine; the `VMInstance` object you created and the running instance are two different objects in the API. Under tenant access the rights are granted on the `virtualmachineinstances` **subresource** (`console` and `portforward`), not on the whole `virtualmachines` objects — a bare name hits the vm object and comes back `forbidden`. The platform builds the instance name from the prefix `vm-instance-` plus your machine's name: `spravochnik` is the instance `vm-instance-spravochnik`.

```bash
# tenant access: the machine lives in the tenant
export KUBECONFIG=~/.kube/workshop
# console = connect to the machine's serial console. It's the same screen that
# "Open Console" gives you in vSphere, only text-based:
#   --namespace  which section of the cluster to look in; for your tenant it's called
#                tenant- plus your login, replace XX with your own number
#   vmi/...      the target: the running instance of the machine, not the VMInstance description
virtctl console --namespace=tenant-workshopXX vmi/vm-instance-spravochnik
```

If the screen is blank after connecting — press Enter, and the login prompt will appear. To exit the console — `Ctrl+]`. The names of all running instances in your tenant are shown by `kubectl --kubeconfig ~/.kube/workshop get vminstance -n tenant-workshopXX`.

From the inside it's ordinary Ubuntu. Make sure the directory has come up:

```bash
uname -a                       # kernel and architecture: the same line as on a bare-metal server
systemctl status directory     # the directory service: should be active (running)
curl -s localhost:8080 | head  # the same page, but requested from inside the machine itself
```

If `systemctl status directory` shows `active (running)` and `curl` to `localhost:8080` returned the HTML with the employee list — the server is ready, and the publication on the outside is about to swap the `503` for the page. There's no trace of Kubernetes inside, and there shouldn't be: the guest doesn't know it's in a cluster — exactly as a VM in vSphere has no need to know about vCenter.

## Step 4. The domain answers — the directory is published

📍 **Where:** on your laptop. Or in the browser.

The same request that returned `503`, but now the service on 8080 has come up. Substitute your own number.

```bash
curl http://spravochnik.workshopXX.workshop.aenix.io
```

**What you should see** — the HTML of the directory page:

```html
<h1>Справочник сотрудников</h1><ul><li>Иванов И. — 101</li><li>Петров П. — 102</li></ul>
```

Open this address in a browser and you'll see the same list. The directory is visible from the outside by a human-friendly domain name, with HTTPS from the platform, without a single ticket to networking or for a certificate.

**Let's unpack what just happened.**

An Ubuntu virtual machine that knows nothing about Kubernetes is listening on ordinary HTTP on an ordinary port. From the outside it's reached by the domain `spravochnik.workshopXX.workshop.aenix.io`, and the request travels to it through the same ingress that publishes containerized applications. No agents inside the guest, no gateways, no "integration". For publication it makes no difference what's behind the domain — an nginx Pod or a whole virtual machine: it sees a `Service`, behind the `Service` there's a ready backend, and that's enough.

This is exactly what "legacy doesn't have to be containerized" means. The 2011 directory will keep working the way it always did — and from the outside it looks just like any new "Propusk" service: a name, a domain, HTTPS.

## Verification

📍 **Where:** on your laptop, in the same terminal window where you worked with `kubectl`.

The script checks not the presence of objects but the work in substance: the domain name returns a `200` and it's the directory page, the machine itself is running, and the `Ingress` that publishes it is in place. The check by domain works even without tenant access — `curl` is enough for it; tenant access adds the machine-state checks.

```bash
# tenant access: from here the script takes the VM itself and the Ingress
export KUBECONFIG=~/.kube/workshop
# your login without the word tenant-: from it the script builds both the section name tenant-workshopXX
# and the domain name spravochnik.workshopXX.workshop.aenix.io
export COZY_TENANT=workshopXX
# the ./ before the name means "the file from the current folder", i.e. from labs/12-vm
./check.sh
```

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to install it is written at the start of lab 0. Without WSL you can still complete the lab, but there won't be an artifact report.

`COZY_TENANT` is mandatory — without it the script stops right away: the domain is built from it. If tenant access isn't set, the machine-state checks are skipped with a warning, while the main check — the answer on the domain — still runs.

## Cleanup

Leave the virtual machine if you're planning the monitoring lab: its consumption shows up in the graphs too, and it makes a good illustration. If you're not — delete the machine and the disk through the dashboard.

⚠️ **Delete in the right order: the machine first, then the disk.** A disk attached to a running machine won't delete, and you'll end up with an object stuck in a deleting state.

The `Ingress` and `Service` that publish the directory were created by the instructor — don't touch them, they'll be needed by the next participant on this testbed.

The cost of cleanup here is honestly higher than in the other labs: a disk with data is a disk with data, and it doesn't vanish instantly. On the other hand, creating it required neither a ticket for disk space nor a sign-off.

## What we can do now

- Bring up a virtual machine in a tenant — with the mouse and as text
- Explain why the disk and the machine are two objects, and what that buys you
- Publish a workload to the outside through ingress and a domain — the same way as a container
- Read a `503` from an ingress as "there's no one to answer behind the domain yet", not as a breakage
- Show on a live example that migrating legacy doesn't require rewriting it

## And in vSphere this would be

A VM in vSphere is home turf, and it's made there the familiar way. The difference isn't the machine itself, but exposing it to the outside under a human-friendly name.

To publish this machine on a domain in vSphere, you'd need a reverse proxy or load balancer as a separate product, a networking ticket for an external address, a DNS ticket for the name, and a security ticket for the certificate. Three or four commands, three or four systems, and the general question of "who operates all this". Here the publication is an `Ingress` object that the instructor set up in advance, and a domain that fills in the second the machine starts answering.

**Where vSphere is more convenient, honestly.** When it comes to managing the virtual machines themselves, vCenter is still richer, and there's no point pretending otherwise:

| What | vSphere | Cozystack |
|---|---|---|
| Templates and cloning | mature, with guest customization | disk cloning is there, a customization wizard is not |
| Snapshots | familiar, with a tree | present, but the ecosystem around them is younger |
| Live migration | vMotion, refined over years | present, but used less often and less battle-tested |
| Rights on a VM folder | granular | rights at the tenant level, no folders |
| Console and guest tools | VMware Tools with full telemetry | qemu-guest-agent, less data |

If you need **only** virtual machines — the honest answer is that moving for the sake of moving makes no sense. The payoff appears where you need something else alongside the VMs: clusters, databases, queues, registries, object storage, publishing on a domain. Then, instead of five products with five permission models, you have one catalog, and the 2011 directory stands in it next to everything else.
