# Workshop: real-time card fraud detection on your own cloud

In about two hours you build a working real-time fraud detection system for card payments, then run it the way a bank runs production: through a traffic spike, the loss of a database node, and a server move in the middle of the payment flow.

Everything runs on [Cozystack](https://cozystack.io), an open-source CNCF platform that turns ordinary servers into a private cloud. You work through a shared VM, the bastion, so all you need is a laptop with a terminal and a browser.

[Русская версия](README.ru.md)

## The story

Every time a card is used, the shop's terminal asks the card issuer one question: approve or decline? The program that receives these requests is the **card authorization switch**. In most banks it is old, it runs on a virtual machine, and nobody wants to touch it. Ours is no different: it sits on a VM in your tenant and approves everything that is below $5,000. A fraud ring would love it.

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

The source code of every piece is in [`app/`](app/). The scoring rules and their weights are in one short file, [`app/internal/scoring/rules.go`](app/internal/scoring/rules.go).

## The route

| Part | What you do | Minutes |
|---|---|---|
| 0 | Look around | 15 |
| 1 | Order the data services: GUI, YAML from the docs, and Git | 30 |
| 2 | Fraud scoring | 25 |
| 3 | Grow the system with the catalog | 30 |
| 4 | Production day | 30 |

The route totals 130 minutes, a little over two hours.

## What the host gave you

You have one username (`austinNN`) and one password, the same for the bastion and GitLab. Your credentials file is `~/credentials.txt` on the bastion.

| Where | Address |
|---|---|
| Bastion | `ssh austinNN@<bastion-address>` |
| Cozystack dashboard | https://dashboard.workshop.aenix.io |
| GitLab | https://gitlab.workshop.aenix.io |
| Fraud dashboard, after Part 2 | `https://fraud.austinNN.workshop.aenix.io` |

Everywhere below, `austinNN` stands for your own username. On the bastion, everything is already filled in with your number.

The host has prepared your tenant `tenant-austinNN` with the legacy switch VM and your Kubernetes cluster `fraud`. In namespace `fraud` of your cluster, card terminals send 20 payments a second to the switch. Your materials are in `~/workshop`: this README, `manifests/`, and `app/`.

Your GitLab repository `austinNN/fraud-infra` is already cloned at `~/fraud-infra`. It contains `platform/kubernetes.yaml` for your cluster and `platform/switch-vm.yaml` for the switch. Flux runs in the platform on your tenant's behalf: it applies `platform/` from `main` within about a minute of a push, using your tenant rights. Every Cozystack application you order ends up in this repository. In the GUI exercises you create the application in the dashboard first, then add its declaration to Git.

## Part 0. Look around (15 min)

### 0.1 Log in and find your tenant

📍 On your laptop, then on the bastion.

```bash
ssh austinNN@<bastion-address>
cd ~/workshop
ls
```

**You should see:** the workshop materials, including `README.md`, `manifests/`, and `app/`.

You have two kubectl contexts, one for each level of the cloud:

| Context | What it talks to | What lives there |
|---|---|---|
| `tenant` (default) | Cozystack | your tenant: the VM, catalog services, and cluster itself |
| `fraud` | your own Kubernetes cluster | the fraud detection services |

```bash
kubectl --context tenant get vminstances,kubernetes
kubectl --context tenant get resourcequota
kubectl --context tenant get applicationdefinitions
kubectl --context fraud get nodes
kubectl --context fraud -n fraud get pods
```

**You should see:** the switch VM and cluster `fraud` ready, your tenant quota, the application catalog, one cluster node, and the running `terminals` pod. A `prepull-explainer` pod in `Completed` is expected: the host used it to download the language model in advance.

The quota is your tenant's budget: `hard` is the limit and `used` is what you have consumed. The application definitions list what you can order. Open the Cozystack dashboard, select your tenant, and find the same VM, Kubernetes cluster, budget, and catalog.

### 0.2 Your infrastructure is a Git repository

📍 On the bastion and in GitLab.

```bash
cd ~/fraud-infra && ls platform && cat platform/kubernetes.yaml
```

**You should see:** `kubernetes.yaml` and `switch-vm.yaml`, then the declaration of your `fraud` cluster.

Open your repository in GitLab, `https://gitlab.workshop.aenix.io/austinNN/fraud-infra`, and log in with your bastion username and password. The platform applies the files in `platform/` from `main`. For each Git task below, save the requested files in this clone, commit them, and push to `main`; give the platform about a minute to reconcile.

### 0.3 Watch the bare switch, then attack it

📍 On the bastion, then inside the switch VM.

```bash
cd ~/workshop
virtctl console vm-instance-switch
```

**You should see:** the VM login prompt. Press Enter if the screen stays empty, then log in with user `ubuntu`, password `ubuntu`.

Inside the VM:

```bash
journalctl -u auth-switch -f
```

**You should see:** every five seconds, `5s: 100 authorizations, 0 declined, stand-in 0.0%, p99 0 ms`. The switch runs in legacy mode: it declines only payments above $5,000. Stolen cards that buy a $40 dinner get through.

Stop the log with `Ctrl-C` and leave the console with `Ctrl-]`.

Now prove that fraud gets through. A fraud ring hits your cardholders: card testing with tiny payments, a card used in two countries minutes apart, and a run on a whole range of card numbers:

```bash
kubectl --context fraud apply -f manifests/04-attack.yaml
kubectl --context fraud -n fraud logs job/attack -f
```

**You should see:** first the attack describing itself (`attack: card testing on card …4750: 36 probes of $0.50–$3.00`, `attack: impossible travel …`, `attack: BIN attack on 411111 …`), then every five seconds a line such as `sent 30, approved 30, declined 0`. Every fraudulent payment is approved: none of them is above $5,000. Stop with `Ctrl-C`. In Part 2 you run the same attack, with the same cards, against the system you are about to build.

## Part 1. Order the data services (30 min)

📍 On the bastion, outside the VM console, and in the Cozystack dashboard.

The three services come from the Cozystack catalog, in the same way you would order a managed database in a public cloud. Kafka carries requests, decisions, and the switch's journal. Redis remembers each card's recent activity. PostgreSQL stores every transaction and every alert, with a primary and a hot standby.

### 1.1 Redis: start in the GUI, then put it under Git

In the Cozystack dashboard, select your tenant `tenant-austinNN`, open the catalog, and choose Redis. Set the name to `features`, replicas to `1`, size to `1Gi`, storage class to `replicated`, and authentication off. Create it, then look at the same object from the bastion:

```bash
kubectl --context tenant get redis features -o yaml
```

**You should see:** Redis `features` with the settings you chose in the dashboard.

Write `~/fraud-infra/platform/redis.yaml` with the same declaration. Hints: kind `Redis`, `metadata.name: features`, and spec fields `replicas: 1`, `size: 1Gi`, `storageClass: replicated`, `authEnabled: false`. Take only `apiVersion`, `kind`, `metadata.name`, and these `spec` fields from the object you just inspected; leave out `status` and the generated metadata.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Redis
metadata:
  name: features
spec:
  replicas: 1
  size: 1Gi
  storageClass: replicated
  authEnabled: false
```

</details>

Commit and push:

```bash
cd ~/fraud-infra
git add platform/redis.yaml
git commit -m "Order Redis for card history"
git push
```

From now on Git is the source of truth: the object you created in the dashboard is managed from the repository.

### 1.2 Kafka: write the declaration from the docs

Use the [Kafka documentation](https://cozystack.io/docs/v1.6/applications/kafka/) to write `~/fraud-infra/platform/kafka.yaml`, named `kafka`: one broker and one ZooKeeper, both on replicated storage (5Gi and 2Gi), preset `c1.small`, and three topics `auth.requests`, `auth.decisions`, `auth.journal` with 8 partitions and 1 replica each.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Kafka
metadata:
  name: kafka
spec:
  kafka:
    replicas: 1
    size: 5Gi
    storageClass: replicated
    resourcesPreset: c1.small
  zookeeper:
    replicas: 1
    size: 2Gi
    storageClass: replicated
    resourcesPreset: c1.small
  topics:
    - {name: auth.requests, partitions: 8, replicas: 1, config: {}}
    - {name: auth.decisions, partitions: 8, replicas: 1, config: {}}
    - {name: auth.journal, partitions: 8, replicas: 1, config: {}}
```

</details>

`auth.requests` carries the switch's questions, `auth.decisions` the scorer's answers, and `auth.journal` every answer the switch gave, whoever made the decision. Eight partitions let eight scorers share the work; Part 4 will show why that number matters.

### 1.3 PostgreSQL: a primary and a hot standby

Use the [PostgreSQL documentation](https://cozystack.io/docs/v1.6/applications/postgres/) to write `~/fraud-infra/platform/postgres.yaml`, named `cases`: a primary and a hot standby, 2Gi each on replicated storage, preset `t1.micro`, a user `fraud` with password `Fraud2026`, and a database `fraud` owned by that user. Hint: `replicas: 2` means the primary plus one standby.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Postgres
metadata:
  name: cases
spec:
  replicas: 2
  size: 2Gi
  storageClass: replicated
  resourcesPreset: t1.micro
  users:
    fraud:
      password: Fraud2026
  databases:
    fraud:
      roles:
        admin: [fraud]
```

</details>

### 1.4 Commit, push, and watch

Commit both files and push:

```bash
cd ~/fraud-infra
git add platform/kafka.yaml platform/postgres.yaml
git commit -m "Order Kafka and the case database"
git push
```

Then watch the applications:

```bash
watch -n 5 kubectl --context tenant get kafka,redis,postgres
```

**You should see:** `features` (Redis) and `cases` (PostgreSQL) move to `READY True` within one or two minutes, and `kafka` within ten to twenty minutes; carry on with 1.5 and 1.6 while it starts. When the whole room orders at once, the platform installs services one after another. Stop watching with `Ctrl-C`. You can go on to Part 2 as soon as Redis and PostgreSQL are ready: the fraud services you deploy there wait for Kafka by themselves.

### 1.5 Under the hood (5 min of this part)

Look at what Cozystack made from your declarations:

```bash
kubectl --context tenant get hr
kubectl --context tenant get clusters.postgresql.cnpg.io
kubectl --context tenant get pods -l cnpg.io/cluster=postgres-cases -L role
kubectl --context tenant get svc | grep postgres-cases
```

**You should see:** Helm releases, the CloudNativePG cluster behind `cases`, its primary and replica pods, and PostgreSQL services ending in `rw`, `ro`, and `r`.

Operators keep these services running: Strimzi manages Kafka, CloudNativePG manages PostgreSQL, and the Redis operator manages Redis. Cozystack turns your application declarations into Helm releases and operator resources; the operators maintain the pods and services underneath.

### 1.6 Drift: watch reconciliation put an object back

Delete the Redis application by hand, leaving its declaration in Git:

```bash
kubectl --context tenant delete redis features
kubectl --context tenant get redis -w
```

**You should see:** `features` return within about a minute. Stop watching with `Ctrl-C`.

Reconciliation compares what exists with what Git declares and puts the missing object back. Make lasting changes in Git; a manual change does not change the desired state.

## Part 2. Fraud scoring (25 min)

### 2.1 Deploy the scorer and connect the switch

📍 On the bastion.

Deploy the fraud detection services into your own cluster. The scorer in `manifests/02-scoring.yaml` is deliberately small, with a CPU limit of `500m`, so that in Part 4 you can watch it run out of capacity:

```bash
cd ~/workshop
kubectl --context fraud apply -f manifests/02-scoring.yaml
kubectl --context fraud -n fraud get pods -w
```

**You should see:** `scorer`, `cases` and `dashboard` in `Running`. Stop with `Ctrl-C`.

The services reach Kafka, Redis and PostgreSQL by their platform names, such as `kafka-kafka-kafka-bootstrap.tenant-austinNN.svc.cozy.local`. Your cluster is a tenant of the platform, and the platform's services are on the same network.

The scorer is running, but nobody asks it anything yet: the switch still decides alone. Before you connect the switch, check that Kafka is ready:

```bash
kubectl --context tenant get kafka
```

**You should see:** `kafka` with `READY True`. If it is still starting, wait and run the command again: Kafka takes ten to twenty minutes after the push in 1.4.

Go back to the switch:

```bash
virtctl console vm-instance-switch
```

**You should see:** the switch VM console. Log in with `ubuntu` / `ubuntu`.

Inside the VM, point the switch at Kafka and restart it:

```bash
sudo sed -i 's#^KAFKA_BOOTSTRAP=.*#KAFKA_BOOTSTRAP=kafka-kafka-kafka-bootstrap:9092#' /etc/auth-switch/env
cat /etc/auth-switch/env
sudo systemctl restart auth-switch
journalctl -u auth-switch -f
```

**You should see:** `switch started in SCORING mode`, then `100 authorizations, 0 declined, stand-in 0.0%`. The first five seconds may show some stand-in while the connections warm up.

The short name `kafka-kafka-kafka-bootstrap` is enough: the VM's DNS search list already holds your tenant's domain.

Every payment now makes a round trip through Kafka to the scorer in your cluster and back, and the terminal still gets its answer in about ten milliseconds. If the scorer does not answer within 400 ms, the switch falls back to its old static rule, so a slow scorer never stops a payment. Banks call this **stand-in processing**.

Leave the console (`Ctrl-]`) and open your dashboard: `https://fraud.austinNN.workshop.aenix.io`

**You should see:** about 20 authorizations a second, almost no declines, the decision latency, and Kafka lag close to zero.

### 2.2 A language model explains every blocked payment

📍 On the bastion.

A decline needs a reason a support agent can read out to the customer. A small language model writes it. It runs inside your cluster on the CPU: Qwen2.5 0.5B Instruct, served by llama.cpp. The model weights come into your cluster; no card data goes out of it, and no external AI service is involved.

```bash
cat manifests/03-explainer.yaml
kubectl --context fraud apply -f manifests/03-explainer.yaml
kubectl --context fraud -n fraud rollout status deploy/explainer --timeout=5m
```

**You should see:** `successfully rolled out` within a minute or two: the pod downloads a 400 MB model and loads it. If the command gives up waiting, run it again.

`cases` was already configured with the explainer's address and has been waiting for it. Nothing is blocked yet, so there is nothing to explain. Step 2.3 changes that.

### 2.3 Run the attack again

📍 On the bastion, with your dashboard open.

A fraud ring goes after your cardholders in three ways at once:

* **card testing**: three stolen cards make dozens of tiny online payments to check that they work, then try a big electronics purchase;
* **impossible travel**: a card used in Dallas is used in Lagos two minutes later;
* **BIN attack**: sixty card numbers in a row from the same bank range, one dollar each.

```bash
kubectl --context fraud apply -f manifests/04-attack.yaml
kubectl --context fraud -n fraud logs job/attack -f
```

**You should see:** in the attack log, most payments `declined`. The first few probes of each stolen card are approved: one tiny payment looks like any other, and the pattern becomes clear after a handful. On the dashboard, declines rising and blocked transactions appearing with their reason codes. Within a minute or two each of them gets a plain-English explanation from the model. It is a very small model on one CPU: the explanations arrive one by one, and now and then one reads clumsily.

Read the rules that caught the attack: [`app/internal/scoring/rules.go`](app/internal/scoring/rules.go). A card-testing run is stopped by about the sixth probe, a BIN attack by about the eighth card.

## Part 3. Grow the system with the catalog (30 min)

📍 On the bastion, in your infrastructure repository, and in the Cozystack dashboard.

Fraud detection works, and now the fraud analysts come to you. They want to run any query they like over every payment the switch has answered: which merchants get the most declines, how declines change minute by minute, when the switch had to decide alone. Neither the scorer nor the case database is built for that, and heavy reports must not slow down the payment flow.

So you add an analytics database next to the system without touching it. ClickHouse reads the switch's journal straight from Kafka, as one more independent reader beside `cases` and the dashboard, and keeps every payment ready for fast queries. The reports then go to an S3 bucket the analysts can open in the browser. Both come from the same catalog and the same Git repository as everything else: the path from the payment journal to a finished report is three catalog services and one SQL file, with no code of your own in between.

### 3.1 ClickHouse for the fraud analysts

Use the [ClickHouse documentation](https://cozystack.io/docs/v1.6/applications/clickhouse/) to write `~/fraud-infra/platform/clickhouse.yaml`, named `analytics`: a single ClickHouse node (one replica, one shard) on replicated storage, 5Gi, preset `t1.medium`, and a user `fraud` with password `Fraud2026`. A single node does not need ClickHouse Keeper: find how to switch it off. Do not take `t1.small`: ClickHouse runs out of memory reading the payment journal.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: ClickHouse
metadata:
  name: analytics
spec:
  replicas: 1
  shards: 1
  resourcesPreset: t1.medium
  size: 5Gi
  storageClass: replicated
  clickhouseKeeper:
    enabled: false
  users:
    fraud:
      password: Fraud2026
```

</details>

Commit and push:

```bash
cd ~/fraud-infra
git add platform/clickhouse.yaml
git commit -m "Order ClickHouse for the analysts"
git push
```

Wait for `analytics` to be ready in the dashboard.

### 3.2 Read the journal straight from Kafka

First load [`manifests/05-analytics.sql`](manifests/05-analytics.sql) into ClickHouse. The command sends the file from `~/workshop` to the ClickHouse client that runs inside the database pod:

```bash
cd ~/workshop
kubectl --context tenant exec -i chi-clickhouse-analytics-clickhouse-0-0-0 -c clickhouse -- clickhouse-client --user fraud --password Fraud2026 --multiquery < manifests/05-analytics.sql
```

**You should see:** no errors, and at the end the output of the file's three example queries; right after loading they may still be empty.

The file creates three objects: `journal_stream`, a table that reads the Kafka topic `auth.journal`; `payments`, a MergeTree table that stores the rows; and `payments_stream_mv`, a materialized view that moves every journal entry from the first table into the second. ClickHouse reads Kafka directly, without another application in between.

Now open the same client interactively to ask your own questions:

```bash
kubectl --context tenant exec -it chi-clickhouse-analytics-clickhouse-0-0-0 -c clickhouse -- clickhouse-client --user fraud --password Fraud2026
```

**You should see:** the ClickHouse SQL prompt, connected as `fraud`. Leave it with `exit`.

Give ClickHouse a minute to catch up with the journal, then run the three example queries from the file: declines by reason per minute, the top 10 merchants by declines, and stand-in per minute. For example:

```sql
SELECT merchant, count(*)
FROM payments
WHERE decision = 'DECLINE'
GROUP BY merchant
ORDER BY count(*) DESC
LIMIT 10;
```

**You should see:** up to ten merchants with their decline counts, ordered from most to least. The other queries show declines grouped by minute and reason, and stand-in counts and shares per minute; the values depend on the traffic and attacks you ran.

### 3.3 A bucket for reports

The bucket goes straight into Git, like Kafka and ClickHouse: write `~/fraud-infra/platform/bucket.yaml` for a `Bucket` named `reports` with one user, `analytics`. Hint: `spec.users.analytics: {}`.

A bucket user is not a person: it is a separate pair of S3 access keys for this bucket. Cozystack creates the keys and stores them in a secret named after the bucket and the user. ClickHouse will write reports with these keys, so the analytics job gets access to this one bucket and nothing else.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: reports
spec:
  users:
    analytics: {}
```

</details>

Commit and push:

```bash
cd ~/fraud-infra
git add platform/bucket.yaml
git commit -m "Order a bucket for reports"
git push
```

When `reports` is ready, read its keys in the Cozystack dashboard: open Bucket → reports → Secrets → `bucket-reports-analytics-credentials`. You need `accessKey`, `secretKey`, and `bucketName`; the endpoint, `s3.workshop.aenix.io`, is already in the query. In the ClickHouse client, replace the placeholders with those values and export a report:

```sql
INSERT INTO FUNCTION s3('https://s3.workshop.aenix.io/<bucketName>/daily-report.csv', '<accessKey>', '<secretKey>', 'CSVWithNames')
SETTINGS s3_truncate_on_insert=1
SELECT merchant, count(*)
FROM payments
WHERE decision = 'DECLINE'
GROUP BY merchant
ORDER BY count(*) DESC
LIMIT 10;
```

**You should see:** `daily-report.csv` in the bucket UI at `https://bucket-reports.austinNN.workshop.aenix.io`. Open the UI and find the file.

## Part 4. Production day (30 min)

📍 On the bastion, with the fraud dashboard open.

### 4.1 Black Friday with an autoscaler

Write a `HorizontalPodAutoscaler` named `scorer` in namespace `fraud`, targeting the `scorer` Deployment. Use a minimum of 1 replica, a maximum of 8, and the CPU metric with target type `AverageValue` and value `250m`. Eight is the maximum useful number because `auth.requests` has eight partitions.

<details><summary>Solution</summary>

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: scorer
  namespace: fraud
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: scorer
  minReplicas: 1
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: AverageValue
          averageValue: 250m
```

</details>

Like the `VMPodScrape`, the HPA belongs to your own cluster: save it in `~/workshop` as `hpa.yaml` and apply it with `kubectl --context fraud apply -f hpa.yaml`. The terminals read their rate from a ConfigMap, so you can raise traffic without a restart; Kubernetes delivers the new value to the pod within a minute:

```bash
kubectl --context fraud -n fraud patch configmap traffic -p '{"data":{"rate":"200"}}'
```

**You should see:** within one or two minutes, stand-in rising to 100%, and the Scoring queue growing. Stand-in means the switch decided alone with its static rule: in a real bank that is the moment fraud gets through, because nobody checked.

Watch the autoscaler:

```bash
kubectl --context fraud -n fraud get hpa scorer -w
```

**You should see:** replicas going 1 → 2 → 4, then within about three minutes stand-in falling back to a few percent. Stop watching with `Ctrl-C`.

Think of a supermarket with eight checkout lanes: adding cashiers does not create more lanes. The partitions are the lanes and the scorers are the cashiers. `auth.requests` has eight partitions, and in a Kafka consumer group one partition is read by one consumer at a time. How far a streaming system scales is decided when the topic is created, not when the pods are added.

Optional: see the ceiling for yourself. Pin the autoscaler to twelve scorers, wait a minute, and read the last line of each scorer's log:

```bash
kubectl --context fraud -n fraud patch hpa scorer -p '{"spec":{"minReplicas":12,"maxReplicas":12}}'
kubectl --context fraud -n fraud logs -l app=scorer --tail=1 --prefix
```

**You should see:** eight scorers report payments and four report `scored 0`: the extra scorers have no partition to read. Put the autoscaler back:

```bash
kubectl --context fraud -n fraud patch hpa scorer -p '{"spec":{"minReplicas":1,"maxReplicas":8}}'
```

Back to a normal day:

```bash
kubectl --context fraud -n fraud patch configmap traffic -p '{"data":{"rate":"20"}}'
```

**You should see:** traffic returning to about 20 payments a second, with the HPA scaling down by itself after about five minutes.

### 4.2 The primary database node goes down

Find the primary of your PostgreSQL cluster:

```bash
kubectl --context tenant get pods -l cnpg.io/cluster=postgres-cases -L role
```

**You should see:** one pod with `role=primary` and the other as a replica. The primary is the one every write goes to.

Take it away, as if its server had died (`--grace-period=5` shortens the shutdown grace period):

```bash
kubectl --context tenant delete pod <the primary pod> --grace-period=5
kubectl --context tenant get pods -l cnpg.io/cluster=postgres-cases -L role -w
```

**You should see:** within seconds, the other pod becomes `primary`; the deleted one comes back as the new replica. Stop watching with `Ctrl-C`.

Meanwhile, on the fraud dashboard, the database panel shows `database unavailable` for a few seconds, and the Case management queue grows. Payments are not affected: the switch never talks to the database. Its journal waits in Kafka. Read the `cases` log:

```bash
kubectl --context fraud -n fraud logs deploy/cases --tail=20
```

**You should see:** `database unavailable, holding … messages, retrying`, then the backlog written. The dashboard's reconciliation line compares what the switch journaled with what the database stored; once the backlog is written — within a minute or two — it shows `missing: 0`. Not one case was lost.

### 4.3 The switch moves to another server mid-flow

The server under your switch needs maintenance. In a bank that usually means a change window at 3 a.m. Here the VM moves to another server while it keeps answering terminals:

```bash
kubectl --context tenant get vmi vm-instance-switch -o wide
virtctl migrate vm-instance-switch
kubectl --context tenant get vmim -w
```

**You should see:** the migration go through `Pending`, `Scheduling`, `TargetReady`, and `Succeeded` within a minute. Stop watching with `Ctrl-C`.

Check the node again:

```bash
kubectl --context tenant get vmi vm-instance-switch -o wide
```

**You should see:** the VM on another node. The memory of the running VM is copied to the new server while it works, and the disk does not have to move: it is on replicated storage that both servers can reach.

On the dashboard, **terminal errors stay at zero**. For a second or two the VM's network settles on the new server, and a few authorizations go unanswered; the terminals do what real terminals do and repeat them with the same transaction id. The dashboard counts those as **repeated by the terminal**.

```bash
kubectl --context fraud -n fraud logs deploy/terminals --tail=20
```

**You should see:** terminals continuing to send payments while terminal errors on the dashboard stay at zero.

## What's next

Your environment stays with you for two weeks: the bastion, cluster, and dashboards keep working. Change the rules in [`rules.go`](app/internal/scoring/rules.go), write a new attack, and use the same environment for the certification assignment the host shares at the end of the session. The host also shares the support chat link.

Found something wrong in the Cozystack documentation today? Open an issue or a PR in https://github.com/cozystack/website and say which page you used and what you expected.

## If something goes wrong

| Symptom | Cause and fix |
|---|---|
| `virtctl console` shows nothing | Press Enter. The login prompt is printed only once. |
| The switch log shows `stand-in 100%` after Part 2 | Kafka is not ready yet, or the address in `/etc/auth-switch/env` has a typo. `kubectl --context tenant get kafka` must show `READY True`. |
| Dashboard returns 502 or 503 | The dashboard pod is not running yet: `kubectl --context fraud -n fraud get pods`. |
| No explanations after the attack in Part 2 | The explainer is still loading the model: `kubectl --context fraud -n fraud logs deploy/explainer`. |
| `forbidden` on a command | Check the context: catalog services, VMs, and PostgreSQL pods live in `tenant`; the fraud services live in `fraud`. |
| `apply` fails with `SchemaError … unknown model in reference` | The client-side check failed, not the cluster. Add `--validate=false`. |
| Git push rejected | Run `git pull --rebase`, then push again. |
| Flux is not applying your change, or your YAML has an error | `kubectl --context tenant get kustomization platform` shows the error; fix the file, commit, and push. |
| ClickHouse reports `Memory limit exceeded` | Use preset `t1.medium`. |
