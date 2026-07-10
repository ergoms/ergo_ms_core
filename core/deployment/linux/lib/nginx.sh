#!/usr/bin/env bash
# Nginx management for Linux
# Portable nginx в virtual_env/packages/nginx (сборка из официального tarball)

NGINX_VERSION='1.27.4'
NGINX_CONF_NAME='ergo_ms'
NGINX_SERVICE_NAME='ergo_ms_nginx'
NGINX_UNIT_PATH="/etc/systemd/system/${NGINX_SERVICE_NAME}.service"
NGINX_LEGACY_SITES_AVAILABLE='/etc/nginx/sites-available'
NGINX_LEGACY_SITES_ENABLED='/etc/nginx/sites-enabled'

_nginx_packages_dir() {
  local root="$1"
  echo "$root/virtual_env/packages/nginx"
}

_nginx_binary() {
  local root="$1"
  echo "$(_nginx_packages_dir "$root")/sbin/nginx"
}

_nginx_main_conf() {
  local root="$1"
  echo "$(_nginx_packages_dir "$root")/conf/nginx.conf"
}

_nginx_site_conf() {
  local root="$1"
  echo "$(_nginx_packages_dir "$root")/conf/${NGINX_CONF_NAME}.conf"
}

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
        NGINX_ENABLED|NGINX_SERVER_NAME|NGINX_PUBLIC_HOST|NGINX_LISTEN_HOST|NGINX_LISTEN_PORT|NGINX_USE_HTTPS|NGINX_HOST_POLICY|NGINX_ALT_HOSTS|ERGO_SSL_CERT|ERGO_SSL_KEY|ERGO_TLS_EMAIL|ERGO_TLS_DOMAINS|ERGO_TLS_WEBROOT|ERGO_TLS_STAGING)
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
  if [[ "$explicit" == "false" ]]; then
    return 1
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
  local root="$1"
  [[ -x "$(_nginx_binary "$root")" ]]
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

_nginx_install_build_deps() {
  echo "-> Installing build dependencies..."
  if command -v apt-get >/dev/null 2>&1; then
    local apt_opts=(
      -o "DPkg::Lock::Timeout=120"
      -o "APT::Acquire::Retries=3"
    )
    _nginx_wait_for_apt_locks || return 1
    if _nginx_sudo apt-get "${apt_opts[@]}" install -y -qq build-essential zlib1g-dev libssl-dev libpcre3-dev; then
      return 0
    fi
    _nginx_wait_for_apt_locks || return 1
    _nginx_sudo apt-get "${apt_opts[@]}" install -y -qq build-essential zlib1g-dev libssl-dev libpcre2-dev
    return $?
  fi
  if command -v dnf >/dev/null 2>&1; then
    _nginx_sudo dnf install -y -q gcc make zlib-devel openssl-devel pcre2-devel
    return $?
  fi
  if command -v yum >/dev/null 2>&1; then
    _nginx_sudo yum install -y -q gcc make zlib-devel openssl-devel pcre2-devel
    return $?
  fi
  if command -v pacman >/dev/null 2>&1; then
    _nginx_sudo pacman -Sy --noconfirm base-devel zlib openssl pcre2
    return $?
  fi
  echo "[ERROR] Cannot detect package manager for build dependencies." >&2
  return 1
}

_nginx_configure_pcre_flag() {
  if [[ -f /usr/include/pcre2.h ]] && ! [[ -f /usr/include/pcre.h ]]; then
    echo '--with-pcre'
  fi
}

_nginx_download_tarball() {
  local dest="$1"
  local url="https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url"
    return $?
  fi
  echo "[ERROR] curl or wget is required to download nginx." >&2
  return 1
}

