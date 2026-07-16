. "$(dirname "${BASH_SOURCE[0]}")/nginx_common.sh"

_nginx_install_build_deps() {
  echo "-> Установка зависимостей сборки..."
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
  echo "[ERROR] Не удалось определить менеджер пакетов для зависимостей сборки." >&2
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
  echo "[ERROR] Для загрузки nginx нужны curl или wget." >&2
  return 1
}

_nginx_install_binary() {
  local root="$1"
  local nginx_bin
  nginx_bin="$(_nginx_binary "$root")"

  if [[ -x "$nginx_bin" ]]; then
    echo "[OK] Nginx уже установлен: $nginx_bin"
    "$nginx_bin" -v 2>&1 | sed 's/^/[OK] /'
    return 0
  fi

  if ! _nginx_install_build_deps; then
    echo "[ERROR] Не удалось установить зависимости сборки." >&2
    return 1
  fi

  local nginx_dir tarball src_dir build_dir jobs pcre_flag
  nginx_dir="$(_nginx_packages_dir "$root")"
  build_dir="$(mktemp -d)"
  tarball="$build_dir/nginx-${NGINX_VERSION}.tar.gz"
  src_dir="$build_dir/nginx-${NGINX_VERSION}"
  jobs="$(nproc 2>/dev/null || echo 2)"
  pcre_flag="$(_nginx_configure_pcre_flag)"

  echo "-> Загрузка nginx ${NGINX_VERSION}..."
  if ! _nginx_download_tarball "$tarball"; then
    rm -rf "$build_dir"
    echo "[ERROR] Не удалось загрузить архив nginx." >&2
    return 1
  fi

  echo "-> Распаковка исходников..."
  tar -xzf "$tarball" -C "$build_dir"

  if [[ ! -d "$src_dir" ]]; then
    rm -rf "$build_dir"
    echo "[ERROR] Каталог исходников nginx не найден." >&2
    return 1
  fi

  mkdir -p "$nginx_dir/logs" "$nginx_dir/temp" "$nginx_dir/conf"

  echo "-> Конфигурация nginx (prefix: $nginx_dir)..."
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
    echo "[ERROR] nginx ./configure завершился с ошибкой." >&2
    return 1
  fi

  echo "-> Сборка nginx..."
  if ! (cd "$src_dir" && make -j"$jobs"); then
    rm -rf "$build_dir"
    echo "[ERROR] nginx make завершился с ошибкой." >&2
    return 1
  fi

  echo "-> Установка nginx в $nginx_dir..."
  if ! (cd "$src_dir" && make install); then
    rm -rf "$build_dir"
    echo "[ERROR] nginx make install завершился с ошибкой." >&2
    return 1
  fi

  rm -rf "$build_dir"

  if [[ -x "$nginx_bin" ]]; then
    echo "[OK] Nginx установлен в $nginx_dir"
    "$nginx_bin" -v 2>&1 | sed 's/^/[OK] /'
    return 0
  fi

  echo "[ERROR] Исполняемый файл nginx не найден после установки: $nginx_bin" >&2
  return 1
}

_nginx_log_env() {
  local root="$1"
  shift
  local py="$root/virtual_env/python/bin/python"
  local script="$root/core/deployment/scripts/log_env.py"
  if [[ -x "$py" && -f "$script" ]]; then
    "$py" "$script" "$@" "$root" 2>/dev/null
  fi
}

