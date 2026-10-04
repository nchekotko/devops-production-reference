#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 03-gateway.sh — установка Envoy Gateway v1.2.1 и настройка Gateway API.
# Идемпотентность обеспечивается через `helm upgrade --install` и `kubectl apply`.
# =============================================================================

# --- 1. Установка/обновление Envoy Gateway (Helm-чарт) -----------------------
echo "==> Установка/обновление Envoy Gateway v1.2.1 (release 'eg')"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.1 \
  --namespace envoy-gateway-system \
  --create-namespace

# --- 2. Применение Gateway API-ресурсов (GatewayClass, Gateway, HTTPRoute) ---
echo "==> Применение Gateway API-ресурсов из каталога gateway/"
kubectl apply -f gateway/

# --- 3. Ожидание выдачи External-IP сервису Envoy (типа LoadBalancer) -------
# Точное имя сервиса Envoy может быть вида envoy-default-eg-<hash>,
# поэтому ищем ЛЮБОЙ LoadBalancer-сервис в namespace default по External-IP.
echo "==> Ожидание External-IP сервиса Envoy Gateway (LoadBalancer) в namespace default"

LB_IP=""
for attempt in {1..60}; do
  LB_IP="$(kubectl get svc -n default -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | head -n 1 || true)"
  LB_IP="${LB_IP//[[:space:]]/}"
  if [[ -n "${LB_IP}" && "${LB_IP}" != "<none>" && "${LB_IP}" != "<pending>" ]]; then
    break
  fi
  LB_IP=""
  printf '    External-IP ещё не назначен (%s/60), повтор через 5 сек...\n' "${attempt}"
  sleep 5
done

if [[ -z "${LB_IP}" ]]; then
  echo "ОШИБКА: не удалось дождаться External-IP у LoadBalancer-сервиса Envoy Gateway." >&2
  echo "Текущее состояние сервисов в namespace default:" >&2
  kubectl get svc -n default -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.type}{" "}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' >&2
  exit 1
fi

# --- 4. Вывод команды проверки доступа --------------------------------------
echo ""
echo "==> Envoy Gateway доступен по адресу: http://${LB_IP}/"
echo ""
echo "Команда проверки доступа через Gateway API:"
echo "  curl http://${LB_IP}/"
echo "Ожидаемый ответ:"
echo "  Hello World!"
