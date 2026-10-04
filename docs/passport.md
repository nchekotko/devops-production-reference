# Паспорт решения — DevOps-кейс (MTS ENGINEER HACK)

> Краткий документ для быстрого ознакомления экспертов. Полная документация — в README.md репозитория.

---

## Страница 1. Архитектура и состав решения

| Параметр | Значение |
|---|---|
| Версия Kubernetes | **v1.31.6** |
| Способ развёртывания Kubernetes | **kubeadm** (один control-plane узел, containerd 1.7.24, CNI Calico 3.29.3, MetalLB 0.14.9) |
| Реализация Gateway API | **Envoy Gateway v1.2.1** (GatewayClass + Gateway + HTTPRoute) |
| Инструменты автоматизации | **Ansible** (подготовка узла и кластера) + **Helm** (компоненты) + **Makefile** (`make deploy`) |
| Инструмент логирования | **Fluentd** (DaemonSet) → **Loki** → Grafana |
| Способ развёртывания Prometheus | **kube-prometheus-stack** (Helm, Prometheus Operator + Grafana + node-exporter + kube-state-metrics) |
| ОС тестирования | **Ubuntu 24.04 LTS** |

### Архитектурная схема

```
                        ┌──────────────────────────────────────┐
   Пользователь ──────► │  Envoy Gateway (LoadBalancer/MetalLB) │
   curl / HTTPS        └────────────────┬─────────────────────┘
                                        │ Gateway / HTTPRoute (path/host)
                                        ▼
                          ┌───────────────────────────┐
                          │  Nginx Deployment + Service│◄── nginx-exporter (метрики)
                          │  "Hello World!" + access.log│
                          └──────────────┬────────────┘
                                         │ stdout/stderr (контейнерные логи)
                                         ▼
              ┌──────────────────┐   ┌────────────────────────┐
              │  Prometheus       │◄──│  Fluentd DaemonSet      │
              │  (node-exporter,  │   │  (сбор логов контейнеров)│
              │   kube-state-     │   └──────────┬─────────────┘
              │   metrics,        │              ▼
              │   nginx-exporter) │        ┌──────────────┐
              └────────┬─────────┘        │  Loki (логи)  │
                       ▼                  └───────┬───────┘
              ┌───────────────────────────────────▼────────┐
              │          Grafana (метрики + логи)           │
              └────────────────────────────────────────────┘
```

Поток данных: трафик → Gateway API → приложение; метрики → Prometheus; логи → Fluentd → Loki → Grafana.

---

## Страница 2. Реализованный функционал

### Обязательные компоненты

**1. Kubernetes-окружение (kubeadm, Ubuntu 24.04)**
- *Как реализовано:* Ansible-плейбуки `prepare-node.yml` (containerd, kubeadm/kubelet/kubectl, sysctl, Helm) и `init-cluster.yml` (`kubeadm init`, Calico, MetalLB).
- *Обоснование:* kubeadm — приоритет по ТЗ, вендор-нейтральный, полный контроль.
- *Проверка:* `kubectl get nodes` → `Ready`.

**2. Демо-приложение (Nginx)**
- *Как реализовано:* Deployment (2 реплики) + Service + ConfigMap; `GET /` → `Hello World!`; access-лог в stdout, error-лог в stderr.
- *Обоснование:* публичный образ `nginx:1.27.3`, однозначно проверяемый ответ.
- *Проверка:* `curl http://<LB-IP>/` → `Hello World!`.

**3. Gateway API (Envoy Gateway)**
- *Как реализовано:* GatewayClass `eg` → Gateway `eg` (listener :80) → HTTPRoute → Service `nginx:80`; внешний IP от MetalLB.
- *Обоснование:* флагманская open-source реализация Gateway API (CNCF), нативная поддержка всех ресурсов.
- *Проверка:* `curl http://<LB-IP>/` через Gateway API возвращает ответ приложения.

**4. Мониторинг (Prometheus)**
- *Как реализовано:* kube-prometheus-stack; ServiceMonitor `nginx-metrics` для nginx-prometheus-exporter; node-exporter и kube-state-metrics из коробки.
- *Обоснование:* один чарт закрывает Prometheus + Grafana + экспортеры инфраструктуры.
- *Проверка:* Prometheus query `up` и `nginx_connections_active` возвращают данные.

**5. Логирование (Fluentd → Loki)**
- *Как реализовано:* Fluentd DaemonSet (образ с плагином `fluent-plugin-grafana-loki`) собирает логи контейнеров и шлёт в Loki; Grafana подключена к Loki.
- *Обоснование:* Fluentd — требование ТЗ; Loki лёгкий и работает в той же Grafana, что и метрики.
- *Проверка:* после `curl` запись видна в Loki (`{container_name="nginx"}`).

**6. Поддержка Ubuntu 24.04** — всё тестируется на Ubuntu 24.04 LTS.

**7. Автоматизация и идемпотентность** — `make deploy` последовательно выполняет все шаги; повторный запуск безопасен (`kubectl apply`, `helm upgrade --install`, guard'ы в Ansible).

### Дополнительные улучшения

| Улучшение | Реализация |
|---|---|
| Расширенные возможности Gateway API | маршрутизация по path и hostname (HTTPRoute с несколькими правилами) |
| HTTP-метрики приложения | sidecar nginx-prometheus-exporter: запросы, соединения, коды |
| Метрики CPU/RAM инфраструктуры | node-exporter + kube-state-metrics |
| Централизованный поиск логов | Loki + Grafana (единый UI для метрик и логов) |
| Практики надёжности | probes, resources requests/limits, RBAC, отсутствие секретов в репозитории |

---

## Страница 3. Ревью работы и потенциальное масштабирование

**Главная особенность решения.** Сбалансированный, полностью воспроизводимый стек на вендор-нейтральных open-source компонентах: kubeadm + Envoy Gateway + kube-prometheus-stack + Fluentd/Loki, сведённый к единой команде `make deploy`.

**Самое сложное решение.** Выбор связки логирования: между Fluentd→Elasticsearch (готовый образ, но тяжёлое хранилище) и Fluentd→Loki (лёгкое, но нужен кастомный образ с плагином). Выбрали Loki ради единого UI с метриками в Grafana и низкого потребления ресурсов.

**Предложения по дальнейшему развитию:**
- TLS-терминация на Gateway (cert-manager + Let's Encrypt) — нужен публичный домен;
- CI/CD (GitHub Actions: lint манифестов, kubeconform, smoke-тест после деплоя);
- Горизонтальное масштабирование: несколько worker-узлов, HPA для приложения;
- Расширенный observability: Alertmanager-правила, Grafana dashboards, retention-политики Loki;
- Для телеком-специфики: eBPF-наблюдаемость (Cilium Hubble), метрики SLO/SLI, федерация Prometheus.
