# Lab 1 · Your first application

| | |
|---|---|
| **Time** | 25 minutes |
| **What it proves** | An application is described in text, deploys in seconds, and you ask no one for permission |
| **What you'll need** | The cluster from lab 0, `kubectl`, the file `~/lab.kubeconfig` |

## Why this matters

Before we take on a real task, let's practise on something harmless. We'll deploy a tiny
application that does nothing except one thing: it shows **the name of its own copy**.

Sounds pointless, but that very name is the main character of the next three labs. Through it
you'll watch a copy die and be born again, watch them multiply to six, and watch an old
version give way to a new one.

We'll deploy it in text: one file and one command. There's no mouse in this lab, and there's
a reason for that — that's where we'll begin.

## Little glossary

| Term | What it is | Like… but |
|---|---|---|
| **Pod** | A running copy of an application | A **virtual machine**, but the Pod is disposable. It isn't repaired or backed up — you delete it, and a new one is created |
| **Image** | A snapshot of the application with everything it needs to run | A **VM template**, but immutable. You can't go inside and fix it — you build a new one |
| **Deployment** | A description: which image, how many copies, how to update them | A **vApp**, but it holds a desired number of copies rather than references to specific VMs |
| **Service** | A permanent address that the copies sit behind | A **load-balancer pool**, but the name doesn't change even when every copy behind it has been recreated |
| **ConfigMap** | A settings file living inside the cluster | A **file on a VM's disk**, but it lives apart from the application and is slipped inside at startup |
| **Manifest** | A file describing the desired state | There's no direct analogue, and that's the whole point |

## What's in the lab folder

You already have all the files — you pulled them along with the repository. There's nothing
to create or retype: wherever it says `kubectl apply -f name.yaml` below, the file is taken
from here.

```bash
# the path is relative to the root of the repository you pulled in lab 0
cd labs/01-deploy
```

| File | What it is | When you'll need it |
|---|---|---|
| `rickroll.yaml` | The application in full: nginx settings, the deployment itself, and the entry point to it | you apply it on your own `lab` cluster |
| `check.sh` | A check that the application responds and returns the Pod name | you run it at the end of the lab |

## Step 1. Where the dashboard ends and your cluster begins

📍 **Where:** on the laptop.

The Cozystack dashboard shows what you **order from the platform**: Kubernetes clusters,
databases, queues, virtual machines — catalog items. The `lab` cluster shows up there as a
single item: ordered and running.

The dashboard doesn't look inside it, and it can't. Your cluster is a separate API server
with its own address and its own access file — that same `~/lab.kubeconfig`; the management
dashboard doesn't talk to it. The `lab` cluster has no graphical console of its own either:
none is listed among the add-ons you can attach to it.

Hence the boundary of responsibility, and it's worth remembering: **the platform is
responsible for what you ordered, and for what's inside what you ordered, you are
responsible.** Inside the cluster the work goes through `kubectl` — the command that sends
object descriptions to its API server and shows you what's there right now.

Let's connect:

```bash
# KUBECONFIG — the variable kubectl reads to learn which access file to use.
# Here that's access to the lab cluster, not to the tenant: different files, different clusters.
export KUBECONFIG=~/lab.kubeconfig
# get nodes = "show the nodes". The answer confirms kubectl is talking to the right place.
kubectl get nodes
```

**What you should see:** a line with your node and the status `Ready`. If you get a
connection error instead — check `echo $KUBECONFIG`: the variable has to be set in every new
terminal window.

## Step 2. Deploy the application

📍 **Where:** on the laptop.

Go to this lab's folder — you pulled the repository in lab 0:

```bash
# the path is relative to the folder you cloned the repository into
cd labs/01-deploy
```

If you don't have the repository yet:

```bash
# clone = download the whole repository; a folder with the same name will appear next to you
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd labs/01-deploy
```

In the folder is `rickroll.yaml`. Before we apply it — let's work out what's in it.

<details>
<summary><b>A closer look: what's inside rickroll.yaml</b></summary>

There are four objects in the file, separated by a `---` line. Let's go through them in order.

### First: the web-server settings

```yaml
kind: ConfigMap
metadata:
  name: rickroll-conf
data:
  default.conf: |
    server {
      listen 8080;
      root /usr/share/nginx/html;
      location / {
        sub_filter '__POD__' '$hostname';
        sub_filter_once off;
      }
    }
```

`ConfigMap` is a way to place a settings file into the cluster separately from the
application. Inside is an ordinary nginx config (nginx is a web server, and it's the one
that will serve our page), the same as would sit in `/etc/nginx/conf.d/` on a VM.

