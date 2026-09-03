## 28. Step 8: why the application still fails

**The database is empty — the application needs its schema**

📍 **Where:** inside your own machine — the one you brought up in phase three (app-VM). Not on the bastion. It is already on the cluster network and can see the database by name.

### First — a second check that will also fail

We fixed the addresses, the application restarted, and its health endpoint answers `200`. It looks like everything is ready. Let's try to create an order:

```bash
curl -s -X POST localhost:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"item":"test order"}' -w '\nHTTP %{http_code}\n'
```

**Back comes a `500`.** Even though health was `200` a moment ago.

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

Because this application's health check looks only at the **fact of a connection** to the database: the connection opened, the server answered — so it's "alive." Whether the tables it needs are inside, it does not check.

And there are no tables. When you ordered Postgres from the catalog, you were handed an **empty server**: the `orders` database and the `orders` user are set up, and that's all. On the old machine the tables existed — the application created them once, long ago, on its first run, and over the years everyone forgot about it.

You've just seen, into the bargain, what a green health check is worth. It says "I got through to the database," not "I'm working." In a real project it's easy to build monitoring on a check like this that will cheerfully show everything green while users can't place a single order.

</details>

**What we do.** We're moving the application, not its data, so the tables have to be created anew. This is done once, with a file containing a list of SQL commands. Such a file is called a **schema** — it describes how the storage is laid out: which tables, which fields they hold, and of what type.

<details>
<summary><b>A closer look: what's inside orders-schema.sql</b></summary>

The file is `scripts/orders-schema.sql` in the repository. It contains just two commands.

**The first creates the orders table:**

```sql
CREATE TABLE IF NOT EXISTS orders (
    id           BIGSERIAL PRIMARY KEY,
    item         TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'NEW',
    created_by   TEXT,
    processed_by TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ
);
```

Field by field:

- `id BIGSERIAL PRIMARY KEY` — the order number. `BIGSERIAL` means "the database hands out the next one in sequence itself," `PRIMARY KEY` means "it is unique and used to look the row up."
- `item` — what was ordered. `NOT NULL` — an order with no item makes no sense, and the database won't accept such a row.
- `status` — the state of the order, `NEW` by default. It changes to `PROCESSED` once the message has passed through Kafka.
- `created_by` / `processed_by` — who created it and who processed it. This is exactly where the application writes `kafka`, and it's this field that will show, at step 9, that the queue really works.
- `created_at` / `processed_at` — when. `TIMESTAMPTZ` — a timestamp with time zone.
- `IF NOT EXISTS` — "if the table already exists, do nothing and don't complain." Thanks to this the file can be applied again without breaking anything.

**The second adds one row of history:**

```sql
INSERT INTO orders (...) SELECT '12x rack rails', 'PROCESSED', ...
WHERE NOT EXISTS (SELECT 1 FROM orders);
```

This is cosmetic: so that at step 9 the list of orders isn't empty. `WHERE NOT EXISTS` means "insert only if the table is empty" — running it again won't create a duplicate.

**What is deliberately absent from the file:** no `CREATE DATABASE`, no `CREATE USER`. Both the database and the role were already created by the Cozystack catalog when you ordered Postgres at step 5. This is the whole point of a managed service: it takes the routine on itself, and all that's left for you is your own schema.

</details>

> ⚠️ **Discrepancy in the file's comments.** The header of `orders-schema.sql` says that first you need `GRANT CREATE,USAGE ON SCHEMA public` as the superuser. **This is out of date, don't do it** — the `orders` role belongs to `orders_admin`, which owns the database and the schema, so it already has the rights. Verified. We'll fix the comment in the file.
