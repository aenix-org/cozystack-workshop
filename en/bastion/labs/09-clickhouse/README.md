# Lab 9 · Analytics over a million rows

| | |
|---|---|
| **Time** | 45 minutes |
| **What it proves** | A report over a million records is computed in milliseconds, and setting it up takes ten minutes |
| **What you'll need** | The cluster from lab 0 and `~/lab.kubeconfig`; access to your tenant's dashboard; a tenant number of the form `workshopXX`; the ability to read SQL |

> ⚠️ **A dense lab that requires reading SQL. Don't schedule it right after lab 8.**

## Why this matters

The "Pass" service has been running for six months now. Management shows up with a question
that sounds harmless:

> How many guests do we get a month, is it going up or down, and what hours is there a queue at
> the entrance? We'd like to look once a month, ideally every day.

The database where the passes themselves live doesn't hold that — it has current requests, not
years of history. The history lives in the entry log: every turnstile swipe over the whole time
the service has run. That's already a million rows, and it will keep growing.

Then the familiar begins. Someone writes a `GROUP BY` query against the production database; it
runs for two minutes and takes the pass service down for those two minutes. Someone suggests
exporting to Excel — and hits the row limit. Someone sets up a nightly export into a separate
database, and six months later no one remembers why the numbers in the report disagree with reality.

The right answer is **a separate database for analytics, built differently**. Not "the same one,
but on another server," but different on the inside. In this lab we'll spin up ClickHouse, load a
million entry records into it, and see how long the report takes to compute.

Along the way we'll work out **why a columnar database is fast at analytics and slow at pinpoint
operations** — because the second half matters as much as the first, and not knowing it is exactly
what leads people to put ClickHouse where it isn't needed.

Every term in this lab is explained the first time it appears, and the next section is a glossary
of the ones already introduced.

## Glossary

| Term | What it is | Like… but |
|---|---|---|
| **OLAP** | A workload of "few queries, but each one reads millions of rows" | **A quarterly vRealize report**, but the breakdown is invented at the moment the question is asked, not planned in advance |
| **Columnar DBMS** | Stores each field as a separate stream | **No direct analog**, but it reads only the fields you ask for. Changing a single value, though, is expensive |
| **ClickHouse** | A columnar DBMS; here, a managed service from the catalog | not a replacement for PostgreSQL but a complement to it |
| **MergeTree** | The main way tables are stored in ClickHouse | data sits in parts, and parts are periodically merged into larger ones |
| **Sorting key (`ORDER BY`)** | The order in which data is laid out within parts | **The order of files on disk**, but it's the only real "index." There's one per table, and you choose it in advance |
| **HTTP interface** | A way to talk to ClickHouse with an ordinary HTTP request | the query goes out as text in the body of a POST, the answer comes back as a table |

The rest of this lab's terms — OLTP, row-based DBMS, part, mutation, shard, replica, Keeper —
are introduced as we go, in the step where they're first needed. There's no need to memorize them
now: divorced from the action they won't stick.

<details>
<summary><b>If you'd rather see the whole list at once</b></summary>

| Term | What it is | Like… but |
|---|---|---|
| **OLTP** | A workload of "many small operations": create a request, change a status | **vCenter working with its own database**, but each operation touches a handful of rows — there are just a lot of them |
| **Row-based DBMS** | Stores records whole, row after row | **Files on a datastore: each one sits whole**, but that's exactly why a row is easy to change and a column is hard to sum quickly |
| **Part** | A chunk of data on disk produced by a single insert | you don't touch them by hand, but their number and size explain the behavior |
| **Mutation** | A deferred change or deletion of rows | it isn't done in place: it rewrites whole parts, in the background |
| **Shard** | A portion of the data on a separate set of servers | about volume, not about reliability |
| **Replica** | A full copy of the data | **A datastore replica**, but about reliability, not volume |
| **Keeper** | The service through which copies coordinate among themselves | **A quorum disk**, but needed only when there's more than one copy |

</details>

## What's in the lab folder

You already have all the files — you got them with the repository. There's nothing to create or
retype: wherever it says `kubectl apply -f name.yaml` below, the file comes from here.

```bash
cd labs/09-clickhouse
```

| File | What it is | When you'll use it |
|---|---|---|
| `clickhouse.yaml` | The order for an analytics database — the same as the button in the dashboard | you apply it **in the tenant**, not in the `lab` cluster |
| `01-schema.sql` | The table for entry events | you run it in the database |
| `02-generate.sql` | Generation of a million rows, so there's something to compute | you run it next |
| `03-report.sql` | The report itself — "how many guests and when the peaks are" | you run it last |
| `check.sh` | A check that the report really computes, and in a reasonable time | you run it at the end of the lab |

## Step 1. Order ClickHouse

📍 **Where:** in the browser, in the Cozystack dashboard, in your tenant.

Tenant → **Create application** → `ClickHouse`.

