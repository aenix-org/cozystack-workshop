# Lab 4 · Rolling out a new version and rolling back

| | |
|---|---|
| **Time** | 30 minutes |
| **What it proves** | A version can be changed and reverted under live traffic, with no maintenance window |
| **What you'll need** | The cluster from lab 0, `rickroll` from lab 1, Fortio from lab 3, three terminal windows, a browser |

## Why this matters

You'll roll the "Pass" service out once, but you'll update it dozens of times. In the usual scheme, every update means arranging a window, a Saturday night, a snapshot before you start, and a person sitting there watching. When change costs that much, changes pile up: instead of ten small rollouts you do one big one, and the big one breaks more readily.

We'll work out what it costs here on the guinea pigs — that is, on the practice `rickroll`, not on "Pass". We'll swap the application's version **right in the middle of load** — not during a quiet hour, but amid thousands of requests a minute — and watch the error counter. Then we'll roll back, again under load.

## Little glossary

| Term | What it is | Like… but |
|---|---|---|
| **RollingUpdate** | Replacing copies one at a time, not all at once | **Updating VMs one by one by hand**, but the cluster does it itself and stops if a new copy fails to come up |
| **Revision** | A saved snapshot of the application's description | **A VM snapshot**, but it keeps only the description — there is no data inside it |
| **maxSurge** | How many copies beyond the requested number may be brought up during the rollout | no direct analogue; counted as a percentage of `replicas` and rounded up |
| **maxUnavailable** | How many copies may be shut down without waiting for a replacement | **How many VMs you shut down at once**, but rounded down, so with three copies it comes out to zero |
| **readinessProbe** | A "ready to take traffic" check | **A health check in the load balancer pool**, but it also holds the rollout back, rather than only pulling a member out of balancing |
| **ReplicaSet** | A set of identical copies responsible for one version of the description | **A pool of identical VMs from a template**, but each version gets its own set, and the previous one stays alongside with zero copies |
| **EndpointSlice** | A list of the addresses of copies ready to take traffic | **A list of load-balancer pool members**, but the cluster maintains it by labels, not the administrator by hand |
| **JSON Patch** | A pinpoint edit of a single field by its path inside an object | no direct analogue; the path points to the **index** of an element in a list, not its name |

## What's in the lab folder

You already have all the files — you got them together with the repository. There's nothing to create or retype: wherever you see `kubectl apply -f name.yaml` below, the file is taken from here.

```bash
# From here on, all commands are run from this folder: paths in `kubectl apply -f` are counted from it.
cd labs/04-rollout
```

| File | What it is | When it comes in handy |
|---|---|---|
| `rickroll-page-v2.yaml` | The second version of the page — what we roll out under load | you apply it on your `lab` cluster |
| `check.sh` | A check that the rollout went through without losing any requests | you run it at the end of the lab |
| — | The load generator we take from the neighboring lab: `../03-scale/fortio.yaml` | |

## Step 1. Preparing the ground

📍 **Where:** on the laptop.

Before the rollout you need to do two things, and neither is cosmetic.

**We turn off autoscaling**, because it too controls the `replicas` field. Watching a rollout while someone changes the number of copies at the same time is a guaranteed way not to understand what happened. One mechanism per field.

**We make three copies**, so the replacement is visible one at a time. A copy here is a Pod: the smallest unit of execution in the cluster, the application container together with its environment, the nearest analogue of a single VM. With one copy the rollout would also go through without downtime, but you'd see only "there was one Pod, now there's another" and wouldn't see the order in which the cluster replaces them.

```bash
# KUBECONFIG — the file with the cluster's address and the credentials to log into it. While the
# variable is set, every kubectl command goes to the `lab` cluster, not the one it was issued from.
export KUBECONFIG=~/lab.kubeconfig

# hpa — the autoscaler set up in the scaling lab. We delete it
# so the number of copies changes only on our command.
#   --ignore-not-found  don't treat it as an error if it's no longer in the cluster
kubectl delete hpa rickroll --ignore-not-found

# scale = "keep this many copies". The number goes into the application's description,
# and the cluster then brings up the missing ones itself.
kubectl scale deployment rickroll --replicas=3

# rollout status = "wait until the requested becomes actual". The command keeps the window
# busy until all three copies are ready, and only then returns the prompt.
kubectl rollout status deployment/rickroll
```

Check that the Fortio load generator is in place:

```bash
# get = "show what's there". The reply `Error from server (NotFound)` means it isn't there.
kubectl get deployment fortio
```

