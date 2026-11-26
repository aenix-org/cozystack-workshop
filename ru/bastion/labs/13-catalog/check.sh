#!/usr/bin/env bash
# Check for lab 13: the chart and the application definition are ready to hand off to the admin.
#
# This check is INTENTIONALLY local. A tenant cannot apply an ApplicationDefinition
# (the object is cluster-scoped), so looking for it in the cluster is pointless:
# the object's absence is not the participant's fault. We check what they are responsible for:
# the chart builds, the schema works, the definition is parsed and consistent with the chart.
#
# Run from the lab folder:
#   cd labs/13-catalog && ./check.sh
# A cluster is not required: without KUBECONFIG two checks are skipped with a warning,
# not with an error.

LAB_NAME="13-catalog"
LAB_TITLE="Lab 13 · Your own application in the Cozystack catalog"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- tools -----------------------------------------------------------------
# Without helm there is nothing to check, so the script stops right here instead of spitting out
# a dozen identical failures further down the text.
if ! command -v helm >/dev/null 2>&1; then
  fail "helm is not installed on this machine" \
       "install it: brew install helm (macOS) or https://helm.sh/docs/intro/install/ — without it the lab cannot be checked"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm is present (${HELM_VER})"
evidence "helm version" "$HELM_VER"

# --- chart in place --------------------------------------------------------
# We distinguish "the chart is broken" from "the script was run from the wrong folder". The second
# mistake is more common than the first, and its message should be separate.
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "chart not found in ${CHART}" \
       "run the script from the lab folder: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- linter ----------------------------------------------------------------
# helm lint reads the chart as text: it finds typos in templates, missing Chart.yaml
# fields, references to nonexistent values. It never reaches the cluster here.
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "chart passes helm lint"
  evidence "helm lint" "$LINT_OUT"
else
  fail "chart does not pass helm lint" \
       "read the output below and fix the indicated files: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- render ----------------------------------------------------------------
# Empty output and output consisting only of comments would slip past the linter, so we check
# that among the rendered output there is a Deployment, and list what was actually produced.
# The point here is not "the command ran" but "real objects came out".
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "chart renders, producing objects: ${KINDS}"
  evidence "What the chart renders" "$KINDS"
else
  fail "helm template did not produce a single Deployment" \
       "look at the render error: helm template main chart"
  evidence "helm template output" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- chart is accepted by a real cluster -----------------------------------
# The only check in the whole lab set that verifies the manifest against a real cluster schema
# rather than against text.
#
# `helm lint` and `helm template` check templates, but NOT the Kubernetes schema: a manifest
# with a field in the wrong place slips past them, but the cluster rejects it. Learned the hard
# way — a securityContext mistakenly inserted into volumes passed both and fell apart only
# on the server. The check is needed where the chart is actually applied.
#
# Why lint and template do not replace it:
#   helm lint      looks at the chart's structure: files in place, templates parse;
#   helm template  substitutes values and produces text — but what those fields are and whether
#                  such an object even has them, it does not and cannot know;
#   apply --dry-run=server sends the manifest to the apiserver, which runs it through the type
#                  schema and through admission control and answers whether it would accept it,
#                  creating nothing in the process. That is where `unknown field` and a policy
#                  rejection come from — exactly what the chart stumbles over at the customer's.
# The --dry-run=client flag does not give this check: it parses the manifest on your machine.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  # A permission denial and a schema denial are different things, and must not be confused. Under
  # tenant access (~/.kube/config) there are no rights on Deployment and ConfigMap at all, so what
  # arrives here is Forbidden — and that says nothing about the quality of the chart. A substantive
  # check is only possible with access to the `lab` cluster, where you are the full owner.
  if printf '%s' "$DRY" | grep -qiE 'forbidden|cannot create|is not allowed'; then
    warn "server-side chart check skipped: the current access does not allow running it" \
         "run it with access to your own cluster: KUBECONFIG=~/lab.kubeconfig ./check.sh"
  elif printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "cluster rejects the rendered chart" \
         "look at: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "Server rejection" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "cluster accepts the rendered chart — the fields and their places are correct"
  fi
else
  warn "chart check on the cluster skipped: no access" \
       "set KUBECONFIG to run helm template through kubectl apply --dry-run=server"
fi

# --- parameters really reach the manifests ---------------------------------
# A chart can build and render, yet a parameter be substituted nowhere —
# for example, the value was written into the template as a literal number. So we check each
# parameter for real: we set a deliberately unusual value and look for it in the finished manifest.
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "the replicas parameter reaches the manifest (--set replicas=5 yields replicas: 5)"
else
  fail "the replicas parameter does not reach the manifest" \
       "templates/deployment.yaml should have replicas: {{ .Values.replicas }}"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "the external parameter switches the Service type to LoadBalancer"
else
  warn "the external parameter does not switch the Service type" \
       "not a chart breakage, but a Cozystack catalog convention: the external field on applications means exactly external access"
fi

# --- the schema actually protects ------------------------------------------
# A schema that rejects nothing is useless. We check that it rejects.
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "the values schema does not reject a deliberately invalid value (replicas=abc passed)" \
       "check that values.schema.json sits next to values.yaml and declares replicas as integer"
else
  ok "the values schema rejects the wrong type (replicas=abc does not pass)"
fi

