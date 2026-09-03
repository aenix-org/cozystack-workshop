## 15. A closer look: what's inside 02-conversion-vm.yaml

The file holds **two** objects, separated by a `---` line. That's how YAML packs several
documents into one file. A virtual machine can't exist without a disk, so the disk is
described separately and is always created first.

```yaml
kind: VMDisk
metadata:
  name: convert-tools
spec:
  source:
    image:
      name: ubuntu-20.04
  storage: 25Gi
  storageClass: replicated
```

`kind: VMDisk` — the disk on its own, a separate object. This takes getting used to: in
vSphere a disk is a property of the machine, here it's a standalone entity you can create
ahead of time, attach to a machine, detach, and attach to another.

`source.image.name: ubuntu-20.04` — where to pull the contents from. This is that same image
catalog from the map above: Cozystack has already downloaded the official Ubuntu 20.04 cloud
image from `cloud-images.ubuntu.com` and keeps it locally. Here we're asking it to make a
copy. Nobody reaches out to the internet for it; the copy is made inside the cluster.

⚠️ **The Ubuntu version is specified deliberately — don't change it.** On 24.04 the machine
won't boot; on 22.04 the repack trips over the old RPM package database inside CentOS 7 —
`virt-v2v` can't parse it. Tested so you don't have to.

`storage: 25Gi` — the disk size. The catalog Ubuntu image takes up 20Gi, and **the disk must
be larger than the image**, otherwise the copy breaks off midway and the disk then hangs in a
`Terminating` state and gets in the way. The headroom is also needed because the downloaded
`app-1.ova` and the repack result will sit inside it at the same time.

`storageClass: replicated` — how to store it. `replicated` means several copies on different
nodes: a node goes down — the data is still there. The analog is a storage policy in vSphere.
There's also `local` — faster, but it lives on a single node.

```yaml
kind: VMInstance
metadata:
  name: convert
spec:
  instanceType: u1.large
  instanceProfile: ubuntu
  runStrategy: Always
  disks:
    - name: convert-tools
```

`instanceType: u1.large` — the machine size, a ready-made bundle of "so many CPUs, so much
memory": here two CPUs and eight gigabytes. The repack holds the image in memory in chunks and
demands it in earnest.

`instanceProfile: ubuntu` — a set of virtual-hardware settings tailored to this guest system:
which disk controllers, which network card, how the clock is passed through. The closest analog
is "Guest OS Type" in the VM creation wizard, which likewise silently changes a dozen settings
to fit the chosen system.

`runStrategy: Always` — keep the machine running, and if it crashes, bring it back up. This
isn't "autostart when the host boots" but a standing rule: the platform makes sure the machine
is running.

`disks` — which disks to attach. A reference by name to the `VMDisk` object described above.

```yaml
  cloudInit: |
    #cloud-config
    password: ubuntu
    packages: [ libguestfs-tools, virt-v2v, qemu-utils ]
    runcmd:
      - [ bash, -c, "wget ... mc && chmod +x /usr/local/bin/mc" ]
```

`cloudInit` — instructions the machine runs by itself on first boot. This is the standard
mechanism of every cloud image: at startup the system looks for such text and executes it. In
vSphere the closest analog is a Customization Specification, only here it's expressed as text
and sits in the same file as the machine itself.

Here we're asking it to set a password, install `virt-v2v` with its dependencies, and download
`mc` — a console client for working with S3 storage, the very one we'll use to upload the
result into the bucket.

⚠️ **The password in plain text** — only for the training testbed: the machine lives for half an
hour and is reachable only from inside the cluster. On a real machine you put ssh keys in place
of `password`.
