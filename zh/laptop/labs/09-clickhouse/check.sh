#!/usr/bin/env bash
# Check for lab 9: ClickHouse holds a log of entry passes and a report is computed from it.
#
# We check not "the service was created" but the substance: the table exists, at least a million rows,
# the data is varied and has pronounced peaks, the monthly report runs in
# milliseconds, and a single-column query reads a small fraction of the table — that is,
# columnar storage works, it is not merely claimed.
#
# Run (in each new terminal window the variables are set again):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # your own number instead of XX
#   export CH_PASSWORD='password of the analyst user'
#   cd labs/09-clickhouse && ./check.sh
#
# The password is not printed and does not end up in the report.
# The script spins up one-off pods with curl, so it takes about a minute.

# The name and title are needed by the shared library: it labels the report artifact with them.
# lib.sh holds ok/fail/warn/evidence/finish and the environment checks below — so that
# fifteen check scripts print uniformly, rather than each in its own way.
LAB_NAME="09-clickhouse"
LAB_TITLE="Lab 9 · Analytics over a million rows"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Both checks stop the script with a clear message if the cluster access file
# or the tenant number is not set. Without them, kubectl errors would follow.
need_kubeconfig
need_tenant

# The participant sets COZY_TENANT as `workshop07`, while the namespace is called
# `tenant-workshop07`. We accept both spellings.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# The default names are the same as in the lab. The form ${X:-value} means "take the
# environment variable, and if it is absent, substitute the value": if you named the app
# differently — run as CH_APP=name ./check.sh, no need to edit the script.
# The address is internal, from within the cluster: 8123 — the port of ClickHouse's HTTP interface.
CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "ClickHouse address" "$CH_URL"

# --- 1. does the service respond at all -------------------------------------
# /ping requires no password, so this is the first and cheapest check:
# it separates "no connection" from "connection exists, wrong password".
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse responds at the tenant's internal address"
else
  fail "ClickHouse does not respond at ${CH_HOST}" \
       "check the tenant number in COZY_TENANT and the app name (default 'analytics'; otherwise CH_APP=name ./check.sh); in the dashboard the app must be in a ready state"
  finish
  exit $?
fi

# Everything below requires logging into the database. Without a password the script does not guess
# or stay silent, but honestly says that the database contents were not checked, and finishes the
# report: otherwise the participant would think the check had passed.
if [ -z "${CH_PASSWORD:-}" ]; then
  fail "the CH_PASSWORD variable is not set, the database contents were not checked" \
       "export CH_PASSWORD='password of the ${CH_USER} user' and run the script again; the password is visible in the dashboard, secret clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# Run SQL from standard input and return the response.
# A separate function, not in_cluster_curl: the query goes in the POST body, and the body
# needs standard input, which the shared function does not have.
# The password goes into the pod as an environment variable from a temporary Secret, not as an argument:
# everything that ends up in args is visible to anyone with `get pods`, sits in etcd and shows up in the audit
# log. The lab itself talks about this — checking it with a script that does the opposite
# would be a double standard.
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# Pull a number out of the statistics block of a JSON-format response.
chstat() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
key = sys.argv[1]
src = d.get("statistics", {}) if key in ("elapsed",) else d
val = src.get(key, d.get("statistics", {}).get(key))
if val is None:
    sys.exit(1)
print(val)
' "$1" 2>/dev/null
}

# --- 2. the table exists ----------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "table ${CH_TABLE} exists"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse rejected the password for user ${CH_USER}" \
         "verify the password in the dashboard: app ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "table ${CH_TABLE} does not exist" \
         "create it: ch < 01-schema.sql (schema walkthrough — in README)"
  fi
  finish
  exit $?
fi

# --- 3. how much data there is and how varied it is -------------------------
# One query instead of six: each ch_query call spins up a pod, and six
# pods in a row would turn the check into a minute-long wait for no reason.
STATS="$(ch_query <<SQL
SELECT
    (SELECT count() FROM ${CH_TABLE}),
    (SELECT uniqExact(entrance) FROM ${CH_TABLE}),
    (SELECT uniqExact(pass_type) FROM ${CH_TABLE}),
    (SELECT uniqExact(toStartOfMonth(created_at)) FROM ${CH_TABLE}),
    (SELECT max(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT min(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT sum(data_uncompressed_bytes) FROM system.columns
      WHERE database = currentDatabase() AND table = '${CH_TABLE}')
SQL
)"

ROWS="$(printf '%s' "$STATS" | awk 'NR==1{print $1}')"
UNIQ_ENT="$(printf '%s' "$STATS" | awk 'NR==1{print $2}')"
UNIQ_TYPE="$(printf '%s' "$STATS" | awk 'NR==1{print $3}')"
UNIQ_MONTH="$(printf '%s' "$STATS" | awk 'NR==1{print $4}')"
PEAK_MAX="$(printf '%s' "$STATS" | awk 'NR==1{print $5}')"
PEAK_MIN="$(printf '%s' "$STATS" | awk 'NR==1{print $6}')"
TABLE_BYTES="$(printf '%s' "$STATS" | awk 'NR==1{print $7}')"

for v in ROWS UNIQ_ENT UNIQ_TYPE UNIQ_MONTH PEAK_MAX PEAK_MIN TABLE_BYTES; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*) eval "$v=0" ;;
  esac
