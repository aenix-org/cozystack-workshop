# Workshop chat messages — the bastion path

One file, one message. Post them as the hands-on work goes along, not all at once.

This set is for participants who work **through the shared bastion (VM)**:
the tools and cluster access are already on the bastion, the tenant number is filled into the files
ahead of time, and the application is checked by its domain name. The set for working from your own laptop is
in [`../../laptop/chat/`](../../laptop/chat/).

Message numbering runs continuously with the laptop set (which is why it has gaps: the posts about
installing tools aren't needed here).

| # | Message | File |
|---|---|---|
| 1 | What we're actually doing | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | A little glossary: what it's called on your side and what it's called here | [`02-glossary.md`](02-glossary.md) |
| 3 | Before you begin: what you'll need | [`03-prerequisites.md`](03-prerequisites.md) |
| 8 | Logging in to the bastion | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 10 | The materials are already on the bastion | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | File map: what lives where and where it runs | [`11-file-map.md`](11-file-map.md) |
| 12 | Phase 1. Getting the image out of vSphere | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | A closer look: what's inside 01-bucket.yaml | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | Step 1: your own storage | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | A closer look: what's inside 02-conversion-vm.yaml | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | Step 2: the converter machine | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | A closer look: what convert.sh does | [`17-convert-script.md`](17-convert-script.md) |
| 18 | Step 3: converting the image | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | Phase 2. Bringing the machine up in its new home | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | A closer look: what's inside 03-app-vm.yaml | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | Step 4: your virtual machine | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | Phase 3. Throwing out the menagerie | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | A closer look: what's inside 04-managed.yaml | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | Step 5: a database and a queue from the catalog | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | Step 6: fixing the network inside the machine | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | First check: we try to start it and hit an error | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | Step 7: pointing the application at the managed services | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | Step 8: why the application still crashes | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | Step 8: installing the client and applying the schema | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | Step 9: verifying the whole chain | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | If something isn't working | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | After the workshop | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
