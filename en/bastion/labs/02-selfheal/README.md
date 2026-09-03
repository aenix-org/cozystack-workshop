# Lab 2 · Self-healing: kill a copy and see what happens

| | |
|---|---|
| **Time** | 25 minutes |
| **What it proves** | A copy comes back on its own within seconds, but that alone is not fault tolerance |
| **What you'll need** | The cluster from lab 0, `rickroll` from lab 1, `kubectl`, two terminal windows |

## Why this matters

Soon you'll be on the hook for the "Gate Pass" service: security looks at the guest list at seven
in the morning, and "we're rebooting, hold on" doesn't fly there. Before you take on a promise like
that, it's worth finding out — where nothing's at stake — exactly what the cluster does on its own and what you'll have to do yourself.

Let's take on Kubernetes's loudest promise — self-healing. We'll delete a running copy of the
application and time, by the clock, how long it stays gone. Then we'll delete something else —
and see that the copy does not come back. The difference between these two cases is what this lab is about.

## Mini-glossary

| Term | What it is | Like… but |
|---|---|---|
| **Desired state** | A record in the cluster saying "it should look like this" | **Cluster settings in vCenter**, but the cluster doesn't apply it once — it endlessly brings reality into line with it |
| **Controller** | A process in the cluster's control plane that checks "as ordered" against "as is" | **vSphere HA**, but it runs constantly and across all objects, rather than waking up when a host fails |
| **ReplicaSet** | An object that makes sure there are exactly as many copies as were ordered | **A "keep N instances" rule**, but it doesn't repair what's broken — it creates a new one to replace what disappeared |
| **ownerReferences** | A mark inside an object: "this one created me" | it's what makes deleting a parent automatically take all its children with it |
| **Termination** | The pause between "delete" and "process killed" | **Guest Shutdown instead of Power Off**, but 30 seconds by default, after which it's killed hard |
| **EndpointSlice** | A list of the live addresses behind a Service | **A pool's member list on a load balancer**, but it's built automatically from labels and readiness — you don't write into it by hand |

## What's in the lab folder

You already have all the files — you got them along with the repository. There's nothing to create
or type out again: wherever it says `kubectl apply -f name.yaml` below, the file is taken from here.

```bash
# All the lab's commands are run from this folder — otherwise the relative paths in them won't line up.
cd labs/02-selfheal
```

| File | What it is | When it's useful |
|---|---|---|
| `check.sh` | Checks that the cluster restored the deleted copies by itself | you run it at the end of the lab |
| — | The lab has no manifests of its own: we work with the application from lab 1, and the file is taken from there — `../01-deploy/rickroll.yaml` | |

## Step 1. Look at what we have

📍 **Where:** on the bastion (in the bastion terminal).

The `rickroll` application is already running. Before we break anything, let's look at what objects
it's made of: with a single command we ask the cluster about three kinds of entity at once.

```bash
# KUBECONFIG — the path to the file with the cluster's address and your login credentials.
# Until the variable is set, kubectl looks for a cluster on the bastion itself and doesn't find one.
export KUBECONFIG=~/lab.kubeconfig

# get = "show me what's there". Three kinds of object are listed at once, separated by commas.
#   -l app=rickroll   show only those labelled app=rickroll — that is, our
#                     application, not the entire contents of the cluster
kubectl get deployment,replicaset,pods -l app=rickroll
```

**What you should see** — one line for each of the three objects:

```
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/rickroll   1/1     1            1           14m

NAME                                  DESIRED   CURRENT   READY   AGE
replicaset.apps/rickroll-6f4b9c8d57   1         1         1       14m

NAME                             READY   STATUS    AGE
pod/rickroll-6f4b9c8d57-xk2mp    1/1     Running   14m
```

⚠️ **There may be more than one `replicaset` line.** Each rollout of a new version leaves the
previous set in the history — with zeros in the columns. The live one is where the ones are; the
rest stick around so there's somewhere to roll back to.

