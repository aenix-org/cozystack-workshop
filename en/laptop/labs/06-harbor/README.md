# Lab 6 · Your own private image registry

| | |
|---|---|
| **Time** | 45 minutes, 10 of them spent waiting |
| **What it proves** | An image registry stands up in ten minutes, and the cluster can pull only from it |
| **What you'll need** | The cluster from Lab 0, `kubectl`, `docker` (or `podman`) on the laptop, dashboard access |

## Why this matters

The "Passes" service made it as far as information security, and an email came back.

> Container images are pulled from public registries on the internet. This is unacceptable:
> nobody has vetted what's inside an image, its contents can change under the same name,
> and if the external resource is unavailable, a production service won't start. All images
> must be stored in the organization's internal registry.

There's nothing to argue with — every point is fair. A public image tagged `latest` can be one
thing today and another tomorrow. The image's author can delete it. An external registry can
throttle your download speed at the worst possible moment — and that's not hypothetical, every
large public registry does it.

So you need a registry of your own. Normally that's a project in itself: a request for a VM,
installation, certificates, storage, backups, someone's quarter. Today it's a line item in the
catalog.

And since the registry is yours and closed, the cluster will have to be granted access to it.
This is where everyone trips up, and we'll trip up too, on purpose.

## Little glossary

| Term | What it is | Like… but |
|---|---|---|
| **Image** | A snapshot of an application with everything needed to run it | **A VM template**, but immutable: you can't step inside and fix it, you build a new one |
| **Layer** | A part of an image. An image is built from layers, and layers are reused | identical layers of different images are stored in the registry only once |
| **Tag** | A version label for an image: `passes-api:v1` | **A template version name**, but a tag can be reassigned to a different image, and that's the main source of trouble |
| **Registry** | An image store served over HTTP | **A Content Library**, but it hands out layers over the network on every launch rather than copying the whole template |
| **Harbor** | A registry with a UI, projects, permissions and a vulnerability scanner | **Content Library + permissions + reports**, but it can inspect image contents and sign them |
| **A project in Harbor** | An area inside the registry with its own permissions | **A folder in a Content Library**, but it can be public or private, and that determines whether credentials are needed |
| **`imagePullSecret`** | A Secret holding a login and password for the registry, read by the node | **The account for connecting a Content Library**, but it's needed by the **node**, not by you; your `docker login` does the cluster no good |
| **Dockerfile** | The instructions for building an image | **The instructions for preparing a template**, but it runs in full and from scratch on every build |
| **Downward API** | A way to give a Pod information about itself through environment variables | **Guest variables from VMware Tools**, but the values are injected by the cluster at launch; the application doesn't ask for them |

## Two kubeconfigs: don't mix them up

From here on the lab involves two different clusters, and it's worth keeping them apart before
the first command.

| Kubeconfig | What it is | What we do with it |
|---|---|---|
| `~/.kube/workshop` | The Cozystack management cluster, your tenant | look at managed services: Harbor, databases, queues |
| `~/lab.kubeconfig` | **Your** `lab` cluster from Lab 0 | deploy the application |

Both come from the dashboard. The tenant one lives in the `kubeconfig-tenant-workshopXX`
Secret (the Secrets tab), the cluster one in the access section of your `lab` cluster.

⚠️ **The most common cause of "nothing works for me" in this lab is a command that went to the
wrong cluster.** Before every block of commands it's written which cluster it's meant for. If
you're unsure:

```bash
# echo prints the value of the variable: which access file kubectl is using right now.
# Empty means kubectl will use the default file ~/.kube/config, not the one you think.
echo $KUBECONFIG

# get nodes = "show the cluster's nodes". Here it's a litmus test:
# the answer tells you which of the two clusters the command went to.
kubectl get nodes
```

The `lab` cluster will have a single node named something like `kubernetes-lab-md0-...`. In the
management cluster this command will most likely return a refusal — a tenant has no permission to
view nodes.

## What's in the lab folder

All the files are already yours — you got them along with the repository. There's nothing to
create or type out again: wherever it says `kubectl apply -f name.yaml` below, the file is taken
from here.

```bash
# every command in this lab is run from the lab folder — change into it
cd labs/06-harbor
```

