#!/usr/bin/env bash
set -euo pipefail

# Deploy the monitoring stack (kube-prometheus-stack) and the nginx ServiceMonitor.
# Idempotent: `helm upgrade --install` and `kubectl apply` are safe to re-run.

# Resolve the repository root so the script works regardless of the current cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

REPO_NAME="prometheus-community"
REPO_URL="https://prometheus-community.github.io/helm-charts"
CHART="kube-prometheus-stack"
RELEASE="kps"
NAMESPACE="monitoring"

# Add the Helm repository (idempotent) and refresh its index.
if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "${REPO_NAME}"; then
  helm repo add "${REPO_NAME}" "${REPO_URL}"
fi
helm repo update "${REPO_NAME}"

# Install/upgrade kube-prometheus-stack.
helm upgrade --install "${RELEASE}" "${REPO_NAME}/${CHART}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f monitoring/values-kps.yaml

# Deploy the nginx application ServiceMonitor (picked up via label `release: kps`).
kubectl apply -f monitoring/nginx-servicemonitor.yaml

echo ""
echo "Monitoring deployed."
echo ""
echo "Port-forwards:"
echo "  Prometheus: kubectl port-forward -n ${NAMESPACE} svc/kps-prometheus 9090:9090"
echo "  Grafana:    kubectl port-forward -n ${NAMESPACE} svc/kps-grafana 3000:3000"
echo ""
echo "Prometheus queries (Prometheus UI at http://localhost:9090):"
echo "  up"
echo "  nginx_connections_active"
echo ""
echo "Grafana UI at http://localhost:3000 (default admin / prom-operator)."
