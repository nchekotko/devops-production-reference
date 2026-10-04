# План реализации решения — кейс DevOps (MTS ENGINEER HACK)

> Назначение документа: пошаговый план выполнения ТЗ от подготовки окружения до сдачи архива.
> Все обязательные требования ТЗ покрыты; дополнительные улучшения (для бонусных баллов) помечены как **«Бонус»**.

---

## 0. Цель и итоговый результат

Развернуть с нуля в Kubernetes простое веб-приложение и собрать вокруг него базовую
инфраструктуру публикации, мониторинга и сбора логов, воспроизводимую проверяющими
экспертами на Ubuntu 24.04 по инструкции из публичного Git-репозитория.

**Критерии готовности (Definition of Done):**
1. Приложение развёрнуто в Kubernetes и отвечает на HTTP (`Hello World!`).
2. Доступ к приложению организован через Kubernetes Gateway API (GatewayClass → Gateway → HTTPRoute → Service).
3. Prometheus собирает метрики минимум от одного компонента; target «up», запрос в Prometheus UI возвращает данные.
4. Fluentd (или Filebeat) собирает access/error-логи приложения; после `curl` запись появляется в хранилище логов.
5. Решение работает на Ubuntu 24.04.
6. Развёртывание автоматизировано, идемпотентно, сводится к 1–2 командам.
7. README содержит архитектуру, версии, пошаговую инструкцию и команды проверки.
8. Сдан архив: `Фамилия.zip` → `Ссылка.txt` + `Паспорт.pdf` (≤4 стр., ≤15 МБ).

---

## 1. Выбранный технологический стек (с обоснованием)

| Компонент | Выбор | Версия (зафиксировать) | Обоснование |
|---|---|---|---|
| Kubernetes | **kubeadm** | v1.31.x | Приоритет по ТЗ; вендор-нейтральный; полный контроль над кластером |
| ОС | Ubuntu 24.04 LTS | 24.04 | Требование ТЗ |
| Container runtime | containerd | 1.7.x / 2.0.x | Стандарт для kubeadm; проще CRI-O |
| CNI | **Calico** (резерв — Flannel) | 3.29.x | Стабильный, простая установка одним манифестом |
| Gateway API | **Envoy Gateway** | 1.x | Флагманская open-source реализация Gateway API (CNCF); полная поддержка маршрутов, path/host, TLS, traffic-splitting |
| LoadBalancer IP | **MetalLB** (Layer2) | 0.14.x | Даёт внешний IP сервисам типа LoadBalancer в bare-metal/kubeadm |
| Демо-приложение | **Nginx** + nginx-prometheus-exporter | nginx 1.27.x | Публичный образ; access-логи в stdout; проверяемый ответ |
| Мониторинг | **kube-prometheus-stack** (Prometheus Operator + Prometheus + Grafana + node-exporter + kube-state-metrics) | последняя стабильная | Один Helm-чарт закрывает метрики инфраструктуры + UI; ServiceMonitor/PodMonitor |
| Логирование | **Fluentd** (DaemonSet) → **Loki** → Grafana | fluentd 1.17 / loki 3.x | Fluentd указан в ТЗ; Loki лёгкий и работает в той же Grafana, что и метрики |
| Автоматизация | **Ansible** (подготовка узла) + **Helm** (компоненты) + **Makefile/deploy.sh** | — | Ansible — подготовка ОС/кластера; Helm — компоненты; make — единая точка входа |
| Управление пакетами | Helm | 3.x | Идемпотентный `helm upgrade --install` |

---

## 2. Архитектура решения

```
                    ┌────────────────────────────────────────────┐
 Пользователь ───► │  Envoy Gateway (LoadBalancer, MetalLB IP)   │
  curl/HTTPS       └──────────────┬─────────────────────────────┘
                                  │ Gateway / HTTPRoute (path/host)
                                  ▼
                     ┌────────────────────────────┐
                     │  Nginx Deployment + Service │◄── nginx-exporter (metrics)
                     │  "Hello World!" + access.log │
                     └──────────────┬─────────────┘
                                    │ stdout/файл логов
                                    ▼
        ┌───────────────┐   ┌──────────────────────────┐
        │   Prometheus   │◄──│  Fluentd DaemonSet       │
        │ (node-exporter │   │  (хвост логов контейнеров)│
        │  kube-state-   │   └───────────┬──────────────┘
        │  metrics,      │               ▼
        │  nginx-exporter│        ┌──────────────┐
        └───────┬───────┘        │  Loki (хранение)│
                ▼                └───────┬────────┘
        ┌─────────────────────────────────▼──────────┐
        │            Grafana (метрики + логи)         │
        └────────────────────────────────────────────┘
```

