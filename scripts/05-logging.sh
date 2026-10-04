#!/usr/bin/env bash
# Развёртывание логирования: Loki (Helm) + Fluentd DaemonSet (кастомный образ) + datasource Grafana.
# Идемпотентно: helm upgrade --install и kubectl apply можно запускать повторно.
set -euo pipefail

# Пути ниже — относительно корня репозитория.
cd "$(dirname "$0")/.."

HELM_REPO="grafana"
HELM_REPO_URL="https://grafana.github.io/helm-charts"
LOKI_RELEASE="loki"
LOKI_NAMESPACE="logging"
IMAGE="fluentd-loki:1.17"
TARBALL="/tmp/fluentd-loki.tar"

echo "=== 1. Добавление Helm-репозитория grafana ==="
helm repo add "$HELM_REPO" "$HELM_REPO_URL"
helm repo update

echo ""
echo "=== 2. Установка Loki (single-binary, filesystem, PVC) ==="
helm upgrade --install "$LOKI_RELEASE" grafana/loki \
  --namespace "$LOKI_NAMESPACE" \
  --create-namespace \
  --values logging/values-loki.yaml

echo ""
echo "=== 3. Сборка кастомного образа Fluentd с плагином Loki ==="
if ! command -v docker >/dev/null 2>&1; then
  echo "ОШИБКА: docker не найден в PATH. Установите docker и повторите запуск." >&2
  exit 1
fi
echo "docker build -t $IMAGE logging/fluentd"
docker build -t "$IMAGE" logging/fluentd

echo "docker save $IMAGE -o $TARBALL"
docker save "$IMAGE" -o "$TARBALL"

echo ""
echo "=== 4. Импорт образа в containerd (namespace k8s.io) ==="
if ! command -v ctr >/dev/null 2>&1; then
  echo "ОШИБКА: ctr не найден в PATH. Проверьте установку containerd." >&2
  exit 1
fi
echo "ctr -n k8s.io images import $TARBALL"
ctr -n k8s.io images import "$TARBALL"

echo ""
echo "=== 5. Применение манифестов Fluentd и datasource Loki ==="
kubectl apply -f logging/fluentd-kubernetes.yaml -f logging/grafana-datasource-loki.yaml

echo ""
echo "=== Готово. Проверка появления записей в Loki ==="
echo "  # 1. Сделать HTTP-запрос к приложению (nginx пишет access-лог в stdout):"
echo "  #    curl http://<адрес-приложения>/"
echo "  # 2. Пробросить порт Loki:"
echo "  kubectl -n logging port-forward svc/loki 3100:3100"
echo "  # 3. Запросить логи приложения:"
echo "  curl -G 'http://localhost:3100/loki/api/v1/query_range' --data-urlencode 'query={container_name=\"nginx\"}'"
