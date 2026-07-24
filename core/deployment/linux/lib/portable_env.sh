#!/usr/bin/env bash
# Чтение PORTABLE_*_ENABLED из .env (без Django).

_ergo_env_value() {
  local root="$1"
  local name="$2"
  local env_file="$root/.env"
  local line value
  [[ -f "$env_file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^${name}=(.*)$ ]] || continue
    value="${BASH_REMATCH[1]}"
    value="${value//\"/}"
    value="${value//\'/}"
    value="$(echo "$value" | tr '[:upper:]' '[:lower:]' | xargs)"
    echo "$value"
    return 0
  done < "$env_file"
  return 1
}

_ergo_env_truthy() {
  local root="$1"
  local name="$2"
  local default="${3:-false}"
  local value
  if value="$(_ergo_env_value "$root" "$name")"; then
    case "$value" in
      1|true|yes|on) return 0 ;;
      *) return 1 ;;
    esac
  fi
  case "$(echo "$default" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
  esac
  return 1
}

is_portable_python_enabled() {
  local root="$1"
  _ergo_env_truthy "$root" 'PORTABLE_PYTHON_ENABLED' 'true'
}

is_portable_nodejs_enabled() {
  local root="$1"
  _ergo_env_truthy "$root" 'PORTABLE_NODEJS_ENABLED' 'true'
}

export -f _ergo_env_value _ergo_env_truthy
export -f is_portable_python_enabled is_portable_nodejs_enabled
