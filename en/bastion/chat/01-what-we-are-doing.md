## 1. What we're actually doing

**Read this before your first command. Everything afterwards will make more sense.**

### What you have right now

An internal "Orders" service. In vSphere it's given **three virtual machines** —
exactly the way this usually looks:

| Machine | What's on it | Address |
|---|---|---|
| `app` | the `orders-api` application in Java, CentOS 7 | — |
| `db` | PostgreSQL, installed by hand | `192.168.10.30` |
| `mq` | Kafka, installed by hand | `192.168.10.40` |

The application is written in Spring Boot, runs as an ordinary systemd service, and its
settings live in `/etc/orders/application.properties`. And that's where it gets interesting:

```properties
spring.datasource.url=jdbc:postgresql://192.168.10.30:5432/orders
spring.kafka.bootstrap-servers=192.168.10.40:9092
```

**The addresses are hard-wired.** Not names — numbers. Someone once stood up three machines,
typed the IPs into the config, and ever since those three numbers have held the whole
installation together. Change the subnet and the application falls over. Move the database to
another host and you have to open the file by hand and restart the service.

If you just recognized your own infrastructure — yes, it's like that for everyone.

### What we're going to do about it

We move **only `app`**. The other two machines don't go anywhere — in their place we take
ready-made Postgres and Kafka from the Cozystack catalog.

The difference is fundamental. You could move all three VMs without us — and you'd end up with
the same menagerie, just on new hardware. The same Postgres you installed back in 2019, that
nobody updates and nobody backs up, because "there was a script for that, wasn't there." A
managed service arrives with replication, backups and monitoring, and you stop thinking about
it altogether.

**And no data may be lost in the process** — the orders from all these years have to be moved
into the new database. That's a separate step, and in a real migration it's the most
nerve-wracking one.

That difference — "moved the menagerie" versus "moved the application and threw the menagerie
out" — is what this workshop is about.

The road has three phases.

**Phase 1 — get the image out.** The virtual machine's disk from vSphere needs to be turned
into a format Cozystack understands, and put somewhere the cluster can pull it from. These are
steps 1–3.

**Phase 2 — bring the machine up in its new home.** From the exported image we stand up a VM,
now in Cozystack, and bring it back to its senses: it won't have a network, because the
hardware around it has changed. These are steps 4 and 6.

**Phase 3 — throw the menagerie out.** We stand up Postgres and Kafka from the catalog, **move
the data out of the old database**, and reconfigure the application away from nailed-down IPs
onto proper names. These are steps 5, 7, 8, 9.

> **If you've never worked with Kubernetes — that's fine, it's by design.** Every term is
> explained as we go, and the next message is a little glossary where all of it is translated
> into the language of vSphere.