| Field | Value | Why |
|---|---|---|
| Name | `analytics` | short — you'll be typing it into addresses later |
| Replicas | **1** | a training testbed. These are copies of the **server**, not of the data — see the warning below |
| Shards | **1** | a million rows is little. You shard when the data won't fit on one server |
| Size | `5Gi` | a million rows takes a few megabytes; the rest is headroom |
| Log storage size | `2Gi` | the volume for the server's own text logs, `/var/log/clickhouse-server` |
| Log TTL | `15` | the query log older than fifteen days is discarded |
| Storage class | `replicated` | the data will land in three copies on different nodes |
| Resources preset | `u1.small` | 1 processor, 4 GB. Groupings are computed in memory |
| Users | user `analyst`, make up a password | this is the user we'll work as |
| ClickHouse Keeper → enabled | **turn off** | Keeper coordinates copies among themselves. There's one copy — nothing to coordinate |

> ⚠️ **A server copy is not a data copy.** The `Replicas` field brings up several ClickHouse
> servers, but the tables themselves are not replicated: an ordinary `MergeTree`, which we'll
> create in the next step, lives on the server where it was created. Set two replicas with such a
> table and the inserts will go to one server, while queries will land now on it, now on its empty
> neighbor.
>
> For the data to actually be duplicated, you create the table as `ReplicatedMergeTree`, and
> coordination needs Keeper turned on. That's a separate topic, and it's pointless in a training
> testbed — but you need to know about this difference before you set a two in production.

⚠️ **Make up a proper password and write it down.** You'll need it later, both in commands and in
the check script. You can look it up afterward in the dashboard: application `analytics` →
the **Secrets** tab → `clickhouse-analytics-credentials`.

⚠️ **Keeper is on by default, and that's the right default.** As soon as there's more than one
copy, they need a place to agree on who wrote what. We have one copy, and three Keeper copies would
waste the testbed's resources for nothing. If you don't see this checkbox in your form, expand the
section with the additional parameters.

### A closer look: what's inside clickhouse.yaml

The lab folder contains `clickhouse.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: ClickHouse
metadata:
  name: analytics
  namespace: tenant-workshopXX
spec:
  replicas: 1
  shards: 1
  size: 5Gi
  logStorageSize: 2Gi
  logTTL: 15
  storageClass: replicated
  resourcesPreset: u1.small
  users:
    analyst:
      password: YourPasswordHere
  backup:
    enabled: false
  clickhouseKeeper:
    enabled: false
```

`apiVersion: apps.cozystack.io/v1alpha1` — the Cozystack catalog seen from the side where it looks
like an API. When you click the button, the dashboard assembles exactly this object.

`namespace: tenant-workshopXX` — **managed services live in your tenant on the management cluster,
not in the lab cluster from lab 0.** These are two different clusters, and you'll have to keep that
in mind for the rest of the lab.

`shards` and `replicas` are two different things people constantly confuse. **Shards are about
volume:** the data is split among sets of servers, each holding its own part. **Replicas are about
reliability:** each holds everything in full. A million rows is a few megabytes — there's nothing
to shard.

`users` — a map of users. ClickHouse will create `analyst` with the given password and put it in
the Secret `clickhouse-analytics-credentials`, which is visible in the dashboard.

⚠️ Alongside your user, another one will appear in this Secret — `backup`. The chart creates it
itself, for the backup mechanism. You don't need to touch it.

`backup.enabled: false` — backups aren't needed in the lab. In production it's the first thing you
turn on.

`clickhouseKeeper.enabled: false` — see above, about the single copy.

This file is applied **not to the lab cluster** but to the tenant:

```bash
# --kubeconfig names the access file explicitly and overrides the KUBECONFIG variable.
# So the order goes to the tenant on the management cluster, not to the lab cluster.
kubectl --kubeconfig ~/.kube/config apply -f clickhouse.yaml
```

Management access to the tenant is already set up on this bastion — the file `~/.kube/config`
(token-based, no browser opens). There's nothing to fetch or save.

Wait until it's ready. That's two to four minutes: the server comes up, the volume is created, the
user is set up.

## Step 2. Set up a working Pod

📍 **Where:** on the bastion, in the lab cluster.

Here we need to stop and understand the layout.

**A Pod** is the smallest unit of execution in Kubernetes: one or more containers that always live
and die together. The closest analog from vSphere is a virtual machine, only without its own
operating system and without its own disk. From here on this word comes up constantly.

**ClickHouse lives in your tenant on the management cluster.** Your role in the tenant lets you
order and delete services, but not run your own Pods there or forward ports. This isn't a breakage
but a boundary.

**Your work area is the lab cluster from lab 0.** That's where we'll reach ClickHouse from, over
its internal address:

```
chendpoint-clickhouse-analytics.tenant-workshopXX.svc.cozy.local:8123
```

Let's break the name down into parts:

| Part | What it means |
|---|---|
| `chendpoint-` | a prefix the ClickHouse operator adds to its service |
| `clickhouse-` | a prefix the Cozystack catalog adds to the application name |
| `analytics` | the name you set in the dashboard |
| `tenant-workshopXX` | your tenant. Substitute your own number |
| `svc.cozy.local` | the internal-name zone of the management cluster |
| `8123` | the HTTP interface port. There's also 9000 — for the native protocol |

Bring up the working Pod. Substitute your tenant number and your password:

```bash
# Everything from here happens in the lab cluster, so we switch kubectl to it.
export KUBECONFIG=~/lab.kubeconfig
# run creates a single Pod from the given image — a disposable little machine inside the cluster.
# The image ships curl, and that's enough: a separate ClickHouse client won't be needed.
#   --restart=Never  don't bring it up again when the command inside finishes
#   --env=CH_URL     the address of the storage's HTTP interface; the trailing slash is required
#   --env=CH_AUTH    the "user:password" pair for ordinary HTTP authentication
#   --command --     everything after the two dashes is the command the Pod will run
# sleep 86400 = "do nothing for a day": the Pod is needed only as a workspace.
kubectl run ch-workbench \
  --image=curlimages/curl:8.11.1 \
  --restart=Never \
  --env=CH_URL="http://chendpoint-clickhouse-analytics.tenant-workshopXX.svc.cozy.local:8123/" \
  --env=CH_AUTH="analyst:YourPasswordHere" \
  --command -- sleep 86400
# wait holds the terminal until the Pod starts, but no longer than two minutes.
kubectl wait --for=condition=Ready pod/ch-workbench --timeout=120s
```

**Why the address and password are Pod variables rather than inline in the command.** Everything
you type into `kubectl exec` ends up in your shell's history and in the process list on the node.
The Pod's variables are set once, and after that the password never appears in commands.

⚠️ **This doesn't solve the problem completely, and it's more honest to say so up front.** A value
passed through `--env` stays in the Pod's description: it's visible to anyone with the right to
read Pods in your namespace, it sits in the cluster's database, and it lands in the audit log. For
a training testbed that's acceptable; for a production one it isn't: there the password goes into a
separate cluster object (`Secret` — an object meant for sensitive values) and is attached by a
reference to it, while the object itself is filled from a secrets store. That's what the lab on
secrets is about.

Now let's set up a short command so we don't have to type `curl` every time. First let's take apart
what it's made of.

<details>
<summary><b>Taking this command apart, piece by piece</b></summary>

`kubectl exec -i ch-workbench` — run something inside the working Pod. The `-i` flag forwards
standard input inside: without it the query won't make it to ClickHouse.

`sh -c '…'` in single quotes — the string is passed inside as is, and `$CH_AUTH` is expanded
**inside the Pod**, from the Pod's variable. Your bastion doesn't see these values and doesn't
write them into command history.

`curl -sS` — quietly, but do report errors. `-s` removes the progress indicator, `-S` brings back
the error messages that `-s` would otherwise swallow.

`-u "$CH_AUTH"` — the username and password. ClickHouse accepts ordinary HTTP authentication.

`--data-binary @-` — "take the request body from standard input as is." This is exactly how SQL
gets into ClickHouse: **the query is the body of an ordinary POST request**, not some special
protocol. Hence a corollary: to reach ClickHouse you don't need a driver. `curl` is enough, and
that often helps when you're troubleshooting.

`?default_format=PrettyCompact` — the form in which to return the answer. `PrettyCompact` is a
table for a human. There are more than thirty formats; below we'll need `JSON`.

</details>

```bash
# We define ch — a short name for a long command. From here "ch" means: send to
# ClickHouse the SQL that arrives on standard input, and show the answer as a table.
# The name lives until you close this terminal window; in a new window define it again.
ch() {
  kubectl exec -i ch-workbench -- sh -c \
    'curl -sS -u "$CH_AUTH" --data-binary @- "$CH_URL?default_format=PrettyCompact"'
}
```

Let's check the connection:

```bash
# echo prints a string, | passes it to ch's input. SELECT version() is the cheapest
# query possible: the server reads nothing from disk, it just names its version.
echo 'SELECT version()' | ch
```

**What you should see** — the ClickHouse version number in a little frame.

⚠️ **If the command is silent or fails with `Could not resolve host` / `Connection refused`** —
there's no point going further. Common causes, in decreasing order of likelihood: you didn't
substitute your own number for `workshopXX`; the application in the dashboard isn't ready yet; a
typo in the service name. If the answer is `Authentication failed`, the connection is there but the
password is wrong: recreate the Pod with the right `CH_AUTH`.

Windows PowerShell users, your version:

```powershell
# $input — what came into the function through the pipeline on the left.
# The backtick at the end of a line continues the command onto the next line.
function ch {
  $input | kubectl exec -i ch-workbench -- sh -c `
    'curl -sS -u "$CH_AUTH" --data-binary @- "$CH_URL?default_format=PrettyCompact"'
}
"SELECT version()" | ch
```

## Step 3. Create the entry-log table

📍 **Where:** on the bastion, in the lab cluster.

We set up a table for the entry log: one row per turnstile swipe. The file `01-schema.sql` is in
the lab folder, and it's worth reading before you apply it — two lines in it determine which
queries will turn out fast later and which won't.

<details>
<summary><b>Walking through the schema line by line</b></summary>

```sql
-- IF NOT EXISTS — don't complain if the table already exists. The file can be applied twice.
CREATE TABLE IF NOT EXISTS passes
(
    pass_id      UInt64,                 -- the pass number
    created_at   DateTime,               -- when the person went through the turnstile
    guest_name   String,                 -- the guest's name: everyone's is their own
    host_dept    LowCardinality(String), -- the host's department: few values
    entrance     LowCardinality(String), -- the entrance: there are three
    pass_type    LowCardinality(String), -- one-time, weekly, vehicle
    duration_min UInt16                  -- how many minutes the guest stayed inside
)
ENGINE = MergeTree               -- how to store: parts on disk, merging in the background
ORDER BY (created_at, entrance)  -- what order to put the data in; also the index
```

`UInt64`, `UInt16` — unsigned integers of 8 and 2 bytes. In ClickHouse you choose the size of a
type deliberately: a billion rows times four extra bytes is four gigabytes. For a duration in
minutes, two bytes is more than enough.

`LowCardinality(String)` — a string with few distinct values. We have three entrance names and
five departments. ClickHouse stores such fields as a dictionary: on disk there are numbers, not
words repeated a million times. The saving is enormous, and we'll see it in figures.

⚠️ **The rule is this:** up to a few thousand distinct values — `LowCardinality`; more than that —
a plain `String`. Wrapping a guest's name, which is almost always unique, in `LowCardinality` means
making things worse: the dictionary would grow larger than the data itself.

`ENGINE = MergeTree` — the main way of storing. Each insert puts a new **part** on disk, and parts
are merged into larger ones in the background. Hence, by the way, an important practical rule: you
should insert **in batches of many rows**, not one at a time. A million single-row inserts would
create a million parts and take the server down.

```sql
ORDER BY (created_at, entrance)
```

This is the most important line in the file, and you choose it before you start writing data.

`ORDER BY` sets **the order in which the data physically sits on disk**. It also works as the only
real index: ClickHouse keeps marks every few thousand rows and uses them to figure out which parts
of the file it can skip reading entirely.

The query "how many entries were there in March" turns into "read this stretch of the file." The
query "find the entry with number 424242" turns into nothing: `pass_id` isn't in the sorting key,
so it will have to read the whole column. We'll see this in a separate step, and it isn't a flaw in
the implementation but a direct consequence of the design.

**An analogy from a familiar world.** The sorting key is like deciding what order to file paper
passes in the archive: by date or by surname. File them by date and the March folder is pulled out
instantly, while a particular Ivanov is found by going through them one by one. And no one is going
to refile a million sheets after the fact.

</details>

**Apply it.**

```bash
# < reads the file and feeds it to ch's input, that is, sends the file's contents
# to ClickHouse in a single query. CREATE TABLE returns an empty answer — that is success.
ch < 01-schema.sql
```

## Step 4. Generate a million records

📍 **Where:** on the bastion, in the lab cluster.

We have no entry data, and we need a million. We'll generate it right inside ClickHouse — no
exports, scripts, or intermediate files. First let's look at what the generator is made of.

<details>
<summary><b>Walking through the generator line by line</b></summary>

```sql
INSERT INTO passes
SELECT …
FROM numbers(1000000)
```

`numbers(1000000)` — a built-in generator table: a million rows with a single column `number` from
0 to 999999. It reads nothing from disk, it doesn't exist in nature, it's computed on the fly. This
is a standard trick: any test data in ClickHouse is made this way.

```sql
    number AS pass_id,
```

The pass number. Unique, because `number` is unique.

```sql
    addDays(
        toDateTime('2026-01-01 00:00:00'),
        toUInt16(sqrt(cityHash64(number, 'day') % 57600))
    )
```

`cityHash64(number, 'day')` — a fast hash function. From a row's number it makes a pseudo-random
number, and the same input always yields the same result. The second argument, `'day'`, is the
"salt": with a different salt the same number yields a different result. That's how, from a single
`number`, we make as many independent random values as we like.

`% 57600` gives a number from 0 to 57599, and `sqrt` of it gives 0 to 239, that is, a day within
eight months. The square root here isn't for looks: it **concentrates the data toward the end of
the period**. Guests grow more numerous over time — as in life, and that's exactly what management
wants to see in the report.

```sql
            [8, 9, 9, 10, 10, 10, 11, 11, 12,
             13, 14, 14, 15, 15, 15, 16, 17, 18][1 + cityHash64(number, 'hour') % 18]
```

The hour of arrival. Instead of a uniform "8 to 18" we take a value from an array where the hours
repeat with different frequencies: ten appears three times, fifteen three times, eight just once.
This produces **two pronounced peaks** — before lunch and after. Those are exactly what management
asked us to find, and it's good when the test data contains what we're about to look for.

⚠️ Array indexing in ClickHouse starts at one, not zero. Hence the `1 + …`.

```sql
    ['North', 'North', 'North',
     'South', 'South', 'West'][1 + cityHash64(number, 'entrance') % 6] AS entrance
```

The same trick for an uneven distribution: the north entrance gets half the flow, the south a
third, the west the remainder. Uniform data looks implausible in reports and shows nothing.

```sql
    toUInt16(30 + cityHash64(number, 'duration') % 300) AS duration_min
