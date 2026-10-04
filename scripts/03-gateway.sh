#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 03-gateway.sh — установка Envoy Gateway v1.2.1 и настройка Gateway API.
# Дополнительно генерирует самоподписанный TLS-сертификат для HTTPS-листенера.
# Идемпотентно: `helm upgrade --install` и `kubectl apply` безопасны при повторе.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

NS=default
TLS_SECRET="nginx-tls"

# --- 1. Установка/обновление Envoy Gateway (Helm-чарт) -----------------------
echo "==> Установка/обновление Envoy Gateway v1.2.1 (release 'eg')"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.1 \
  --namespace envoy-gateway-system \
  --create-namespace

# --- 2. Самоподписанный сертификат для HTTPS-листенера (идемпотентно) --------
echo "==> Генерация TLS-сертификата (self-signed) для HTTPS-листенера"
if command -v openssl >/dev/null 2>&1; then
  if ! kubectl -n "$NS" get secret "$TLS_SECRET" >/dev/null 2>&1; then
    TMP_KEY="$(mktemp)"
    TMP_CRT="$(mktemp)"
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "$TMP_KEY" -out "$TMP_CRT" -days 365 \
      -subj "/CN=hello.example.com" \
      -addext "subjectAltName=DNS:hello.example.com,DNS:*.example.com" >/dev/null 2>&1
    kubectl -n "$NS" create secret tls "$TLS_SECRET" \
      --key="$TMP_KEY" --cert="$TMP_CRT" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -f "$TMP_KEY" "$TMP_CRT"
    echo "    Secret $TLS_SECRET создан (CN=hello.example.com)."
  else
    echo "    Secret $TLS_SECRET уже существует — пропускаем."
  fi
else
  echo "    WARN: openssl не найден — HTTPS-листенер не будет запрограммирован (HTTP продолжит работать)."
fi

# --- 3. Применение Gateway API-ресурсов --------------------------------------
echo "==> Применение Gateway API-ресурсов из каталога gateway/"
kubectl apply -f gateway/

# --- 4. Ожидание адреса Gateway (надёжно: status.addresses + fallback -A) ----
echo "==> Ожидание внешнего адреса Gateway"

GATEWAY_IP=""
for attempt in {1..60}; do
  # Приоритетно берём адрес из статуса Gateway (не зависит от namespace прокси).
  GATEWAY_IP="$(kubectl -n "$NS" get gateway eg -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
  GATEWAY_IP="${GATEWAY_IP//[[:space:]]/}"

  # Fallback: ищем LoadBalancer-сервис Envoy по всем namespace.
  if [[ -z "$GATEWAY_IP" || "$GATEWAY_IP" == "<none>" ]]; then
    GATEWAY_IP="$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.type}{" "}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null \
      | awk '$2=="LoadBalancer" && $1 ~ /envoy/ {print $3}' | head -n1 || true)"
    GATEWAY_IP="${GATEWAY_IP//[[:space:]]/}"
  fi

  if [[ -n "$GATEWAY_IP" && "$GATEWAY_IP" != "<none>" && "$GATEWAY_IP" != "<pending>" ]]; then
    break
  fi
  GATEWAY_IP=""
  printf '    Адрес ещё не назначен (%s/60), повтор через 5 сек...\n' "$attempt"
  sleep 5
done

if [[ -z "$GATEWAY_IP" ]]; then
  echo "ОШИБКА: не удалось дождаться адреса Gateway." >&2
  kubectl get gateway -n "$NS" >&2
  kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.type}{" "}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' >&2
  exit 1
fi

echo ""
echo "==> Приложение доступно через Gateway API:"
echo "    HTTP:   http://${GATEWAY_IP}/"
echo "    HTTPS:  https://${GATEWAY_IP}/   (самоподписанный сертификат: curl -k)"
echo ""
echo "Команды проверки:"
echo "  curl -fsS http://${GATEWAY_IP}/                               # Hello World!"
echo "  curl -fsS http://${GATEWAY_IP}/v1                             # Hello v1! (path-маршрут)"
echo "  curl -fsS http://${GATEWAY_IP}/split                          # Hello World! / Hello World v2! (traffic split 80/20)"
echo "  curl -fsS -H 'Host: hello.example.com' http://${GATEWAY_IP}/  # Hello World v2! (hostname-маршрут)"
echo "  curl -kfsS https://${GATEWAY_IP}/                             # Hello World! (TLS-терминация)"
