#!/usr/bin/env bash
# PostgreSQL management for Linux
# Portable PostgreSQL в virtual_env/packages/postgres

SCRIPT_DIR_POSTGRES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=portable_env.sh
source "$SCRIPT_DIR_POSTGRES/portable_env.sh"

POSTGRES_SERVICE_NAME_DEFAULT='ergo-postgres'
POSTGRES_SERVICE_NAME="$POSTGRES_SERVICE_NAME_DEFAULT"
POSTGRES_SERVICE_DISPLAY_NAME='Ergo MS - PostgreSQL'
POSTGRES_UNIT_PATH="/etc/systemd/system/${POSTGRES_SERVICE_NAME}.service"

_postgres_init_service_config() {
  local root="$1"
  local name display
  name="$(_ergo_env_value "$root" 'POSTGRES_SERVICE_LINUX' 2>/dev/null || true)"
  if [[ -n "${name:-}" ]]; then
    POSTGRES_SERVICE_NAME="$name"
  else
    POSTGRES_SERVICE_NAME="$POSTGRES_SERVICE_NAME_DEFAULT"
  fi
  display="$(_ergo_env_value "$root" 'POSTGRES_SERVICE_DISPLAY_NAME' 2>/dev/null || true)"
  if [[ -n "${display:-}" ]]; then
    POSTGRES_SERVICE_DISPLAY_NAME="$display"
  else
    POSTGRES_SERVICE_DISPLAY_NAME='Ergo MS - PostgreSQL'
  fi
  POSTGRES_UNIT_PATH="/etc/systemd/system/${POSTGRES_SERVICE_NAME}.service"
}

_postgres_dir() {
  local root="$1"
  echo "$root/virtual_env/packages/postgres"
}

_postgres_bin_dir() {
  local root="$1"
  local dir
  dir="$(_postgres_dir "$root")"
  if [[ -x "$dir/bin/postgres" ]]; then
    echo "$dir/bin"
    return 0
  fi
  if [[ -x "$dir/pgsql/bin/postgres" ]]; then
    echo "$dir/pgsql/bin"
    return 0
  fi
  echo "$dir/bin"
}

_postgres_bin() {
  local root="$1"
  local name="$2"
  echo "$(_postgres_bin_dir "$root")/$name"
}

_postgres_data() {
  local root="$1"
  echo "$(_postgres_dir "$root")/data"
}

_postgres_python() {
  local root="$1"
  local py="$root/virtual_env/python/bin/python"
  if [[ -x "$py" ]]; then
    echo "$py"
    return 0
  fi
  command -v python3
}

_postgres_is_installed() {
  local root="$1"
  [[ -x "$(_postgres_bin "$root" postgres)" ]] && [[ -x "$(_postgres_bin "$root" pg_ctl)" ]]
}

_postgres_yaml_default_field() {
  local root="$1"
  local field="$2"
  local yaml_path="$root/databases.yaml"
  [[ -f "$yaml_path" ]] || return 0
  local in_default=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*default:[[:space:]]*$ ]]; then
      in_default=1
      continue
    fi
    if [[ "$in_default" -eq 1 && "$line" =~ ^[[:space:]]{2}[A-Za-z_]+:[[:space:]]*$ ]]; then
      break
    fi
    if [[ "$in_default" -eq 1 && "$line" =~ ^[[:space:]]+${field}:[[:space:]]*(.+)$ ]]; then
      printf '%s' "${BASH_REMATCH[1]}" | tr -d '[:space:]"'"'"
      return 0
    fi
  done <"$yaml_path"
}

_postgres_listen_port() {
  local root="$1"
  local port_file
  port_file="$(_postgres_dir "$root")/PORT"
  if [[ -f "$port_file" ]]; then
    local raw
    raw="$(tr -d '[:space:]' <"$port_file" || true)"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      echo "$raw"
      return 0
    fi
  fi
  local yaml_port
  yaml_port="$(_postgres_yaml_default_field "$root" port || true)"
  if [[ "$yaml_port" =~ ^[0-9]+$ ]]; then
    echo "$yaml_port"
    return 0
  fi
  echo "5433"
}

