## 18. Step 3: converting the image

**Turning a VMware image into a KVM image**

📍 **Where:** inside the converter machine you just logged into over the console. Not on the bastion.

📄 We're working with `scripts/convert.sh`. This machine has network access, so it will download the
file itself — no need to copy anything through the clipboard.

Pull the script from GitHub straight onto the machine:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/convert.sh
```

Open it:
```bash
nano convert.sh
```

**Now those three values you jotted down in step 1 come in handy.** Near the top of the
file there's a block labeled «PASTE YOUR VALUES» — replace the placeholders in it with your
own, leaving the quotes in place:

```
BUCKET="your-bucket-name"
ACCESS_KEY="your-accessKey"
SECRET_KEY="your-secretKey"
```

Leave the `S3_ENDPOINT` line and the link to the source image alone — they're already correct
and the same for everyone.

To save in nano: `Ctrl+O`, then `Enter`, then `Ctrl+X` to exit. Check that no placeholders
are left:
```bash
grep ВСТАВЬТЕ convert.sh || echo "all filled in, ready to run"
```

Run it — always through `sudo`, the script needs root privileges. And run it **in `screen`**:
the conversion takes about five minutes, and right now you're on a chain of two connections (your laptop → SSH
to the bastion → the converter machine's console). If any link in the chain drops, an ordinary run
will break off halfway. `screen` keeps the process alive even when the connection drops:

```bash
screen -S convert          # start a separate session
sudo bash convert.sh       # run it inside that session
#  connection dropped? log back in to this same machine, then:  screen -r convert
```

What happens inside: the script downloads the source image, runs `virt-v2v`,
compresses the result and uploads it to your bucket.

The most important work is done by `virt-v2v`. It changes more than just the file format: it slips
virtio drivers into the guest system and fixes up the bootloader. Without this, the machine
won't start at all on the new hypervisor.

⏳ **This will take about five minutes.** Our testbed has no nested virtualization,
so the conversion runs in emulation mode. The progress is visible in the console — don't close it.

At the end the script will print a **presigned link** to your image — look in the output for a line
starting with the word `Share:`, the link comes right after it.

**What to do with it:** copy it into that same notepad. In the next step you'll go back to the bastion, open `manifests/03-app-vm.yaml` and paste it into the `url` field — where
the `ВСТАВЬТЕ_PRESIGNED_URL` placeholder currently sits. The very one I warned you about
when we were filling in the numbers.

This is a temporary signed link: the storage isn't exposed to the outside, and you made the link
with your own keys. It lives for a week — plenty for the workshop and for experimenting afterward.
