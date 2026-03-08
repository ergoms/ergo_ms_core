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

stop_all() {
  local root="${SERVICE_PROJECT_ROOT:-}"
  local u
  for u in $(units_list "$root"); do systemctl_do stop "$u" || true; done
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

show_service_logs() {
  local service_name="$1"
  local lines="${2:-500}"
  
  echo "-> Showing last $lines lines of $service_name logs..."
  echo ""
  
  if [[ $(id -u) -eq 0 ]]; then
    journalctl -u "$service_name" -n "$lines" -f | cat
  else
    sudo journalctl -u "$service_name" -n "$lines" -f | cat
  fi
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
      echo "Removed /etc/systemd/system/$u"
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
    echo "Removed /etc/systemd/system/ergo-celery-worker.service (legacy)"
  fi
  
  daemon_reload
  if [[ "$purge" == "true" ]]; then
    if [[ -f "/etc/default/ergo_ms" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/default/ergo_ms"
      else
        sudo rm -f "/etc/default/ergo_ms"
      fi
      echo "Removed /etc/default/ergo_ms"
    fi
  fi
}

install_services() {
  local root="$1"
  
  echo ""
  echo "=== Installing Services ==="
  echo ""
  
  cd "$root" || exit 1
  
  # Устанавливаем корень для операций со службами
  set_service_project_root "$root"
  
  write_env_file "$root"
  
  # Получаем базовые unit definitions
  get_base_unit_definitions
  
  # Устанавливаем базовые службы
  install_unit "ergo-api-dev"        "$API_UNIT"
  install_unit "ergo-client-dev"     "$CLIENT_UNIT"
  install_unit "ergo-media-api"      "$MEDIA_API_UNIT"
  install_unit "ergo-celery-beat"    "$CELERY_BEAT_UNIT"
  
  # Устанавливаем воркеры из конфигурации
  install_worker_units "$root"

  daemon_reload

  # Включаем и запускаем базовые службы
  enable_and_start ergo-api-dev.service
  enable_and_start ergo-client-dev.service
  enable_and_start ergo-media-api.service
  enable_and_start ergo-celery-beat.service
  
  # Включаем и запускаем воркеры
  enable_and_start_workers "$root"

  echo ""
  echo "=== Services Installed and Started ==="
  echo ""
  status_all
  echo ""
  echo "Services are now running!"
}

install_single_service() {
  local service_name="$1"
  local root="$2"
  
  echo ""
  echo "=== Installing $service_name Service ==="
  echo ""
  
  cd "$root" || exit 1
  
  # Устанавливаем корень для операций со службами
  set_service_project_root "$root"
  
  write_env_file "$root"
  
  # Получаем базовые unit definitions
  get_base_unit_definitions
  
  local unit_name=""
  
  case "$service_name" in
    "api")
      unit_name="ergo-api-dev"
      install_unit "$unit_name" "$API_UNIT"
      ;;
    "client")
      unit_name="ergo-client-dev"
      install_unit "$unit_name" "$CLIENT_UNIT"
      ;;
    "worker")
      # Устанавливаем все воркеры из конфигурации
      install_worker_units "$root"
      daemon_reload
      enable_and_start_workers "$root"
      echo ""
      echo "=== All Worker Services Installed and Started ==="
      echo ""
      status_all
      echo ""
      echo "Worker services are now running!"
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
    "ollama")
      local unit_name="ergo-ollama"
      install_unit "$unit_name" "$OLLAMA_UNIT"
      ;;
    *)
      echo "Unknown service: $service_name" >&2
      exit 1
      ;;
  esac

  daemon_reload
  enable_and_start "${unit_name}.service"

  echo ""
  echo "=== $service_name Service Installed and Started ==="
  echo ""
  status_all
  echo ""
  echo "$service_name service is now running!"
}

export -f set_service_project_root
export -f start_all
export -f stop_all
export -f restart_all
export -f status_all
export -f show_service_logs
export -f uninstall_all
export -f install_services
export -f install_single_service
