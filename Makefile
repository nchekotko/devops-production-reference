SHELL := /bin/bash
.DEFAULT_GOAL := help

# Процент трафика на canary-версию для `make canary` (0..100).
PCT ?= 5

.PHONY: help cluster app gateway monitoring logging deploy verify canary gitops clean

help: ## Показать доступные команды
	@echo "Цели:"
	@echo "  make cluster     - подготовка узла + kubeadm-кластер (Calico, MetalLB, Metrics Server, Local Path)"
	@echo "  make app         - развернуть Nginx-приложение (HPA/PDB/NetworkPolicy)"
	@echo "  make gateway     - развернуть Envoy Gateway (Gateway API + TLS)"
	@echo "  make monitoring  - развернуть Prometheus (kube-prometheus-stack)"
	@echo "  make logging     - развернуть Loki + Fluentd"
	@echo "  make deploy      - всё вместе (идемпотентно)"
	@echo "  make verify      - сквозная проверка решения (PASS/FAIL)"
	@echo "  make canary PCT=N- сдвинуть canary-трафик на N% в nginx-v2 (по умолчанию 5)"
	@echo "  make gitops      - установить ArgoCD (GitOps-режим)"
	@echo "  make clean       - удалить решение (кластер остаётся)"

cluster:
	bash scripts/01-cluster.sh

app:
	bash scripts/02-app.sh

gateway:
	bash scripts/03-gateway.sh

monitoring:
	bash scripts/04-monitoring.sh

logging:
	bash scripts/05-logging.sh

deploy: cluster app gateway monitoring logging
	@echo ""
	@echo "Развёртывание завершено. Проверьте решение: make verify"

verify:
	bash scripts/verify.sh

canary:
	bash scripts/canary.sh $(PCT)

gitops:
	bash gitops/bootstrap-argocd.sh

clean:
	bash scripts/clean.sh