| File | What it is | When it comes in handy |
|---|---|---|
| `app/` | The "Passes" service sources in Go and a `Dockerfile` — you build the image from them | you build locally, `docker build` |
| `passes-broken.yaml` | A **deliberately incomplete** file: no registry access credentials | you apply it to see the refusal with your own eyes |
| `passes.yaml` | The same file, but with registry access | you apply it once you've figured things out |
| `check.sh` | A check that the image came from your Harbor, not from the internet | you run it at the end of the lab |

## Step 1. Create Harbor

📍 **Where:** in the browser, in the Cozystack dashboard. The registry is a shared tenant
resource, not part of your lab cluster, so it's created in the same place the cluster itself was.

Tenant → **Create application** → `Harbor`.

| Field | Value | Why |
|---|---|---|
| Name | `harbor` | it becomes part of the registry address; you'll see what comes out after creation |
| Host | leave empty | then the address is assembled on its own from the name and the tenant domain |
| Storage class | `replicated` | the data will be kept in three copies across different nodes |
| Trivy → enabled | **turn off** | the vulnerability scanner downloads a database several gigabytes in size; on a training testbed that's an extra twenty minutes of waiting |
| Database → replicas | `1` | we're not testing the fault tolerance of the registry's database today |
| Database → size | `5Gi` | |
| Redis → replicas | `1` | |
| Redis → size | `1Gi` | |
| Core / Registry preset | leave as suggested | |

⚠️ **The Redis in this form is Harbor's own internal cache; it has nothing to do with the next
lab.** In the lab about caching you'll stand up a separate Redis for your own application. The
name is the same, the roles are different.

Click create and wait. Harbor comes up in five to ten minutes: it's not a single application but
several services plus a database plus object storage for the image layers themselves.

⚠️ **If Harbor sits in a "not ready" state longer than fifteen minutes** — look at what's
happening: `kubectl -n tenant-workshopXX get pods | grep harbor`. Most often it's the install
queue, shared across the whole platform: your application is behind other people's in it and is
waiting.

Harbor stores image layers in S3-compatible storage, and the bucket for them is created on its
own — you don't need to enable your own storage in the tenant for this, the parent one will do.
If the Pods still don't appear after more than half an hour, write to the workshop chat with the
output of this command.

## Step 2. Grab the credentials and log in to the registry

📍 **Where:** in the dashboard, then in a terminal on the laptop.

Open the `harbor` application you created and find the tab with the secrets. There you'll find a
secret with the registry credentials, and inside it three keys you need:

| Key | What's in it |
|---|---|
| `url` | your registry's address, of the form `https://harbor-....<testbed domain>` |
| `admin-password` | the administrator's password |
| `redis-password` | Harbor's internal password, which you don't need |

The login is `admin`.

⚠️ **Don't guess the registry's address, take it from the `url` key.** The platform prefixes the
application name with the service type, so the address may turn out different from what you
expected from the name. The same address is visible in the application's list of ingresses.

The same password is also available via a command. A tenant isn't allowed to read **all** secrets
across the board — check for yourself, `kubectl auth can-i get secrets` answers `no`. But for each
application you create, the platform sets up a separate rule allowing exactly its credentials:

