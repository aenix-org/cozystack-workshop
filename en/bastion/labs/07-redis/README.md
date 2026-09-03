# Lab 7 · A cache in front of a slow backend

| | |
|---|---|
| **Time** | 50 minutes, 10 of them spent waiting |
| **What it proves** | The gain from a cache is measured, not declared: it was 800 ms, now it's single digits |
| **What you'll need** | The cluster from lab 0, Harbor and the image from lab 6, `kubectl`, `docker`, dashboard access |

> ⚠️ **`workshopXX` is a placeholder, not a name.** Substitute your own tenant number, or
> the command will go to someone else's tenant and you'll get an access denied — or, worse,
> someone else's data. You received your number together with your password.

## Why this matters

The "Passes" service works, infosec is happy, the registry is your own. And then the guards show up.

> At the checkpoint the guest list takes ten seconds to open. People stand in line, we
> stare at the screen and wait. It used to be fine.

Here's what's going on. Each row of the list is a guest, every guest has an employee who
invited them, and the employee records don't live with you. They live in an HR system
installed back in 2011, and it takes **800 milliseconds** to answer a request. Twelve rows
on the screen — nearly ten seconds.

You can't rewrite the HR system: it isn't yours, it belongs to someone else, and its backlog
of changes is booked solid until next year. You can't speed it up either, for the same reason.

What you can do is stop asking it so often. An employee's surname and department change
roughly once every few years. Asking the slow system for them **every time** the list opens
is wasteful: it's enough to ask once and remember the answer.

The place where answers are remembered is called a cache. Today we'll put one in — and, what
matters more, **measure the difference before and after**. Not "it got faster," but a concrete number.

## Mini-glossary

| Term | What it is | Like… but |
|---|---|---|
| **Cache** | Fast storage of ready answers to repeated questions | **A read cache on a storage array**, but here the application decides what to cache, not the device |
| **Redis** | A key-value store held entirely in RAM | there's no direct analogue; the closest is memcached, if you've come across it |
| **Key** | The string a value is looked up by in the cache | **A file name**, but you invent it, and everything depends on how you do |
| **TTL (time to live)** | How long an entry lives before it disappears on its own | **A snapshot retention period**, but deletion happens with no one involved and no scheduled job |
| **Miss (cache miss)** | The answer isn't in the cache, you have to go to the slow source | **A read-cache miss on a storage array**, but a miss here costs not milliseconds but a trip to someone else's system |
| **Hit (cache hit)** | The answer was found in the cache | **A read-cache hit**, but the application counts the hit, and it too is visible in the response in the `cached` field |
| **Sentinel** | A service that watches Redis and reassigns the leader role on failure | **An HA agent**, but it runs inside Redis itself, no separate cluster is needed for it |
| **Managed service** | A service the platform installs, updates, and backs up for you | you don't get root on the machine it runs on — and that's the point |
| **Fortio** | A load generator with a web interface and a latency histogram | there's no counterpart in vSphere: it's not a tool for measuring infrastructure but a tool for measuring a service |
| **p50 / p99** | The median and the "worst percentages": 99% of requests have latency no higher than this | the average latency is misleading, these two numbers aren't |

## Two kubeconfigs: don't mix them up

In this lab there are two clusters again.

| Kubeconfig | What it is | What we do in it |
|---|---|---|
| `~/.kube/config` | The Cozystack management cluster, your tenant | look at Redis: address, state |
| `~/lab.kubeconfig` | **Your** `lab` cluster from lab 0 | deploy the application and measure |

Both come from the dashboard: the tenant one from the `kubeconfig-tenant-workshopXX` Secret on the
Secrets tab, the cluster one from the access section of your `lab` cluster.

⚠️ **Before every block of commands it says where it's addressed.** If something behaves
strangely, the first thing to do is `echo $KUBECONFIG`.

## What's in the lab folder

You already have all the files — you took them along with the repository. There's nothing to
create or type out again: wherever it says `kubectl apply -f name.yaml` below, the file comes from here.

```bash
# all commands in this lab run from the lab folder — switch into it
cd labs/07-redis
```

| File | What it is | When it comes in handy |
|---|---|---|
| `app/` | The sources of the "Passes" service, the version with a cache | you build it locally, `docker build` |
| `hr-legacy.yaml` | A stub of the legacy directory: answers slowly, like the real one | you apply it on your `lab` cluster |
| `passes-api.yaml` | The "Passes" service without a cache — first we measure how bad it is | you apply it to the same place |
| `cache-patch-broken.yaml` | A **deliberately incomplete** patch that turns the cache on | you apply it to see the error |
| `cache-patch.yaml` | The working patch. A patch, not a full manifest: you see exactly what changes | you apply it after the walkthrough |
| `fortio.yaml` | The load generator for the before-and-after measurements | you apply it to the same place |
| `check.sh` | A check that the second request is an order of magnitude faster than the first | you run it at the end of the lab |