_nginx_install_binary() {
  local root="$1"
  local nginx_bin
  nginx_bin="$(_nginx_binary "$root")"

  if [[ -x "$nginx_bin" ]]; then
    echo "[OK] Nginx already installed: $nginx_bin"
    "$nginx_bin" -v 2>&1 | sed 's/^/[OK] /'
    return 0
  fi

  if ! _nginx_install_build_deps; then
    echo "[ERROR] Failed to install build dependencies." >&2
    return 1
  fi

  local nginx_dir tarball src_dir build_dir jobs pcre_flag
  nginx_dir="$(_nginx_packages_dir "$root")"
  build_dir="$(mktemp -d)"
  tarball="$build_dir/nginx-${NGINX_VERSION}.tar.gz"
  src_dir="$build_dir/nginx-${NGINX_VERSION}"
  jobs="$(nproc 2>/dev/null || echo 2)"
  pcre_flag="$(_nginx_configure_pcre_flag)"

  echo "-> Downloading nginx ${NGINX_VERSION}..."
  if ! _nginx_download_tarball "$tarball"; then
    rm -rf "$build_dir"
    echo "[ERROR] Failed to download nginx tarball." >&2
    return 1
  fi

  echo "-> Extracting source..."
  tar -xzf "$tarball" -C "$build_dir"

  if [[ ! -d "$src_dir" ]]; then
    rm -rf "$build_dir"
    echo "[ERROR] Extracted nginx source directory not found." >&2
    return 1
  fi

  mkdir -p "$nginx_dir/logs" "$nginx_dir/temp" "$nginx_dir/conf"

  echo "-> Configuring nginx (prefix: $nginx_dir)..."
  local -a configure_opts=(
    --prefix="$nginx_dir"
    --sbin-path="$nginx_dir/sbin/nginx"
    --conf-path="$nginx_dir/conf/nginx.conf"
    --pid-path="$nginx_dir/logs/nginx.pid"
    --lock-path="$nginx_dir/logs/nginx.lock"
    --error-log-path="$nginx_dir/logs/error.log"
    --http-log-path="$nginx_dir/logs/access.log"
    --http-client-body-temp-path="$nginx_dir/temp/client_body"
    --http-proxy-temp-path="$nginx_dir/temp/proxy"
    --http-fastcgi-temp-path="$nginx_dir/temp/fastcgi"
    --http-uwsgi-temp-path="$nginx_dir/temp/uwsgi"
    --http-scgi-temp-path="$nginx_dir/temp/scgi"
    --with-http_ssl_module
    --with-http_v2_module
  )
  if [[ -n "$pcre_flag" ]]; then
    configure_opts+=("$pcre_flag")
  fi

  if ! (cd "$src_dir" && ./configure "${configure_opts[@]}"); then
    rm -rf "$build_dir"
    echo "[ERROR] nginx ./configure failed." >&2
    return 1
  fi

  echo "-> Building nginx..."
  if ! (cd "$src_dir" && make -j"$jobs"); then
    rm -rf "$build_dir"
    echo "[ERROR] nginx make failed." >&2
    return 1
  fi

  echo "-> Installing nginx to $nginx_dir..."
  if ! (cd "$src_dir" && make install); then
    rm -rf "$build_dir"
    echo "[ERROR] nginx make install failed." >&2
    return 1
  fi

  rm -rf "$build_dir"

  if [[ -x "$nginx_bin" ]]; then
    echo "[OK] Nginx installed to $nginx_dir"
    "$nginx_bin" -v 2>&1 | sed 's/^/[OK] /'
    return 0
  fi

  echo "[ERROR] Nginx binary not found after install: $nginx_bin" >&2
  return 1
}

_nginx_write_main_conf() {
  local root="$1"
  local site_conf="$2"
  local main_conf nginx_dir logs_dir temp_dir include_path
  nginx_dir="$(_nginx_packages_dir "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  logs_dir="$nginx_dir/logs"
  temp_dir="$nginx_dir/temp"
  include_path="$site_conf"

  mkdir -p "$nginx_dir/conf" "$logs_dir" "$temp_dir"

  cat >"$main_conf" <<EOF
worker_processes auto;

error_log $logs_dir/error.log;
pid       $logs_dir/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    access_log $logs_dir/access.log;

    sendfile        on;
    keepalive_timeout 65;

    client_body_temp_path $temp_dir/client_body;
    proxy_temp_path       $temp_dir/proxy;
    fastcgi_temp_path     $temp_dir/fastcgi;
    uwsgi_temp_path       $temp_dir/uwsgi;
    scgi_temp_path        $temp_dir/scgi;

    include $include_path;
}
EOF
}