If it isn't there, bring it up from the neighboring folder: `kubectl apply -f ../03-scale/fortio.yaml`.

## Step 2. Putting the second version into the cluster

📍 **Where:** on the laptop.

The folder holds `rickroll-page-v2.yaml` — the description of an object of type ConfigMap. A ConfigMap keeps a text file in the cluster separately from the application, and the cluster then places that file inside the container. Here it holds the page that nginx serves.

<details>
<summary><b>A closer look: what's inside rickroll-page-v2.yaml</b></summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rickroll-page-v2
data:
  index.html: |
    ...
    <div class="tag">ВЕРСИЯ 2</div>
    <h1>We're No Strangers To Love</h1>
    ...
    <div class="pod">вас обслужил под<b>__POD__</b></div>
```

Inside is a single page: a different heading, a different color scheme, a conspicuous "ВЕРСИЯ 2" badge. The differences are made deliberately eye-catching — you'll be looking at the browser, not at a diff.

Note two things.

**`__POD__` is still there.** Substituting the copy's name is done by the nginx settings from the `rickroll-conf` ConfigMap, which is shared by both versions. We're changing the page, not the server's behavior.

**The object's name is `rickroll-page-v2`, not `rickroll-page`.** This is the key decision of the whole lab, and it's worth spelling out why.

The obvious move is a different one: take the existing `rickroll-page-v1` and rewrite its contents. One command, no new objects. Don't do it, and here's why.

First, you'd lose the old one. There'd be no rollback: the previous page no longer exists anywhere but in your file — and if you made the edit through `kubectl edit`, it isn't even in the file.

Second, the update would be uncontrolled. The application's description doesn't change when you edit a ConfigMap, which means the Deployment — the object that stores that description (which image, how many copies, where to get the files) and makes sure it's carried out — would notice nothing and start no rollout. The cluster would nonetheless swap the files inside the running Pods — on its own, in its own time, over about a minute, and in an arbitrary order across the copies. You'd get a change that isn't in the history, that can't be rolled back with a command, and that reached the copies out of sync.

Hence the rule: **versions are different objects, and switching a version is a change to the application's description.** That's exactly how the Deployment sees it, how it lands in the revision history, and how it can be undone.

</details>

Apply it. A second ConfigMap appears in the cluster; it won't touch the running application, because nothing references it yet:

```bash
# apply = "bring the cluster to what's described in the file".
#   -f name.yaml   where to take the description from; the file is in this same folder
kubectl apply -f rickroll-page-v2.yaml
```

**What you should see:** `configmap/rickroll-page-v2 created`.

Now open the application and make sure **nothing has changed**:

```bash
# port-forward = a temporary tunnel from the laptop into the cluster.
#   svc/rickroll  where it leads: into the Service, that is, with requests spread across the copies
#   8080:80       on the left the port on the laptop, on the right the service's port inside the cluster
# While the tunnel is open the window is busy; it closes on Ctrl+C.
kubectl port-forward svc/rickroll 8080:80
```

<http://localhost:8080> — the same first version. We put the new page into the cluster, but the application doesn't know about it: its volume still points at `rickroll-page-v1`. Close the tunnel (`Ctrl+C`), this isn't the rollout yet.

## Step 3. Understanding how the cluster will replace the copies

📍 **Where:** on the laptop.

Before switching the version, let's look at the rules the replacement will follow. They live in the application's description itself:

```bash
# -o jsonpath=... — instead of a table, print a single field of the object by giving the path to it.
#   {.spec.strategy}  the block of rules by which the cluster replaces copies
#   {"\n"}            a newline at the end, otherwise the output runs into the prompt
kubectl get deployment rickroll -o jsonpath='{.spec.strategy}{"\n"}'
```

```json
{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"},"type":"RollingUpdate"}
```

This block isn't in `rickroll.yaml` — the cluster filled in the default values.

<details>
<summary><b>What these percentages mean with our three copies</b></summary>

Both numbers are counted from `replicas`, that is, from three. And they round in opposite directions.

**`maxSurge: 25%`** — how many copies may be brought up **beyond** the requested number while the replacement is in progress. 25% of three is 0.75, and rounding **up** gives 1. So during the rollout the cluster may temporarily have four copies.

**`maxUnavailable: 25%`** — how many copies may be kept **unavailable** at the same time. 25% of three is the same 0.75, but rounding **down** gives **0**.

Zero is a hard constraint. The cluster is not allowed to shut down a single working copy until a ready replacement has appeared. Not "will try to" — is not allowed to: this is a constraint, not an intention.

Hence the order of operations at each replacement step:

1. bring up one new copy (allowed by `maxSurge`);
2. wait for its `readinessProbe` to answer with success;
3. add it to the EndpointSlice, that is, send traffic to it;
4. **only now** pull one old copy out of balancing and shut it down;
5. repeat until no old copies remain.

Everything hinges on the third and fourth points, and they hinge on the `readinessProbe`. Remove the readiness check from the manifest and the cluster will start treating a copy as usable the moment the process starts. Traffic will go to an nginx that hasn't yet read its config, and you'll get a batch of 500s. The readiness check here isn't monitoring, it's a **brake on the rollout**, and that's its main job.

A useful corollary: if the new version is broken badly enough that it doesn't pass the readiness check, the rollout will **stop**. The old copies keep working. We'll see this toward the end of the lab, only we'll break it a different way.

</details>

## Step 4. Turning on the load

Rolling out in silence is no fun — that's how it was done in vSphere too. Let's send traffic and change the version under it.

📍 **Window 1** — a tunnel to Fortio:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
# A tunnel to the load generator: port 8081 on the laptop → port 8080 of the fortio service.
# 8081 was chosen on the left so as not to collide with the tunnel to the application itself on 8080.
kubectl port-forward svc/fortio 8081:8080
```

📍 **In the browser** — <http://localhost:8081/fortio/>. Fill in:

| Field | Value | Why so |
|---|---|---|
| URL | `http://rickroll/` | the name of the Service — the stable address behind which all the copies stand; traffic will go through balancing, not to a specific Pod |
| QPS | `300` | a steady background; there's no need to squeeze out the maximum right now |
| Duration | `180s` | three minutes — the window within which we'll manage to both roll out and roll back |
| Connections | `20` | |

Press **Start** and **don't touch the browser until the end of the lab**.

The same load can be generated with a command, if the form didn't work out:

```bash
# exec = run a command inside an already-running Pod. The load is generated not by your laptop,
# but by Fortio itself from inside the cluster, so no tunnel is needed for this.
#   deploy/fortio  in any copy of the fortio application
#   --             everything to the right is a command for the container, not for kubectl
#   -qps 300       three hundred requests per second
#   -c 20          twenty simultaneous connections
#   -t 180s        hold the load for three minutes
kubectl exec deploy/fortio -- fortio load -qps 300 -c 20 -t 180s http://rickroll/
```

📍 **Window 2** — watching the copies:

```bash
export KUBECONFIG=~/lab.kubeconfig
# -l app=rickroll — show only Pods with this label; others won't get into the output.
# -w = "watch and append": the window stays busy and prints a new line every time
# the state of some copy changes. Exit — Ctrl+C.
kubectl get pods -l app=rickroll -w
```

## Step 5. Switching the version

📍 **Window 3** — a free window. The first holds the tunnel to Fortio, the second is busy watching the Pods, so we run the patch in the third. Access has to be set up in it again:

```bash
# A new terminal window doesn't remember the previous one's variables — we set KUBECONFIG again.
export KUBECONFIG=~/lab.kubeconfig
```

Now we'll change exactly one field in the application's description: the volume named `page` — the folder that gets placed inside the container — must take its contents from the ConfigMap `rickroll-page-v2`. There is no "update the application" command, and there never will be: there is only a new record of how things should be. The cluster will notice the discrepancy with the actual state itself and start replacing the copies.

```bash
# patch = change a field in an object pinpoint-style, without rewriting the whole object.
#   --type=json  the edit format: "operation + path + value"
#   op: replace  replace what sits at this path
#   path         the address of the field inside the object; volumes/0 — the first volume in the list (see below)
#   value        the new ConfigMap name from which the volume will take the page
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v2"}]'
```

**What you should see:**

```
deployment.apps/rickroll patched
```

⚠️ **This patch is fragile, and that needs to be said outright.** The path `/spec/template/spec/volumes/0/...` addresses the volume **by its index in the list**. In `rickroll.yaml` the `page` volume comes first and `conf` second — there's even a comment about it there. But if someone swaps them (and YAML doesn't forbid it in any way), the very same command will, without a single error, overwrite the name of the nginx config, and the application will break in a baffling way.

