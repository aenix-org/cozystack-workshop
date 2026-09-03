# Lab 10 · Document store

| | |
|---|---|
| **Time** | 45 minutes |
| **What it proves** | Data of differing shapes can be stored without empty columns and without a separate table for every case — and you pay for it in discipline |
| **What you'll need** | The cluster from lab 0 and `~/lab.kubeconfig`; access to your tenant's dashboard; a tenant number of the form `workshopXX`; a willingness to read JavaScript code |

> ⚠️ **This lab is dense, and it asks you to read JavaScript code.** Take it on with a
> fresh head, not right after another long lab. The code is walked through line by line
> everywhere — you don't need to know the language in advance.

## Why this matters

The "Pass" service was rolled out with a single type of pass — a one-time pass for a
specific date. A month later the client came back with refinements, all of them reasonable:

| Pass type | What else is needed |
|---|---|
| One-time | date, entrance |
| Weekly | a from/to period, a list of entrances, a mark for whether the badge was returned |
| Vehicle | plate number, model, whether there's a trailer, weight, parking-space number |
| Group | organization, contact person, escort, a list of participants with their ages |

In a table with fixed columns this problem has two solutions, and both are bad.

**Solution one: a single table with every column.** You add `car_plate`, `car_model`,
`trailer`, `weight_kg`, `parking`, `valid_from`, `valid_to`, `badge_returned`,
`organization`, `contact`, `escort` — and a one-time pass has eleven empty fields out of
fifteen. Six months on there are thirty columns, nobody remembers which of them are
required for which type, and the very first `NOT NULL` field breaks half the scenarios.

**Solution two: a table per type.** Four tables instead of one, plus a fifth that ties them
together so security can show a combined list at the gate. Every new pass type means a
schema migration, a release, and sign-off. And the query "show me all passes for today"
turns into a `UNION` of four pieces that has to be edited when you add a fifth.

**The list of participants on a group pass fits neither.** It's variable in length, so it
needs yet another table with a reference back to the pass.

There's a third way: a store that doesn't require every record to have the same shape. In
this lab we'll stand up MongoDB, put four passes of four different shapes into it, and
search across them. And then we'll take an honest look at what we pay for it — because we
do pay, and not a little.

Kubernetes and MongoDB terms are explained in this lab when they first appear, and some are
collected in the little glossary below.

## Mini-glossary

| Term | What it is | Like… but |
|---|---|---|
| **Document** | A single record. A set of fields, nested objects and lists | **A table row**, but the neighboring record may have a different set of fields, and that's not an error |
| **Collection** | A set of documents | **A table**, but it has no schema by default. You can add a schema, but that's a separate decision |
| **BSON** | The binary format the documents are stored in | Like JSON, but with types: a date is a date, not a string |
| **Replica set** | Several copies, one primary, the rest take over | **An HA cluster**, but the copies vote among themselves, so you need an odd number of them |
| **`mongosh`** | The MongoDB command shell | **PowerCLI**, but it's full JavaScript, not a query language |

The remaining words in this lab — _id, Sharding, Dotted field notation, Sparse index,
Schema validator, $lookup — are introduced as we go, in the step where they're first needed.
There's no need to memorize them now: divorced from the action they won't stick.

<details>
<summary><b>If you'd like to see the whole list at once</b></summary>

| Term | What it is | Like… but |
|---|---|---|
| **`_id`** | The document's unique key | **A primary key**, but it's created for you if you don't set it |
| **Sharding** | Splitting data across replica sets | About volume, not about reliability |
| **Dotted field notation** | Reaching a nested field through a dot: `car.plate` | **A file path in a folder**, but it also reaches into lists: `members.age` |
| **Sparse index** | An index that includes only documents where the field is present | A plain necessity where the field is present in only a minority of records |
| **Schema validator** | A rule a document is required to satisfy | **Form validation before saving**, but it's turned on manually and after the fact — there's no schema by default |
| **`$lookup`** | A way to pull in data from another collection | **A JOIN**, but one-directional and noticeably more expensive: the join isn't chosen by an optimizer, it's carried out by brute force |

</details>

## What's in the lab folder

You already have all the files — you got them along with the repository. There's nothing to
create or retype: wherever it says `kubectl apply -f name.yaml` below, the file is taken from
here.

```bash
cd labs/10-mongodb
```

| File | What it is | When you'll need it |
|---|---|---|
| `mongodb.yaml` | The order for a document database — the same thing as the button in the dashboard | you apply it **in the tenant**, not in the `lab` cluster |
| `passes.js` | Filling the database with passes of different types: one-time, weekly, vehicle | you run it in the database |
| `validator.js` | Rules for validating documents — so that no junk gets into the database | you run it next |
| `check.sh` | A check that documents of different shapes sit side by side and unfit ones are rejected | you run it at the end of the lab |

## Step 1. Order MongoDB

📍 **Where:** in the browser, in the Cozystack dashboard, in your tenant.

Tenant → **Create application** → `MongoDB`.

