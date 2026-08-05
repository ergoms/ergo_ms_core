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

_unit_is_present() {
  local unit="$1"
  [[ "$unit" == *.service ]] || unit="${unit}.service"
  [[ -f "/etc/systemd/system/$unit" || -L "/etc/systemd/system/$unit" ]] && return 0
  systemctl list-unit-files --type=service --no-legend "$unit" 2>/dev/null | grep -q .
}

start_all() {
  local root="${SERVICE_PROJECT_ROOT:-}"
  local u

  # Redis при ERGO_BROKER=redis — через redis_start (служба или процесс)
  if is_redis_enabled "$root" && declare -F redis_start >/dev/null 2>&1; then
    redis_start "$root" || true
  fi

  # Meilisearch при ERGO_SEARCH_ENABLED — через meilisearch_start
  if is_search_enabled "$root" && declare -F meilisearch_start >/dev/null 2>&1; then
    meilisearch_start "$root" || true
  fi

  for u in $(units_list "$root"); do
    # Redis / Meilisearch уже обработаны отдельно
    [[ "$u" == "ergo_ms_redis.service" || "$u" == "ergo_ms_redis" ]] && continue
    [[ "$u" == "ergo_ms_meilisearch.service" || "$u" == "ergo_ms_meilisearch" ]] && continue
    if _unit_is_present "$u"; then
      systemctl_do start "$u" || true
    fi
  done
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
  local cmd

  # Модульные stop_commands (процесс без службы / доп. очистка) — до systemctl
  if [[ -n "$root" && -d "$root" ]] && command -v ergoms >/dev/null 2>&1; then
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      ( cd "$root" && ergoms "$cmd" ) || true
    done < <(list_module_host_stop_commands "$root")
  fi

  for u in $(units_list "$root"); do
    [[ "$u" == "ergo_ms_redis.service" || "$u" == "ergo_ms_redis" ]] && continue
    [[ "$u" == "ergo_ms_meilisearch.service" || "$u" == "ergo_ms_meilisearch" ]] && continue
    systemctl_do stop "$u" || true
  done

  if is_search_enabled "$root" && declare -F meilisearch_stop >/dev/null 2>&1; then
    meilisearch_stop "$root" || true
  fi

  if is_redis_enabled "$root" && declare -F redis_stop >/dev/null 2>&1; then
    redis_stop "$root" || true
  fi

  # Иначе kill_ergo_project_session_processes рвёт node/vite — npm печатает ERR на «упавший» lifecycle.
  if [[ -n "$root" && -d "$root" ]] && command -v ergoms >/dev/null 2>&1; then
    ( cd "$root" && ergoms npm run stop-dev ) || true
  fi
  kill_ergo_project_session_processes "$root"
}

restart_all() {
  local root="${SERVICE_PROJECT_ROOT:-}"
  local u

  if is_redis_enabled "$root" && declare -F redis_restart >/dev/null 2>&1; then
    redis_restart "$root" || true
  fi

  if is_search_enabled "$root" && declare -F meilisearch_restart >/dev/null 2>&1; then
    meilisearch_restart "$root" || true
  fi

  for u in $(units_list "$root"); do
    [[ "$u" == "ergo_ms_redis.service" || "$u" == "ergo_ms_redis" ]] && continue
    [[ "$u" == "ergo_ms_meilisearch.service" || "$u" == "ergo_ms_meilisearch" ]] && continue
    if _unit_is_present "$u"; then
      systemctl_do restart "$u" || true
    fi
  done
}

