# Workshop: move a VMware VM to Cozystack (through the bastion)

An order service has lived for years on three virtual machines in VMware: the application itself, a PostgreSQL database and a Kafka queue. Today you move the application VM to Cozystack and replace the other two with managed services from the Cozystack catalog. You write every manifest yourself, keep the whole infrastructure in Git, convert the disk with your own hands and fix what breaks inside the guest.

> This version runs on a shared VM (the bastion) where the tools and your access are already set up. If you work from your own laptop, use [`../laptop/`](../laptop/). The route is the same; only part 0 differs.

Plan on about three hours. Each task says what to describe and which page of the documentation to read; the solution is hidden under a spoiler. Try first, then open it.

## Route

| Part | What you do | Time |
|---|---|---|
| 0 | Log in to the bastion, look around, read the VMware VM's description | 20 min |
| 1 | Order object storage for the disk image, first in the dashboard, then in Git | 15 min |
| 2 | Write a temporary conversion VM, convert the disk by hand, remove the VM through Git | 40 min |
| 3 | Write the application VM, sized from VMware's description, and import the disk | 20 min |
| 4 | Order PostgreSQL with a replica and Kafka from the catalog | 15 min |
| 5 | Bring the application back to life and publish it over HTTPS | 40 min |
| 6 | Day two: resize the VM, live-migrate it, lose the database primary | 25 min |

## What the host gives you

- the bastion address: `95.217.173.146`
- the Cozystack dashboard: https://dashboard.workshop.aenix.io
- your login `vmwXX` and a password; the same pair works on the bastion, in the dashboard and in GitLab
- your Git repository: `https://gitlab.workshop.aenix.io/vmwXX/vmware-migration`

Everywhere below, replace `vmwXX` with your login. Your tenant's namespace is `tenant-vmwXX`.

## Part 0. Log in and look around (20 min)

### 0.1 The bastion

📍 On your laptop, then on the bastion.

```bash
ssh vmwXX@95.217.173.146
```

Everything below runs on the bastion unless a step says otherwise. Your home folder already has what you need:

```bash
ls ~
cat ~/credentials.txt
kubectl config get-contexts
kubectl get resourcequota
```

**You should see:** `credentials.txt`, `vmware-migration` (your Git repository) and `workshop` (this guide with its files); one kubectl context, `tenant`, whose default namespace is `tenant-vmwXX`; and your quota, with `hard` limits and what is already `used`.

<details><summary>What a tenant is, in vSphere terms</summary>

A tenant is roughly a resource pool with its own permissions and budget, plus its own catalog of services. Everything you create today lives in one namespace, `tenant-vmwXX`, and counts against one quota. Unlike a resource pool, a tenant orders databases, queues, object storage and whole Kubernetes clusters as easily as VMs.

</details>

See what you can order:

```bash
kubectl get applicationdefinitions -o custom-columns=KIND:.spec.application.kind
```

**You should see:** a few dozen kinds, among them `VMInstance`, `VMDisk`, `Bucket`, `Postgres` and `Kafka`. The **Catalog** page in the dashboard shows the same list; log in there as `vmwXX` too. Every one of them is ordered the same way: you describe what you want in a short YAML file, and the platform builds it.

### 0.2 Your infrastructure is a Git repository

```bash
cd ~/vmware-migration
git log --oneline
cat platform/README.md
```

**You should see:** one commit and a `platform/` folder with a single README. The same repository is at `https://gitlab.workshop.aenix.io/vmwXX/vmware-migration`; Git on the bastion already knows your password.

The platform watches this repository. Once a minute Flux, the GitOps engine built into Cozystack, takes the `main` branch and applies every YAML file in `platform/` to your tenant. When you delete a file, Flux deletes the object. Look at the link:

```bash
kubectl get gitrepository,kustomization
git log -1 --format=%h
```

**You should see:** `infra` (where Flux reads from) and `platform` (what it applies), both `READY True`, and the same commit hash in their status as in `git log`.

From here on, every manifest goes into `~/vmware-migration/platform/`, then `git add`, `git commit`, `git push`. Give the platform about a minute after each push; `kubectl get kustomization platform` shows the last commit Flux applied.

<details><summary>Why Git and not kubectl apply</summary>

