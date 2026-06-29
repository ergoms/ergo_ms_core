#!/usr/bin/env bash
# Nginx management for Linux
# Установка, настройка и управление nginx на Linux

NGINX_CONF_NAME="ergo_ms"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"

_nginx_read_env() {
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
        NGINX_ENABLED|NGINX_SERVER_NAME|NGINX_PUBLIC_HOST|NGINX_LISTEN_HOST|NGINX_LISTEN_PORT|NGINX_USE_HTTPS|NGINX_HOST_POLICY|NGINX_ALT_HOSTS|ERGO_SSL_CERT|ERGO_SSL_KEY)
          export "$key=$value"
          ;;
      esac
    fi
  done < "$env_file"
}

_nginx_truthy() {
  local value
  value="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" ]]
}

_nginx_should_use_ssl() {
  local explicit="${1:-false}"
  local port="${2:-${NGINX_LISTEN_PORT:-80}}"
  if [[ "$explicit" == "true" ]]; then
    return 0
  fi
  if _nginx_truthy "${NGINX_USE_HTTPS:-}"; then
    return 0
  fi
  [[ "$port" == "443" ]]
}

_nginx_warn_insecure_certs() {
  local cert="${ERGO_SSL_CERT:-}"
  local key="${ERGO_SSL_KEY:-}"
  if [[ -z "$cert" || -z "$key" ]]; then
    echo "[WARN] ERGO_SSL_CERT / ERGO_SSL_KEY not set. HTTPS will fail nginx -t." >&2
    return 0
  fi
  if [[ "$cert" == *snakeoil* || "$key" == *snakeoil* ]]; then
    echo "[WARN] Self-signed snakeoil certificate in use. Use Let's Encrypt for production." >&2
    return 0
  fi
  if [[ ! -f "$cert" ]]; then
    echo "[WARN] SSL certificate not found: $cert" >&2
  fi
  if [[ ! -f "$key" ]]; then
    echo "[WARN] SSL private key not found: $key" >&2
  fi
}

_nginx_sudo() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

_nginx_is_installed() {
  command -v nginx >/dev/null 2>&1
}

_nginx_wait_for_apt_locks() {
  local timeout="${1:-180}"
  local waited=0
  local lock_paths=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
    /var/lib/apt/lists/lock
  )

  if ! command -v fuser >/dev/null 2>&1; then
    return 0
  fi

  while (( waited < timeout )); do
    local busy=0
    local lock
    for lock in "${lock_paths[@]}"; do
      if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
        busy=1
        break
      fi
    done
    if (( busy == 0 )); then
      return 0
    fi
    if (( waited == 0 )); then
      echo "-> Waiting for apt/dpkg lock (another package manager is running)..."
    fi
    sleep 3
    waited=$((waited + 3))
  done

  echo "[ERROR] apt/dpkg lock is still held after ${timeout}s." >&2
  echo "  Wait until unattended-upgrades or apt-get finishes, then retry:" >&2
  echo "  sudo ergoms install-nginx" >&2
  echo "  Check: ps aux | grep -E 'apt|dpkg|unattended'" >&2
  return 1
}

_nginx_install_via_apt() {
  local apt_opts=(
    -o "DPkg::Lock::Timeout=120"
    -o "APT::Acquire::Retries=3"
  )

  _nginx_wait_for_apt_locks || return 1

  echo "-> Installing nginx (apt)..."
  if _nginx_sudo apt-get "${apt_opts[@]}" install -y -qq nginx; then
    return 0
  fi

  echo "-> Refreshing package lists..."
  _nginx_wait_for_apt_locks || return 1
  if ! _nginx_sudo apt-get "${apt_opts[@]}" update -qq; then
    echo "[WARN] apt-get update failed. Retrying nginx install anyway..." >&2
  fi

  _nginx_wait_for_apt_locks || return 1
  _nginx_sudo apt-get "${apt_opts[@]}" install -y -qq nginx
}

