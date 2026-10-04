#!/usr/bin/env bash
# Сквозная проверка решения (best-effort). Запускать: make verify
set -uo pipefail

NS_APP=default
NS_MON=monitoring
NS_LOG=logging

echo ""
echo "=== 1. Состояние узлов кластера ==="
kubectl get nodes -o wide

echo ""
echo "=== 2. Рабочие нагрузки (все namespace) ==="
kubectl get pods -A

echo ""
echo "=== 3. Ожидание готовности приложения ==="
kubectl -n "$NS_APP" rollout status deploy/nginx --timeout=120s || echo "(предупреждение: deployment nginx не Ready)"

echo ""
echo "=== 4. Ресурсы Gateway API ==="
kubectl get gatewayclass 2>/dev/null || true
kubectl get gateway,httproute -A 2>/dev/null || kubectl get gw,gwroute -A 2>/dev/null || true

echo ""
echo "=== 5. Сервисы и их внешние адреса ==="
kubectl get svc -A

echo ""
echo "=== 6. Проверка приложения через Gateway API ==="
# Envoy Gateway создаёт Service типа LoadBalancer (MetalLB выдаёт IP)
IP="$(kubectl get svc -n "$NS_APP" -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null | awk '{print $1}')"
if [ -n "$IP" ] && [ "$IP" != "" ]; then
  echo "LoadBalancer IP: $IP"
  echo "Ответ приложения:"
  curl -fsS "http://$IP/" || echo "(curl не выполнен)"
else
  echo "LoadBalancer IP ещё не назначен. Выполните вручную:"
  echo "  curl http://<LB-IP>/        # ожидается: Hello World!"
fi

echo ""
echo "=== 7. Проверка Prometheus ==="
echo "  kubectl -n $NS_MON port-forward svc/kps-prometheus 9090:9090"
echo "  # затем в браузере/curl: http://localhost:9090/api/v1/query?query=up"

echo ""
echo "=== 8. Проверка логирования (Loki) ==="
echo "  kubectl -n $NS_LOG port-forward svc/loki 3100:3100"
echo "  # затем:"
echo "  curl -G 'http://localhost:3100/loki/api/v1/query_range' \\"
echo "        --data-urlencode 'query={container_name=\"nginx\"}'"

echo ""
echo "=== 9. Доступ к Grafana (метрики + логи) ==="
echo "  kubectl -n $NS_MON port-forward svc/kps-grafana 3000:80"
echo "  # login: admin / password: prom-operator (значение по умолчанию; смените при необходимости)"
