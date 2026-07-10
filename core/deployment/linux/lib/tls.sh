#!/usr/bin/env bash
# TLS (Let's Encrypt) for ERGO MS on Linux

TLS_HOOK_NAME='99-ergo-ms-reload-nginx.sh'
TLS_HOOK_DIR='/etc/letsencrypt/renewal-hooks/deploy'

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

_tls_set_env_value() {
  local root="$1"
  local key="$2"
  local value="$3"
  ROOT="$root" KEY="$key" VALUE="$value" "$(_tls_python "$root")" - <<'PY'
import os
import re
from pathlib import Path

root = Path(os.environ['ROOT'])
key = os.environ['KEY']
value = os.environ['VALUE']
env_path = root / '.env'
content = env_path.read_text(encoding='utf-8') if env_path.is_file() else ''
pattern = re.compile(rf'^{re.escape(key)}=.*$', re.MULTILINE)
line = f'{key}={value}'
if pattern.search(content):
    content = pattern.sub(line, content, count=1)
else:
    if content and not content.endswith('\n'):
        content += '\n'
    content += line + '\n'
env_path.write_text(content, encoding='utf-8')
PY
}

_tls_read_env_value() {
  local root="$1"
  local key="$2"
  local env_file="$root/.env"
  [[ -f "$env_file" ]] || return 0
  grep -E "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
}

_tls_install_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    echo "[OK] certbot: $(certbot --version 2>&1 | head -1)"
    return 0
  fi

  echo "-> Installing certbot..."
  if command -v apt-get >/dev/null 2>&1; then
    _nginx_wait_for_apt_locks || return 1
    _nginx_sudo apt-get update -qq
    _nginx_sudo apt-get install -y -qq certbot
  elif command -v dnf >/dev/null 2>&1; then
    _nginx_sudo dnf install -y -q certbot
  elif command -v yum >/dev/null 2>&1; then
    _nginx_sudo yum install -y -q certbot
  elif command -v pacman >/dev/null 2>&1; then
    _nginx_sudo pacman -Sy --noconfirm certbot
  else
    echo "[ERROR] Cannot detect package manager. Install certbot manually." >&2
    return 1
  fi

  command -v certbot >/dev/null 2>&1
}

_tls_install_renewal_hook() {
  local root="$1"
  local template="$root/core/deployment/nginx/hooks/certbot-deploy-reload-nginx.sh"
  local target="$TLS_HOOK_DIR/$TLS_HOOK_NAME"

  if [[ ! -f "$template" ]]; then
    echo "[WARN] Hook template not found: $template" >&2
    return 1
  fi

  _nginx_sudo mkdir -p "$TLS_HOOK_DIR"
  local content
  content="$(cat "$template")"
  content="${content//__ERGO_ROOT__/$root}"

  local tmp_file
  tmp_file="$(mktemp)"
  printf '%s\n' "$content" > "$tmp_file"
  _nginx_sudo install -m 0755 "$tmp_file" "$target"
  rm -f "$tmp_file"
  echo "[OK] Renewal deploy-hook: $target"
}

_tls_enable_timer() {
  if command -v systemctl >/dev/null 2>&1; then
    _nginx_sudo systemctl enable certbot.timer 2>/dev/null || true
    _nginx_sudo systemctl start certbot.timer 2>/dev/null || true
    if systemctl is-active certbot.timer >/dev/null 2>&1; then
      echo "[OK] certbot.timer is active (auto-renewal scheduled)"
      return 0
    fi
    echo "[WARN] certbot.timer not available. Use: ergoms renew-tls" >&2
  fi
}

