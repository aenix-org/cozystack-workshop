## 30. Step 9: verify the whole chain

**The moment of truth**

⚠️ **First — inside the virtual machine — shut down firewalld.** The migrated CentOS
carried over rules from its past life and exposes only SSH to the outside. The application
port is closed, and a port-forward from your laptop will run into `no route to host` — and
this will look like "the application is down."

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Check right there, from inside the machine, that the application is alive:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — you can port-forward. `503` — go back to the networking step.

📍 **Next — on your laptop.** Forward the application port to yourself:
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```
Don't close the window with this command: the tunnel lives as long as it keeps running.

⚠️ **Here `vmi/` is required, whereas in `virtctl console` it's the opposite — it gets in the
way.** This is not a typo or a whim of ours: the two commands have different target syntax.
`port-forward` requires `type/name` and without the prefix answers `target must contain type
and name separated by '/'`. `console` expects just the name and with the prefix answers
`forbidden`, because it takes the word `vmi` to be the machine's name.

If virtctl complains about a version mismatch between the client and the cluster — that is a
warning, not an error, and it doesn't get in the way.

If the port-forward still won't come up, the same tunnel can be made through the machine's Pod:
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <pod-name-from-output> 8080:8080
```

In another terminal window:
```bash
# health
curl -s http://localhost:8080/actuator/health

# create an order
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# see that it was recorded
curl -s http://localhost:8080/api/orders
```

If the order was created — you have walked the whole path. The application came over from
VMware, runs in the cluster, writes to a managed database, and sends events to a managed queue.

Half an hour ago this system was living on ESXi.
