## 25. Step 6: fix the network inside the machine

**Network first, everything else after**

📍 **Where:** inside your virtual machine, in the console. Not on the laptop.

📄 This is the contents of `scripts/netfix-dhcp.sh` from the repository. **You don't need to download it into the machine, and you can't** — the machine has no network yet, and that missing network is exactly our breakage. Type the commands by hand; there are two of them. The file lives in the repository so you can reread it later.

The application is down right now, and this is not a fault of the testbed. The past still lingers inside the image: a static address from the VMware network and a gateway that doesn't exist here. The machine clings to them and sees neither the cluster DNS nor its neighbors.

Enter the machine through the console — from the laptop:
```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```
🖱 **Or with the mouse:** in the dashboard, open your machine and click **VNC** — it's the same console, just in the browser. Both paths go through the cluster API and work even now, when the network inside the machine is broken.

Next — inside the machine (this is CentOS, the network is configured here, not in netplan):
```bash
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' /etc/sysconfig/network-scripts/ifcfg-eth0
```
Check with your own eyes what came out:
```bash
cat /etc/sysconfig/network-scripts/ifcfg-eth0
```
The line `BOOTPROTO=dhcp` should remain, and there should be no lines with an address or a gateway. If you edit it by hand with `nano`, the result is the same, just slower.

Now the machine needs to be restarted:
```bash
reboot
```
🖱 **Or with the mouse:** in the dashboard, on the machine's page, the **Restart** button.

After the reboot, check that the address has become a cluster one:
```bash
ip -4 addr show eth0
```
It should be something like `10.244.x.x`. That means the machine is on the cluster network and sees its DNS.

⚠️ Order matters: while the address is still the old one, service names don't resolve, and there's no point editing the application's config.