```bash
# get secret = "show the Secret object". The secret's name is assembled from the prefix
# for the application type and its name: harbor- + harbor.
#   -n tenant-workshopXX  which namespace to look in — your tenant
#   -o jsonpath='...'     pull a single field out of the object rather than printing the whole thing
#   base64 -d             decode: values inside secrets are stored in base64
#   ; echo                add a newline, otherwise the password runs into the prompt
kubectl -n tenant-workshopXX get secret harbor-harbor-credentials \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The dashboard is more convenient in that you don't have to fuss with base64. The command is more
convenient in that you can drop it into a script.

Open the address in a browser and log in. You'll see the Harbor UI with a single project,
`library`.

Now the same thing from the terminal. `docker login` asks for a username and password and saves
the credentials on your laptop, in the file `~/.docker/config.json`. After that `docker push`
and `docker pull` go to this registry without asking anything.

```bash
# login = "remember the credentials for this registry".
# The argument is the registry address from the url key; harbor-harbor.workshop03.example.org here is an example.
# The command will ask for a username (admin) and a password; the password isn't shown as you type.
docker login harbor-harbor.workshop03.example.org
```

From here on in the text `harbor-harbor.workshop03.example.org` is **your** address — substitute your own.

**What you should see:**

```
Login Succeeded
```

⚠️ **This `docker login` taught your laptop to log in to the registry — and only it.** It did
nothing for the cluster. Remember this; you'll need it a little further into the lab.

## Step 3. Set up a private project

📍 **Where:** in the browser, in Harbor.

**Projects** → **New Project**.

| Field | Value | Why |
|---|---|---|
| Project Name | `passes` | one project per service — that makes it easier to hand out permissions |
| Access Level | **do not check Public** | security asked for a closed registry, not "yours, but open to the whole internet" |
| Storage quota | `-1` (no limit) | on the testbed a quota would only get in the way |

The `library` project, which was there from the very start, is public. Images are pulled from it
without any credentials at all. That's exactly why we won't use it: it won't produce the very
access error the lab was built around.

## Step 4. Build the image

📍 **Where:** on the laptop.

In this lab's folder there's `app/` — the source of the "Passes" service and the build
instructions. Before building, let's go over what's in there.

<details>
<summary><b>A closer look: what's inside the app</b></summary>

The file `app/main.go`, about seventy lines of Go. It does exactly two things.

**It answers `/healthz` with the word `ok`.** This is the readiness-check address: the cluster
knocks here and doesn't send traffic to a replica until it gets an answer.

**It answers `/` with a small JSON** in which it reports about itself:

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

How does the application know its own name, node and namespace? It **doesn't find them out**.
The cluster puts them there at launch, into environment variables:

```go
Pod:  env("POD_NAME", "unknown"),
Node: env("NODE_NAME", "unknown"),
```

And the manifest says what to put there:

```yaml
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
```

This is called the downward API — "information handed down from above". The closest analogue in
vSphere is the guest variables that VMware Tools hands into the machine. The difference is that
here the application asks for nothing and goes nowhere: the values are already sitting in the
environment by the time the process starts. No client to the cluster API, no permissions on that
API needed.

**There isn't a single external library in the application, only the Go standard library.** This
isn't affectation: a build with dependencies would go to the internet for packages, and the whole
lab started with security forbidding trips to the internet.

The file `app/Dockerfile` is the build instructions. It has two stages:

```dockerfile
FROM golang:1.23-alpine AS build
...
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/passes-api .

FROM alpine:3.21
COPY --from=build /out/passes-api /usr/local/bin/passes-api
```

The first stage is the build stage. It needs the entire Go compiler, roughly 350 MB. The second
stage is what actually ships to the cluster: from the first stage **only the finished binary** is
carried over, everything else is thrown away.

The result is an image of about ten megabytes instead of three hundred and fifty. It's not only
about size: inside there's no compiler, no sources, no package manager. Whoever did get into the
container has nothing to work with.

Compare this with how it works for virtual machine templates. A template carries the whole
operating system inside it, along with the compiler if it ever ended up there. Shrinking it after
the fact is nearly impossible.

The last lines:

```dockerfile
RUN adduser -D -u 10001 app
USER 10001
```

The application doesn't run as root. In a properly configured cluster a Pod won't be allowed to
run as root, and that's not us being fussy but a requirement you'll run into in any modern
cluster.

</details>

The `docker build` command builds the image: it reads the `Dockerfile`, runs the steps described
there, and puts the result into the image store on your laptop. The name the result is stored
under is set by the `-t` flag and consists of three parts:

| Part | What it means |
|---|---|
| `harbor-harbor.workshop03.example.org` | the registry address — where they'll go for the image |
| `passes/passes-api` | the project and name inside the registry |
| `v1` | the version tag |

The registry address is part of the image name. That's precisely why moving to your own registry
changes every manifest: the image name becomes a different one.

Let's build. Replace the address with your own:

```bash
cd labs/06-harbor