_nginx_migrate_legacy_install() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
      echo "-> Stopping system nginx (port conflict with packages install)..."
      _nginx_sudo systemctl stop nginx 2>/dev/null || true
    fi
  fi

  local legacy_conf="$NGINX_LEGACY_SITES_AVAILABLE/${NGINX_CONF_NAME}.conf"
  local legacy_link="$NGINX_LEGACY_SITES_ENABLED/${NGINX_CONF_NAME}.conf"

  if [[ -f "$legacy_conf" || -L "$legacy_link" ]]; then
    echo "-> Removing legacy Ergo MS config from /etc/nginx..."
    _nginx_sudo rm -f "$legacy_conf" "$legacy_link" 2>/dev/null || true
    echo "[OK] Legacy /etc/nginx config removed"
  fi
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

  local -a args=(
    "$script"
    --template "$template"
    --root "$root"
    --server-name "$server_name"
    --listen-host "$listen_host"
    --listen-port "$listen_port"
    --use-https "$use_ssl"
  )
  if [[ "$use_ssl" == "true" ]]; then
    args+=(
      --ssl-cert "${ERGO_SSL_CERT:-/etc/ssl/certs/ssl-cert-snakeoil.pem}"
      --ssl-key "${ERGO_SSL_KEY:-/etc/ssl/private/ssl-cert-snakeoil.key}"
    )
  fi

  "$py" "${args[@]}"
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

_nginx_unit_content() {
  local root="$1"
  local nginx_bin main_conf nginx_dir
  nginx_bin="$(_nginx_binary "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  nginx_dir="$(_nginx_packages_dir "$root")"

  cat <<UNIT
[Unit]
Description=Ergo MS - Nginx
After=network.target

[Service]
Type=forking
PIDFile=$nginx_dir/logs/nginx.pid
WorkingDirectory=$nginx_dir
ExecStartPre=$nginx_bin -t -c $main_conf
ExecStart=$nginx_bin -c $main_conf
ExecReload=$nginx_bin -s reload -c $main_conf
ExecStop=$nginx_bin -s quit -c $main_conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
}

nginx_install_service() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "[ERROR] Nginx not installed. Run: ergoms install-nginx" >&2
    return 1
  fi

  nginx_stop_service "$root" 2>/dev/null || true

  local content
  content="$(_nginx_unit_content "$root")"
  install_unit "$NGINX_SERVICE_NAME" "$content"
  _nginx_sudo systemctl daemon-reload
  enable_and_start "${NGINX_SERVICE_NAME}.service"
  echo "[OK] Nginx systemd service installed and started"
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

  _nginx_migrate_legacy_install

  if ! _nginx_install_binary "$root"; then
    return 1
  fi

  local template
  template="$(_nginx_select_template "$root" "$use_ssl")"
  if [[ ! -f "$template" ]]; then
    echo "[ERROR] Template not found: $template" >&2
    return 1
  fi

  local dist_path="$root/core/client/dist"
  if [[ ! -f "$dist_path/index.html" ]]; then
    echo "[ERROR] $dist_path/index.html not found." >&2
    echo "  Nginx serves production build, not Vite dev. Run:" >&2
    echo "    ergoms client-build" >&2
    echo "  Then: ergoms install-nginx" >&2
    return 1
  fi

  local rendered site_conf
  rendered="$(_nginx_render_template "$template" "$root" "$server_name" "$listen_host" "$listen_port" "$use_ssl")"
  site_conf="$(_nginx_site_conf "$root")"
  printf '%s\n' "$rendered" >"$site_conf"
  echo "[OK] Config written: $site_conf"

  _nginx_write_main_conf "$root" "$site_conf"

  local nginx_bin main_conf nginx_dir
  nginx_bin="$(_nginx_binary "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  nginx_dir="$(_nginx_packages_dir "$root")"

  echo "-> Testing nginx configuration..."
  if (cd "$nginx_dir" && "$nginx_bin" -t -c "$main_conf"); then
    echo "[OK] Configuration valid"
  else
    echo "[ERROR] nginx -t failed." >&2
    return 1
  fi

  nginx_install_service "$root"

  echo "[OK] Nginx installed and running"
  echo "    Path: $nginx_dir"
  echo "    Config: $site_conf"
  echo "    Logs: $nginx_dir/logs"
  if [[ "$use_ssl" == "true" ]]; then
    echo "    Listening: https://${server_name}:443"
  else
    echo "    Listening: http://${server_name}:${listen_port} (bind ${listen_host})"
  fi
}