<details>
<summary><b>Why we do it this way anyway, and how to do it right</b></summary>

We took JSON Patch because it shows the mechanics in their pure form: one command, one field, a visible consequence. For a lab that's valuable.

**Safer** — the same thing with an ordinary merge patch. Lists in Kubernetes can merge by a key, and for `volumes` that key is `name`:

```bash
# Without --type=json this is a merge patch: you describe a piece of the object in the same form
# it has in the manifest, and the cluster merges it with what's already there. The volumes list merges
# by the `name` key, so here the `page` volume is addressed, not "the volume at such-and-such index".
kubectl patch deployment rickroll -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"page","configMap":{"name":"rickroll-page-v2"}}]}}}}'
```

Here the addressing is by the volume's name, the order in the list doesn't matter, and there's nothing to mix up.

**Right** — don't patch at all. A patch, like `kubectl edit`, changes the object in the cluster but doesn't change your file. A week later someone applies `rickroll.yaml` from the repository, and the application silently drifts back to the first version. Nobody will understand why.

In normal work the version is changed like this: you edit a line in the file, send the change for review, and after the merge automation applies it. Then the cluster's state and the repository's contents always match. That's exactly what we'll do in lab 5.

</details>

Watch the replacement go:

```bash
# rollout status prints the progress of the replacement line by line and finishes when all copies are updated.
# If the rollout doesn't converge, the command returns a non-zero exit code — convenient for
# stopping it in scripts.
kubectl rollout status deployment/rickroll
```