_nginx_install_package() {
  if _nginx_is_installed; then
    echo "[OK] Nginx already installed: $(nginx -v 2>&1)"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    _nginx_install_via_apt
  elif command -v dnf >/dev/null 2>&1; then
    echo "-> Installing nginx (dnf)..."
    _nginx_sudo dnf install -y -q nginx
  elif command -v yum >/dev/null 2>&1; then
    echo "-> Installing nginx (yum)..."
    _nginx_sudo yum install -y -q nginx
  elif command -v pacman >/dev/null 2>&1; then
    echo "-> Installing nginx (pacman)..."
    _nginx_sudo pacman -Sy --noconfirm nginx
  else
    echo "[ERROR] Cannot detect package manager. Install nginx manually." >&2
    return 1
  fi

  if _nginx_is_installed; then
    echo "[OK] Nginx installed"
    return 0
  fi

  echo "[ERROR] Nginx installation failed." >&2
  return 1
}

_nginx_detect_snippets_dir() {
  local root="$1"
  echo "$root/core/deployment/nginx/snippets"
}

_nginx_render_template() {
  local template="$1"
  local root="$2"
  local server_name="${3:-localhost}"
  local listen_host="${4:-0.0.0.0}"
  local listen_port="${5:-80}"
  local use_ssl="${6:-false}"
  local py="$root/virtual_env/python/bin/python"
  [[ -x "$py" ]] || py="python3"

  local script="$root/core/deployment/scripts/render_nginx_config.py"
  if [[ ! -f "$script" ]]; then
    echo "[ERROR] render_nginx_config.py not found" >&2
    return 1
  fi

  "$py" "$script" \
    --template "$template" \
    --root "$root" \
    --server-name "$server_name" \
    --listen-host "$listen_host" \
    --listen-port "$listen_port" \
    --use-https "$use_ssl" \
    --ssl-cert "${ERGO_SSL_CERT:-}" \
    --ssl-key "${ERGO_SSL_KEY:-}"
}

_nginx_select_template() {
  local root="$1"
  local use_ssl="${2:-false}"
  local nginx_dir="$root/core/deployment/nginx"

  if [[ "$use_ssl" == "true" ]] && [[ -f "$nginx_dir/ergo_ms.conf.template" ]]; then
    echo "$nginx_dir/ergo_ms.conf.template"
  else
    echo "$nginx_dir/ergo_ms_http.conf.template"
  fi
}

_nginx_ensure_env() {
  local root="$1"
  local py="$root/virtual_env/python/bin/python"
  [[ -x "$py" ]] || return 0
  "$py" "$root/core/deployment/scripts/ensure_nginx_env.py" 2>/dev/null || true
}

nginx_install() {
  local root="$1"
  _nginx_ensure_env "$root"
  _nginx_read_env "$root"
  local server_name="${2}"
  local listen_host="${NGINX_LISTEN_HOST:-0.0.0.0}"
  local listen_port="${3}"
  local use_ssl="${4:-false}"
  if [[ -z "$server_name" ]]; then
    if [[ -n "${NGINX_PUBLIC_HOST:-}" ]]; then
      server_name="$NGINX_PUBLIC_HOST"
    else
      server_name="${NGINX_SERVER_NAME:-localhost}"
    fi
  fi
  [[ -z "$listen_port" ]] && listen_port="${NGINX_LISTEN_PORT:-80}"

  if _nginx_should_use_ssl "$use_ssl" "$listen_port"; then
    use_ssl="true"
    export ERGO_SSL_CERT="${ERGO_SSL_CERT:-/etc/ssl/certs/ssl-cert-snakeoil.pem}"
    export ERGO_SSL_KEY="${ERGO_SSL_KEY:-/etc/ssl/private/ssl-cert-snakeoil.key}"
    _nginx_warn_insecure_certs
  fi

  echo ""
  echo "=== Nginx: Install ==="
  echo ""

  if ! _nginx_install_package; then
    return 1
  fi

  local template
  template="$(_nginx_select_template "$root" "$use_ssl")"
  if [[ ! -f "$template" ]]; then
    echo "[ERROR] Template not found: $template" >&2
    return 1
  fi

  if [[ ! -d "$root/core/client/dist" ]]; then
    echo "[WARN] $root/core/client/dist not found. Run: ergoms build-all" >&2
  fi

  local rendered
  rendered="$(_nginx_render_template "$template" "$root" "$server_name" "$listen_host" "$listen_port" "$use_ssl")"

  local conf_path="$NGINX_SITES_AVAILABLE/${NGINX_CONF_NAME}.conf"
  local tmp_file
  tmp_file="$(mktemp)"
  printf '%s\n' "$rendered" > "$tmp_file"

  _nginx_sudo mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"
  _nginx_sudo install -m 0644 "$tmp_file" "$conf_path"
  rm -f "$tmp_file"

  _nginx_sudo ln -sf "$conf_path" "$NGINX_SITES_ENABLED/${NGINX_CONF_NAME}.conf"

  # Отключаем default, если он конфликтует
  if [[ -L "$NGINX_SITES_ENABLED/default" ]]; then
    echo "-> Disabling default nginx site..."
    _nginx_sudo rm -f "$NGINX_SITES_ENABLED/default"
  fi

  echo "-> Testing nginx configuration..."
  if _nginx_sudo nginx -t; then
    echo "[OK] Configuration valid"
    _nginx_sudo systemctl enable nginx 2>/dev/null || true
    _nginx_sudo systemctl reload nginx 2>/dev/null || _nginx_sudo systemctl start nginx
    echo "[OK] Nginx installed and running"
    echo "    Config: $conf_path"
    if [[ "$use_ssl" == "true" ]]; then
      echo "    Listening: https://${server_name}:443"
    else
      echo "    Listening: http://${server_name}:${listen_port} (bind ${listen_host})"
    fi
  else
    echo "[ERROR] nginx -t failed. Config written but not activated." >&2
    return 1
  fi
}

