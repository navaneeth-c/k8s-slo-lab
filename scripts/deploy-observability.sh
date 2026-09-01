#!/usr/bin/env bash
# Deploys the kube-prometheus-stack (Prometheus + Grafana + Alertmanager) and
# wires up podinfo's ServiceMonitor + PrometheusRules. Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OBS_DIR="${SCRIPT_DIR}/../observability"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo "Installing/upgrading kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f "${OBS_DIR}/kube-prometheus-stack-values.yaml" \
  --wait --timeout 5m

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
  -n monitoring --dry-run=client -o yaml \
  | kubectl label -f - --local -o yaml grafana_dashboard=1 \
  | kubectl apply -f -

echo "Done. Grafana: http://localhost:30090 (admin / admin, see values file)"
