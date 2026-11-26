#!/bin/bash
# The migrated CentOS 7 image carries a static VMware IP (ifcfg-eth0 BOOTPROTO=static,
# IPADDR=192.168.10.x, GATEWAY=192.168.10.1). Because of this the VM is not on the pod-NIC and does not
# resolve managed services (CoreDNS unreachable). We switch eth0 to DHCP.
#
# Run inside the app-VM (CentOS 7) as root, THEN restart the VM (dashboard -> Restart).
# The change is persistent — it survives a reboot.
# THIS IS NOT netplan (that is Ubuntu) — on CentOS 7 the network is in ifcfg-eth0.
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== before =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== after =="; cat "$IFCFG"
echo "== eth0 switched to DHCP. NOW restart the VM: dashboard -> Restart. =="
echo "   After reboot: eth0 will get a pod-NIC (10.244.x), managed services will start resolving."
