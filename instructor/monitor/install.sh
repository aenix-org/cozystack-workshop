#!/bin/bash
# Installs the participant recorder and the monitor on the bastion. Run with sudo from the unpacked directory.
set -euo pipefail
cd "$(dirname "$0")"
install -d -m 755 /opt/ws-monitor /etc/ws-monitor
install -m 644 ws-monitor.py index.html /opt/ws-monitor/
install -m 644 hook.bash /etc/ws-monitor/hook.bash
install -m 644 zz-ws-record.sh /etc/profile.d/zz-ws-record.sh
[ -f /etc/ws-monitor/exclude ] || printf 'ubuntu\nroot\n' > /etc/ws-monitor/exclude
install -d -m 1733 -o root -g root /var/log/ws-sessions
line='[ -r /etc/ws-monitor/hook.bash ] && . /etc/ws-monitor/hook.bash'
grep -qxF "$line" /etc/bash.bashrc || printf '\n# workshop monitor: command events of recorded shells\n%s\n' "$line" >> /etc/bash.bashrc
install -m 644 ws-monitor.service /etc/systemd/system/ws-monitor.service
systemctl daemon-reload
systemctl enable --now ws-monitor
systemctl restart ws-monitor
sleep 1
systemctl --no-pager --lines=3 status ws-monitor | head -5