| Field | Value | Why |
|---|---|---|
| Name | `passes` | short — you'll have to type it in addresses later |
| Version | `v8` | the current branch |
| Replicas | **1** | a training testbed. Why it's three in production is right below |
| Size | `5Gi` | four documents take up bytes, the rest is headroom |
| Storage class | `replicated` | the data will be laid down in three copies on different nodes |
| Resources preset | `s1.small` | 1 processor, 2 GB |
| Sharding | off | you shard when the data doesn't fit on a single server |
| Users | the `passapp` user, set the password **explicitly** | it's the one we'll work under |
| Databases | the `passes` database, with `passapp` in the admin role | without a role the user won't be accepted |
| External | off | we're not exposing it outward |

⚠️ **Be sure to set the password by hand and write it down.** If you leave the field empty,
the chart will generate a password itself — and put it in a secret that isn't visible in the
dashboard. You'll be left with a working database you can't connect to.

Two words you'll meet more than once from here on. **A chart** is the blueprint the platform
uses to deploy a service: a set of templates plus the values you filled in on the form. The
closest thing is a virtual machine template with a setup wizard. **A Secret** is a cluster
object that holds passwords and keys; in the dashboard it's shown as a separate tab on the
application card.

⚠️ **A user without a role means a failure at deployment.** If you create `passapp` in the
Users section but don't grant it a role in any database in the Databases section, the chart
will stop with the error "user is not assigned to any database role". This isn't a breakage
but a safeguard against a useless user, though the message isn't found right away.

⚠️ **A single copy is not MongoDB in its normal form, and it's worth understanding why.**
MongoDB is designed for a set of three replicas: they elect a primary by vote, and losing
one doesn't stop the work. A vote requires a majority, so the number of copies is made odd.
With a single copy there's no one to vote with, and for this the chart turns on a special
`unsafeFlags` mode. In the lab this saves testbed resources; in production you must not do it
this way.

### A closer look: what's inside mongodb.yaml

The lab folder contains `mongodb.yaml`:

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: MongoDB
metadata:
  name: passes
  namespace: tenant-workshopXX
spec:
  replicas: 1
  size: 5Gi
  storageClass: replicated
  resourcesPreset: s1.small
  version: v8
  external: false
  sharding: false
  users:
    passapp:
      password: YourPasswordHere
  databases:
    passes:
      roles:
        admin:
          - passapp
  backup:
    enabled: false
```

`namespace: tenant-workshopXX` — **managed services live in your tenant on the management
cluster, not in the lab cluster from lab 0.** These are two different clusters.

`users` and `databases` are two linked maps, and the link between them is mandatory.
`users` lists the accounts, `databases` lists the databases and who can do what in them.
`roles.admin` grants the right to read, write and change the structure within a single
database; `roles.readonly` — read only.

⚠️ Users are created in the service database `admin`, but privileges are granted in yours.
That's why the connection string will need `authSource=admin` — more on that separately in
the next step.

`sharding: false` — an ordinary replica set. Turning sharding on adds config servers and
routers: three or four extra pods for a data split we don't need.

This file is applied **not to the lab cluster** but to the tenant — which means the access
file needs to be the tenant one too. The kubeconfig (the file with the cluster's address and
login data) is taken from the dashboard: **Info → the Secrets tab → `kubeconfig-tenant-workshopXX`**.
Save it to `~/.kube/workshop` — this path is used in every lab.

Now we order the database as text. The command doesn't install anything itself: it hands the
order to the platform, and the platform brings up everything needed on its side.

```bash
# apply = "bring the cluster to what's described in the file".
#   --kubeconfig ~/.kube/workshop  which access file to use. Without it kubectl
#                                  will take the default access and wander off to the wrong cluster
#   -f mongodb.yaml                which file to apply (-f = file)
kubectl --kubeconfig ~/.kube/workshop apply -f mongodb.yaml
```

**What you should see** — `mongodb.apps.cozystack.io/passes created`. The word `created`
means the order was accepted, not that the database is ready.

Readiness takes three to five minutes: the server comes up, the replica set is initialized,
the users are created. You can watch how things are going like this:

```bash
# get = "show me what's there". The READY column will tell you whether the order reached a working state.
#   -n tenant-workshopXX  which namespace to look in (a namespace is a partition inside
#                         the cluster; your tenant is exactly such a separate namespace)
kubectl --kubeconfig ~/.kube/workshop get mongodb passes -n tenant-workshopXX
```

⚠️ **The `mongodb-passes-credentials` Secret in the dashboard will have an empty password
for the first few minutes.** It holds the credentials of the service account `databaseAdmin`,
and the chart fills them in only after the operator (the platform's program that drives the
order to a working state and then keeps watch over it) has created the users — that is, on
the next round of reconciling the state. Wait a few minutes and refresh the page. We won't
need this account: we work under `passapp`, whose password you set yourself.

## Step 2. Create a working Pod

📍 **Where:** on the laptop, in the lab cluster.

The layout is the same as in the other labs about managed services.

**MongoDB lives in your tenant on the management cluster.** Your role in the tenant lets you
order and delete services, but not run your own Pods there or forward ports.

**Your working ground is the lab cluster from lab 0.** That's where we'll go from, over the
internal address:

```
mongodb-passes-rs0.tenant-workshopXX.svc.cozy.local:27017
```

| Part | What it means |
|---|---|
| `mongodb-` | the prefix the Cozystack catalog adds to the application name |
| `passes` | the name you set in the dashboard |
| `-rs0` | the replica-set name. The operator names the service of the first set this way |
| `tenant-workshopXX` | your tenant. Substitute your own number |
| `svc.cozy.local` | the internal-name zone of the management cluster |
| `27017` | MongoDB's standard port |

**A Pod** is the smallest unit of execution in Kubernetes: one or several containers that
always live on the same node and share a single address. The closest analogue is a virtual
machine brought up for a single task, except it's created in seconds and shut down without
regret. We'll bring up such a Pod with the `mongo:8.0` image: inside it sits `mongosh` — the
MongoDB command shell — and you won't have to install it on your laptop.

The database address together with the username and password is written as a single line —
it's called the connection string. Let's walk through it before typing the command.

<details>
<summary><b>Walking through the connection string</b></summary>

```
mongodb://passapp:password@host:27017/passes?authSource=admin&directConnection=true
```

`mongodb://` — the scheme. Then the username, password, address, port.