done

if [ "$ROWS" -ge 1000000 ]; then
  ok "the table has ${ROWS} rows — a million was generated"
else
  fail "the table has ${ROWS} rows, a million was expected" \
       "run the generator: ch < 02-generate.sql (generator walkthrough — in README)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "the data is varied: entrances ${UNIQ_ENT}, pass types ${UNIQ_TYPE}, months ${UNIQ_MONTH}"
else
  fail "the data is monotonous: entrances ${UNIQ_ENT}, types ${UNIQ_TYPE}, months ${UNIQ_MONTH}" \
       "on such data the report will show nothing; regenerate: TRUNCATE TABLE ${CH_TABLE}, then ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "the data has pronounced hourly peaks (the busiest hour to the quietest — at least twofold)"
  evidence "Distribution by hour" "max per hour: ${PEAK_MAX}
min per hour: ${PEAK_MIN}"
else
  warn "no hourly peaks visible: max ${PEAK_MAX}, min ${PEAK_MIN}" \
       "the 'when are the peaks' report is meaningless on such data; check that the generator completed fully"
fi

# --- 4. the monthly report computes fast ------------------------------------
REPORT="$(ch_query <<SQL
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM ${CH_TABLE}
GROUP BY month
ORDER BY month
FORMAT JSON
SQL
)"

ELAPSED="$(printf '%s' "$REPORT" | chstat elapsed)"
READ_ROWS="$(printf '%s' "$REPORT" | chstat rows_read)"

if [ -z "$ELAPSED" ]; then
  fail "the monthly report did not run" \
       "run it manually: ch < 03-report.sql and look at the error text"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  # We keep the threshold close to what the lab promises. The former five seconds counted
  # a four-second report as a success — even though the lab header says
  # "computes in milliseconds". The script must not confirm what it did not check.
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "the monthly report computed in ${MS} ms, rows read: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "the monthly report took ${MS} ms — that is not the order of magnitude the lab is about" \
         "a million rows on an idle stand fits within tens of milliseconds; check that the service is not busy with a neighboring load, and retry"
  else
    warn "the monthly report computed in ${MS} ms — slower than expected, but within reason" \
         "this happens on a busy stand; on an idle one such a report fits within tens of milliseconds"
  fi
  evidence "Monthly report" "time: ${MS} ms
rows read: ${READ_ROWS}"
fi

# --- 5. columnar storage works, it is not merely claimed --------------------
# The query touches one small column. If the storage is columnar, the amount read
# will be noticeably less than the whole table weighs.
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

# Both quantities are UNCOMPRESSED: `bytes_read` in the query statistics is the decompressed
# volume, and from system.columns we take `data_uncompressed_bytes`. Comparing against
# `data_compressed_bytes` gave a fraction of the on-disk size and printed the participant
# a wrong number — on a well-compressed table it could go past a hundred percent.
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "Single-column read" "bytes read: ${NARROW_BYTES}
whole table uncompressed, bytes: ${TABLE_BYTES}
share: ${SHARE}%"
  # A threshold, not just "less than the whole". One narrow column out of seven should give single-digit
  # percents; "99% instead of 100%" is formally less but proves nothing — and that is exactly
  # the claim the lab puts in its title.
  if [ "$SHARE" -le 25 ]; then
    ok "the single-column query read ${SHARE}% of the table's data — columnar storage works"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "the single-column query read ${SHARE}% of the table's data — less than the whole, but the gain is more modest than expected" \
         "single-digit percents were expected; check that the query addresses one narrow column, not several"
  else
    warn "the single-column query read no less than the whole table" \
         "this happens on very small tables; check that there really are a million rows"
  fi
else
  warn "could not measure how much the narrow query read" \
       "run it manually: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON and look at bytes_read"
fi

# finish prints the summary and writes the report artifact to a file; the exit code is non-zero
# if at least one check failed.
finish
