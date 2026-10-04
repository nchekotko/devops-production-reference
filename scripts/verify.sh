#!/usr/bin/env bash
# =============================================================================
# Сквозная проверка решения. Запуск: make verify
# Выполняет РЕАЛЬНЫЕ проверки: HTTP-ответ приложения через Gateway API,
# расширенные маршруты (path/hostname/split/TLS), метрики Prometheus и логи Loki.
# Печатает PASS/FAIL и возвращает ненулевой код, если хоть одна проверка упала.
# =============================================================================
set -uo pipefail

NS_APP=default
NS_MON=monitoring
NS_LOG=logging
FAIL=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# --- 1. Узлы -----------------------------------------------------------------
echo ""
echo "=== 1. Состояние узлов кластера ==="
kubectl get nodes -o wide

# --- 2. Поды -----------------------------------------------------------------
echo ""
echo "=== 2. Рабочие нагрузки (все namespace) ==="
kubectl get pods -A

# --- 3. Готовность приложения ------------------------------------------------
echo ""
echo "=== 3. Готовность приложения ==="
kubectl -n "$NS_APP" rollout status deploy/nginx --timeout=120s >/dev/null 2>&1 \
  && pass "deployment nginx Ready" || fail "deployment nginx не Ready"
kubectl -n "$NS_APP" rollout status deploy/nginx-v2 --timeout=120s >/dev/null 2>&1 \
  && pass "deployment nginx-v2 Ready" || fail "deployment nginx-v2 не Ready"

# --- 4. Gateway API ----------------------------------------------------------
echo ""
echo "=== 4. Ресурсы Gateway API ==="
kubectl get gatewayclass 2>/dev/null || true
kubectl get gateway,httproute -A 2>/dev/null || true

# --- 5. Внешний адрес Gateway -------------------------------------------------
echo ""
echo "=== 5. Внешний адрес (Gateway / LoadBalancer) ==="
IP="$(kubectl -n "$NS_APP" get gateway eg -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
IP="${IP//[[:space:]]/}"
if [[ -z "$IP" || "$IP" == "<none>" ]]; then
  IP="$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.type}{" "}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null \
    | awk '$2=="LoadBalancer" && $1 ~ /envoy/ {print $3}' | head -n1 || true)"
fi
if [[ -n "$IP" && "$IP" != "<none>" ]]; then
  pass "Назначен адрес Gateway: $IP"
else
  fail "Адрес Gateway не назначен (проверьте MetalLB и переменную LB_IP_RANGE)"
fi

# --- 6. HTTP-проверки приложения ---------------------------------------------
echo ""
echo "=== 6. Проверка приложения через Gateway API ==="
check_http() {
  local desc="$1"; local expect="$2"; shift 2
  local out
  out="$(curl -fsS --max-time 10 "$@" 2>/dev/null || true)"
  if echo "$out" | grep -qF "$expect"; then
    pass "$desc"
  else
    fail "$desc (ожидалось '${expect}', получено: '${out:0:80}')"
  fi
}

if [[ -n "$IP" && "$IP" != "<none>" ]]; then
  check_http "GET / возвращает 'Hello World!'" "Hello World!" "http://$IP/"
  check_http "GET /v1 возвращает 'Hello v1!'" "Hello v1!" "http://$IP/v1"
  check_http "Host: hello.example.com -> 'Hello World v2!'" "Hello World v2!" -H "Host: hello.example.com" "http://$IP/"
  check_http "HTTPS / (TLS-терминация, self-signed)" "Hello World!" -k "https://$IP/"

  # traffic split 80/20 — результат недетерминирован, проверяем одно из двух значений.
  out="$(curl -fsS --max-time 10 "http://$IP/split" 2>/dev/null || true)"
  if echo "$out" | grep -qE "Hello World!|Hello World v2!"; then
    pass "GET /split (traffic split) возвращает один из backend'ов"
  else
    fail "GET /split не вернул ожидаемый ответ (получено: '${out:0:80}')"
  fi
else
  echo "  (HTTP-проверки пропущены: нет адреса)"
fi

# --- 7. Prometheus -----------------------------------------------------------
echo ""
echo "=== 7. Проверка Prometheus ==="
prom_query() {
  local q="$1"
  kubectl -n "$NS_MON" port-forward svc/kps-prometheus 19090:9090 >/dev/null 2>&1 &
  local pid=$!
  sleep 5
  local res
  res="$(curl -s --max-time 10 "http://localhost:19090/api/v1/query" --data-urlencode "query=$q" 2>/dev/null || true)"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "$res"
}

up="$(prom_query 'up')"
if echo "$up" | grep -q '"status":"success"'; then
  pass "Prometheus отвечает на запрос 'up'"
else
  fail "Prometheus не отвечает (query up)"
fi

conn="$(prom_query 'nginx_connections_active')"
if echo "$conn" | grep -q 'nginx_connections_active'; then
  pass "Метрика nginx_connections_active доступна"
else
  fail "Метрика nginx_connections_active не найдена"
fi

# --- 8. Логирование (Fluentd -> Loki) ----------------------------------------
echo ""
echo "=== 8. Проверка логирования (Fluentd -> Loki) ==="
# Генерируем запрос, чтобы в access-логе появилась свежая запись.
if [[ -n "$IP" && "$IP" != "<none>" ]]; then
  curl -fsS --max-time 10 "http://$IP/" >/dev/null 2>&1 || true
fi
sleep 5

loki_query() {
  local q="$1"
  kubectl -n "$NS_LOG" port-forward svc/loki 13100:3100 >/dev/null 2>&1 &
  local pid=$!
  sleep 5
  local res
  res="$(curl -sG --max-time 10 'http://localhost:13100/loki/api/v1/query_range' \
    --data-urlencode "query=$q" --data-urlencode 'limit=5' 2>/dev/null || true)"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  echo "$res"
}

res="$(loki_query '{container_name="nginx"}')"
if echo "$res" | grep -q '"status":"success"' && echo "$res" | grep -q '"values"'; then
  pass "Loki содержит записи приложения ({container_name=\"nginx\"})"
else
  fail "В Loki не найдены записи приложения (проверьте Fluentd DaemonSet)"
fi

# --- 9. Grafana --------------------------------------------------------------
echo ""
echo "=== 9. Доступ к Grafana (метрики + логи) ==="
echo "  kubectl -n $NS_MON port-forward svc/kps-grafana 3000:80"
echo "  # http://localhost:3000 , логин admin, пароль из Secret:"
echo "  kubectl -n $NS_MON get secret grafana-admin-secret -o jsonpath='{.data.admin-password}' | base64 -d; echo"

# --- Итог --------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ИТОГ: все проверки пройдены ==="
else
  echo "=== ИТОГ: провалено проверок: $FAIL ==="
fi
exit "$FAIL"