`/passes` after the port — **the default database**. You connect and you're immediately in
it, without a separate command.

`authSource=admin` — **which database to look for the account itself in.** The `passapp`
user is created in the service database `admin`, while its privileges are granted in
`passes`. Without this parameter the driver will go looking for the account in `passes`,
won't find it, and will return "Authentication failed" — a message that looks like "wrong
password" and sends the search off in the wrong direction. This is the most common mistake
on a first connection to a managed MongoDB.

`directConnection=true` — "connect straight to this server, don't try to work out the makeup
of the replica set". Without this parameter the driver will ask the server who else is in
the set, and get back the internal names of the members, which don't always resolve from
outside. With a single copy there's nothing to work out, so it's simpler to say so directly.
In production with three copies it's the opposite: you don't set the parameter, because what
you want there is exactly the automatic switch to a new primary when the old one fails.

**Why the address and password go in a Pod variable rather than straight into the command.**
Everything you write in `kubectl exec` ends up in your shell history and in the process list
on the node. The Pod variable is set once, and after that the password doesn't appear in
commands.

This doesn't solve the problem entirely, and it's more honest to say so up front: a value
passed through `--env` stays in the Pod's spec — visible to anyone with the right to read
Pods in your namespace, it sits in the cluster database and lands in the audit log. For a
training testbed that's acceptable, for a production one it isn't: there you put the password
in a Secret and wire it in through `envFrom`. That's exactly what the lab on secrets is about.

</details>

Bring up the Pod. Substitute your tenant number for `workshopXX` and your password for
`YourPasswordHere`:

```bash
# KUBECONFIG — which access file kubectl uses. Here it's the lab cluster
# from lab 0: you launch your own Pods only in it, the tenant won't let you in with this.
export KUBECONFIG=~/lab.kubeconfig

# run = "create a single Pod and run this image in it". The flags that matter:
#   --image=mongo:8.0        what to run. The image contains the mongosh shell
#   --restart=Never          create exactly a single Pod, not a Deployment. Otherwise
#                            the cluster would bring it back up every time it finished
#   --env=MONGO_URI=...      an environment variable inside the Pod. The password stays in it,
#                            rather than being repeated in every following command
#   --command -- sleep 86400 what to keep the container busy with. The mongo image would by default start
#                            the database server — we don't need it, we need a live container
#                            you can step into. 86400 seconds is a day
kubectl run mongo-workbench \
  --image=mongo:8.0 \
  --restart=Never \
  --env=MONGO_URI="mongodb://passapp:YourPasswordHere@mongodb-passes-rs0.tenant-workshopXX.svc.cozy.local:27017/passes?authSource=admin&directConnection=true" \
  --command -- sleep 86400

# wait = "don't return control until the condition is met"
#   --for=condition=Ready  we wait until the Pod reports readiness itself
#   --timeout=180s         how long to wait before returning an error rather than hanging forever
kubectl wait --for=condition=Ready pod/mongo-workbench --timeout=180s
```

**What you should see** — `pod/mongo-workbench created`, followed by
`pod/mongo-workbench condition met`.

Now let's set up a short command so we don't have to type all of this every time, and check
the connection to the database:

```bash
# mo — a shortcut that lives until you close the terminal window: this is how you
# declare your own command in the shell.
#   exec        run something inside an already-running Pod
#   -i          forward standard input inside: without it you can't feed in a program
#   sh -c '...' we run a shell in the Pod so that it substitutes $MONGO_URI itself.
#               The quotes are single on purpose: the Pod should substitute the variable, not
#               your terminal — otherwise the password ends up in the command history
#   --quiet     don't print the mongosh greeting, leave only the answer
mo() { kubectl exec -i mongo-workbench -- sh -c 'mongosh --quiet "$MONGO_URI"'; }

# ping — a service request, "are you alive?". It reads and writes nothing, it checks the connection
# and that the credentials were accepted. The | sign sends this line to mongosh's input
echo 'db.runCommand({ ping: 1 })' | mo
```

**What you should see** — `{ ok: 1 }`.

`mongosh` reads the program from standard input, so this same command can swallow whole
files: `mo < passes.js`.

⚠️ **If the answer is `Authentication failed`** — the connection is there but the
credentials are wrong. Check in order: `authSource=admin` in the connection string; the
password matches the one you set in the dashboard; the username is `passapp`. To recreate the
Pod with a corrected string: `kubectl delete pod mongo-workbench` and start over.