```

Visit duration from 30 to 329 minutes. `toUInt16` is needed because the column's type is declared
explicitly, while the result of the arithmetic is wider.

**How long it took.** A million rows were generated and written in seconds, entirely inside the
server. The data didn't travel over the network, didn't pass through your bastion, and didn't sit
in an intermediate file. Compare that with the usual way of making test data — a script that
inserts one row at a time.

</details>

**Apply it.**

```bash
# The file holds a single INSERT … SELECT: ClickHouse will invent a million rows itself and write them,
# without ever leaving the server.
ch < 02-generate.sql
```

**What you should see** — an empty answer and the prompt returning after a few seconds. An empty
answer from `INSERT` is success.

Let's check what we got:

```bash
# count() with no conditions answers the question "how many rows are in the table in total."
echo 'SELECT count() FROM passes' | ch
```

**What you should see** — `1000000`.

## Step 5. The report management came for

📍 **Where:** on the bastion, in the lab cluster.

The very report management came for: how many guests in each month, how long a visit lasts on
average, which hour people arrive at most often, and which entrance is busier. The file
`03-report.sql` is a single query; we take it apart before running it.

<details>
<summary><b>Walking through the report line by line</b></summary>

```sql
-- One report row for each month that occurs in the data.
SELECT
    toStartOfMonth(created_at)          AS month,        -- which month to assign it to
    count()                             AS guests,       -- how many entries in it
    round(avg(duration_min))            AS avg_minutes,  -- average visit duration
    topK(1)(toHour(created_at))[1]      AS peak_hour,    -- the most frequent hour of arrival
    topK(1)(entrance)[1]                AS busiest_entrance  -- the most frequent entrance
FROM passes
GROUP BY month   -- collapse all rows of one month into a single answer row
ORDER BY month   -- output the months in ascending order
```

`toStartOfMonth` turns an exact time into the first day of the month. A classic trick for grouping
by period: instead of "group by year and month" — a single value that we both group and sort by.

`count()` — how many rows fell into the group. That's exactly "how many guests per month."

`topK(1)(x)[1]` — the most frequent value of `x` in the group. `topK(1)` returns an array of one
element, `[1]` pulls it out. That's how both the peak hour and the busiest entrance end up in a
single report row.

It's worth noting separately what the query doesn't have: subqueries, temporary tables, or joins.
Everything is computed in a single pass over the data.

</details>

**Apply it.**

```bash
# One grouping over the whole table. The answer will have as many rows as there are months
# that occur in the data.
ch < 03-report.sql
```

**What you should see** — eight rows, one per month, with a growing number of guests.

Now the main thing — **how long it took to compute**. The `JSON` format at the end of the query
adds a statistics block to the answer:

```bash
# <<'SQL' … SQL — a way to pass multi-line text to a command's input, without a file.
# The quotes around SQL mean "leave the contents alone": otherwise the shell would try
# to interpret the characters inside the query as its own.
ch <<'SQL'
-- The same report, trimmed to two columns: month and guest count.
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM passes
GROUP BY month
ORDER BY month
FORMAT JSON  -- return the answer not as a table but as JSON: it contains a statistics block
SQL
```

Scroll the output to the end:

```json
    "statistics": {
        "elapsed": 0.0089,
        "rows_read": 1000000,
        "bytes_read": 4000000
    }
```

**A million rows, about nine milliseconds.** Your figure will be your own, but the order is the
same — single or tens of milliseconds.

<details>
<summary><b>How this same report would be done on an ordinary database</b></summary>

Take the familiar scenario: the entry log sits in PostgreSQL or MS SQL, right next to the pass
service itself.

**What happens to the query.** A row-based database stores a record whole: number, time, guest
name, department, entrance, type, duration — all in a row, one after another. To compute `count()`
by month it has to go through every row, which means **reading all the fields from disk**,
including the guest names that don't figure in the report. On a million rows that's tens of
seconds; on ten million, minutes.

You can get around this with an index on `created_at`, a covering index, a materialized view, or a
pre-aggregated table. Each of these solutions works, and each one means: someone had to **know in
advance which report would be asked for**. Ask for a different breakdown and it's back to square
one.

**What happens to the service.** A heavy query competes for disk and memory with the production
workload. While the report is computing, the guards at the entrance see a spinning indicator.
That's where the rule "reports only at night" comes from, and from it — a read replica, a nightly
export, mismatched numbers, and the question "why does the report show yesterday's data."

**What people do in practice.** They stand up a second database next to it, built for analytics,
and pour the data into it. That's exactly what we just did, except the second database came up in
ten minutes from a catalog rather than over a quarter with a rollout project.

| | Row-based (PostgreSQL) | Columnar (ClickHouse) |
|---|---|---|
| Find a pass by number | microseconds, via the index | reads the whole column |
| Change the status of one pass | microseconds | rewrites parts in the background |
| Count guests by month | seconds or minutes | milliseconds |
| Add a row | routine | better in a batch; one at a time is bad |
| Transactions | full-fledged | none in the usual sense |

Neither column is "better." These are tools for different work, and the right answer is almost
always both, each in its place.

</details>

## Step 6. Why it's fast: a look at the columns

📍 **Where:** on the bastion, in the lab cluster.

The word "columnar" sounds abstract until you see the figures.

```bash
ch <<'SQL'
-- We ask ClickHouse itself how much space each column of the table takes.
SELECT
    name,                                                    -- the column's name
    formatReadableSize(data_compressed_bytes)   AS on_disk,  -- how much sits on disk
    formatReadableSize(data_uncompressed_bytes) AS raw,      -- how much it would be without compression
    round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio  -- how many times it compressed
