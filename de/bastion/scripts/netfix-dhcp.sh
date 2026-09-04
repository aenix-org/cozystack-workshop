#!/bin/bash
# Das migrierte CentOS-7-Image trägt eine statische VMware-IP (ifcfg-eth0 BOOTPROTO=static,
# IPADDR=192.168.10.x, GATEWAY=192.168.10.1). Deshalb ist die VM nicht am pod-NIC und
# resolvt keine managed Services (CoreDNS nicht erreichbar). eth0 auf DHCP umschalten.
#
# In der app-VM (CentOS 7) als root ausführen, DANACH die VM neu starten (Dashboard -> Restart).
# Die Änderung ist persistent — sie übersteht einen Reboot.
# DAS IST NICHT netplan (das ist Ubuntu) — bei CentOS 7 liegt das Netzwerk in ifcfg-eth0.
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== vorher =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== nachher =="; cat "$IFCFG"
echo "== eth0 auf DHCP umgeschaltet. STARTEN SIE JETZT die VM neu: Dashboard -> Restart. =="
echo "   Nach dem Reboot: eth0 erhält ein pod-NIC (10.244.x), managed Services beginnen zu resolven."
