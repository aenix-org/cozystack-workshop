## 21. Step 4: your virtual machine

**Bringing up a machine from your own image**

📍 **Where:** on your laptop.

⚠️ **First, shut down the converter machine** — it has done its job and is holding 8Gi of your quota.
If you don't get rid of it, the new machine will hang in `Pending`, and it will look
like the testbed is broken. In past workshops almost everyone got stuck here:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

The image stays in the bucket — that's what we'll bring the machine up from.

Now open `manifests/03-app-vm.yaml`, paste the presigned link into the `url` field
and apply it:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

First the cluster downloads the image from the link and spreads it across the replicas — this takes a minute or two.
Then the machine starts.

Let's get inside:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

**Access to your machine:**
```
login:    root
password: cozydemo
```

To leave the console — `Ctrl+]`.

**Here you have the same pair of objects as with the converter machine**, only the disk isn't
taken from the catalog — it's downloaded from your link:

• **VM Disk** `app-1` — 10Gi, source = http, that same presigned URL
• **VM Instance** `app-1` — profile `centos.7`, instance type `u1.medium`

The names match, and that's fine: the disk and the machine are different object types. In `virtctl`
commands the machine, as last time, is addressed with its prefix: **`vm-instance-app-1`**.

🖱 **Through the dashboard:** **1)** **VM Disk → Deploy new**: name `app-1`, source = **http**,
in the URL field — the presigned link, size `10Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: name `app-1`, instance type `u1.medium`,
profile `centos.7`, disk — `app-1`. The console — the **VNC** button on the machine's page.

Notice what you just did: you described a virtual machine in text
and applied it with a single command. You can drop this file into a repository and bring up
a hundred machines just like it without making a single click.