## Step 1. Build version v2 and push it to your own registry

📍 **Where:** on the bastion (in the bastion terminal).

The `app/` folder holds the source. It differs from the previous lab's version in two things:
a "slow directory" mode, and cache handling.

<details>
<summary><b>A closer look: what's inside app/</b></summary>

**One image, two roles.** The `MODE` variable determines what the process starts up as:

| `MODE` | What it is | What it does |
|---|---|---|
| `hr` | a stub of the legacy directory | sleeps for `HR_DELAY` (800 ms by default) and returns the employee's data |
| `api` | the "Passes" service itself | goes to the directory, and if `REDIS_ADDR` is set — to the cache first |

Two images instead of one would mean two places where you can forget to update the version.

**How the trip for data works.** The entire caching logic is about twenty lines:

```go
if cache != nil {
    raw, found, err := cache.Get(key)
    switch {
    case err != nil:
        log.Printf("cache unavailable (%v), going to the directory", err)
    case found:
        if json.Unmarshal([]byte(raw), &emp) == nil {
            fromCache = true
        }
    }
}

if !fromCache {
    emp, err = fetchEmployee(hrClient, hrURL, id)
    ...
    cache.SetTTL(key, string(b), ttl)
}
```

Notice the first branch: **if the cache is unavailable, the application does not crash.** It
writes to the log and goes to the directory — slowly, but correctly. This isn't decoration, it's
a mandatory property of any cache: a cache speeds things up but cannot be a condition for staying
operational. If the service goes down together with the cache, you've built not a cache but one
more point of failure.

From this property, by the way, a predictable failure will grow a little further into the lab.
An application that silently keeps working is pleasant in production and treacherous when debugging.

**The key.** `employee:42` — an entity name, a colon, an identifier. The colon here isn't Redis
syntax but a widely adopted habit: it lets you later search by the pattern `employee:*` and not
confuse your own keys with someone else's when two applications live in one Redis.

**The lifetime is set by the same command as the write:**

```go
r.do("SET", key, val, "EX", strconv.Itoa(ttlSeconds))
```

Not `SET` and then `EXPIRE` as two commands. Between two commands the connection can drop — and
the key stays in the cache forever. Keys like that get hunted for months afterward.

**The Redis client here is our own, fifty lines.** The Redis protocol is text-based, and for `GET`
and `SET` it fits into a single function. In a real project you'd take a ready-made library —
it handles connection pooling, retries, and sentinel. Here our own is needed precisely so the
build has no external dependencies: remember how the previous lab began.

**A separate HTTP client with an enlarged connection pool:**

```go
tr := http.DefaultTransport.(*http.Transport).Clone()
tr.MaxIdleConnsPerHost = 64
```

Without this line, under load half the time would go to establishing TCP connections to the
directory, and the measurement would show not the directory's latency but our own sloppiness.
The first rule of measurement: make sure you're measuring what you think you are.

</details>

Build it and push it to your own Harbor. `build` builds the image from the `Dockerfile` and leaves
it on the bastion, `push` sends it to the registry. The image name is the same as in the previous
lab, but the tag is different — `v2`: the registry will now hold both versions, and the old one
won't go anywhere.

Substitute your own address:

```bash
cd labs/07-redis

# build = "build the image from the Dockerfile".
#   --platform linux/amd64  which processor to build for; the cluster nodes are x86
#   -t <host>/<project>/<name>:<tag>  what to name the result; the registry host at the
#                           start of the name is where push will send it later
#   app/                    the folder with the Dockerfile and sources to build from
docker build --platform linux/amd64 -t harbor.workshop03.example.org/passes/passes-api:v2 app/

# push = "send the image to the registry". The address is taken from the first part of the
# image name, the credentials — from the docker login you did in the previous lab.
docker push harbor.workshop03.example.org/passes/passes-api:v2
```

⚠️ **`--platform linux/amd64` is required if you have a Mac on Apple Silicon or a VM on
ARM.** Without it the image will build for ARM, push without errors, and in the cluster give
`CrashLoopBackOff` with `exec format error` in the logs.

## Step 2. Deploy the directory and the service

📍 **Where:** on the bastion, the `lab` cluster.

