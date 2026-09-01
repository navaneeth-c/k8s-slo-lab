#!/usr/bin/env bash
# Deploys the kube-prometheus-stack (Prometheus + Grafana + Alertmanager) plus
# metrics-server (kind ships none, and without it the HPA reads <unknown>),
# then wires up podinfo's ServiceMonitor and PrometheusRules. Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBS_DIR="${SCRIPT_DIR}/../observability"

# Chart versions are pinned: this repo's value keys are written against these,
# and "install whatever the repo has today" is how reproducible labs stop being
# reproducible.
KPS_VERSION="88.6.2"
METRICS_SERVER_VERSION="3.14.0"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo update >/dev/null

echo "Installing/upgrading metrics-server (HPA support on kind)..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version "${METRICS_SERVER_VERSION}" \
  --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}' \
  --wait --timeout 2m

echo "Installing/upgrading kube-prometheus-stack ${KPS_VERSION}..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "${KPS_VERSION}" \
  --namespace monitoring --create-namespace \
  -f "${OBS_DIR}/kube-prometheus-stack-values.yaml" \
  --wait --timeout 8m

echo "Waiting for the Prometheus Operator CRDs to be ready..."
kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=60s
kubectl wait --for=condition=Established crd/prometheusrules.monitoring.coreos.com --timeout=60s

echo "Applying ServiceMonitor and PrometheusRules..."
kubectl apply -n monitoring -f "${OBS_DIR}/servicemonitor.yaml"
kubectl apply -n monitoring -f "${OBS_DIR}/alerts/availability-alert.yaml"
kubectl apply -n monitoring -f "${OBS_DIR}/alerts/burn-rate-alert.yaml"

echo "Loading the RED dashboard as a Grafana sidecar-discovered ConfigMap..."
kubectl create configmap podinfo-red-dashboard \
  --from-file=podinfo-red.json="${OBS_DIR}/dashboards/podinfo-red.json" \
  -n monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl label configmap podinfo-red-dashboard -n monitoring grafana_dashboard=1 --overwrite

echo "Done. Grafana: http://localhost:30090 (admin / admin, see values file)"
