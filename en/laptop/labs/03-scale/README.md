# Lab 3 · Load and autoscaling

| | |
|---|---|
| **Time** | 30 minutes |
| **What it proves** | The number of replicas can be set by load, not by a service-desk ticket |
| **What you'll need** | The cluster from lab 0, `rickroll` from lab 1, three terminal windows, a browser |

## Why this matters

The "Access Pass" service, the whole reason for this exercise, will behave unevenly. At eight in the morning security and half the office open it at once; at three in the afternoon nobody touches it. Sizing capacity for the peak means heating the air nine hours a day, and sizing it for the average means a queue at the gate.

Let's try the third option on for size: the number of replicas is set not by a person, but by the load itself. We'll give the application real traffic and watch it grow to six replicas, then shrink back to one.

Along the way we'll sort out the thing people trip over most often here — the difference between "how much we ask for" and "how much we allow."

## Mini-glossary

| Term | What it is | Like… but |
|---|---|---|
| **HPA** | An object that changes the replica count based on a metric | **DRS plus adding VMs by hand**, but it changes the number of instances rather than spreading them across hosts |
| **metrics-server** | A service that collects the current consumption of Pods | **vCenter statistics collection**, but it keeps only the last few minutes — no history at all |
| **requests** | How much of a resource we reserve as guaranteed | **Reservation**, but utilization percentage is computed from it, and it's also what decides where a Pod fits |
| **limits** | The ceiling a Pod cannot rise above | **Limit**, but at the ceiling the CPU is throttled while memory kills the Pod |
| **Utilization** | Consumption as a percentage of `requests` | **"CPU Usage %" on the graph**, but it can be 600% and that's not a mistake |
| **Fortio** | A load generator with a web interface | **HCIBench**, but it lives inside the cluster as an ordinary application |

## What's in the lab folder

You already have all the files — you got them together with the repository. There's nothing to create or retype: wherever you see `kubectl apply -f name.yaml` below, the file comes from here.

```bash
# Every command in this lab is run from this folder — otherwise the file names in them won't be found.
cd labs/03-scale
```

| File | What it is | When it's useful |
|---|---|---|
| `hpa.yaml` | The autoscaling rule: grow replicas based on CPU load | you apply it on your own `lab` cluster |
| `fortio.yaml` | A load generator with a web interface — this is what drives the load | you apply it to the same place |
| `check.sh` | Verifies that replicas grew under load and shrank afterward | you run it at the end of the lab |

## Step 1. Confirm we start with a single replica

📍 **Where:** on the laptop.

The whole lab rests on the replica count growing noticeably. So we have to start from one — otherwise there's nothing to compare the growth against. Let's see how many replicas are running right now.

```bash
# KUBECONFIG is the path to the file with the cluster's address and login details.
# Until the variable is set, kubectl looks for the cluster on the laptop itself and doesn't find it.
export KUBECONFIG=~/lab.kubeconfig

# The READY column reads as "ready / requested": 1/1 means one replica requested and running.
kubectl get deployment rickroll
```

It should say `1/1`. If it's more, bring it back to one, otherwise the growth won't be as visible:

```bash
# scale changes exactly one field in the application's record — the replica count.
# The cluster will retire the extra replicas on its own, within seconds.
kubectl scale deployment rickroll --replicas=1
```

## Step 2. Read what the application asks for

Before configuring autoscaling, you need to understand what it will calculate percentages against.

```bash
# An object in the cluster has hundreds of fields; the table doesn't show them. jsonpath extracts
# exactly one spot from the response. Read the path top to bottom: spec.template is the template
# from which replicas are created, containers[0] is the first container in it, resources is its
# request and ceiling for CPU and memory. The tail {"\n"} is a newline, so the response
# doesn't run into the next command prompt.
kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
```

```json
{"limits":{"cpu":"300m","memory":"128Mi"},"requests":{"cpu":"20m","memory":"32Mi"}}
```

Two pairs of numbers, and they get mixed up constantly. Let's work through it on the CPU.

