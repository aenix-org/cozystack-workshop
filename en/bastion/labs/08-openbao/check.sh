#!/usr/bin/env bash
# Check for lab 8: the password is moved out of the manifest into OpenBao and lives by the rules.
#
# We check not "the object was created" but the essence: the vault is unsealed, the secret is
# readable by token, there is more than one version (which means rotation actually happened), audit
# is enabled, and the applied application manifest has no plaintext passwords.
#
# No secret ends up in the report. Values are not printed anywhere.
#
# The script spins up throwaway pods with curl, so it takes about a minute to run.

# LAB_NAME and LAB_TITLE go into the report header. Below, the shared checks library is sourced:
# it provides ok / warn / fail / evidence / finish and the functions that spin up throwaway pods
# inside the cluster. need_kubeconfig and need_tenant stop the script early if access or the tenant
# number are not set: otherwise everything would fail at once and the report would give no clue why.
LAB_NAME="08-openbao"
LAB_TITLE="Lab 8 · Secrets not in the manifest"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- where to look ---------------------------------------------------------
# The participant sets COZY_TENANT as `workshop07`, but the namespace is called
# `tenant-workshop07`. We accept both spellings: it is easy to slip here, and the
# error message would be cryptic ("service not responding").
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# What and where we look for. BAO_APP is the name of the OpenBao application in the tenant, and it is
# part of the vault's internal address: if you named the application differently, run the check
# as BAO_APP=name ./check.sh. SECRET_PATH is the path inside the vault where the lab puts the
# database password.
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "Vault address" "$BAO_URL"

# Pull a value by a chain of keys from JSON on standard input.
# Returns 1 if the path does not exist or it is not JSON, so the caller can tell
# "no such key" from "empty value".
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1:]:
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        sys.exit(1)
print("" if d is None else d)
' "$@" 2>/dev/null
}


# A request to OpenBao. We pass the token via an environment variable from a temporary Secret,
# and NOT as a header in the arguments: a pod's arguments are visible to anyone with `get pods`,
# they sit in etcd and go into the audit log. Here it is the vault's root token — exactly the leak
# the whole lab is written against.
#
# The definition sits BEFORE the first call: when it lived inside the else branch, the very first
# check called a nonexistent function and the lab could never pass.
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. the vault responds -------------------------------------------------
# The very first request answers two questions at once: did the application come up, and is the
# tenant number correct. We ask for the seal status — it is the only endpoint OpenBao serves without
# a token. An empty response further down means "no connection", and all content checks lose meaning.
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao does not respond at ${BAO_URL}" \
       "check the tenant number in COZY_TENANT and the application name (default 'secrets'; otherwise BAO_APP=name ./check.sh); in the dashboard the application must be in the ready state"
else
  ok "OpenBao responds at the tenant's internal address"
fi

# --- 2. initialized --------------------------------------------------------
# Initialization is a one-time operation in which the vault creates its master key
# and first token. Until it is done, there is nothing inside: no secrets, no place for them.
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "vault is initialized"
elif [ -n "$SEAL" ]; then
  fail "vault is not initialized" \
       "run: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 and save the output"
fi

# --- 3. unsealed -----------------------------------------------------------
# A sealed vault is the normal state after a pod restart: the data is on disk, but there is nothing
# to read it with until the unseal key is entered. Hence the requirement to check behavior, not the
# presence of an object: "application ready" and "secrets are served" are two different statements,
# and the second does not follow from the first.
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "vault is unsealed and serving requests"
  evidence "Vault state" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "vault is sealed — it answers any request with a 503 refusal" \
       "run: kubectl exec bao-workbench -- bao operator unseal <your-unseal-key>"
  evidence "Vault state" "$SEAL"
fi

# --- 4. the secret is in place and readable --------------------------------
# Next we need a token. Without it there is nothing to check, but we must not silently skip either:
# the reader must see what is missing.
if [ -z "$SEAL" ]; then
  # No connection — checking the content is pointless. We stay quiet so as not to swamp the
  # report with four failures that all share the same cause, named above.
  warn "vault content not checked: no connection to OpenBao" \
       "sort out the connection, then run the script again"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "the BAO_TOKEN variable is not set, so vault content was not checked" \
       "export BAO_TOKEN='the root token printed at the first unseal of the vault' and run the script again"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "secret secret/${SECRET_PATH} is readable by token, the password field is not empty"
    # Into the report we put the version number, not the value.
    evidence "Secret" "path: secret/${SECRET_PATH}
