# Lab 11 · Building a mobile app in the cluster

| | |
|---|---|
| **Time** | 40 minutes, of which up to 15 are spent waiting for the first build |
| **What it proves** | A build server isn't a server — it's a task that occupies a node for the duration of the build and then releases it |
| **What you'll need** | The cluster from Lab 0, `kubectl`, `~/lab.kubeconfig`, access to the tenant dashboard |

## Why this matters

The mobile team is writing a client for Propusk — the very screen an employee uses to
request a guest pass. For now they build it on one developer's VM. When he's on vacation,
there's no release.

They don't have a build server of their own, and they won't: their request for a dedicated
machine for the Android SDK was turned down twice — "the load is uneven, the machine will
sit idle." Which, frankly, is true. The build runs for twenty minutes a day, but the machine
it needs has four cores and sixteen gigabytes.

Here we'll do exactly what's being asked of us: we'll take those four cores **for twenty
minutes**, build the APK, and hand them back. And we'll put the finished file where anyone
can pick it up, including a tester with a phone — in a bucket.

This is the first time in all the labs that a workload **ends**. Everything we've deployed
until now was meant to run forever.

## Mini-glossary

| Term | What it is | Like… but |
|---|---|---|
| **Job** | A task: run something and wait until it finishes successfully | **A scheduled task in the guest OS**, but a job creates its own machine to run on and cleans it up itself |
| **Deployment** | A description of an application that runs forever | **A vApp**, but it never "finishes successfully" — a copy that disappears is recreated |
| **Object storage** | Storage with no files or directories — just a key and its contents | **A datastore**, but it isn't mounted. You put and fetch whole objects, over HTTP |
| **Bucket** | A named area within object storage | **A folder on a datastore**, but not nested: a bucket is the top level, and the "folders" inside it are part of the object's name |
| **S3** | A protocol for accessing object storage over HTTP | no direct analog; closer to a REST API than to NFS |
| **Access keys** | An "access key / secret key" pair instead of a login and password | **A service account**, but the keys are issued per bucket, not per person |
| **Secret** | A cluster object where you put passwords and keys | **An entry in a credential store**, but inside the cluster it's base64, not encryption. It hides things from view, not from an admin |
| **emptyDir** | A temporary disk that lives exactly as long as the Pod | **A temporary vmdk**, but it vanishes together with the Pod, with no way to recover it |

### Job versus Deployment — in one table

This is the key distinction of the lab, and it's worth nailing down before we apply anything.

The word **Pod** appears in both rows below. A Pod is the smallest unit of execution in a
cluster: a container (or several) brought up on a specific node. The closest analog is a
virtual machine dedicated to a single task, except it's created in seconds and doesn't
outlive its node. Neither a Job nor a Deployment runs anything itself: they create Pods and
decide what to do when a Pod disappears.

| | Deployment | Job |
|---|---|---|
| What "all good" means | the copies are running right now | the process exited with code 0 |
| A Pod finished successfully | the cluster treats it as a failure and creates a new one | the cluster considers the work done |
| How long it lives | until you delete it | until it runs to completion |
| How many times it executes | never — it doesn't "execute," it runs | once (or as many times as specified) |
| What's left afterward | a running application | the results of the work and logs |

Hence a practical consequence everyone trips over: **if you run a build as a Deployment, the
cluster will run it again and again**. The build finished successfully — so the copy is
gone — so a new one must be created. An infinite loop, and it's not the cluster's fault:
that's what it was told to do.

## What's in the lab folder

All the files are already yours — you got them with the repository. There's nothing to
create or retype: wherever it says `kubectl apply -f name.yaml` below, the file comes from here.

```bash
cd labs/11-android
```