# build = "build the image from the Dockerfile".
#   --platform linux/amd64  which processor to build for; the cluster nodes are on x86,
#                           and the laptop may be on ARM — then without the flag you get the wrong thing
#   -t <address>/<project>/<name>:<tag>  what to name the result. The registry address at the start of the name
#                           is where docker push will later send it
#   app/                    the last argument — the folder with the Dockerfile and sources;
#                           its entire contents are handed to the builder
docker build --platform linux/amd64 -t harbor-harbor.workshop03.example.org/passes/passes-api:v1 app/
```

⚠️ **`--platform linux/amd64` is not decoration.** If you have a Mac on Apple Silicon (M1–M4) or
an ARM laptop, without this flag you'll build an ARM image. It will build without errors, push
without errors, and in the cluster — the nodes there are on ordinary x86 — the Pod will land in
`CrashLoopBackOff`, and the logs will say `exec format error`. This takes a long time to diagnose,
because nothing around it hints that the issue is the processor architecture.

**What you should see** — lines about the build steps and, at the end:

```
Successfully tagged harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

## Step 5. Send the image to your registry

📍 **Where:** on the laptop.

The built image so far lives only on your disk. `docker push` sends it to the registry layer by
layer; layers that are already in the registry are not sent again.

```bash
# push = "send the image to the registry". Where to send it, docker takes from the image name:
# the first part of the name is the registry address, and there it goes, with the credentials from docker login.
docker push harbor-harbor.workshop03.example.org/passes/passes-api:v1
```

**What you should see** — the layers going out, and at the end a line with a long hash, the
`digest`.

Take a look in Harbor in the browser: **Projects** → `passes` → a repository `passes/passes-api`
has appeared there, and in it the tag `v1`. You can see the size, the date and that same `digest`.

That `digest` is the exact contents of the image. The tag `v1` can be reassigned tomorrow to a
different image and no one will notice; the `digest` can't be forged. Hence the rule everyone
learns sooner or later: **you ship to production by digest, not by tag.**

## Step 6. Deploy to the cluster

📍 **Where:** on the laptop, the `lab` cluster.

```bash
# KUBECONFIG tells kubectl which access file to use. We switch to your `lab` cluster:
# from here on all kubectl commands go to it.
# It stays in effect until the terminal window is closed.
export KUBECONFIG=~/lab.kubeconfig
```

In the lab folder there's `passes-broken.yaml`. Instead of the registry address it has a
placeholder, `HARBOR-HOST` — it needs to be replaced with your address. `sed` does this: it edits
the file in place, without asking or showing anything. Take the line for your system:

```bash
# sed -i = "edit the file in place"
#   's|what|with what|g'  replace all occurrences; the separator | is used instead of / because
#                     the address has slashes and they would have to be escaped
#   The sed in macOS requires a mandatory argument after -i; the empty quotes
#   mean "make no backup copy". On Linux there must be no such argument.

# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes-broken.yaml
```

Apply it:

```bash
# apply = "bring the cluster to what's described in the file"
kubectl apply -f passes-broken.yaml

# get pods = "show the Pods".
#   -l app=passes-api  only the ones with this label, not everything
#   -w                 don't exit, print changes as they appear;
#                      stop watching — Ctrl+C
kubectl get pods -l app=passes-api -w
```

**What you'll see** — and it's not what you were expecting:

```
NAME                          READY   STATUS             RESTARTS   AGE
passes-api-6c9d4f7b8-2xk4n    0/1     ErrImagePull       0          8s
passes-api-6c9d4f7b8-2xk4n    0/1     ImagePullBackOff   0          22s
```

Stop watching with `Ctrl+C` and see what the cluster says:

```bash
# describe = "tell me about the object in detail". At the very end of the output comes the event log:
# what the cluster tried to do with the Pod and how it ended.
# tail -12 keeps the last twelve lines — the events are right there.
kubectl describe pod -l app=passes-api | tail -12
```

```
  Warning  Failed   kubelet  Failed to pull image
    "harbor-harbor.workshop03.example.org/passes/passes-api:v1":
    failed to resolve reference: unexpected status from HEAD request: 401 Unauthorized
```

> **Stop and think before reading on.**
>
> You just successfully logged in to the registry with `docker login` and successfully sent the
> image there. The registry knows you. Why does the cluster get refused?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