⚠️ **If the answer is `getaddrinfo ENOTFOUND` or the connection hangs** — the name isn't
resolving. Most likely you didn't substitute your own number for `workshopXX`, or the
application in the dashboard isn't ready yet.

It's more convenient to examine the data not one command at a time but in a live shell — it
stays open, and you type queries in it one after another:

```bash
# -it instead of -i: a t is added — "give me a terminal". Hence the input prompt,
# command history on the up arrow, and highlighting. Without t the shell would silently wait for input.
kubectl exec -it mongo-workbench -- sh -c 'mongosh "$MONGO_URI"'
```

**What you should see** — a prompt of the form `passes>`: the name of the database you've
landed in.

From here on the commands in the text are shown the way you type them in this shell. To
exit — `exit`.

## Step 3. Put in four passes of four different shapes

📍 **Where:** on the laptop, in the lab cluster.

The file `passes.js` is a program for `mongosh`: it adds four passes to the database and
prints how many documents there turned out to be. There's no need to create a single table
in advance, and just below there's an explanation of why.

```bash
cd labs/10-mongodb
# The < sign feeds the file's contents into the command's input — the same thing as if you
# typed the whole text of the file by hand in the mongosh shell.
mo < passes.js
```

**What you should see** — `документов в коллекции: 4`.

<details>
<summary><b>Walking through what we put in</b></summary>

The first thing worth noticing: **there was no `CREATE TABLE`**. The `passes` collection
came into being at the moment of the first insert. It has no schema — that is, by default
MongoDB has no opinion about which fields a document may have.

Now to the documents.

**The one-time pass** — the shortest shape:

```js
  {
    type: "разовый",
    guest: "Иванов Иван Иванович",
    host: "petrov@corp.ru",
    entrance: "Северная",
    valid_on: ISODate("2026-09-01T09:00:00Z"),
    purpose: "собеседование"
  }
```

Six fields, all scalar. In a table this would be an ordinary row.

`ISODate(...)` is not a string but precisely a date. MongoDB stores documents in the binary
BSON format, where a value has a type: date, integer, floating-point, boolean, binary data.
This is an important difference from plain JSON: you can compare and sort by a date, but by
the string `"2026-09-01"` only if you're lucky with the way it was written.

**The weekly pass** — instead of `valid_on` there are now `valid_from` and `valid_to`, and
instead of a single entrance, `entrances` is now **a list**:

```js
    entrances: ["Северная", "Южная"],
    badge_returned: false
```

A list right in the field. In a table this would have needed either a separate
"pass — entrance" table or a comma-separated string that later nobody could search properly.

The one-time pass has no `badge_returned` field at all. Not `NULL`, not empty — **there is
no such field in this document.** These are different things, and they're searched for
differently.

**The vehicle pass** — a **nested object** has appeared:

```js
    car: {
      plate: "А123ВС174",
      model: "ГАЗель Next",
      trailer: false,
      weight_kg: 3500
    },
```

Everything to do with the vehicle sits inside a single `car` field. This isn't a string with
JSON inside, but a full-fledged structure: you can search by `car.plate` and build an index
on it.

**The group pass** — **a list of objects**:

```js
    members: [
      { name: "Орлов Пётр", age: 16 },
      { name: "Волкова Мария", age: 15 },
      { name: "Зайцев Илья", age: 17 }
    ]
```

A variable-length list of participants, each with their own fields. And — note — this
document **has no `guest` field**: in place of a guest there's an organization and a contact
person. The document's shape differs from the others not by one field but in essence.

This is exactly what the document model exists for. No empty columns, no four tables, no
fifth to tie them together.

</details>

## Step 4. Search across documents of different shapes

📍 **Where:** in the `mongosh` shell inside the working Pod.

Everything security and management need is ordinary queries. They all read the same way:
`db` is the database you're connected to, `passes` is the collection in it, then after a dot
comes the action, and in the parentheses is the selection condition. The condition is always
written as an object: "field — what value it should have".

**All passes for a specific date:**

```js
// find = "show the documents that match the condition"
// { valid_on: ISODate(...) } — the document's valid_on field must equal exactly this
// date. ISODate is a date, not a string: the comparison is by time, not by spelling
db.passes.find({ valid_on: ISODate("2026-09-02T07:30:00Z") })
```

**What you should see** — a single document, Kuznetsov's vehicle pass.

**Vehicle passes only:**

```js
// A condition on an ordinary string field: a whole match, there's no case-insensitivity here
db.passes.find({ type: "автомобильный" })
```

**Searching by plate number — reaching inside a nested object through a dot:**

```js
// "car.plate" — a path into the document: the plate field inside the car object.
// The quotes around the path are mandatory, otherwise JavaScript will read the dot its own way
db.passes.find({ "car.plate": "А123ВС174" })
```

<details>
<summary><b>Why this works and how it differs from "a string with JSON inside"</b></summary>

`"car.plate"` is dotted notation for a path to a field. MongoDB understands the document's
structure and can reach inside, rather than storing the nested object as a chunk of text.

The difference is practical. If `car` sat in a relational table as a `TEXT` column with JSON
inside, searching by plate would mean `LIKE '%А123ВС174%'` — a full scan without an index,
with false positives. Here it's an ordinary condition you can build an index on, and we will.

⚠️ The quotes around `"car.plate"` are mandatory: without them JavaScript will read the dot
as accessing an object property and won't understand what's being asked of it.