| File | What it is | When you'll need it |
|---|---|---|
| `bucket.yaml` | Storage for the built APKs | you apply it **in the tenant** |
| `propusk-src.yaml` | The source code of the Propusk mobile app | you apply it on your `lab` cluster |
| `android-build.yaml` | The build itself. The script is pulled out into a ConfigMap rather than inlined in the job | you apply it there too |
| `check.sh` | A check that the build succeeded and the APK landed in storage | you run it at the end of the lab |

## Step 1. Create the bucket

📍 **Where:** in the browser, in the tenant dashboard.

**A tenant** is your slice of the platform: what you see in the dashboard and what you
control. You ordered the `lab` cluster from Lab 0 inside it, and you'll order the bucket
there too.

A bucket is a **managed service** — a ready-made catalog item: you say what you need, and
the platform brings it up, updates it, and fixes it. It lives **not in the `lab` cluster**
but alongside it, in the tenant. And that's how it should be: build artifacts outlive the
cluster they were built in.

The tenant access file on this bastion is already set up — `~/.kube/config`, the same path as in
all the labs (token-based access, no browser opens).

Tenant → **Create application** → `Bucket`.

| Field | Value | Why |
|---|---|---|
| Name | `builds` | short and it's clear what's inside |
| Users | add the user `ci` | the build will write using these keys |
| Locking | off | protection against object deletion; overkill for builds |
| Storage pool | leave empty | the default pool is fine |

**The same bucket as text**, if you prefer. Note: the `namespace` (a partition inside the
cluster; your tenant is a separate namespace) here is the tenant's, and you need the tenant
access file, not the one for the `lab` cluster.

```bash
# KUBECONFIG — which access file kubectl uses. Here it's the tenant's: the bucket
# is ordered on the management cluster, not in the lab cluster
export KUBECONFIG=~/.kube/config

# apply = "bring the cluster to what's described in the file." The command doesn't create
# the storage itself — it hands the order to the platform.
#   -f bucket.yaml   which file to apply. Before this, replace
#                    tenant-workshopXX in it with your namespace, or the order goes elsewhere
kubectl apply -f bucket.yaml
```

**What you should see** — `bucket.apps.cozystack.io/builds created`.

<details>
<summary><b>A closer look: what's inside bucket.yaml</b></summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
```

`apps.cozystack.io` is the API group where the platform's managed services live. Virtual
machines, databases, and queues will have the same prefix. This isn't an "add-on on top of
Kubernetes" — these are ordinary Kubernetes objects, described by the platform.

```yaml
spec:
  users:
    ci: {}
```

A map of users. Each key is a separate S3 user, and for each one the platform will issue
**its own** pair of access keys. An empty object `{}` means full access.

Why several users on one bucket: the build needs write access, while the mobile team and
testers need read-only. Different keys, different rights, revoked separately:

```yaml
  users:
    ci: {}
    mobile:
      readonly: true
```

We'll make do with one to save lab time, but it's worth knowing about.

</details>

The bucket takes a few seconds to provision. Wait until it shows as ready in the dashboard.

## Step 2. Fetch the keys

📍 **Where:** in the dashboard, on the bucket's card, the **Secrets** tab.

Find the secret `bucket-builds-ci-credentials`. It holds four values:

| Field | What it is |
|---|---|
| `endpoint` | the storage address, **without** `https://` — you'll have to add the prefix yourself |
| `bucketName` | the real bucket name: long, with an identifier, not `builds` |
| `accessKey` | the "login" |
| `secretKey` | the "password" |

⚠️ **`bucketName` is not the name you typed in.** The name `builds` is the name of the
Cozystack object. The real bucket name in storage is issued by the platform itself, and it
looks like `bucket-a9209f83-...`. That's exactly what you must substitute, otherwise you'll
get access denied to a nonexistent bucket and spend ten minutes hunting for a typo.

These same four values are available via the command line — the platform grants access to
the credentials of every application you've created. The command below extracts one of the
four values, `accessKey`; the rest are fetched the same way, only the field name changes.