**You're not the one downloading the image.** `kubelet` downloads it — a service on the cluster
node. That's a different machine, a different process and a different user.

Your `docker login` wrote the credentials into the file `~/.docker/config.json` on **your
laptop**. The cluster node knows nothing about that file and can't: between it and your laptop
there's nothing in common at all, other than the fact that you send commands there.

Go back to the warning after `docker login` a little earlier in the lab. That's exactly what it
said, but the consequences weren't visible yet.

**How to do it right.** The credentials need to be placed into the cluster itself — into a Secret
object of a special kind — and then the application's manifest needs to say which secret to use
when downloading. Such a secret is called an `imagePullSecret`.

**Why the cluster needs separate credentials rather than yours.** Three reasons, and all three are
practical.

First: you might not be around. A node will restart at three in the morning and go download the
image again. If it went under your account, everything would hinge on your still working at this
company and your password not having expired.

Second: the permissions differ. You need permission to **write** to the registry, to send builds
there. The cluster needs only to **read**. Giving the cluster permission to erase images from the
registry is a bad idea, and with your account you'd have given it exactly that.

Third: the trail differs. When the registry log shows that the image was downloaded by
`robot$passes-puller` rather than `admin`, an incident investigation becomes possible.

**Why not configure the node directly.** You can put the credentials straight on the node, into
the container runtime config — then no `imagePullSecret` is needed. People sometimes do that. But
nodes in a cluster are disposable: they're recreated on upgrade, added as load grows, killed on
failure. A setting made by hand on a node lives until the node is first replaced. A secret in the
cluster outlives any replacement.

**A lesson broader than this error.** `ImagePullBackOff` is almost always one of three things: a
typo in the image name, no credentials, or the image exists but not for the right processor
architecture. Look not at the Pod's status but at `kubectl describe pod` — that's where the real
cause is written.

</details>

## Step 7. Grant the cluster access to the registry

📍 **Where:** on the laptop, the `lab` cluster.

We create a secret with the registry credentials. A separate variant of the `create secret`
command makes a secret of the kind `kubelet` can read on its own when downloading images:

```bash
# create secret docker-registry = "create a secret with registry credentials"
#   harbor             the secret's name inside the cluster; the application manifest will refer to it
#   --docker-server    which registry these credentials are for — the same address as in the image name
#   --docker-username  who's logging in
#   --docker-password  the password; single quotes are needed if it has a $, ! or space
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password='YOUR-PASSWORD'
```

⚠️ **A password on the command line stays in the shell history.** On the testbed this doesn't
matter, in a working environment it does. A way without the history:

```bash
# read puts what's typed at the keyboard into the HARBOR_PASS variable:
#   -s  don't show what's typed on the screen
#   -r  don't treat a backslash as a special character
# Nothing will appear on the screen after this line: paste the password and press Enter.
read -rs HARBOR_PASS

# From here the password is substituted from the variable, so only the variable name
# goes into the shell history. The double quotes are mandatory: without them spaces would break the value.
kubectl create secret docker-registry harbor \
  --docker-server=harbor-harbor.workshop03.example.org \
  --docker-username=admin \
  --docker-password="$HARBOR_PASS"

# unset erases the variable so the password doesn't reach the next commands in this window
unset HARBOR_PASS
```

<details>
<summary><b>What's inside this secret and why it has a separate type</b></summary>

Let's ask the cluster what kind of secret came out:

```bash
#   -o jsonpath='{.type}'  print a single field of the object — the secret's type
#   {"\n"}                 add a newline, otherwise the output runs into the prompt
kubectl get secret harbor -o jsonpath='{.type}{"\n"}'
```

```
kubernetes.io/dockerconfigjson
```

The secret has a **type**, and it's not decorative. An ordinary secret is a set of key-value
pairs, and what to do with them is up to the application. A secret of type
`kubernetes.io/dockerconfigjson` is understood by `kubelet` itself: it knows that inside is a file
of the same format as `~/.docker/config.json`, and it can use it when downloading images.

To look at the contents (the password there is in base64 — that's **not encryption**, but a way to
write binary data as text, and anyone can decode it):