**`requests: cpu: 20m`** — "twenty millicpu," that is, two hundredths of a core. This is the request: the amount the cluster commits to keeping behind the Pod at all times. The scheduler uses this number to decide whether the Pod fits on a node: the sum of requests of all Pods on a node cannot exceed the node's capacity. The nearest analog is a reservation in vSphere.

**`limits: cpu: 300m`** — the ceiling. The Pod won't be given more than three tenths of a core, even if the node is idle. The analog is a limit in vSphere.

There's a fifteenfold gap between them, and that's deliberate: a Pod can take a lot when the CPU is free, but only a little is guaranteed to it.

⚠️ **CPU and memory behave differently when they hit their limit, and it matters more than it seems.** Hit the CPU limit and the application simply starts running slower (throttling). Hit the memory limit and the kernel kills the container: you see the status `OOMKilled` and the Pod is recreated. The first is unpleasant; the second is an outage. In vSphere memory can't be exceeded either, but there the guest gets swap and degrades rather than dying.

**And now the key point for this lab.** HPA computes load not from the limit, not from the node's capacity, and not from how many cores the application sees inside itself. It computes it **from `requests`**. A threshold of 50% with `requests: 20m` means 10 millicpu per replica.

From this follows the thing that most often keeps autoscaling from working for people setting it up for the first time: **if a container has no `requests.cpu` specified, there's nothing to compute against, and HPA won't work at all.** It won't throw an error — it will silently keep showing `<unknown>`.

## Step 3. Turn on autoscaling

The `hpa.yaml` file is in the folder. Let's go through it, then apply it.

<details>
<summary><b>A closer look: what's inside hpa.yaml</b></summary>

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: rickroll
```

`autoscaling/v2` is not decoration. In the old `v1` you could only set a CPU target and couldn't control the rate of growth. Everything below the `metrics` block is unavailable in `v1`. If you see an example online on `autoscaling/v1` — it's not fatally out of date, but it won't cover half of what you need.

```yaml
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: rickroll
```

Who we watch and who we turn. HPA doesn't manage Pods directly — it changes the `replicas` field on the Deployment, and from there the same chain works as in the self-healing lab: the Deployment passes the number to the ReplicaSet, the ReplicaSet creates the missing replicas.

From this comes a practical rule: **as long as HPA exists, changing `replicas` by hand is pointless.** You set three, and fifteen seconds later HPA sets its own. Two mechanisms on one field is always an argument, and HPA wins it.

```yaml
  minReplicas: 1
  maxReplicas: 6
```

A corridor. The lower bound guards against "there's no load, let's turn everything off" — HPA can't scale down to zero. The upper bound protects the budget and the node: without it a sudden spike (or a bug in the application that eats the CPU) would multiply replicas until the nodes run out of room.

Six was chosen for the training node `u1.medium`. Six replicas at 20m of request each is 120m — the node handles that easily.

```yaml
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

The rule: keep the **average** load across all replicas at 50% of their `requests`, that is, 10m per replica.

The word "average" is key here, and all the arithmetic depends on it. HPA computes like this:

```
replicas needed = ceil( current replicas × current load ÷ target load )
```

One replica at 645% load with a target of 50% gives `ceil(1 × 645 / 50) = 13`. Thirteen is more than six, so HPA will hit `maxReplicas`.

Why the target is 50 and not 80: at 80% growth begins only once the application is already in trouble. Half leaves a margin for the time it takes new replicas to come up. For real services this number is tuned to how many seconds startup takes.

```yaml
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 2
          periodSeconds: 15
```

The rate of growth. By default, before scaling up, Kubernetes looks at the metric history over some window so it doesn't jerk on a random spike. In a lab that looks like "nothing is happening," so the window is zeroed out: we react to the very first measurement.

`Pods: 2 / 15s` — add no more than two replicas every fifteen seconds. That's why the path up will be in steps: 1 → 3 → 5 → 6.

⚠️ **By specifying `policies`, you replace the standard ones rather than adding to them.** The standard growth policy (doubling every 15 seconds) no longer applies here.

```yaml
    scaleDown:
      stabilizationWindowSeconds: 60
```

