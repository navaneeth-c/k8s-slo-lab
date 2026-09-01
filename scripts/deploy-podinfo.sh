#!/usr/bin/env bash
# Deploys podinfo itself. Usage:
#   ./deploy-podinfo.sh            # dev/default values, default namespace
#   ./deploy-podinfo.sh prod       # values-prod.yaml overrides, prod namespace
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../charts/podinfo"

ENVIRONMENT="${1:-dev}"

case "${ENVIRONMENT}" in
  prod)
    NAMESPACE="prod"
    VALUES_FLAG="-f ${CHART_DIR}/values-prod.yaml"
    ;;
  dev)
    NAMESPACE="default"
    VALUES_FLAG=""
    ;;
  *)
    # Anything else deploying dev values silently would be the worst outcome.
    echo "usage: deploy-podinfo.sh [dev|prod] (got: ${ENVIRONMENT})" >&2
    exit 1
    ;;
esac

# Helm 4 renamed --atomic to --rollback-on-failure; both give the same
# guarantee. Detect rather than assume, so the script works on either.
HELM_MAJOR="$(helm version --template '{{.Version}}' | sed 's/^v//' | cut -d. -f1)"
if [[ "${HELM_MAJOR}" -ge 4 ]]; then
  ROLLBACK_FLAG="--rollback-on-failure"
else
  ROLLBACK_FLAG="--atomic"
fi

echo "Deploying podinfo (${ENVIRONMENT}) to namespace '${NAMESPACE}'..."
# shellcheck disable=SC2086
helm upgrade --install podinfo "${CHART_DIR}" \
  --namespace "${NAMESPACE}" --create-namespace \
  ${VALUES_FLAG} \
  ${ROLLBACK_FLAG} --timeout 3m

kubectl -n "${NAMESPACE}" rollout status deployment/podinfo
echo "podinfo (${ENVIRONMENT}) is up. Try: kubectl -n ${NAMESPACE} port-forward svc/podinfo 9898:9898"
