#!/usr/bin/env bash
# Check for lab 6: the application arrives in the cluster from ITS OWN private registry.
#
# We check not "Harbor is created", but the whole chain: the registry answers on its own API,
# the image in the manifest lives exactly there, the cluster has credentials for that same address,
# and a pod with this image actually runs and responds.
#
# Two clusters, and this is the main reason the script looks more complex than its neighbors:
# KUBECONFIG is your lab cluster, where the application runs; COZY_KUBECONFIG is the
# Cozystack management cluster, where the managed Harbor service lives in your tenant.
# You can't query them with a single command, so below are two different ways to call kubectl.
#
# Run by you, from the lab folder; changes nothing, only looks and prints a report:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_KUBECONFIG=~/.kube/config
#     ./check.sh

LAB_NAME="06-harbor"
LAB_TITLE="Lab 6 · Your own private image registry"
# Common wrapper for all labs: ok / fail / warn / evidence / finish and environment checks.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Without a cluster access file and without a tenant number there is nothing to check — exit right away.
need_kubeconfig
need_tenant

APP="passes-api"
# The tenant namespace on the management cluster: the name is built from the prefix
# tenant- and your number, that is tenant-workshopXX. The number is taken from the environment,
# you don't need to substitute it into the script text by hand.
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"

# Two ways to call kubectl: kget goes to your lab cluster, cozy — to the management cluster.
# Errors are silenced on purpose: a missing object here is not a failure but one of the expected
# outcomes, and it is handled below by a separate branch with clear advice.
kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- managed Harbor service on the management cluster -------------------------
# Optional part: without the tenant kubeconfig the lab is still checkable,
# but we won't see the service from the platform side.
#
# We separately catch the "command didn't work" case: the role in the tenant may not allow
# viewing applications. This is not the participant's error and not a reason to fail the check, so
# here it's warn — "didn't look", not fail — "done wrong". We deliberately distinguish a command
# error from an empty response: an empty list means Harbor was not created at all.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "tenant kubeconfig ${COZY_KUBECONFIG} not found — Harbor state was not checked" \
       "specify the path: export COZY_KUBECONFIG=~/.kube/config"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "could not view Harbor applications in tenant ${TENANT_NS}" \
         "the role in the tenant may not allow this command — this is not a lab error; everything else is checked below"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "there is no Harbor application in tenant ${TENANT_NS}" \
         "create it in the dashboard: Create application -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "managed Harbor service «${HARBOR_NAME}» is ready"
    else
      warn "Harbor «${HARBOR_NAME}» exists, but does not report readiness" \
           "check its state in the dashboard; Harbor takes 5-10 minutes to come up, and without object storage in the tenant it won't come up at all"
    fi
    evidence "Harbor applications in the tenant" "$HARBOR_LIST"
    # We don't try to read the credentials secret: the tenant can read this secret
    # (the platform creates a separate rule for each application's credentials),
    # but we don't need the password in the report anyway.
  fi
fi

# --- where the application takes the image from ------------------------------
# The point of the lab is that the image came from your registry, not from the internet. This is checked
# by the image name in the manifest: the first part of the name up to the slash is the registry address.
# If it has neither a dot nor a colon, there is no address there at all, and the cluster would silently go
# for the image to Docker Hub — that is, exactly where the security team forbade.
# We catch the HARBOR-HOST placeholder and known public registries in separate branches:
# formally the address is in place, but the lab requirement is not met, and the advice differs in each case.
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "there is no application ${APP} in the lab cluster" \
       "apply passes.yaml, substituting the address of your own Harbor into it"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # looks like a registry address
    *) REGISTRY="" ;;          # no address — means the image is pulled from Docker Hub
  esac

  if [ -z "$REGISTRY" ]; then
    fail "image ${IMAGE} is pulled from a public registry, not from yours" \
         "the first part of the image name must be the address of your Harbor"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "the placeholder address HARBOR-HOST is still in the manifest" \
         "substitute the address of your own Harbor: sed -i 's|HARBOR-HOST|harbor.yourdomain|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "the image is pulled from public registry ${REGISTRY}" \
         "the security team asked for a private registry — build and push the image to your own Harbor"
  else
    ok "the application starts from your registry: ${REGISTRY}"
    evidence "Application image" "$IMAGE"
  fi
fi

# --- the registry actually works --------------------------------------------
# The address in the manifest may be written correctly, but there may be no registry at it: Harbor
# does not come up instantly, and a typo in the domain looks exactly the same. So we
# knock on its API and wait for the "pong" answer — this confirms that it is indeed Harbor
# there, and not someone else's site or a load balancer stub.
if [ -z "$REGISTRY" ]; then
  : # already reported above