Поток данных:
- **Трафик**: Пользователь → Envoy Gateway (MetalLB IP) → HTTPRoute → Nginx Service → Pod.
- **Метрики**: Prometheus тянет node-exporter, kube-state-metrics, nginx-prometheus-exporter (и, бонусом, Envoy proxy).
- **Логи**: Nginx пишет access/error-логи → Fluentd DaemonSet собирает со всех нод → Loki → Grafana (Logs).

---

## 3. Структура Git-репозитория (целевая)

```
.
├── README.md                        # главная инструкция (архитектура, версии, развёртывание, проверки)
├── Makefile                         # make deploy / make verify / make clean
├── deploy.sh                        # единая точка входа (обёртка над ansible+helm)
├── docs/
│   ├── architecture.md              # детальная архитектура (диаграмма, потоки данных)
│   └── passport.md                  # исходник паспорта (для экспорта в PDF)
├── ansible/
│   ├── inventory/hosts.yml
│   └── playbooks/
│       ├── prepare-node.yml         # containerd, kubeadm, kubelet, kubectl, sysctl, модули
│       └── init-cluster.yml         # kubeadm init + CNI + MetalLB
├── kubernetes/
│   ├── cluster/kubeadm-config.yaml  # конфиг kubeadm (версия, сеть подов)
│   └── base/                        # namespace, RBAC при необходимости
├── apps/nginx/
│   ├── deployment.yaml              # nginx + sidecar nginx-prometheus-exporter
│   ├── service.yaml                 # ClusterIP Service
│   └── configmap.yaml               # index.html "Hello World!" + логи в stdout
├── gateway/
│   ├── gatewayclass.yaml            # GatewayClass (Envoy Gateway)
│   ├── gateway.yaml                 # Gateway (listener :80/:443)
│   └── httproute.yaml               # HTTPRoute → nginx Service (path/host)
├── monitoring/
│   ├── values-kps.yaml              # Helm values kube-prometheus-stack
│   └── servicemonitors/             # ServiceMonitor для nginx-exporter, envoy
├── logging/
│   ├── values-loki.yaml             # Helm values Loki (single binary, filesystem)
│   ├── fluentd-daemonset.yaml       # DaemonSet + ConfigMap (tail → Loki)
│   └── fluentd-values.yaml          # (или chart fluentd)
├── scripts/
│   └── verify.sh                    # сквозная проверка (curl, prometheus query, loki query)
└── .gitignore                       # исключить секреты, *.pem, kubeconfig, архивы
```

---

## 4. Пошаговый план реализации

### Этап 1. Подготовка Kubernetes-окружения (kubeadm, Ubuntu 24.04)

**Задачи:**
1. Ansible-плейбук `prepare-node.yml`:
   - отключение swap, настройка `sysctl` (ip_forward, bridge-nf-call-iptables);
   - установка containerd (репозиторий Docker/containerd.io), конфиг `config.toml` (systemd cgroup);
   - установка `kubeadm`, `kubelet`, `kubectl` (apt-репозиторий pkgs.k8s.io), фиксация версии;
   - включение и запуск сервисов.
2. `init-cluster.yml`:
   - `kubeadm init` с `kubeadm-config.yaml` (podSubnet под Calico, версия v1.31.x);
   - копирование kubeconfig, снятие taint с control-plane (для однноузлового стенда);
   - установка Calico (kubectl apply) и MetalLB (Layer2, адресный пул).
3. Фиксация всех шагов как **идемпотентных** (повторный запуск не ломает кластер).

**Проверка:** `kubectl get nodes` → `Ready`; `kubectl get pods -A` → все `Running`.

**Выход:** работоспособный кластер + все команды зафиксированы в Ansible.

---

### Этап 2. Развёртывание демонстрационного веб-приложения (Nginx)

**Задачи:**
1. ConfigMap: `index.html` с ответом `Hello World!` (однозначно проверяемый).
2. ConfigMap конфигурации nginx: `access_log /dev/stdout;` — логи в stdout (для сбора Fluentd).
3. Deployment: образ `nginx:1.27.x`, 1–2 реплики, probes (readiness/liveness), resources.
4. Service: `ClusterIP` (порт 80).
5. **Бонус**: sidecar `nginx-prometheus-exporter` (`nginx/nginx-prometheus-exporter`) на порту 9113 + `stub_status` в nginx — для HTTP-метрик.

