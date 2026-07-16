#!/usr/bin/env bash
# Service management functions
# Функции управления службами

# Глобальная переменная для хранения корня проекта в контексте служб
SERVICE_PROJECT_ROOT=""

# Установка корня проекта для операций со службами
set_service_project_root() {
  SERVICE_PROJECT_ROOT="$1"
  # Сбрасываем кэш списка служб при изменении корня
  reset_units_cache
}

start_all() {
  local root="${SERVICE_PROJECT_ROOT:-}"
  local u
  for u in $(units_list "$root"); do systemctl_do start "$u"; done
}

# Собирает PID текущего процесса и всех предков (чтобы не завершить shell, запустивший ergoms stop).
_kill_ergo_skip_pids_ancestor_chain() {
  local p=$$ n=0 max=64
  while [[ "$p" -gt 1 && "$n" -lt "$max" ]]; do
    printf '%s\n' "$p"
    p=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null || echo 1)
    [[ -z "$p" || "$p" == 0 ]] && break
    ((n++)) || true
  done
}

# Завершает оставшиеся после systemctl пользовательские процессы этого репозитория (Daphne, Celery, Vite,
# фоновые ergoms/npm и т.д.) по наличию абсолютного пути корня или virtual_env в cmdline.
kill_ergo_project_session_processes() {
  local root="${1:-${SERVICE_PROJECT_ROOT:-}}"
  [[ -n "$root" ]] || return 0
  [[ -d /proc ]] || return 0
  if command -v readlink >/dev/null 2>&1; then
    root="$(readlink -f "$root" 2>/dev/null || echo "$root")"
  fi
  local venv_mark="${root}/virtual_env"
  local proc pid cmd round
  local -A skip=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && skip["$pid"]=1
  done < <(_kill_ergo_skip_pids_ancestor_chain)

  _cmdline_matches_project() {
    local c="$1"
    [[ -n "$c" ]] || return 1
    [[ "$c" == *"$root"* ]] && return 0
    [[ "$c" == *"$venv_mark"* ]] && return 0
    return 1
  }

  for round in 1 2; do
    for proc in /proc/[0-9]*; do
      [[ -r "$proc/cmdline" ]] || continue
      pid="${proc##/proc/}"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      [[ -v "skip[$pid]" ]] && continue
      cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
      _cmdline_matches_project "$cmd" || continue
      if [[ "$round" -eq 1 ]]; then
        kill -TERM "$pid" 2>/dev/null || true
      else
        kill -0 "$pid" 2>/dev/null || continue
        cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
        _cmdline_matches_project "$cmd" || continue
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
    [[ "$round" -eq 1 ]] && sleep 0.8
  done
}

stop_all() {
  local root="${SERVICE_PROJECT_ROOT:-}"
  local u
  for u in $(units_list "$root"); do systemctl_do stop "$u" || true; done
  # Иначе kill_ergo_project_session_processes рвёт node/vite — npm печатает ERR на «упавший» lifecycle.
  if [[ -n "$root" && -d "$root" ]] && command -v ergoms >/dev/null 2>&1; then
    ( cd "$root" && ergoms npm run stop-dev ) || true
  fi
  kill_ergo_project_session_processes "$root"
}

restart_all() {
  local root="${SERVICE_PROJECT_ROOT:-}"
  local u
  for u in $(units_list "$root"); do systemctl_do restart "$u"; done
}

status_all() {
  local root="${SERVICE_PROJECT_ROOT:-}"
  local u
  for u in $(units_list "$root"); do systemctl_do status "$u" | cat; done
}

show_celery_tasks_logs() {
  local module_name="${1:-}"
  local lines="${2:-500}"
  local root="${SERVICE_PROJECT_ROOT:-}"

  if [[ -z "$root" ]]; then
    root="$(detect_project_root 2>/dev/null || pwd)"
  fi

  # shellcheck source=lib/logs_paths.sh
  source "$(dirname "${BASH_SOURCE[0]}")/logs_paths.sh"

  local log_file
  log_file="$(resolve_ergo_logs_dir "$root")/celery_tasks.log"
  if [[ ! -f "$log_file" ]]; then
    echo "[ERROR] Лог задач Celery не найден: $log_file" >&2
    return 1
  fi

  echo "-> Последние $lines строк celery_tasks.log..."
  echo "   $log_file"
  if [[ -n "$module_name" ]]; then
    local pattern="celery\\.module\\.${module_name}"
    echo "   Фильтр: $pattern"
    echo ""
    grep -E "$pattern" "$log_file" 2>/dev/null | tail -n "$lines" || true
    tail -n 0 -F "$log_file" | grep --line-buffered -E "$pattern" | cat
    return 0
  fi

  echo ""
  tail -n "$lines" -F "$log_file" | cat
}

