#!/usr/bin/env bash
# TLS (Let's Encrypt) for ERGO MS on Linux

TLS_HOOK_NAME='99-ergo-ms-reload-nginx.sh'

_tls_config_dir() {
  local root="$1"
  echo "$root/virtual_env/packages/letsencrypt"
}

_tls_hook_dir() {
  local root="$1"
  echo "$(_tls_config_dir "$root")/renewal-hooks/deploy"
}

_tls_python() {
  local root="$1"
  local py="$root/virtual_env/python/bin/python"
  [[ -x "$py" ]] || py="python3"
  echo "$py"
}

_tls_cli() {
  local root="$1"
  shift
  "$(_tls_python "$root")" "$root/core/deployment/scripts/tls_cli.py" --root "$root" "$@"
}

_tls_resolve_domains() {
  local root="$1"
  ROOT="$root" "$(_tls_python "$root")" - <<'PY'
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(os.environ['ROOT']) / 'core/deployment/nginx'))
from tls_config import _read_env, resolve_domains

for domain in resolve_domains(_read_env(Path(os.environ['ROOT']) / '.env')):
    print(domain)
PY
}

_tls_read_env_value() {
  local root="$1"
  local key="$2"
  local env_file="$root/.env"
  [[ -f "$env_file" ]] || return 0
  grep -E "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
}

_tls_certbot_bin() {
  local root="$1"
  echo "$root/virtual_env/python/bin/certbot"
}

_tls_install_certbot() {
  local root="$1"
  local py certbot_bin pip_cache
  py="$(_tls_python "$root")"
  certbot_bin="$(_tls_certbot_bin "$root")"

  if [[ -x "$certbot_bin" ]]; then
    echo "[OK] certbot (venv): $($certbot_bin --version 2>&1 | head -1)"
    return 0
  fi

  if [[ ! -x "$py" ]]; then
    echo "[ERROR] Нет virtual_env/python. Выполните: ergoms setup" >&2
    return 1
  fi

  pip_cache="$root/virtual_env/cache/pip"
  mkdir -p "$pip_cache"
  echo "-> Установка certbot в virtual_env/python (pip, без пакетов ОС)..."
  if ! PIP_CACHE_DIR="$pip_cache" "$py" -m pip install --upgrade 'certbot>=3.0,<5'; then
    echo "[ERROR] Не удалось установить certbot в venv" >&2
    return 1
  fi

  if [[ -x "$certbot_bin" ]]; then
    echo "[OK] certbot установлен: $($certbot_bin --version 2>&1 | head -1)"
    return 0
  fi
  echo "[ERROR] certbot не появился в $certbot_bin после pip install" >&2
  return 1
}

_tls_install_renewal_hook() {
  local root="$1"
  local template="$root/core/deployment/nginx/hooks/certbot-deploy-reload-nginx.sh"
  local hook_dir
  hook_dir="$(_tls_hook_dir "$root")"
  local target="$hook_dir/$TLS_HOOK_NAME"

  if [[ ! -f "$template" ]]; then
    echo "[WARNING] Hook template не найден: $template" >&2
    return 1
  fi

  mkdir -p "$hook_dir"
  local content
  content="$(cat "$template")"
  content="${content//__ERGO_ROOT__/$root}"

  printf '%s\n' "$content" > "$target"
  chmod 0755 "$target" 2>/dev/null || true
  echo "[OK] deploy-hook обновления certbot: $target"
}

_tls_enable_timer() {
  echo "[INFO] Автообновление: ergoms renew-tls (или планировщик ОС). Системный certbot.timer не используется — config-dir в проекте."
}