The key line is `sub_filter '__POD__' '$hostname'`. It tells nginx: in the page you serve,
replace the text `__POD__` with the name of the machine you're running on. Inside a Pod, the
machine name is the name of the Pod itself. That's how the page learns who served it.

Why the settings are a separate object rather than baked into the image: so you can change
them without rebuilding the image. We'll make use of that in the lab about rolling out
versions.

### Second: the page itself

```yaml
kind: ConfigMap
metadata:
  name: rickroll-page-v1
data:
  index.html: |
    ...<div class="pod">served by pod<b>__POD__</b></div>...
```

That same `__POD__` that nginx will substitute. The `-v1` in the name is no accident: in the
lab about rolling out versions a `-v2` will appear, and switching between them will be a
rollout of the new version.

### Third: the application

```yaml
kind: Deployment
spec:
  replicas: 1
```

`Deployment` is the description of the application as a whole. `replicas: 1` is how many
copies to keep running. Note the wording: not "run one", but **"keep one"**. The difference
shows up in the next lab, when we delete the copy.

```yaml
      image: nginxinc/nginx-unprivileged:1.27-alpine
```

The image. We've taken the unprivileged variant of nginx — it listens on port 8080 and
doesn't run as root. Ordinary nginx demands privileges that a properly configured cluster
won't grant. This isn't us being fussy — it's a security requirement you'll meet in any
modern cluster.

```yaml
      resources:
        requests: {cpu: 20m, memory: 32Mi}
        limits:   {cpu: 300m, memory: 128Mi}
```

Two different things, and they're constantly confused.

`requests` is how much to **reserve as a guarantee**. The scheduler uses this number to
decide which node the Pod fits on. The closest analogue is a reservation in vSphere.

`limits` is the ceiling it **won't be allowed to rise above**. The analogue is a limit in
vSphere.

`20m` reads as "20 milli-CPUs", that is, two hundredths of a core. We're asking for little
on purpose: the application is tiny, and in the scaling lab a low request will let you see
the copies grow with your own eyes.

```yaml
      readinessProbe:
        httpGet: {path: /healthz, port: http}
```

The readiness check. The cluster knocks on this address and sends no traffic to the Pod
until it gets an answer. This is exactly what will provide the zero-downtime update in the
lab about rolling out versions: a new copy starts receiving requests only once it's genuinely
ready to handle them.

### How the settings get inside the container

We've described the two ConfigMaps, but on their own they just sit in the cluster and never
reach nginx. Two blocks tie them together — and the whole trick of this lab rests on them:

```yaml
          volumeMounts:
            - name: page
              mountPath: /usr/share/nginx/html
            - name: conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: page
          configMap:
            name: rickroll-page-v1
        - name: conf
          configMap:
            name: rickroll-conf
```

Read it from the bottom up. `volumes` declares: "take this ConfigMap and turn it into a
folder of files". `volumeMounts` says: "place that folder inside the container at this path".
The upshot is that `index.html` ends up where nginx looks for pages, and `default.conf` where
it looks for settings.

The closest analogy from your world is attaching a shared folder to a virtual machine. The
difference is that the contents live in the cluster as a separate object, and you can change
them without touching either the image or the machine itself.

⚠️ **Order in `volumes` matters.** The lab about rolling out versions switches the page with a
command that addresses the volume **by number** — the first in the list. If you swap the
blocks around, the command will silently substitute the settings for the page, and nginx will
stop working. There's a comment about this in the file itself. The safe approach — a
patch-merge by volume name instead of by number — is covered in the lab about rolling out
versions.

### Fourth: the permanent address

```yaml
kind: Service
spec:
  selector:
    app: rickroll
  ports:
    - port: 80
      targetPort: http
```

`Service` is a permanent name that all copies of the application sit behind. You address
`rickroll`, and you reach any one of them.

The link between the Service and the Pods isn't a list of addresses but a **condition**:
`selector: app: rickroll` means "all Pods with the label `app: rickroll`". A label is an
arbitrary "key: value" pair you attach to an object so you can later find it by that pair;
the closest thing to it is tags in vSphere, except here labels aren't for scanning by eye but
for building working connections. A new Pod appears with this label — it automatically joins
the load balancing. It disappears — it drops out. No one edits the list by hand.

This is precisely the key difference from a load-balancer pool, where you write the addresses
in.

</details>

Now let's apply it:

```bash
# apply = "bring the cluster to what's described in the file". All four objects are created
# with a single command; the cluster works out the order within the file on its own.
#   -f   take the description from a file
kubectl apply -f rickroll.yaml
```

**What you should see** — four lines about objects being created:

```
configmap/rickroll-conf created
configmap/rickroll-page-v1 created
deployment.apps/rickroll created
service/rickroll created
```

