#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 04-monitoring.sh — kube-prometheus-stack (Prometheus + Grafana + Alertmanager
# + node-exporter + kube-state-metrics) + ServiceMonitor + алерты + дашборд.
# Версия чарта закреплена; пароль Grafana — случайный, в Secret (не в git).
# Идемпотентно: helm upgrade --install и kubectl apply безопасны при повторе.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

REPO_NAME="prometheus-community"
REPO_URL="https://prometheus-community.github.io/helm-charts"
CHART="kube-prometheus-stack"
CHART_VERSION="80.6.0"      # закреплённая версия чарта
RELEASE="kps"
NAMESPACE="monitoring"

# --- 1. Helm-репозиторий (идемпотентно) --------------------------------------
if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "${REPO_NAME}"; then
  helm repo add "${REPO_NAME}" "${REPO_URL}"
fi
helm repo update "${REPO_NAME}"

# --- 2. Secret Grafana (случайный пароль, не хранится в репозитории) ---------
echo "==> Подготовка Secret администратора Grafana"
if ! kubectl -n "${NAMESPACE}" get secret grafana-admin-secret >/dev/null 2>&1; then
  ADMIN_PASSWORD="$(openssl rand -hex 16)"
  kubectl -n "${NAMESPACE}" create secret generic grafana-admin-secret \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${ADMIN_PASSWORD}"
  echo "    Grafana admin password (сохраните): ${ADMIN_PASSWORD}"
else
  echo "    Secret grafana-admin-secret уже существует — пропускаем."
fi

# --- 3. Установка/обновление kube-prometheus-stack ---------------------------
echo "==> Установка/обновление kube-prometheus-stack ${CHART_VERSION} (release 'kps')"
helm upgrade --install "${RELEASE}" "${REPO_NAME}/${CHART}" \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f monitoring/values-kps.yaml

# --- 4. ServiceMonitor, алерты и дашборд -------------------------------------
echo "==> Применение ServiceMonitor, PrometheusRule и Grafana dashboard"
kubectl apply -f monitoring/nginx-servicemonitor.yaml \
             -f monitoring/prometheusrule-nginx.yaml \
             -f monitoring/grafana-dashboard-nginx.yaml

echo ""
echo "Monitoring deployed (chart ${CHART_VERSION})."
echo ""
echo "Port-forwards:"
echo "  Prometheus: kubectl port-forward -n ${NAMESPACE} svc/kps-prometheus 9090:9090"
echo "  Grafana:    kubectl port-forward -n ${NAMESPACE} svc/kps-grafana 3000:80"
echo ""
echo "Prometheus queries (Prometheus UI at http://localhost:9090):"
echo "  up"
echo "  nginx_connections_active"
echo "  rate(nginx_http_requests_total[5m])"
echo ""
echo "Grafana UI at http://localhost:3000 (логин admin, пароль из Secret):"
echo "  kubectl -n ${NAMESPACE} get secret grafana-admin-secret -o jsonpath='{.data.admin-password}' | base64 -d; echo"
