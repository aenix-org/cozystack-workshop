#!/bin/bash
# 移行された CentOS 7 イメージは VMware の静的 IP を保持している(ifcfg-eth0 BOOTPROTO=static,
# IPADDR=192.168.10.x, GATEWAY=192.168.10.1)。このため VM は pod-NIC 上になく、
# managed サービスを解決できない(CoreDNS に到達不可)。eth0 を DHCP に切り替える。
#
# app-VM(CentOS 7)内で root として実行し、その後 VM を再起動する(ダッシュボード -> Restart)。
# 変更は永続的で、再起動しても維持される。
# これは netplan ではない(それは Ubuntu)— CentOS 7 ではネットワークは ifcfg-eth0 にある。
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== 変更前 =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== 変更後 =="; cat "$IFCFG"
echo "== eth0 を DHCP に切り替えました。今すぐ VM を再起動してください: ダッシュボード -> Restart。 =="
echo "   再起動後: eth0 は pod-NIC(10.244.x)を取得し、managed サービスの解決が始まります。"