Wait for the copy to start up:

```bash
# rollout status waits until the Deployment sees the job through: the required number of copies
# is running and ready to accept requests. The command finishes on its own when that happens.
kubectl rollout status deployment/rickroll
```

The wait was a matter of seconds. What started wasn't an operating system but a single
process inside one already running: the kernel on the node was brought up long ago and is
shared by all containers. A virtual machine in the same place would take a minute or two to
boot — it has to bring up its own kernel, services, and network.

## Step 3. See what the cluster made out of the file

📍 **Where:** on the laptop.

The cluster doesn't store the file itself, but the objects it created from it. Let's ask what
the thing we applied looks like now:

```bash
# get deployment rickroll = show a single object by type and name.
#   -o yaml   print it in full, in the same form you could write it by hand
kubectl get deployment rickroll -o yaml
```

The output is long: the cluster filled in most of it itself — default values, internal
fields, the current state. Find these lines by eye:

```yaml
spec:
  replicas: 1
  template:
    spec:
      containers:
      - image: nginxinc/nginx-unprivileged:1.27-alpine
```

This is what you wrote in the file. **Inside the cluster everything is described in text** —
both what you apply and what the cluster hands back. When you ordered the cluster through the
Cozystack dashboard in lab 0, it assembled the very same text and sent it to the platform: the
button is a layer over the text, not an alternative to it.

The difference is in what remains afterwards. A file you can put into Git, review before
applying, look up who changed it and when, roll back with a single command, deploy the same
thing in a second cluster without trying to remember which boxes you ticked in the first. A
click of the mouse leaves no trace: a month later no one, you included, will remember why that
particular value was set.

## Step 4. Open it in the browser

📍 **Where:** on the laptop.

**What's about to happen:** the application lives inside the cluster and isn't visible from
outside. The command below runs a tunnel from your laptop inward.

```bash
# port-forward = a tunnel from the laptop into the cluster, alive as long as the command runs.
#   svc/rickroll   run the tunnel to the Service named rickroll, which in turn routes
#                  the request to a live copy of the application
#   8080:80        the left number is the port on the laptop, the right is the Service port in the cluster
kubectl port-forward svc/rickroll 8080:80
```

The command doesn't finish: it holds the tunnel open until you stop it. Open
<http://localhost:8080>.

**What you should see:** a shimmering heading, a line of the song, and at the bottom — the Pod
name. Compare it against what the cluster shows.

📍 **Where:** in a second terminal window. The first is busy with the tunnel — while the
command runs, you can't type anything in it. Open a new window and set the access file again
there: environment variables don't carry over into a new window.

```bash
export KUBECONFIG=~/lab.kubeconfig
```

```bash
# get pods = "show the running copies".
#   -l app=rickroll   show not all Pods, but only those with the label app=rickroll —
#                     the very one the Service uses to find them
kubectl get pods -l app=rickroll
```

The names match. It was this exact copy that served the page.

To close the tunnel — `Ctrl+C`.

## The check

📍 **Where:** on the laptop, in the same terminal window where you were working with `kubectl`.

```bash
# run it from the lab folder: the script looks for its files next to itself.
# the ./ before the name means "run the file from right here", not look for it in system folders
./check.sh
```

⚠️ **On Windows the script runs from WSL**, not from PowerShell — how to set it up is written
at the start of lab 0. Without WSL you can still complete the lab, but there'll be no artifact
report.

The script checks not the fact that the manifest was applied, but the work in substance: the
application responds over HTTP, the response contains a Pod name, and that name matches an
actually running copy.

## Cleanup

You'll need the application in labs 2, 3, and 4 — don't delete it now. Keeping it is cheap:
one copy of nginx asks for two hundredths of a core and 32 megabytes, and when it comes to
deleting it — that's a single command, and the resources return to the node's shared pool the
same second.

## What we can do now

- Tell where the platform dashboard ends and your own cluster begins
- Deploy an application with a single file and a single command
- Read a manifest and explain what each block is for
- Tell `requests` from `limits`
- Understand that a Service finds copies by a label, not by a list of addresses
- Reach inside the cluster with a browser through `port-forward`

## And in vSphere this would be

A request for a VM, a request to networking for an address, a request to security for a
certificate. Days at best. Here — one file and one command.

**Where vSphere is more convenient, honestly.** When you deploy a VM, you get a full-fledged
machine: you can go inside, install anything, fix it in place, and leave it running that way.
A Pod is built differently — it's immutable, and "go inside and fix it" makes no sense there,
because at the next restart the edit vanishes. This is disciplining, but at first it's
irritating, and it's foolish to pretend otherwise.
