# Lab 14 · Observability: find your own spike in the graphs

| | |
|---|---|
| **Time** | 30 minutes |
| **What it proves** | Metrics collect themselves, continuously and retroactively. You don't need to buy a separate monitoring system |
| **What you'll need** | The cluster from lab 0, the app from lab 1, lab 3 completed (load and HPA), access to the tenant dashboard |

## Why this matters

Yesterday at 16:40, "Propusk" was slow to respond for fifteen minutes. The complaint arrived today at 11:00,
as it always does. The question from management: what was that, and will it happen again.

The "let's reproduce it now and take a look" approach doesn't work: you can't reproduce someone else's load
from yesterday. The only way to answer is to have **records from yesterday**, taken before anyone asked.

In this lab we'll find, in the graphs, the traces of our own load from lab 3: the CPU spike when the traffic
started, and the step up when autoscaling added copies. We made no special preparations for this — the records
are already there.

## Mini-glossary

| Term | What it is | Like… but |
|---|---|---|
| **Metric** | A number taken regularly: how much CPU, memory, how many requests | **a counter in the vCenter graphs**, but stored as history rather than as the last value |
| **Label** | A "name=value" pair on a metric: pod, namespace, cluster | **the object a counter is attached to**, but there are many labels, and you can slice and group by any of them |
| **Time series** | A single metric with a single set of labels, over time | **a single graph in vCenter**, but every combination of labels is its own series, and there are thousands of them |
| **Scrape** | Collection: an agent polls the sources every N seconds | **vCenter counter collection**, but an agent pulls the data rather than the application pushing it |
| **PromQL** | The query language for metrics | there's no direct analogue: in vCenter you pick a counter, here you write an expression |
| **VictoriaMetrics** | The store where the collected metrics are kept | **the vCenter statistics database**, but it understands the Prometheus query language, even though it isn't Prometheus itself |
| **Grafana** | The interface to metrics and logs | **the Performance tab**, but a separate product; dashboards are written by hand or taken ready-made |
| **Retention** | How long to keep the history | **the statistics levels in vCenter**, but set by a parameter; by default 3 days and 14 days across two separate stores |
| **Logs** | The lines an application writes | **logs in the guest OS**, but collected centrally, with their own query language, not PromQL |
| **Pod** | The smallest unit of execution: one container or several, always on a single node | **a virtual machine**, but disposable: instead of rebooting it, it's recreated under a new name |
| **Namespace** | A partition inside the cluster: identical names in different namespaces don't collide | **a folder in the vCenter inventory**, but it also divides up permissions, quotas, and network policies |
| **Tenant** | Your slice of the platform: Grafana lives there, and the cluster's metrics flow into it | **a Resource Pool with its own permissions**, but it also hands out ready-made services, not just resources |

### Metrics and logs — why they're different things

They're constantly lumped together, and then people go looking in the logs for something that only exists in the metrics.

| | Metrics | Logs |
|---|---|---|
| What they are | numbers at regular intervals | lines at the moment of an event |
| Example | "at 16:41:30 the Pod used 240 millicores" | "16:41:31 ERROR connection refused" |
| How much space | little, and the volume is predictable | a lot, and the volume depends on how talkative the application is |
| How long they're kept | weeks and months | days |
| The question they answer | "how much and when" | "what exactly happened" |
| Query language | PromQL | LogsQL (in Grafana this is a separate data source) |

They work as a pair: **the metrics find you the moment, the logs find you the cause.** The graph
showed a spike at 16:41 — you go to the logs for that minute. It doesn't work the other way round: searching
the logs for "when things went bad" can take forever.

### Why metrics are taken continuously, not on demand

This is the main thing that separates monitoring from diagnostics, and it's worth stating plainly.

Collecting on demand is **physically** impossible: by the time the question is asked, the event is already over.
No system will show you last night's load if no one was recording it last night.

So the agent polls everything, indiscriminately, every 30 seconds and puts it into storage. Yes,
99% of these numbers will never be looked at by anyone. The price of that 99% is a few gigabytes of disk.
The price of the missing one percent is "we don't know what happened, and we never will."

