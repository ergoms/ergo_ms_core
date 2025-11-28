#!/usr/bin/env bash
# Service management functions
# Функции управления службами

start_all() {
  local u
  for u in $(units_list); do systemctl_do start "$u"; done
}

stop_all() {
  local u
  for u in $(units_list); do systemctl_do stop "$u" || true; done
}

restart_all() {
  local u
  for u in $(units_list); do systemctl_do restart "$u"; done
}

status_all() {
  local u
  for u in $(units_list); do systemctl_do status "$u" | cat; done
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
  stop_all || true
  local u
  for u in $(units_list); do systemctl_do disable "$u" || true; done
  for u in $(units_list); do
    if [[ -f "/etc/systemd/system/$u" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/systemd/system/$u"
      else
        sudo rm -f "/etc/systemd/system/$u"
      fi
      echo "Removed /etc/systemd/system/$u"
    fi
  done
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
  
  write_env_file "$root"
  
  # Get unit definitions
  get_unit_definitions
  
  install_unit "ergo-api-dev"        "$API_UNIT"
  install_unit "ergo-client-dev"     "$CLIENT_UNIT"
  install_unit "ergo-celery-worker"  "$CELERY_WORKER_UNIT"
  install_unit "ergo-celery-beat"    "$CELERY_BEAT_UNIT"
  install_unit "ergo-ollama"         "$OLLAMA_UNIT"

  daemon_reload

  enable_and_start ergo-api-dev.service
  enable_and_start ergo-client-dev.service
  enable_and_start ergo-celery-worker.service
  enable_and_start ergo-celery-beat.service
  enable_and_start ergo-ollama.service

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
  
  write_env_file "$root"
  
  # Get unit definitions
  get_unit_definitions
  
  case "$service_name" in
    "api")
      local unit_name="ergo-api-dev"
      install_unit "$unit_name" "$API_UNIT"
      ;;
    "client")
      local unit_name="ergo-client-dev"
      install_unit "$unit_name" "$CLIENT_UNIT"
      ;;
    "worker")
      local unit_name="ergo-celery-worker"
      install_unit "$unit_name" "$CELERY_WORKER_UNIT"
      ;;
    "beat")
      local unit_name="ergo-celery-beat"
      install_unit "$unit_name" "$CELERY_BEAT_UNIT"
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

export -f start_all
export -f stop_all
export -f restart_all
export -f status_all
export -f show_service_logs
export -f uninstall_all
export -f install_services
export -f install_single_service

