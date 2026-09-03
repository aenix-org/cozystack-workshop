## 16. Step 2: the converter machine

**Bringing up the VM in which we'll do the conversion**

📍 **Where:** on the laptop.

**What "conversion" is and why there's no way around it.** A virtual machine's disk is a file. VMware stores it in its own format, `VMDK`. KVM, which runs the VMs in Cozystack, doesn't understand that format — it needs `QCOW2`. The contents are the same, your CentOS with all its trimmings, but the packaging is different. Conversion is repacking the file from one format into the other; the data itself doesn't change.

On top of that, you have to fix up what's inside. A system that grew up in vSphere expects to find VMware's virtual hardware: its own network cards, its own disk controllers, the `vmxnet3` and `pvscsi` drivers. In the new home the hardware is different — `virtio`. If you don't slip the right drivers into the boot image ahead of time, the machine starts up and finds neither disk nor network. Conversion takes care of this too.

**Why a separate machine, and not your laptop.** The tool is called `virt-v2v`, and it drags along a mountain of dependencies, runs under Linux, and chews through tens of gigabytes. Installing it on your working laptop just for a one-off is a bad idea, and on Windows and macOS it won't run at all. It's easier to bring up a throwaway machine next to the storage, do the job inside it, and shut it down.

As a bonus, this is exactly the approach used for conversion in real migration projects: the converter lives next to the data, not on someone's laptop over a VPN.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

We wait for the `Running` state (press Ctrl+C to stop watching). We go inside **through the console**:

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

**Access to the converter machine:**
```
login:    ubuntu
password: ubuntu
```

To leave the console — `Ctrl+]`. If the screen is blank, press Enter.

⚠️ **Do not go in via `virtctl ssh`.** At previous workshops it didn't work for anyone: it answers `exit status 255` and drops the connection. The console goes through the cluster API and always works. The same thing is available with the mouse — the **VNC** button on the machine's page in the dashboard.

**What exactly this command created.** The file describes two objects, so two entries will show up in the dashboard, not one:

• **VM Disk** named `convert-tools` — a 25Gi disk, cloned from the catalog image `ubuntu-20.04`
• **VM Instance** named `convert` — the machine itself, which attaches that disk

A VM never exists without a disk — that's why the disk is always created first, as a separate object. Remember this; on step 4 you'll see exactly the same pair.

⚠️ And a word about names right away, or you'll get confused. The object in the dashboard is called `convert`, but the machine it brings up is known inside the cluster as **`vm-instance-convert`** — with the prefix. So in the dashboard you look for `convert`, while in `virtctl` commands you write `vm-instance-convert`.

🖱 **Via the dashboard:** you create the same two objects by hand, one after the other.
**1)** **VM Disk → Deploy new**: name `convert-tools`, source = **image**, image `ubuntu-20.04`, size `25Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: name `convert`, instance type `u1.large`, profile `ubuntu`, and in the list of disks you pick `convert-tools` — the one you created a step earlier. You can go inside right there with the **VNC** button, and then neither ssh nor virtctl is needed, everything's in the browser.

⚠️ Make the disk no smaller than 25Gi: if it's smaller than the image, the clone won't go through, and then the disk hangs in the Terminating state and gets in the way.

⚠️ The manifest deliberately specifies the **ubuntu-20.04** image; don't change it. On 24.04 the machine doesn't boot, and on 22.04 the conversion trips over the old package database inside CentOS 7. We checked this so that you don't have to.