⚠️ **The downside, worth knowing about in advance.** Continuous collection means continuous
cost: the agent takes up CPU and memory, and storage grows. On a large cluster, metrics become
a noticeable line item in consumption, and you have to thin them out: reduce retention,
drop unneeded labels, turn off collection of rarely-used metrics. This is routine operational
work, and it doesn't appear in the first month, but it does appear.

## What's in the lab folder

You already have all the files — you got them along with the repository. There's nothing to create or type
out again: wherever it says `kubectl apply -f name.yaml` below, the file is taken from here.

```bash
# switch to this lab's folder: all the relative paths below are counted from here
cd labs/14-observability
```

| File | What it is | When it comes in handy |
|---|---|---|
| `check.sh` | Checks that metrics are being collected and the graphs respond | you run it at the end of the lab |
| — | This lab has no manifests of its own: we take the load and autoscaling from lab 3 — `../03-scale/` | |

## Step 1. Make sure metrics are being collected at all

📍 **Where:** on the laptop.

The `lab` cluster doesn't expose its metrics on its own, but through the `Monitoring agents`
add-on. Check whether it's enabled:

```bash
# KUBECONFIG — the variable kubectl reads to learn the cluster's address and who to
# log in as. You saved the file ~/lab.kubeconfig when you created the `lab` cluster.
# It has to be set again in every new terminal window.
export KUBECONFIG=~/lab.kubeconfig

# get pods = "show me which pods exist".
#   -n cozy-monitoring   look not across the whole cluster, but in this namespace: that's
#                        exactly where the add-on puts its collectors.
kubectl get pods -n cozy-monitoring
```

**If you see `vmagent` and `fluent-bit` in the list** — everything's in place, move on.

⚠️ **Look at the names, not at whether the list is empty.** The `cozy-monitoring` namespace
always exists: the platform also puts `metrics-server` there, and that gets installed on any
cluster with its own etcd and doesn't depend on the add-on. In other words, seeing a
`metrics-server` line and concluding that metrics collection is on is a classic mistake, and it surfaces
only in Grafana, where everything will be empty.

**If the list has `metrics-server` but neither `vmagent` nor `fluent-bit`:**

```
NAME                              READY   STATUS    RESTARTS   AGE
metrics-server-7d4b8c9f5-x2klm    1/1     Running   0          3d
```

That means the add-on is off, and you have no records of the past. This, by the way, is a precise
illustration of the previous section: you can't enable collection retroactively.

You enable it in the dashboard: `Kubernetes` → `lab` → edit → in the Addons section, check
`Monitoring agents`. The add-on comes up in a couple of minutes, but **metrics only start accumulating
from that moment on** — you won't find the spike from lab 3 anymore.

So you'll have to create the spike again. Bear in mind that the cleanup in lab 3 removed
autoscaling, and the cleanup in lab 4 removed the load generator, so you need to bring back both:

```bash
export KUBECONFIG=~/lab.kubeconfig          # the same access file as above

# apply = "bring the cluster to what's described in the file". Both files live in the
# neighboring lab's folder, so the path starts with `../` — no need to type them again.
kubectl apply -f ../03-scale/hpa.yaml       # the autoscaling rule for rickroll
kubectl apply -f ../03-scale/fortio.yaml    # the load generator

# rollout status = "hold the terminal and tell me when the rollout is done".
# deployment/fortio — the object type and its name. The command returns the prompt
# with the line `successfully rolled out` once the generator comes up.
kubectl rollout status deployment/fortio
```

Wait until `kubectl get hpa rickroll` shows a percentage instead of `<unknown>`; `hpa` is
short for `HorizontalPodAutoscaler`, the autoscaling object. This takes a couple of
minutes. Then forward the generator's port and apply the same load as in lab 3, otherwise the
autoscaling step won't appear:

```bash
# port-forward = dig a tunnel from the laptop into the cluster. While the command runs,
# a request to localhost:8081 lands in the load generator.
#   svc/fortio    the target: the service (not the pod) named fortio
#   8081:8080     on the left, the port on your laptop; on the right, the port inside the service
# Don't close the window: the tunnel lives exactly as long as the command runs.
kubectl port-forward svc/fortio 8081:8080
```