Downward, on the other hand, comes with a delay. HPA looks at the maximum of the requested counts over the last minute and reduces the replica count only if the load was low for that entire interval. Otherwise, on every pause between spikes, replicas would start vanishing and reappearing.

The standard value here is **300 seconds**, five minutes. We cut it to a minute so you have time to see the return within the lab. In production five minutes is more sensible.

</details>

Apply it:

```bash
# apply = "bring the cluster to what's described in the file." The HPA object will appear at once,
# but it won't start computing right away — that's what we'll trip over in the next step.
kubectl apply -f hpa.yaml
```

## Step 4. The check that won't pass

Let's see what we got:

```bash
# hpa is shorthand for horizontalpodautoscaler; kubectl understands both spellings.
# The TARGETS column reads as "current load / target," REPLICAS is how many
# replicas are requested right now.
kubectl get hpa rickroll
```

**What you'll see:**

```
NAME       REFERENCE             TARGETS              MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: <unknown>/50%   1         6         1          10s
```

In the `TARGETS` column, instead of the load, there's `<unknown>`. Autoscaling doesn't know how much CPU the application consumes, and so it has nothing to base a decision on.

⚠️ **Or you might see a percentage right away** — for instance, `cpu: 5%/50%`. That doesn't mean anything is different for you: the metrics collector in your cluster has already been running for a while and has had time to poll the Pods. `<unknown>` appears on a cluster that was just brought up. If you get a number straight away — read the breakdown below anyway, because you'll meet the cause of `<unknown>` one day, and it's better to learn it in advance than at the moment it gets in your way.

> **Stop and think before reading on.**
>
> The manifest applied without errors, the object is created, the container has `requests` — we just looked. So it's not that something is missing from the description.
>
> Hint: where does autoscaling even learn the current load from? Someone has to report that number to it — and that someone polls the Pods not continuously, but once every several dozen seconds.

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

There isn't enough time. Wait a minute and a half to two minutes and look again:

```bash
# The same command as above. We're looking at the same TARGETS column.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 0%/50%     1         6         1          2m
```

**This isn't a breakage and there's nothing to fix here.** Pod load is collected by a separate service, `metrics-server`. It polls the nodes roughly once every fifteen seconds and averages the result over a short window. Until it has two measurements in a row, it has nothing to hand over, and HPA honestly writes "I don't know."

You can check that metrics are flowing directly:

```bash
# top = "how many resources these Pods are eating right now." The numbers come from
# the same metrics-server that feeds autoscaling: if top answers, then the
# data source is alive and it's only a matter of time.
kubectl top pods -l app=rickroll
```

```
NAME                        CPU(cores)   MEMORY(bytes)
rickroll-6f4b9c8d57-p9wqt   1m           4Mi
```

If after five minutes it's still `<unknown>` and `kubectl top` answers `error: Metrics API not available` — then it really is a breakage, and the cause is one of two: `metrics-server` isn't installed in the cluster, or the container has no `requests.cpu` set (in which case `kubectl top` works but HPA still can't compute — there's nothing to take the percentage from).

`metrics-server` installs itself into the cluster along with it — you don't need to enable it separately. It lives in the `cozy-monitoring` namespace, and you can check like this:

```bash
# -n = which namespace to look in. A namespace is a section of the cluster;
# by default kubectl looks in default and doesn't see the system Pods there.
# deploy is shorthand for deployment.
kubectl -n cozy-monitoring get deploy metrics-server
```

Don't confuse it with the **Monitoring agents** checkbox from lab 0: that one is responsible for collecting metrics into storage and for graphs (the observability lab), while `metrics-server` is responsible for the current numbers for `kubectl top` and autoscaling. Different mechanisms, and they live independently.

The exact cause will be told by:

```bash
# describe = the object's full card: all fields, events, and conditions,
# unlike get, which prints a few table columns.
kubectl describe hpa rickroll
```

At the very bottom, in `Conditions`, there will be a `ScalingActive` line with a human-readable explanation.