_postgres_listen_bind() {
  local root="$1"
  local yaml_host
  yaml_host="$(_postgres_yaml_default_field "$root" host || true)"
  case "$(printf '%s' "$yaml_host" | tr '[:upper:]' '[:lower:]')" in
    '' ) echo "127.0.0.1" ;;
    localhost|::1) echo "127.0.0.1" ;;
    *) echo "$yaml_host" ;;
  esac
}

_postgres_db_access_field() {
  local root="$1"
  local field="$2"
  local fallback="$3"
  local value
  value="$(_postgres_yaml_default_field "$root" "$field" || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$fallback"
  fi
}

_postgres_db_access_summary() {
  local root="$1"
  local db_name db_user db_password
  db_name="$(_postgres_db_access_field "$root" name ergo_ms)"
  db_user="$(_postgres_db_access_field "$root" user postgres)"
  db_password="$(_postgres_db_access_field "$root" password admin)"
  echo "    База: $db_name"
  echo "    Пользователь: $db_user"
  echo "    Пароль: $db_password"
  echo "[INFO] Источник: databases.yaml (default) или значения по умолчанию portable"
}

_postgres_yaml_port_hint() {
  local root="$1"
  local listen_port="$2"
  local yaml_port
  yaml_port="$(_postgres_yaml_default_field "$root" port || true)"
  if [[ -z "$yaml_port" ]]; then
    echo "[INFO] Задайте default.port в databases.yaml (сейчас portable: $listen_port)"
    return 0
  fi
  if [[ "$yaml_port" != "$listen_port" ]]; then
    echo "[WARNING] databases.yaml default.port=$yaml_port, portable слушает $listen_port"
    echo "[INFO] Переустановите portable (ergoms install-postgres) или выровняйте port в databases.yaml"
  fi
}

_postgres_portable_present() {
  local root="$1"
  if _postgres_is_installed "$root"; then
    return 0
  fi
  [[ -f "$POSTGRES_UNIT_PATH" ]] && return 0
  return 1
}

_postgres_run_script() {
  local root="$1"
  shift
  local py
  py="$(_postgres_python "$root")"
  if [[ -z "$py" ]]; then
    echo "[ERROR] Python не найден. Выполните: ergoms setup" >&2
    return 1
  fi
  export PYTHONIOENCODING=utf-8
  export PYTHONUTF8=1
  "$py" "$root/core/deployment/scripts/install_postgres.py" --root "$root" "$@"
}

_postgres_system_present() {
  local root="$1"
  _postgres_run_script "$root" --check-system-only
}

_postgres_force_install() {
  local root="$1"
  _postgres_run_script "$root" --check-force-only
}