In both manifests, instead of the registry address there's a placeholder `HARBOR-HOST`: `sed`
replaces it, editing the files in place. Then `apply` hands the cluster what's described in the
files, and `rollout status` waits for the copies to come up.

```bash
# KUBECONFIG tells kubectl which access file to use. We switch to
# your `lab` cluster; it holds until you close the terminal window.
export KUBECONFIG=~/lab.kubeconfig

# sed -i = "edit the file in place".
#   's|old|new|g'  replace every occurrence; the | separator is used instead of / because
#                  the address contains slashes
#   The macOS version of sed requires a mandatory argument after -i; empty quotes
#   mean "don't make a backup". On Linux that argument must not be there.
#   There are two files at the end of the line: sed accepts several at once and edits them in one pass.

# Linux
sed -i    's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml
# macOS
sed -i '' 's|HARBOR-HOST|harbor.workshop03.example.org|g' hr-legacy.yaml passes-api.yaml

# apply = "bring the cluster to what's described in the files". The -f flag is repeated for each file.
kubectl apply -f hr-legacy.yaml -f passes-api.yaml

# rollout status waits for the copies to be ready and exits on its own; if they don't, it returns an error
kubectl rollout status deployment/hr-legacy
kubectl rollout status deployment/passes-api
```

⚠️ Both manifests reference the `harbor` Secret — the very `imagePullSecret` from the previous
lab. If you didn't do it, the Pods will land in `ImagePullBackOff`. To create the Secret:

```bash
# create secret docker-registry = "create a Secret with registry credentials";
# such a Secret can be read by the kubelet itself when it pulls the image onto a node.
#   harbor             the Secret's name in the cluster — both manifests reference it
#   --docker-server    which registry these credentials are for
#   --docker-username  who logs in; --docker-password — the Harbor administrator password
kubectl create secret docker-registry harbor \
  --docker-server=harbor.workshop03.example.org \
  --docker-username=admin --docker-password='YOUR-PASSWORD'
```

Let's check that the chain works. The service is visible only from inside the cluster, so we make
the request from there too: we spin up a one-off Pod with `curl`, it asks the `passes-api`
service, prints the answer, and disappears.

```bash
# run probe = "run a Pod named probe".
#   --rm              delete the Pod as soon as it's done
#   -i                show us its output
#   --restart=Never   don't restart: this is a one-time command, not a permanent service
#   --image=...       which image to use; the version is pinned so nothing new arrives
#   --quiet           don't print service lines, only the answer
#   --                everything after these two dashes is the command inside the Pod
# An address of the form <service>.<namespace>.svc.cluster.local is the service's internal name;
# by it the Pods find each other without knowing addresses.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**What you should see:**

```json
{"cache":"off","cached":false,"dept":"Logistics","id":"42","name":"Popova E. K.",
 "pod":"passes-api-6f8b9c7d5-x2ktm","took_ms":803,"ttl_s":60}
```

The key fields: `cache: off` — no cache, `took_ms: 803` — there they are, your eight hundred
milliseconds. This is the very number we're going to reduce.

## Step 3. Measure how bad it is now

📍 **Where:** on the bastion, the `lab` cluster.

One request isn't a measurement. You need load resembling the real thing and a distribution of latencies.

Deploy the generator. It comes up like an ordinary application and lives in the cluster next to
the service — that way the measurement doesn't depend on your internet or on the tunnel:

```bash
# the file has two objects: the generator itself and a service for it
kubectl apply -f fortio.yaml
kubectl rollout status deployment/fortio
```

Now we start the load. The `kubectl exec` command runs something inside an already-running Pod —
here, inside the generator, the generator itself is launched, in bombardment mode:

```bash
# exec deploy/fortio = run a command inside this application's Pod
#   --            the boundary: kubectl on the left, on the right the command that goes into the Pod
#   fortio load   bombardment mode: send requests and measure the response time
#   -qps 20       twenty requests per second — we set a pace, not "push as hard as we can"
#   -t 20s        how long the measurement lasts
#   -c 16         sixteen parallel connections. The number isn't arbitrary:
#                 the directory answers in 800 ms, so one connection manages
#                 a little more than one request per second. To hold the set 20 per
#                 second, you need no fewer than sixteen connections — otherwise Fortio
#                 will hit the latency wall and not deliver the requested pace.
#   the last argument is the address we're bombarding
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**What you should see** — at the end of the output, a histogram and lines with percentiles:

```
# target 50% 0.801
# target 90% 0.806
# target 99% 0.812
Code 200 : 400 (100.0 %)
```

