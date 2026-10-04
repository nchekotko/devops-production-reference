#!/usr/bin/env bash
# =============================================================================
# clean.sh — безопасный teardown решения.
# Удаляет развёрнутые компоненты (приложение, Gateway API, monitoring, logging)
# и Helm-релизы, НО НЕ трогает кластер и инфраструктуру
# (Calico/MetalLB/metrics-server/local-path-provisioner остаются).
# Для полного сброса узла используйте отдельно: kubeadm reset -f
# Идемпотентно: повторный запуск безопасен (ошибки "not found" игнорируются).
# =============================================================================
set -uo pipefail

echo "==> Удаление Helm-релизов"
helm uninstall kps -n monitoring 2>/dev/null || true
helm uninstall loki -n logging 2>/dev/null || true
helm uninstall eg -n envoy-gateway-system 2>/dev/null || true

echo "==> Удаление namespace'ов (monitoring, logging, envoy-gateway-system)"
kubectl delete namespace monitoring logging envoy-gateway-system --ignore-not-found 2>/dev/null || true

echo "==> Удаление ресурсов приложения и Gateway API (namespace default)"
kubectl delete -f apps/nginx/ 2>/dev/null || true
kubectl delete -f gateway/ 2>/dev/null || true
kubectl -n default delete secret nginx-tls --ignore-not-found 2>/dev/null || true

echo ""
echo "==> Решение удалено. Кластер и инфраструктура сохранены."
echo "    Повторное развёртывание: make deploy"
echo "    Полный сброс узла (вручную, осторожно!): kubeadm reset -f"