```bash
# We work with the same tenant access as in the previous step: the secret lives in the tenant.
# get secret = "show the object with passwords and keys." The values inside the secret are
# base64-encoded — this isn't encryption, just a way of writing binary data as text.
#   -n tenant-workshopXX   which namespace to look in
#   -o jsonpath='...'      return not the whole object, but a single field from it:
#                          .data.accessKey — the accessKey field inside the data section
#   base64 -d              decode it back into readable form (d = decode)
#   ; echo                 add a line break: without it the value would run into
#                          the next terminal prompt
kubectl -n tenant-workshopXX get secret bucket-builds-ci-credentials \
  -o jsonpath='{.data.accessKey}' | base64 -d; echo
```

Reading all secrets wholesale isn't allowed for the tenant, though: `kubectl auth can-i get
secrets` will answer `no`. Rights are granted narrowly, to specific names — and to the
kubeconfig of your cluster from Lab 0 as well.

## Step 3. Put the keys into your own cluster

The build will run in the `lab` cluster, but the keys live in the tenant. The clusters are
different; nothing moves across automatically. We'll transfer them by hand.

📍 **Where:** on the bastion (in the bastion terminal).

We'll assemble our own secret in the `lab` cluster with the four values from the previous
step. Don't change the field names: the build script looks for variables with exactly these
names.

```bash
# From here to the end of the lab we work with the lab cluster, not the tenant
export KUBECONFIG=~/lab.kubeconfig

# create secret generic = "create a secret from the values I'm about to list."
# generic means "an arbitrary set of name-value pairs," not a ready-made type
# for an image-registry password or a TLS certificate.
#   bucket-creds        the secret's name. The Job will reference it by this name
#   --from-literal=name='value'   one pair. In place of ВСТАВЬТЕ_..., substitute
#                       the values from the bucket's card in the dashboard
kubectl create secret generic bucket-creds \
  --from-literal=endpoint='ВСТАВЬТЕ_endpoint' \
  --from-literal=bucketName='ВСТАВЬТЕ_bucketName' \
  --from-literal=accessKey='ВСТАВЬТЕ_accessKey' \
  --from-literal=secretKey='ВСТАВЬТЕ_secretKey'