**Write these numbers down.** In ten minutes you'll need them for comparison, and memory is built
so that "well, it was around eight hundred" turns into "well, it was around half a second."

### The same thing with the mouse

With the mouse — this isn't the Cozystack dashboard: it works with the management cluster and shows
the tenant's catalog entries, but doesn't peek inside your `lab` cluster. The generator itself has
its own web interface, and you have to reach it through a tunnel.

```bash
# port-forward svc/fortio = a tunnel from the bastion to the generator's service in the cluster
#   8081:8080 — the left number is the port on your bastion, the right one the service port in the cluster
# Port 8081 is used because 8080 might be taken by something else on your machine.
# Don't close the window: the tunnel lives as long as the command runs. To stop it — Ctrl+C.
kubectl port-forward svc/fortio 8081:8080
```

Open <http://localhost:8081/fortio>. Fill in:

| Field | Value |
|---|---|
| URL | `http://passes-api.default.svc.cluster.local/employee?id=42` |
| QPS | `20` |
| Duration | `20s` |
| Connections | `16` |

Click **Start**. A latency histogram will be drawn at the bottom. It's clearer than the numbers:
you can see all the requests gathered into one narrow band around 800 ms — meaning it's slow not
"sometimes" but always and by the same amount.


<details>
<summary><b>Why p50 and p99, not the average latency</b></summary>

Average latency is the most deceptive metric in operations.

Imagine: ninety requests at 10 ms and ten requests at 2000 ms. The average is 209 ms, and by the
report everything looks decent. But in reality every tenth user waited two seconds and left.

**p50 (the median)** — half the requests are faster than this number, half slower. It answers the
question "how long does an ordinary user wait."

**p99** — 99% of requests are faster than this number. It answers the question "how bad does it get."
It's p99 that determines whether the guards at the checkpoint will complain: people complain not
about the average, but about that one time they had to wait.

In our measurement p50 and p99 nearly coincided — 801 and 812 ms. That's a sign the slowness isn't
random but systemic: slow exactly always. This is cured by a cache. If p50 were 10 ms and p99 were
2000 ms, the cause would be different, and a cache wouldn't help.

</details>

## Step 4. Create Redis

📍 **Where:** in the browser, in the Cozystack dashboard. Redis is a shared tenant resource, like Harbor.

Tenant → **Create application** → `Redis`.

| Field | Value | Why so |
|---|---|---|
| Name | `cache` | it goes into service names, shorter is handier |
| Replicas | `2` | one leader copy and one follower: we'll see what that gives |
| Size | `1Gi` | the employee directory will fit in memory with plenty to spare |
| Storage class | `replicated` | |
| Resources preset | leave the suggested one | |
| Version | `v8` | |
| Auth enabled | **on** (by default) | the platform generates the password itself |
| External | **off** | there's no reason to expose this cache to the outside |

Expect to wait three to five minutes for it to be ready.

⚠️ **This Redis has nothing to do with the Redis you may have seen in the Harbor creation form.**
There it's the registry's own internal cache. This one is your own, for your application.

<details>
<summary><b>How managed Redis differs from Redis installed on a VM</b></summary>

Installing Redis on a virtual machine is half an hour's work: `apt install redis`, tweak `bind`
and `requirepass`, enable it at startup. That's exactly why a managed service seems excessive.
The difference isn't in the installation but in what happens afterward.

**Replication.** You set `replicas: 2` — and got two copies of the data on different nodes plus
three sentinels watching over them. If the node with the leader copy dies, the sentinels hold an
election and make the second copy the leader. The application will survive this with a pause of a
few seconds. Assembling the same thing by hand is a day's work and then another day to verify it
really fails over, rather than just looking configured.

**Updates.** A vulnerability in Redis isn't rare. On a VM an update means `apt upgrade`, a restart,
and hope that the config survives a major-version change. Here the image update arrives together
with a platform update, and the order in which the copies restart is arranged so the service
doesn't disappear.

**Observability.** Metrics are already being collected: an exporter is running next to each
copy, the graphs are there without any effort from you. On a VM that's one more package, one more
config, and one more thing that got forgotten.

**What you give up.** Honestly: root on the machine with Redis. You can't SSH in, you can't edit
the config by hand, you can't drop your own script next to it. Anything not surfaced as an
application parameter is out of reach for you — and far from everything is surfaced. If you need a
non-standard `maxmemory-policy` or a Redis module, a managed service won't give it to you, and
you'll have to install your own on a VM. This is a real limitation, not a trifle.

</details>

## Step 5. Find the Redis address and check connectivity