**A lesson broader than this error.** In Kubernetes "applied" and "working" are separated in time. The `apply` command only records your intent into the cluster. From there controllers pick it up, and each has its own pace: HPA recomputes once every fifteen seconds, metrics lag by a minute, the garbage collector comes around once every few minutes. The habit from vCenter — "the dialog closed, so it's done" — lets you down here. What you should watch is not the command's return code, but the object's `status`.

</details>

## Step 5. Bring up the load generator

Loading the application from the laptop through `port-forward` is pointless: the bottleneck becomes your home internet and the tunnel itself, not the application. The generator has to sit inside the cluster, next to the target.

The `fortio.yaml` file is in the folder.

<details>
<summary><b>A closer look: what's inside fortio.yaml</b></summary>

```yaml
kind: Deployment
metadata:
  name: fortio
```

Fortio is an ordinary application in the cluster, deployed with the same Deployment as everything else. There's no special "testing infrastructure" here, and that in itself is telling.

```yaml
        - name: fortio
          image: fortio/fortio:latest
          args: ["server"]
```

The Fortio image can run in two modes. `fortio load ...` is a one-off run from the command line. `fortio server` is a continuously running service with a web interface, where you start the load with a button and see the result right there as a graph. We take the second: at a workshop, looking at a latency histogram in the browser is clearer than reading a column of numbers in the terminal.

⚠️ **The `latest` tag in a manifest is something you shouldn't do in production.** Today it's one image, a month from now another, and you won't be able to reproduce your own test. For a training generator it's tolerable; for anything else it's not.

```yaml
          ports:
            - containerPort: 8080
              name: http
```

Fortio's web interface listens on 8080 and lives at the path `/fortio/`. The name `http` will be needed below, in the Service.

```yaml
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: "1"
              memory: 256Mi
```

Notice: the generator is allocated more than the target. A request of 100m against `rickroll`'s 20m, a ceiling of a whole core against 300m.

This isn't generosity, it's a mandatory condition for a correct test. If the generator runs short on CPU, it will hit its own ceiling, and you'll be measuring Fortio, not the application. The symptom of this mistake is recognizable: latencies rise while the target's load stays put.

```yaml
kind: Service
metadata:
  name: fortio
spec:
  ports:
    - port: 8080
      targetPort: http
```

A stable address for the web interface. From inside the cluster it's now reachable as `http://fortio:8080/`, and from outside via `port-forward`, which is what we'll do next.

</details>

Apply and wait:

```bash
# There are two objects at once in the file: the Deployment with the generator and a Service — a
# stable address for its web interface.
kubectl apply -f fortio.yaml

# rollout status holds the terminal and prints progress until the replica is ready.
# We wait here on purpose: until the generator is up, there's nothing to drive load with.
kubectl rollout status deployment/fortio
```

## Step 6. Open Fortio in the browser

📍 **Window 1** — the tunnel to Fortio. Port `8081` was chosen so as not to collide with `8080` if you still have the tunnel to `rickroll` from lab 1 open:

```bash
export KUBECONFIG=~/lab.kubeconfig

# port-forward runs a tunnel from your laptop into the cluster.
#   svc/fortio    what we connect to: the Service named fortio
#   8081:8080     reads as "port on your side : port in the cluster" — a request
#                 to localhost:8081 goes to port 8080 of this Service
kubectl port-forward svc/fortio 8081:8080
```

The command doesn't finish — it holds the tunnel open. While it runs, open <http://localhost:8081/fortio/>.

⚠️ **The trailing slash in the path is mandatory.** At `http://localhost:8081/fortio` without it, Fortio answers 404, and it looks as if it didn't start.

## Step 7. Prepare a second window to watch the growth

The point of the lab isn't the numbers in Fortio's report, but what happens to the replicas. You need to see this at the same time as the load, not after it.

📍 **Window 2** — leave it open until the end of the lab.

We'll watch with the `-w` (watch) flag. It means not "refresh the screen" but "print a new line on every change." The output comes out as an event log rather than a table. This is an important difference from `watch kubectl get pods`, where you see only the "now" snapshot and easily miss the intermediate states.

```bash
export KUBECONFIG=~/lab.kubeconfig

# We watch rickroll's replicas: each new line is a state change of one of them.
# The command doesn't finish; to exit, Ctrl+C — this has no effect on the replicas themselves.
kubectl get pods -l app=rickroll -w
```

