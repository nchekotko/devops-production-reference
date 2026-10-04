# GitOps-режим (ArgoCD)

Репозиторий поддерживает два способа развёртывания прикладного слоя:

1. **Скриптовый (основной):** `make deploy` — Ansible + Helm + `kubectl apply`.
2. **GitOps:** ArgoCD следит за репозиторием и сам приводит кластер в состояние,
   описанное в kustomize-оверлее (`kustomization.yaml` в корне репозитория).

## Что управляется через GitOps

Kustomize-оверлей `kustomization.yaml` объединяет raw-манифесты:
- приложение (`apps/nginx/`): Deployment(+v2), Service(+v2), ConfigMap(+v2), HPA, PDB, NetworkPolicy;
- Gateway API (`gateway/`): GatewayClass, Gateway (HTTP/HTTPS), HTTPRoute (fallback/path/split), hostname- и canary-маршруты;
- конфиги мониторинга (`monitoring/`): ServiceMonitor, PrometheusRule, Grafana dashboard;
- логирование (`logging/`): Fluentd DaemonSet, datasource Loki.

## Порядок развёртывания GitOps-режима

GitOps управляет **прикладным слоем**, а инфраструктура (кластер и Helm-чарты)
ставится заранее — они создают CRD и namespace'ы, от которых зависят манифесты:

```bash
# 1. Кластер + Helm-чарты (Envoy Gateway, kube-prometheus-stack, Loki) + образ Fluentd + TLS-секрет
make cluster gateway monitoring logging
# (приложение можно НЕ ставить через make app — его задеплоит ArgoCD)

# 2. ArgoCD
make gitops

# 3. Применить Application (предварительно замените repoURL в gitops/argocd/application.yaml)
kubectl apply -f gitops/argocd/application.yaml
```

После этого ArgoCD синхронизирует прикладной слой с веткой `main` и будет
поддерживать его в актуальном состоянии (self-heal + prune).

## Ограничения и примечания

- **repoURL** в `gitops/argocd/application.yaml` — заглушка; замените на реальный URL.
- **Образ Fluentd** (`fluentd-loki:1.17`) собирается и импортируется в containerd
  скриптом `make logging` (GitOps не собирает образы). В multi-node потребуется
  публикация образа в registry и указание его в DaemonSet.
- **TLS-секрет** `nginx-tls` для HTTPS-листенера создаётся `make gateway`.
- Helm-чарты (Envoy Gateway, kube-prometheus-stack, Loki) намеренно оставлены в
  `make`-скриптах, чтобы не усложнять демо; при желании их можно перевести в
  ArgoCD как Helm-приложения (source.chart + helm.values / valueFiles).

## Ручной декларативный деплой (без ArgoCD)

```bash
kubectl apply -k .
```
