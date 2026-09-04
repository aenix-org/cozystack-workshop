#!/bin/bash
# माइग्रेट किया गया CentOS 7 इमेज एक स्टैटिक VMware IP रखता है (ifcfg-eth0 BOOTPROTO=static,
# IPADDR=192.168.10.x, GATEWAY=192.168.10.1). इसके कारण VM pod-NIC पर नहीं है और
# managed-सेवाओं को resolve नहीं करता (CoreDNS अनुपलब्ध). हम eth0 को DHCP पर स्विच करते हैं.
#
# app-VM (CentOS 7) के अंदर root के रूप में चलाएँ, फिर VM को पुनः आरंभ करें (डैशबोर्ड -> Restart).
# बदलाव persistent है — यह रिबूट के बाद भी बना रहता है.
# यह netplan नहीं है (वह Ubuntu का है) — CentOS 7 में नेटवर्क ifcfg-eth0 में होता है.
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== पहले =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== बाद में =="; cat "$IFCFG"
echo "== eth0 को DHCP पर स्विच किया गया. अब VM को पुनः आरंभ करें: डैशबोर्ड -> Restart. =="
echo "   रिबूट के बाद: eth0 को pod-NIC (10.244.x) मिलेगा, managed-सेवाएँ resolve होने लगेंगी."