If you have a third window, put this in it too — that way you can see the decision-making process itself:

```bash
# The same watching, but of the autoscaling decisions: TARGETS shows how the load
# changes, REPLICAS shows how many replicas it requested in response.
kubectl get hpa rickroll -w
```

## Step 8. Apply the load

📍 **Where:** in the browser, on the Fortio tab.

Fill in the form:

| Field | Value | Why so |
|---|---|---|
| URL | `http://rickroll/` | the Service name; Fortio is in the cluster and sees it directly |
| QPS | `1200` | twelve hundred requests per second |
| Duration | `90s` | a minute and a half: enough both for growth and to make it out |
| Connections | `80` | eighty parallel connections |

Press **Start**.

⚠️ **If the fields are named differently in your version of Fortio** (for example, the number of connections is labeled `Threads`), go by meaning: URL, request rate, duration, parallelism. You can apply the same load with a command, bypassing the browser:

```bash
# exec runs a command inside an already-running Pod, not on your laptop.
#   deploy/fortio   in a Pod of this application; which Pod exactly — kubectl picks itself
#   --              everything after this separator is the command for the Pod
#   -qps 1200       twelve hundred requests per second
#   -c 80           eighty parallel connections
#   -t 90s          hold the load for a minute and a half
# The last argument is the target: the Service name of our application.
kubectl exec deploy/fortio -- fortio load -qps 1200 -c 80 -t 90s http://rickroll/
```

## Step 9. Watch what happens

📍 **Window 2**, about twenty seconds after the start:

```
NAME                        READY   STATUS              AGE
rickroll-6f4b9c8d57-p9wqt   1/1     Running             22m
rickroll-6f4b9c8d57-mn4kd   0/1     Pending             0s
rickroll-6f4b9c8d57-mn4kd   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-t8zxc   0/1     ContainerCreating   0s
rickroll-6f4b9c8d57-mn4kd   1/1     Running             3s
rickroll-6f4b9c8d57-t8zxc   1/1     Running             3s
```

Then two more, then one more. Within a minute there are six replicas.

📍 **Look at the HPA** — what it sees and what it decided:

```bash
# TARGETS is the current average load against the target, REPLICAS is how many replicas are requested.
kubectl get hpa rickroll
```

```
NAME       REFERENCE             TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
rickroll   Deployment/rickroll   cpu: 645%/50%   1         6         6          8m
```

**645%.** On the testbed where this lab was tried out, it came to exactly that; yours will be a different order of numbers, but definitely hundreds of percent.

The number looks absurd until you remember what it's computed from. Not from the node's capacity, but from the replica's **request**, and our request is 20m — two hundredths of a core. A replica takes several times more than requested, and that's allowed: `requests` is a guaranteed minimum, not a ceiling. The ceiling is `limits`, and it's still far off.

The node, meanwhile, is far from free: `u1.medium` is one core, and in this minute both the application's replicas and the load generator itself are running on it. The high percentage comes not from an abundance of capacity but from a small denominator.

**Percentages over a hundred here are the norm, not an alarm.** This is the main thing that breaks the intuition brought from vCenter: there "CPU Usage 645%" would mean a catastrophe, because the percentage was computed from what was allotted. Here it's computed from the requested minimum, and between the request and the ceiling we have a fifteenfold gap.

Check HPA's arithmetic yourself:

```bash
# The consumption of each replica separately. CPU(cores) is printed in millicpu:
# 100m is a hundredth of a core, 1000m is a whole core.
kubectl top pods -l app=rickroll
```

The average across the replicas is exactly the number HPA compares against the threshold: 50% of the 20m request, that is, 10m. The sum across all replicas will hit the node's core — and that's where the growth stops, even if you raise the load further.

📍 **In the browser on the Fortio tab**, meanwhile, a latency histogram is being drawn. Watch the run through to the end: at the end a line like `Code 200 : 108000 (100.0 %)` will appear. Zero errors — the application coped. Remember where this line is: in lab 4 it will be the main piece of evidence.

