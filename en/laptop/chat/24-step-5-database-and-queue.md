## 24. Step 5: database and queue from the catalog

**Bringing up managed Postgres and Kafka**

📍 **Where:** on the laptop.

In the original system, the database and the queue lived on separate CentOS 7 VMs — the very
`192.168.10.30` and `192.168.10.40` from the config. Those we **do not carry over**: instead of them we take
the platform's services. Patching an outdated operating system is no longer your job.

<details>
<summary><b>Why the application needs a queue and what it even does</b></summary>

It's a fair question: the database is obviously needed, but what's the queue doing here.

**How the application works.** A user creates an order. If the application did all the
work at once — recorded the order, ran the calculations, sent the email, poked the adjacent system —
the user would wait until all of that finished. And if the adjacent system were down, they'd wait
until the timeout and get an error, even though the order was already created.

So the work is torn in two. The application writes the order to the database with status `NEW`,
puts a message "order #123 has appeared" onto the queue, and **replies to the user right away**.
From there a handler picks the message off the queue at its own pace, does the heavy part, and
sets the order's status to `PROCESSED`.

This is exactly why the table has a `processed_by` field. In step 9 you'll see the value
`kafka` there — and that will be the proof that the "application → queue → handler" chain
has come back together in its new home.

**How it was in vSphere.** A separate VM, with Kafka and ZooKeeper installed on it by hand.
Who installed them is unknown, the version is whatever it was at the time, there were no updates
ever, and there's no monitoring. The classic machine everyone is afraid to reboot.

**Why the queue doesn't need to be moved but the database does.** The difference is in what they store.
The database holds every order in all of history — lose it, and the company loses data. The queue
holds only the messages that are in transit right now — seconds of life. A proper migration of the
queue consists of letting the handler finish off what's left and switching over to the new one.
There's nothing to copy.

This is a general rule worth taking away from the workshop: **during a move, what you struggle with is
whatever holds state.** Everything else is recreated from scratch.

</details>

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

They don't come up instantly — while you wait, take a look in the dashboard at what exactly got created.

**What got created:** a **Postgres** object named `db` — with a database `orders`
and a user `orders` inside it — and a **Kafka** object named `kafka` with a topic `orders`.
Don't change the names: the addresses below and the commands in the next steps count on them.

🖱 **Via the dashboard:** this is the most visual step for the mouse. The platform catalog —
**Postgres → Deploy new**: name `db`, one replica, in the users section a user
`orders`, in the databases section a database `orders`. Then **Kafka → Deploy new**: name `kafka`,
one replica, topic `orders`.

**You don't need to write anything down, but here are the addresses — they'll come in handy in step 7.** From inside
the cluster the database and the queue are reachable by name:

• Postgres — `postgres-db-rw.tenant-workshopXX.svc.cozy.local:5432`
• Kafka — `kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local:9092`

These two lines are exactly what, two steps from now, will replace the hard-coded addresses `192.168.10.30`
and `192.168.10.40` in the application's config. I'll send them to you as ready-made commands; you'll
substitute your own number in place of `XX`.

Remember the difference itself: before, the application went to a hard-coded address; now it goes by name.
An address can change, a name will stay.