FROM system.columns   -- a system table: in it ClickHouse describes itself
WHERE database = currentDatabase() AND table = 'passes'   -- only our table
ORDER BY data_compressed_bytes DESC   -- the heaviest columns on top
SQL
```

**What you should see** — roughly this picture:

```
name          on_disk    raw       ratio
guest_name    5.20 MiB   13.4 MiB  2.6
pass_id       3.81 MiB   7.63 MiB  2.0
created_at    1.20 MiB   3.81 MiB  3.2
duration_min  1.10 MiB   1.91 MiB  1.7
entrance      35.1 KiB   1.00 MiB  29.2
pass_type     41.0 KiB   1.05 MiB  26.1
host_dept     52.3 KiB   1.10 MiB  21.4
```

Your figures will be your own, but the ratios are the same.

<details>
<summary><b>What you can see here and why it explains the speed</b></summary>

**First: each field sits separately.** That's what "columnar" means. In a row-based database, the
disk goes "row 1 whole, row 2 whole, row 3 whole." Here it's "all of `created_at` in a run, all of
`entrance` in a run, all of `guest_name` in a run."

Hence the consequence the whole thing was undertaken for: **a query reads only the fields it
mentions.** The monthly report needs `created_at` and a row counter. It will read a little over a
megabyte and won't touch the guest names, which take five times as much.

A row-based database will read everything for the same query. Not because it's poorly written, but
because the fields sit intermixed: to get to the time in row 500001, you have to read the block
that holds the time together with everything else.

**Second: look at the `ratio` for `entrance`.** Twenty-nine times. A million values drawn from
three options compressed to almost nothing.

That's how `LowCardinality` works: on disk there's a dictionary of three strings and a million
small numbers, and alongside that the general compression, for which identical numbers in a row are
a gift. For `guest_name`, where every value is different, the compression is only two and a half
times.

**Third, and this breaks intuition: compression speeds things up, it doesn't slow them down.** It
seems that decompression is extra work. In practice the bottleneck is the disk, not the processor:
reading 35 kilobytes and
decompressing them is faster than reading a megabyte. That's why columnar databases compress
aggressively and win twice — on space and on time.

</details>

Let's confirm that the query really does read little. We'll count over a single small column:

```bash
ch <<'SQL'
-- We count visits longer than a hundred minutes. The query names one column out of seven — so
-- it should read only a small part of the table. We'll check that by bytes_read.
SELECT count() FROM passes WHERE duration_min > 100 FORMAT JSON
SQL
```

Look at `bytes_read` at the end of the output and compare it with the table's data volume:

```bash
ch <<'SQL'
-- We sum the uncompressed volume of all columns. That's exactly "how much data there is in total" —
-- the figure that bytes_read from the previous output should be compared against.
SELECT formatReadableSize(sum(data_uncompressed_bytes)) AS total
FROM system.columns
WHERE database = currentDatabase() AND table = 'passes'
SQL
```

⚠️ **You must compare against the uncompressed volume, not the size on disk.** `bytes_read` in the
query statistics is what the database decompressed and read — an uncompressed figure. Divide it by
`bytes_on_disk` and you get a fraction of the compressed data, and on a table with good compression
such a "fraction" easily runs past a hundred percent. The figures have to be comparable, otherwise
the number is pretty but meaningless.

The query passed over a million rows while reading a mere few percent of the data: it read
`duration_min` and didn't touch `guest_name`.

## Step 7. Finding the peaks

📍 **Where:** on the bastion, in the lab cluster.

The second half of management's question is about the queue at the entrance. We'll count how many
entries fell on each hour of the day and draw it as bars right in the terminal. The query has two
parts — we take it apart before running it.

<details>
<summary><b>Taking the query apart</b></summary>

The inner query is an ordinary grouping: how many entries fell on each hour of the day. Eleven rows
come out.

The outer one adds a picture to them. `bar(value, from, to, width)` draws a bar of
pseudo-graphics — a built-in ClickHouse function made precisely so you can look at the result in
the terminal without opening Excel.

`max(guests) OVER ()` — a window function: the maximum over the **whole result**, not over a group.
The empty parentheses after `OVER` mean "the window is the entire set of rows." It's needed so that
the longest bar is exactly fifty characters, and the rest are proportional.

Why you couldn't just write `max(guests)` without `OVER ()`: it would be an aggregate function, and
it would collapse the eleven rows into one. The window function computes the same thing but leaves
the rows in place.

</details>

```bash
ch <<'SQL'
SELECT
    hour,                                     -- the hour of the day
    guests,                                   -- how many entries fell on this hour
    bar(guests, 0, max(guests) OVER (), 50) AS chart  -- a bar of pseudo-graphics