📍 **Where:** on the bastion, the **management** cluster.

Redis lives in your tenant on the management cluster, and the application in your `lab` cluster.
These are two different clusters, and the first thing to do is make sure the second one can reach
the first.

Let's look at what services have appeared:

```bash
# --kubeconfig sets the access file right in the command — just once, without touching KUBECONFIG.
# This way two commands in a row can be addressed to different clusters without getting confused.
#   -n tenant-workshopXX  the namespace of your tenant
#   get svc               "show the services" — permanent addresses backed by Pods
#   | grep redis          keep only the lines with the word redis in the output
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX get svc | grep redis
```

**What you should see** — several services with telling prefixes:

| Name | What's behind it |
|---|---|
| `rfrm-redis-cache` | the leader copy (master) — written to and read from here |
| `rfrs-redis-cache` | the follower copies (replicas) — read-only |
| `rfs-redis-cache` | sentinel — the service that watches and switches roles |

⚠️ **Where the extra `redis-` in the names comes from.** The platform adds a prefix with the
service type to the application name: the `cache` application of type Redis is internally called
`redis-cache`. Hence `rfrm-redis-cache`, not `rfrm-cache`. Don't guess names — look at the output
of the command above, that's the source of truth.

We need `rfrm-redis-cache`: the cache both writes and reads, and you can only write to the leader copy.

The full name by which it's visible from your cluster is assembled like this:

```
rfrm-redis-cache.tenant-workshopXX.svc.cozy.local
```

Grab the password. 📍 **Where:** in the dashboard, the `cache` application, the secrets tab. You
need the `redis-cache-auth` Secret, the `password` key.

Now — a connectivity check. 📍 **Where:** on the bastion, the **`lab`** cluster.

In your cluster we spin up a one-off Pod with a Redis client and ask it to say the word `ping` to
Redis. If an answer comes back, then the cache in the tenant is visible from the `lab` cluster —
and that's the one and only thing we're checking right now.

⚠️ **We pass the password via the `REDISCLI_AUTH` variable, not the `-a` flag.** Anything that
ends up in a command's arguments is visible in the process list on the node and stays in the Pod's
description — which anyone with access to your namespace can read. `redis-cli` itself warns about
this, and silencing the warning instead of removing the cause is a bad habit.

```bash
export KUBECONFIG=~/lab.kubeconfig

# run redis-probe = a one-off Pod with the redis-cli client:
#   --rm --restart=Never  it did its job and deleted itself, no need to restart
#   -i --quiet            show us the output and don't print service lines
#   --env=REDISCLI_AUTH   the password goes into the Pod as an environment variable, not an argument
#   --                    to the right of these dashes is the command that goes into the Pod
#   redis-cli -h <name>   which server to connect to; the name is that same full one
#   ping                  a short "are you alive"; the answer to it is PONG
kubectl run redis-probe --rm -i --restart=Never --image=redis:7-alpine --quiet \
  --env=REDISCLI_AUTH='YOUR-PASSWORD' -- \
  redis-cli -h rfrm-redis-cache.tenant-workshopXX.svc.cozy.local ping
```

**What you should see:**

```
PONG
```

⚠️ **If instead of `PONG` you got a name resolution error** — then the internal names of the
management cluster aren't visible from your cluster. This is fixed by addressing it by IP:

```bash
# -o jsonpath='{.spec.clusterIP}' — print one field of the object: the internal address
# the platform assigned to this service. {"\n"} adds a line break.
kubectl --kubeconfig ~/.kube/config -n tenant-workshopXX get svc rfrm-redis-cache \
  -o jsonpath='{.spec.clusterIP}{"\n"}'
```

From here on, substitute the address you got in place of the name everywhere. It'll work the same;
the only downside is that if Redis is recreated the address changes, whereas the name doesn't. If
it doesn't answer by address either — write in the workshop chat, this is a testbed
configuration issue, not your mistake.

## Step 6. Turn the cache on

📍 **Where:** on the bastion, the `lab` cluster.

We change the application not with a whole manifest but with a patch — that way you see exactly
what changes. First we substitute the address of your Redis into the patch, then hand the patch to
the cluster: `kubectl patch` appends changes to an already-existing object rather than replacing
it wholesale.

```bash
# the same address substitution as before, only the placeholder is different — REDIS-ADDR

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch-broken.yaml

# patch deployment passes-api = "fix up this object with what's in the file"
#   --patch-file  where to take the changes from
# Changing environment variables means new Pods: the old ones will be replaced.
kubectl patch deployment passes-api --patch-file cache-patch-broken.yaml

# wait until the new copies become ready — otherwise we'll measure the old ones still
kubectl rollout status deployment/passes-api
```

