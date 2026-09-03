## 22. Phase 3. Ditching the menagerie

**Steps 5, 7, 8, 9.** The most valuable part. Inside the machine we moved over, its own
Postgres and Kafka are still living — the very ones someone installed once and nobody has
touched since.

We are **not** bringing them along. Instead we take ready-made ones from the Cozystack
catalog and reconfigure the application. The difference is simple: behind a managed service
there's replication, automatic backups and monitoring; behind a homemade one, the hope that
the person who set it up still works at the company.

The order is this: first we spin up the services (step 5), then we point the application at
them (step 7), then we create a table in the database (step 8) and check the whole chain
(step 9).
