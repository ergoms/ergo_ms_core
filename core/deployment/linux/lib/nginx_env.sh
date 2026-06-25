#!/usr/bin/env bash
# Чтение NGINX_ENABLED из .env (без Django / без циклических импортов).

is_nginx_enabled() {
  local root="${1:-}"
  local env_file line value

  if [[ -z "$root" ]]; then
    root="$(detect_project_root 2>/dev/null || echo '')"
  fi
  [[ -n "$root" ]] || return 1

  env_file="$root/.env"
  [[ -f "$env_file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^NGINX_ENABLED=(.*)$ ]] || continue
    value="${BASH_REMATCH[1]}"
    value="${value//\"/}"
    value="${value//\'/}"
    value="$(echo "$value" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "$value" in
      1|true|yes) return 0 ;;
    esac
  done < "$env_file"
  return 1
}

nginx_skip_client_message() {
  local root="${1:-}"
  echo "[OK] ergo-client-dev skipped (NGINX_ENABLED=true, client is served via nginx)"
  echo "  Open: http://$(grep -E '^NGINX_PUBLIC_HOST=' "$root/.env" 2>/dev/null | cut -d= -f2- | tr -d \"'\" || echo '<NGINX_PUBLIC_HOST>')"
  echo "  After UI changes: ergoms client-build && ergoms reload-nginx"
}

export -f is_nginx_enabled
export -f nginx_skip_client_message