_nginx_write_main_conf() {
  local root="$1"
  local site_conf="$2"
  local main_conf nginx_dir runtime_logs_dir central_logs_dir temp_dir include_path
  local nginx_error_level error_log_path access_log_path access_log_line
  nginx_dir="$(_nginx_packages_dir "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  runtime_logs_dir="$nginx_dir/logs"
  central_logs_dir="$(_nginx_log_env "$root" logs-dir)"
  [[ -z "$central_logs_dir" ]] && central_logs_dir="$root/logs"
  nginx_error_level="$(_nginx_log_env "$root" nginx-error-level)"
  [[ -z "$nginx_error_level" ]] && nginx_error_level="warn"
  error_log_path="$(_nginx_log_env "$root" path NGINX_ERROR)"
  access_log_path="$(_nginx_log_env "$root" path NGINX_ACCESS)"
  [[ -z "$error_log_path" ]] && error_log_path="$central_logs_dir/nginx-error.log"
  [[ -z "$access_log_path" ]] && access_log_path="$central_logs_dir/nginx-access.log"
  if [[ "$(_nginx_log_env "$root" nginx-access-enabled)" == "false" ]]; then
    access_log_line="access_log off;"
  else
    access_log_line="access_log $access_log_path;"
  fi
  temp_dir="$nginx_dir/temp"
  include_path="$site_conf"

  mkdir -p "$nginx_dir/conf" "$runtime_logs_dir" "$temp_dir" "$central_logs_dir"

  cat >"$main_conf" <<EOF
worker_processes auto;

error_log $error_log_path $nginx_error_level;
pid       $runtime_logs_dir/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    $access_log_line

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
      echo "-> Остановка системного nginx (конфликт порта с packages install)..."
      _nginx_sudo systemctl stop nginx 2>/dev/null || true
    fi
  fi

  local legacy_conf="$NGINX_LEGACY_SITES_AVAILABLE/${NGINX_CONF_NAME}.conf"
  local legacy_link="$NGINX_LEGACY_SITES_ENABLED/${NGINX_CONF_NAME}.conf"

  if [[ -f "$legacy_conf" || -L "$legacy_link" ]]; then
    echo "-> Удаление устаревшего конфига Ergo MS из /etc/nginx..."
    _nginx_sudo rm -f "$legacy_conf" "$legacy_link" 2>/dev/null || true
    echo "[OK] Устаревший конфиг /etc/nginx удалён"
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
    echo "[ERROR] render_nginx_config.py не найден" >&2
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

_nginx_resolve_env() {
  local root="$1"
  local py="$root/virtual_env/python/bin/python"
  local script="$root/core/deployment/scripts/resolve_env.py"
  [[ -x "$py" && -f "$script" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    [[ -n "$key" ]] && export "$key=$value"
  done < <("$py" "$script" --root "$root" --scope nginx 2>/dev/null || true)
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
    echo "[ERROR] Nginx не установлен. Выполните: ergoms install-nginx" >&2
    return 1
  fi

  nginx_stop_service "$root" quiet 2>/dev/null || true

  local content
  content="$(_nginx_unit_content "$root")"
  install_unit "$NGINX_SERVICE_NAME" "$content"
  _nginx_sudo systemctl daemon-reload
  enable_and_start "${NGINX_SERVICE_NAME}.service"
  echo "[OK] Служба systemd nginx установлена и запущена"
}

nginx_install() {
  local root="$1"
  _nginx_read_env "$root"
  _nginx_resolve_env "$root"
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
  echo "=== Nginx: установка ==="
  echo ""

  _nginx_migrate_legacy_install

  if ! _nginx_install_binary "$root"; then
    return 1
  fi

  local template
  template="$(_nginx_select_template "$root" "$use_ssl")"
  if [[ ! -f "$template" ]]; then
    echo "[ERROR] Шаблон не найден: $template" >&2
    return 1
  fi

  local dist_path="$root/core/client/dist"
  if [[ ! -f "$dist_path/index.html" ]]; then
    echo "[ERROR] $dist_path/index.html не найден." >&2
    echo "  Nginx serves production build, not Vite dev. Run:" >&2
    echo "    ergoms client-build" >&2
    echo "  Then: ergoms install-nginx" >&2
    return 1
  fi

  local rendered site_conf
  rendered="$(_nginx_render_template "$template" "$root" "$server_name" "$listen_host" "$listen_port" "$use_ssl")"
  site_conf="$(_nginx_site_conf "$root")"
  printf '%s\n' "$rendered" >"$site_conf"
  echo "[OK] Конфиг записан: $site_conf"

  _nginx_write_main_conf "$root" "$site_conf"

  local nginx_bin main_conf nginx_dir
  nginx_bin="$(_nginx_binary "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  nginx_dir="$(_nginx_packages_dir "$root")"

  echo "-> Проверка конфигурации nginx..."
  if (cd "$nginx_dir" && "$nginx_bin" -t -c "$main_conf"); then
    echo "[OK] Конфигурация корректна"
  else
    echo "[ERROR] nginx -t завершился с ошибкой." >&2
    return 1
  fi

  nginx_install_service "$root"

  echo "[OK] Nginx установлен и запущен"
  echo "    Path: $nginx_dir"
  echo "    Config: $site_conf"
  echo "    Логи: $nginx_dir/logs"
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
  echo "=== Nginx: удаление ==="
  echo ""

  _nginx_migrate_legacy_install
  nginx_stop_service "$root" quiet 2>/dev/null || true

  if [[ -f "$NGINX_UNIT_PATH" ]]; then
    echo "-> Удаление unit systemd nginx..."
    if [[ $(id -u) -eq 0 ]]; then
      systemctl disable --now "${NGINX_SERVICE_NAME}.service" 2>/dev/null || true
      rm -f "$NGINX_UNIT_PATH"
      systemctl daemon-reload
    else
      sudo systemctl disable --now "${NGINX_SERVICE_NAME}.service" 2>/dev/null || true
      sudo rm -f "$NGINX_UNIT_PATH"
      sudo systemctl daemon-reload
    fi
    echo "[OK] Unit systemd nginx удалён"
  fi

  local site_conf
  site_conf="$(_nginx_site_conf "$root")"
  if [[ -f "$site_conf" ]]; then
    rm -f "$site_conf"
    echo "[OK] Конфиг удалён: $site_conf"
  fi

  local nginx_dir
  nginx_dir="$(_nginx_packages_dir "$root")"
  if [[ "$purge" == "true" ]] && [[ -d "$nginx_dir" ]]; then
    rm -rf "$nginx_dir"
    echo "[OK] Удалено: $nginx_dir"
  elif [[ -d "$nginx_dir" ]]; then
    echo "[OK] Nginx остановлен (бинарники сохранены; --purge удалит packages/nginx)"
  fi

  echo "[OK] Nginx удалён"
}

nginx_start_service() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "[ERROR] Nginx не установлен. Выполните: ergoms install-nginx" >&2
    return 1
  fi

  if [[ -f "$NGINX_UNIT_PATH" ]]; then
    if systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
      echo "[OK] Служба nginx уже запущена"
      return 0
    fi
    echo "-> Запуск службы nginx..."
    _nginx_sudo systemctl start "${NGINX_SERVICE_NAME}.service"
    echo "[OK] Служба nginx запущена"
    return 0
  fi

  nginx_stop_service "$root" quiet 2>/dev/null || true

  local nginx_bin main_conf nginx_dir
  nginx_bin="$(_nginx_binary "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  nginx_dir="$(_nginx_packages_dir "$root")"
  local pid_file="$nginx_dir/logs/nginx.pid"
  rm -f "$pid_file"

  echo "-> Запуск nginx..."
  (cd "$nginx_dir" && "$nginx_bin" -c "$main_conf")
  sleep 2

  if [[ -f "$pid_file" ]] || pgrep -f "$nginx_bin" >/dev/null 2>&1; then
    echo "[OK] Nginx запущен"
    return 0
  fi

  echo "[ERROR] Nginx не запустился. Проверьте логи: $(
    _nginx_log_env "$root" path NGINX_ERROR
  )" >&2
  return 1
}

_nginx_remove_stale_pid_file() {
  local root="${1:-}"
  [[ -z "$root" ]] && return 0
  _nginx_is_installed "$root" || return 0

  local pid_file
  pid_file="$(_nginx_packages_dir "$root")/logs/nginx.pid"
  [[ -f "$pid_file" ]] || return 0

  local pid
  pid="$(tr -d '[:space:]' <"$pid_file" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pid_file"
    fi
    return 0
  fi
  rm -f "$pid_file"
}

_nginx_wait_stopped() {
  local root="${1:-}"
  local timeout_sec="${2:-10}"
  local i max=$((timeout_sec * 2))

  for ((i = 0; i < max; i++)); do
    _nginx_remove_stale_pid_file "$root"
    if ! _nginx_is_running "$root"; then
      return 0
    fi
    sleep 0.5
  done

  _nginx_remove_stale_pid_file "$root"
  _nginx_is_running "$root" && return 1
  return 0
}

_nginx_force_stop_processes() {
  pkill -f 'virtual_env/packages/nginx/sbin/nginx' 2>/dev/null || true
  pkill -f 'virtual_env/packages/nginx/nginx.exe' 2>/dev/null || true
}

_nginx_is_running() {
  local root="${1:-}"

  _nginx_remove_stale_pid_file "$root"

  if [[ -f "$NGINX_UNIT_PATH" ]] && systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    return 0
  fi
  if [[ -n "$root" ]] && _nginx_is_installed "$root"; then
    local nginx_dir
    nginx_dir="$(_nginx_packages_dir "$root")"
    if pgrep -f "$nginx_dir/sbin/nginx" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if pgrep -f 'virtual_env/packages/nginx/sbin/nginx' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

nginx_stop_service() {
  local root="${1:-}"
  local quiet="${2:-}"

  _nginx_remove_stale_pid_file "$root"

  if ! _nginx_is_running "$root"; then
    [[ -z "$quiet" ]] && echo "[SKIP] Nginx не был запущен"
    return 0
  fi

  if [[ -f "$NGINX_UNIT_PATH" ]] && systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
    echo "-> Остановка службы nginx..."
    _nginx_sudo systemctl stop "${NGINX_SERVICE_NAME}.service"
    if ! _nginx_wait_stopped "$root" 15; then
      _nginx_force_stop_processes
      if ! _nginx_wait_stopped "$root" 5; then
        echo "[ERROR] Не удалось остановить службу nginx" >&2
        return 1
      fi
    fi
    echo "[OK] Служба nginx остановлена"
    return 0
  fi

  if [[ -n "$root" ]] && _nginx_is_installed "$root"; then
    local nginx_bin main_conf nginx_dir
    nginx_bin="$(_nginx_binary "$root")"
    main_conf="$(_nginx_main_conf "$root")"
    nginx_dir="$(_nginx_packages_dir "$root")"

    if [[ -x "$nginx_bin" ]]; then
      echo "-> Остановка процесса nginx..."
      (cd "$nginx_dir" && "$nginx_bin" -s quit -c "$main_conf" 2>/dev/null) || true
      if _nginx_wait_stopped "$root" 8; then
        [[ -z "$quiet" ]] && echo "[OK] Nginx остановлен"
        return 0
      fi
    fi
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
    _nginx_sudo systemctl stop nginx 2>/dev/null || true
  fi

  _nginx_force_stop_processes

  if ! _nginx_wait_stopped "$root" 5; then
    echo "[ERROR] Не удалось остановить nginx" >&2
    return 1
  fi
  [[ -z "$quiet" ]] && echo "[OK] Nginx остановлен"
}

nginx_reload_service() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "[ERROR] Nginx не установлен. Выполните: ergoms install-nginx" >&2
    return 1
  fi

  local nginx_bin main_conf nginx_dir
  nginx_bin="$(_nginx_binary "$root")"
  main_conf="$(_nginx_main_conf "$root")"
  nginx_dir="$(_nginx_packages_dir "$root")"

  echo "-> Проверка конфигурации..."
  if ! (cd "$nginx_dir" && "$nginx_bin" -t -c "$main_conf"); then
    echo "[ERROR] Проверка конфигурации завершилась с ошибкой. Перезагрузка не выполнена." >&2
    return 1
  fi

  if [[ -f "$NGINX_UNIT_PATH" ]] && systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
    echo "-> Перезагрузка службы nginx..."
    _nginx_sudo systemctl reload "${NGINX_SERVICE_NAME}.service"
    echo "[OK] Nginx перезагружен"
    return 0
  fi

  echo "-> Перезагрузка nginx..."
  (cd "$nginx_dir" && "$nginx_bin" -s reload -c "$main_conf")
  echo "[OK] Nginx перезагружен"
}

nginx_status_service() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "Nginx: не установлен"
    echo "  Expected path: $(_nginx_packages_dir "$root")"
    return 0
  fi

  local nginx_dir site_conf
  nginx_dir="$(_nginx_packages_dir "$root")"
  site_conf="$(_nginx_site_conf "$root")"

  echo ""
  echo "=== Статус Nginx ==="

  if [[ -f "$NGINX_UNIT_PATH" ]]; then
    if systemctl is-active --quiet "${NGINX_SERVICE_NAME}.service" 2>/dev/null; then
      echo "  Service ($NGINX_SERVICE_NAME): Running"
    else
      echo "  Service ($NGINX_SERVICE_NAME): Not running"
    fi
  elif pgrep -f "$nginx_dir/sbin/nginx" >/dev/null 2>&1; then
    echo "  Process: Запущен (PID: $(pgrep -f "$nginx_dir/sbin/nginx" | head -n1))"
  else
    echo "  Process: Not running"
  fi

  if [[ -f "$site_conf" ]]; then
    echo "  Config: Installed ($site_conf)"
  else
    echo "  Config: Not installed"
  fi

  echo "  Path: $nginx_dir"
  echo "  Логи: $nginx_dir/logs"
  echo ""
}

nginx_test_config() {
  local root="$1"
  if ! _nginx_is_installed "$root"; then
    echo "[ERROR] Nginx не установлен" >&2
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