Measure again — with the same command we measured with before turning the cache on. The
bombardment conditions must match down to the last flag, or there'll be nothing to compare:

```bash
# the same twenty requests per second, the same twenty seconds, the same sixteen connections
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

> **Stop and think before reading on.**
>
> The numbers haven't changed: the same eight hundred milliseconds. And yet not a single Pod
> crashed, there are no errors in the responses, every request returned `200`. Redis is created,
> the address is right — you just got a `PONG` from it.
>
> Where to look?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

First look at what the application itself answers: the response has fields that show whether the
cache is on and whether the answer came from it.

```bash
# the same one-off Pod with curl as before: we ask the service from inside the cluster
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  curl -s "http://passes-api.default.svc.cluster.local/employee?id=42"
```

```json
{"cache":"redis","cached":false,"took_ms":802, ...}
```

`cache: redis` — the cache is on. `cached: false` — and yet the answer didn't come from it. And
it's **always** false, no matter how many times you repeat.

Now the log. The application writes there what it couldn't do — and that's the only place where
the truth is currently visible:

```bash
# logs = "show what the application wrote to its output".
#   -l app=passes-api  across all copies with this label at once, not one named copy
#   --tail=20          the last twenty lines of each copy, not the whole log
kubectl logs -l app=passes-api --tail=20
```

```
cache unavailable (redis: NOAUTH Authentication required.), going to the directory
cache unavailable (redis: NOAUTH Authentication required.), going to the directory
```

There's the answer. We specified the Redis address but not the password. Redis requires
authentication — you turned on `Auth enabled` yourself at creation, and that's the right setting.
The application honestly tried, got refused, wrote it to the log, and went to the directory.

**Why this didn't look like a breakage.** Because there was no breakage. The application is
designed to survive the cache being unavailable: a cache speeds things up but cannot be a
condition for staying operational. In production this saves you — Redis going down doesn't take
the service down. When debugging, that same property hides the problem: everything is green, no
errors, but no faster.

**A lesson broader than this mistake.** A failure that doesn't get in the way of working is the
most expensive kind of failure. It raises no alarm and lives in production for months. Hence a
practical rule: **every accelerator must have an observable sign that it's working.** For us that's
the `cached` field in the response. If it weren't there, you'd be guessing right now.

In a real system, in this spot there's a "cache hit ratio" metric and an alert in case it drops to zero.

</details>

## Step 7. Put the password in and measure again

📍 **Where:** on the bastion, the `lab` cluster.

The Redis password lives in the management cluster, and the application needs it in yours. We
carry it over — through a shell variable, so the password doesn't end up in the command history:

```bash
# read puts what's typed on the keyboard into the REDIS_PASS variable:
#   -s  don't show what's typed on the screen
#   -r  don't treat a backslash as a special character
# Nothing will appear on screen after this line: paste the password from the dashboard and Enter.
read -rs REDIS_PASS

# create secret generic = an ordinary Secret, a set of key-value pairs.
#   redis-password              the Secret's name in the cluster
#   --from-literal=password=... create a password key in it with this value;
#                               it's the "Secret name + key" pair the patch will reference
kubectl create secret generic redis-password --from-literal=password="$REDIS_PASS"

# unset erases the variable so the password doesn't reach the next commands in this window
unset REDIS_PASS
```

Apply the full patch. It has the same Redis address plus a reference to the just-created Secret and
the lifetime of the cache entries; the walkthrough is in the spoiler right after the command.

```bash
# the same address substitution, now in the working patch file

# Linux
sed -i    's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml
# macOS
sed -i '' 's|REDIS-ADDR|rfrm-redis-cache.tenant-workshopXX.svc.cozy.local|g' cache-patch.yaml

# fix up the existing Deployment with the file's contents and wait for the new copies
kubectl patch deployment passes-api --patch-file cache-patch.yaml
kubectl rollout status deployment/passes-api
```

<details>
<summary><b>A closer look: what's inside cache-patch.yaml</b></summary>

```yaml
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: REDIS_ADDR
              value: "rfrm-redis-cache.tenant-workshopXX.svc.cozy.local:6379"
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-password
                  key: password
            - name: CACHE_TTL
              value: "60"
