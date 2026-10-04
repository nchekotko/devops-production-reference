# DevOps-решение: веб-приложение в Kubernetes с Gateway API, мониторингом и логированием

Решение кейса **MTS ENGINEER HACK** (DevOps): развёртывание простого веб-приложения в
Kubernetes с организацией доступа через Kubernetes Gateway API, сбором метрик Prometheus
и сбором логов Fluentd. Полностью воспроизводимо на **Ubuntu 24.04** и сводится к
единственной команде `make deploy`. В решении реализованы production-практики: TLS,
персистентное хранилище, секреты, HPA/PDB, NetworkPolicy, алерты, дашборд, canary-деплой,
GitOps (ArgoCD) и CI/CD.

---

## 1. Краткое описание

- Кластер **Kubernetes v1.31.6**, развёрнутый через **kubeadm** (containerd + Calico + MetalLB).
- **Metrics Server** — для `kubectl top` и HorizontalPodAutoscaler.
- **Local Path Provisioner** — StorageClass `local-path` для персистентных PVC.
- Демо-приложение **Nginx** (`Hello World!`) с access/error-логами в stdout/stderr,
  sidecar **nginx-prometheus-exporter** для HTTP-метрик, **HPA** и **PDB**.
- Публикация через **Kubernetes Gateway API** — **Envoy Gateway** (GatewayClass → Gateway → HTTPRoute)
  с HTTP- и HTTPS-листенерами (TLS-терминация) и расширенной маршрутизацией
  (path, hostname, traffic splitting, canary).
- Мониторинг **Prometheus** (kube-prometheus-stack): метрики узлов/кластера/приложения,
  **алерты** (PrometheusRule), **Grafana dashboard**, персистентное хранилище метрик.
- Логирование **Fluentd** (DaemonSet) → **Loki** (persistent) → **Grafana**.
- Автоматизация **Ansible + Helm + Makefile**; идемпотентный повторный запуск;
  **GitOps** (ArgoCD + kustomize) и **CI/CD** (GitHub Actions).

---

## 2. Архитектура

```
                         ┌──────────────────────────────────────────┐
    Пользователь ──────► │  Envoy Gateway (LoadBalancer/MetalLB IP)  │
    curl HTTP/HTTPS     │  листенеры :80 (HTTP) и :443 (TLS)          │
                         └────────────────┬─────────────────────────┘
                                          │ Gateway / HTTPRoute (path/host/weight)
                                          ▼
                            ┌───────────────────────────┐
                            │  Nginx Deployment + Service│◄── nginx-exporter (метрики)
                            │  "Hello World!" + access.log│
                            └──────────────┬────────────┘
                                           │ stdout/stderr (контейнерные логи)
                                           ▼
                ┌──────────────────┐   ┌────────────────────────┐
                │  Prometheus       │◄──│  Fluentd DaemonSet      │
                │  (node-exporter,  │   │  (CRI-парсинг логов)    │
                │   kube-state-     │   └──────────┬─────────────┘
                │   metrics,        │              ▼
                │   nginx-exporter, │        ┌──────────────┐
                │   Alertmanager)   │        │  Loki (логи)  │
                └────────┬─────────┘        └───────┬───────┘
                         ▼                 ┌────────▼────────┐
                ┌───────────────────┐      │  Grafana (метрики│
                │ Metrics Server     │      │  + логи + alerts)│
                │ Local Path Prov.   │      └─────────────────┘
                └───────────────────┘
```

Поток данных: трафик → Gateway API → приложение; метрики → Prometheus; логи → Fluentd → Loki → Grafana.

---

## 3. Технологии и версии

| Компонент | Технология | Версия |
|---|---|---|
| Kubernetes | kubeadm | v1.31.6 |
| ОС | Ubuntu | 24.04 LTS |
| Container runtime | containerd | 1.7.24 |
| CNI | Calico | 3.29.3 |
| LoadBalancer | MetalLB (Layer2) | 0.14.9 |
| Метрики узлов (HPA) | Metrics Server | v0.7.2 |
| StorageClass | Local Path Provisioner | v0.0.31 |
| Gateway API | Envoy Gateway | v1.2.1 |
| Приложение | Nginx (+ nginx-prometheus-exporter) | 1.27.3 / 1.4.0 |
| Мониторинг | kube-prometheus-stack (Helm) | chart 80.6.0 |
| Логирование | Fluentd → Loki (Helm) | fluentd 1.17.2 / loki chart 6.7.1 |
| Плагин Fluentd→Loki | fluent-plugin-grafana-loki | 1.3.0 |
| GitOps | ArgoCD (+ kustomize) | v2.12.x |
| Автоматизация | Ansible, Helm, Make, GitHub Actions | ansible-core, helm 3.x |

---

## 4. Требования к среде

- Один сервер/ВМ с **Ubuntu 24.04 LTS** (root или sudo-доступ). Рекомендуется **4 vCPU / 8 ГБ RAM / 40 ГБ диск**
  (полный стек observability на одной ноде требователен к памяти; на 4 ГБ возможен OOM).
