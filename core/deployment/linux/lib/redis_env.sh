#!/usr/bin/env bash
# Effective Redis: REDIS_ENABLED или ERGO_BROKER=redis (без Django).

is_redis_enabled() {
  local root="${1:-}"
  local env_file line value
  local redis_enabled=''
  local ergo_broker='local'

  if [[ -z "$root" ]]; then
    root="$(detect_project_root 2>/dev/null || echo '')"
  fi
  [[ -n "$root" ]] || return 1

  env_file="$root/.env"
  [[ -f "$env_file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^REDIS_ENABLED=(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value//\"/}"
      value="${value//\'/}"
      value="$(_ergoms_trim "$value")"
      value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
      case "$value" in
        1|true|yes|on) redis_enabled=1 ;;
        *) redis_enabled=0 ;;
      esac
    elif [[ "$line" =~ ^ERGO_BROKER=(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value//\"/}"
      value="${value//\'/}"
      ergo_broker="$(_ergoms_trim "$value")"
      ergo_broker="$(printf '%s' "$ergo_broker" | tr '[:upper:]' '[:lower:]')"
    fi
  done < "$env_file"

  if [[ -n "$redis_enabled" ]]; then
    [[ "$redis_enabled" == "1" ]] && return 0
    return 1
  fi
  [[ "$ergo_broker" == "redis" ]] && return 0
  return 1
}

export -f is_redis_enabled