At <http://localhost:8081/fortio/>: **URL** `http://rickroll/`, **QPS** `1200`,
**Duration** `90s`, **Connections** `80`. Come back here a couple of minutes after it finishes — the
data will be there.

⚠️ To avoid ending up in this situation, enable `Monitoring agents` right when you create the
cluster — in lab 0 it's a separate line in the parameters table.

<details>
<summary><b>What exactly runs there and where the collected data goes</b></summary>

In your cluster's `cozy-monitoring` namespace, the following run:

| Who | What it does |
|---|---|
| `vmagent` | polls the metric sources every 30 seconds and sends what it collects to the tenant |
| `kube-state-metrics` | turns the state of cluster objects into metrics: how many replicas, what state the Pods are in |
| `node-exporter` | metrics of the node itself: CPU, memory, disk, network |
| `fluent-bit` | collects container logs and sends them to the tenant |
| `metrics-server` | **not part of monitoring**: installed together with the cluster and supplies the current numbers for `kubectl top` and autoscaling. It stores nothing and takes no part in metrics collection |

Note: **there's no storage here**. Everything collected is sent immediately over the network to the
tenant, into the shared metrics store next to Grafana. This is deliberate: the `lab` cluster is a
disposable thing — you'll delete it, but the records of how it behaved have to outlive that deletion.

To see the address the collector sends its data to:

```bash
# get vmagent = "show me the collector object". Instead of the usual table we ask for a single
# field from its description — the -o jsonpath syntax works with any cluster object:
#   .items[0]                  the first (and here only) collector found
#   .spec.remoteWrite[0].url   the address it hands the metrics to
#   {"\n"}                     a newline, otherwise the output runs into the prompt
kubectl get vmagent -n cozy-monitoring \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}{"\n"}'
```

```
http://vminsert-shortterm.tenant-workshopXX.svc.cozy.local:8480/insert/0/prometheus
```

The address points into your tenant. It's the same mechanism the virtual machine from lab 12 used to talk to the
application: an ordinary network between ordinary addresses.

</details>

## Step 2. Open the tenant's Grafana

📍 **Where:** in the browser.

The address is the `grafana` subdomain of your tenant host:

```
https://grafana.<your tenant host>
```

The exact address is written down in the dashboard: your tenant → the `Monitoring` app → the
`Ingress` tab. An Ingress is a rule for publishing a service to the outside under a domain name; the
closest analogue is an entry on a load balancer, only described inside the same cluster. The address is
there in full, host name and all.

A second place is the output of `check.sh` from this same lab: the line "Grafana for your metrics".
The script pulls the address out of that same ingress, so there's no need to type it by hand.

⚠️ **If there's no `Monitoring` app in your tenant** — then you have no Grafana of your own either, and
the metrics go to the parent tenant's monitoring. The reliable path is to deploy `Monitoring` from the
catalog (the `Administration` section): the address will appear on the `Ingress` tab of your own
app, and all the queries below will work. `check.sh` will also find someone else's monitoring and
name the namespace it runs in, but you'll only be able to open it if you have access to that namespace.

**How to log in.** The login is `admin`. The password is in the `grafana-admin-password` Secret:
dashboard → the `Monitoring` app → the `Secrets` tab → the `password` key → `Reveal`.

As the tenant, `kubectl` won't give you access to this Secret (core Secrets aren't visible to you), so go through the dashboard.

If your monitoring is the parent's, this Secret is out of your reach — then either deploy your own
`Monitoring` app, as described above, or ask for access from whoever runs the testbed.

Once you're in, open **Explore** — this is the section for one-off queries, without saving dashboards.
In the data source dropdown, select **`vm-shortterm`** (which is also the default).

⚠️ **Switch the query field to `Code` mode.** Grafana opens Explore in the builder
(`Builder`) — a form with dropdowns where there's nowhere to type the query text.
The `Builder | Code` toggle is above the input field, on the right. All the queries below are
typed in `Code`.

<details>
<summary><b>What the data sources in the list are</b></summary>

| Source | What's inside | Keeps |
|---|---|---|
| `vm-shortterm` | high-resolution metrics | 3 days |
| `vm-longterm` | the same metrics, thinned out | 14 days |
| `vlogs-generic` | container logs | 1 day |

