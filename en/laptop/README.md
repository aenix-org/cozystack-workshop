# Workshop: migrating a VMware VM to Cozystack (from your own laptop)

We take an application that has run for years on a virtual machine in VMware and move
it to Cozystack. You do all of it with your own hands.

> If the instructor gave you a shared VM (the bastion) with the tools and access already
> in place — you need the other set, [`../bastion/`](../bastion/), where everything is
> already set up.

This file is the route: what comes after what, which commands to type, and what you should
end up with. The explanations of why things are built the way they are, and the line-by-line
walkthroughs of the manifests and scripts, live in the [`chat/`](chat/) folder — one file
per message. The links sit at the end of each step.

## The route

The application lives on three machines: the application itself, the database, and the
message queue. We move only the first — the database and the queue stay behind, and in
their place we take ready-made ones from the Cozystack catalog.

| Phase | What we do | Where |
|---|---|---|
| 1 | Set up storage for the image | on the laptop |
| 2 | Repackage the disk from the VMware format into the KVM format | in a temporary machine |
| 3 | Bring the machine up in its new home | on the laptop |
| 4 | Order the database and the queue from the catalog | on the laptop |
| 5 | Fix networking and switch the application to the new addresses | in your machine |

After that comes the final check: an order created in the application makes it all the way
to the database and the queue.

## What the instructor gave you

The instructor gives you:

* the dashboard https://dashboard.workshop.aenix.io
* the username `workshopXX`, the password will be given on the spot
* the kubeconfig — in the dashboard: `Info` → the `Secrets` tab → the `kubeconfig-tenant-workshopXX` secret

Everywhere below, replace `workshopXX` with your own number.

## Before you start: four utilities

They're installed on your laptop once, before the workshop.

| Utility | What for | Install |
|---|---|---|
| `kubectl` | applies files, shows what's in the cluster | [chat/04](chat/04-install-kubectl.md) |
| `virtctl` | the virtual machine console and port forwarding | [chat/05](chat/05-install-virtctl.md) |
| `kubelogin` | login through the browser; without it the cluster won't let you in | [chat/06](chat/06-install-kubelogin.md) |
| `git` | to pull this repository | [chat/09](chat/09-install-git.md) |

⚠️ **krew is not needed for this workshop** — why, in [chat/07](chat/07-about-krew.md).

A check that everything is in place. Each command prints a version or a help text, not
"command not found":

```bash
kubectl version --client
virtctl version --client
kubectl oidc-login --help
```

## Connecting to the cluster

Save the kubeconfig from the dashboard to disk and point the `KUBECONFIG` variable at it.

**macOS and Linux** — put the contents of the secret into `~/.kube/workshop`, then:

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Windows (PowerShell):**

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # paste the kubeconfig; file type — "All Files"
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

On the first request a browser will open — log in as `workshopXX`.

⚠️ **Windows: save the file only in UTF-8.** Notepad and the `>` redirect in PowerShell
write UTF-16, and `kubectl` won't read such a file — it will answer
`x509: certificate signed by unknown authority`, even though there's nothing wrong with the certificate.

⚠️ The error `dial tcp [::1]:8080 ... refused` means that `kubectl` didn't find the kubeconfig,
not that the cluster is unreachable. A walkthrough of both — in [chat/08](chat/08-connect-to-cluster.md).

## Getting the materials

```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/laptop
```

⚠️ The `/laptop` tail is mandatory: this folder holds the materials for the laptop path,
with the manifests and scripts; without it the commands will find neither `manifests`
nor `scripts`.

In every file there's a `tenant-workshopXX` placeholder. Substitute your own number all
at once (in the example — `workshop03`):

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +

# macOS — the same sed, but it requires empty quotes after -i
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

```powershell
# Windows
Get-ChildItem -Path manifests,scripts -File -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw) -replace 'tenant-workshopXX','tenant-workshop03' |
    Set-Content $_.FullName -NoNewline
}
```

We check that not a single placeholder is left:

```bash
grep -rn tenant-workshopXX manifests scripts || echo "all clean, you can continue"
```