```
Waiting for deployment "rickroll" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "rickroll" rollout to finish: 2 out of 3 new replicas have been updated...
deployment "rickroll" successfully rolled out
```

📍 **In window 2** you can meanwhile see the copies being replaced one at a time: first a new one appears and reaches `1/1 Running`, and only after that does one of the old ones go into `Terminating`.

Note the tail of the names: the new copies have a changed middle part too — that's a different ReplicaSet. The Deployment didn't rework the old one, it created a second one alongside and pours copies from one into the other. The old one hasn't gone anywhere; it has zero copies and it's waiting in the wings:

```bash
# rs — shorthand for ReplicaSet, a set of copies of one version of the description.
# DESIRED — how many copies are requested in this set, READY — how many of them are ready to answer.
kubectl get rs -l app=rickroll
```

```
NAME                  DESIRED   CURRENT   READY   AGE
rickroll-6f4b9c8d57   0         0         0       48m
rickroll-7c5d4f9b21   3         3         3       40s
```

## Step 6. Counting the errors

📍 **Where:** on the laptop, in window 3 — it freed up after the previous command.

Open a tunnel to the application:

```bash
# The same tunnel as at the start of the lab: port 8080 on the laptop → port 80 of the rickroll service.
kubectl port-forward svc/rickroll 8080:80
```

📍 **In the browser** <http://localhost:8080> — the green page with the "ВЕРСИЯ 2" badge. Refresh it a few times: the copy's name at the bottom changes, because the Service distributes the requests across the three copies.

Close the tunnel (`Ctrl+C`).

📍 **Now the main thing — the Fortio tab.** Wait for the run to finish and find the lines with the response codes:

```
Code 200 : 54000 (100.0 %)
All done 54000 calls (plus 0 warmup) 0.412 ms avg, 300.0 qps
```

**Zero errors.** The application changed its version entirely, under continuous traffic, and not one of the fifty-four thousand requests was harmed.

We paid for this with a single block in the manifest — that same `readinessProbe` from lab 1. Without it the cluster would have pulled the old copy out of balancing before making sure the new one was ready to answer, and this line would have looked different.

⚠️ **A few dozen errors out of tens of thousands of requests instead of zero** is not a broken testbed. Removing a copy from balancing and stopping the process inside it happen in parallel, and under fast traffic a handful of connections manage to slip into that gap. This is cured by a pause before shutdown (`preStop`) and graceful connection draining in the application itself. We deliberately don't do this in the lab: it's more useful to know the gap exists than to assume it closes by itself.

## Step 7. Rolling back

Start the load in Fortio again (the same parameters) and, while it runs, look at the change history:

```bash
# history = the list of saved revisions of the description. Each line is a state you can
# return to with a single command. CHANGE-CAUSE — an optional note on why it was changed.
kubectl rollout history deployment/rickroll
```

```
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

Two revisions. Each is a saved snapshot of the application's description at the moment of the change. The first with `rickroll-page-v1`, the second with `v2`. They're kept precisely because the old ReplicaSets aren't deleted: by default the cluster keeps the ten most recent.

The rollback:

```bash
# undo with no extra parameters = return to the previous revision. This isn't "rewinding
# time", it's an ordinary rollout of the old description: copies are replaced one at a time, by the same
# maxSurge and maxUnavailable rules.
kubectl rollout undo deployment/rickroll
# We wait until the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