```

**What you should see:**

```
secret/bucket-creds created
```

⚠️ **Use single quotes.** Secret keys regularly contain `$`, `!`, and `&`. Inside double
quotes the shell would interpret them its own way, and you'd get a different key than the one
you copied.

**Why this command is typed by hand instead of living in the repository as a file.**
Everything else in these labs is text that can go into Git. A secret can't. The `Secret`
object inside the cluster stores its values in base64, and base64 isn't encryption but a way
of writing: anyone who gets to the file reads the keys. A secret file in Git means keys in
Git forever, including the entire history. This is exactly the kind of audit finding that
brings OpenBao into the Propusk scenario.

## Step 4. Look at what we're going to build

The folder contains `propusk-src.yaml` — the app's source code as a ConfigMap. **A
ConfigMap** is a cluster object that holds text files inside it: the cluster then places them
inside the container as ordinary files on disk. The closest analog is a shared folder of
configs, except it's stored in the cluster itself and arrives together with the task's
description.

The source code lives there for the same reason: the build needs files, and there's no point
setting up a network disk for six text files.

The app does one thing: it displays the line «Request a guest pass». That's enough,
because the lab isn't about Android but about where it gets built.

**An APK** is what comes out at the end. It's an archive containing the compiled application,
images, texts, and a description of which screen to launch; this is exactly what the phone
installs. In its role it's the same as an `.msi` for Windows: a single file you hand to the
user.

<details>
<summary><b>A closer look: what's inside the source code</b></summary>

Six files, spread across the keys of the ConfigMap.

### `settings.gradle.kts` — where Gradle looks for dependencies

```kotlin
pluginManagement {
  repositories { google(); mavenCentral(); gradlePluginPortal() }
}
```

Three public repositories from which the Android build plugin, the Kotlin plugin, and
everything they pull in will be downloaded. This list is exactly what explains why the first
build is slow: from an empty container, everything has to be pulled down.

⚠️ This same spot is the first thing you'll change when security forbids going to the
internet for dependencies. Then your proxy repository gets written in here, exactly as Harbor
became the replacement for Docker Hub.

### `build.gradle.kts` — tool versions

```kotlin
plugins {
  id("com.android.application") version "8.5.2" apply false
  id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
```

`apply false` means "declare the version but don't enable it in the root project" — the
`app` module will enable them. The versions are pinned deliberately: a build that pulls "the
latest" will, a month from now, build differently than it does today, and you're the one
who'll be figuring out why.

### `app-build.gradle.kts` — the module itself

```kotlin
android {
  namespace = "io.aenix.propusk"
  compileSdk = 34
  defaultConfig { minSdk = 24; targetSdk = 34 }
}
```

`compileSdk 34` is the version of the Android SDK we compile against. It also determines
exactly what has to be downloaded at the SDK-install step, and that's about a gigabyte and a
half.

`minSdk 24` is the oldest Android the app will run on. Here that's Android 7.

```kotlin
  kotlinOptions { jvmTarget = "17" }
```

Kotlin compiles to JVM bytecode, hence the requirement on the Java version. The image we use
ships JDK 17, and these two numbers must match.

### `MainActivity.kt` — the application

```kotlin
class MainActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    ...
    view.text = getString(R.string.greeting)
```

One activity, one `TextView`, text from resources. It uses bare `android.app.Activity` rather
than a compatibility library: the app has zero external dependencies, and that saves a couple
of minutes of downloading on every build.

`R.string.greeting` is a reference to a string from `strings.xml`. The `R` class is generated
at build time; it isn't in the source. If you see the error "unresolved reference: R," it
means the resource-generation step failed, not your code.

### `AndroidManifest.xml` and `strings.xml`

The manifest declares which activity launches from the icon. `strings.xml` keeps texts
separate from code — that way they can be translated without involving the programmer.

</details>

We put the source code into the cluster. Nothing runs yet: these are just files the build
will need at the next step.

```bash
# Creates a ConfigMap with six files inside. To check it's in place:
# kubectl get configmap propusk-src
kubectl apply -f propusk-src.yaml
```

**What you should see** — `configmap/propusk-src created`.

## Step 5. Break down the Job

Before you run it, read what exactly you're running. The build will occupy the entire node,
and it's worth understanding what for.

<details>
<summary><b>A closer look: what's inside android-build.yaml</b></summary>

The file has two objects: a ConfigMap with the build script and the Job itself.

### The build script

It's in a ConfigMap for the same reason the nginx page lived separately from the Deployment:
forty lines of shell inside a `command` field are impossible to read.

Five steps, and all five are ordinary commands you'd type by hand on a build server. The
container starts empty: it has Java and Gradle from the image, but no Android SDK, no keys, no
source — the SDK and keys are pulled in by the build commands, and the source is brought along
by the ConfigMap mounted into the container.

| Step | What it does | How long it takes |
|---|---|---|
| 1 | downloads the Android command-line tools — the set of utilities used to install the SDK itself | 1–2 minutes |
| 2 | accepts the licenses and installs the SDK, platform 34, build-tools | 5–15 minutes |
| 3 | `gradle :app:assembleDebug` — compiling the source into an APK | 3–8 minutes |
| 4 | installs `mc`, a command-line client for S3 storage | seconds |
| 5 | puts the APK into the bucket under two names | seconds |

Three lines deserve a closer look.

```bash
# yes — a command that prints "y" endlessly: this way a batch of "accept the
# license? [y/n]" questions gets answered without a human.
#   >/dev/null 2>&1   discard both normal output and error output: it's not needed here
#   || true           "even if the command returned an error, treat it as fine"
yes | sdkmanager --sdk_root="$ANDROID_SDK_ROOT" --licenses >/dev/null 2>&1 || true
```

`|| true` here isn't a shortcut but a necessity: `yes` gets a SIGPIPE when `sdkmanager`
closes its input, and it returns a non-zero code. Under `set -o pipefail` this would fail the
build for no reason. If the licenses really weren't accepted, the very next command will
refuse to install the SDK, so we're not hiding the error.

```bash
# alias set = "remember the storage address and keys under the short name builds," so
# we don't repeat them in every copy command that follows.
#   "https://${endpoint}"   the address: we add the https:// prefix ourselves, it's not in the secret
#   ${accessKey} ${secretKey}   the login and password in S3 terms, they come from the secret
#   >/dev/null              suppress the output
mc alias set builds "https://${endpoint}" "${accessKey}" "${secretKey}" >/dev/null
```

The output is suppressed deliberately, and for the same reason the script has no `set -x`:
the Job's logs are visible to everyone with access to the cluster, and keys must not end up
there.

```bash
# echo prints a line to the task's log. It does no work — it's a marker
# that the previous copy command ran to completion
echo "APK-UPLOADED ${bucketName}/propusk/propusk-${STAMP}.apk"
```

A marker line. By it `check.sh` distinguishes "the Job ran" from "the APK actually made it to
the bucket" — these are different claims, and the second is stronger.

### The Job

```yaml
kind: Job
spec:
  backoffLimit: 1
```

How many times to recreate the Pod if the build fails. Zero would be more honest, but the
network sometimes drops out while downloading the gigabyte and a half of SDK, and a second
attempt is cheaper than investigating "why did mine fail."

```yaml
  activeDeadlineSeconds: 7200
```

A ceiling on the whole task, two hours. Without it, a hung build would hold the node until
evening, and you'd hear about it from a neighbor whose things won't deploy.

The countdown starts from the Job's creation, not from the container's start: time spent in
`Pending` and the node recreation a bit further along in the lab draw down the same limit. An
hour wasn't enough for this — the build would die with `DeadlineExceeded` right after a person
had already waited it out.

```yaml
      restartPolicy: Never
```

For a Job this field is required, and there are only two valid values. `Never` means: don't
restart a failed process inside the same Pod, but hand the decision to the Job — it'll create
a new one. That way each attempt has its own logs, and you can see which one failed.

The value `Always`, familiar from Deployment, isn't available here: "always restart" and
"wait until it finishes" contradict each other.

```yaml
          envFrom:
            - secretRef:
                name: bucket-creds
```

All four keys of the secret become environment variables with the same names. The alternative
is to list each variable separately; for four keys of the same kind, that's extra noise.

⚠️ A side effect worth knowing: `envFrom` will drag **all** the secret's keys into the
environment, including ones added later. For a secret you created yourself and for a single
task, that's acceptable. For a shared secret spanning the whole namespace, it isn't.

```yaml
          resources:
            requests: {cpu: "1", memory: 4Gi}
            limits:   {cpu: "2", memory: 6Gi}
```

Here's that honest price of an Android build. `requests` is what to reserve: one core and
four gigabytes. Less makes no sense — the Kotlin compiler will eat them up and ask for more.
`limits` is the ceiling: two cores and six gigabytes.

Compare it to the app from the first lab: `20m` of CPU and `32Mi` of memory. A fiftyfold
difference in CPU and a hundred-and-thirtyfold difference in memory. This bears on the
question "why specify `requests` at all": without them the scheduler would consider the build
as weightless as nginx and place it on a node where it doesn't fit.

```yaml
        - name: work
          emptyDir:
            sizeLimit: 12Gi
```

A temporary disk on the node. The SDK, the Gradle cache, and the build result will land
here — six to eight gigabytes in total. It lives exactly as long as the Pod: the Job
finished, the disk is gone.

**From this it follows directly why every build is slow.** We download the SDK and
dependencies from scratch every time. On a real build server, instead of `emptyDir` there'd
be a persistent volume, and it would outlive the task: the first build slower, the second
noticeably faster. We deliberately don't do this in the lab, to avoid introducing an extra
entity, but in real life it's the first thing you'd add.

```yaml
            items:
              - key: app-build.gradle.kts
                path: app/build.gradle.kts
```

A ConfigMap key can't contain a slash, but a mount path can. That's how a flat map of six keys
unfolds into the directory tree Gradle expects.

</details>

## Step 6. Run it — and hit a wall

📍 **Where:** on the bastion, in the `lab` cluster.

We apply the job and immediately look at the Pod it created.

```bash
# Creates two objects from the file: a ConfigMap with the script and the Job itself.
# From this moment the cluster is obliged to find a node for the build and start it
kubectl apply -f android-build.yaml

# get pods = "show the Pods." The task's Pod has no name of its own — the Job invents it
# itself, appending a random tail to its own name. So we search not by name but by label:
#   -l job-name=propusk-build   select Pods with the job-name label equal to the job's name.
#                               The Job attaches this label to its Pods itself
kubectl get pods -l job-name=propusk-build
```

**What you'll most likely see:**

```
NAME                   READY   STATUS    RESTARTS   AGE
propusk-build-x7k2p    0/1     Pending   0          40s
```

`Pending` doesn't mean "starting up." It means "didn't start and won't." The cluster writes
the reason into the Pod's events — its log of who tried to do what with it.

```bash
# describe = "show everything known about the object": settings, state, events.
# The output is long, so we keep only its tail:
#   sed -n '/Events:/,$p'   print lines from the one where "Events:" appears,
#                           through the end of the output ($ — end)
kubectl describe pod -l job-name=propusk-build | sed -n '/Events:/,$p'
```

**What you should see** — the line with the reason the Pod wasn't placed:

```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory.
```

> **Stop and think before reading on.**
>
> What exactly didn't add up? Recall which node you ordered in Lab 0 and how much memory the
> Job requested.

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

In Lab 0 we took the node `u1.medium` — one core and four gigabytes. The Job asks for
`requests: memory 4Gi` and `cpu 1`. That's exactly what the node has, but part of it is
already taken: kubelet reserves memory for itself, plus the node runs system Pods for
networking and monitoring, plus the app from the first lab.

Note that **both** fall short — CPU too. The `u1.medium` node gives one core, the build asks
for a whole one, and part of the core is already taken by system Pods. That's why the message
has two reasons, not one: any one of them is enough for the scheduler.

The scheduler adds up the `requests` of all Pods on the node and compares that with what the
node is actually willing to give. There's not enough free room, and the Pod is left waiting
forever.

**A lesson broader than this error.** The Kubernetes scheduler counts not actual consumption
but what's **declared**. A node where all the Pods are dozing and CPU usage is three percent
can be fully occupied as far as the scheduler is concerned — if the sum of `requests` already
equals capacity. And the reverse: a node gasping under load will keep accepting new Pods until
the sum of `requests` hits the ceiling.

This also explains the at-first-glance odd pair `Insufficient cpu, Insufficient memory` on a
seemingly empty cluster — you'll run into it more than once.

In vSphere you're familiar with both: the reservation that DRS accounts for during placement,
and actual load, which it looks at separately. Here placement is computed **only** from the
reservation, without the second half.

</details>

## Step 7. Grow the node

📍 **Where:** in the dashboard, in the `lab` application.

Open `Kubernetes` → `lab` → edit. In the node group, change:

| Field | Before | After | Why |
|---|---|---|---|
| Instance type | `u1.medium` (1 core, 4 GB) | `u1.large` (2 cores, 8 GB) | the minimum the build fits into |
| Disk | `20Gi` | `40Gi` | the SDK, Gradle cache, and image layers won't fit in twenty |

If your tenant's quota allows, take `u1.xlarge` (4 cores, 16 GB). The build will go
noticeably faster, and you'll hand the extra resources back right after the lab. If it doesn't
allow it, the form will refuse on save, and then `u1.large` is what's left.

⚠️ **Changing the node type recreates the node's virtual machine.** The old node departs, a
new one comes up, the Pods move over. This takes a few minutes, and everything that lived on
the node's local disk disappears. For our labs this is painless — the data lives in managed
services, not on the nodes — but on a production cluster this is an operation you plan.

Wait for the new node. The `lab` cluster has no graphical console, so we watch with a command:

```bash
# get nodes = "show the cluster's nodes" — those very virtual machines on which
# the Pods run.
#   -w   watch, "don't exit; append lines on every change." The old node
#        will drop from the list, a new one will appear and reach STATUS=Ready.
#        To leave the watch — Ctrl+C, which has no effect on the cluster
kubectl get nodes -w
```

As soon as the node is `Ready`, the stuck build Pod will move on its own — the scheduler
reviews `Pending` Pods constantly, there's no need to ask it. We check that it's moving:

```bash
# The same query as before the node edit. Now the STATUS column should show
# ContainerCreating, and in a minute or two Running
kubectl get pods -l job-name=propusk-build
```

## Step 8. Wait for the build

📍 **Where:** on the bastion, in the `lab` cluster.

We'll watch the build in its log — that is, in what the script prints to the screen inside the
container.

```bash
# logs = "show what the task printed."
#   -f                  follow: don't exit, but append lines as they appear.
#                       Exit — Ctrl+C, the build keeps going regardless
#   job/propusk-build   you can point at the Job itself, not the Pod: kubectl will find its Pod on its own
kubectl logs -f job/propusk-build
```

**What you should see** — the script's five steps in sequence. Timing guideposts:

| Log marker | Roughly when |
|---|---|
| `== 1/5 installing Android command-line tools ==` | immediately |
| `== 2/5 accepting licenses and downloading the SDK (the longest step) ==` | +1–2 minutes, and hangs the longest |
| `== 3/5 building the APK ==` | +5–15 minutes from the start |
| `BUILD SUCCESSFUL in ...` | +10–25 minutes from the start |
| `APK-UPLOADED bucket-.../propusk/propusk-...apk` | right after it |

⚠️ **Twenty minutes of silence at the `2/5` marker is normal, not a freeze.** `sdkmanager`
doesn't show download progress in non-interactive mode: it stays quiet and then prints `done`.
You can confirm the process is alive in another terminal window — check whether the Pod is
eating CPU and memory:

```bash
# top = "how much it's consuming right now." Not the requests claim, but actual usage
# this very second. Non-zero CPU means work is happening inside
kubectl top pod -l job-name=propusk-build
```

The Job is considered complete when the Pod exited with code 0 (a zero return code is the
widely accepted "ran without errors"):

```bash
# We look not at the Pod but at the job itself: it has columns the Pod doesn't
kubectl get job propusk-build
```

```
NAME             STATUS     COMPLETIONS   DURATION   AGE
propusk-build    Complete   1/1           18m32s     19m
```

The `DURATION` column is precisely the answer to the mobile team's question "how long does
the build take." Run the same Job a second time, by deleting and recreating it, and it'll take
just as long: we have no cache, and we know why.

## Step 9. Retrieve the APK

📍 **Where:** in the tenant dashboard, on the bucket's card.

The bucket has a web interface — open it from the bucket's card and log in with the same
`accessKey` and `secretKey`. Inside you'll see:

```
propusk/propusk-20260821-141207.apk
propusk/propusk-latest.apk
```

Two names for one file is common practice: the dated name shows the build history, and by
`latest` a tester always grabs the freshest one without asking what today's date is.

Note that the `propusk` "folder" doesn't actually exist. There are no directories in object
storage: `propusk/propusk-latest.apk` is the object's name in full, and the slash inside it is
drawn as a tree by the interface for our convenience.

**How this differs from the file share** you're used to:

| | File share (NFS, SMB) | Object storage (S3) |
|---|---|---|
| How it's connected | mounted as a disk | not mounted, requests over HTTP |
| Partial writes | you can write into the middle of a file | not allowed, an object is put whole |
| Directories | real | none, the slash is part of the name |
| Locks | yes | no |
| Who can reach it | whoever is on the same network | anyone with a key and HTTPS |
| How much fits | as much as the volume holds | practically no ceiling |

Hence the rule for choosing: **a database or a shared folder of documents — a file share;
artifacts and backups — object storage**. Trying to put a database on S3 is as painful as
handing out APKs over SMB across the internet.

## The check

📍 **Where:** on the bastion, in the same terminal window where you worked with `kubectl`.

```bash
# The script reaches the lab cluster with the same access file as you. The bucket
# credentials it takes from the bucket-creds secret — you don't need to enter anything separately
export KUBECONFIG=~/lab.kubeconfig
./check.sh
```

⚠️ **On Windows the script runs from WSL**, not from PowerShell — how to install it is
described at the start of Lab 0. You can complete the lab without WSL, but there'll be no
artifact report.

The script checks not that you applied the manifest, but that the build ran to the end: the
Job finished successfully, the logs contain `BUILD SUCCESSFUL`, the APK made it to the bucket,
and the storage from the secret really does respond from inside the cluster.

## Cleanup

Once finished, the Job consumes nothing: the Pod terminated, and its cores and gigabytes
returned to the node's free capacity at the moment of `Complete` — someone else can take them
right away. All that remains is a record in the cluster and the logs — a few kilobytes.

There's no need to delete it right away; the logs will still be useful. When you're done:

```bash
# delete -f = "remove from the cluster what's described in this file." Along with the Job
# its logs will disappear too, so this command comes last in time, not first
kubectl delete -f android-build.yaml
kubectl delete -f propusk-src.yaml
# We delete the secret separately: there's no file for it, you created it with a command
kubectl delete secret bucket-creds
```

⚠️ **Return the node to `u1.medium` if you no longer need it** — otherwise it'll occupy four
cores until the end of the workshop. Leave the bucket and its contents: it's small and will
come in handy if you want to rebuild.

It's precisely this cheapness of cleanup that is the argument against a dedicated build server.
We took a bigger node for the duration of the build and returned the previous one with a single
field edit.

## What we can now do

- Tell a Job from a Deployment and understand why a build must not be run as the latter
- Run a heavy one-off task in the cluster without setting up a machine for it
- Put artifacts into object storage and explain how it isn't a file share
- Read `Pending` as "didn't fit by `requests`," not as "loading"
- State the real price of an Android build in cores, gigabytes, and minutes

## And in vSphere this would have been

A request for a VM to serve as the build agent. A justification for why it needs sixteen
gigabytes if it works twenty minutes a day. A rejection. A second attempt a quarter later.
Then a machine that sits idle 98% of the time and, a year on, has three generations of the SDK
installed because deleting them is scary.

Here resources are taken for the duration of the task and returned by themselves.

**Where vSphere is more convenient, honestly.** A build machine that lives permanently has one
undeniable advantage: everything is already downloaded on it. Our build time is mostly the
downloading of the SDK and dependencies, which a permanent agent wouldn't have. This is cured
by a persistent volume for the cache, but the volume has to be set up, its size watched, and it
cleaned — that is, taking back part of the very work we were escaping. The difference is that a
volume costs pennies and requires no request, whereas a machine did.

And second: a live machine you can SSH into to see why a build is behaving strangely is
convenient. With a Job's Pod you can only look at the logs, and after completion even less.
Debugging a build in the cluster is slower at first.