**Проверка:** `kubectl port-forward` + `curl` → `Hello World!`; `kubectl logs` содержит access-запись.

**Выход:** Deployment + Service + ConfigMap, работающие внутри кластера.

---

### Этап 3. Gateway API (Envoy Gateway)

**Задачи:**
1. Установить Envoy Gateway (Helm `gateway-helm/eg` или манифест) + GatewayClass.
2. Ресурсы:
   - `GatewayClass` (controllerName: `gateway.envoyproxy.io/gatewayclass-controller`);
   - `Gateway` (listener на 80; **бонус** — listener на 443 с TLS);
   - `HTTPRoute` → backend `nginx` Service (порт 80).
3. Service Envoy Gateway типа `LoadBalancer` получает IP от MetalLB.
4. **Бонусы** (расширенные возможности Gateway API): маршрутизация по path и hostname, несколько backends, traffic splitting (weighted), TLS-терминация.

**Проверка:** `curl http://<LB-IP>/` → `Hello World!`; `kubectl get gateway,httproute`.

**Выход:** приложение доступно снаружи через Gateway API; команда проверки — в README.

---

### Этап 4. Мониторинг (Prometheus)

**Задачи:**
1. Установить `kube-prometheus-stack` через Helm (Prometheus Operator + Prometheus + Grafana + node-exporter + kube-state-metrics).
2. ServiceMonitor/PodMonitor:
   - node-exporter, kube-state-metrics (метрики инфраструктуры — обязательный минимум);
   - **Бонус**: `ServiceMonitor` для nginx-prometheus-exporter (запросы, коды, latency) и Envoy proxy.
3. Убедиться, что targets в состоянии `UP` (`Prometheus → Status → Targets`).

**Проверка:** Prometheus query, например `up` или `rate(nginx_http_requests_total[5m])`, возвращает данные.

**Выход:** Prometheus собирает метрики; команда/запрос проверки — в README.

---

### Этап 5. Логирование (Fluentd → Loki)

**Задачи:**
1. Установить Loki (Helm `grafana/loki`, single-binary, filesystem storage) + добавить его datasource в Grafana.
2. Развернуть Fluentd как DaemonSet (на каждой ноде) с ConfigMap:
   - tail логов контейнеров (`/var/log/containers/*.log`);
   - парсинг access-логов nginx (regex/JSON);
   - вывод в Loki (плагин `@type loki`).
3. Настроить labels (namespace, pod, app) для поиска.

**Проверка:** `curl` к приложению → запись появляется в Loki (Grafana → Explore → Logs / Loki API).

**Выход:** access/error-логи собираются и доступны; команда проверки — в README.

---

### Этап 6. Автоматизация развёртывания и идемпотентность

**Задачи:**
1. `Makefile` / `deploy.sh` — единая точка входа:
   - `make infra` — ansible подготовка + kubeadm init;
   - `make deploy` — установка всех компонентов (Helm/kubectl apply) в правильном порядке;
   - `make verify` — сквозная проверка (curl, Prometheus, Loki);
   - `make clean` (опционально).
2. Порядок развёртывания: CNI → MetalLB → Envoy Gateway → app → monitoring → logging.
3. Идемпотентность: везде `helm upgrade --install` и `kubectl apply`; повторный запуск не создаёт дублей и не ломает состояние.
4. Секреты (если появятся) — только через переменные окружения/Secret/шаблон; никаких реальных секретов в репозитории.

**Проверка:** дважды подряд `make deploy` → состояние кластера корректное.

**Выход:** развёртывание сводится к 1–2 командам; воспроизводимо.

---

### Этап 7. Документация (README + паспорт)

**README.md (обязательные разделы по ТЗ):**
- краткое описание и архитектура;
- список технологий и версий, версия Kubernetes, реализация Gateway API;
- требования к среде (Ubuntu 24.04, ресурсы);
- пошаговая инструкция развёртывания + команда запуска (`make deploy`);
- проверка доступности приложения (curl через Gateway API);
- проверка мониторинга (Prometheus query);
- проверка логирования (запись в Loki);
- описание дополнительных возможностей;
- известные ограничения.

**Паспорт решения (≤4 стр., PDF):**
- Стр. 1 — архитектура и состав (версии, стек, схема);
- Стр. 2 — реализованный функционал (каждый обязательный пункт: как реализован, обоснование, как проверить) + бонусы;
- Стр. 3 — ревью и масштабирование (сильная сторона, сложное решение, развитие с учётом телеком-специфики).

---

### Этап 8. Сборка архива для сдачи

