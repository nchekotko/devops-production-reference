#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f apps/nginx/

kubectl -n default rollout status deploy/nginx --timeout=120s
kubectl -n default rollout status deploy/nginx-v2 --timeout=120s