status_all() {
  local root="${SERVICE_PROJECT_ROOT:-}"
  local u
  for u in $(units_list "$root"); do
    if _unit_is_present "$u"; then
      systemctl_do status "$u" | cat
    else
      echo "[SKIP] $u — unit не установлен"
    fi
  done
  if is_redis_enabled "$root" && declare -F redis_status >/dev/null 2>&1; then
    # Если unit уже выведен выше — redis_status дублирует; ок для процесса без unit
    if ! _unit_is_present "ergo_ms_redis"; then
      redis_status "$root" || true
    fi
  fi
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
    write_ergoms_message svc_celery_tasks_log_missing red --stderr "path=$log_file"
    return 1
  fi

  write_ergoms_message svc_tail_celery_tasks cyan "" "lines=$lines"
  echo "   $log_file"
  if [[ -n "$module_name" ]]; then
    local pattern="celery\\.module\\.${module_name}"
    write_ergoms_message svc_log_filter gray "" "pattern=$pattern"
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
    write_ergoms_message svc_celery_beat_log_missing red --stderr "path=$log_file"
    return 1
  fi

  write_ergoms_message svc_tail_celery_beat cyan "" "lines=$lines"
  echo "   $log_file"
  if [[ -n "$module_name" ]]; then
    local pattern="celery\\.beat\\.module\\.${module_name}"
    write_ergoms_message svc_log_filter gray "" "pattern=$pattern"
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
      write_ergoms_message svc_nginx_logs_missing red --stderr "path=$(resolve_ergo_logs_dir "$root")"
      write_ergoms_message svc_nginx_logs_hint yellow --stderr
      return 1
    fi
    write_ergoms_message svc_tail_nginx_logs cyan "" "lines=$lines"
    echo ""
    tail -n "$lines" -F "${files[@]}" | cat
    return 0
  fi

  if [[ "$service_name" == "ergo_ms_redis" || "$service_name" == "ergo_ms_redis.service" || "$service_name" == "ergo-redis" || "$service_name" == "ergo-redis.service" ]]; then
    service_name="ergo_ms_redis"
  fi

  if [[ "$service_name" == "ergo_ms_meilisearch" || "$service_name" == "ergo_ms_meilisearch.service" ]]; then
    service_name="ergo_ms_meilisearch"
  fi

  local -a log_files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && log_files+=("$file")
  done < <(resolve_service_log_files "$service_name" "$root" 2>/dev/null || true)

  if [[ ${#log_files[@]} -eq 0 ]]; then
    write_ergoms_message svc_service_logs_missing red --stderr "name=$service_name"
    write_ergoms_message svc_logs_expected_in yellow --stderr "path=$(resolve_ergo_logs_dir "$root")"
    return 1
  fi

  write_ergoms_message svc_tail_service_logs cyan "" "lines=$lines" "name=$service_name"
  for file in "${log_files[@]}"; do
    echo "   $file"
  done
  if [[ "$service_name" == ergo_ms_celery_worker* ]]; then
    write_ergoms_message svc_module_tasks_log_hint gray "" "path=$(resolve_ergo_logs_dir "$root")/celery_tasks.log"
    write_ergoms_message svc_filter_celery_tasks_cmd gray
  fi
  if [[ "$service_name" == "ergo_ms_celery_beat" || "$service_name" == "ergo_ms_celery_beat.service" ]]; then
    write_ergoms_message svc_module_beat_log_hint gray "" "path=$(resolve_ergo_logs_dir "$root")/celery_beat.log"
    write_ergoms_message svc_filter_celery_beat_cmd gray
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
      write_ergoms_message svc_unit_removed gray "" "path=/etc/systemd/system/$u"
    fi
  done

  # Legacy unit-имена (до префикса ergo_ms_)
  local legacy
  for legacy in \
    ergo-api-dev.service \
    ergo-client-dev.service \
    ergo-media-api.service \
    ergo-celery-beat.service \
    ergo-celery-worker.service \
    ergo-redis.service \
    ergo-postgres.service
  do
    systemctl_do disable "$legacy" 2>/dev/null || true
    systemctl_do stop "$legacy" 2>/dev/null || true
    if [[ -f "/etc/systemd/system/$legacy" ]] || [[ -L "/etc/systemd/system/$legacy" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/systemd/system/$legacy"
      else
        sudo rm -f "/etc/systemd/system/$legacy"
      fi
      write_ergoms_message svc_legacy_unit_removed gray "" "path=/etc/systemd/system/$legacy"
    fi
  done
  while IFS= read -r legacy; do
    [[ -z "$legacy" ]] && continue
    systemctl_do disable "$legacy" 2>/dev/null || true
    systemctl_do stop "$legacy" 2>/dev/null || true
    if [[ -f "/etc/systemd/system/$legacy" ]] || [[ -L "/etc/systemd/system/$legacy" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/systemd/system/$legacy"
      else
        sudo rm -f "/etc/systemd/system/$legacy"
      fi
      write_ergoms_message svc_legacy_unit_removed gray "" "path=/etc/systemd/system/$legacy"
    fi
  done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '/^ergo-celery-worker-/ {print $1}')
  
  daemon_reload
  if [[ "$purge" == "true" ]]; then
    if [[ -f "/etc/default/ergo_ms" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/default/ergo_ms"
      else
        sudo rm -f "/etc/default/ergo_ms"
      fi
      write_ergoms_message svc_unit_removed gray "" "path=/etc/default/ergo_ms"
    fi
  fi
}

disable_client_service_if_nginx() {
  local root="$1"
  if ! is_nginx_enabled "$root"; then
    return 0
  fi
  systemctl_do disable ergo_ms_client_dev.service 2>/dev/null || true
  systemctl_do stop ergo_ms_client_dev.service 2>/dev/null || true
  nginx_skip_client_message "$root"
}

install_services() {
  local root="$1"
  local skip_client=0
  is_nginx_enabled "$root" && skip_client=1
  
  echo ""
  write_ergoms_message svc_install_heading cyan
  echo ""
  
  cd "$root" || exit 1
  
  # Устанавливаем корень для операций со службами
  set_service_project_root "$root"
  
  write_env_file "$root"
  
  # Получаем базовые unit definitions
  get_base_unit_definitions "$root"
  
  # Устанавливаем базовые службы
  install_unit "ergo_ms_api_dev"        "$API_UNIT" "$root"
  if (( skip_client == 0 )); then
    install_unit "ergo_ms_client_dev"     "$CLIENT_UNIT" "$root"
  else
    disable_client_service_if_nginx "$root"
  fi
  install_unit "ergo_ms_media_api"      "$MEDIA_API_UNIT" "$root"
  install_unit "ergo_ms_celery_beat"    "$CELERY_BEAT_UNIT" "$root"
  
  # Устанавливаем воркеры из конфигурации
  install_worker_units "$root"

  daemon_reload

  # Включаем и запускаем базовые службы
  enable_and_start ergo_ms_api_dev.service
  if (( skip_client == 0 )); then
    enable_and_start ergo_ms_client_dev.service
  fi
  enable_and_start ergo_ms_media_api.service
  enable_and_start ergo_ms_celery_beat.service
  
  # Включаем и запускаем воркеры
  enable_and_start_workers "$root"

  echo ""
  write_ergoms_message svc_installed_running_heading green
  echo ""
  status_all
  echo ""
  write_ergoms_message svc_services_started_bang green
}

install_single_service() {
  local service_name="$1"
  local root="$2"
  
  echo ""
  write_ergoms_message svc_install_one_heading cyan "" "name=$service_name"
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
      unit_name="ergo_ms_api_dev"
      install_unit "$unit_name" "$API_UNIT" "$root"
      ;;
    "client")
      if is_nginx_enabled "$root"; then
        disable_client_service_if_nginx "$root"
        return 0
      fi
      unit_name="ergo_ms_client_dev"
      install_unit "$unit_name" "$CLIENT_UNIT" "$root"
      ;;
    "worker")
      # Устанавливаем все воркеры из конфигурации
      install_worker_units "$root"
      daemon_reload
      enable_and_start_workers "$root"
      echo ""
      write_ergoms_message svc_workers_installed_running_heading green
      echo ""
      status_all
      echo ""
      write_ergoms_message svc_workers_started_bang green
      return
      ;;
    "beat")
      unit_name="ergo_ms_celery_beat"
      install_unit "$unit_name" "$CELERY_BEAT_UNIT" "$root"
      ;;
    "media")
      unit_name="ergo_ms_media_api"
      install_unit "$unit_name" "$MEDIA_API_UNIT" "$root"
      ;;
    *)
      write_ergoms_message unknown_service red --stderr "name=$service_name"
      exit 1
      ;;
  esac

  daemon_reload
  enable_and_start "${unit_name}.service"

  echo ""
  write_ergoms_message svc_one_installed_running_heading green "" "name=$service_name"
  echo ""
  status_all
  echo ""
  write_ergoms_message svc_one_started_bang green "" "name=$service_name"
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
