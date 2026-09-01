#!/usr/bin/env bash
# Creates the local kind cluster used for this project. Idempotent: safe to
# re-run, it just skips creation if the cluster already exists.
set -euo pipefail

CLUSTER_NAME="k8s-slo-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  echo "Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --config "${SCRIPT_DIR}/../cluster/kind-config.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo "Cluster ready. Context: kind-${CLUSTER_NAME}"
