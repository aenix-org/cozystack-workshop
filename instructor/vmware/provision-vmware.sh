#!/bin/bash
# Sequential host-side provisioning; compatible with macOS Bash 3.2.
# Usage: STEP=all ./provision-vmware.sh vmw01 vmw02
# Preview: DRY_RUN=1 ./provision-vmware.sh vmw99
# STEP=platform: tenant, Keycloak, GitLab and Flux. STEP=bastion: home and handout.
# Requires ~/workshop.txt, SSH/sudo access to the bastion, and a GitLab root PAT.
# The PAT is read from ../state/gitlab-root-token.txt, or copied there from
# ~/projects/fraud-workshop/state/gitlab-root-token.txt (fraud is never modified).
# Keep state backed up: existing accounts/passwords, repos and tokens are reused.
# Existing accounts must already match the saved password; no password resets.
# Lost deploy-token state requires manual recovery; never revoke tokens here.
# Interrupted operations can be retried. Configuration drift stops provisioning.
# Source-only remote helper directories are retained: this script deletes nothing.
# Passwords, tokens and kubeconfigs stay in state (600), except the explicitly
# requested participant home files and ~/<login> handout (also 600).
set +x
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$HERE/provision_vmware.py" "$@"
