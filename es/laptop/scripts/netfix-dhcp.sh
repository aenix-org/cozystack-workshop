#!/bin/bash
# La imagen migrada de CentOS 7 lleva una IP estática de VMware (ifcfg-eth0 BOOTPROTO=static,
# IPADDR=192.168.10.x, GATEWAY=192.168.10.1). Por eso la VM no está en la pod-NIC y no
# resuelve los servicios gestionados (CoreDNS inaccesible). Cambiamos eth0 a DHCP.
#
# Ejecutar dentro de la app-VM (CentOS 7) como root, LUEGO reiniciar la VM (panel -> Restart).
# El cambio es persistente — sobrevive a un reinicio.
# ESTO NO ES netplan (eso es Ubuntu) — en CentOS 7 la red está en ifcfg-eth0.
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== antes =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== después =="; cat "$IFCFG"
echo "== eth0 cambiado a DHCP. AHORA reinicie la VM: panel -> Restart. =="
echo "   Tras el reinicio: eth0 obtendrá una pod-NIC (10.244.x), los servicios gestionados empezarán a resolverse."
