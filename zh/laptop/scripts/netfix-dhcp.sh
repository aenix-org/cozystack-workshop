#!/bin/bash
# 迁移过来的 CentOS 7 镜像带有静态 VMware IP（ifcfg-eth0 BOOTPROTO=static，
# IPADDR=192.168.10.x，GATEWAY=192.168.10.1）。因此该 VM 不在 pod-NIC 上，也无法
# 解析 managed 服务（CoreDNS 不可达）。我们把 eth0 切换到 DHCP。
#
# 在 app-VM（CentOS 7）中以 root 运行，然后重启 VM（仪表盘 -> Restart）。
# 该改动是持久的——重启后依然生效。
# 这不是 netplan（那是 Ubuntu）——CentOS 7 的网络配置在 ifcfg-eth0 里。
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== 修改前 =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== 修改后 =="; cat "$IFCFG"
echo "== eth0 已切换到 DHCP。现在请重启 VM：仪表盘 -> Restart。 =="
echo "   重启后：eth0 将获得 pod-NIC（10.244.x），managed 服务将开始可解析。"
