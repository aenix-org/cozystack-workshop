## 17. A closer look: what's inside convert.sh

The script has five steps, and each one prints what it's up to.

**Step 1 — checking for hardware acceleration.** It looks for the `/dev/kvm` device.
Internally, `virt-v2v` spins up a tiny virtual machine to get inside the image — and if the
processor is passed through into our machine, this nested virtualization runs fast. If it
isn't, a software mode kicks in: slower, but it works. The line
`LIBGUESTFS_BACKEND=direct` is exactly that switch into such a mode.

**Step 2 — downloading the source image.**

```bash
wget -O source.ova "$OVA_URL"
```

It pulls `app-1.ova` from the workshop's shared storage — the very one on the map above. The
instructor uploaded the file there ahead of time. **In your own project, this is where an
export from vSphere would go:** `Export OVF Template` or `ovftool`, and then the same
repackaging.

**Step 3 — the repackaging itself.**

```bash
virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app
```

`-i ova` — what goes in: a file in OVA format. `-o local -os /root/out` — where to put the
result: into the local folder `/root/out`. `-of qcow2` — a **required** flag: without it
`virt-v2v` will pick a default format, and the platform won't accept that disk. `-on app` —
what to name the result, and that's where the file name `app.qcow2` comes from.

This will take a few minutes — lines like `Copying disk 1/1` will scroll across the screen.
This is exactly where that second, invisible work with the drivers mentioned above happens.

**Step 4 — uploading into your bucket.**

```bash
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app.qcow2 "mybucket/$BUCKET/app.qcow2"
```

`mc alias set` remembers the storage address and keys under the short name `mybucket`, so you
don't have to repeat them in every command afterwards. `mc cp` copies the file — the syntax is
deliberately the same as ordinary `cp`.

**Step 5 — a link for the platform.**

```bash
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"
```

It creates a temporary signed link valid for seven days (168 hours). Signed — meaning a
cryptographic signature is baked into the address, and with this link anyone can download the
file, but only with it and only while it's alive. There's no need to open the bucket to the
whole world, and no need to hand your access keys to the platform either.

Look for the link in the output after the word `Share:` — you'll need it in the next phase.
