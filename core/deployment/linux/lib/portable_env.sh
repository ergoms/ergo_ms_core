#!/usr/bin/env bash
# Чтение PORTABLE_*_ENABLED и прочих ключей из .env + env/*.env (без Django).

_ergo_env_value() {
  local root="$1"
  local name="$2"
  local found=""
  local env_file line value
  local -a files=()

  [[ -f "$root/.env" ]] && files+=("$root/.env")
  if [[ -d "$root/env" ]]; then
    while IFS= read -r env_file; do
      [[ -n "$env_file" ]] && files+=("$env_file")
    done < <(find "$root/env" -maxdepth 1 -type f -name '*.env' ! -name '*.example' 2>/dev/null | sort)
  fi

  for env_file in "${files[@]}"; do
    [[ -f "$env_file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^${name}=(.*)$ ]] || continue
      value="${BASH_REMATCH[1]}"
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      value="$(_ergoms_trim "$value")"
      found="$value"
    done < "$env_file"
  done

  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi
  return 1
}

_ergo_env_truthy() {
  local root="$1"
  local name="$2"
  local default="${3:-false}"
  local value
  if value="$(_ergo_env_value "$root" "$name")"; then
    value="$(echo "$value" | tr '[:upper:]' '[:lower:]')"
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
