## 26. First check: try to start it and catch the error

**Don't skip this step. It's the most useful one of all.**

📍 **Where:** inside your VM — the one you brought up in phase three (app-VM). Not on the bastion.

The VM has moved, booted, and the network works. By all logic it should just run — the application is sitting on this VM exactly where it always sat, we never touched it. Let's check:

```bash
systemctl status orders-api
curl -s -o /dev/null -w 'HTTP %{http_code}\n' localhost:8080/actuator/health
```

**It doesn't work.** The service either failed to come up or answers with `503`. Let's see what it's complaining about:

```bash
journalctl -u orders-api --no-pager | tail -20
```

The log will show something along the lines of `Connection to 192.168.10.30:5432 refused`, or a timeout against that same address.

> **Stop and think before you read on.**
>
> We never touched the application, the VM booted, the network works. Why won't it start?

<details>
<summary><b>The answer, and a lesson broader than this error</b></summary>

Because the config has the addresses `192.168.10.30` and `192.168.10.40` hard-wired into it — the database and the queue, which lived on **two other VMs in vSphere**. We didn't bring them over and never intended to. There's nothing at those addresses here.

The application is fine, the VM is fine, the network is fine. The only thing that's broken is the assumption that the world around it stayed the same.

**This is what a real migration is.** Moving a disk is the easiest part of it, and it's the part that usually gets all the attention. What breaks is always what's on the outside: addresses, DNS names, credentials, certificates, neighboring systems. That's why in a real project you budget a day for moving the VM and weeks for "getting it working."

You just saw that for yourself in two minutes and the hard way, not in someone else's slide deck.

</details>

**What we do next.** We're going to fix not the application but its picture of the world: in place of the hard-wired IPs we'll put the names of the managed services we brought up in step 5.