password field: present (value hidden)
current version: ${DATA_VERSION:-unknown}"
  else
    fail "there is no password field at secret/${SECRET_PATH}" \
         "put it there: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; if the engine is not enabled yet — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. rotation actually happened --------------------------------------
  # A single version of a secret means it was set once and forgotten. Rotation is the whole reason
  # to have a vault: change the password in one place instead of hunting for it across manifests.
  # We count not promises but versions: the vault keeps that count itself.
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "the secret was changed: ${CUR_VER} versions, so rotation happened for real and not just in words"
    evidence "Secret version history" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "the secret has only one version — rotation was not done" \
         "change the password: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<new> and restart the application"
  fi

  # --- 6. the policy is narrow, not "anything goes" ------------------------
  # The policy is the answer to "what will someone who obtained the token be able to do". So we look
  # not at the fact of its existence but at its content: is it granted on a specific path instead of
  # the whole vault, and is it read-only.
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "the passes-read policy exists"
    evidence "passes-read policy" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "the policy is granted on a specific path, not on the whole vault"
    else
      warn "the policy exists, but the path secret/data/${SECRET_PATH} is not visible in it" \
           "check that the policy uses the data prefix: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "the policy allows more than reading" \
           "the application only needs read; the extra permissions should be removed"
    fi
  else
    fail "the passes-read policy was not found" \
         "create it: kubectl exec -i bao-workbench -- bao policy write passes-read - < your policy file (policy walkthrough — in the README)"
  fi

  # --- 7. audit is enabled -------------------------------------------------
  # Without an audit log there is nothing to answer "who read this secret and when" with — and that
  # is the first question asked after an incident. We count the attached audit devices: there must
  # be at least one.
  AUD="$(bao_get "/v1/sys/audit")"
  AUD_COUNT="$(printf '%s' "$AUD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
data = d.get("data", d)
print(len([k for k in data if isinstance(data.get(k), dict)]))
' 2>/dev/null)"
  case "$AUD_COUNT" in
    ''|*[!0-9]*) AUD_COUNT=0 ;;
  esac
  if [ "$AUD_COUNT" -ge 1 ]; then
    ok "audit log is enabled (devices: ${AUD_COUNT})"
    evidence "Audit devices" "$AUD"
  else
    fail "audit log is not enabled — there will be nothing to answer who read the secret with" \
         "enable it: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. the application in the lab cluster ---------------------------------
# Up to here we checked the vault on the management cluster. Next comes your lab cluster, where the
# application itself lives. What matters here is not the fact that the Deployment was created, but the
# presence of ready replicas: an init container that failed to fetch the password will not let the pod
# come up, and it is exactly this state that must be told apart from "all good".
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "the lab cluster has no application ${APP_DEPLOY}" \
       "apply: kubectl apply -f secrets-demo.yaml (do not forget to substitute your tenant number)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "application ${APP_DEPLOY} is running (ready replicas: ${READY})"
  else
    fail "application ${APP_DEPLOY} exists, but no replica is ready" \
         "look at kubectl describe deploy/${APP_DEPLOY} and kubectl logs deploy/${APP_DEPLOY} -c fetch-secret — usually the init container could not reach the vault or was refused by token"
  fi

  # --- 9. no plaintext passwords in the manifest ---------------------------
  # We look at the applied object, not the file on disk: anything could have been applied.
  LEAKS="$(kubectl get deploy "$APP_DEPLOY" -o json 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
suspicious = re.compile(r"(?i)pass|secret|token|key|cred")
spec = d.get("spec", {}).get("template", {}).get("spec", {})
found = []
for c in list(spec.get("initContainers", [])) + list(spec.get("containers", [])):
    for e in c.get("env", []):
        if "value" in e and suspicious.search(e.get("name", "")):
            found.append("%s / env %s is set by value, not by reference" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "the application manifest has no variables with a password set by value"
  else
    fail "the application manifest still has sensitive values in plaintext" \
         "remove them: the value must come from the vault, and the manifest — only a reference. See secrets-demo.yaml"
    evidence "What was found in the manifest" "$LEAKS"
  fi

  # --- 10. the application actually received the secret --------------------
  # The final proof comes from the logs, not from the object description. The manifest can be
  # flawless while the password never arrives in the pod. We look at two things at once: the init
  # container reported that it went to the vault, and the application prints a fingerprint —
  # meaning it really works with the received password.
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "the init container fetched the secret from the vault"
    evidence "Init container log" "$INIT_LOG"
  else
    fail "there is no sign that the init container fetched the secret from the vault" \
         "check kubectl logs deploy/${APP_DEPLOY} -c fetch-secret; if there is no such container — an old manifest was applied"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "the application works with the received password (a fingerprint is written to the log, not the value)"
    evidence "Application log" "$APP_LOG"
  else
    fail "the application log has no password fingerprint" \
         "check kubectl logs deploy/${APP_DEPLOY} -c app — the container may have failed to start"
  fi
fi

# --- 11. the naive secret is removed ---------------------------------------
# We count it as "removed" only if the lab was actually done: on a clean cluster the secret never
# existed, and the report would praise the participant for a cleanup that never happened.
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "the cluster still has the passes-db secret from the naive stage" \
       "it is no longer needed and holds the old password: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "the naive passes-db secret has been removed"
fi

finish
