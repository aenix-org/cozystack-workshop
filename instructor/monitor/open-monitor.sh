#!/bin/bash
# Opens the participant monitor in the browser through an SSH tunnel to the bastion.
# Usage: ./open-monitor.sh <user@bastion> [participant1,participant2,...]
set -euo pipefail
if [ $# -lt 1 ]; then
  echo "usage: $0 <user@bastion> [participant1,participant2,...]" >&2
  exit 2
fi
BASTION="$1"
users="${2:-}"
PORT="${PORT:-8088}"
ssh -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -N -L "$PORT:/run/ws-monitor/monitor.sock" "$BASTION" &
tunnel=$!
trap 'kill $tunnel 2>/dev/null' EXIT INT TERM
sleep 2
url="http://localhost:$PORT/${users:+?u=$users}"
if command -v open >/dev/null; then open "$url"; elif command -v xdg-open >/dev/null; then xdg-open "$url"; fi
echo "Monitor: $url  (Ctrl-C closes the tunnel)"
wait $tunnel
