## 27. Step 7: switch the application over to the managed services

**Replace hard-coded addresses with names**

📍 **Where:** inside your VM, after the reboot.

📄 This is the content of `scripts/connect-managed.sh`. Type it out by hand too — for the same reason, and because it's only three commands.

Inside the machine, open the application config:
```bash
cat /etc/orders/application.properties
```
You'll see those same `192.168.10.30` and `192.168.10.40`. This is the pain of every legacy system: nobody remembers anymore why these particular addresses.

Replace them with the service names (substitute your own number for `XX`):
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
(two commands rather than one with a line break: a line break often gets lost when copying from chat, and the command ends up running only halfway)

Check it:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200` — the application can see both the database and the queue. If you get `503`, go back to the networking step; most likely the address didn't change.
