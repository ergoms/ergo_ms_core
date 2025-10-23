#!/usr/bin/env bash
# Core utilities for ErgoMS deployment
# Базовые утилиты для развертывания ErgoMS

# Константы
UNITS_LIST="ergo-api-dev.service ergo-client-dev.service ergo-celery-worker.service ergo-celery-beat.service"
CLI_NAME="ergoms"

require_root_or_sudo() {
  if [[ $(id -u) -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "This script requires root or sudo. Install sudo or run as root." >&2
      exit 1
    fi
  fi
}

detect_project_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
  # Go up two levels from lib directory
  local deployment_dir
  deployment_dir="$(cd "$script_dir/.." && pwd)"
  
  # Prefer git root if available
  if command -v git >/dev/null 2>&1; then
    if git -C "$deployment_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
      git -C "$deployment_dir" rev-parse --show-toplevel
      return 0
    fi
  fi

  # Fallback: assume deployment directory is inside project root
  echo "$(cd "$deployment_dir/../.." && pwd)"
}

units_list() {
  echo "$UNITS_LIST"
}

cli_name() {
  echo "$CLI_NAME"
}

cli_path() {
  echo "/usr/local/bin/$(cli_name)"
}

systemctl_do() {
  if [[ $(id -u) -eq 0 ]]; then
    systemctl "$@"
  else
    sudo systemctl "$@"
  fi
}

daemon_reload() {
  if [[ $(id -u) -eq 0 ]]; then
    systemctl daemon-reload
  else
    sudo systemctl daemon-reload
  fi
}

export -f require_root_or_sudo
export -f detect_project_root
export -f units_list
export -f cli_name
export -f cli_path
export -f systemctl_do
export -f daemon_reload

