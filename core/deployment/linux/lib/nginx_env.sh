#!/usr/bin/env bash
# Effective nginx: NGINX_ENABLED или ERGO_PROXY=nginx (без Django).

is_nginx_enabled() {
  local root="${1:-}"
  local env_file line value
  local nginx_enabled=''
  local ergo_proxy='none'

  if [[ -z "$root" ]]; then
    root="$(detect_project_root 2>/dev/null || echo '')"
  fi
  [[ -n "$root" ]] || return 1

  env_file="$root/.env"
  [[ -f "$env_file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^NGINX_ENABLED=(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value//\"/}"
      value="${value//\'/}"
      value="$(_ergoms_trim "$value")"
      value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
      case "$value" in
        1|true|yes|on) nginx_enabled=1 ;;
        *) nginx_enabled=0 ;;
      esac
    elif [[ "$line" =~ ^ERGO_PROXY=(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value//\"/}"
      value="${value//\'/}"
      ergo_proxy="$(_ergoms_trim "$value")"
      ergo_proxy="$(printf '%s' "$ergo_proxy" | tr '[:upper:]' '[:lower:]')"
    fi
  done < "$env_file"

  if [[ -n "$nginx_enabled" ]]; then
    [[ "$nginx_enabled" == "1" ]] && return 0
    return 1
  fi
  [[ "$ergo_proxy" == "nginx" ]] && return 0
  return 1
}

nginx_skip_client_message() {
  local root="${1:-}"
  local public_host='<NGINX_PUBLIC_HOST>'

  if [[ -f "$root/.env" ]]; then
    public_host="$(grep -E '^NGINX_PUBLIC_HOST=' "$root/.env" 2>/dev/null | head -1 | cut -d= -f2-)"
    public_host="${public_host#"${public_host%%[![:space:]]*}"}"
    public_host="${public_host%"${public_host##*[![:space:]]}"}"
    public_host="${public_host#\"}"
    public_host="${public_host%\"}"
    public_host="${public_host#\'}"
    public_host="${public_host%\'}"
    [[ -z "$public_host" ]] && public_host='<NGINX_PUBLIC_HOST>'
  fi

  echo "[OK] ergo_ms_client_dev пропущен (ERGO_PROXY=nginx / NGINX_ENABLED, клиент отдаётся через nginx)"
  echo "  Откройте: http://${public_host}"
  echo "  После изменений UI: ergoms client-build && ergoms reload-nginx"
}

export -f is_nginx_enabled
export -f nginx_skip_client_message
