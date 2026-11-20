# Workshop: real-time card fraud detection on your own cloud

In two hours you build a working real-time fraud detection system for card
payments, then run it the way a bank runs production: through a traffic spike,
the loss of a database node, and a server move in the middle of the payment flow.

Everything runs on [Cozystack](https://cozystack.io), an open-source CNCF platform
that turns ordinary servers into a private cloud. You work through a shared VM,
the bastion, so all you need is a laptop with a terminal and a browser.

[Русская версия](README.ru.md)

## The story

Every time a card is used, the shop's terminal asks the card issuer one question:
approve or decline? The program that receives these requests is the **card
authorization switch**. In most banks it is old, it runs on a virtual machine,
and nobody wants to touch it. Ours is no different: it sits on a VM in your
tenant and approves everything that is below $5,000. A fraud ring would love it.

You will not rewrite the switch. You will build fraud detection around it:

```
  card terminals ──► switch (VM, legacy) ──► Kafka: auth.requests ──► scorer (your Kubernetes)
                        ▲   │                                           │  card history in Redis
                        │   │                Kafka: auth.decisions ◄────┘
                        └───┘ approve / decline in milliseconds;
                            │ no answer in 400 ms → the switch decides alone ("stand-in")
                            ▼
                     Kafka: auth.journal ──► cases ──► PostgreSQL ──► dashboard
                                               │
                                               └──► explainer: a small language model
                                                    in your cluster, "why was this blocked?"
```

| Piece | Where it runs | What it does |
|---|---|---|
| switch | VM in your tenant | answers the terminals; asks the scorer, or decides alone (stand-in) |
| Kafka | catalog service | carries every authorization request, decision and journal entry |
| Redis | catalog service | remembers each card's recent activity: how often, where, how much |
| PostgreSQL | catalog service, two replicas | the case database: every transaction and every alert |
| scorer, cases, dashboard | your own Kubernetes cluster | decide, record, show |
| explainer | your own Kubernetes cluster | Qwen2.5 0.5B on the CPU writes a plain-English reason for each block |
| terminals | your own Kubernetes cluster | shops across the US sending ordinary payments |

The source code of every piece is in [`app/`](app/). The scoring rules and their
weights are in one short file, [`app/internal/scoring/rules.go`](app/internal/scoring/rules.go).

## The route

| # | Block | Minutes |
|---|---|---|
| 0 | Log in, look at the switch | 10 |
| 1 | Order Kafka, Redis and PostgreSQL from the catalog | 15 |
| 2 | Deploy the scorer and connect the switch to it | 20 |
| 3 | A language model explains every blocked payment | 15 |
| 4 | Fraud attack | 10 |
| — | Break | 5 |
| 5 | Black Friday | 15 |
| 6 | The primary database node goes down | 10 |
| 7 | The switch moves to another server mid-flow | 10 |
| — | What's next | 10 |

## What the host gave you

One username (`dallasNN`) and one password, the same everywhere:

* **the bastion**: `ssh dallasNN@<bastion-address>`
* **the Cozystack dashboard**: https://dashboard.workshop.aenix.io
* **your fraud dashboard**, once Lab 2 is done: `https://fraud.dallasNN.workshop.aenix.io`

Everywhere below, `dallasNN` stands for your own username. On the bastion, the
files are already filled in with your number; there is nothing to replace.

The host has already prepared, in your tenant `tenant-dallasNN`:

* the **switch** VM, approving every payment;
* your own **Kubernetes cluster** `fraud`;
* the **card terminals** in that cluster, sending about 20 payments a second.

## Lab 0. Log in and look at the switch

```bash
ssh dallasNN@<bastion-address>
cd ~/workshop
ls
```

You have two kubectl contexts, one for each level of the cloud:

| Context | What it talks to | What lives there |
|---|---|---|
| `platform` (default) | Cozystack | your tenant: the VM, the catalog services, the cluster itself |
| `fraud` | your own Kubernetes cluster | the fraud detection services |

```bash
kubectl --context platform get vminstances,kubernetes
kubectl --context fraud get nodes
kubectl --context fraud -n fraud get pods
```

**You should see:** the VM `switch` and the cluster `fraud`, both ready; one node
in your cluster; one `terminals` pod running.

Now log in to the switch. It is a plain Ubuntu VM, user `ubuntu`, password `ubuntu`:

```bash
virtctl console vm-instance-switch
```

Press Enter if the screen stays empty. Inside the VM:

```bash
journalctl -u auth-switch -f
```

**You should see**, every five seconds: `100 authorizations, 0 declined`. The switch
runs in legacy mode: it declines only payments above $5,000. Stolen cards that
buy a $40 dinner get through.

Stop the log with `Ctrl-C`. Stay in the console: you will be back here in Lab 2.
To leave the console, press `Ctrl-]`.

## Lab 1. Kafka, Redis and PostgreSQL from the catalog

📍 On the bastion, outside the VM console.

The three services come from the Cozystack catalog, in the same way you would
order a managed database in a public cloud. One file orders all three:

```bash
cat manifests/01-data-services.yaml
kubectl --context platform apply -f manifests/01-data-services.yaml
kubectl --context platform get kafka,redis,postgres -w
```

**You should see:** all three move to `READY True` within three to five minutes.
Stop watching with `Ctrl-C`.

While they start, look at what you ordered in the Cozystack dashboard
(https://dashboard.workshop.aenix.io, your tenant `tenant-dallasNN`): the same three
applications, with their services and secrets. The operators behind them are
Strimzi for Kafka, CloudNativePG for PostgreSQL and the Redis operator; you did not
have to install any of them.

What each one is for:

* **Kafka** carries three topics. `auth.requests`: the switch asks "approve or
  decline?". `auth.decisions`: the scorer answers. `auth.journal`: the switch writes
  down every answer it gave, whoever made the decision.
* **Redis** is the short-term memory of every card: how many payments in the last
  minute, the last place it was seen, how many tiny "probe" payments it made.
* **PostgreSQL** is the case database. Two replicas, a primary and a hot standby:
  Lab 6 takes the primary away.

⚠️ If `apply` fails with `SchemaError … unknown model in reference`, it is the
client-side check that fails, not the cluster. Add `--validate=false`.

## Lab 2. The scorer, and connecting the switch

📍 On the bastion.

Deploy the fraud detection services into your own cluster:

```bash
kubectl --context fraud apply -f manifests/02-scoring.yaml
kubectl --context fraud -n fraud get pods -w
```

**You should see:** `scorer`, `cases` and `dashboard` in `Running`. Stop with `Ctrl-C`.

The services reach Kafka, Redis and PostgreSQL by their platform names, such as
`kafka-kafka-kafka-bootstrap.tenant-dallasNN.svc.cozy.local`. Your cluster is a
tenant of the platform, and the platform's services are on the same network.

The scorer is running, but nobody asks it anything yet: the switch still decides
alone. Go back to the switch:

```bash
virtctl console vm-instance-switch
```

Inside the VM, point the switch at Kafka and restart it:

```bash
sudo sed -i 's#^KAFKA_BOOTSTRAP=.*#KAFKA_BOOTSTRAP=kafka-kafka-kafka-bootstrap:9092#' /etc/auth-switch/env
cat /etc/auth-switch/env
sudo systemctl restart auth-switch
journalctl -u auth-switch -f
```

The short name `kafka-kafka-kafka-bootstrap` is enough: the VM's DNS search list
already holds your tenant's domain.

**You should see:** `switch started in SCORING mode`, then
`100 authorizations, 0 declined, stand-in 0.0%`. The first five seconds may show
some stand-in while the connections warm up.

Every payment now makes a round trip through Kafka to the scorer in your cluster
and back, and the terminal still gets its answer in about ten milliseconds. If the
scorer does not answer within 400 ms, the switch falls back to its old static rule,
so a slow scorer never stops a payment. Banks call this **stand-in processing**.

Leave the console (`Ctrl-]`) and open your dashboard:
`https://fraud.dallasNN.workshop.aenix.io`

**You should see:** about 20 authorizations a second, almost no declines, the
decision latency, and Kafka lag close to zero.

## Lab 3. A language model explains every blocked payment

📍 On the bastion.

A decline needs a reason a support agent can read out to the customer. A small
language model writes it. It runs inside your cluster on the CPU: Qwen2.5 0.5B
Instruct, served by llama.cpp. The model weights come into your cluster; no card
data goes out of it, and no external AI service is involved.

```bash
cat manifests/03-explainer.yaml
kubectl --context fraud apply -f manifests/03-explainer.yaml
kubectl --context fraud -n fraud rollout status deploy/explainer --timeout=5m
```

**You should see:** `successfully rolled out` within a minute or two: the pod
downloads a 400 MB model and loads it.

`cases` was already configured with the explainer's address and has been waiting
for it. Nothing is blocked yet, so there is nothing to explain. Lab 4 changes that.

## Lab 4. Fraud attack

📍 On the bastion, with your dashboard open.

A fraud ring goes after your cardholders in three ways at once:

* **card testing**: three stolen cards make dozens of tiny online payments to check
  that they work, then try a big electronics purchase;
* **impossible travel**: a card used in Dallas is used in Lagos two minutes later;
* **BIN attack**: sixty card numbers in a row from the same bank range, one dollar each.

```bash
kubectl --context fraud apply -f manifests/04-attack.yaml
kubectl --context fraud -n fraud logs job/attack -f
```

**You should see:** in the attack log, `declined` growing and `approved` staying at
zero; on the dashboard, declines rising and blocked transactions appearing with
their reason codes. A few seconds later each of them gets a plain-English
explanation from the model.

Read the rules that caught the attack:
[`app/internal/scoring/rules.go`](app/internal/scoring/rules.go). A card-testing run
is stopped by about the sixth probe, a BIN attack by about the eighth card.

## Lab 5. Black Friday

📍 On the bastion, with your dashboard open.

Traffic goes up twenty times. The terminals read their rate from a ConfigMap, so
you can change it without a restart:

```bash
kubectl --context fraud -n fraud patch configmap traffic -p '{"data":{"rate":"400"}}'
```

Watch the dashboard for a minute. **You should see:** the scorer's Kafka lag
growing, decision latency climbing past 400 ms, and the **stand-in share** going up.
Stand-in means the switch decided alone with its static rule: in a real bank that is
the moment fraud gets through, because nobody checked.

One scorer is not enough. Add more:

```bash
kubectl --context fraud -n fraud scale deploy/scorer --replicas=6
kubectl --context fraud -n fraud get pods -l app=scorer -o wide
```

**You should see:** the new scorers start, the lag drains, and stand-in goes back
to zero. If some pods stay `Pending`, your cluster is out of room: the cluster
autoscaler adds a second node, which takes a few minutes
(`kubectl --context fraud get nodes -w`).

Now try twelve:

```bash
kubectl --context fraud -n fraud scale deploy/scorer --replicas=12
```

Throughput stops growing at eight. `auth.requests` has eight partitions, and in a
Kafka consumer group one partition is read by one consumer at a time. Scaling out
a streaming system is decided when the topic is created, not when the pods are added.

Back to a normal day:

```bash
kubectl --context fraud -n fraud patch configmap traffic -p '{"data":{"rate":"20"}}'
kubectl --context fraud -n fraud scale deploy/scorer --replicas=2
```

## Lab 6. The primary database node goes down

📍 On the bastion, with your dashboard open.

Find the primary of your PostgreSQL cluster:

```bash
kubectl --context platform get pods -l cnpg.io/cluster=postgres-cases -L role
```

The pod with `role=primary` is the one every write goes to. Take it away, as if
its server had died (`--grace-period=5` skips the usual polite shutdown):

```bash
kubectl --context platform delete pod <the primary pod> --grace-period=5
kubectl --context platform get pods -l cnpg.io/cluster=postgres-cases -L role -w
```

**You should see:** within seconds, the other pod becomes `primary`; the deleted
one comes back as the new replica.

Meanwhile, on the dashboard, the database panel shows `database unavailable` for a
few seconds, and the `cases` lag grows. Payments are not affected: the switch never
talks to the database. Its journal waits in Kafka. In the `cases` log:

```bash
kubectl --context fraud -n fraud logs deploy/cases --tail=20
```

you will see `database unavailable, holding … messages, retrying`, then the backlog
written. The dashboard's reconciliation line compares what the switch journaled
with what the database stored: `missing: 0`. Not one case was lost.

## Lab 7. The switch moves to another server mid-flow

📍 On the bastion, with your dashboard open.

The server under your switch needs maintenance. In a bank that usually means a
change window at 3 a.m. Here the VM moves to another server while it keeps
answering terminals:

```bash
kubectl --context platform get vmi vm-instance-switch -o wide
virtctl migrate vm-instance-switch
kubectl --context platform get vmim -w
```

**You should see:** the migration go through `Scheduling`, `Running` and
`Succeeded`; after that, `get vmi` shows another node. On the dashboard, **terminal
errors stay at zero**: no authorization failed while the VM moved. The memory of
the running VM was copied to the new server, and the disk did not have to move: it
is on replicated storage that both servers can reach.

```bash
kubectl --context fraud -n fraud logs deploy/terminals --tail=20
```

## What's next

You built a real-time fraud detection system on your own cloud: a legacy VM, three
managed services and your own Kubernetes cluster, with a language model that never
sends data outside. Then you ran it through a traffic spike, a database failover and
a live server move.

* **Your environment stays with you for two weeks.** The bastion, the cluster and
  the dashboard keep working. Change the rules in
  [`rules.go`](app/internal/scoring/rules.go), write a new attack, break things.
* **Support chat**: the host shares the link. Ask anything about Cozystack there.
* **Certification assignment**: the host shares it at the end of the session. It is
  done in this same environment.

## If something goes wrong

| Symptom | Cause and fix |
|---|---|
| `virtctl console` shows nothing | Press Enter. The login prompt is printed only once. |
| The switch log shows `stand-in 100%` after Lab 2 | Kafka is not ready yet, or the address in `/etc/auth-switch/env` has a typo. `kubectl --context platform get kafka` must show `READY True`. |
| Dashboard returns 502 or 503 | The dashboard pod is not running yet: `kubectl --context fraud -n fraud get pods`. |
| No explanations after Lab 4 | The explainer is still loading the model: `kubectl --context fraud -n fraud logs deploy/explainer`. |
| `forbidden` on a command | Check the context: catalog services, VMs and PostgreSQL pods live in `platform`; the fraud services live in `fraud`. |