```

**Why a patch, not a full manifest.** A patch is "change this," not "the state should be like
this." In the file you see exactly what changes, not two hundred lines among which you have to hunt
with your eyes for the three new ones.

**Why this doesn't wipe out the other variables.** Lists in Kubernetes can merge by key. For `env`
the key is the `name` field: the three entries from the patch are added to those already there, and
the `REDIS_ADDR` entry replaces the one of the same name left over from the broken patch. Container
lists merge the same way, by name — which is why `- name: api` is mandatory; without it Kubernetes
won't understand which container you're editing.

**Why the password through `secretKeyRef`, not as text.** The value arrives from the
`redis-password` Secret at the moment the Pod starts. There's no password in the manifest itself —
and that matters, because the manifest will go into Git, where it would stay forever. The Secret
won't get into Git.

Honestly: the Secret in the cluster still sits in the clear, just in a different place. Anyone who
can read Secrets in this namespace will see the password. The real solution is an external secret
store, and that's a separate lab.

**`CACHE_TTL: 60`.** Sixty seconds is a compromise. Below — read the next spoiler.

</details>

Let's check one at a time before applying load. Two identical requests in a row for an identifier
that hasn't been asked for yet: the first is bound to be slow, the second — fast.

```bash
# the same one-off Pod with curl, but an sh shell is launched inside it:
#   sh -c '...'  run several commands passed as a single string
#   ; echo       insert a line break between the answers so they don't run together
# id=777 is used because this employee hasn't been asked for yet: it's definitely not in the cache.
kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.11.1 --quiet -- \
  sh -c 'curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"; echo;
         curl -s "http://passes-api.default.svc.cluster.local/employee?id=777"'
```

**What you should see** — two answers, and they're different:

```json
{"cached":false,"took_ms":804, ...}
{"cached":true,"took_ms":1, ...}
```

The first request is a miss: the cache was empty, it had to go to the directory, 804 ms. The
second is a hit: the answer was already there, 1 ms.

Now a measurement under load, the same command with the same flags, a third time:

```bash
# we change nothing in the bombardment conditions: only what's inside the service changes
kubectl exec deploy/fortio -- fortio load -qps 20 -t 20s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=42"
```

**What you should see:**

```
# target 50% 0.0012
# target 90% 0.0021
# target 99% 0.0043
Code 200 : 400 (100.0 %)
```

## Step 8. Tally up the gain

📍 **Where:** on a scrap of paper.

Gather three numbers into a table. Yours will differ — the testbed, the network, the neighbors
on the node:

| | p50 | p99 | What it means for the guards |
|---|---|---|---|
| Without a cache | 801 ms | 812 ms | a 12-row list opens in ~9.6 s |
| Cache on, no password | 802 ms | 815 ms | nothing changed |
| Cache working | 1.2 ms | 4.3 ms | the same list — ~0.05 s |

The difference is **several hundredfold**, and that's not a figure of speech but the quotient of
two measured numbers.

Notice what we did **not** do. We didn't rewrite the HR system. We didn't add nodes. We didn't
change a single line in the logic of the "Passes" service — we just taught it not to ask the same
thing twice. The change fit into three environment variables.

<details>
<summary><b>When a cache doesn't help, and how to see it in advance</b></summary>

A cache is not a universal speedup. It helps under one condition: **the same question is asked many
times.** Test yourself on three cases.

**Every request is unique.** If the guest list requested information about a new employee every
time, there would be no hits at all, and a trip to Redis would be added to every request. It would
get slower. You can confirm it like this — run two short series over different identifiers and look
at the first requests of each:

```bash
# two bombardments in a row over different employees, ten seconds each.
# At the start of each series the cache is empty for that key — and the first request goes to the directory.
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=1"
kubectl exec deploy/fortio -- fortio load -qps 20 -t 10s -c 16 \
  "http://passes-api.default.svc.cluster.local/employee?id=2"