📍 **In window 2** — the same procedure in reverse: three new copies come up one at a time, three current ones leave. `kubectl get rs -l app=rickroll` will show that the copies returned to the first ReplicaSet — the one that was hanging there with zero.

📍 **In the browser** the application is the first version again.

📍 **In Fortio** — again `Code 200 ... (100.0 %)`.

**Compare this with a rollback in vSphere.** There a rollback means restoring from a snapshot: the machine shuts down, the files are put back, the machine boots. Minutes of unavailability plus the loss of everything that happened after the snapshot was taken. Here a rollback means returning the description to the previous revision, and it's no different from an ordinary rollout: the same copies one at a time, the same zero downtime.

⚠️ **`CHANGE-CAUSE` is empty, and that's inconvenient.** The history keeps *what* changed but not *why*. A month from now revision 2 will tell you nothing. You can fill in the cause with the `kubernetes.io/change-cause` annotation, but the real answer to this question isn't an annotation, it's Git, where every change has an author, a date, and a commit message.

## Step 8. A check that won't pass

The mechanism is clear. Now let's look at what happens when a rollout goes wrong — and that happens more often than one would like.

Picture an ordinary morning: a colleague is preparing the third version of the page, is in a hurry, and makes a typo in the name. The manifest is valid, though — the cluster isn't obliged to know that no such object exists. Let's reproduce exactly this:

```bash
# The same patch as when switching to the second version, but with a mistake in the ConfigMap name:
# there is no object `rickroll-page-v3` in the cluster. The reference's existence isn't checked on acceptance,
# so the command will finish successfully.
kubectl patch deployment rickroll --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/configMap/name","value":"rickroll-page-v3"}]'

# --timeout=90s — don't wait forever: not having gotten ready copies, the command gives up after a
# minute and a half and returns an error. The rollout itself won't go anywhere and will stay hanging.
kubectl rollout status deployment/rickroll --timeout=90s
```

**What you'll see:**

```
Waiting for deployment "rickroll" rollout to finish: 0 of 3 updated replicas are available...
error: timed out waiting for the condition
```

Look at the makeup of the copies: three previous ones are working, the new one is stuck at startup.

```bash
# The READY column counts the ready containers inside the Pod: 1/1 — ready, 0/1 — not.
# STATUS says exactly where the startup stalled.
kubectl get pods -l app=rickroll
```

```
NAME                        READY   STATUS              RESTARTS   AGE
rickroll-6f4b9c8d57-4kk2p   1/1     Running             0          6m
rickroll-6f4b9c8d57-9dnvt   1/1     Running             0          6m
rickroll-6f4b9c8d57-lm7bq   1/1     Running             0          6m
rickroll-8b6a1e5c39-wr4tz   0/1     ContainerCreating   0          90s
```

> **Stop and think before reading on.**
>
> There are two questions here, and the second matters more than the first. First: why isn't the new copy starting? Second: what's happening to the service right now — is it down?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

**Why the copy didn't come up.** We never created a ConfigMap named `rickroll-page-v3` — it isn't in the cluster. Ask the cluster directly:

```bash
# events — the cluster's log of occurrences, the nearest analogue of the Tasks & Events tab in vCenter.
#   --field-selector reason=FailedMount  keep only the records about a failed volume mount
#   --sort-by=.lastTimestamp             sort by time, the freshest end up at the bottom
#   | tail -3                            show the last three lines, discard the rest
kubectl get events --field-selector reason=FailedMount --sort-by=.lastTimestamp | tail -3
```

```
Warning  FailedMount  kubelet  MountVolume.SetUp failed for volume "page":
         configmap "rickroll-page-v3" not found
```

Notice: the `kubectl patch` command finished successfully and printed `patched`. The cluster accepted a description in which the reference leads nowhere, and said not a word. There's no check that the ConfigMap exists when the manifest is accepted — it would only be possible at the moment the Pod starts, which is exactly what happened.

**And now the second question, the one this step was made for.** Open the application right in the middle of the stuck rollout:

```bash
# The same tunnel. Traffic will go only to the copies that passed the readiness check,
# that is, to the three old ones: the stuck one didn't make it into balancing.
kubectl port-forward svc/rickroll 8080:80
```

It works. The first version, three copies, no errors. If you had load running in Fortio at that moment — the report still shows a hundred percent 200s.