Two metrics stores instead of one is a compromise between resolution and volume.
You'll investigate an incident with `shortterm`, where you can see every 30 seconds. You'll answer
the question "how did it behave two weeks ago" with `longterm`, where the resolution
is coarser but the depth is greater.

Exactly the same logic as in the vCenter statistics levels, where 20-second-interval data
lives for a day and hourly data for a year.

⚠️ **`vlogs-generic` is logs, and the query language there is different.** PromQL doesn't work in it,
and that's not a bug: logs have their own grammar. Don't waste time switching the source and
pasting in the same query.

</details>

⚠️ **There are no ready-made Pod dashboards in the tenant Grafana.** The list will have dashboards for
databases, ingress, and queues — the things that belong to managed services. Dashboards at the
"Pods and nodes" level aren't part of the tenant set. So from here on we work in Explore and write
queries by hand. This is less convenient than the ready-made Performance tab in vCenter, and there's
no point pretending otherwise.

## Step 3. Find your Pods

📍 **Where:** in Grafana, Explore, the `vm-shortterm` source.

Let's start with the crudest question: what Pods are visible in the cluster at all. The query is short, but
it has three unfamiliar parts — expand the breakdown before you type it in.

<details>
<summary><b>Breaking the query down part by part</b></summary>

```promql
container_cpu_usage_seconds_total
```

The metric name. It's a counter: how many seconds of CPU time the container has spent
since it started. It only goes up — until the container restarts, after which
it starts from zero.

On its own it's useless: "the Pod spent 4718 seconds of CPU" tells you nothing.
This metric becomes useful after `rate()`, which we'll get to in the next step.

```promql
{cluster="kubernetes-lab", namespace="default"}
```

A filter by labels. Both labels here matter.

`cluster` — the name of your cluster as the platform knows it. It is **not equal** to `lab`:
the application is called `lab`, but the release it's deployed by is `kubernetes-lab`, and it's
the release name that ends up in the labels. This is the first pitfall everyone trips over. To check what
yours is called: clear the value and see what Grafana's autocomplete suggests.

The label is needed because a single store holds the metrics of **all** your clusters and
managed services. Without the filter you'll get a mix of everything in the tenant.

`namespace` — the namespace **inside** the `lab` cluster. The app from the first lab was deployed
into `default`, so here it's `default`. Don't confuse it with the tenant namespace
(`tenant-workshopXX`) — these are different things in different clusters. The tenant namespace lives in the
`tenant` label.

```promql
count by (pod) ( ... )
```

Group by the `pod` label and count how many series fell into each group. We're
interested not in the numbers themselves, but in the list of resulting `pod` values.

</details>

```promql
# count by (pod) — break the matched series out by the pod label and count how many series
# are in each group. The numbers themselves don't matter: what we want is the list of pod names that results.
count by (pod) (
  # the metric name — the container CPU-time counter
  container_cpu_usage_seconds_total{
    cluster="kubernetes-lab",   # your cluster: the release name here, not the app name lab
    namespace="default"         # the namespace inside the lab cluster where rickroll is deployed
  }
)
```

**What you should see:** switch the view from Graph to **Table** — the list reads
better that way. The table will have `rickroll-...`, `fortio-...` and, if you did lab 11,
`propusk-build-...`.

## Step 4. Find the CPU spike

The counter from the previous step can't be read in its raw form. Let's turn it into a quantity you
can compare against the Pod's request and against what `kubectl top` shows — into consumed cores.
What `rate()` does in the process, and where the two extra conditions in the query come from, is in the breakdown below;
expand it before you type.

<details>
<summary><b>Breaking the query down part by part</b></summary>

```promql
rate( ... [2m])
```

`rate` takes a counter and computes **its rate of growth per second**, averaging over a two-minute
window. For a CPU-time metric this gives a very convenient quantity: "how many
seconds of CPU per second", that is, how many cores were being consumed. `0.24` means 24% of
one core, that is `240m` in millicores.