```

The first requests of each series are misses. On a large set of rarely-repeated keys the cache
degenerates into overhead.

**The data changes more often than the TTL.** If an employee's information changed every ten
seconds while the TTL was set to 60, the guards would see stale data for up to a minute. A cache
always trades freshness for speed, and deciding how much freshness you can spare is not a technical
decision but a question for the customer.

**Slow not always, but sometimes.** Remember the difference between p50 and p99 from the first
measurement? If p50 is small and p99 is huge, it's not the data source that's slow but something
intermittent: garbage collection, neighbors on the node, locks in the database. A cache will mask
this but not cure it, and one day you'll be untangling the very same thing, only a year later and
with a cache on top.

</details>

<details>
<summary><b>How TTL is chosen</b></summary>

TTL is the only real parameter of a cache, and it's chosen not on technical grounds.

The question goes like this: **how long are you willing to show stale data?**

For an employee directory: a surname is changed once every few years, a department once a year.
Yesterday's department at the checkpoint won't bother anyone. The TTL could just as well be an
hour, or a day.

We set sixty seconds so the lab would be observable: wait a minute, repeat the request — you'll see
`cached: false` again, because the entry expired and went to the directory. With a TTL of a day
you'd have to take that on faith.

Edge cases:

| TTL | What you get |
|---|---|
| Too small | few hits, the cache barely works, the load on the source remains |
| Too large | fast, but users see yesterday's data and complain about something else |
| Not set at all | keys pile up, memory runs out, Redis starts evicting whatever |

The last row is the most treacherous. A cache without a TTL turns over time into a database that no
one backs up.

</details>

## Verification

📍 **Where:** on the bastion, in the same terminal window where you worked with `kubectl`.

The script goes to both clusters at once and takes them from environment variables. The first two
are mandatory, the third is the path to the tenant kubeconfig.

```bash
cd labs/07-redis

# which cluster to check the application in — your `lab`
export KUBECONFIG=~/lab.kubeconfig
# your tenant number: from it the script assembles the namespace name tenant-workshop03
export COZY_TENANT=workshop03
# where the access to the management cluster lives — there the script looks at Redis itself.
# You can leave it unset: then the script looks for ~/.kube/config, and not finding it — skips
# the checks on the management cluster and says so.
export COZY_KUBECONFIG=~/.kube/config

./check.sh
```

⚠️ **On Windows the script runs from WSL**, not from PowerShell — how to install it is written at
the start of lab 0. Without WSL you can still complete the lab, but there will be no artifact report.

The script doesn't take any manifest's word for it. It makes two requests in a row itself for a
random identifier and watches: the first should be a miss and take hundreds of milliseconds, the
second a hit and take single digits. It records the difference in the report as numbers. Along the
way it checks that the slow directory really is slow: without that the comparison would mean nothing.

## Cleanup

Everything will be needed in the following labs — we're not deleting anything now.

When you're done with all the labs:

```bash
# delete -f = remove from the cluster exactly the objects described in the files
kubectl delete -f passes-api.yaml -f hr-legacy.yaml -f fortio.yaml
# the Secret was created by a command, not a file — we delete it by name
kubectl delete secret redis-password
```

Redis itself is deleted through the dashboard, like an ordinary application.

Deleting the cache is a cheap and almost safe operation, and that's a distinct property of caches:
**a cache holds no data that exists nowhere else.** Everything in it can be recovered with a trip
to the source. Losing Redis means losing speed for a few minutes, while it fills up again — but not
losing information. With a database it won't work that way, and in the lab about the database you'll
come back to this.

## What we can do now

- Provision a managed Redis and explain what the replication you didn't configure gives you
- Measure latency before and after a change, rather than talking about it
- Read p50 and p99 and understand why the average latency deceives
- Choose a TTL based on how much staleness the customer tolerates
- Find the failure that doesn't get in the way of working — the most expensive kind of failure

## And in vSphere this would be

There's no counterpart to this task in vSphere, and that's worth saying plainly. A cache isn't an
infrastructure object but part of the application's architecture. The hypervisor can't cache the HR
system's answers and shouldn't be able to.

What you'd do in the world of virtual machines: a request for a VM for Redis, installation,
configuring `requirepass`, configuring autostart, then — if you get around to it — a second VM for
the replica, sentinel, verifying failover. Days of work, of which the cache proper takes half an
hour and the rest is scaffolding. That's where a habit familiar to any administrator comes from:
"let's go without a replica for now, we'll add it later." Later, they don't add it.

The difference isn't that Redis installs faster here. The difference is that the replica, failover,
metrics, and updates arrive by default, and "without a replica for now" never comes up as an option.

**Where vSphere is more convenient, honestly.** Three things.

**Full control.** On your own VM you can install any version of Redis, any module, any
`maxmemory-policy`, and your own monitoring script alongside. Here you have access only to what's
surfaced as application parameters — and far from everything is surfaced.

**Diagnostics.** When Redis on a VM behaves strangely, you SSH in and look at `redis-cli INFO`,
`SLOWLOG`, the system counters. Here there's no SSH, and getting to the same information has to go
through `kubectl exec` and metrics — slower and at lower resolution.

**Predictability of neighbors.** A VM with Redis means guaranteed cores and memory that you see in
vCenter. A managed service lives on shared nodes next to someone else's workload; limits protect
it, but "why is it two milliseconds slower today" will take you longer to figure out than it would
on a dedicated machine.