- Доступ к сети Интернет (apt, Helm-чарты, container images, GitHub raw).
- Установленные: `git`, `curl`. Остальное (containerd, docker-ce, kubeadm, Helm, ansible) ставится автоматически.
- Свободный IP-диапазон в локальной подсети для MetalLB (см. `LB_IP_RANGE`).

---

## 5. Пошаговая инструкция по развёртыванию

```bash
# Все шаги (установка пакетов, kubeadm, сборка образа Fluentd) требуют root.
sudo -i
git clone <URL_репозитория>
cd <repo>
make deploy
```

`make deploy` последовательно выполняет (все шаги идемпотентны):

| Шаг | Команда | Что делает |
|---|---|---|
| 1 | `make cluster` | `scripts/01-cluster.sh` — подготовка узла (containerd, docker-ce, kubeadm/kubelet/kubectl, Helm) и создание кластера (kubeadm init, Calico, MetalLB, Metrics Server, Local Path Provisioner) |
| 2 | `make app` | `scripts/02-app.sh` — Nginx (+ nginx-v2), Service, ConfigMap, HPA, PDB, NetworkPolicy |
| 3 | `make gateway` | `scripts/03-gateway.sh` — Envoy Gateway + TLS-сертификат + GatewayClass/Gateway/HTTPRoute |
| 4 | `make monitoring` | `scripts/04-monitoring.sh` — kube-prometheus-stack + ServiceMonitor + алерты + dashboard |
| 5 | `make logging` | `scripts/05-logging.sh` — Loki (persistent) + Fluentd DaemonSet |

Дополнительные команды:

| Команда | Назначение |
|---|---|
| `make verify` | сквозная проверка решения (PASS/FAIL) |
| `make canary PCT=20` | перевести 20% canary-трафика на `nginx-v2` (Gateway API) |
| `make gitops` | установить ArgoCD (GitOps-режим) |
| `make clean` | удалить решение (кластер остаётся) |

### Параметры (переменные окружения)

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `LB_IP_RANGE` | `192.168.1.240-192.168.1.250` | Диапазон адресов MetalLB — должен быть в подсети сети узла |

Пример: `LB_IP_RANGE=10.0.0.200-10.0.0.210 make deploy`

---

## 6. Проверка доступности приложения (Gateway API)

Envoy Gateway создаёт Service типа LoadBalancer; MetalLB назначает ему внешний IP.

```bash
kubectl get gateway eg -n default -o jsonpath='{.status.addresses[0].value}'
curl http://<IP>/
# ожидаемый ответ: Hello World!
```

Проверка расширенных возможностей Gateway API:

```bash
curl http://<IP>/                             # Hello World!      (fallback-маршрут)
curl http://<IP>/v1                           # Hello v1!         (path-маршрутизация)
curl http://<IP>/split                        # Hello World! / Hello World v2! (traffic split 80/20)
curl -H 'Host: hello.example.com' http://<IP>/  # Hello World v2! (hostname-маршрутизация)
curl -H 'Host: canary.example.com' http://<IP>/ # Hello World! / Hello World v2! (canary, вес через make canary)
curl -k https://<IP>/                         # Hello World!      (TLS-терминация, self-signed)
```

```bash
kubectl get gatewayclass,gw,gwroute -A
kubectl describe httproute nginx -n default
```

---

## 7. Проверка мониторинга (Prometheus)

```bash
kubectl port-forward -n monitoring svc/kps-prometheus 9090:9090
```

Запросы в http://localhost:9090 (или через API):

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up'
curl -s 'http://localhost:9090/api/v1/query?query=nginx_connections_active'
curl -s 'http://localhost:9090/api/v1/query?query=rate(nginx_http_requests_total[5m])'
```

Собираемые метрики:
- **node-exporter** — CPU/память/диск/сеть узлов;
- **kube-state-metrics** — состояние объектов Kubernetes;
- **nginx-exporter** (sidecar) — соединения, HTTP-запросы, коды, latency.

Алерты (Prometheus → Alertmanager): `NginxDown`, `NginxHigh5xxRate`
(см. `monitoring/prometheusrule-nginx.yaml`).

Grafana (метрики + логи + готовый дашборд «Nginx (Gateway API demo)»):

```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# http://localhost:3000 ; логин admin, пароль из Secret:
kubectl -n monitoring get secret grafana-admin-secret -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

---

## 8. Проверка логирования (Fluentd → Loki)

```bash
# сделать запрос к приложению, чтобы появилась запись в access-логе
curl http://<IP>/

# пробросить Loki
kubectl port-forward -n logging svc/loki 3100:3100

# проверить появление записи
curl -G 'http://localhost:3100/loki/api/v1/query_range' \
     --data-urlencode 'query={container_name="nginx"}'
```

Fluentd (DaemonSet) собирает логи всех контейнеров, парсит CRI-формат (поле `stream`
разделяет stdout=access / stderr=error) и отправляет в Loki с лейблами
`namespace_name`/`pod_name`/`container_name`. Просмотр — Grafana → Explore → Loki.

---

## 9. Сквозная проверка