# --- ApplicationDefinition: required fields --------------------------------
# The participant cannot apply the definition, so they will not see the apiserver's rejection.
# Therefore we count the required fields here: without any of them the admin gets a rejection
# on their own side, and the file's author is the one who will have to sort it out.
if [ ! -f "$APPDEF" ]; then
  fail "${APPDEF} not found" \
       "the file should sit next to the chart; take it from the lab repository"
else
  MISSING=""
  # We look for keys line by line, without parsing YAML: PyYAML is not on every machine,
  # and pulling in a dependency just to check one file is not worth it.
  check_key() {
    grep -Eq "$1" "$APPDEF" || MISSING="$MISSING $2"
  }
  check_key '^kind:[[:space:]]+ApplicationDefinition[[:space:]]*$' 'kind: ApplicationDefinition'
  check_key '^apiVersion:[[:space:]]+cozystack\.io/v1alpha1[[:space:]]*$' 'apiVersion: cozystack.io/v1alpha1'
  check_key '^[[:space:]]{4}kind:[[:space:]]+\S+' 'application.kind'
  check_key '^[[:space:]]{4}plural:[[:space:]]+\S+' 'application.plural'
  check_key '^[[:space:]]{4}singular:[[:space:]]+\S+' 'application.singular'
  check_key '^[[:space:]]{4}openAPISchema:' 'application.openAPISchema'
  check_key '^[[:space:]]{4}prefix:[[:space:]]+\S+' 'release.prefix'
  check_key '^[[:space:]]{6}kind:[[:space:]]+(OCIRepository|HelmChart|ExternalArtifact)' 'release.chartRef.kind'
  check_key '^[[:space:]]{4}category:[[:space:]]+\S+' 'dashboard.category'
  check_key '^[[:space:]]{4}icon:[[:space:]]+\S+' 'dashboard.icon'

  if [ -z "$MISSING" ]; then
    ok "all required fields are present in the ApplicationDefinition"
  else
    fail "the ApplicationDefinition is missing fields:${MISSING}" \
         "check against the walkthrough in the README — without any of them the admin gets a rejection on apply"
  fi

  # --- the schema in the definition parses and matches the chart's schema ---
  # These are two separate copies of the same thing, with no link between them whatsoever.
  # If they diverge, the form in the dashboard will show different fields than the chart expects.
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "openAPISchema is empty in the ApplicationDefinition" \
         "paste the contents of chart/values.schema.json in there as a single line"
  else
    CMP="$(SCHEMA_LINE="$SCHEMA_LINE" python3 - "$CHART/values.schema.json" <<'PY' 2>&1
import os, sys, json
try:
    inline = json.loads(os.environ["SCHEMA_LINE"])
except Exception as e:
    print("BADJSON %s" % e); raise SystemExit
try:
    chart = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOCHART %s" % e); raise SystemExit
a = sorted((inline.get("properties") or {}).keys())
b = sorted((chart.get("properties") or {}).keys())
if a == b:
    print("SAME %s" % ",".join(a))
else:
    only_def = sorted(set(a) - set(b))
    only_chart = sorted(set(b) - set(a))
    print("DIFF only in the definition: %s | only in the chart: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "the schema in the definition parses and matches the chart's schema (${CMP#SAME })"
        evidence "Application parameters" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "the schema in the definition has diverged from the chart's schema: ${CMP#DIFF }" \
             "bring them into agreement: the contents of openAPISchema are chart/values.schema.json as a single line"
        ;;
      BADJSON*)
        fail "openAPISchema does not parse as JSON: ${CMP#BADJSON }" \
             "the schema must be a single line of valid JSON under 'openAPISchema: |-'"
        ;;
      *)
        warn "could not compare the schemas (${CMP})" \
             "check by hand that openAPISchema matches chart/values.schema.json"
        ;;
    esac
  fi

  # --- icon -----------------------------------------------------------------
  # The dashboard expects an SVG packed into base64 and does not go anywhere for the image. The error
  # here is silent: the manifest applies, but in the catalog the icon's place will be empty. So we
  # decode the string and check that inside there is really an SVG.
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "the icon decodes from base64 and turns out to be an SVG"
        evidence "Start of the icon" "$ICON_HEAD"
        ;;
      "")
        fail "the icon does not decode from base64" \
             "rebuild the string: base64 -i icon.svg | tr -d '\\n' (on Linux: base64 -w0 icon.svg)"
        ;;
      *)
        fail "the icon decodes, but it is not an SVG" \
             "the dashboard expects exactly an SVG; a raster image it will show as garbage"
        ;;
    esac
  fi
fi

# --- permissions: a denial here is expected --------------------------------
# This is not a check of the participant, but a confirmation of how the platform is built. So
# the answer `no` is a success, and `yes` is a reason to be surprised, not glad.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "confirmed: you are not allowed to apply an ApplicationDefinition (can-i -> no)"
      evidence "Rights on ApplicationDefinition" \
        "kubectl auth can-i create applicationdefinitions -> no
The object is cluster-scoped and changes the catalog for all tenants, so it is the platform admin who applies it."
      ;;
    yes)
      warn "you have rights to apply an ApplicationDefinition (can-i -> yes)" \
           "that means you are working under an admin account, not a tenant one; the lab is designed for a tenant account"
      ;;
    *)
      warn "could not ask the cluster about permissions" \
           "does not affect passing the lab: the check is local, the cluster is not needed here"
      ;;
  esac
else
  warn "cluster was not queried (KUBECONFIG is not set or does not respond)" \
       "the check is local, the cluster is not needed here. To see the permission denial: export KUBECONFIG=~/.kube/config"
fi

finish