FROM
(
    -- The inner query: an ordinary grouping by hour
    SELECT toHour(created_at) AS hour, count() AS guests
    FROM passes
    GROUP BY hour
)
ORDER BY hour   -- hours ascending, so the picture reads top to bottom
SQL
```

**What you should see** — two humps: around ten in the morning and around three in the afternoon.

The answer for management is ready: peaks at 10 and at 15, and it's exactly these hours where it
makes sense to put a second person on the entrance.

While you're at it, look at the query log — ClickHouse records every query there:

```bash
ch <<'SQL'
-- ClickHouse records every executed query in the system table system.query_log.
SELECT
    event_time,                                       -- when the query finished
    query_duration_ms,                                -- how many milliseconds it took
    formatReadableQuantity(read_rows) AS rows_read,   -- how many rows it read
    formatReadableSize(read_bytes)    AS bytes_read,  -- how many bytes it pulled up in doing so
    -- The query text: we collapse line breaks in it and take the first 50 characters,
    -- otherwise the output won't fit on the screen
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 50) AS query
FROM system.query_log
WHERE type = 'QueryFinish'  -- only finished ones: there's a separate record for the start
  AND user = 'analyst'      -- only yours, without the server's own service queries
ORDER BY event_time DESC    -- the recent ones on top
LIMIT 10                    -- and ten is enough
SQL
```

The whole history of your queries, with duration and volume read. It's an ordinary table, and it
lives in the data volume, not the log volume: `Log storage size` from the order form is about the
server's text logs, not this log. The log's retention period is set by `Log TTL`. In production
it's this very table that answers the question "why was everything slow yesterday at seven in the
evening."

⚠️ The log is flushed to disk once every few seconds, so the very latest query may not be in it
yet. Repeat the command.

## A predictable failure · Find a single pass by number

The reports are ready. Security comes with an everyday request: **find the entry with number
424242.**

The query suggests itself:

```bash
ch <<'SQL'
-- We look for a single row by pass number. SELECT * means "return all columns."
SELECT * FROM passes WHERE pass_id = 424242 FORMAT JSON
SQL
```

The row will be found. But look not at it but at the statistics at the end of the output — at
`rows_read`.

> **Stop and think before you read on.**
>
> How many rows did the database read to return one? How many would PostgreSQL read with an index
> on `pass_id`? And why is the difference exactly that large?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

`rows_read` will be about **1 000 000**. To return a single row, ClickHouse read the entire
`pass_id` column.

The reason is the one we worked through a little earlier in the lab: **the only real index in
ClickHouse is the sorting key**, and ours is `(created_at, entrance)`. The data isn't ordered by
`pass_id`, there's nothing to skip parts by, and all that's left is a full scan.

PostgreSQL with an index on `pass_id` would read a few tree pages and one row. A difference of five
orders of magnitude — and not in ClickHouse's favor.

Now the same thing, but done right. Security usually knows not just the number but also **when it
happened**:

```sql
-- The same search, but with a time frame. The condition on created_at lands
-- in the sorting key, and ClickHouse discards everything outside that day.
SELECT * FROM passes
WHERE created_at >= '2026-03-01' AND created_at < '2026-03-02'
  AND pass_id = 424242
FORMAT JSON
```

Look at `rows_read` now — a few thousand instead of a million. The condition on `created_at` landed
in the sorting key, and ClickHouse discarded every part except the needed stretch. The pass may not
be found if it was on a different day — what matters isn't the find but the number of rows read.

**A lesson broader than this error.** ClickHouse isn't a "fast database." It's a database built
for one kind of work: read many rows across a few columns and compute something. At that work it
outruns row-based databases by orders of magnitude. At the opposite — find one row, change one
field, roll back a transaction — it falls behind them by just as many orders of magnitude.

Hence a practical rule worth taking with you:

| Task | Where |
|---|---|
| Order a pass, change it, cancel it | An ordinary database next to the service |
| Find a specific pass by number | The same place |
| A yearly report, funnels, peaks, trends | ClickHouse |
| An event log, metrics, logs | ClickHouse |

Both databases in one tenant, both from the catalog, both spun up in minutes. There's no longer any
need to choose "one for everything" — and that, perhaps, is the main change compared with a world
where each new database meant a new VM and a new ticket.

</details>

## Step 8. Honestly about what's awkward here

📍 **Where:** on the bastion, in the lab cluster.

A guest changed their surname; one record needs fixing. In an ordinary database that's an `UPDATE`
and microseconds.

Note the syntax in advance: not `UPDATE passes SET …` but `ALTER TABLE … UPDATE`. This isn't a whim
of the authors but an honest warning: **what you're running is not a row update but a change to the
table.**

```bash
ch <<'SQL'
-- We change a guest's name in one row. The command returns control immediately, but the work
-- doesn't end there: ClickHouse will queue it and carry it out in the background.
ALTER TABLE passes UPDATE guest_name = 'Whitfield J.' WHERE pass_id = 424242
SQL
```

Let's see what's happening:

```bash
ch <<'SQL'
-- The queue of deferred changes to the table — another ClickHouse system table.
SELECT
    command,       -- what exactly it's been told to do
    is_done,       -- 1 if the work is finished
    parts_to_do,   -- how many parts remain to be rewritten
    create_time    -- when the task was put in the queue
