# Паспорт решения — DevOps-кейс (MTS ENGINEER HACK)

> Краткий документ для быстрого ознакомления экспертов. Полная документация — в README.md репозитория.

---

## Страница 1. Архитектура и состав решения

| Параметр | Значение |
|---|---|
| Версия Kubernetes | **v1.31.6** |
| Способ развёртывания Kubernetes | **kubeadm** (один control-plane узел; containerd 1.7.24, CNI Calico 3.29.3, MetalLB 0.14.9, Metrics Server 0.7.2, Local Path Provisioner 0.0.31) |
| Реализация Gateway API | **Envoy Gateway v1.2.1** (GatewayClass + Gateway + HTTPRoute; HTTP :80 + HTTPS :443) |
| Инструменты автоматизации | **Ansible** (узел и кластер) + **Helm** (компоненты) + **Makefile** (`make deploy`) + **GitHub Actions** (CI) |
| Инструмент логирования | **Fluentd** (DaemonSet) → **Loki** → Grafana |
| Способ развёртывания Prometheus | **kube-prometheus-stack** (Helm, chart 80.6.0: Prometheus Operator + Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics) |
| ОС тестирования | **Ubuntu 24.04 LTS** |

### Архитектурная схема

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
                                         │ stdout/stderr (CRI-логи)
                                         ▼
              ┌──────────────────┐   ┌────────────────────────┐
              │  Prometheus       │◄──│  Fluentd DaemonSet      │
              │  (+Alertmanager)  │   │  (CRI-парсинг)          │
              └────────┬─────────┘   └──────────┬─────────────┘
                       ▼                        ▼
              ┌────────────────┐        ┌──────────────┐
              │ Metrics Server  │        │  Loki (логи)  │
              │ Local Path Prov.│        └──────┬───────┘
              └────────────────┘               ▼
                                      ┌─────────────────┐
                                      │ Grafana (метрики │
                                      │ + логи + алерты) │
                                      └─────────────────┘
```

Поток данных: трафик → Gateway API → приложение; метрики → Prometheus; логи → Fluentd → Loki → Grafana.

---

## Страница 2. Реализованный функционал

### Обязательные компоненты

**1. Kubernetes-окружение (kubeadm, Ubuntu 24.04)**
- *Как реализовано:* Ansible `prepare-node.yml` (containerd, docker-ce, kubeadm/kubelet/kubectl, sysctl, Helm) и `init-cluster.yml` (`kubeadm init`, Calico, MetalLB, Metrics Server, Local Path Provisioner).
- *Обоснование:* kubeadm — приоритет по ТЗ, вендор-нейтральный, полный контроль.
- *Проверка:* `kubectl get nodes` → `Ready`.

**2. Демо-приложение (Nginx)**
- *Как реализовано:* Deployment (2 реплики) + Service + ConfigMap; `GET /` → `Hello World!`; access-лог в stdout, error-лог в stderr; sidecar nginx-prometheus-exporter; HPA (min 2 / max 6, CPU 70%) и PDB (minAvailable 1).
- *Обоснование:* публичный образ `nginx:1.27.3`, однозначно проверяемый ответ.
- *Проверка:* `curl http://<LB-IP>/` → `Hello World!`.

**3. Gateway API (Envoy Gateway)**
- *Как реализовано:* GatewayClass `eg` → Gateway `eg` (listener :80 HTTP и :443 HTTPS/TLS) → HTTPRoute → Service `nginx:80`; внешний IP от MetalLB.
- *Обоснование:* флагманская open-source реализация Gateway API (CNCF).
- *Проверка:* `curl http://<LB-IP>/` и `curl -k https://<LB-IP>/` возвращают ответ приложения.

**4. Мониторинг (Prometheus)**
- *Как реализовано:* kube-prometheus-stack (chart 80.6.0); ServiceMonitor для nginx-exporter; node-exporter и kube-state-metrics из коробки; персистентное хранилище метрик (retention 7 дней).
- *Обоснование:* один чарт закрывает Prometheus + Grafana + Alertmanager + экспортеры.
- *Проверка:* Prometheus query `up` и `nginx_connections_active` возвращают данные.

**5. Логирование (Fluentd → Loki)**
- *Как реализовано:* Fluentd DaemonSet (образ с плагином `fluent-plugin-grafana-loki` 1.3.0) парсит CRI-логи и шлёт в Loki (persistent); Grafana подключена к Loki.
- *Обоснование:* Fluentd — требование ТЗ; Loki лёгкий и работает в той же Grafana.
- *Проверка:* после `curl` запись видна в Loki (`{container_name="nginx"}`).

**6. Ubuntu 24.04** — всё тестируется на Ubuntu 24.04 LTS.

**7. Автоматизация и идемпотентность** — `make deploy`; повторный запуск безопасен (`kubectl apply`, `helm upgrade --install`, guard'ы).

### Production-практики и дополнительные улучшения

| Улучшение | Реализация |
|---|---|
| TLS-терминация | HTTPS-листенер Gateway (:443), сертификат генерируется скриптом |
| Расширенный Gateway API | path- и hostname-маршрутизация, несколько backend'ов, traffic splitting (80/20) |
| HTTP-метрики приложения | sidecar nginx-prometheus-exporter: запросы, коды, latency |
| Персистентность | StorageClass `local-path`; PVC для Prometheus, Grafana, Loki |
| Секреты | пароль Grafana — случайный, в Secret (не в git) |
| Надёжность | HPA, PDB, probes, resources requests/limits |
| Безопасность | NetworkPolicy (default-deny + allow-list), RBAC, минимальные права |
| Наблюдаемость | алерты Prometheus, готовый Grafana dashboard, retention 7 дней |
| Canary-деплой | HTTPRoute `nginx-canary` + `make canary PCT=N` (плавный сдвиг трафика) |
| GitOps | ArgoCD (bootstrap + Application) + kustomize-оверлей (`kubectl apply -k .`) |
| CI/CD | GitHub Actions: shellcheck + kubeconform + hadolint |
| Воспроизводимость | закреплены версии образов, Helm-чартов и гема |

---

## Страница 3. Ревью работы и потенциальное масштабирование

**Главная особенность решения.** Сбалансированный, полностью воспроизводимый стек на вендор-нейтральных open-source компонентах (kubeadm + Envoy Gateway + kube-prometheus-stack + Fluentd/Loki), доведённый до production-уровня (TLS, персистентность, секреты, HPA/PDB, NetworkPolicy, алерты, CI/CD) и сведённый к одной команде `make deploy`.

**Самое сложное решение.** Связка логирования: между Fluentd→Elasticsearch (готовый образ, но тяжёлое хранилище) и Fluentd→Loki (лёгкое, но нужен кастомный образ с плагином). Выбрали Loki ради единого UI с метриками в Grafana и низкого потребления ресурсов; сборку образа сделали воспроизводимой (закреплённый гем).

**Предложения по дальнейшему развитию:**
- HA-топология: несколько worker-узлов, HA control-plane (3 master, etcd);
- cert-manager + Let's Encrypt вместо самоподписанного сертификата (нужен публичный домен);
- Общее сетевое хранилище (NFS/CSI) вместо `local-path` для multi-node;
- Полный GitOps: перевод Helm-чартов в ArgoCD, Flux-альтернатива, pipeline deploy-to-production;
- Расширенный observability: eBPF (Cilium Hubble), SLO/SLI-метрики, федерация Prometheus;
- Для телеком-специфики: горизонтальное масштабирование ingress-шлюза, canary-деплой через Gateway API, единая платформа логирования с ретеншн-политиками.