nginx_uninstall() {
  local root="$1"
  local purge="${2:-false}"

  echo ""
  echo "=== Nginx: Uninstall ==="
  echo ""

  _nginx_migrate_legacy_install
  nginx_stop_service "$root" 2>/dev/null || true

  if [[ -f "$NGINX_UNIT_PATH" ]]; then
    echo "-> Removing nginx systemd unit..."
    if [[ $(id -u) -eq 0 ]]; then
      systemctl disable --now "${NGINX_SERVICE_NAME}.service" 2>/dev/null || true
      rm -f "$NGINX_UNIT_PATH"
      systemctl daemon-reload
    else
      sudo systemctl disable --now "${NGINX_SERVICE_NAME}.service" 2>/dev/null || true
      sudo rm -f "$NGINX_UNIT_PATH"
      sudo systemctl daemon-reload
    fi
    echo "[OK] Nginx systemd unit removed"
  fi

  local site_conf
  site_conf="$(_nginx_site_conf "$root")"
  if [[ -f "$site_conf" ]]; then
    rm -f "$site_conf"
    echo "[OK] Removed config: $site_conf"
  fi

  local nginx_dir
  nginx_dir="$(_nginx_packages_dir "$root")"
  if [[ "$purge" == "true" ]] && [[ -d "$nginx_dir" ]]; then
    rm -rf "$nginx_dir"
    echo "[OK] Removed: $nginx_dir"
  elif [[ -d "$nginx_dir" ]]; then
    echo "[OK] Nginx stopped (binaries kept; use --purge to remove packages/nginx)"
  fi

  echo "[OK] Nginx uninstalled"
}

nginx_start_service() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "[ERROR] Nginx is not installed. Run: ergoms install-nginx" >&2
    return 1
  fi

  if [[ -f "$NGINX_UNIT_PATH" ]]; then
    if systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
      echo "[OK] Nginx service already running"
      return 0
    fi
    echo "-> Starting nginx service..."
    _nginx_sudo systemctl start "${NGINX_SERVICE_NAME}.service"
    echo "[OK] Nginx service started"
    return 0
  fi

  nginx_stop_service "$root" 2>/dev/null || true

  local nginx_bin main_conf nginx_dir
  nginx_bin="$(_nginx_binary "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  nginx_dir="$(_nginx_packages_dir "$root")"
  local pid_file="$nginx_dir/logs/nginx.pid"
  rm -f "$pid_file"

  echo "-> Starting nginx..."
  (cd "$nginx_dir" && "$nginx_bin" -c "$main_conf")
  sleep 2

  if [[ -f "$pid_file" ]] || pgrep -f "$nginx_bin" >/dev/null 2>&1; then
    echo "[OK] Nginx started"
    return 0
  fi

  echo "[ERROR] Nginx failed to start. Check logs: $nginx_dir/logs/error.log" >&2
  return 1
}

