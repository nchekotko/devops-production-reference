FROM fluent/fluentd-kubernetes-daemonset:v1.17.2-debian-1
# Плагин Loki не входит в базовый образ — доставляем gem. Остаёмся под root,
# т.к. DaemonSet задаёт FLUENT_UID=0 (нужен root для чтения host-логов).
USER root
RUN fluent-gem install fluent-plugin-grafana-loki --no-document
