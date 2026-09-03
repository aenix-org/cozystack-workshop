## 11. File map: what lives where and where it runs

**Read this once — after that you won't have to guess**

Keep three places in mind where things happen: the **bastion** (the machine you SSH'd into),
the **converter machine**, and **your app-VM** — both of the latter are created inside the
cluster. There are two kinds of files in the repository, and they run in different places.

**Manifests — `manifests/*.yaml`. Applied from the bastion.**
These describe what to create in the cluster. The command is always the same: `kubectl apply -f <file>`.

• `01-bucket.yaml` — storage for the image · step 1
• `02-conversion-vm.yaml` — the converter machine · step 2
• `03-app-vm.yaml` — your app-VM · step 4 (this is where you paste the presigned link by hand)
• `04-managed.yaml` — Postgres and Kafka from the catalog · step 5

**Scripts — `scripts/*`. They run not on the bastion, but inside the machines in the cluster.**
On the bastion itself you don't run them — you only apply the manifests with `kubectl`.

• `convert.sh` — inside the converter machine · step 3
• `netfix-dhcp.sh` — inside your app-VM · step 6
• `connect-managed.sh` — inside your app-VM · step 7
• `orders-schema.sql` — a table for the database, from inside the app-VM · step 8 (we'll type it in
  as a query; the file is there so you can see exactly what gets created)

**How a script gets inside a machine — and why it differs.**

The **converter machine** has a network, so it downloads the file itself. The repository is
public, no keys needed:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/convert.sh
```

**Your app-VM has no network at all to begin with** — that broken state is exactly what we fix
at step 6. There's nothing to download with and nothing to download to, and files can't be
passed through the console. So you don't download `netfix-dhcp.sh` and `connect-managed.sh` —
you **type them in by hand**: it's just two or three commands each, and I'll give them to you
ready-made in the chat. The files themselves in the repository are the same thing, but spelled
out in full and with comments: handy to reread later, when you repeat this on your own.

⚠️ **The tenant number in the manifests is already filled in** — while the bastion was being
prepared, the `tenant-workshopXX` placeholders were replaced with your number. You don't need
to enter anything by hand. The only things you fill in yourself are `bucketName`, `accessKey`
and `secretKey` in `convert.sh` (it's downloaded into the converter fresh, with `ВСТАВЬТЕ_...`
placeholders), and the presigned link in `manifests/03-app-vm.yaml` at step four.
