#!/usr/bin/env bash
# =============================================================================
# bootstrap-argocd.sh — установка ArgoCD (GitOps-режим).
# Устанавливает ArgoCD в namespace `argocd` и выводит команды доступа.
# После установки примените gitops/argocd/application.yaml (с реальным repoURL).
# =============================================================================
set -euo pipefail

ARGOCD_VERSION="v2.12.6"
NS="argocd"

echo "==> Установка ArgoCD ${ARGOCD_VERSION}"
kubectl create namespace "$NS" 2>/dev/null || true
kubectl apply -n "$NS" -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> Ожидание готовности argocd-server"
kubectl -n "$NS" rollout status deploy/argocd-server --timeout=300s

echo ""
echo "ArgoCD установлен. Доступ к UI:"
echo "  kubectl -n $NS port-forward svc/argocd-server 8080:443"
echo "  # https://localhost:8080 ; логин admin, пароль:"
echo "  kubectl -n $NS get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo ""
echo "Дальше задеплойте приложение (подставьте реальный repoURL в gitops/argocd/application.yaml):"
echo "  kubectl apply -f gitops/argocd/application.yaml"
