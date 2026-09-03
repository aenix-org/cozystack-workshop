## 30. Step 9: verify the whole chain

**The moment of truth**

⚠️ **First — inside the virtual machine — shut down firewalld.** The migrated CentOS
carried over rules from its past life and exposes only SSH to the outside. The application
port is closed, and from the outside this will look like "the application is down."

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Check right there, from inside the machine, that the application is alive:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — the application is responding. `503` — go back to the networking step. Here
`localhost` is the machine you are sitting in: the application is checking itself.

📍 **Next — a check from the outside, by domain name.** Port forwarding is not needed on this
path: the instructor created an `Ingress` in your tenant ahead of time, and as soon as the
application inside the machine is listening on `8080`, the shop is published at
`https://app.workshopXX.workshop.aenix.io` (`XX` is your number). Open it in the browser on
your laptop — or check with `curl` right on the bastion:

```bash
# health
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

# create an order
curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# see that it was recorded
curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

⚠️ While the app-VM is not up yet or still booting, the domain answers `503` — this is
normal: the `Ingress` is waiting for the backend. Once you see `200`, the machine inside is
listening on `8080`.

If the order was created — you have walked the whole path. The application came over from
VMware, runs in the cluster, writes to a managed database, and sends events to a managed queue.

Half an hour ago this system was living on ESXi.
