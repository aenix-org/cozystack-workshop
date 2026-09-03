## 20. A closer look: what's inside 03-app-vm.yaml

Two objects again — a disk and a machine.

```yaml
kind: VMDisk
spec:
  source:
    http:
      url: "ВСТАВЬТЕ_PRESIGNED_URL"
  storage: 10Gi
```

`source.http` instead of `source.image` — that's the whole difference from the previous phase. Here you paste in the link from the `convert.sh` output, the one that comes after the word `Share:`. Paste it in full, including the long "tail" after the question mark: that tail is the signature, and without it the platform will be denied access.

```yaml
kind: VMInstance
spec:
  instanceType: u1.medium
  instanceProfile: centos.7
  disks:
    - name: app-1
```

`instanceProfile: centos.7` — a virtual-hardware profile for an old system. It matters more than it looks: CentOS 7 runs a kernel from 2016, and some modern virtual-hardware settings are beyond it. The profile picks the ones such a kernel knows how to work with.

This, by the way, is the general answer to the question "will it even run an old system?" It will, as long as you tell the platform the system is old.