</details>

**Passes valid at several entrances:**

```js
// entrances is not a string but a list: ["Северная", "Южная"]. The condition is still written
// as for an ordinary field, MongoDB will check it against each element of the list itself
db.passes.find({ entrances: "Южная" })
```

Note: the condition is written as though `entrances` were an ordinary field with the value
`"Южная"`, when in fact it's a list. **MongoDB understands on its own that if a field is a
list, the condition must be checked against each element.** No separate syntax for "contains"
is required.

**Group passes that include minors:**

```js
// The path members.age leads inside a list of objects — to the age field of each participant.
// $lt = less than. A condition with $ is not a value but a way of comparing:
// "the field must be less than 16", not "the field must equal 16"
db.passes.find({ "members.age": { $lt: 16 } })
```

The dotted path works into a list of objects too: the condition is checked against each
participant. `$lt` — "less than". There are about twenty conditions of this kind: `$gt`,
`$gte`, `$in`, `$ne`, `$exists`, `$regex`, and so on.

**All passes that have a vehicle specified at all:**

```js
// $exists asks not about the value but about the very presence of the field in the document:
// "does this document have a car field at all?"
db.passes.find({ car: { $exists: true } })
```

`$exists` is that very distinction between "the field is absent" and "the field is empty". In
a table this question doesn't arise: the column is always there, the only question is `NULL`.

**A summary for management — how many passes of each type.** Here the query doesn't select
documents but computes a total over them, so the command is different — `aggregate`. Let's
walk through it before typing.

<details>
<summary><b>Walking through the aggregation pipeline</b></summary>

Aggregation in MongoDB is a **pipeline**: a list of stages, each of which takes the result of
the previous one as input. It's like a pipeline of commands in a shell, where the output of
one goes to the input of the next.

`$group` — group. `_id: "$type"` means "the grouping key is the value of the `type` field";
the dollar sign before the name says "this is a reference to a field, not a string".
`$sum: 1` — add one for each document, that is, count them.

`$sort: { count: -1 }` — order in descending order; `-1` is "descending", `1` is "ascending".

The same result in SQL — `SELECT type, count(*) FROM passes GROUP BY type ORDER BY 2 DESC`.
Shorter, more familiar, and here an honest comparison goes against MongoDB: its query
language is wordier and takes longer to master.

</details>

```js
// aggregate = "run the documents through a chain of stages". The stages go in order,
// each receiving what the previous one produced:
//   $group — sort the documents into groups by the value of the type field, and count each one
//   $sort  — order the groups by count, -1 means "descending"
db.passes.aggregate([
  { $group: { _id: "$type", count: { $sum: 1 } } },
  { $sort: { count: -1 } }
])
```

**What you should see** — four rows of the form `{ _id: 'разовый', count: 1 }`.

## Step 5. An index on a field that most don't have

📍 **Where:** in the `mongosh` shell inside the working Pod.

Security searches by plate number every day. Let's look at what this search costs right now:
the query is the same as before, but instead of documents we ask for a report on how the
database looked for them.

```js
// explain = "don't give me the documents, tell me how you looked for them"
//   "executionStats"     report mode: not only the plan, but what actually happened
//   .executionStats      we take exactly this section from the answer, so as not to read all of it
// In the report we look at totalDocsExamined — how many documents the database read,
// to return one
db.passes.find({ "car.plate": "А123ВС174" }).explain("executionStats").executionStats
```

**What you should see** — `totalDocsExamined` equals the number of documents in the
collection. The database looked through all of them to find one. With four documents this
goes unnoticed, with four hundred thousand it no longer does.

We build an index — a separate structure the database uses to find the documents it needs
without reading them all in a row:

```js
// createIndex = "build an index on this field and keep maintaining it yourself from now on"
//   { "car.plate": 1 }   on which field. 1 is "ascending" order
//   name: "car_plate"    what to name the index, so you can recognize and delete it later
//   sparse: true         only documents that have the field get into the index
db.passes.createIndex({ "car.plate": 1 }, { name: "car_plate", sparse: true })

// We repeat the same report and compare it with the previous one
db.passes.find({ "car.plate": "А123ВС174" }).explain("executionStats").executionStats
```

**What you should see** — `totalDocsExamined` equals one, and in the plan `IXSCAN` has
appeared instead of `COLLSCAN`. These are the names of the search methods: `COLLSCAN` is a
scan of the whole collection, `IXSCAN` is a lookup by index.

<details>
<summary><b>What a sparse index is and why it's here</b></summary>

`{ "car.plate": 1 }` — which field to build on; `1` means "ascending", `-1` — descending.
For an exact-match search the direction doesn't matter; for sorting it does.

`sparse: true` — **only those documents that have the field get into the index.**

Without this flag MongoDB would have created an index entry for the three documents without a
vehicle too, with a "field absent" value. The index would become almost twice as large, and
those entries would be of no use whatsoever: nobody searches for passes by the criterion "no
vehicle specified".

In a real pass log about ten percent are vehicle passes. A sparse index will be ten times
smaller than an ordinary one and ten times cheaper to maintain.

⚠️ **A sparse index has a price, and you need to know it.** Sorting by this field through
such an index will lose the documents without the field — they aren't in it. In such cases
MongoDB will itself abandon the index and fall back to a scan; the unpleasant part is that
this happens silently.