elif ! command -v curl >/dev/null 2>&1; then
  warn "no curl utility — registry availability was not checked" \
       "open https://${REGISTRY} in a browser, there should be a Harbor interface"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","unknown"))' 2>/dev/null)"
    ok "the registry answers on the API: https://${REGISTRY} (Harbor ${VER:-version unknown})"
    evidence "Registry" "https://${REGISTRY}
API ping: ${PING}
Harbor version: ${VER:-unknown}"
  else
    fail "registry https://${REGISTRY} does not answer the /api/v2.0/ping request" \
         "check the address and the state of the Harbor application in the dashboard"
  fi
fi

# --- the cluster has access credentials -------------------------------------
# It's not enough that the secret is referenced in the manifest — what matters is that it has credentials
# for exactly the registry the image is pulled from. The most common lab mistake looks
# correct: the secret is created, named in the manifest, but the address inside it is wrong
# (an extra https://, a port, a different host name), and kubelet won't apply it.
# So we unpack the secret contents and compare addresses, not names.
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # no application, reported above
elif [ -z "$PULL_SECRETS" ]; then
  fail "no imagePullSecret is specified in the ${APP} manifest" \
       "an image from a private registry won't be pulled without credentials: add imagePullSecrets, see passes.yaml"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # We parse the config with python: base64 -d behaves differently on macOS and Linux,
    # and we must not print the password into the report — we take only the list of addresses.
    SERVERS="$(kget secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' \
      | python3 -c 'import sys,json,base64
raw = sys.stdin.read().strip()
try:
    cfg = json.loads(base64.b64decode(raw))
    print(" ".join(cfg.get("auths", {}).keys()))
except Exception:
    pass' 2>/dev/null)"
    if [ -n "$REGISTRY" ] && printf '%s' "$SERVERS" | grep -q "$REGISTRY"; then
      SECRET_OK="$s"
      break
    fi
  done

  if [ -n "$SECRET_OK" ]; then
    ok "the cluster has credentials for ${REGISTRY} in secret ${SECRET_OK} (password: <hidden>)"
  else
    fail "none of the specified secrets (${PULL_SECRETS}) contains credentials for ${REGISTRY:-your registry}" \
         "create it like this: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-ADDRESS} --docker-username=admin --docker-password=..."
  fi
fi

# --- the pods actually started ----------------------------------------------
# We separately handle the ImagePullBackOff and ErrImagePull states: this is exactly the failure
# the lab shows on purpose, and it's important for the participant to recognize it by sight, not to
# get a generic "pods don't work". We print the real cause as evidence —
# in a registry failure and in a typo in the image name the pod state is the same.
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "running copies of the application: ${RUNNING}"
  evidence "Application pods" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "the image is not being pulled: ${BADSTATE}" \
       "this is a registry access denial or a typo in the image name; the real cause will be shown by kubectl describe pod -l app=passes-api"
  evidence "Failure cause" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "there is not a single running copy of the application (states: ${BADSTATE:-no pods})" \
       "see kubectl describe pod -l app=passes-api"
fi

# A separate check for the hardest-to-diagnose lab error: the image is built
# for ARM, and the cluster nodes are on x86. Everything looks correct — the image built, went
# to the registry, was pulled onto the node — but the process doesn't start. Nothing around hints
# at the processor architecture, and the only clue lies in the pod logs, so
# we look at them with a separate check and name the cause directly.
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "the image is built for a different processor architecture" \
       "rebuild with the flag: docker build --platform linux/amd64 -t ${IMAGE} app/ and push again"
fi

# --- the application responds meaningfully -----------------------------------
# A started pod does not yet mean a working service. We go inside the cluster, request
# the application by its internal name and read the pod name from the response. If it matches a really
# running pod — then the answer comes from exactly the application we deployed, and not
# something else that accidentally took this address. A mismatch is warn, not fail:
# a copy could have been recreated between the two requests, and it's not the participant's fault.
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "there is no Service named ${APP}" \
       "it is described in passes.yaml — apply the whole file, not just the Deployment"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "service ${APP} did not return the expected JSON" \
         "see kubectl logs -l app=passes-api and make sure the port in the Service matches the application port"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "the service responds with JSON, the response came from a really running pod ${SERVED_POD}"
    evidence "Service response" "$BODY"
  else
    warn "the service responded on behalf of pod ${SERVED_POD}, which is not among the running ones" \
         "most likely the copy was recreated between requests — run the check again"
  fi
fi

finish