The `[2m]` window is a compromise. A smaller window (`[30s]`) — the graph is jumpy and breaks up on
sparse data. A larger one (`[5m]`) — the spike gets smeared out and a low peak can disappear entirely.
Start with `[2m]` and tune from there.

⚠️ **The window must be at least twice the collection interval.** Collection happens every 30 seconds,
so you can't set anything below `[1m]` — only one point would fall inside the window, and a rate can't
be computed from a single point, so the graph goes empty. This is the most common cause of "nothing
is drawing for me".

```promql
pod=~"rickroll-.*"
```

`=~` — a comparison by regular expression instead of an exact match. An exact match won't
do here: Pod names contain a random tail and change on every recreation.

```promql
container!=""
```

Discard series with no container name. Such series exist: they're an aggregate over the whole Pod,
and if you don't discard them, every Pod gets counted twice and the graph shows exactly twice
the truth. Another classic trap.

```promql
sum by (pod) ( ... )
```

Sum up everything that's left, by Pod. A Pod can have several containers; we're
interested in the Pod as a whole.

</details>

```promql
# rate(...[2m]) — the counter's growth rate per second, averaged over a 2-minute window.
# For CPU time it reads as "how many cores were being consumed":
# 0.24 — twenty-four percent of one core, that is 240m.
sum by (pod) (     # sum the pod's containers: one line per pod, not per container
  rate(container_cpu_usage_seconds_total{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*",  # =~ comparison by regular expression: the pod name's tail is random
    container!=""        # drop the whole-pod total series, otherwise everything doubles
  }[2m])
)
```

Set the time range to when you were doing lab 3 — for example, the last 3 hours.

**What you should see:** a flat line right at zero, then a sharp rise for the duration of the
load, then a return downward. If there came to be several replicas, there will be several lines, and
they'll appear not all at once but as the Pods are created.

## Step 5. Find the autoscaling step

We've found the spike. Now let's look at how the cluster responded to it: how many copies of the application
it kept running at each moment and how many it wanted to keep. These are two different numbers, and
the difference between them is the most interesting thing in this step. Where they come from is in the breakdown below.

<details>
<summary><b>Where these metrics come from and how desired differs from current</b></summary>

These metrics come not from the application but from `kube-state-metrics` — it reads cluster objects
through the API and turns their fields into numbers. The `horizontalpodautoscaler` label is the name of
the HPA object (`HorizontalPodAutoscaler`, that same autoscaling rule from lab 3), the
`deployment` label is the name of the Deployment, that is, of the description "keep such-and-such many
copies of the application", and so on for every object type.

`desired` — how many copies autoscaling **wants** right now, having calculated from the
load. `current` — how many are **actually** running. There's always a gap between them:
Pods aren't created instantly.

If `desired` stays above `current` for a long time, it means the copies aren't being created. The cause is
almost always the same: there isn't enough room on the nodes, and the new Pods hang in `Pending`. Exactly the situation
you ran into in lab 11.

Useful alongside:

```promql
# how many rickroll copies have been created in total
kube_deployment_status_replicas{cluster="kubernetes-lab", deployment="rickroll"}
# how many of them have passed the readiness check and are already taking traffic
kube_deployment_status_replicas_available{cluster="kubernetes-lab", deployment="rickroll"}
```

The divergence between them during a rollout of a new version is exactly that pause while the
new copy passes its readiness check.

</details>

```promql
# ..._status_current_replicas — how many rickroll copies are running right now.
# The number comes not from the application but from the HPA object, read by kube-state-metrics.
kube_horizontalpodautoscaler_status_current_replicas{
  cluster="kubernetes-lab",             # only your lab cluster
  horizontalpodautoscaler="rickroll"    # the name of the autoscaling object from lab 3
}
```

and alongside, as a second query:

```promql
# ..._status_desired_replicas — how many copies autoscaling wants to have now,
# based on the load. current lagging behind desired is exactly the pod creation time.
kube_horizontalpodautoscaler_status_desired_replicas{
  cluster="kubernetes-lab",
  horizontalpodautoscaler="rickroll"
}
```

**What you should see:** a stepped line. It was one, then three, then five or
six, then — with a delay of about a minute after the load subsides — back down.