**Задачи:**
1. Загрузить всё в публичный Git-репозиторий (main), проверить `git clone` без авторизации.
2. `Ссылка.txt` — только URL репозитория.
3. `Паспорт.pdf` (или .doc/.docx) — ≤4 стр., ≤15 МБ.
4. Архив `Фамилия.zip` (≤18 МБ) с двумя файлами.
5. Проверить, что в репозитории нет секретов (пароли, токены, ключи).

**Выход:** готовый архив для загрузки.

---

## 5. Дополнительные улучшения (бонусные баллы) — реализуем по возможности

| Улучшение | Что даёт | Сложность |
|---|---|---|
| Расширенные возможности Gateway API: path/host-маршрутизация, несколько backend, traffic splitting, TLS | Пункт «Дополнительные возможности Gateway API» | Средняя |
| HTTP-метрики приложения (nginx-exporter: запросы, коды, latency) | Пункт «расширенный мониторинг» | Низкая |
| CPU/RAM метрики (node-exporter + kube-state-metrics) | Расширенный мониторинг | Низкая (из коробки) |
| Централизованный поиск логов (Loki + Grafana) | Расширенное логирование | Средняя |
| Dashboard Grafana (готовый JSON) для метрик и логов | Дополнительные dashboards | Низкая |
| CI/CD (GitHub Actions): проверка манифестов (kubeconform/lint), smoke-тест | Пункт CI/CD | Средняя |
| Практики безопасности: RBAC, network policies, limits, отсутствие секретов | Надёжность/безопасность | Низкая |

---

## 6. Чек-лист соответствия критериям оценки (100 баллов)

- [ ] **Работоспособность Kubernetes + Gateway API (30)** — кластер Ready, приложение отвечает, маршрутизация через Gateway API работает, архитектура логична, используется kubeadm.
- [ ] **Воспроизводимость и автоматизация (25)** — развёртывание по инструкции, высокая автоматизация, минимум ручных действий, повторяемость, идемпотентность, управление зависимостями.
- [ ] **Мониторинг и логирование (20)** — Prometheus реально собирает метрики, Fluentd реально собирает логи, качественный observability-подход.
- [ ] **Качество реализации (15)** — структура конфигураций, качество скриптов, разумные решения, базовые практики безопасности, отсутствие секретов.
- [ ] **Документация и доп. возможности (10)** — качественный README, понятная архитектура, простота воспроизведения, ограничения, CI/CD, расширенный Gateway API и др.

---

## 7. Риски и ограничения

| Риск | Митигация |
|---|---|
| Выбор версий компонентов несовместим с Ubuntu 24.04 | Зафиксировать проверенные версии, тестировать именно на 24.04 |
| Envoy Gateway требует внешний IP | MetalLB (Layer2) в bare-metal/kubeadm |
| Повторный `kubeadm init` ломает кластер | Сделать Ansible идемпотентным (проверка `kubeadm`-состояния перед init) |
| Loki/fluentd сложны в настройке | Использовать официальные Helm-чарты и проверенные ConfigMap; логи приложения выводить в stdout |
| Размер архива > 18 МБ | Не коммитить бинарники/логи; только конфигурации и код |
| Секреты в репозитории | `.gitignore` + проверка перед коммитом; секреты только через env/Secret |

---

## 8. Порядок выполнения (краткий роадмап)

1. Развернуть kubeadm-кластер на Ubuntu 24.04 (локальная VM или облачная VM) — Этап 1.
2. Nginx-приложение + Service — Этап 2.
3. Envoy Gateway + MetalLB + GatewayClass/Gateway/HTTPRoute — Этап 3.
4. kube-prometheus-stack + ServiceMonitor — Этап 4.
5. Fluentd DaemonSet + Loki + Grafana — Этап 5.
6. Обернуть всё в `deploy.sh`/Makefile, проверить идемпотентность — Этап 6.
7. README + паспорт — Этап 7.
8. Загрузить репозиторий, собрать архив, проверить отсутствие секретов — Этап 8.

---

## 9. Декомпозиция работ по пакетам (оптимизация издержек на токены)

**Принцип минимизации издержек:** каждый пакет — это автономный вертикальный срез,
который можно отдать отдельному агенту/модели с коротким самодостаточным заданием.
Агент получает **только** компактный контекст-бриф + спецификацию своего пакета,
а НЕ полный текст ТЗ и не весь репозиторий. Это экономит входные токены;
фиксированные версии/имена/порты исключают переделку (экономия выходных токенов);
встроенная команда проверки убирает лишние циклы «проверь-исправь».

