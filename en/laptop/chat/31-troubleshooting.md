## 31. When something doesn't work

**A short list of the things people trip over**

• **The application isn't reachable from outside.** On a migrated CentOS the usual culprit
  is the built-in firewall — it's blocking port 8080:
  ```bash
  systemctl stop firewalld
  ```

• **`kubectl` answers "forbidden".** Check that you're talking to your own namespace:
  `-n tenant-workshopXX`. And remember that `vminstance` is available, not `vm` or `vmi`.

• **The order won't be created, yet health still returns `200`.** The table wasn't created —
  go back to the message about the database schema.

• **The new machine (app-VM) is stuck in `Pending`.** The converter machine wasn't shut down —
  it's holding 8Gi of the quota, and there isn't enough left for the new one. Delete it and its disk:
  ```bash
  kubectl delete vminstance convert --namespace tenant-workshopXX
  kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
  ```

• **`mc` reports `Insufficient permissions` when uploading the image.** In `convert.sh` the
  `BUCKET` field holds `my-images` instead of the real `bucketName` (the long `bucket-...-...`).
  Take the `bucketName` from the bucket's secret in the dashboard and put it in.

• **The disk is stuck in the Terminating state.** Most likely the disk size is smaller than the image.
  For ubuntu-20.04 you need at least 25Gi.

• **Nothing helps.** Write here, and we'll work it out together. This is a normal part of the job,
  not something to be embarrassed about — a real migration is the same, only at three in the morning.