**And now the point of this step.** In a relational database with a single table for all pass
types, an index on `car_plate` would have to be built on a column where ninety percent of the
rows are `NULL`. Some DBMSs put such rows into the index anyway, and it bloats. This is worked
around with partial indexes — a mechanism of the same kind as `sparse`, only not available
everywhere and not obvious right away.

So the problem is one and the same. The difference is that here it doesn't arise as a side
effect of "let's put all the types in one table": we have no column that had to be created
for the sake of a minority of records.

</details>

## A predictable failure · The pass that isn't on the list

Let's keep working. The officer at the gate issued another one-time pass — through a script
written in a hurry:

```js
// insertOne = "add one document". What fields are in it, the database doesn't ask
db.passes.insertOne({
  tipe: "разовый",
  guest: "Николаев Сергей Игоревич",
  host: "petrov@corp.ru",
  data: ISODate("2026-09-04T09:00:00Z")
})
```

The insert succeeded: back came `acknowledged: true` ("accepted") and a new `_id` — the
document's unique key, which the database came up with itself. Let's check that there are now
five documents:

```js
// countDocuments = "count the documents that match the condition".
// Empty curly braces are a condition with no restrictions, that is, "all"
db.passes.countDocuments({})
```

Five. Now what security does every morning — opens the list of one-time passes:

```js
// The same selection by type as in the search step: show the passes whose
// type field equals "разовый"
db.passes.find({ type: "разовый" })
```

> **Stop and think before you read on.**
>
> How many passes came back? Where's the fifth? What would happen with the same mistake in a
> relational database — and why is that better?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

One pass came back, not two. Guest Nikolaev will arrive, security won't find him, and sorting
it out will take a while — because the document **exists**, it **was inserted successfully**,
and no error was recorded anywhere.

The cause is two typos: `tipe` instead of `type` and `data` instead of `valid_on`. MongoDB
didn't notice them, because **the collection has no schema, and so no opinion about which
fields are correct.** To it, `tipe` is just as legitimate a field as any other.

Let's find the casualties — documents that have no `type` field at all:

```js
// $exists: false — the opposite of the previous step: "the field is not in the document".
// It's worth keeping such a query handy: it shows what has accumulated past the schema
db.passes.find({ type: { $exists: false } })
```

In a relational database an `INSERT` with a `tipe` column would fail immediately:
`column "tipe" does not exist`. The error would surface in tests, not a week later at the
gate. **This is the main price of schema flexibility: the check the database used to do must
now be done by someone else.**

**A lesson broader than this mistake.** And here it's important not to draw the wrong
conclusion. The right conclusion is not "document databases are bad", but "no schema by
default doesn't mean no schema at all". Your data always has a schema: it's either described
explicitly, or it lives in people's heads and in the code, where nobody checks it.

Let's remove the corrupted document and turn on validation.

</details>

We delete the documents without a type:

```js
// deleteMany = "delete all documents that match the condition". The condition is the same
// as in the search above — which means exactly what you just saw will be deleted
db.passes.deleteMany({ type: { $exists: false } })
```

**What you should see** — `deletedCount: 1`.

Now let's turn on validation — a rule every document is required to satisfy. It's in the file
`validator.js`; let's walk through it before applying it.

<details>
<summary><b>Walking through the rule</b></summary>

```js
db.runCommand({
  collMod: "passes",
  validator: { $jsonSchema: { … } },
  validationLevel: "strict",
  validationAction: "error"
});
```

`collMod` — change the settings of an existing collection. The validator is hung on a live
collection after the fact, nothing needs to be stopped.

```js
      required: ["type", "host"],
```

The required fields. **Note what's not in the list: `guest`.** The group pass has no guest,
an organization in its place. The rule has to be broad enough for a legitimate document shape
to pass through it — and this constraint is felt at once: the more varied your documents, the
less you can demand of all of them together.

```js
        type: {
          enum: ["разовый", "недельный", "автомобильный", "групповой"],
        },
```

A value from the list only. A fifth pass type will require changing the rule — and that's
good: the change becomes deliberate.

```js
        car: {
          bsonType: "object",
          required: ["plate"],
          …
        },
```

The rules work on nested objects too. If the `car` field is present, it must have a `plate`.
If the field is absent — no requirements, the document is legitimate.

```js
  validationLevel: "strict",
  validationAction: "error"
```

`strict` — validate all inserts and all updates. There's a gentler `moderate`: it validates
new documents and updates to those that already satisfy the rule, while leaving the old
invalid ones alone. It's with `moderate` that you turn validation on for a collection where
inconsistency has already piled up: first we stop making it worse, then we fix the old, then
we switch to `strict`.

`error` — reject. There's `warn`: record it in the log and accept it anyway. Good for
watching for a week how much comes in before turning on rejection.

</details>

We apply the rule:

```bash
# The same trick as with passes.js: the file's contents are fed to mongosh's input.
# The rule is hung on a live collection — no need to stop the database
mo < validator.js
```

**What you should see** — `правило установлено`.

We try to repeat the same typo — now under the rule's watch:

```js
// The tipe field is unknown to the rule, and there's no required type in the document.
// Before, such a document would silently settle into the collection
db.passes.insertOne({ tipe: "разовый", guest: "Проверка", host: "x@corp.ru" })
```