nginx_stop_service() {
  local root="${1:-}"

  if [[ -f "$NGINX_UNIT_PATH" ]] && systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
    echo "-> Stopping nginx service..."
    _nginx_sudo systemctl stop "${NGINX_SERVICE_NAME}.service"
    echo "[OK] Nginx service stopped"
    return 0
  fi

  if [[ -n "$root" ]] && _nginx_is_installed "$root"; then
    local nginx_bin main_conf nginx_dir pid_file
    nginx_bin="$(_nginx_binary "$root")"
    main_conf="$(_nginx_main_conf "$root")"
    nginx_dir="$(_nginx_packages_dir "$root")"
    pid_file="$nginx_dir/logs/nginx.pid"

    if [[ -x "$nginx_bin" ]]; then
      echo "-> Stopping nginx process..."
      (cd "$nginx_dir" && "$nginx_bin" -s quit -c "$main_conf" 2>/dev/null) || true
      sleep 1
    fi
    rm -f "$pid_file"
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    _nginx_sudo systemctl stop nginx 2>/dev/null || true
  fi

  pkill -f 'virtual_env/packages/nginx/sbin/nginx' 2>/dev/null || true
  echo "[OK] Nginx stopped"
}

nginx_reload_service() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "[ERROR] Nginx is not installed. Run: ergoms install-nginx" >&2
    return 1
  fi

  local nginx_bin main_conf nginx_dir
  nginx_bin="$(_nginx_binary "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  nginx_dir="$(_nginx_packages_dir "$root")"

  echo "-> Testing configuration..."
  if ! (cd "$nginx_dir" && "$nginx_bin" -t -c "$main_conf"); then
    echo "[ERROR] Configuration test failed. Not reloading." >&2
    return 1
  fi

  if [[ -f "$NGINX_UNIT_PATH" ]] && systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
    echo "-> Reloading nginx service..."
    _nginx_sudo systemctl reload "${NGINX_SERVICE_NAME}.service"
    echo "[OK] Nginx reloaded"
    return 0
  fi

  echo "-> Reloading nginx..."
  (cd "$nginx_dir" && "$nginx_bin" -s reload -c "$main_conf")
  echo "[OK] Nginx reloaded"
}

nginx_status_service() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "Nginx: Not installed"
    echo "  Expected path: $(_nginx_packages_dir "$root")"
    return 0
  fi

  local nginx_dir site_conf
  nginx_dir="$(_nginx_packages_dir "$root")"
  site_conf="$(_nginx_site_conf "$root")"

  echo ""
  echo "=== Nginx Status ==="

  if [[ -f "$NGINX_UNIT_PATH" ]]; then
    if systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
      echo "  Service ($NGINX_SERVICE_NAME): Running"
    else
      echo "  Service ($NGINX_SERVICE_NAME): Not running"
    fi
  elif pgrep -f "$nginx_dir/sbin/nginx" >/dev/null 2>&1; then
    echo "  Process: Running (PID: $(pgrep -f "$nginx_dir/sbin/nginx" | head -n1))"
  else
    echo "  Process: Not running"
  fi

  if [[ -f "$site_conf" ]]; then
    echo "  Config: Installed ($site_conf)"
  else
    echo "  Config: Not installed"
  fi

  echo "  Path: $nginx_dir"
  echo "  Logs: $nginx_dir/logs"
  echo ""
}

nginx_test_config() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "[ERROR] Nginx is not installed" >&2
    return 1
  fi

  local nginx_bin main_conf nginx_dir
  nginx_bin="$(_nginx_binary "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  nginx_dir="$(_nginx_packages_dir "$root")"
  (cd "$nginx_dir" && "$nginx_bin" -t -c "$main_conf")
}

export -f nginx_install
export -f nginx_install_service
export -f nginx_uninstall
export -f nginx_start_service
export -f nginx_stop_service
export -f nginx_reload_service
export -f nginx_status_service
export -f nginx_test_config