In vSphere the truth about a VM is whatever vCenter shows right now: someone resized it at night, someone added a disk, and nobody remembers why. With GitOps the truth is the repository. Every change has an author, a time and a message, can be reviewed before it lands and undone with `git revert`. If someone changes the platform by hand, Flux puts it back within a minute. You will see both effects today.

</details>

### 0.3 Read the VMware VM before you move it

The VM was exported from vSphere as an OVA: a tar archive with an `.ovf` description and a `.vmdk` disk. Before moving anything, find out what it is. The description sits at the start of the archive, so the first 64 KB are enough:

```bash
cd ~
curl -sL -r 0-65535 https://github.com/aenix-org/cozystack-workshop/releases/download/vmware-demo-ova/app-1.ova | tar xO app-1.ovf 2>/dev/null > app-1.ovf
grep -E 'osType|ElementName>|capacity=|ethernet' app-1.ovf
```

Write down the guest OS, the number of vCPUs, the memory and the disk size. You will need them in part 3.

<details><summary>What you should have found</summary>

- `vmw:osType="centos7_64Guest"`: CentOS 7, 64-bit.
- `2 virtual CPU(s)` and `2048 MB of memory`.
- `ovf:capacity="8591507456"`: an 8 GiB disk.
- `E1000 ethernet adapter on "VM Network"`: an emulated Intel NIC on a port group called `VM Network`. Keep it in mind until part 5.

</details>

## Part 1. Object storage for the disk image (15 min)

The converted disk needs a place from which the platform can download it over HTTP. That place is a bucket: S3-compatible object storage from the catalog.

### 1.1 Order a bucket in the dashboard

📍 In the dashboard.

Open **Catalog → Bucket**, name it `images` and add one user called `convert`. Create it, then look at it from the terminal:

```bash
kubectl get buckets.apps.cozystack.io images
kubectl get secret bucket-images-convert-credentials -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
```

**You should see:** `images` with `READY True`, and a Secret with four keys: `accessKey`, `bucketName`, `endpoint`, `secretKey`.

A bucket "user" is not a person: it is a pair of S3 keys that opens only this bucket. Cozystack generates the keys and puts them into that Secret.

