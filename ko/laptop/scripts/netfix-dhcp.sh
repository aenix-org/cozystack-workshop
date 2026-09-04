#!/bin/bash
# 마이그레이션된 CentOS 7 이미지는 정적 VMware IP를 그대로 가지고 있습니다(ifcfg-eth0 BOOTPROTO=static,
# IPADDR=192.168.10.x, GATEWAY=192.168.10.1). 이 때문에 VM이 pod-NIC에 붙지 못하고
# managed 서비스를 resolve하지 못합니다(CoreDNS에 접근 불가). eth0을 DHCP로 전환합니다.
#
# app-VM(CentOS 7) 안에서 root로 실행한 뒤, VM을 재시작하세요(대시보드 -> Restart).
# 이 변경은 영구적입니다 — 재부팅 후에도 유지됩니다.
# 이것은 netplan이 아닙니다(그건 Ubuntu) — CentOS 7에서는 네트워크가 ifcfg-eth0에 있습니다.
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== 변경 전 =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== 변경 후 =="; cat "$IFCFG"
echo "== eth0을 DHCP로 전환했습니다. 이제 VM을 재시작하세요: 대시보드 -> Restart. =="
echo "   재부팅 후: eth0이 pod-NIC(10.244.x)을 받고, managed 서비스가 resolve되기 시작합니다."
