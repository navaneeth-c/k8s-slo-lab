# Thin wrappers over scripts/. Every target is idempotent and safe to re-run.
SHELL := /usr/bin/env bash
NAMESPACE ?= default
CLUSTER   ?= k8s-slo-lab

.PHONY: help up load burn break fix down lint status

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

up: ## Create the kind cluster, install Prometheus/Grafana, deploy podinfo
	./scripts/setup-cluster.sh
	./scripts/deploy-observability.sh
	./scripts/deploy-podinfo.sh
	@echo
	@echo "Grafana:    http://localhost:30090  (admin / admin)"
	@echo "podinfo:    kubectl -n $(NAMESPACE) port-forward svc/podinfo 9898:9898"
	@echo "Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090"

load: ## Drive healthy traffic so the dashboard and SLI have data
	./scripts/load.sh healthy 300

burn: ## Drive 5xx traffic and watch the fast-burn SLO alert fire
	./scripts/load.sh errors 900
	./scripts/alert-watch.sh PodinfoSLOFastBurn firing 600

break: ## Scale podinfo to zero and watch the availability alert fire
	kubectl -n $(NAMESPACE) scale deployment/podinfo --replicas=0
	./scripts/alert-watch.sh PodinfoUnavailable firing 300

fix: ## Scale podinfo back up and watch the alert clear
	kubectl -n $(NAMESPACE) scale deployment/podinfo --replicas=2
	kubectl -n $(NAMESPACE) rollout status deployment/podinfo
	./scripts/alert-watch.sh PodinfoUnavailable inactive 300

lint: ## Lint and render the chart against both value sets
	helm lint ./charts/podinfo
	helm lint ./charts/podinfo -f ./charts/podinfo/values-prod.yaml
	helm template podinfo ./charts/podinfo >/dev/null
	helm template podinfo ./charts/podinfo -f ./charts/podinfo/values-prod.yaml >/dev/null
	@echo "Chart renders clean against both value sets."

status: ## Show what is currently running
	@kubectl -n $(NAMESPACE) get deploy,hpa,svc -l app.kubernetes.io/name=podinfo
	@kubectl -n monitoring get prometheusrule,servicemonitor

down: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
