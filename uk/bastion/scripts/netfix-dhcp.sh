#!/bin/bash
# Мігрований образ CentOS 7 несе статичну VMware IP-адресу (ifcfg-eth0 BOOTPROTO=static,
# IPADDR=192.168.10.x, GATEWAY=192.168.10.1). Через це VM не на pod-NIC і не
# резолвить керовані сервіси (CoreDNS недоступний). Перемикаємо eth0 на DHCP.
#
# Запускати в app-VM (CentOS 7) під root, ПОТІМ перезапустити VM (дашборд -> Restart).
# Зміна персистентна — переживає перезапуск.
# ЦЕ НЕ netplan (це Ubuntu) — у CentOS 7 мережа в ifcfg-eth0.
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== було =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== стало =="; cat "$IFCFG"
echo "== eth0 перемкнено на DHCP. ТЕПЕР перезапустіть VM: дашборд -> Restart. =="
echo "   Після ребута: eth0 отримає pod-NIC (10.244.x), керовані сервіси почнуть резолвитися."
