SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help cluster app gateway monitoring logging deploy verify

help: ## Показать доступные команды
	@echo "Цели:"
	@echo "  make cluster     - подготовка узла + kubeadm-кластер (Calico, MetalLB)"
	@echo "  make app         - развернуть Nginx-приложение"
	@echo "  make gateway     - развернуть Envoy Gateway (Gateway API)"
	@echo "  make monitoring  - развернуть Prometheus (kube-prometheus-stack)"
	@echo "  make logging     - развернуть Loki + Fluentd"
	@echo "  make deploy      - всё вместе (идемпотентно)"
	@echo "  make verify      - сквозная проверка решения"

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