Overlay it on the CPU consumption graph from the previous step: in Explore a second
query is added with the `+ Add query` button. You can see the step follows **behind** the spike with
a lag of several tens of seconds: first the CPU rose, then autoscaling noticed it and
reacted. This is the answer to the question "why did the users manage to notice the slowdown
after all".

## Step 6. Look at the same thing through autoscaling's eyes

Autoscaling looks not at absolute consumption but at the **fraction of `requests`**.
`requests` is a Pod's request for resources: how much CPU and memory the scheduler reserves
for it on a node, regardless of whether the Pod uses those resources or not.
The closest analogue is a reservation in vSphere.

Let's look at exactly the quantity the decision is made on. The query consists of two
parts separated by a division sign: on top, the actual consumption; on the bottom, the request.

```promql
# The top part — the pod's actual CPU consumption. The same query as above.
sum by (pod) (
  rate(container_cpu_usage_seconds_total{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*", container!=""
  }[2m])
)
/
# The bottom part — how much the pod requested. The result of the division is the fraction of the request: 1 means
# "consuming exactly as much as it requested", 0.5 — half of what was requested.
sum by (pod) (
  kube_pod_container_resource_requests{
    cluster="kubernetes-lab", namespace="default",
    pod=~"rickroll-.*",
    resource="cpu"     # the metric also has memory series — we keep only CPU
  }
)
```

**What you should see:** a line that runs low almost all the time and rises for the
duration of the load. A value of one on this graph means "the Pod consumes exactly as much as it
requested".

In `hpa.yaml` from lab 3 there's `averageUtilization: 50`, and in `rickroll.yaml` —
`requests.cpu: 20m`. That is, the trigger threshold is 10 millicores per Pod, which on the graph is the
`0.5` mark. Find the moment the line crossed it, and check it against the step from the
previous step: between them will be those same tens of seconds.

⚠️ Dividing two expressions in PromQL works by matching on **all** labels. Here it lines up,
because both parts are grouped `by (pod)` and no other labels remain after grouping.
If the sets of labels differed, the result would come out empty — no error and no warning, an empty
graph. This is the language's most treacherous feature.

## Step 7. Three queries for everyday use

It's worth saving these — they cover most day-to-day questions.

**Who in the cluster consumes the most CPU, top 10:**

```promql
# topk(10, ...) — keep only the ten series with the largest values.
# Grouping by (namespace, pod) adds the namespace to the answer: you can see whose pod it is.
# The [5m] window is wider than in the previous steps: we want not the shape of the spike, but the average level.
topk(10,
  sum by (namespace, pod) (
    rate(container_cpu_usage_seconds_total{cluster="kubernetes-lab", container!=""}[5m])
  )
)
```

**Memory by Pod (not a counter, so no `rate`):**

```promql
# container_memory_working_set_bytes — not a counter but an instantaneous value: this many bytes
# are occupied at this moment. rate() here would give nonsense — "bytes per second".
sum by (pod) (
  container_memory_working_set_bytes{
    cluster="kubernetes-lab", namespace="default", container!=""
  }
)
```

⚠️ Specifically `working_set`, not `container_memory_usage_bytes`. The latter includes the file
cache, which the kernel will give up under pressure, and so it regularly scares people with figures that have nothing
to do with the application's real needs. The decision to kill a Pod for memory
is also made on `working_set`.

**How much resource is reserved versus how much is actually used:**

```promql
# sum without by — add everything into a single number: how much CPU is reserved for all
# the cluster's pods. This is the request, not the consumption: what's reserved and sitting idle
# goes into the sum too.
sum(kube_pod_container_resource_requests{cluster="kubernetes-lab", resource="cpu"})
```

Compare this number with the sum from the first query. The difference between "reserved" and
"used" is what you pay for and get nothing in return. The same conversation as about
reservations in vSphere, only here you can see it on a graph.

If you did lab 11, take a look at the Android build while you're at it — it's clearly visible:

```promql
# The same rate, but a filter on the build pods. sum without by (pod) — one line for the whole build,
# however many pods it brings up.
sum(rate(container_cpu_usage_seconds_total{
  cluster="kubernetes-lab", pod=~"propusk-build-.*", container!=""
}[2m]))
```

