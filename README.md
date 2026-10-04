# DevOps-решение: веб-приложение в Kubernetes с Gateway API, мониторингом и логированием

Решение кейса **MTS ENGINEER HACK** (DevOps): развёртывание простого веб-приложения в
Kubernetes с организацией доступа через Kubernetes Gateway API, сбором метрик Prometheus
и сбором логов Fluentd. Полностью воспроизводимо на **Ubuntu 24.04** и сводится к
единственной команде `make deploy`.

---

## 1. Краткое описание

- Кластер **Kubernetes v1.31.6**, развёрнутый через **kubeadm** (containerd + Calico + MetalLB).
- Демо-приложение **Nginx**, отвечающее `Hello World!` на `GET /`, с access/error-логами в stdout/stderr.
- Публикация через **Kubernetes Gateway API** — реализация **Envoy Gateway** (GatewayClass → Gateway → HTTPRoute).
- Мониторинг **Prometheus** (kube-prometheus-stack): метрики узлов, состояния кластера и HTTP-метрики приложения.
- Логирование **Fluentd** (DaemonSet) → **Loki**, просмотр в **Grafana**.
- Автоматизация **Ansible + Helm + Makefile**, идемпотентный повторный запуск.

---

## 2. Архитектура

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
                                         │ stdout/stderr
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

---

## 3. Технологии и версии

| Компонент | Технология | Версия |
|---|---|---|
| Kubernetes | kubeadm | v1.31.6 |
| ОС | Ubuntu | 24.04 LTS |
| Container runtime | containerd | 1.7.24 |
| CNI | Calico | 3.29.3 |
| LoadBalancer | MetalLB (Layer2) | 0.14.9 |
| Gateway API | Envoy Gateway | v1.2.1 |
| Приложение | Nginx (+ nginx-prometheus-exporter) | 1.27.3 / 1.4.0 |
| Мониторинг | kube-prometheus-stack (Prometheus + Grafana + node-exporter + kube-state-metrics) | последняя стабильная |
| Логирование | Fluentd → Loki | fluentd 1.17 / loki 6.x |
| Автоматизация | Ansible, Helm, Make | ansible-core, helm 3.x |

---

## 4. Требования к среде

- Один сервер/ВМ с **Ubuntu 24.04 LTS** (root или sudo-доступ), минимум 2 vCPU / 4 ГБ RAM / 20 ГБ диск.
- Доступ к сети Интернет (для apt, Helm-чартов и container images).
- Установленные: `git`, `curl`. Остальное (containerd, kubeadm, Helm, ansible) ставится автоматически.
- Свободный IP-диапазон в локальной подсети для MetalLB (см. `LB_IP_RANGE` ниже).

---

## 5. Пошаговая инструкция по развёртыванию

```bash
# Все шаги (установка пакетов, kubeadm, сборка/импорт образа Fluentd) требуют прав root.
sudo -i
git clone <URL_репозитория>
cd <repo>
make deploy
```

`make deploy` последовательно выполняет (все шаги идемпотентны):

| Шаг | Команда | Что делает |
|---|---|---|
| 1 | `make cluster` | `scripts/01-cluster.sh` — подготовка узла (containerd, kubeadm/kubelet/kubectl, Helm) и создание кластера (kubeadm init, Calico, MetalLB) |
| 2 | `make app` | `scripts/02-app.sh` — развёртывание Nginx-приложения (Deployment + Service + ConfigMap) |
| 3 | `make gateway` | `scripts/03-gateway.sh` — установка Envoy Gateway + GatewayClass/Gateway/HTTPRoute |
| 4 | `make monitoring` | `scripts/04-monitoring.sh` — установка kube-prometheus-stack + ServiceMonitor |
| 5 | `make logging` | `scripts/05-logging.sh` — установка Loki + Fluentd DaemonSet |

При необходимости шаги можно выполнять по отдельности.

### Параметры (переменные окружения)

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `LB_IP_RANGE` | `192.168.1.240-192.168.1.250` | Диапазон адресов MetalLB — должен быть в подсети сети узла |

Пример: `LB_IP_RANGE=10.0.0.200-10.0.0.210 make deploy`

---

## 6. Проверка доступности приложения (Gateway API)

Envoy Gateway создаёт Service типа LoadBalancer; MetalLB назначает ему внешний IP.

```bash
kubectl get svc -n default   # найти EXTERNAL-IP сервиса Envoy Gateway
curl http://<LB-IP>/
# ожидаемый ответ: Hello World!
```

Или одной командой:

```bash
IP=$(kubectl get svc -n default -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' | awk '{print $1}')
curl -fsS "http://$IP/"
```