There are three objects, even though in the lab 1 manifest you described a single Deployment. The
cluster created the other two itself, and this isn't a cosmetic detail — everything that follows depends on this chain.

<details>
<summary><b>Unpacking the chain: who created whom, and why</b></summary>

Look at the names. A Pod's name is the ReplicaSet's name plus five random characters, and the
ReplicaSet's name is the Deployment's name plus a hash. That's how the chain is built.

**Deployment** holds your intent in full: which image, how many copies, how to update. It doesn't
watch the Pods directly — it watches the ReplicaSet.

**ReplicaSet** holds a single thought: "there should be exactly this many Pods with the label
`app=rickroll`". That's all. It knows nothing about images or versions.

**A Pod** is a running copy.

You can confirm this isn't guesswork like so:

```bash
# The default kubectl table doesn't show the ownerReferences field — you have to ask for it explicitly.
#   -o jsonpath=...   "pull these fields out of the server's response and print them like this"
# Inside the expression: range .items[*] — walk through every Pod found, .metadata.name —
# the Pod's name, ownerReferences[0].kind and .name — the kind and name of whatever created it.
kubectl get pods -l app=rickroll -o jsonpath='{range .items[*]}{.metadata.name}{"  <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}'
```

Output:

```
rickroll-6f4b9c8d57-xk2mp  <- ReplicaSet/rickroll-6f4b9c8d57
```

The `ownerReferences` field is the record "this object created me". The ReplicaSet has the same
record, only there it points to the Deployment.

Why three tiers instead of one object: the tiers are responsible for different things. When we roll
out a new version in lab 4, the Deployment will create a **second** ReplicaSet for the new version and
start moving copies from the old set to the new one, one at a time. The old ReplicaSet won't go
anywhere in the meantime — it's precisely what lets you roll back with a single command.

A side fact worth remembering: deleting a parent takes its children with it. Delete the ReplicaSet
by hand — the Deployment creates a new one within a second. Delete the Deployment — everything
disappears. We'll test the second case at the end of the lab.

</details>

## Step 2. Kill a copy and time it

Now we'll delete a Pod. Not power it off, not reboot it — delete it entirely, as if someone had
clicked Delete from Disk on a virtual machine.

**What's about to happen:** the command below will remember the current copy's name, delete it, and
then once a second ask the cluster whether a copy with a **different** name has appeared in the
Running state. As soon as one does, it prints how long that took.

```bash
# items[0].metadata.name — the name of the first Pod in the list. We save it in the POD variable:
# without that we won't be able to tell the old copy from the new one later.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')
echo "killing: $POD"

# date +%s — the current time in seconds. This is our stopwatch: we note it before the delete,
# and subtract it from a fresh reading right at the end.
START=$(date +%s)

# delete pod — delete the copy for good.
#   --wait=false   don't wait for the Pod to fully disappear, return control immediately:
#                  we need to start counting seconds from this moment, not afterwards
kubectl delete pod "$POD" --wait=false

# Once a second we re-read the Pod list and look for a line where all of these hold at once:
#   $1!=old        the name doesn't match the old one — so this is a different copy
#   $2=="1/1"      one container out of one is ready
#   $3=="Running"  the pod is running
#   --no-headers   don't print the table header, so awk sees only data
#   2>/dev/null    hide error messages during the seconds when there are no Pods at all
while true; do
  NEW=$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null \
        | awk -v old="$POD" '$1!=old && $2=="1/1" && $3=="Running" {print $1; exit}')
  [ -n "$NEW" ] && break
  sleep 1
done
echo "new copy $NEW ready in $(( $(date +%s) - START ))s"
```

**What you should see:**

```
killing: rickroll-6f4b9c8d57-xk2mp
pod "rickroll-6f4b9c8d57-xk2mp" deleted
new copy rickroll-6f4b9c8d57-p9wqt ready in 4s
```

Four seconds. On the testbed the spread is two to fifteen, depending on how busy the node is.
The image is already on the node, there's nothing to download, so it all comes down to starting the
process and the readiness check.