Twenty minutes of a flat plateau at a core and a half to two cores, then a drop to zero. That's how a
Job looks on a graph — a one-off task that carries the work through to the end and finishes. Unlike
an application, which is kept running permanently, its line has an end.

## Step 8. Take a look into the logs

Switch the data source to **`vlogs-generic`**. The query language here is different: in PromQL
you described numeric series, in LogsQL you select lines by the values of their fields.

The query below reads like this: "show the lines whose `kubernetes_namespace_name` field equals
`default` and whose `kubernetes_pod_name` field starts with `rickroll`".
The asterisk at the end is that same random tail in the Pod name, the one that forced you to write
`=~` in PromQL.

```logsql
kubernetes_namespace_name:default AND kubernetes_pod_name:rickroll*
```

Match the time: take the minute of the spike you found on the CPU consumption
graph, and look at the logs for it. In that minute nginx will have a spike of request records.

**This is what we separated metrics and logs for.** With the graph you found the moment among three
hours in a second. With the logs for that minute — what exactly was happening. It doesn't work the
other way round: searching for "when things went bad" by scrolling through logs can take a very long time.

## Check

📍 **Where:** on the laptop, in the same terminal window where you worked with `kubectl`.

```bash
export KUBECONFIG=~/lab.kubeconfig          # access to the lab cluster `lab`

# The two variables below give the script access to the tenant as well. With them it will
# additionally check that the metrics made it there, and print the address of your Grafana. Without them
# the check will pass, but the report will be shorter.
export COZY_TENANT=workshopXX               # your number instead of XX
export COZY_KUBECONFIG=~/.kube/workshop     # the tenant access file

./check.sh                                  # ./ = "run the file from the current folder"
```

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to set it up is
written at the start of lab 0. You can complete the lab without WSL, but there'll be no artifact report.

The script checks not "you looked at the graph" — that can't be checked — but what
can and should be checked: that metrics collection really works, that sending is configured to your
tenant, that log collection works, and that the cluster has a trace of the load from lab 3 that can be found in these
graphs.

## Cleanup

There's nothing to clean up. The `Monitoring agents` add-on consumes little and will be useful until the end of the
workshop — leave it enabled.

The metrics will erase themselves: by default `shortterm` keeps 3 days, `longterm` 14, logs
a day. This is that rare case where the cleanup is done for you and can't be forgotten.

## What we can do now

- Explain why metrics are collected continuously, and how they differ from logs
- Check that collection in the cluster is enabled and exactly where it sends to
- Write queries that find your Pods and their consumption, and not fall for `container!=""`
- Find the load spike in the graphs and autoscaling's reaction to it
- Read the divergence of `desired` and `current` as a sign of insufficient room

## And in vSphere this would be

vCenter shows counters for hosts and virtual machines — that's enough as long as the questions
are asked about virtual machines. The moment the question becomes "what happened to the service", you need
vRealize Operations: a separate product, a separate license, a separate installation,
separate virtual machines to run it on, and a separate person who knows how to configure it.

Here, metrics and log collection is an add-on you enable with a checkbox in the application, and
Grafana with its storage comes up as a catalog item. No license, no implementation project.

**Where vSphere is more convenient, honestly.** When it comes to what works right after installation,
vCenter wins hands down, and we saw it right here in the lab:

| | vSphere | Cozystack |
|---|---|---|
| Graphs right after installation | the Performance tab on every object | you need to enable the add-on and open Grafana |
| Ready-made views | present for any VM and host | in the tenant — only for managed services |
| Finding the counter you need | pick it from a list with the mouse | write a query in PromQL |
| Barrier to entry | an hour | several days, PromQL has to be learned |
| Depth once you've got the hang of it | limited by the set of counters | limited by which metrics and labels are collected |

PromQL is a language, and it really does have to be learned. For the first two weeks you'll be
copying other people's queries and not understanding why the graph is empty. In return you get what
vCenter doesn't have at all: the ability to ask an arbitrary question — "show the consumption of this
application's Pods relative to their reservation, grouped by node, for last Tuesday" — and get an
answer, rather than "there's no such counter".
