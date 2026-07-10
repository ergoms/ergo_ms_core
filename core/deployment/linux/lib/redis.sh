#!/usr/bin/env bash
# Redis management for Linux
# Portable Redis в virtual_env/packages/redis (сборка из исходников)

REDIS_SERVICE_NAME='ergo-redis'
REDIS_UNIT_PATH="/etc/systemd/system/${REDIS_SERVICE_NAME}.service"

_redis_dir() {
  local root="$1"
  echo "$root/virtual_env/packages/redis"
}

_redis_server() {
  local root="$1"
  local dir
  dir="$(_redis_dir "$root")"
  if [[ -x "$dir/bin/redis-server" ]]; then
    echo "$dir/bin/redis-server"
    return 0
  fi
  echo "$dir/bin/redis-server"
}

_redis_cli() {
  local root="$1"
  echo "$(_redis_dir "$root")/bin/redis-cli"
}

_redis_conf() {
  local root="$1"
  echo "$(_redis_dir "$root")/conf/redis.conf"
}

_redis_python() {
  local root="$1"
  local py="$root/virtual_env/python/bin/python"
  if [[ -x "$py" ]]; then
    echo "$py"
    return 0
  fi
  command -v python3
}

_redis_read_env() {
  local root="$1"
  local env_file="$root/.env"
  [[ -f "$env_file" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      case "$key" in
        REDIS_ENABLED|REDIS_HOST|REDIS_PORT|REDIS_DB_CACHE|REDIS_DB_CHANNEL)
          export "$key=$value"
          ;;
      esac
    fi
  done < "$env_file"
}

_redis_ensure_env() {
  local root="$1"
  local configure="${2:-false}"
  local py
  py="$(_redis_python "$root")"
  [[ -n "$py" ]] || return 0
  if [[ "$configure" == "true" ]]; then
    "$py" "$root/core/deployment/scripts/ensure_redis_env.py" --configure 2>/dev/null || true
  else
    "$py" "$root/core/deployment/scripts/ensure_redis_env.py" 2>/dev/null || true
  fi
}

_redis_is_installed() {
  local root="$1"
  [[ -x "$(_redis_server "$root")" ]] && [[ -f "$(_redis_conf "$root")" ]]
}

_redis_run_install_script() {
  local root="$1"
  local port="${2:-6379}"
  local py
  py="$(_redis_python "$root")"
  if [[ -z "$py" ]]; then
    echo "[ERROR] Python not found. Run: ergoms setup" >&2
    return 1
  fi
  "$py" "$root/core/deployment/scripts/install_redis.py" --root "$root" --port "$port"
}

_redis_ping() {
  local root="$1"
  local py
  py="$(_redis_python "$root")"
  [[ -n "$py" ]] || return 1
  "$py" "$root/core/deployment/scripts/install_redis.py" --root "$root" --ping-only
}

_redis_unit_content() {
  local root="$1"
  local server conf
  server="$(_redis_server "$root")"
  conf="$(_redis_conf "$root")"
  cat <<UNIT
[Unit]
Description=Ergo MS Redis (portable packages)
After=network.target

[Service]
Type=forking
EnvironmentFile=-/etc/default/ergo_ms
ExecStart=$server $conf
ExecStop=$(_redis_cli "$root") -c $conf shutdown
PIDFile=$(_redis_dir "$root")/run/redis.pid
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

redis_install() {
  local root="$1"
  local listen_port="${2:-}"
  local as_service="${3:-false}"
  local configure="${4:-false}"

  _redis_ensure_env "$root" "$configure"
  _redis_read_env "$root"
  [[ -n "$listen_port" ]] || listen_port="${REDIS_PORT:-6379}"

  echo ""
  echo "=== Redis: Install & Start ==="
  echo ""

  if ! _redis_run_install_script "$root" "$listen_port"; then
    return 1
  fi

  if [[ "$as_service" == "true" ]]; then
    redis_install_service "$root"
  else
    redis_start "$root"
  fi

  echo ""
  echo "[OK] Redis installed"
  echo "    Listening: 127.0.0.1:${listen_port}"
  echo "    Path: $(_redis_dir "$root")"
  echo "    Config: $(_redis_conf "$root")"
  if [[ "$configure" != "true" ]]; then
    echo "    Set REDIS_ENABLED=true in .env and re-run install-redis, or pass configure flag"
  fi
}

redis_install_service() {
  local root="$1"
  if ! _redis_is_installed "$root"; then
    echo "[ERROR] Redis not installed. Run: ergoms install-redis" >&2
    return 1
  fi

  redis_stop "$root" 2>/dev/null || true

  local content
  content="$(_redis_unit_content "$root")"
  install_unit "$REDIS_SERVICE_NAME" "$content"
  enable_and_start "$REDIS_SERVICE_NAME.service"
  echo "[OK] Redis systemd service installed and started"
}

redis_start() {
  local root="$1"
  if ! _redis_is_installed "$root"; then
    echo "[ERROR] Redis not installed. Run: ergoms install-redis" >&2
    return 1
  fi

  if systemctl is-active --quiet "$REDIS_SERVICE_NAME.service" 2>/dev/null; then
    echo "[OK] Redis service already running"
    return 0
  fi

  if [[ -f "$REDIS_UNIT_PATH" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      systemctl start "$REDIS_SERVICE_NAME.service"
    else
      sudo systemctl start "$REDIS_SERVICE_NAME.service"
    fi
    echo "[OK] Redis service started"
    return 0
  fi

  redis_stop "$root" 2>/dev/null || true
  local server conf
  server="$(_redis_server "$root")"
  conf="$(_redis_conf "$root")"
  echo "-> Starting Redis..."
  "$server" "$conf"
  sleep 2
  if _redis_ping "$root"; then
    echo "[OK] Redis started"
  else
    echo "[ERROR] Redis failed to start. Check logs: $(_redis_dir "$root")/logs/redis.log" >&2
    return 1
  fi
}

redis_stop() {
  local root="${1:-}"
  if systemctl is-active --quiet "$REDIS_SERVICE_NAME.service" 2>/dev/null; then
    echo "-> Stopping Redis service..."
    if [[ $(id -u) -eq 0 ]]; then
      systemctl stop "$REDIS_SERVICE_NAME.service"
    else
      sudo systemctl stop "$REDIS_SERVICE_NAME.service"
    fi
    echo "[OK] Redis service stopped"
    return 0
  fi

  if [[ -n "$root" ]] && _redis_is_installed "$root"; then
    local cli conf
    cli="$(_redis_cli "$root")"
    conf="$(_redis_conf "$root")"
    if [[ -x "$cli" ]]; then
      echo "-> Shutting down Redis..."
      "$cli" -c "$conf" shutdown 2>/dev/null || true
      sleep 1
    fi
  fi

  pkill -x redis-server 2>/dev/null || true
  echo "[OK] Redis stopped"
}

redis_restart() {
  local root="$1"
  if [[ -f "$REDIS_UNIT_PATH" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      systemctl restart "$REDIS_SERVICE_NAME.service"
    else
      sudo systemctl restart "$REDIS_SERVICE_NAME.service"
    fi
    echo "[OK] Redis service restarted"
    return 0
  fi
  redis_stop "$root"
  redis_start "$root"
}

redis_status() {
  local root="$1"
  if ! _redis_is_installed "$root"; then
    echo "Redis: Not installed"
    echo "  Expected path: $(_redis_dir "$root")"
    return 0
  fi

  echo ""
  echo "=== Redis Status ==="

  if [[ -f "$REDIS_UNIT_PATH" ]]; then
    if systemctl is-active --quiet "$REDIS_SERVICE_NAME.service" 2>/dev/null; then
      echo "  Service ($REDIS_SERVICE_NAME): Running"
    else
      echo "  Service ($REDIS_SERVICE_NAME): Not running"
    fi
  elif pgrep -x redis-server >/dev/null 2>&1; then
    echo "  Process: Running (PID: $(pgrep -x redis-server | head -n1))"
  else
    echo "  Process: Not running"
  fi

  echo "  Path: $(_redis_dir "$root")"
  echo "  Config: $(_redis_conf "$root")"

  if _redis_ping "$root"; then
    echo "  Ping: PONG"
  else
    echo "  Ping: failed (server not running?)"
  fi
}

redis_test() {
  local root="$1"
  if _redis_ping "$root"; then
    echo "[OK] PONG"
    return 0
  fi
  echo "[ERROR] Redis ping failed" >&2
  return 1
}

redis_uninstall() {
  local root="$1"
  local purge="${2:-false}"

  echo "=== Redis: Uninstall ==="
  redis_stop "$root"

  if [[ -f "$REDIS_UNIT_PATH" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      systemctl disable --now "$REDIS_SERVICE_NAME.service" 2>/dev/null || true
      rm -f "$REDIS_UNIT_PATH"
      systemctl daemon-reload
    else
      sudo systemctl disable --now "$REDIS_SERVICE_NAME.service" 2>/dev/null || true
      sudo rm -f "$REDIS_UNIT_PATH"
      sudo systemctl daemon-reload
    fi
    echo "[OK] Redis systemd unit removed"
  fi

  local dir
  dir="$(_redis_dir "$root")"
  if [[ "$purge" == "true" ]] && [[ -d "$dir" ]]; then
    rm -rf "$dir"
    echo "[OK] Removed $dir"
  else
    echo "[OK] Redis stopped (binaries kept; use purge to remove packages/redis)"
  fi
}