One spot the command leaves untouched on purpose: in `manifests/03-app-vm.yaml` the line
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` — you'll get that link after the second phase.

In detail: [chat/10](chat/10-clone-and-set-number.md) ·
file map [chat/11](chat/11-file-map.md)

---

## Phase 1. Storage for the image

📍 On the laptop.

The repackaged disk needs to go somewhere the platform can pull it from over the network.
We set up a bucket — object storage with an S3 interface.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**You should see:** `bucket.apps.cozystack.io/my-images created`, then `READY: True`.

⚠️ **Write the type name in full, not `bucket`.** The word is taken three times in the cluster:
our type from the catalog, the Flux type, and the type from the object-storage standard. Which
of the three `kubectl` will substitute for the short name is not known in advance, and if it's
the wrong one, you'll get a permissions denial on a resource you never asked for:
`buckets.source.toolkit.fluxcd.io is forbidden`. This is not an access problem, and there's
nothing to fix.

⚠️ **If `apply` fails with `SchemaError … unknown model in reference`** — it's the client-side
validation that trips up, not the cluster; the manifest is correct. To work around it:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`. The flag turns off only the local
check; the server will still validate the object on its end.

**You'll need the keys next:** dashboard → `Bucket` → `my-images` → the `Secrets` tab →
the `bucket-my-images-app-credentials` secret. From there you take `bucketName`, `accessKey`
and `secretKey` — you'll put them into the script in the next phase.

Manifest walkthrough: [chat/13](chat/13-bucket-manifest.md) ·
the whole step: [chat/14](chat/14-step-1-bucket.md)

---

## Phase 2. Repackaging the disk

📍 First on the laptop, then inside the temporary machine.

The disk from VMware is written in the VMDK format, while KVM reads QCOW2. `virt-v2v` handles
the repackaging; there's no point installing it on the laptop for a one-off, so we bring up
a temporary machine with the tools already in place.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**You should see:** two lines with `created`, then `Running`.

⚠️ `Running` means "powered on", not "ready": inside, `cloudInit` keeps working for a few more
minutes — installing packages and downloading `mc`. Log in too early and you won't find `virt-v2v`.

