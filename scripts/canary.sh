#!/usr/bin/env bash
# =============================================================================
# canary.sh — сдвиг canary-трафика через Gateway API (traffic splitting).
# Использование: bash scripts/canary.sh <0..100>
#   аргумент — процент трафика на canary-версию (nginx-v2); остальное на v1.
# Пример: bash scripts/canary.sh 20  -> 80% v1 / 20% v2
# =============================================================================
set -euo pipefail

PCT="${1:-5}"
if ! [[ "$PCT" =~ ^[0-9]+$ ]] || (( PCT < 0 || PCT > 100 )); then
  echo "Использование: $0 <0..100>  — процент трафика на canary-версию (nginx-v2)" >&2
  exit 1
fi
V1=$((100 - PCT))

kubectl -n default patch httproute nginx-canary --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/0/weight\",\"value\":${V1}},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/backendRefs/1/weight\",\"value\":${PCT}}
]"

echo "Canary (Host: canary.example.com): nginx v1 = ${V1}%, nginx-v2 = ${PCT}%"
echo "Проверка распределения:"
echo "  for i in \$(seq 1 20); do curl -s -H 'Host: canary.example.com' http://<IP>/; echo; done"
