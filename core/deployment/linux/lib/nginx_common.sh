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
    echo "[WARNING] ERGO_SSL_CERT / ERGO_SSL_KEY не заданы. HTTPS не пройдёт nginx -t." >&2
    return 0
  fi
  if [[ "$cert" == *snakeoil* || "$key" == *snakeoil* ]]; then
    echo "[WARNING] Используется самоподписанный сертификат. Для production — Let's Encrypt." >&2
    return 0
  fi
  if [[ ! -f "$cert" ]]; then
    echo "[WARNING] SSL-сертификат не найден: $cert" >&2
  fi
  if [[ ! -f "$key" ]]; then
    echo "[WARNING] Приватный ключ SSL не найден: $key" >&2
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