### 9.1. Единый контекст-бриф (выдаётся каждому агенту, ~15 строк)

```
Проект: MTS ENGINEER HACK — DevOps-кейс. Репозиторий в корне проекта.
Стек (версии финальные): Kubernetes v1.31.x (kubeadm), Ubuntu 24.04, containerd,
CNI Calico 3.29, MetalLB 0.14 (Layer2), Gateway API = Envoy Gateway 1.x,
приложение nginx:1.27, мониторинг kube-prometheus-stack (Prometheus Operator),
логирование Fluentd (DaemonSet) -> Loki (chart grafana/loki) -> Grafana.
Пространства имён: default (приложение + gateway), monitoring (Prometheus),
logging (Loki + Fluentd).
Приложение: ответ "Hello World!", access-лог в stdout, порт 80,
sidecar nginx-prometheus-exporter:9113, метрики через /stub_status.
Gateway API: GatewayClass controllerName=gateway.envoyproxy.io/gatewayclass-controller,
Gateway listener :80, HTTPRoute pathPrefix=/. Метки сервиса приложения: app=nginx.
Prometheus: ServiceMonitor с меткой release=kps (совместимо с chart).
Fluentd: tail /var/log/containers/*.log, лейблы namespace/pod/app, output @type loki.
Идемпотентность: только `kubectl apply` и `helm upgrade --install`; повторный запуск безопасен.
Секреты: не коммитить; только env/Secret. Все версии/имена фиксировать в README.
```

### 9.2. Пакеты работ (WP) и их порядок

| Пакет | Содержание | Читает (вход) | Пишет (выход) | Класс токенов | Зависит от |
|---|---|---|---|---|---|
| **WP0** скелет | Makefile, deploy.sh, .gitignore, структура каталогов, scripts/verify.sh | бриф | ~6 файлов | XS | — |
| **WP1** кластер | ansible prepare-node + init-cluster, kubeadm-config, Calico, MetalLB | бриф | ansible/, kubernetes/cluster/ | M | — |
| **WP2** приложение | nginx Deployment+Service+ConfigMap, exporter sidecar | бриф | apps/nginx/ | S | — |
| **WP3** gateway | Envoy Gateway + GatewayClass/Gateway/HTTPRoute (+бонус TLS/split) | бриф + имя Service из WP2 | gateway/ | M | WP2 |
| **WP4** мониторинг | kube-prometheus-stack values + ServiceMonitor (nginx-exporter, node) | бриф + метки exporter из WP2 | monitoring/ | S | WP2 |
| **WP5** логирование | Loki values + Fluentd DaemonSet ConfigMap | бриф + путь логов из WP2 | logging/ | M | WP2 |
| **WP6** README | полный README.md по обязательным разделам ТЗ | бриф + выходы WP1–5 | README.md | L | WP1–5 |
| **WP7** паспорт | docs/passport.md + экспорт в PDF (≤4 стр.) | README | docs/ + Паспорт.pdf | M | WP6 |
| **WP8** сдача | Ссылка.txt, сборка архива, проверка на секреты | README + PDF | архив | XS | WP6, WP7 |

### 9.3. Схема параллелизации (экономия времени и токенов)

```
WP0 ──► WP1 ────────────────┐
        WP2 ────────────────┼──► WP6 ──► WP7 ──► WP8
             ├──► WP3 ───────┤
             ├──► WP4 ───────┤
             └──► WP5 ───────┘
```

- **Волна 1 (параллельно):** WP0, WP1, WP2 — не зависят друг от друга.
- **Волна 2 (параллельно):** WP3, WP4, WP5 — зависят только от WP2 (имя Service/метки/путь логов).
- **Волна 3:** WP6 (агрегирует всё) → WP7 → WP8 последовательно.

### 9.4. Правила экономии токенов при исполнении

1. Агенту передаётся **бриф + спецификация одного пакета**, а не всё ТЗ и не весь репозиторий.
2. Пакеты атомарны: агент создаёт файлы только своего каталога и не правит чужие.
3. В каждой спецификации заранее указаны имена файлов, версии и команда проверки —
   это убирает лишние уточняющие циклы.
4. Пакеты S/XS исполняются одной моделью за один проход; M/L — при необходимости
   разбиваются на подшаги внутри того же пакета (без расширения входного контекста).
5. WP6 (README) собирается из уже готовых фактов (версии/команды из WP1–5), поэтому
   агент получает не сырые манифесты целиком, а сводку «файл → что делает → как проверить».