**Notice the name.** The tail changed: `xk2mp` became `p9wqt`. This isn't the same Pod restarted —
it's a different Pod. The old one is nowhere anymore; you can't repair it, restore it from a recycle
bin, or look at what was on its disk.

Nobody "restored" anything. Several times a second the ReplicaSet checks "ordered: 1" against
"have: 0" and, on a mismatch, creates what's missing. The copy vanished — a mismatch appeared —
a copy was created. The same mechanism would have fired if the Pod had been evicted from the node
for a more important workload, if the node itself had gone down, or if the application inside the Pod
had died from running out of memory.

## Step 3. Check whether there was fault tolerance

The copy came back in four seconds. Does that mean the service wasn't interrupted?

Let's check. We'll need **two terminal windows**.

📍 **Window 1** — inside the cluster we start a tiny Pod that pokes our application through the Service
once a second and draws a dot on success, an `X` on error:

```bash
export KUBECONFIG=~/lab.kubeconfig

# run = create a single Pod straight from the command line, without a manifest.
#   --rm             delete the Pod as soon as you interrupt the command
#   -it              the Pod's output comes to your screen, Ctrl+C stops it
#   --restart=Never  there's a single copy and no need to recreate it: this is a tool, not a service
#   --image          busybox — an image a few megabytes in size that has wget
# Everything after -- runs inside the Pod. The address http://rickroll is the name of the Service;
# inside the cluster it turns into the application's address on its own.
#   -q               don't print download statistics
#   -T 2             wait no longer than two seconds for a reply, otherwise we count it as a failure
#   -O /dev/null     throw the response body away, all we care about is the fact of a reply
kubectl run pinger --rm -it --restart=Never --image=busybox:1.36 -- \
  sh -c 'while true; do wget -q -T 2 -O /dev/null http://rickroll/healthz \
         && echo "$(date +%T) ." || echo "$(date +%T) X"; sleep 1; done'
```

Each line carries a timestamp: this way you'll see not just the failure itself but **how many seconds**
it lasted — and that's the number this whole lab is after.

⚠️ **You need a second terminal, not a background run.** The point of the exercise is to see the
failure **at the moment** you delete the copy in the other window: the line with the cross should
appear before your eyes. You can read it afterwards in `kubectl logs`, but then the main thing is
lost — the link between your action and its consequence.

Why from inside the cluster and not from the bastion: `port-forward` latches onto a specific Pod and
dies together with it, so it would show a failure either way — even where there isn't one. Whereas
`wget` from a neighbouring Pod goes through the Service, that is, exactly the way a real client would.

Wait until the dots start running.

📍 **Window 2** — kill the copy:

```bash
export KUBECONFIG=~/lab.kubeconfig

# No pod name is given, a label instead: delete every copy with the label app=rickroll.
# Right now there's only one, so the one the pinger is polling is exactly the one that goes.
kubectl delete pod -l app=rickroll
```

📍 **Look at window 1.** You'll see something like this:

```
.........XXXXX.........
```

For a few seconds the service answered with an error — we got five, on a busy node it can be
fifteen. The copy came back quickly, but while it was gone there was no one to answer.

**Here's the honest way to put what we observed.** Self-healing is not fault tolerance. Self-healing
brings the system back to normal without a human. Fault tolerance means the client noticed nothing
at all. One copy gives you the first and not the second.

Don't stop the pinger, you'll need it right away.

## Step 4. Do the same thing, but with three copies

📍 **Window 2.** We order three copies instead of one and wait until all three are ready.

```bash
# scale changes exactly one field in the application's record — the number of copies.
kubectl scale deployment rickroll --replicas=3

# rollout status holds the terminal and prints progress until all the copies you asked for
# are ready. The command finishes on its own — no need to poll get pods by hand.
kubectl rollout status deployment/rickroll
```

We changed exactly one number in the desired state. From there the same ReplicaSet does everything:
it sees "ordered 3, have 1" and creates the two missing copies. This takes the same seconds as before.

Make sure there are now three copies and that they all landed behind the Service:

```bash
# EndpointSlice — that very list of live addresses the Service keeps for you.
#   -l kubernetes.io/service-name=rickroll   take the list belonging to the Service rickroll
#   -o jsonpath=...                          from each entry print only the address itself,
#                                            one per line
kubectl get endpointslices -l kubernetes.io/service-name=rickroll \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}'
```

Three addresses. Nobody entered them there — the Service assembled the list itself, from the label
`app=rickroll` and the readiness of each copy. This is exactly the difference from a load-balancer
pool that lab 1 talked about: there you enter the addresses, here you describe a condition.

Now we kill one of the three copies:

```bash
# We take the name of the first of the three copies — which one exactly doesn't matter.
POD=$(kubectl get pods -l app=rickroll -o jsonpath='{.items[0].metadata.name}')

# And delete it. No --wait=false here: the command returns once the Pod is already gone.
kubectl delete pod "$POD"
```

📍 **Look at window 1:**

```
...........................
```

Not a single `X`. The copy was killed, it was recreated, the client didn't notice.

The difference between the one-copy test and the three-copy test is a single number in the manifest. **Fault tolerance here isn't a
feature you switch on — it's a consequence of there being more than one copy.** That's exactly why in
Kubernetes there's no "enable HA" checkbox: there's nothing to enable, there's only `replicas`.

Stop the pinger in window 1 by pressing `Ctrl+C`. If the Pod is left hanging, remove it:
`kubectl delete pod pinger`.

## Step 5. A test that won't pass

The mechanism is clear: delete a copy, it comes back. Let's test it once more, but this time delete
not a copy but the application itself:

```bash
# We delete not a copy but the application's record itself. There will be no confirmation,
# the object won't go to any recycle bin — there'll be nowhere to restore it from but the file.
kubectl delete deployment rickroll
```

We wait a few seconds and look at whether the copies came back:

```bash
# We look for pods by the application's label. An empty response here is an answer too.
kubectl get pods -l app=rickroll
```

**What you'll see:**

```
No resources found in default namespace.
```

The copies did not come back. Not after five seconds, not after a minute.

> **Stop and think before reading on.**
>
> Why did the copy reappear earlier when you killed it, but not now? We didn't turn anything off.

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

Earlier you were deleting a **copy** — that is, a fact. The record "there should be three copies"
stayed in place, reality diverged from it, and the controller eliminated the divergence.

This time you deleted the **record itself**. There's nothing left to diverge from: the desired state
is "this application does not exist", the actual state is "this application does not exist". They
match, and the controller has nothing to do. Along the way, following the `ownerReferences` chain,
the ReplicaSet and all three Pods left together with the Deployment.

**A lesson broader than this error.** The rule worth carrying away from the lab whole:

> Kubernetes protects you from losing a **fact**, but does nothing to protect you from losing **intent**.

All of self-healing works exactly as long as the record of how things should be is intact. If the
record is changed or deleted, the cluster will diligently and very quickly bring reality into line
with the new desired state, whatever it may be. It won't ask "are you sure?" and won't leave a recycle bin.

There are two practical consequences, and both are unpleasant exactly once.

**First: deletion here is quieter than in vSphere.** Tearing down a Deployment is one line — no
confirmation, no "Delete from Disk?" with a red icon. You can't restore it from the cluster: a
deleted object is stored nowhere.

**Second: the only real protection is to keep intent outside the cluster.** If the manifest lives in
Git and automation brings it into the cluster, then an accidental deletion is cured by the automation
returning the object from the repository a minute later. That's GitOps, and we'll turn it on in lab 5.
For now, your `rickroll.yaml` is the only copy of the intent. It's a good thing it's in a file: you
can review it, put it in Git, and apply it again.

Incidentally, the middle link is worth testing separately and behaves differently. Restore the
application (the next step), then try deleting the ReplicaSet rather than the Deployment:

```bash
# rs — short for replicaset; kubectl understands both spellings.
# We delete the middle link, leaving the Deployment in place.
kubectl delete rs -l app=rickroll

# And immediately look at what's left: compare the set's name with what it was before the delete.
kubectl get rs -l app=rickroll
```

The set reappears within a second — and **with the same name**. The hash in the name is computed from
the Pod template, and we didn't touch the template: the same name means the cluster restored exactly
the same thing rather than creating something new. The record "there should be this application"
stayed intact — the Deployment is responsible for it, and it survived the set's deletion.

</details>

## Step 6. Bring the application back

You have the intent, it's in a file. Restoring it is a single command:

```bash
# apply = "bring the cluster to what's described in the file". The object doesn't exist — it will be created.
#   -f ../01-deploy/rickroll.yaml   the file lives in the lab 1 folder, hence the path via ../
kubectl apply -f ../01-deploy/rickroll.yaml

# We wait for the copy to come up and become ready to take requests.
kubectl rollout status deployment/rickroll
```

Notice what there **wasn't** here: no backup, no snapshot, no export from vCenter. You restored the
application from a ten-kilobyte text file, and what you got was literally the same as before. With a
virtual machine this trick doesn't work: its description and its contents are inseparable.

## Verification

📍 **Where:** on the bastion, in the same terminal window where you were working with `kubectl`.

The script checks not that you ran the commands but what's left in the cluster: the application is
serving requests through the Service again, it inserts the name of its copy into the page, and that
name belongs to a genuinely running Pod. Separately it looks for traces of copies being recreated —
from the age of the Pods and from the cluster's events.

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to install it is written at
the start of lab 0. You can complete the lab without WSL, but there'll be no artefact report.

```bash
# ./ means "a file from the current folder", not a command from the system PATH.
# The script changes nothing in the cluster: it only reads and prints a report.
./check.sh
```

## Cleanup

The `rickroll` application is needed in labs 3 and 4 — we don't delete it.

There's nothing to clean up here, and that's worth noting in its own right. You restored the
application from the file, and the file orders one copy — the cluster shut the extra two down itself,
back on the previous step, without asking and without waiting for your command. To confirm:

```bash
# The READY column should read 1/1.
kubectl get deployment rickroll
```

The node's resources were freed the moment the containers ended. There's no "defragmentation" or
scheduled reclaiming of space here: a container finished — its memory and CPU time are immediately
available to its neighbours.

## What we can do now

- Explain the Deployment → ReplicaSet → Pod chain and understand why it has three tiers
- Tell self-healing (the copy came back) from fault tolerance (the client didn't notice)
- Change the number of copies with a single number and watch the Service pick them up on its own
- Understand that the cluster protects a fact but not intent, and where intent belongs

## And in vSphere this would be

vSphere HA restarts a VM after a host failure: first the cluster has to make sure the host really is
lost (that's tens of seconds), then the machine boots from scratch — kernel, services, application.
Minutes. VM Monitoring based on lost heartbeats works the same way and on the same time scale.

Here it's seconds, and not only on a host failure: the same mechanism fires when a copy is evicted,
when OOM kills it, when you delete it yourself.

**Where vSphere is more convenient, honestly.** Three things.

First, vSphere HA brings back **the very same machine** with everything that was on its disk. A Pod
comes back empty: anything that wasn't on a persistent volume is lost for good. For a stateless
application that's a plus; for a legacy service that spent years writing something into its own
`/var`, it's a source of very nasty surprises.

Second, vSphere has Fault Tolerance: two machines in lock-step and zero downtime on a host failure,
with no reworking of the application at all. There's no direct analogue in Kubernetes, and there
can't be — here zero downtime is achieved by having several copies, which means the application must
be able to run in several copies. If it can't, Kubernetes won't solve that problem for you — it'll expose it.

Third, the post-mortem. In vCenter the reason a machine restarted is visible as a single entry in the
cluster's events, and it stays there. In Kubernetes events live for about an hour and then disappear,
and you'll have to reconstruct the picture from the logs of several components. Until you've set up
log and event collection (lab 14), "why did it restart overnight" is a question with no answer.
