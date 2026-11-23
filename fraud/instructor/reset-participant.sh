#!/bin/bash
# Returns a participant environment to the state the session starts from:
# no catalog services, only the terminals in the cluster, the switch in legacy mode.
# Run on the bastion as the participant (it uses their kubeconfig):
#   sudo -u dallasNN bash reset-participant.sh
set -uo pipefail
kubectl --context fraud -n fraud delete job attack --ignore-not-found
kubectl --context fraud -n fraud delete deploy scorer cases dashboard explainer --ignore-not-found
kubectl --context fraud -n fraud delete svc dashboard explainer --ignore-not-found
kubectl --context fraud -n fraud patch configmap traffic -p '{"data":{"rate":"20"}}'
kubectl --context platform delete kafka kafka --ignore-not-found
kubectl --context platform delete redis features --ignore-not-found
kubectl --context platform delete postgres cases --ignore-not-found
echo "Now, inside the switch VM:"
echo "  sudo sed -i 's#^KAFKA_BOOTSTRAP=.*#KAFKA_BOOTSTRAP=#' /etc/auth-switch/env && sudo systemctl restart auth-switch"