```bash
# .data.\.dockerconfigjson — the key inside the secret. The key name itself starts with a dot,
# so it's escaped: otherwise jsonpath would take it for a path separator.
# base64 -d decodes the value back into text — you'll see the same format
# as in the file ~/.docker/config.json on your laptop.
kubectl get secret harbor -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Hence something important: **a Secret in Kubernetes is not encrypted by default**, it's merely
walled off by access permissions. Whoever can read secrets in the namespace sees the passwords.
How to handle this like a human being is a separate lab about a secrets store.

**How it's done in the field.** Not with the `admin` account. Harbor has robots: **Projects** →
`passes` → **Robot Accounts** → create a robot with only `pull` permission. The robot's credentials
go into the `imagePullSecret`, and then a leaked secret from the cluster means someone can download
your images — unpleasant, but not fatal. A leaked `admin` means someone can substitute them.

We use `admin` so as not to drag out the lab. Know that this is a simplification.

</details>

Now apply the correct manifest. First the same address substitution as before, only in a
different file; then remove the broken application and put up the working one:

```bash
# Linux
sed -i    's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor-harbor.workshop03.example.org|g' passes.yaml

# delete -f = remove from the cluster exactly the objects described in the file
kubectl delete -f passes-broken.yaml
kubectl apply -f passes.yaml

# rollout status waits until the new replicas become ready, then finishes on its own.
# If it doesn't get there, it returns an error, which is why such a line is handy in scripts.
kubectl rollout status deployment/passes-api
```

**What you should see:**

```
deployment "passes-api" successfully rolled out
```

The difference between the working manifest and the broken one is exactly two lines:

```yaml
      imagePullSecrets:
        - name: harbor
```

## Step 8. See what came out of it

📍 **Where:** on the laptop, the `lab` cluster.

The application isn't exposed to the outside, but you need to look at it. `port-forward` digs a
tunnel from the laptop into the cluster: while the command is running, a request to
`localhost:8080` goes to the `passes-api` service. The closest analogue is a temporary port
forward on a NAT gateway, only without touching the network.

```bash
# port-forward svc/passes-api = a tunnel to the service, not to a specific Pod
#   8080:80 — the left number is the port on your laptop, the right one the service port in the cluster
# Don't close the window: the tunnel lives as long as the command runs.
kubectl port-forward svc/passes-api 8080:80
```

In another terminal window:

```bash
# curl — "go to the address and show the answer".
#   -s     don't show the progress indicator
#   ; echo add a newline: the answer comes as a single line, and without it
#          it runs into the shell prompt
curl -s http://localhost:8080/; echo
```

**What you should see** — a JSON in which the application reports which replica answered, on which
node it runs and from which registry it arrived:

```json
{
  "service": "passes-api",
  "version": "v1",
  "pod": "passes-api-7d9f8c6b4-xk2mp",
  "node": "kubernetes-lab-md0-abc12",
  "namespace": "default",
  "registry": "harbor-harbor.workshop03.example.org",
  "time": "2026-08-21T09:12:33Z"
}
```

The `pod` field in the answer is the name of the replica that answered. Compare it against the
list of replicas:

```bash
# a new terminal window knows nothing about the KUBECONFIG variable — set it here too,
# otherwise kubectl will go to the wrong cluster
export KUBECONFIG=~/lab.kubeconfig

# the same selection by label: the list should contain the name you saw in the answer
kubectl get pods -l app=passes-api
```

Repeat the request several times — the name will stay **the same one**, and that's not a
malfunction. `port-forward` picks a single replica at the moment it starts and holds the tunnel to
exactly that one until `Ctrl+C`; there's no balancing on this path at all. There is on the
`Service`, but you can only see it from inside the cluster — from outside you're talking to a
specific Pod.

You can check the balancing for real like this — eight requests from a temporary Pod that lives
inside the cluster:

```bash
# run brings up a one-off Pod, --rm cleans it up afterwards.
# Everything after -- runs inside the Pod: eight times we hit the service by its internal name
# and print the line with the name of the replica that answered.
kubectl run probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 \
  -- sh -c 'for i in $(seq 1 8); do curl -s http://passes-api/ | grep -o "passes-api-[a-z0-9-]*"; done'
