# Thin wrappers over scripts/. Targets are safe to re-run; `burn` and `break`
# deliberately damage the deployment and `fix`/`stop-load` undo them.
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
NAMESPACE ?= default
CLUSTER   ?= k8s-slo-lab

.PHONY: help up load burn break fix stop-load lint test-rules status down

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

up: ## Create the kind cluster, install Prometheus/Grafana/metrics-server, deploy podinfo
	./scripts/setup-cluster.sh
	./scripts/deploy-observability.sh
	./scripts/deploy-podinfo.sh
	@echo
	@echo "Grafana:    http://localhost:30090  (admin / admin)"
	@echo "podinfo:    kubectl -n $(NAMESPACE) port-forward svc/podinfo 9898:9898"
	@echo "Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"

load: ## Drive healthy traffic so the dashboard and SLI have data
	./scripts/load.sh healthy 300

burn: ## Drive 5xx traffic, watch the fast-burn SLO alert fire, then stop the load
	@kubectl -n $(NAMESPACE) get deployment/podinfo >/dev/null
	./scripts/load.sh errors 600
	./scripts/alert-watch.sh PodinfoSLOFastBurn firing 600 || { $(MAKE) stop-load; exit 1; }
	$(MAKE) stop-load

break: ## Scale podinfo to zero and watch the availability alert fire
	@kubectl -n $(NAMESPACE) get deployment/podinfo >/dev/null
	kubectl -n $(NAMESPACE) scale deployment/podinfo --replicas=0
	./scripts/alert-watch.sh PodinfoUnavailable firing 300

fix: ## Scale podinfo back up, stop any error load, watch the alert clear
	$(MAKE) stop-load
	kubectl -n $(NAMESPACE) scale deployment/podinfo --replicas=2
	kubectl -n $(NAMESPACE) rollout status deployment/podinfo
	./scripts/alert-watch.sh PodinfoUnavailable inactive 300

stop-load: ## Delete any running load jobs
	kubectl -n $(NAMESPACE) delete job podinfo-load podinfo-load-errors --ignore-not-found

lint: ## Lint and render the chart against both value sets
	helm lint ./charts/podinfo
	helm lint ./charts/podinfo -f ./charts/podinfo/values-prod.yaml
	helm template podinfo ./charts/podinfo >/dev/null
	helm template podinfo ./charts/podinfo -f ./charts/podinfo/values-prod.yaml >/dev/null
	@echo "Chart renders clean against both value sets."

test-rules: ## Unit-test the alert rules with promtool
	./scripts/test-rules.sh

status: ## Show what is currently running
	@kubectl -n $(NAMESPACE) get deploy,hpa,svc -l app.kubernetes.io/name=podinfo
	@kubectl -n monitoring get prometheusrule,servicemonitor

down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
