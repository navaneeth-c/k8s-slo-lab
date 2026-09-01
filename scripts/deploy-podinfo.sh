#!/usr/bin/env bash
# Deploys podinfo itself. Usage:
#   ./deploy-podinfo.sh            # dev/default values, default namespace
#   ./deploy-podinfo.sh prod       # values-prod.yaml overrides, prod namespace
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../charts/podinfo"

ENVIRONMENT="${1:-dev}"

if [[ "${ENVIRONMENT}" == "prod" ]]; then
  NAMESPACE="prod"
  VALUES_FLAG="-f ${CHART_DIR}/values-prod.yaml"
else
  NAMESPACE="default"
  VALUES_FLAG=""
fi

echo "Deploying podinfo (${ENVIRONMENT}) to namespace '${NAMESPACE}'..."
# shellcheck disable=SC2086
helm upgrade --install podinfo "${CHART_DIR}" \
  --namespace "${NAMESPACE}" --create-namespace \
  ${VALUES_FLAG} \
  --rollback-on-failure --timeout 3m

kubectl -n "${NAMESPACE}" rollout status deployment/podinfo
echo "podinfo (${ENVIRONMENT}) is up. Try: kubectl -n ${NAMESPACE} port-forward svc/podinfo 9898:9898"
