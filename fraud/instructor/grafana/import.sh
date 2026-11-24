#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <grafana-url> <user> <password>" >&2
  exit 1
fi

GRAFANA_URL="$1"
USER="$2"
PASSWORD="$3"
DASHBOARD_FILE="$(cd "$(dirname "$0")" && pwd)/fraud-dashboard.json"

PAYLOAD=$(python3 - "$DASHBOARD_FILE" <<'EOF'
import json
import sys

with open(sys.argv[1]) as f:
    dashboard = json.load(f)
dashboard["id"] = None
print(json.dumps({"dashboard": dashboard, "overwrite": True, "folderUid": "", "inputs": []}))
EOF
)

RESPONSE=$(curl -sS -u "$USER:$PASSWORD" \
  -H "Content-Type: application/json" \
  -X POST \
  -d "$PAYLOAD" \
  "$GRAFANA_URL/api/dashboards/db")

python3 - "$GRAFANA_URL" "$RESPONSE" <<'EOF'
import json
import sys

url = sys.argv[1].rstrip("/")
resp = json.loads(sys.argv[2])
print(f"{url}/d/{resp['uid']}/{resp['slug']}")
EOF