FROM system.mutations
WHERE table = 'passes'
ORDER BY create_time DESC
SQL
```

<details>
<summary><b>What a mutation is and why it's expensive</b></summary>

The command returned control immediately, while the work has been queued. Such deferred work is
called a **mutation**, and it's visible in `system.mutations`: `is_done` shows whether it's
finished, `parts_to_do` — how many parts remain to be rewritten.

Why rewritten. The data sits in columns in compressed parts. You can't change a single value inside
a compressed block — the block has to be decompressed, changed, compressed, and written anew. In
practice ClickHouse rewrites **the entire part**, with all its columns.

On our million rows that's fractions of a second, and `is_done` is most likely already `1`. On a
table of a billion rows the same operation is hours of disk work and double the space usage for the
duration of the rewrite.

Hence the rules that in the ClickHouse world are taken for granted:

- **You don't change data.** You append to it. The entry log shouldn't change anyway: an entry
  either happened or it didn't
- If a record does need fixing, you write a new version of the row and take the fresh one when
  reading. There's a separate kind of table for this (`ReplacingMergeTree`)
- Deleting old data is done not with a query but with a retention period (`TTL`): "discard rows
  older than three years." Then whole parts are deleted, not individual rows
- Bulk edits are gathered into a single rare operation instead of a hundred small ones

**And what's missing here entirely: transactions in the usual sense.** Transferring money from one
account to another so that both operations apply or neither does can't be done in ClickHouse. This
isn't a gap in the implementation — it's a deliberate renunciation for the sake of read speed.
That's exactly why ClickHouse isn't placed under the pass service but alongside it.

</details>

## Verification

📍 **Where:** on the bastion, in the same terminal window where you worked with `kubectl`.

```bash
cd labs/09-clickhouse
# The script reads these three environment variables, so you must set them before running it
# and in the same terminal window.
export KUBECONFIG=~/lab.kubeconfig       # which cluster to check
export COZY_TENANT=workshop03            # your tenant number
export CH_PASSWORD='your-analyst-password'  # the one you set when ordering ClickHouse
./check.sh
```

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to install it is described
at the start of lab 0. You can complete the lab without WSL, but there'll be no artifact report.

The script checks not the fact that the service was created but the work on its merits: the table
exists, there are no fewer than a million rows, the data has pronounced peaks, the monthly report
computes in milliseconds, and a query over a single column reads a small fraction of the table.

The password doesn't make it into the report.

## Cleanup

```bash
# The working Pod stores nothing: all the work happened inside ClickHouse, and the Pod only
# passed queries along. Delete it without regret.
kubectl delete pod ch-workbench
```

ClickHouse itself is deleted in the dashboard: application `analytics` → delete.

Why this is cheap. An analytics database in classic infrastructure is a VM (more likely three),
disks, installation, configuration, monitoring, and a person responsible for all of it. You can't
give it back: the space is already allocated, the license is bought, and "what if we need it." Here
you took a service for an hour and returned it in ten seconds, and the space it occupied was freed.

⚠️ **Deleting it also removes the table.** A million rows regenerate in seconds, so in the lab it's
no loss. If you put something real in there, turn on backups first — they're a separate section in
the order form.

## What we can do now

- Explain the difference between a row-based and a columnar database not in words but in figures of
  compression and bytes read
- Spin up ClickHouse from the catalog and understand why the form has shards, replicas, and Keeper
- Choose a sorting key deliberately and predict which queries will be fast
- Generate plausible test data inside the database, without scripts or exports
- Answer the question "when are the peaks" with a query rather than an export to Excel
- Understand where ClickHouse loses, and not put it where an ordinary database is needed

## And in vSphere this would be

A separate machine for the analytics database — and it turns out almost at once that one isn't
enough: you need a second for the replica and space for the daily exports. The report "how many
guests a month" turns into an infrastructure project with its own hardware, its own monitoring, and
its own owner.

Here — a catalog entry and ten minutes, including generating a million rows.

**Where vSphere is more convenient, honestly.** A VM with a database is a machine you can walk up
to. Log in over SSH, look at top, tweak a config, drop a script next to it, take a snapshot before
a risky operation and roll back if it didn't work. A managed service doesn't give you this **on
purpose**: in the tenant you won't be allowed either to `exec` into a Pod or into the logs. You
manage the service through the order form, not through the machine underneath it.

As long as everything works, this is an advantage — fewer ways to break things. When something
behaves strangely, this limitation is felt keenly: the administrator's usual set of actions is
unavailable, and all that's left is to turn to whoever operates the platform. The query log and
metrics cover part of this pain, but not all of it, and pretending they cover all of it would be
dishonest.

And a second thing people remember later. A managed service means someone else's defaults. The
ClickHouse version, the part-merge parameters, the memory settings are chosen for you. Usually
sensibly, sometimes not for your workload, and you won't be able to change them as freely as on
your own machine.