tls_install() {
  local root="$1"
  local domain_override="${2:-}"
  local email_override="${3:-}"
  local staging="${4:-false}"

  _nginx_read_env "$root"
  _tls_set_env_value "$root" NGINX_ENABLED true

  if [[ -n "$domain_override" ]]; then
    _tls_set_env_value "$root" NGINX_PUBLIC_HOST "$domain_override"
    _tls_set_env_value "$root" NGINX_SERVER_NAME "$domain_override"
  fi

  if [[ -n "$email_override" ]]; then
    _tls_set_env_value "$root" ERGO_TLS_EMAIL "$email_override"
  fi

  if ! _tls_cli "$root" validate; then
    return 1
  fi

  local -a domains=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && domains+=("$line")
  done < <(_tls_resolve_domains "$root")

  local primary="${domains[0]}"
  local email
  email="$(_tls_read_env_value "$root" ERGO_TLS_EMAIL)"

  local webroot
  webroot="$(_tls_read_env_value "$root" ERGO_TLS_WEBROOT)"
  [[ -n "$webroot" ]] || webroot='/var/www/certbot'

  echo ""
  echo "=== TLS: Let's Encrypt install ==="
  echo "    Domain(s): ${domains[*]}"
  echo "    Email:     $email"
  echo "    Webroot:   $webroot"
  echo ""

  if ! _tls_install_certbot; then
    return 1
  fi

  _nginx_sudo mkdir -p "$webroot"

  if [[ ! -f "$root/core/client/dist/index.html" ]]; then
    echo "[ERROR] $root/core/client/dist/index.html not found. Run: ergoms client-build" >&2
    return 1
  fi

  _nginx_ensure_env "$root"

  echo "-> Installing HTTP nginx (ACME webroot)..."
  if ! nginx_install "$root" "$primary" 80 false; then
    echo "[ERROR] HTTP nginx install failed (required for certificate validation)" >&2
    return 1
  fi

  local -a certbot_args=(
    certonly
    --webroot
    -w "$webroot"
    --email "$email"
    --agree-tos
    --non-interactive
    --keep-until-expiring
  )

  if [[ "$staging" == "true" ]]; then
    certbot_args+=(--staging)
    echo "[WARN] Using Let's Encrypt STAGING (not trusted by browsers)"
  fi

  local domain
  for domain in "${domains[@]}"; do
    certbot_args+=(-d "$domain")
  done

  echo "-> Requesting certificate..."
  if ! _nginx_sudo certbot "${certbot_args[@]}"; then
    echo "[ERROR] certbot failed. Check DNS, port 80, and http://$primary/.well-known/" >&2
    return 1
  fi

  echo "-> Updating .env for HTTPS..."
  if ! _tls_cli "$root" apply-env --domain "$primary"; then
    return 1
  fi

  _nginx_read_env "$root"

  echo "-> Installing HTTPS nginx..."
  if ! nginx_install "$root" "$primary" 443 true; then
    return 1
  fi

  _tls_install_renewal_hook "$root"
  _tls_enable_timer

  echo ""
  echo "[OK] TLS installed for $primary"
  _tls_cli "$root" status --domain "$primary"
  echo ""
  echo "    Site: https://$primary"
  echo "    Renew: ergoms renew-tls"
  echo "    Status: ergoms status-tls"
}

tls_renew() {
  local root="$1"
  local dry_run="${2:-false}"

  echo ""
  echo "=== TLS: Renew certificates ==="
  echo ""

  if ! command -v certbot >/dev/null 2>&1; then
    echo "[ERROR] certbot not installed. Run: ergoms install-tls" >&2
    return 1
  fi

  _tls_install_renewal_hook "$root" 2>/dev/null || true

  local -a args=(renew)
  if [[ "$dry_run" == "true" ]]; then
    args+=(--dry-run)
    echo "-> Dry run (no changes)..."
  else
    echo "-> Renewing if due..."
  fi

  if _nginx_sudo certbot "${args[@]}"; then
    echo "[OK] certbot renew completed"
    if [[ "$dry_run" != "true" ]]; then
      nginx_reload_service "$root" || true
      _tls_cli "$root" status || true
    fi
    return 0
  fi

  echo "[ERROR] certbot renew failed" >&2
  return 1
}

tls_status() {
  local root="$1"
  _tls_cli "$root" status
}

export -f tls_install
export -f tls_renew
export -f tls_status
