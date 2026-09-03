## 10. The materials are already on the bastion

**Nothing to clone**

📍 **Where:** on the bastion you just logged into over SSH.

The materials folder already sits in your home directory, and **your tenant number is already filled in**. The `tenant-workshopXX` placeholders were replaced with your `tenant-workshopNN` when the bastion was prepared — there is nothing to find and replace, just apply the files as they are.

Go into the folder and see what's inside:

```bash
cd ~/workshop
ls manifests scripts
```

You should see four manifests and four scripts — the very ones from the file map. Confirm that the number filled in is yours:

```bash
grep -m1 namespace manifests/01-bucket.yaml
```

The `namespace:` line will hold your `tenant-workshopNN`, not `tenant-workshopXX`.

**If you get lost**, the way back is always the same:
```bash
cd ~/workshop
```

**What to open files with for editing.** You'll need this exactly once — to paste the presigned URL into `manifests/03-app-vm.yaml` in the third phase. `nano` will do:
`nano manifests/03-app-vm.yaml` (save: `Ctrl+O`, `Enter`, exit: `Ctrl+X`).

The only placeholder deliberately left in is in `manifests/03-app-vm.yaml`, the line
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. You'll get that URL once you convert the image. For now, just know it's waiting for you there.