**A completely broken rollout didn't bring the service down.** This is a direct consequence of `maxUnavailable: 0`, which we worked out at the start of the lab: the cluster wasn't allowed to shut down a single working copy until it got a ready replacement. It didn't get a replacement — so it didn't shut anything down either. The rollout stopped exactly where it started to break, and stayed in that state.

**The lesson is broader than this error.**

> A failed rollout in Kubernetes by default **gets stuck**, it doesn't collapse.

This flips the familiar logic of updating on its head. In the "stop, update, start" scheme any error in the middle means downtime, and that's why updates are done at night, with people on the phone. In the "bring up the new, make sure, switch over" scheme an error means the switch didn't happen — and the old thing goes on working just as it did.

Hence the practical takeaway for whoever's on call: **a stuck rollout is not an incident.** It won't wake you at night. It can be sorted out in the morning — or rolled back with a single command and sorted out later.

That's exactly what we'll do now.

</details>

Getting out:

```bash
# We return the previous revision — the one where the ConfigMap name is written correctly.
kubectl rollout undo deployment/rickroll
# We wait until the stuck copy disappears and the makeup of the copies converges with the description.
kubectl rollout status deployment/rickroll
```

The stuck copy disappears, and the description returns to the working one.

## Verification

📍 **Where:** on the laptop, in the same terminal window where you worked with `kubectl`.

```bash
# The script changes nothing in the cluster: it only reads the state and prints a report.
./check.sh
```

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to install it is written at the start of lab 0. Without WSL you can complete the lab, but there won't be an artifact report.

The script looks at the substance of the matter, not at the commands you typed: the application's history has several revisions (meaning the version really was changed and reverted), the second version's ConfigMap is in the cluster, the application answers over HTTP, and the page it serves matches the ConfigMap that the description points at. Separately it checks the `readinessProbe` — without it the zero downtime can't be reproduced.

## Cleanup

The `rickroll` application will be needed later — we don't delete it. Return it to one copy:

```bash
# Two extra copies will free up the node's memory — there won't be any load in the labs ahead.
kubectl scale deployment rickroll --replicas=1
```

The load generator is no longer needed:

```bash
# delete -f = delete exactly the objects listed in the file, and nothing besides them.
# The path leads to the neighboring folder, because the file is where the scaling lab is.
kubectl delete -f ../03-scale/fortio.yaml
```

The `rickroll-page-v2` ConfigMap can be left as is: it takes up a couple of kilobytes and consumes neither CPU nor memory. Descriptions in Kubernetes are stored in the control plane's database and cost nothing while nothing references them — unlike a virtual machine snapshot, which takes up space on storage and slows the machine down the more the longer it lives.

## What we can do now

- Change an application's version under live traffic and confirm by the counter that there were no errors
- Explain where the zero downtime comes from: `maxUnavailable`, `readinessProbe`, and the "ready first, then switch over" order
- Read the revision history and roll back with a single command
- Understand why versions are made as separate objects, not by editing an existing one
- Know that a broken rollout gets stuck rather than taking down the service, and why that's not an incident

## And in vSphere this would be

A maintenance window, agreed in advance. A snapshot before you start — minutes and storage space. An in-place update. If it didn't take off — a restore from the snapshot, more minutes of unavailability. All of it at night, because you can't do it during the day.

Here — one command during the day, under traffic, and a second command if you don't like the result.

**Where vSphere is more convenient, honestly.** Three things.

First and foremost: **a snapshot takes the whole state, while `rollout undo` takes only the description.** If, during the time the new version was working, your application managed to write something to the database or change the schema, the rollback returns the code and doesn't return the data. You'll get the old version on top of new data — sometimes that's worse than leaving things as they were. A VM snapshot saves you from this, `rollout undo` doesn't. It's for exactly this reason that database schema migrations are written to be compatible both ways, and that's a discipline Kubernetes will demand of you where vSphere didn't.

Second, a rollback in vSphere returns absolutely everything: packages installed by hand, an edit made to a config over the phone. Here only what was described in the manifest is rolled back. Anything someone did on the side won't be rolled back, because the cluster doesn't know about it.

Third, a snapshot doesn't require the application to be able to run in two versions at once. But `RollingUpdate` does: during the rollout old and new copies serve requests together, behind one address. If they're incompatible with each other — in session format, in data schema, in protocol — there'll be no zero downtime, there'll be a mess. For applications that aren't ready for this, there's the `Recreate` strategy: shut them all down, then bring them all up. It gives downtime, but it's predictable, and sometimes it's more honest to choose it.