show_celery_beat_logs() {
  local module_name="${1:-}"
  local lines="${2:-500}"
  local root="${SERVICE_PROJECT_ROOT:-}"

  if [[ -z "$root" ]]; then
    root="$(detect_project_root 2>/dev/null || pwd)"
  fi

  # shellcheck source=lib/logs_paths.sh
  source "$(dirname "${BASH_SOURCE[0]}")/logs_paths.sh"

  local log_file
  log_file="$(resolve_ergo_logs_dir "$root")/celery_beat.log"
  if [[ ! -f "$log_file" ]]; then
    echo "[ERROR] Лог Celery beat не найден: $log_file" >&2
    return 1
  fi

  echo "-> Последние $lines строк celery_beat.log..."
  echo "   $log_file"
  if [[ -n "$module_name" ]]; then
    local pattern="celery\\.beat\\.module\\.${module_name}"
    echo "   Фильтр: $pattern"
    echo ""
    grep -E "$pattern" "$log_file" 2>/dev/null | tail -n "$lines" || true
    tail -n 0 -F "$log_file" | grep --line-buffered -E "$pattern" | cat
    return 0
  fi

  echo ""
  tail -n "$lines" -F "$log_file" | cat
}

show_service_logs() {
  local service_name="$1"
  local lines="${2:-500}"
  local root="${SERVICE_PROJECT_ROOT:-}"

  if [[ -z "$root" ]]; then
    root="$(detect_project_root 2>/dev/null || pwd)"
  fi

  # shellcheck source=lib/logs_paths.sh
  source "$(dirname "${BASH_SOURCE[0]}")/logs_paths.sh"

  if [[ "$service_name" == "ergo_ms_nginx" || "$service_name" == "ergo_ms_nginx.service" ]]; then
    local files=()
    while IFS= read -r file; do
      [[ -n "$file" && -f "$file" ]] && files+=("$file")
    done < <(resolve_service_log_files "ergo_ms_nginx" "$root" 2>/dev/null || true)
    if [[ ${#files[@]} -eq 0 ]]; then
      echo "[ERROR] Файлы логов Nginx не найдены в $(resolve_ergo_logs_dir "$root")" >&2
      echo "Выполните ergoms install-nginx или ergoms reload-nginx." >&2
      return 1
    fi
    echo "-> Последние $lines строк логов nginx..."
    echo ""
    tail -n "$lines" -F "${files[@]}" | cat
    return 0
  fi

  if [[ "$service_name" == "ergo-redis" || "$service_name" == "ergo-redis.service" || "$service_name" == "ergo_ms_redis" ]]; then
    service_name="ergo-redis"
  fi

  local -a log_files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && log_files+=("$file")
  done < <(resolve_service_log_files "$service_name" "$root" 2>/dev/null || true)

  if [[ ${#log_files[@]} -eq 0 ]]; then
    echo "[ERROR] Файлы логов для службы не найдены: $service_name" >&2
    echo "Ожидается в: $(resolve_ergo_logs_dir "$root")" >&2
    return 1
  fi

  echo "-> Последние $lines строк логов $service_name..."
  for file in "${log_files[@]}"; do
    echo "   $file"
  done
  if [[ "$service_name" == ergo-celery-worker* ]]; then
    echo "   Логи задач модулей: $(resolve_ergo_logs_dir "$root")/celery_tasks.log"
    echo "   Фильтр: ergoms logs celery-tasks [module] [lines]"
  fi
  if [[ "$service_name" == "ergo-celery-beat" || "$service_name" == "ergo-celery-beat.service" ]]; then
    echo "   Логи beat модулей: $(resolve_ergo_logs_dir "$root")/celery_beat.log"
    echo "   Фильтр: ergoms logs celery-beat [module] [lines]"
  fi
  echo ""
  tail -n "$lines" -F "${log_files[@]}" | cat
}

uninstall_all() {
  local purge="$1"
  local root="${SERVICE_PROJECT_ROOT:-}"
  
  stop_all || true
  local u
  for u in $(units_list "$root"); do systemctl_do disable "$u" || true; done
  for u in $(units_list "$root"); do
    if [[ -f "/etc/systemd/system/$u" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/systemd/system/$u"
      else
        sudo rm -f "/etc/systemd/system/$u"
      fi
      echo "Удалён /etc/systemd/system/$u"
    fi
  done
  
  # Также удаляем старые службы воркеров (без имени) для обратной совместимости
  if [[ -f "/etc/systemd/system/ergo-celery-worker.service" ]]; then
    systemctl_do disable "ergo-celery-worker.service" || true
    if [[ $(id -u) -eq 0 ]]; then
      rm -f "/etc/systemd/system/ergo-celery-worker.service"
    else
      sudo rm -f "/etc/systemd/system/ergo-celery-worker.service"
    fi
    echo "Удалён /etc/systemd/system/ergo-celery-worker.service (устаревший)"
  fi
  
  daemon_reload
  if [[ "$purge" == "true" ]]; then
    if [[ -f "/etc/default/ergo_ms" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/default/ergo_ms"
      else
        sudo rm -f "/etc/default/ergo_ms"
      fi
      echo "Удалён /etc/default/ergo_ms"
    fi
  fi
}

disable_client_service_if_nginx() {
  local root="$1"
  if ! is_nginx_enabled "$root"; then
    return 0
  fi
  systemctl_do disable ergo-client-dev.service 2>/dev/null || true
  systemctl_do stop ergo-client-dev.service 2>/dev/null || true
  nginx_skip_client_message "$root"
}

install_services() {
  local root="$1"
  local skip_client=0
  is_nginx_enabled "$root" && skip_client=1
  
  echo ""
  echo "=== Установка служб ==="
  echo ""
  
  cd "$root" || exit 1
  
  # Устанавливаем корень для операций со службами
  set_service_project_root "$root"
  
  write_env_file "$root"
  
  # Получаем базовые unit definitions
  get_base_unit_definitions "$root"
  
  # Устанавливаем базовые службы
  install_unit "ergo-api-dev"        "$API_UNIT"
  if (( skip_client == 0 )); then
    install_unit "ergo-client-dev"     "$CLIENT_UNIT"
  else
    disable_client_service_if_nginx "$root"
  fi
  install_unit "ergo-media-api"      "$MEDIA_API_UNIT"
  install_unit "ergo-celery-beat"    "$CELERY_BEAT_UNIT"
  
  # Устанавливаем воркеры из конфигурации
  install_worker_units "$root"

  daemon_reload

  # Включаем и запускаем базовые службы
  enable_and_start ergo-api-dev.service
  if (( skip_client == 0 )); then
    enable_and_start ergo-client-dev.service
  fi
  enable_and_start ergo-media-api.service
  enable_and_start ergo-celery-beat.service
  
  # Включаем и запускаем воркеры
  enable_and_start_workers "$root"

  echo ""
  echo "=== Службы установлены и запущены ==="
  echo ""
  status_all
  echo ""
  echo "Службы запущены!"
}

install_single_service() {
  local service_name="$1"
  local root="$2"
  
  echo ""
  echo "=== Установка службы $service_name ==="
  echo ""
  
  cd "$root" || exit 1
  
  # Устанавливаем корень для операций со службами
  set_service_project_root "$root"
  
  write_env_file "$root"
  
  # Получаем базовые unit definitions
  get_base_unit_definitions "$root"
  
  local unit_name=""
  
  case "$service_name" in
    "api")
      unit_name="ergo-api-dev"
      install_unit "$unit_name" "$API_UNIT"
      ;;
    "client")
      if is_nginx_enabled "$root"; then
        disable_client_service_if_nginx "$root"
        return 0
      fi
      unit_name="ergo-client-dev"
      install_unit "$unit_name" "$CLIENT_UNIT"
      ;;
    "worker")
      # Устанавливаем все воркеры из конфигурации
      install_worker_units "$root"
      daemon_reload
      enable_and_start_workers "$root"
      echo ""
      echo "=== Все службы воркеров установлены и запущены ==="
      echo ""
      status_all
      echo ""
      echo "Службы worker запущены!"
      return
      ;;
    "beat")
      unit_name="ergo-celery-beat"
      install_unit "$unit_name" "$CELERY_BEAT_UNIT"
      ;;
    "media")
      unit_name="ergo-media-api"
      install_unit "$unit_name" "$MEDIA_API_UNIT"
      ;;
    *)
      echo "Неизвестная служба: $service_name" >&2
      exit 1
      ;;
  esac

  daemon_reload
  enable_and_start "${unit_name}.service"

  echo ""
  echo "=== Служба $service_name установлена и запущена ==="
  echo ""
  status_all
  echo ""
  echo "Служба $service_name запущена!"
}

export -f disable_client_service_if_nginx
export -f set_service_project_root
export -f start_all
export -f stop_all
export -f restart_all
export -f status_all
export -f show_service_logs
export -f uninstall_all
export -f install_services
export -f install_single_service