## Step 10. Watch the replicas drive back down

The load is over. Do nothing, watch window 2.

For the first minute and a half to two minutes nothing will happen. The pause is made up of three delays: metrics lag by about a minute, `stabilizationWindowSeconds: 60` requires the load to be low for the entire last minute, and HPA itself recomputes once every fifteen seconds.

Then the lines will pour in all at once:

```
rickroll-6f4b9c8d57-t8zxc   1/1     Terminating   4m
rickroll-6f4b9c8d57-mn4kd   1/1     Terminating   4m
...
```

Five replicas leave, one remains — `minReplicas`.

**Notice the asymmetry.** We went up in steps of two replicas; we came down in a single move. That's by design: erring on the side of "too many replicas" costs only the wallet, while erring on the side of "too few" means bringing the service down. So they grow aggressively and shrink cautiously.

## Verification

📍 **Where:** on the laptop, in the same terminal window where you worked with `kubectl`.

The script checks not the fact that the manifest was applied, but that the mechanism is genuinely alive: that the HPA exists and targets the right Deployment, that the container has a `requests.cpu` the percentage is computed from, that `metrics-server` is really handing over numbers (`TARGETS` isn't `<unknown>`), and that the HPA status still carries a mark that scaling has already fired.

⚠️ **Run the check before cleanup** — once the HPA is deleted there will be nothing to check.

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to install it is written at the start of lab 0. Without WSL you can complete the lab, but there'll be no report artifact.

```bash
# ./ means "a file from the current folder," not a command from the system PATH.
# The script changes nothing in the cluster: it only reads and prints a report.
./check.sh
```

## Cleanup

**Delete the HPA.** In lab 4 we'll be rolling out a new version under load, and an extra mechanism changing the replica count at the same time would only muddle the picture:

```bash
# delete -f = "remove from the cluster what's described in this file." The application stays:
# only the HPA is described in the file. After deletion the replica count freezes at the current value.
kubectl delete -f hpa.yaml
```

**Keep Fortio** — it will be needed in lab 4 as a load source. If you're not planning lab 4, remove it too:

```bash
# Removes both objects from the file — the generator's Deployment and its Service.
kubectl delete -f fortio.yaml
```

Don't touch the `rickroll` application.

Everything you freed returned to the node's shared pool the moment the containers finished. There's no "allocated but not given back" here — a request lives exactly as long as the Pod lives.

## What we can now do

- Explain the difference between `requests` and `limits` and predict what happens when each is hit
- Understand why HPA computes percentages from `requests` and why without them it doesn't work
- Read the HPA formula and say in advance how many replicas it will request
- Tell "the manifest is applied" apart from "the mechanism started working" and know where to look at status
- Give an application real load from inside the cluster, not from the laptop

## And in vSphere this would be

In vSphere you scale up: hot-add of CPU and memory to a running machine. A person does it on a schedule or on an alert, and that's it — vCenter can't multiply application instances; for that you need a load balancer, a machine template, and someone's manual work. DRS solves a different problem: it moves existing machines between hosts, but it doesn't change their count.

Here the number of replicas is a consequence of load, described in twenty lines of text.

**Where vSphere is more convenient, honestly.** Three things, and all of them significant.

First, hot-add works with any application, including one written in 2009 that exists strictly as a single instance. HPA requires the application to be able to run in several replicas at once: with no shared state, no writing to a local file, no session pinned to an instance. If it can't do that, autoscaling is unavailable to you, and Kubernetes won't solve this problem — it will lay it bare. This is exactly where the real boundary of migration runs, not in the manifests.

Second, metrics. vCenter keeps statistics for months, and the question "what happened last Tuesday" is answered with a graph. `metrics-server` holds the last few minutes and nothing more — it's designed precisely to feed HPA. For history you'll have to set up Prometheus, and that's a separate job (lab 14).

Third, cost predictability. A machine with four cores costs a certain amount, and that's known in advance. Autoscaling means that on a bad day you'll get six times more consumption than on a normal one. `maxReplicas` is not a fine performance tuning knob, it's your money fuse, and it should be treated accordingly.