nginx_uninstall() {
  echo ""
  echo "=== Nginx: Uninstall Ergo MS config ==="
  echo ""

  nginx_stop_service 2>/dev/null || true

  local conf="$NGINX_SITES_AVAILABLE/${NGINX_CONF_NAME}.conf"
  local link="$NGINX_SITES_ENABLED/${NGINX_CONF_NAME}.conf"

  if [[ -f "$conf" ]]; then
    _nginx_sudo rm -f "$conf"
    echo "[OK] Removed: $conf"
  fi
  if [[ -L "$link" ]]; then
    _nginx_sudo rm -f "$link"
    echo "[OK] Removed: $link"
  fi

  if _nginx_is_installed; then
    _nginx_sudo nginx -t 2>/dev/null && _nginx_sudo systemctl reload nginx 2>/dev/null || true
  fi

  echo "[OK] Ergo MS nginx config removed"
}

nginx_start_service() {
  if ! _nginx_is_installed; then
    echo "[ERROR] Nginx is not installed. Run: ergoms install-nginx" >&2
    return 1
  fi
  echo "-> Starting nginx..."
  _nginx_sudo systemctl start nginx
  echo "[OK] Nginx started"
}

nginx_stop_service() {
  if ! _nginx_is_installed; then
    echo "[ERROR] Nginx is not installed" >&2
    return 1
  fi
  echo "-> Stopping nginx..."
  _nginx_sudo systemctl stop nginx
  echo "[OK] Nginx stopped"
}

nginx_reload_service() {
  if ! _nginx_is_installed; then
    echo "[ERROR] Nginx is not installed. Run: ergoms install-nginx" >&2
    return 1
  fi
  echo "-> Testing configuration..."
  if _nginx_sudo nginx -t; then
    _nginx_sudo systemctl reload nginx
    echo "[OK] Nginx reloaded"
  else
    echo "[ERROR] Configuration test failed. Not reloading." >&2
    return 1
  fi
}

nginx_status_service() {
  if ! _nginx_is_installed; then
    echo "Nginx: Not installed"
    return
  fi

  local conf="$NGINX_SITES_ENABLED/${NGINX_CONF_NAME}.conf"
  if [[ -L "$conf" ]] || [[ -f "$conf" ]]; then
    echo "Ergo MS config: Installed"
  else
    echo "Ergo MS config: Not installed"
  fi

  _nginx_sudo systemctl status nginx --no-pager 2>/dev/null || echo "Nginx service: inactive"
}

nginx_test_config() {
  if ! _nginx_is_installed; then
    echo "[ERROR] Nginx is not installed" >&2
    return 1
  fi
  _nginx_sudo nginx -t
}

export -f nginx_install
export -f nginx_uninstall
export -f nginx_start_service
export -f nginx_stop_service
export -f nginx_reload_service
export -f nginx_status_service
export -f nginx_test_config
