## 23. A closer look: what's inside 04-managed.yaml

```yaml
kind: Postgres
metadata:
  name: db
spec:
  replicas: 1
  size: 10Gi
  storageClass: local
  resourcesPreset: t1.micro
  users:
    orders:
      password: Orders2019!
  databases:
    orders:
      roles:
        admin: [ orders ]
```

`kind: Postgres` — again the catalog stance, just like `Bucket` in the first phase. You are not installing a database engine: you are ordering one. The platform itself brings up the processes, sets up replication, arranges a backup schedule, and wires in monitoring.

`users` and `databases` — the platform will create the `orders` user, the `orders` database, and grant that user administrator rights on that database. There is nothing to create by hand: that is exactly why the schema file we apply later contains no `CREATE DATABASE` or `CREATE USER` commands — they have already been run for you.

`replicas: 1` — a single copy, a training testbed. In a production system you set more, and then the platform itself keeps track of which one is primary and fails over on an outage.

`resourcesPreset: t1.micro` — the size, a ready-made bundle of CPU and memory. The smallest one.

⚠️ **The password sits in plain text** right in the file you commit to the repository. For a training testbed this is acceptable; for a production one it is not: there the password lives in a secrets store, and the description keeps only a reference to it.

Further down in the same file is a `kind: Kafka` object.

**What a queue is and why it's here.** Kafka is a message queue. When the application accepts an order, it does two things: it writes the order to the database and drops a message into the queue — "order number such-and-such has arrived." From there other programs read that message — the one that emails the customer, the one that tallies reports. The point of this layer is that the application does not need to know who will read it, or when: it dropped the message off and moved on. If a reader happens to be down at that moment, the message waits for it in the queue.

In our testbed there are no readers; the queue is there for completeness: the application writes to it when an order is created, and if Kafka is unavailable, the health check will honestly report that things are bad. This is exactly what happens in a real system too.