Log in (username `ubuntu`, password `ubuntu`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

Inside: `nano convert.sh`, paste in the text of `scripts/convert.sh`, put your own
`bucketName`, `accessKey` and `secretKey` in place of `ВСТАВЬТЕ_...`, and run
`bash convert.sh`.

**You should see:** at the end of the output, after the word `Share:` — a signed link to the image.
You'll need it in the next phase.

Manifest walkthrough: [chat/15](chat/15-conversion-vm-manifest.md) ·
script walkthrough: [chat/17](chat/17-convert-script.md) ·
both steps in full: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## Phase 3. The machine in its new home

📍 On the laptop.

⚠️ First shut down the converter machine — it has done its job and is holding 8Gi of your quota.
If you don't remove it, the new machine will hang in `Pending`:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

Put the link you got into `manifests/03-app-vm.yaml` in place of
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`, then:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**You should see:** two lines with `created`, then `Running`. The wait is longer here —
the platform is downloading the image from your link.

Log in (username `root`, password `cozydemo`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **There will be no network inside.** This isn't a broken testbed — it's how it should be. We fix
it in phase five.

Manifest walkthrough: [chat/20](chat/20-app-vm-manifest.md) ·
the whole step: [chat/21](chat/21-step-4-your-vm.md)

---

## Phase 4. The database and the queue from the catalog

📍 On the laptop.

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**You should see:** `postgres.apps.cozystack.io/db created` and
`kafka.apps.cozystack.io/kafka created`. Kafka takes noticeably longer to come up than Postgres.

Manifest walkthrough: [chat/23](chat/23-managed-manifest.md) ·
the whole step: [chat/24](chat/24-step-5-database-and-queue.md)

---

## Phase 5. Wiring up the application

📍 Inside your virtual machine.

Three actions in strict order: without networking the script can't reach the database, and
without the database it won't accept the schema.

| Step | What we fix | With what |
|---|---|---|
| 5.1 | the machine has no network | `scripts/netfix-dhcp.sh` |
| 5.2 | the application looks for the old addresses | `scripts/connect-managed.sh` |
| 5.3 | the new database has no tables | `scripts/orders-schema.sql` |

**5.1.** The script changes `BOOTPROTO=static` to `dhcp` and removes the address from the VMware
network. You type it by hand — the machine still has no network, so you can't download the file.
After that the machine needs a **reboot**: CentOS 7 applies network settings at boot.

**5.2.** The script replaces the hard-coded addresses `192.168.10.30` and `192.168.10.40` in
`/etc/orders/application.properties` with service names and restarts the application.

**5.3.** We install the `psql` client and apply the schema — the commands are below, in the
final check.

In detail: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## The final check: three steps in order

### Step 1. Shut down firewalld

📍 Inside your machine. The rules are left over from the old network and are cutting off requests to the application.

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**You should see:** `200`. If `503` — something from the database or the queue didn't connect.

### Step 2. The database schema

📍 Inside your machine. The stock psql from CentOS 7 is version 9.2; it can't do SCRAM and
answers `SCRAM authentication requires libpq version 10 or above`. We install a fresh one:

```bash
# 1. The PGDG repository — the source of PostgreSQL packages
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: not in the CentOS 7 repositories, so we take it from the EPEL archive
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. The client itself — only from the live pgdg15 repository
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ The second and third commands are not redundant. Without `libzstd` the install fails on
`Requires: libzstd >= 1.4.0`. Without `--disablerepo`/`--enablerepo` — on
`HTTPS Error 410 - Gone`: the repository package enables every PostgreSQL version at once,
including the end-of-life 12 and 13, and before installing, `yum` walks every enabled
repository and fails on the first dead one.

```bash
psql --version
```

If `command not found` — the client landed outside `PATH`: look at
`ls /usr/pgsql-*/bin/psql`, then `export PATH="$PATH:/usr/pgsql-15/bin"`.

We fetch the schema and apply it:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**You should see:** in the last command — the `orders` table.

The database address is not an IP but a name: `postgres-db-rw` (the `db` service, read-write),
`tenant-workshopXX` (your namespace), `svc.cozy.local` (the suffix for the cluster's internal
names). The password is set in `manifests/04-managed.yaml`, so there's nowhere you need to
hunt for it.

In detail: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### Step 3. Port forwarding and checking from the outside

📍 On the laptop.

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

Don't close the window — the tunnel lives as long as the command runs. In a second window:

```bash
curl -s http://localhost:8080/actuator/health

curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s http://localhost:8080/api/orders
```

**You should see:** the order in the list. The whole journey is complete.

In detail: [chat/30](chat/30-step-9-verify-chain.md)

---

## Cheat sheet

> **The `vmi/` prefix isn't needed by every command, and that's not a typo.** The two commands
> have different target syntax. `virtctl console` expects just the name and with the prefix
> answers `forbidden`, because it takes the word `vmi` for the machine's name. `virtctl port-forward`
> requires `type/name` and without the prefix answers
> `target must contain type and name separated by '/'`.

```bash
# log into the app-VM (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# log into the conversion-VM (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# forward the application's port to the laptop
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

To leave the console — `Ctrl+]`. If the screen is blank after you connect, press Enter.
The same thing is available with the mouse: the **VNC** button on the machine's page in the dashboard.

## Where it's easy to get stuck

* For the conversion-VM, use only `ubuntu-20.04`. On 24.04 the kernel panics; on 22.04
  `virt-v2v` can't parse the old CentOS 7 RPM database.
* The VMDisk for a catalog image must be larger than the image itself, otherwise the clone
  won't go through and the disk will hang in `Terminating`. For `ubuntu-20.04`, 25Gi is enough.
* On a fresh app-VM, `netfix` first, then `connect` — otherwise the application won't see the
  managed services.
* Don't open `.yaml` files in Word or Google Docs: they swap out the quotes and dashes, the
  file stops applying, and the error looks inexplicable.

The rest of the pitfalls — [chat/31](chat/31-troubleshooting.md).

## For those setting up the testbed

Quotas, the order for creating tenants, and the platform version — in [REQUIREMENTS.md](../REQUIREMENTS.md).

## All messages in order

The list of 32 messages — [chat/README.md](chat/README.md).