```bash
make verify
```

Скрипт выполняет реальные проверки (с выводом PASS/FAIL и ненулевым кодом при сбое):
состояние узлов/подов, готовность деплойментов, назначение адреса Gateway, HTTP-ответ
приложения, расширенные маршруты (path/hostname/split/TLS), запросы Prometheus
(`up`, `nginx_connections_active`) и наличие записей в Loki.

---

## 10. Production-практики

| Практика | Реализация |
|---|---|
| TLS-терминация | HTTPS-листенер Gateway (:443), сертификат генерируется `03-gateway.sh` (для прода — cert-manager) |
| Персистентность | StorageClass `local-path`; PVC для Prometheus, Grafana, Loki |
| Секреты | Пароль Grafana — случайный, в Secret `grafana-admin-secret` (не в git); `.gitignore` исключает ключи/архивы |
| Надёжность | readiness/liveness-пробы, resources requests/limits, HPA, PDB |
| Безопасность | NetworkPolicy (default-deny + allow-list), RBAC для Fluentd, минимальные права |
| Наблюдаемость | Алерты Prometheus, готовый Grafana dashboard, retention метрик/логов 7 дней |
| Canary-деплой | HTTPRoute `nginx-canary` + `make canary PCT=N` (плавный сдвиг трафика) |
| GitOps | ArgoCD (bootstrap + Application) поверх kustomize-оверлея (`kubectl apply -k .`) |
| Воспроизводимость | Все версии закреплены (образы, Helm-чарты, гем), идемпотентный `make deploy` |
| CI/CD | GitHub Actions: shellcheck + kubeconform + hadolint |
| Teardown | `make clean` (удаление решения без сноса кластера) |

---

## 11. Дополнительные возможности

- **Расширенные возможности Gateway API**: path- и hostname-маршрутизация, несколько
  backend'ов, traffic splitting (weights), TLS-терминация.
- **Canary-деплой**: `make canary PCT=N` плавно переводит трафик между версиями
  приложения через Gateway API (`Host: canary.example.com`).
- **HTTP-метрики приложения**: nginx-prometheus-exporter (запросы, соединения, коды, latency).
- **CPU/RAM метрики**: node-exporter + kube-state-metrics; HPA по CPU.
- **Централизованный поиск логов**: Loki + единый UI Grafana (метрики + логи + алерты).
- **GitOps**: ArgoCD + kustomize-оверлей (см. `gitops/`).
- **Надёжность и безопасность**: HPA, PDB, NetworkPolicy, probes, resources, RBAC, секреты.

---

## 12. Структура репозитория

```
.
├── Makefile                        # make deploy / verify / canary / gitops / clean
├── kustomization.yaml              # kustomize-оверлей (kubectl apply -k ., для GitOps)
├── .github/workflows/ci.yml        # CI: shellcheck + kubeconform + hadolint
├── scripts/
│   ├── 01-cluster.sh               # подготовка узла + kubeadm-кластер
│   ├── 02-app.sh                   # Nginx-приложение
│   ├── 03-gateway.sh               # Envoy Gateway + TLS-сертификат
│   ├── 04-monitoring.sh            # Prometheus (+ секрет Grafana, алерты, дашборд)
│   ├── 05-logging.sh               # Loki + Fluentd
│   ├── canary.sh                   # сдвиг canary-трафика
│   ├── clean.sh                    # безопасный teardown решения
│   └── verify.sh                   # сквозная проверка (PASS/FAIL)
├── gitops/                         # ArgoCD bootstrap + Application + README
├── ansible/playbooks/              # prepare-node.yml, init-cluster.yml
├── kubernetes/cluster/             # kubeadm-config, metrics-server, local-path-provisioner
├── apps/nginx/                     # deployment(+v2), service(+v2), configmap(+v2), hpa, pdb, networkpolicy
├── gateway/                        # gatewayclass, gateway, httproute, httproute-host, httproute-canary
├── monitoring/                     # values-kps, servicemonitor, prometheusrule, dashboard
├── logging/                        # values-loki, fluentd DaemonSet + Dockerfile
└── docs/passport.md                # исходник паспорта решения
```

---

## 13. Известные ограничения

- Кластер — **один узел** (control-plane + workload). Для продакшена требуется добавить
  worker-узлы и настроить HA control-plane (дорожная карта — в паспорте).
- MetalLB работает в режиме **Layer2** (адрес из локальной подсети узла); BGP не используется.
- TLS-сертификат Gateway — **самоподписанный** (`curl -k`). Для публичного домена —
  cert-manager + Let's Encrypt.
- Образ Fluentd (с плагином Loki) собирается на узле из `logging/fluentd/Dockerfile`
  (docker-ce) и импортируется в containerd — решение рассчитано на одноузловой кластер.
  Для GitOps/multi-node образ нужно публиковать в registry.
- Loki/Prometheus/Grafana используют StorageClass `local-path` (данные на узле); для
  multi-node потребуется общее хранилище (NFS/CSI).
- Развёртывание выполняется от root (установка пакетов, kubeadm, сборка образа Fluentd).