⚠️ Always type the full kind, `buckets.apps.cozystack.io`. The short word `bucket` is taken three times in the cluster (the catalog kind, a Flux kind and the object storage standard's kind), and `kubectl` may pick one you have no rights to and answer `forbidden`. It is not a permissions problem; use the full name.

### 1.2 Move the bucket into Git

📍 On the bastion.

```bash
kubectl get buckets.apps.cozystack.io images -o yaml
```

Write `platform/bucket.yaml` with the same declaration. Take only `apiVersion`, `kind`, `metadata.name` and `spec`. Leave out `status`, `namespace` and everything the platform generated (`uid`, `resourceVersion`, `creationTimestamp`, `managedFields`, annotations and labels): Flux puts the object into your namespace by itself.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Bucket
metadata:
  name: images
spec:
  users:
    convert: {}
```

</details>

```bash
cd ~/vmware-migration
git add platform/bucket.yaml
git commit -m "Keep the image bucket in Git"
git push
```

Nothing changes on the platform, because the declaration is the same. What changed is who owns it: from now on the bucket is managed from the repository.

### 1.3 Under the hood

```bash
kubectl get helmreleases | grep images
```

**You should see:** `bucket-images` and `bucket-images-system`, both `True`. Every catalog object becomes a Helm release, and the release creates the real resources. You never write Helm charts yourself: the catalog entry is the chart, your YAML is its values.

## Part 2. A temporary VM to convert the disk (40 min)

VMware stores disks as VMDK; Cozystack runs VMs on KVM. The tool that repacks the disk and also prepares the guest for KVM (drivers, boot loader) is `virt-v2v`. You will not install it on the bastion: you order a temporary Linux VM with the tools, use it once and throw it away.

### 2.1 Write the conversion VM

In Cozystack a VM is two objects: a `VMDisk` (the disk, and where its data comes from) and a `VMInstance` (CPU, memory, attached disks, boot settings). They live separately on purpose: delete the instance and the disk survives; attach the disk to another instance and it boots there.

Read the docs for [VM disks](https://cozystack.io/docs/v1.7/virtualization/vm-disk/) and [VM instances](https://cozystack.io/docs/v1.7/virtualization/vm-instance/) and write `platform/convert.yaml` with both objects, both named `convert`:

- the disk: from the platform's ready-made image `ubuntu-20.04`, 20Gi, storage class `replicated`;
- the VM: the `ubuntu` profile, instance type `u1.large` (2 vCPU and 8 GiB: `virt-v2v` likes memory), the `convert` disk attached;
- cloud-init that sets the password `ubuntu` for the `ubuntu` user, allows password login and installs `virt-v2v`, `libguestfs-tools`, `qemu-utils` and `awscli`.

Hints: the image is `source.image.name`, the size is `instanceType`, the profile is `instanceProfile`, and cloud-init goes into `cloudInit` as a string that starts with `#cloud-config`. Put both objects in one file, separated by `---`.

⚠️ Make the disk exactly 20Gi, the size of the image. It cannot be smaller, and on this testbed a larger one gets stuck while the cloned volume is being grown ([cozystack#5460](https://github.com/cozystack/cozystack/issues/5460)).

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
metadata:
  name: convert
spec:
  source:
    image:
      name: ubuntu-20.04
  storage: 20Gi
  storageClass: replicated
---
apiVersion: apps.cozystack.io/v1alpha1
kind: VMInstance
metadata:
  name: convert
spec:
  instanceType: u1.large
  instanceProfile: ubuntu
  disks:
    - name: convert
  cloudInit: |
    #cloud-config
    password: ubuntu
    chpasswd: { expire: false }
    ssh_pwauth: true
    package_update: true
    packages: [virt-v2v, libguestfs-tools, qemu-utils, awscli]
```

</details>

```bash
git add platform/convert.yaml
git commit -m "Temporary VM for disk conversion"
git push
kubectl get vminstances -w
```

**You should see:** the `convert` VM appear within a minute and turn `READY True` a minute or two later. Stop watching with `Ctrl-C`, then check the disk as well: `kubectl get vmdisks`.

<details><summary>What u1.large means</summary>

An instance type is a named size, like an EC2 type: `u1.large` is 2 vCPU and 8 GiB. The platform has a ladder of them:

```bash
kubectl get virtualmachineclusterinstancetypes -o custom-columns=NAME:.metadata.name,CPU:.spec.cpu.guest,MEMORY:.spec.memory.guest | grep -E '^NAME|^u1\.'
```

Named sizes keep VMs comparable and quotas predictable. When you need an exact shape, as in part 3, a `VMInstance` takes `resources` instead.

</details>

### 2.2 Convert the disk

📍 Inside the conversion VM.

`Running` means the VM is powered on, not that it is ready: cloud-init needs a few more minutes to install the packages.

```bash
virtctl console vm-instance-convert
```

Log in as `ubuntu` / `ubuntu` (press Enter if the screen stays blank), then:

```bash
sudo -i
cloud-init status --wait
which virt-v2v aws
```

**You should see:** `status: done`, then two paths. If it says `status: error` but both tools are there, carry on: an optional package step complained, and it does not matter here.

Download the OVA. During the live workshop it comes from the testbed's own object storage, which is fast and costs no internet traffic. On your own, use the public copy on GitHub instead.

```bash
cd /root
curl -fLo app-1.ova https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova
# on your own: https://github.com/aenix-org/cozystack-workshop/releases/download/vmware-demo-ova/app-1.ova
tar tvf app-1.ova
```

**You should see:** about 800 MB downloaded and three files in the archive: `app-1.ovf` (the description), `app-1-disk1.vmdk` (the disk) and `app-1.mf` (checksums).

Convert it:

```bash
mkdir -p /root/out
virt-v2v -i ova app-1.ova -o local -os /root/out -of qcow2 -on app-1
```

Read the command as a sentence: the input (`-i`) is an OVA file; the output (`-o`) goes to a local folder (`-os`, which must already exist); the output format (`-of`) is QCOW2; the converted VM is called `app-1`. Without `-of qcow2` you get a raw image the full size of the disk.

**You should see:** numbered stages over about five minutes: `Opening the source`, `Inspecting the overlay`, `Converting CentOS Linux release 7.8.2003 (Core) to run on KVM`, `Copying disk 1/1`, `Finishing off`. A warning about `grub/device.map` and `vda` is harmless.

```bash
ls -lh /root/out
qemu-img info /root/out/app-1-sda
```

**You should see:** `app-1-sda` (the disk, about 1.7 GB) and `app-1.xml` (a libvirt description you will not need), `file format: qcow2`, `virtual size: 8 GiB`.

<details><summary>What virt-v2v changed inside the guest</summary>

It did more than repack the file. It opened the CentOS file system, made sure the virtio drivers are in the initramfs so the guest can see a KVM disk and NIC instead of VMware's SCSI controller and E1000, removed VMware Tools and fixed the boot configuration. A plain `qemu-img convert` would have produced a disk that often does not boot on KVM.

</details>

### 2.3 Upload the disk and get a link

The bucket keys are in the Secret from 1.1. Open a second SSH session to the bastion:

```bash
kubectl get secret bucket-images-convert-credentials -o go-template='{{range $k, $v := .data}}{{$k}}={{$v | base64decode}}{{"\n"}}{{end}}'
```

📍 Back inside the conversion VM, paste your values:

```bash
export AWS_ACCESS_KEY_ID=<accessKey>
export AWS_SECRET_ACCESS_KEY=<secretKey>
export BUCKET=<bucketName>
export S3=https://s3.workshop.aenix.io

aws --endpoint-url $S3 s3 cp /root/out/app-1-sda s3://$BUCKET/app-1.qcow2
aws --endpoint-url $S3 s3 ls s3://$BUCKET/
aws --endpoint-url $S3 s3 presign s3://$BUCKET/app-1.qcow2 --expires-in 86400
```

The Secret's `endpoint` is the same host without `https://`.

**You should see:** the upload progress, then `app-1.qcow2` in the bucket, then a long URL. Copy that URL. It is a presigned link: anyone holding it can download this one object for 24 hours without keys. The platform will use it in part 3.

Log out of the VM (`exit` twice) and leave the console with `Ctrl-]`.

### 2.4 Throw the conversion VM away through Git

📍 On the bastion.

The conversion VM holds 2 vCPU and 8 GiB of your quota. Remove it the GitOps way, by deleting its file:

```bash
cd ~/vmware-migration
git rm platform/convert.yaml
git commit -m "Conversion done, remove the temporary VM"
git push
kubectl get vminstances -w
```

**You should see:** within a minute or two `convert` disappears from the list, and `kubectl get vmdisks` no longer shows it either. Flux noticed the file was gone and deleted the objects it had created from it. That is the `prune: true` setting of your `platform` Kustomization (`kubectl get kustomization platform -o yaml`).

> **Stop and think.** What would have happened if you had deleted the VM with `kubectl delete vminstance convert` and left the file in Git?

<details><summary>Answer</summary>

Flux would have recreated it within a minute: the repository still says it should exist. In GitOps you change the repository, not the platform. For the same reason a VM someone deletes by mistake comes back by itself.

</details>

## Part 3. The application VM (20 min)

### 3.1 Write it

Write `platform/app-1.yaml` with a `VMDisk` and a `VMInstance`, both named `app-1`:

- the disk downloads its data from your presigned URL and is 10Gi on `replicated` storage (the guest disk is 8 GiB; leave some room);
- the VM has exactly the shape you wrote down in 0.3, set with `resources` rather than an instance type, uses the profile for CentOS 7 and boots from the `app-1` disk.

Hints: an HTTP source is `source.http.url`; put the URL in quotes, it contains `&` and `=`. The profile names are listed by `kubectl get virtualmachineclusterpreferences`.

⚠️ `resources` sizes the VM only when `cpu`, `sockets` and `memory` are all set. If you give only some of them, the platform refuses the VM and explains why in the HelmRelease status. That message is worth reading once on purpose.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: VMDisk
metadata:
  name: app-1
spec:
  source:
    http:
      url: "<your presigned URL>"
  storage: 10Gi
  storageClass: replicated
---
apiVersion: apps.cozystack.io/v1alpha1
kind: VMInstance
metadata:
  name: app-1
spec:
  instanceProfile: centos.7
  resources:
    cpu: 2
    sockets: 1
    memory: 2Gi
  disks:
    - name: app-1
```

</details>

```bash
git add platform/app-1.yaml
git commit -m "Move app-1 from VMware"
git push
kubectl get datavolumes -w
```

**You should see:** `vm-disk-app-1` going through `ImportScheduled` and `ImportInProgress` with a percentage to `Succeeded`, in about two minutes. Then:

```bash
kubectl get vminstances app-1
kubectl get virtualmachineinstances vm-instance-app-1 -o wide
```

**You should see:** `READY True`, the VM `Running` on one of the nodes, with an address from the cluster network (`10.244.x.x`).

<details><summary>Under the hood: who downloaded the disk</summary>

The `VMDisk` became a DataVolume of CDI (the Containerized Data Importer). CDI started an importer pod that downloaded the QCOW2 file from your link, converted it to a raw block device and wrote it to a replicated volume. The same mechanism imports from an image, from an upload (`virtctl image-upload`) or from another disk (`source.disk`); only the source changes.

</details>

### 3.2 Look inside

📍 In the VM console.

```bash
virtctl console vm-instance-app-1
```

Log in as `root` / `cozydemo`. The VM booted on KVM, but:

```bash
ip -4 addr show eth0
cat /etc/sysconfig/network-scripts/ifcfg-eth0
```

**You should see:** `192.168.10.21/24`, an address from the old VMware network, set statically in `ifcfg-eth0` together with a gateway that does not exist here. The VM has no working network. Leave it like that for now and log out (`Ctrl-]`); part 5 fixes it.

## Part 4. Database and queue from the catalog (15 min)

The application used to talk to a PostgreSQL VM at `192.168.10.30` and a Kafka VM at `192.168.10.40`. You do not move them: you order managed services instead.

### 4.1 PostgreSQL with a replica

Using the [PostgreSQL docs](https://cozystack.io/docs/v1.7/applications/postgres/), write `platform/postgres.yaml`: a `Postgres` named `orders` with a primary and one hot replica, 5Gi each on `replicated` storage, preset `t1.micro`, a user `orders` and a database `orders` that the user administers. Do not set a password: Cozystack generates one.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Postgres
metadata:
  name: orders
spec:
  replicas: 2
  size: 5Gi
  storageClass: replicated
  resourcesPreset: t1.micro
  users:
    orders: {}
  databases:
    orders:
      roles:
        admin: [orders]
```

</details>

### 4.2 Kafka

Using the [Kafka docs](https://cozystack.io/docs/v1.7/applications/kafka/), write `platform/kafka.yaml`: a `Kafka` named `events` with one broker, 5Gi on `replicated` storage, preset `c1.small`, and one topic `orders` with one partition and one replica. Kafka runs in KRaft mode, without ZooKeeper.

<details><summary>Solution</summary>

```yaml
apiVersion: apps.cozystack.io/v1alpha1
kind: Kafka
metadata:
  name: events
spec:
  kafka:
    replicas: 1
    size: 5Gi
    storageClass: replicated
    resourcesPreset: c1.small
  topics:
    - name: orders
      partitions: 1
      replicas: 1
      config: {}
```

</details>

```bash
git add platform/postgres.yaml platform/kafka.yaml
git commit -m "Order the database and the queue from the catalog"
git push
kubectl get postgres,kafka
kubectl get kafka -w
```

**You should see:** both turn `READY True`, PostgreSQL within a few minutes and Kafka within about ten. Carry on with part 5 while they start.

### 4.3 Under the hood: what you got

```bash
kubectl get pods -l cnpg.io/cluster=postgres-orders -L role
kubectl get services | grep -E 'postgres-orders|kafka-events'
```

**You should see:** two pods, one `primary` and one `replica`, managed by the CloudNativePG operator, and the services the application will use: `postgres-orders-rw` (always points to the current primary) and `kafka-events-kafka-bootstrap` on port 9092.

The generated password is in a Secret:

```bash
kubectl get secret postgres-orders-credentials -o jsonpath='{.data.orders}' | base64 -d; echo
```

## Part 5. Bring the application back to life (40 min)

📍 Mostly inside the application VM. No scripts this time: for each problem you find the symptom, then the cause, then fix it. Hints are hidden; open them only when you are stuck.

```bash
virtctl console vm-instance-app-1
```

### 5.1 The network

The VM still believes it lives in VMware's `192.168.10.0/24`. In Cozystack every VM gets its address from the cluster network over DHCP.

Make `eth0` use DHCP, apply the change without a reboot and check that the cluster DNS answers.

<details><summary>Hint</summary>

On CentOS 7 the interface is configured in `/etc/sysconfig/network-scripts/ifcfg-eth0`. You need `BOOTPROTO=dhcp` and no `IPADDR`, `NETMASK`, `GATEWAY` or `DNS1` lines. `systemctl restart network` applies it.

</details>

<details><summary>Solution</summary>

```bash
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^NETMASK/d; /^GATEWAY/d; /^DNS/d' /etc/sysconfig/network-scripts/ifcfg-eth0
cat /etc/sysconfig/network-scripts/ifcfg-eth0
systemctl restart network
ip -4 addr show eth0
cat /etc/resolv.conf
getent hosts postgres-orders-rw kafka-events-kafka-bootstrap
```

</details>

**You should see:** a `10.244.x.x` address, a `search tenant-vmwXX.svc.cozy.local ...` line in `resolv.conf`, and the two service names resolved to addresses.

Thanks to that search line, short service names work inside the VM, exactly as they do for pods.

### 5.2 The application's view of the world

```bash
systemctl status orders-api --no-pager | head -5
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
journalctl -u orders-api --no-pager | tail -5
```

**You should see:** the service is running but unhealthy, and the log complains about `192.168.10.30`.

> **Stop and think.** The VM moved, it boots, the network works. Why is the application still broken?

<details><summary>Answer, and a lesson broader than this error</summary>

Its configuration still points at the database and the queue that lived on two other VMware VMs. We did not move them and never meant to. The application is fine, the VM is fine, the network is fine; only the assumption that the world around it stayed the same is broken.

That is what a real migration looks like. Moving the disk is the easy part. What breaks is everything outside it: addresses, names, credentials, certificates, neighbouring systems.

</details>

Find the configuration file, point it at the managed services and give it the generated password from 4.3. Restart the application.

<details><summary>Hint</summary>

`systemctl cat orders-api` shows how the service starts and which file it reads. Three lines matter: `spring.datasource.url`, `spring.datasource.password` and `spring.kafka.bootstrap-servers`.

</details>

<details><summary>Solution</summary>

```bash
cat /etc/orders/application.properties
PW='<password from postgres-orders-credentials>'
sed -i "s#192.168.10.30:5432#postgres-orders-rw:5432#; s#192.168.10.40:9092#kafka-events-kafka-bootstrap:9092#; s#^spring.datasource.password=.*#spring.datasource.password=$PW#" /etc/orders/application.properties
grep -E 'url|password|servers' /etc/orders/application.properties
systemctl restart orders-api
sleep 15
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

</details>

**You should see:** `200`.

### 5.3 The first order

```bash
curl -s -X POST localhost:8080/api/orders -H 'Content-Type: application/json' -d '{"item":"test"}' -w '\nHTTP %{http_code}\n'
```

**You should see:** `HTTP 500`, although health said `200` a moment ago.

<details><summary>Why health is green and the order still fails</summary>

The health check only tests that a connection to the database opens. Whether the tables the application needs exist, it does not check. And they do not: you ordered an empty database. On the old VM the tables were created by hand years ago, and everybody forgot. `journalctl -u orders-api | grep relation` shows `relation "orders" does not exist`.

</details>

Create the schema. It is in this repository, [`scripts/orders-schema.sql`](scripts/orders-schema.sql): one table and one row of history. There is no point in installing a PostgreSQL client on a CentOS 7 machine whose repositories are long gone: the database is a managed service, so talk to it from the platform side. The database pods carry `psql`.

📍 On the bastion:

```bash
cp ~/workshop/scripts/orders-schema.sql ~/
cd ~
kubectl get pods -l cnpg.io/cluster=postgres-orders -L role
( echo 'SET ROLE orders;'; cat orders-schema.sql ) | kubectl exec -i postgres-orders-1 -c postgres -- psql -d orders -v ON_ERROR_STOP=1
kubectl exec postgres-orders-1 -c postgres -- psql -d orders -c '\dt'
```

Use whichever pod is `primary`. `SET ROLE orders` makes the table belong to the application's user rather than to the superuser the pod logs you in as.

**You should see:** `CREATE TABLE`, `INSERT 0 1`, then the `orders` table owned by `orders`.

📍 Back in the VM:

```bash
curl -s -X POST localhost:8080/api/orders -H 'Content-Type: application/json' -d '{"item":"first order on Cozystack"}' -w '\nHTTP %{http_code}\n'
```

**You should see:** `HTTP 200` and the new order with `"status":"NEW"`.

### 5.4 Did the event reach Kafka?

The application writes every new order to the `orders` topic. Read the topic from the platform side.

📍 On the bastion:

```bash
BROKER=$(kubectl get pods -l strimzi.io/name=kafka-events-kafka,strimzi.io/broker-role=true -o name | head -1)
kubectl exec $BROKER -- bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic orders --from-beginning --timeout-ms 8000
```

The broker pods are labelled by the Strimzi operator that runs Kafka for the catalog; `broker-role=true` picks a broker rather than a KRaft controller.

**You should see:** the ids of the orders you created, then `TimeoutException` and `Processed a total of N messages`. The exception only means eight seconds passed without new messages, which is how `--timeout-ms` stops the consumer. The chain VM → PostgreSQL → Kafka works.

### 5.5 Publish the application over HTTPS

In vSphere you would ask the network team for a VIP and a certificate. Here you describe both in Git: a Kubernetes `Service` that sends traffic to the VM, and an `Ingress` on the platform's ingress controller with a Let's Encrypt certificate.

Write `platform/publish.yaml`:

- a `Service` named `orders` that selects the VM's pod by the label `vm.kubevirt.io/name: vm-instance-app-1` and maps port 80 to 8080;
- an `Ingress` named `orders` with `ingressClassName: tenant-root`, host `orders.vmwXX.workshop.aenix.io`, backend the `orders` Service on port 80, TLS with a certificate from the `letsencrypt-prod` cluster issuer.

<details><summary>Solution</summary>

```yaml
apiVersion: v1
kind: Service
metadata:
  name: orders
spec:
  selector:
    vm.kubevirt.io/name: vm-instance-app-1
  ports:
    - name: http
      port: 80
      targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: orders
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    acme.cert-manager.io/http01-ingress-ingressclassname: tenant-root
spec:
  ingressClassName: tenant-root
  rules:
    - host: orders.vmwXX.workshop.aenix.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: orders
                port:
                  number: 80
  tls:
    - hosts: [orders.vmwXX.workshop.aenix.io]
      secretName: orders-tls
```

</details>

```bash
git add platform/publish.yaml
git commit -m "Publish the order service over HTTPS"
git push
```

Give it a minute, then:

```bash
curl -s https://orders.vmwXX.workshop.aenix.io/actuator/health
```

**You should see:** a timeout, or `502 Bad Gateway`.

> **Stop and think.** The application answers inside the VM. The Service and the Ingress exist. What is still in the way?

<details><summary>Hint</summary>

Something inside the guest that came over from VMware and decides which ports can be reached from outside.

</details>

<details><summary>Solution</summary>

firewalld. The old VM only allowed SSH from the network; the application was reached through a load balancer that is not here any more. Inside the VM:

```bash
firewall-cmd --list-all
systemctl disable --now firewalld
```

In a real migration you would open port 8080 instead (`firewall-cmd --add-port=8080/tcp --permanent && firewall-cmd --reload`). Either way, it is a decision about the guest, not about the platform.

</details>

```bash
curl -s https://orders.vmwXX.workshop.aenix.io/actuator/health
curl -s https://orders.vmwXX.workshop.aenix.io/api/orders
```

**You should see:** `{"status":"UP"}` over HTTPS with a valid certificate, and your orders. Open the same address in a browser.

## Part 6. Day two (25 min)

📍 On the bastion.

The VM has moved. Now see what running it on Cozystack looks like.

### 6.1 Give the VM more memory, through Git

The application team asks for 4 GiB. Change `memory` in `platform/app-1.yaml`, commit and push. Then:

```bash
kubectl get virtualmachines vm-instance-app-1 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

**You should see:** `RestartRequired=True`. CPU and memory of a running VM change only on restart, so the platform waits for you to choose the moment. Restart it:

```bash
virtctl restart vm-instance-app-1
kubectl get virtualmachineinstances vm-instance-app-1 -o jsonpath='{.spec.domain.memory.guest}{" "}{.status.interfaces[0].ipAddress}{"\n"}'
```

**You should see:** `4Gi` and the same IP address as before. The change is in Git with your name on it, and the address survived the restart.

### 6.2 Live-migrate the VM while it serves traffic

Start a loop that creates an order every second. Keep it running in a second SSH session:

```bash
while true; do curl -s -o /dev/null -w "%{http_code} " -X POST https://orders.vmwXX.workshop.aenix.io/api/orders -H 'Content-Type: application/json' -d '{"item":"load"}'; sleep 1; done
```

In the first terminal, move the VM to another node, the way vMotion would:

```bash
kubectl get virtualmachineinstances vm-instance-app-1 -o wide
virtctl migrate vm-instance-app-1
kubectl get virtualmachineinstancemigrations -w
```

**You should see:** the migration going through `Scheduling`, `TargetReady`, `Running` to `Succeeded` in well under a minute, the VM on a different node afterwards with the same IP, and an unbroken row of `200` in the loop (at most one or two hiccups at the switch-over).

The memory is copied while the VM runs; the disk does not move at all, because it sits on replicated storage that every node can reach.

If the migration stays in `Scheduling` for minutes, no other node has enough free memory for a second copy of the VM: a live migration needs room for both the source and the target while memory is being copied. That is a capacity question for whoever runs the platform, and the same one you would ask about DRS headroom in vSphere.

### 6.3 Lose the database primary

Keep the loop running. Find the primary and kill it, as if its server lost power:

```bash
kubectl get pods -l cnpg.io/cluster=postgres-orders -L role
kubectl delete pod <the primary> --grace-period=5
kubectl get pods -l cnpg.io/cluster=postgres-orders -L role -w
```

**You should see:** within seconds the replica becomes `primary`, and the deleted pod comes back as a `replica`. In the loop, a few requests fail for about ten seconds, then `200` again. The application reconnected by itself, because it talks to `postgres-orders-rw`, a name that always points at the current primary.

Stop the loop with `Ctrl-C`.

> **Stop and think.** What did the old VMware setup do when the database VM's host died?

<details><summary>Answer</summary>

vSphere HA restarted the database VM on another host: a minute or two of downtime plus PostgreSQL's crash recovery, and no protection against a broken disk. Here the database is a managed cluster with a hot replica; the operator promotes it in seconds, and the old primary rejoins as a replica without anyone touching it.

</details>

## What you have now

Everything you built is in your repository: `git log --oneline` tells the whole migration as a list of commits, and `platform/` describes the result. Hand that repository to a colleague and their tenant ends up the same.

## If something goes wrong

| Symptom | Likely cause | What to do |
|---|---|---|
| A push changed nothing on the platform | Flux has not picked it up yet, or the YAML is invalid | `kubectl get kustomization platform`; the message names the file and the error |
| `forbidden` on `bucket` | the short name matched another kind | use `buckets.apps.cozystack.io` |
| A VM stays `READY False` | the HelmRelease rejected the values | `kubectl get helmrelease vm-instance-<name> -o yaml`, read `status.conditions` |
| `cloud-init status` never finishes | package installation is still running | wait; `tail -f /var/log/cloud-init-output.log` |
| `virt-v2v: error: -os /root/out ... does not exist` | the output folder must exist | `mkdir -p /root/out` |
| DataVolume stays `ImportInProgress` at 0% or fails | the presigned link expired or was cut when pasting | generate a new link, update `platform/app-1.yaml` |
| The console shows nothing | the screen is blank | press Enter; leave with `Ctrl-]` |
| The VM is `Paused` with an IO error | a storage replica was re-attached under the VM (a known issue on this testbed's node image, [cozystack#3168](https://github.com/cozystack/cozystack/issues/3168)) | `virtctl restart vm-instance-app-1` |
| Health is `200`, orders return `500` | no tables in the new database | part 5.3 |
| HTTPS times out or returns `502` | firewalld in the guest | part 5.5 |