```

**What you should see:** two different names mixed together — this is the `Service` spreading
requests across the replicas.

To close the tunnel — `Ctrl+C` in the first window.

Close the loop: go into Harbor in the browser, into the `passes` project. On the
`passes/passes-api` repository the download counter (**Pulls**) has become non-zero. Your cluster
really did go exactly here.

## Verification

📍 **Where:** on the laptop, in the same terminal window where you worked with `kubectl`.

The script goes to both clusters at once and takes them from environment variables. The first two
are mandatory, the third is the path to the tenant kubeconfig.

```bash
cd labs/06-harbor

# which cluster to check the application in — your `lab`
export KUBECONFIG=~/lab.kubeconfig
# your tenant number: from it the script assembles the namespace name tenant-workshop03
export COZY_TENANT=workshop03
# where the access to the management cluster lives — there the script will look at Harbor itself.
# You can leave it unset: then the script looks for ~/.kube/workshop, and not finding it — skips
# the checks on the management cluster and says so.
export COZY_KUBECONFIG=~/.kube/workshop

./check.sh
```

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to install it is written
at the start of Lab 0. Without WSL you can do the lab, but there'll be no artifact report.

The script checks not the fact that Harbor was created, but the work in substance: the registry
answers over its API, the application in the cluster was started from an image lying in your very
own registry, the secret with the credentials exists and points to the same address, and the
service itself returns a JSON with the name of a Pod that actually exists.

## Cleanup

The application and Harbor will be needed in the next lab — don't delete them now.

When you're done with all the labs:

```bash
# delete the objects described in the file: both the Deployment and the Service
kubectl delete -f passes.yaml
# the secret was created by a command, not a file — delete it by name
kubectl delete secret harbor
```

Harbor itself is deleted through the dashboard, like any ordinary application. Along with it the
layer store goes too — that's a dozen seconds, not a request to write off a VM.

It's worth understanding what exactly you're deleting. A registry isn't only the place where the
images sit, but also the only answer to the question "what did we actually ship to production over
the past year". Deleting it in a working environment as easily as here is not something you'll
want.

## What we can do now

- Set ourselves up an image registry and explain how it differs from a Content Library
- Build an image with a two-stage build and understand why the result comes out thirty times smaller
- Tell a `docker login` on the laptop apart from the access the cluster needs
- Read `ImagePullBackOff` and find the real cause in `describe pod`
- Give a Pod information about itself through the downward API, without granting it permissions on the cluster API

## In vSphere this would be

The closest analogue of a registry is a Content Library. There is a similarity: both store images
and hand them out to machines, and both can do permissions and synchronization between sites.

Beyond that they diverge, and the difference isn't in the details.

**A Content Library copies the whole template.** A registry hands out layers and stores identical
layers once. If you have twenty services on the same base Alpine, the base lies in the registry in
a single copy, and when the twenty-first service launches the node will download only its own
layer — a handful of megabytes.

**A template is named, an image is addressed.** An image has a digest — a hash of its contents. By
it you can verify that you're running exactly the code you built and no other. A template has no
such thing: you rely on no one having swapped it.

**A registry is an HTTP service.** From this follows the whole point of the exercise: a build in
the pipeline puts an image there with one command, the cluster fetches it with another, and no one
mounts storage or copies files between sites by hand.

**Where vSphere is more convenient, honestly.** Three things.

A Content Library doesn't require understanding anything about credentials. Connect it — it works.
Here you had to separately explain to the cluster how to reach the registry, and you tripped up on
it, as everyone does.

Permissions in vCenter are unified. One account for everything: machines, the library, and the
network. Here permissions in the dashboard, permissions in the cluster and permissions in Harbor
are three different sets that must be kept in sync. That's the price of the registry being a
product in its own right, not part of the platform.

A template can be edited. You deploy a machine from a template, tune it further, capture a new
template — and the fact that the exact sequence of steps is written down nowhere doesn't get in
the way of anything. Images aren't built that way: if the build doesn't reproduce from the
`Dockerfile`, you're in trouble. The discipline is useful, but getting used to it is hard, and
pretending otherwise is foolish.
