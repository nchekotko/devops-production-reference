#!/usr/bin/env bash
# =============================================================================
# Оркестратор: подготовка узла + создание кластера Kubernetes v1.31.6.
# Запуск на самой ноде (Ubuntu 24.04) от root:
#     sudo bash scripts/01-cluster.sh
# Идемпотентен: повторный запуск безопасен.
# =============================================================================
set -euo pipefail

# Корень репозитория (родитель каталога scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# kubeadm и установка пакетов требуют привилегий root.
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: запустите от root: sudo bash scripts/01-cluster.sh" >&2
  exit 1
fi

echo "==> [1/3] Проверка/установка Ansible"
if ! command -v ansible-playbook >/dev/null 2>&1; then
  apt-get update
  # python3-apt нужен модулям ansible (apt/apt_repository).
  DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-core python3-apt
fi
ansible-playbook --version

echo "==> [2/3] Подготовка узла (ansible/playbooks/prepare-node.yml)"
ansible-playbook ansible/playbooks/prepare-node.yml

echo "==> [3/3] Инициализация кластера (ansible/playbooks/init-cluster.yml)"
ansible-playbook ansible/playbooks/init-cluster.yml

echo "==> Готово. Проверка кластера: kubectl get nodes"