tls_install() {
  local root="$1"
  local domain_override="${2:-}"
  local email_override="${3:-}"
  local staging="${4:-false}"

  _nginx_read_env "$root"

  if ! _tls_cli "$root" validate; then
    echo "[WARNING] Проверьте .env вручную: NGINX_ENABLED=true, домены и ERGO_TLS_EMAIL" >&2
    return 1
  fi

  local -a domains=()
  if [[ -n "$domain_override" ]]; then
    domains=("$domain_override")
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] && domains+=("$line")
    done < <(_tls_resolve_domains "$root")
  fi

  local primary="${domains[0]}"
  local email
  if [[ -n "$email_override" ]]; then
    email="$email_override"
  else
    email="$(_tls_read_env_value "$root" ERGO_TLS_EMAIL)"
  fi

  local webroot
  webroot="$(_tls_read_env_value "$root" ERGO_TLS_WEBROOT)"
  [[ -n "$webroot" ]] || webroot="$root/virtual_env/packages/certbot/webroot"

  local config_dir work_dir logs_dir
  config_dir="$(_tls_config_dir "$root")"
  work_dir="$config_dir/work"
  logs_dir="$config_dir/logs"

  echo ""
  echo "=== TLS: установка Let's Encrypt ==="
  echo "    Домены: ${domains[*]}"
  echo "    Email:  $email"
  echo "    Webroot: $webroot"
  echo "    Config:  $config_dir"
  echo ""

  if ! _tls_install_certbot "$root"; then
    return 1
  fi

  mkdir -p "$webroot" "$config_dir" "$work_dir" "$logs_dir"

  if [[ ! -f "$root/core/client/dist/index.html" ]]; then
    echo "[ERROR] $root/core/client/dist/index.html не найден. Выполните: ergoms client-build" >&2
    return 1
  fi

  _nginx_read_env "$root"
  _nginx_resolve_env "$root"

  echo "-> Установка HTTP nginx (ACME webroot)..."
  if ! nginx_install "$root" "$primary" 80 false; then
    echo "[ERROR] Установка HTTP nginx завершилась с ошибкой (нужна для проверки сертификата)" >&2
    return 1
  fi

  local -a certbot_args=(
    certonly
    --config-dir "$config_dir"
    --work-dir "$work_dir"
    --logs-dir "$logs_dir"
    --webroot
    -w "$webroot"
    --email "$email"
    --agree-tos
    --non-interactive
    --keep-until-expiring
  )

  if [[ "$staging" == "true" ]]; then
    certbot_args+=(--staging)
    echo "[WARNING] Используется STAGING Let's Encrypt (браузеры не доверяют сертификату)"
  fi

  local domain
  for domain in "${domains[@]}"; do
    certbot_args+=(-d "$domain")
  done

  echo "-> Запрос сертификата..."
  local certbot_bin
  certbot_bin="$(_tls_certbot_bin "$root")"
  if ! "$certbot_bin" "${certbot_args[@]}"; then
    echo "[ERROR] certbot завершился с ошибкой. Проверьте DNS, порт 80, and http://$primary/.well-known/" >&2
    return 1
  fi

  echo "-> Рекомендуемые переменные для .env:"
  _tls_cli "$root" suggest-env --domain "$primary" || true

  _nginx_read_env "$root"

  echo "-> Установка HTTPS nginx..."
  if ! nginx_install "$root" "$primary" 443 true; then
    return 1
  fi

  _tls_install_renewal_hook "$root"
  _tls_enable_timer

  echo ""
  echo "[OK] TLS установлен для $primary"
  _tls_cli "$root" status --domain "$primary"
  echo ""
  echo "    Сайт: https://$primary"
  echo "    Обновление: ergoms renew-tls"
  echo "    Статус: ergoms status-tls"
}

tls_renew() {
  local root="$1"
  local dry_run="${2:-false}"

  echo ""
  echo "=== TLS: обновление сертификатов ==="
  echo ""

  if ! _tls_install_certbot "$root"; then
    echo "[ERROR] certbot (venv) недоступен. Выполните: ergoms setup && ergoms install-tls" >&2
    return 1
  fi

  _tls_install_renewal_hook "$root" 2>/dev/null || true

  local config_dir work_dir logs_dir
  config_dir="$(_tls_config_dir "$root")"
  work_dir="$config_dir/work"
  logs_dir="$config_dir/logs"
  local certbot_bin
  certbot_bin="$(_tls_certbot_bin "$root")"

  local -a args=(
    renew
    --config-dir "$config_dir"
    --work-dir "$work_dir"
    --logs-dir "$logs_dir"
  )
  if [[ "$dry_run" == "true" ]]; then
    args+=(--dry-run)
    echo "-> Пробный запуск (без изменений)..."
  else
    echo "-> Обновление при необходимости..."
  fi

  if "$certbot_bin" "${args[@]}"; then
    echo "[OK] certbot renew завершён"
    if [[ "$dry_run" != "true" ]]; then
      nginx_reload_service "$root" || true
      _tls_cli "$root" status || true
    fi
    return 0
  fi

  echo "[ERROR] certbot renew завершился с ошибкой" >&2
  return 1
}

tls_status() {
  local root="$1"
  _tls_cli "$root" status
}

export -f tls_install
export -f tls_renew
export -f tls_status