**What you should see** — `MongoServerError: Document failed validation`. Now the typo
doesn't get through.

⚠️ **Validation doesn't catch everything, and this has to be said plainly.** The rule
requires the `type` field to be present and to be from the list. A typo in an **optional**
field — `guestt` instead of `guest` — it will let through: the document is still legitimate,
just with an extra field. You can forbid any unknown fields (`additionalProperties: false`),
but then every new field will require editing the rule, and you'll come right back to what
you were getting away from — a schema migration for every little thing. Where to draw the
line is a decision you make, and it's always a compromise.

## Step 6. Honestly: where the document model loses

📍 **Where:** in the `mongosh` shell inside the working Pod.

Schema flexibility isn't the only difference, and the rest aren't in MongoDB's favor.

<details>
<summary><b>There are no joins in the usual form</b></summary>

The task: for each pass, pull in the phone number and job title of the employee who ordered
it. Employees are in a separate collection `staff`, keyed by email.

In SQL this is one line: `JOIN staff ON staff.email = passes.host`.

Here — a pipeline stage:

```js
db.passes.aggregate([
  // $lookup = "for each pass, go to another collection and bring back a record from there"
  { $lookup: {
      from: "staff",          // where to go — the employees collection
      localField: "host",     // which pass field to compare
      foreignField: "email",  // with which employee field
      as: "host_info"         // under what name to put what's found into the document
  } },
  // What's found is always put as a list, even if there's a single match.
  // $unwind unrolls the list back into a single value
  { $unwind: "$host_info" }
])
```

We don't have a `staff` collection — the query will return nothing. It's here as a sample of
the syntax, not as a lab step.

It works. But:

- `$lookup` is **one-directional**: for each document on the left a search is run on the
  right. This isn't an optimizer that will choose a join method, but precisely a brute-force
  lookup
- the result comes back **as a list**, even if there's a single match. Hence `$unwind`, to
  unroll it
- joining more than two collections turns out cumbersome and slow
- in a sharded deployment, until recently `$lookup` worked with limitations

That's why in the MongoDB world the task is solved differently: **data that's needed together
is stored together.** The requester's phone number and job title are written straight into
the pass document.

And this is a real trade-off, not a minor inconvenience:

| | A reference to `staff` | A copy of the data in the document |
|---|---|---|
| Reading | needs `$lookup` | a single lookup |
| An employee changed their phone number | fixed in one place | you have to go through all the passes |
| Integrity | the database watches over it | the application watches over it, that is, you |

In a relational database there's no choice — there it's normalization and foreign keys. Here
there's a choice, and with it responsibility.

</details>

<details>
<summary><b>There are no foreign keys at all</b></summary>

Try it:

```js
// The host field, by meaning, refers to an employee. No such employee exists —
// will the database check this? The document satisfies the rule from the last step: type is
// in place and from the list, host is a string
db.passes.insertOne({ type: "разовый", host: "не-существует@corp.ru", guest: "Тест" })
```

The document will be inserted. There's no employee with such an email, and the database won't
look at that.

In a relational database a foreign key would reject such a row. Here the concept of a foreign
key doesn't exist at all: **the coherence of the data is entirely on the application.** The
validator from the previous step checks the shape of the document, but can't check that a
field's value exists in another collection.

In practice this means: every "is there such an employee" check is written by the developer,
and if they forgot it — you'll find out when security tries to call the requester.

Don't forget to remove the test document:

```js
// deleteOne = "delete one document that matches the condition", not all of them at once
db.passes.deleteOne({ host: "не-существует@corp.ru" })
```

</details>

<details>
<summary><b>There are transactions, but not by default</b></summary>

Here it's important to be precise, because people often say untrue things about MongoDB in
both directions.

**True:** multi-document transactions do exist in MongoDB, starting from version 4.0 for
replica sets. You can change two documents so that either both apply or neither does.

**Also true:** by default they're not there. An operation on **a single document** is atomic.
If you want more — open a session and explicitly begin a transaction:

```js
// A session is a separate "conversation" with the database, within which you can declare a transaction
const s = db.getMongo().startSession();
s.startTransaction();          // from this point changes accumulate, but are visible to no one
// … operations through s.getDatabase("passes") …
s.commitTransaction();         // apply it all at once. To cancel it all at once — abortTransaction()
```

**And a third truth, the most practical:** transactions in MongoDB are more expensive than in
a relational database, they have a time limit, and the whole data model is built on the
assumption that you hardly need them. If your scenario requires them often, that's a sign the
data should have been laid out differently — or that a document database isn't needed here.

For a pass service this isn't a problem: a pass is a single document, and all operations on it
are atomic by themselves. For payroll it's a problem, and a big one.

</details>

<details>
<summary><b>Schema inconsistency creeps in on its own</b></summary>

We've already seen this with the typo. But there's a more insidious variety: inconsistency
that crept in not through an error but through oversight.

A year later you discover in the collection that dates are stored in three ways: as
`ISODate`, as the string `"2026-09-01"`, and as a number with a timestamp — because three
different teams wrote them at different times. A range search over dates finds a third of the
records, and nobody understands why.

You can see what's actually in the collection like this:

```js
db.passes.aggregate([
  // $$ROOT — the whole document in full. $objectToArray breaks it into
  // "field name — value" pairs, so you can then work with the fields as data
  { $project: { fields: { $objectToArray: "$$ROOT" } } },
  // We unroll the list of pairs: one pair — one row at the input of the next stage
  { $unwind: "$fields" },
  // We group by two attributes at once: the field name (k) and its value type (t),
  // and count how many times such a combination occurred
  { $group: { _id: { k: "$fields.k", t: { $type: "$fields.v" } }, n: { $sum: 1 } } },
  { $sort: { "_id.k": 1 } }   // alphabetically, so one field sits next to its own types
])
```

The query breaks each document into "field — value" pairs, determines the type of the value,
and counts how many times each field appeared with each type. On our four documents it will
show an even picture. On a real collection a year on it shows what nobody suspected, and it's
one of the most useful queries when untangling an inherited database.

**The takeaway worth carrying off:** a schema validator is not decoration and not a
"box-ticking formality". In a document database it's the only thing standing between you and
inconsistency. It should be turned on right away, not when things get desperate.

</details>

**The bottom line of an honest comparison:**

| Task | Relational | Document |
|---|---|---|
| Records of the same shape | natural | also possible, but why |
| Records of different shapes | empty columns or a table per type | natural |
| Lists and nesting | separate tables | a field in the document |
| Joining with other data | JOIN, an optimizer | `$lookup` or a copy of the data |
| Referential integrity | the database watches over it | the application watches over it |
| Transactions | by default | explicit, more expensive, rarer |
| Protection against typos | there's always a schema | a validator, if you turned it on |
| Changing the schema | a migration and a release | a new field appears on its own |

## Verification

📍 **Where:** on the laptop, in the same terminal window where you worked with `kubectl`.

The verification script connects to the database itself, so it needs the same things you do:
access to the lab cluster, the tenant number, and the password of the `passapp` user. They're
passed as environment variables.

```bash
cd labs/10-mongodb
# The same access file as in the steps above: the script works from inside the lab cluster
export KUBECONFIG=~/lab.kubeconfig
# The tenant number: from it the script will assemble the database address. Substitute your own
export COZY_TENANT=workshop03
# The password in single quotes: inside them the shell doesn't touch $, ! and & within the string.
# The password doesn't make it into the report
export MONGO_PASSWORD='your-passapp-password'
./check.sh
```

⚠️ **On Windows the script is run from WSL**, not from PowerShell — how to set it up is
written at the start of lab 0. Without WSL you can still complete the lab, but there will be
no report artifact.

The script will check not the fact of the service's creation but the work in substance: the
collection has documents of all four shapes, search by a nested field and into a list works,
a sparse index is built on the rare field, the schema validator is turned on, and no
documents without a type remain.

The password doesn't make it into the report.

## Cleanup

The working Pod is no longer needed — all this time it kept the container busy with the
`sleep` command:

```bash
# delete = "remove from the cluster". The Pod disappears along with its MONGO_URI variable,
# so the password doesn't remain in the cluster
kubectl delete pod mongo-workbench
```

MongoDB itself is deleted in the dashboard: the `passes` application → delete.

Why this is cheap. A MongoDB replica set in classic infrastructure is three virtual machines,
installation, vote configuration, monitoring of replication lag, and a person who knows how
to fix all of it. Here you took a service for an hour and returned it in ten seconds, and the
space it occupied went back into the cluster's free capacity — someone else can claim it
right away.

⚠️ **The data will disappear along with the deletion.** The four passes are restored with a
single command, so in the lab this is no loss. If you put something real in there — turn on
backups first; they're a separate section on the order form.

## What we can do now

- Explain when the document model is appropriate and when it's a way to make trouble for
  yourself
- Order MongoDB from the catalog and not stumble over `authSource`, roles, and a single copy
- Store documents of different shapes and search by nested fields and into lists
- Build a sparse index and understand what it pays for its savings
- Turn on a schema validator and see what it protects against and what it doesn't
- Name out loud what a document database lacks: foreign keys, the usual joins, transactions
  by default

## And in vSphere this would be

Three machines for the replica set, and the most labor-intensive part of them is not the
installation but configuring the vote among the copies: who is primary, what to do on loss of
connection, how to bring a lagging one back. Plus a separate conversation with the
information-security team about who will be updating this database a year from now.

Here — an entry in the catalog and five minutes.

**Where vSphere is more convenient, honestly.** A virtual machine with MongoDB is a machine
you can walk up to: log in over SSH, look at `mongotop`, tweak the config, take a snapshot
before a risky operation. A managed service doesn't give you this **deliberately**: the
tenant won't let you `exec` into a Pod or into the database's logs. As long as everything
works, that's an advantage — fewer ways to break it. When the database behaves strangely, the
administrator's usual set of actions is unavailable, and all that's left is to go to whoever
operates the platform.

And a second thing, specific to MongoDB in particular. A managed service pins the version and
the set of parameters. Upgrading a major version of MongoDB is an operation that in your own
installation you plan yourself, with an application-compatibility check and the option to roll
back to a snapshot. Here a version change is a field on the form and someone else's upgrade
procedure under the hood. Usually this is exactly what you want. But on the day the upgrade
goes wrong, you won't be sorting it out with your own hands, and you need to understand this
in advance, not discover it along the way.
