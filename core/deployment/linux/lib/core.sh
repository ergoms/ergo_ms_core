#!/usr/bin/env bash
# Core utilities for ErgoMS deployment
# Базовые утилиты для развертывания ErgoMS

SCRIPT_DIR_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=console_tags.sh
source "$SCRIPT_DIR_CORE/console_tags.sh"
# shellcheck source=nginx_env.sh
source "$SCRIPT_DIR_CORE/nginx_env.sh"

# Константы (базовые службы без воркеров)
BASE_SERVICES="ergo-api-dev ergo-client-dev ergo-celery-beat"
CLI_NAME="ergoms"

# Глобальная переменная для кэширования списка служб
CACHED_UNITS_LIST=""

require_root_or_sudo() {
  if [[ $(id -u) -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "Скрипт требует root или sudo. Установите sudo или запустите от root." >&2
      exit 1
    fi
  fi
}

write_ergoms_message() {
  local key="$1"
  local color="${2:-white}"
  local use_stderr="${3:-}"
  local root="${ERGO_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(detect_project_root 2>/dev/null || echo '')"
  fi
  local python="$root/virtual_env/python/bin/python"
  local script="$root/core/deployment/scripts/ergoms_console.py"
  if [[ -f "$python" && -f "$script" ]]; then
    local args=("$script" --key "$key" --color "$color")
    [[ -n "$use_stderr" ]] && args+=(--stderr)
    shift 3 || true
    while [[ $# -gt 0 ]]; do
      args+=(--param "$1")
      shift
    done
    "$python" "${args[@]}"
    return
  fi
  echo "[$key]" >&2
}

write_ergoms_text() {
  local text="$1"
  local color="${2:-white}"
  local use_stderr="${3:-}"
  local root="${ERGO_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(detect_project_root 2>/dev/null || echo '')"
  fi
  local python="$root/virtual_env/python/bin/python"
  local script="$root/core/deployment/scripts/ergoms_console.py"
  if [[ -f "$python" && -f "$script" ]]; then
    local args=("$script" --text "$text" --color "$color")
    [[ -n "$use_stderr" ]] && args+=(--stderr)
    "$python" "${args[@]}"
    return
  fi
  if [[ -n "$use_stderr" ]]; then
    echo "$text" >&2
  else
    echo "$text"
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

# Парсинг YAML файла для получения имён воркеров
# Используем простой парсер без внешних зависимостей
parse_workers_from_yaml() {
  local yaml_file="$1"
  local workers=()
  
  if [[ ! -f "$yaml_file" ]]; then
    echo ""
    return
  fi
  
  local in_workers=false
  local indent_level=0
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Пропускаем комментарии и пустые строки
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    
    # Проверяем начало секции workers:
    if [[ "$line" =~ ^workers:[[:space:]]*$ ]]; then
      in_workers=true
      continue
    fi
    
    # Если мы в секции workers
    if [[ "$in_workers" == true ]]; then
      # Проверяем, не началась ли новая секция верхнего уровня (defaults:, etc)
      if [[ "$line" =~ ^[a-z_]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
        in_workers=false
        continue
      fi
      
      # Ищем имена воркеров (строки с отступом в 2 пробела и двоеточием)
      if [[ "$line" =~ ^[[:space:]]{2}([a-z_]+):[[:space:]]*$ ]]; then
        local worker_name="${BASH_REMATCH[1]}"
        workers+=("$worker_name")
      fi
    fi
  done < "$yaml_file"
  
  echo "${workers[*]}"
}

# Получение списка воркеров из celery_workers.yaml
get_celery_workers() {
  local project_root="${1:-}"
  
  if [[ -z "$project_root" ]]; then
    project_root="$(detect_project_root 2>/dev/null || echo '')"
  fi
  
  if [[ -z "$project_root" ]]; then
    echo ""
    return
  fi
  
  local workers_config="$project_root/celery_workers.yaml"
  parse_workers_from_yaml "$workers_config"
}

# Генерация списка служб на основе конфигурации воркеров
generate_units_list() {
  local project_root="${1:-}"
  local units="ergo-api-dev.service ergo-media-api.service ergo-celery-beat.service"

  if is_nginx_enabled "$project_root"; then
    units="$units ergo_ms_nginx.service"
  else
    units="ergo-api-dev.service ergo-client-dev.service ergo-media-api.service ergo-celery-beat.service"
  fi
  
  local workers
  workers="$(get_celery_workers "$project_root")"
  
  if [[ -n "$workers" ]]; then
    # Добавляем службы для каждого воркера из конфига
    for worker in $workers; do
      units="$units ergo-celery-worker-${worker}.service"
    done
  else
    # Если конфиг не найден, используем один общий воркер
    units="$units ergo-celery-worker.service"
  fi
  
  echo "$units"
}

# Получение списка имён воркеров (без .service)
get_worker_service_names() {
  local project_root="${1:-}"
  local services=""
  
  local workers
  workers="$(get_celery_workers "$project_root")"
  
  if [[ -n "$workers" ]]; then
    for worker in $workers; do
      services="$services ergo-celery-worker-${worker}"
    done
  else
    services="ergo-celery-worker"
  fi
  
  echo "$services"
}

units_list() {
  local project_root="${1:-}"
  
  # Кэшируем результат для ускорения
  if [[ -n "$CACHED_UNITS_LIST" ]]; then
    echo "$CACHED_UNITS_LIST"
    return
  fi
  
  CACHED_UNITS_LIST="$(generate_units_list "$project_root")"
  echo "$CACHED_UNITS_LIST"
}

# Сброс кэша списка служб (если нужно перечитать конфиг)
reset_units_cache() {
  CACHED_UNITS_LIST=""
}

cli_name() {
  echo "$CLI_NAME"
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
export -f write_ergoms_message
export -f write_ergoms_text
export -f detect_project_root
export -f parse_workers_from_yaml
export -f get_celery_workers
export -f generate_units_list
export -f get_worker_service_names
export -f units_list
export -f reset_units_cache
export -f cli_name
export -f systemctl_do
export -f daemon_reload