Проверка ресурсов Gateway API:

```bash
kubectl get gatewayclass,gw,gwroute -A
kubectl describe httproute nginx -n default
```

---

## 7. Проверка мониторинга (Prometheus)

```bash
kubectl port-forward -n monitoring svc/kps-prometheus 9090:9090
```

Затем откройте http://localhost:9090 и выполните запросы (или через API):

```bash
# список целей и их состояние
curl -s 'http://localhost:9090/api/v1/query?query=up'

# HTTP-метрики приложения
curl -s 'http://localhost:9090/api/v1/query?query=nginx_connections_active'
curl -s 'http://localhost:9090/api/v1/query?query=rate(nginx_http_requests_total[5m])'
```

Собираемые метрики:
- **node-exporter** — CPU/память/диск/сеть узлов;
- **kube-state-metrics** — состояние объектов Kubernetes (поды, деплойменты, узлы);
- **nginx-exporter** (sidecar) — соединения и HTTP-запросы приложения.

---

## 8. Проверка логирования (Fluentd → Loki)

```bash
# сделать запрос к приложению, чтобы появилась запись в access-логе
curl http://<LB-IP>/

# пробросить Loki
kubectl port-forward -n logging svc/loki 3100:3100

# проверить появление записи
curl -G 'http://localhost:3100/loki/api/v1/query_range' \
     --data-urlencode 'query={container_name="nginx"}'
```

Логи собираются со всех нод DaemonSet'ом Fluentd (access- и error-логи приложения из
stdout/stderr контейнеров) и поступают в Loki. Просмотр в Grafana (Explore → Loki):

```bash
kubectl port-forward -n monitoring svc/kps-grafana 3000:80
# http://localhost:3000 , логин/пароль по умолчанию: admin / prom-operator
```

---

## 9. Сквозная проверка

```bash
make verify
```

Скрипт выводит состояние узлов, подов, ресурсов Gateway API и готовые команды проверки.

---

## 10. Дополнительные возможности

- **Расширенные возможности Gateway API**: маршрутизация по path и hostname (несколько правил в HTTPRoute).
- **HTTP-метрики приложения**: nginx-prometheus-exporter (запросы, соединения, коды ответов, latency).
- **Метрики CPU/RAM**: node-exporter и kube-state-metrics.
- **Централизованный поиск логов**: Loki + единый UI Grafana (метрики и логи).
- **Практики надёжности и безопасности**: readiness/liveness-пробы, resources requests/limits, RBAC для Fluentd, отсутствие секретов в репозитории.

---

## 11. Структура репозитория

```
.
├── Makefile                     # make deploy / make verify / отдельные шаги
├── scripts/
│   ├── 01-cluster.sh            # подготовка узла + kubeadm-кластер
│   ├── 02-app.sh                # Nginx-приложение
│   ├── 03-gateway.sh            # Envoy Gateway
│   ├── 04-monitoring.sh         # Prometheus
│   ├── 05-logging.sh            # Loki + Fluentd
│   └── verify.sh                # сквозная проверка
├── ansible/playbooks/           # prepare-node.yml, init-cluster.yml
├── kubernetes/cluster/          # kubeadm-config.yaml
├── apps/nginx/                  # deployment/service/configmap
├── gateway/                     # gatewayclass/gateway/httproute
├── monitoring/                  # values-kps.yaml, nginx-servicemonitor.yaml
├── logging/                     # values-loki.yaml, fluentd DaemonSet + Dockerfile
└── docs/passport.md             # исходник паспорта решения
```

---

## 12. Известные ограничения

- Кластер — **один узел** (control-plane + workload). Для продакшена требуется добавить worker-узлы и настроить HA control-plane.
- MetalLB работает в режиме **Layer2** (адрес берётся из локальной подсети узла); BGP не используется.
- Образ Fluentd (с плагином Loki) собирается на узле из `logging/fluentd/Dockerfile` и импортируется в containerd — решение рассчитано на однноузловой кластер.
- TLS-терминация на Gateway не включена (требует сертификатов/домена) — доступен listener HTTP :80.
- Пароль Grafana — значение по умолчанию (`admin/prom-operator`); для реальной эксплуатации сменить через values.
- Хранилище Loki — ephemeral (persistence отключена, т.к. на bare-metal kubeadm нет default StorageClass). Для персистентности добавьте StorageClass (например, local-path-provisioner) и включите `singleBinary.persistence`.
- Развёртывание выполняется от root (установка пакетов, kubeadm, сборка и импорт образа Fluentd через docker/ctr).