_postgres_unit_content() {
  local root="$1"
  local postgres data
  _postgres_init_service_config "$root"
  postgres="$(_postgres_bin "$root" postgres)"
  data="$(_postgres_data "$root")"
  cat <<UNIT
[Unit]
Description=${POSTGRES_SERVICE_DISPLAY_NAME}
After=network.target

[Service]
Type=simple
EnvironmentFile=-__ERGO_MS_ENV__
User=root
ExecStart=$postgres -D $data
ExecStop=$(_postgres_bin "$root" pg_ctl) stop -D $data -m fast
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

_postgres_use_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

postgres_install() {
  local root="$1"
  local listen_port="${2:-}"
  local no_skip_system="${3:-false}"

  _postgres_init_service_config "$root"

  echo ""
  echo "=== PostgreSQL: установка и запуск ==="
  echo ""

  local force_env=false
  if _postgres_force_install "$root"; then
    force_env=true
  fi

  if _postgres_system_present "$root" && [[ "$force_env" != "true" ]] && [[ "$no_skip_system" != "true" ]]; then
    echo "[SKIP] Найдена системная служба PostgreSQL — portable не устанавливается"
    echo "[INFO] Принудительно: POSTGRES_FORCE_INSTALL=true в .env"
    return 0
  fi

  local args=(--no-start)
  [[ -n "$listen_port" ]] && args+=(--port "$listen_port")
  if [[ "$force_env" == "true" ]] || [[ "$no_skip_system" == "true" ]]; then
    args+=(--no-skip-system)
  fi

  if ! _postgres_run_script "$root" "${args[@]}"; then
    echo "[ERROR] Установка PostgreSQL не удалась" >&2
    return 1
  fi

  if ! _postgres_is_installed "$root"; then
    echo "[SKIP] Portable PostgreSQL не установлен (системная СУБД или пропуск)"
    return 0
  fi

  if _postgres_use_systemd; then
    postgres_install_service "$root"
  else
    postgres_start "$root"
  fi

  if ! _postgres_run_script "$root" --ensure-db-only; then
    echo "[ERROR] Не удалось создать базы данных" >&2
    return 1
  fi

  local listen_port listen_bind
  listen_port="$(_postgres_listen_port "$root")"
  listen_bind="$(_postgres_listen_bind "$root")"
  echo ""
  echo "[OK] PostgreSQL установлен"
  echo "    Путь: $(_postgres_dir "$root")"
  echo "    Служба: $POSTGRES_SERVICE_NAME"
  echo "    Прослушивание: ${listen_bind}:${listen_port}"
  _postgres_db_access_summary "$root"
  _postgres_yaml_port_hint "$root" "$listen_port"
}

postgres_install_service() {
  local root="$1"
  _postgres_init_service_config "$root"
  if ! _postgres_is_installed "$root"; then
    echo "[ERROR] PostgreSQL не установлен. Выполните: ergoms install-postgres" >&2
    return 1
  fi

  postgres_stop "$root" quiet 2>/dev/null || true

  local content
  content="$(_postgres_unit_content "$root")"
  install_unit "$POSTGRES_SERVICE_NAME" "$content" "$root"
  enable_and_start "$POSTGRES_SERVICE_NAME.service"
  echo "[OK] Служба systemd PostgreSQL установлена и запущена"
}

postgres_start() {
  local root="$1"
  _postgres_init_service_config "$root"
  if ! _postgres_is_installed "$root"; then
    echo "[ERROR] PostgreSQL не установлен. Выполните: ergoms install-postgres" >&2
    return 1
  fi

  if systemctl is-active --quiet "$POSTGRES_SERVICE_NAME.service" 2>/dev/null; then
    echo "[OK] Служба PostgreSQL уже запущена"
    return 0
  fi

  if [[ -f "$POSTGRES_UNIT_PATH" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      systemctl start "$POSTGRES_SERVICE_NAME.service"
    else
      sudo systemctl start "$POSTGRES_SERVICE_NAME.service"
    fi
    echo "[OK] Служба PostgreSQL запущена"
    return 0
  fi

  local pg_ctl data log_file
  pg_ctl="$(_postgres_bin "$root" pg_ctl)"
  data="$(_postgres_data "$root")"
  log_file="$(_postgres_dir "$root")/logs/pg_ctl.log"
  mkdir -p "$(_postgres_dir "$root")/logs"
  echo "-> Запуск PostgreSQL..."
  if ! "$pg_ctl" start -D "$data" -l "$log_file" -w -t 60; then
    echo "[ERROR] PostgreSQL не запустился. Проверьте логи: $log_file" >&2
    return 1
  fi
  echo "[OK] PostgreSQL запущен"
}

postgres_stop() {
  local root="${1:-}"
  local quiet="${2:-}"
  _postgres_init_service_config "$root"

  if systemctl is-active --quiet "$POSTGRES_SERVICE_NAME.service" 2>/dev/null; then
    [[ -z "$quiet" ]] && echo "-> Остановка службы PostgreSQL..."
    if [[ $(id -u) -eq 0 ]]; then
      systemctl stop "$POSTGRES_SERVICE_NAME.service"
    else
      sudo systemctl stop "$POSTGRES_SERVICE_NAME.service"
    fi
    [[ -z "$quiet" ]] && echo "[OK] Служба PostgreSQL остановлена"
    return 0
  fi

  if [[ -n "$root" ]] && _postgres_is_installed "$root"; then
    local pg_ctl data
    pg_ctl="$(_postgres_bin "$root" pg_ctl)"
    data="$(_postgres_data "$root")"
    [[ -z "$quiet" ]] && echo "-> Остановка PostgreSQL (pg_ctl)..."
    "$pg_ctl" stop -D "$data" -m fast -w 2>/dev/null || true
  fi

  [[ -z "$quiet" ]] && echo "[OK] PostgreSQL остановлен"
  return 0
}

postgres_restart() {
  local root="$1"
  _postgres_init_service_config "$root"
  if systemctl is-active --quiet "$POSTGRES_SERVICE_NAME.service" 2>/dev/null \
    || [[ -f "$POSTGRES_UNIT_PATH" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      systemctl restart "$POSTGRES_SERVICE_NAME.service"
    else
      sudo systemctl restart "$POSTGRES_SERVICE_NAME.service"
    fi
    echo "[OK] Служба PostgreSQL перезапущена"
    return 0
  fi
  postgres_stop "$root"
  postgres_start "$root"
}

postgres_status() {
  local root="$1"
  local dir
  _postgres_init_service_config "$root"
  dir="$(_postgres_dir "$root")"

  if ! _postgres_is_installed "$root"; then
    echo "PostgreSQL: не установлен"
    echo "  Ожидаемый путь: $dir"
    return 0
  fi

  echo ""
  echo "=== Статус PostgreSQL ==="
  if systemctl is-active --quiet "$POSTGRES_SERVICE_NAME.service" 2>/dev/null; then
    echo "  Служба ($POSTGRES_SERVICE_NAME): active"
  elif [[ -f "$POSTGRES_UNIT_PATH" ]]; then
    echo "  Служба ($POSTGRES_SERVICE_NAME): inactive"
  else
    echo "  Служба: не зарегистрирована"
  fi
  local listen_port listen_bind
  listen_port="$(_postgres_listen_port "$root")"
  listen_bind="$(_postgres_listen_bind "$root")"
  echo "  Путь: $dir"
  echo "  Прослушивание: ${listen_bind}:${listen_port}"
  _postgres_yaml_port_hint "$root" "$listen_port"
  if _postgres_run_script "$root" --ping-only; then
    echo "  Ping: OK"
  else
    echo "  Ping: не удался (сервер не запущен?)"
  fi
}

postgres_test() {
  local root="$1"
  _postgres_run_script "$root" --ping-only
}

postgres_migrate_to_portable() {
  local root="$1"
  shift || true

  echo ""
  echo "=== PostgreSQL: миграция данных в portable ==="
  echo ""

  if ! _postgres_is_installed "$root"; then
    echo "[ERROR] PostgreSQL не установлен. Выполните: ergoms install-postgres" >&2
    return 1
  fi

  local py
  py="$(_postgres_python "$root")"
  if [[ -z "$py" ]]; then
    echo "[ERROR] Python не найден. Выполните: ergoms setup" >&2
    return 1
  fi
  export PYTHONIOENCODING=utf-8
  export PYTHONUTF8=1
  export PYTHONUNBUFFERED=1
  "$py" -u "$root/core/deployment/scripts/migrate_postgres_to_portable.py" --root "$root" "$@"
}

postgres_uninstall() {
  local root="$1"
  local purge="${2:-false}"

  _postgres_init_service_config "$root"
  echo "=== PostgreSQL: удаление ==="
  postgres_stop "$root" quiet 2>/dev/null || true

  if [[ -f "$POSTGRES_UNIT_PATH" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      systemctl disable --now "$POSTGRES_SERVICE_NAME.service" 2>/dev/null || true
      rm -f "$POSTGRES_UNIT_PATH"
      systemctl daemon-reload
    else
      sudo systemctl disable --now "$POSTGRES_SERVICE_NAME.service" 2>/dev/null || true
      sudo rm -f "$POSTGRES_UNIT_PATH"
      sudo systemctl daemon-reload
    fi
    echo "[OK] Служба PostgreSQL удалена"
  fi

  local dir
  dir="$(_postgres_dir "$root")"
  if [[ "$purge" == "true" ]] && [[ -d "$dir" ]]; then
    rm -rf "$dir"
    echo "[OK] Удалено: $dir"
  else
    echo "[OK] PostgreSQL остановлен (бинарники сохранены; для удаления packages/postgres используйте --purge)"
  fi
}
