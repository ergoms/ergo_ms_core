#!/usr/bin/env bash
# Custom commands management
# Управление пользовательскими командами

_ergoms_export_tool_caches() {
  local root="$1"
  local pip_cache="$root/virtual_env/cache/pip"
  local poetry_cache="$root/virtual_env/cache/poetry"
  local npm_cache="$root/virtual_env/cache/npm"
  mkdir -p "$pip_cache" "$poetry_cache" "$npm_cache"
  export PIP_CACHE_DIR="$pip_cache"
  export POETRY_CACHE_DIR="$poetry_cache"
  export npm_config_cache="$npm_cache"
  export NPM_CONFIG_CACHE="$npm_cache"
}

_ergoms_prepend_nodejs_path() {
  local root="$1"
  local node_bin="$root/virtual_env/packages/nodejs/bin"
  if [[ -d "$node_bin" ]]; then
    export PATH="$node_bin:$PATH"
  fi
}

_ergoms_npm_bin() {
  local root="$1"
  local npm_bin="$root/virtual_env/packages/nodejs/bin/npm"
  if [[ -x "$npm_bin" ]]; then
    echo "$npm_bin"
  else
    echo "npm"
  fi
}

load_custom_commands() {
  local root="$1"
  
  declare -g -A CUSTOM_COMMANDS=()
  
  # Load core commands
  local config_file="$root/core/deployment/commands.conf"
  if [[ -f "$config_file" ]]; then
    while IFS='=' read -r key value; do
      # Skip comments and empty lines
      [[ "$key" =~ ^[[:space:]]*# ]] && continue
      [[ "$key" =~ ^[[:space:]]*$ ]] && continue
      [[ -z "$key" ]] && continue
      
      # Remove leading/trailing whitespace
      key=$(echo "$key" | xargs)
      value=$(echo "$value" | xargs)
      
      if [[ -n "$key" && -n "$value" ]]; then
        CUSTOM_COMMANDS["$key"]="$value"
      fi
    done < "$config_file"
  fi
  
  # Load module commands
  local modules_path="$root/modules"
  if [[ -d "$modules_path" ]]; then
    for module_dir in "$modules_path"/*; do
      if [[ -d "$module_dir" ]]; then
        local module_name=$(basename "$module_dir")
        local module_config="$module_dir/ergoms.conf"
        
        if [[ -f "$module_config" ]]; then
          while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ "$key" =~ ^[[:space:]]*$ ]] && continue
            [[ -z "$key" ]] && continue
            
            # Remove leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            
            if [[ -n "$key" && -n "$value" ]]; then
              # Add module prefix to command name
              local prefixed_name="${module_name}:${key}"
              CUSTOM_COMMANDS["$prefixed_name"]="$value"
            fi
          done < "$module_config"
        fi
      fi
    done
  fi
}

execute_command_string() {
  local root="$1"
  local cmd_string="$2"
  shift 2
  local user_args=("$@")
  
  # Mark as internal so wrappers in init_terminal.sh pass through
  export ERGOMS_INTERNAL=1
  
  # Parse command type (poetry:, api:, media_api:, npm:, shell:, win:, linux:)
  if [[ "$cmd_string" =~ ^(poetry|api|media_api|npm|shell|win|linux):(.+)$ ]]; then
    local cmd_type="${BASH_REMATCH[1]}"
    local cmd_args="${BASH_REMATCH[2]}"
    
    # Skip Windows commands on Linux
    if [[ "$cmd_type" == "win" ]]; then
      return 0
    fi
    
    # shellcheck disable=SC2086
    case "$cmd_type" in
      poetry)
        cd "$root" || exit 1
        local venv_python="$root/virtual_env/python/bin/python"
        if [[ -f "$venv_python" ]]; then
          # Prefer venv Poetry module to avoid missing/broken console script.
          # shellcheck disable=SC2086
          exec "$venv_python" -m poetry $cmd_args "${user_args[@]}"
        fi
        # shellcheck disable=SC2086
        exec poetry $cmd_args "${user_args[@]}"
        ;;
      api)
        local venv_python="$root/virtual_env/python/bin/python"
        if [[ ! -f "$venv_python" ]]; then
          echo "[ERROR] Виртуальное окружение не найдено" >&2
          exit 1
        fi
        export PYTHONPATH="$root"
        export PYTHONIOENCODING="utf-8"
        export PYTHONUNBUFFERED="1"
        _ergoms_export_tool_caches "$root"
        cd "$root/core/api" || exit 1
        # shellcheck disable=SC2086
        exec "$venv_python" -m commands $cmd_args "${user_args[@]}"
        ;;
      media_api)
        local venv_python="$root/virtual_env/python/bin/python"
        if [[ ! -f "$venv_python" ]]; then
          echo "[ERROR] Виртуальное окружение не найдено" >&2
          exit 1
        fi
        cd "$root" || exit 1
        export PYTHONPATH="$root/core/media_api/src:$root"
        _ergoms_export_tool_caches "$root"
        # shellcheck disable=SC2086
        exec "$venv_python" -m media_server.manage $cmd_args "${user_args[@]}"
        ;;
      npm)
        cd "$root/virtual_env/npm" || exit 1
        _ergoms_export_tool_caches "$root"
        _ergoms_prepend_nodejs_path "$root"
        # shellcheck disable=SC2086
        exec "$(_ergoms_npm_bin "$root")" $cmd_args "${user_args[@]}"
        ;;
      shell|linux)
        cd "$root" || exit 1
        # Execute shell command as-is
        local full_command="$cmd_args"
        if [[ ${#user_args[@]} -gt 0 ]]; then
          full_command="$full_command ${user_args[*]}"
        fi
        # shellcheck disable=SC2086
        exec bash -c "$full_command"
        ;;
    esac
  else
    # Execute as shell command (backward compatibility)
    cd "$root" || exit 1
    # shellcheck disable=SC2086
    exec $cmd_string "${user_args[@]}"
  fi
}

_should_run_on_this_platform() {
  local cmd_string="$1"
  [[ "$cmd_string" =~ ^win: ]] && return 1
  return 0
}

_suggest_conf_commands() {
  local query="${1,,}"
  local query_alt="${query//_/-}"
  local name normalized

  for name in "${!CUSTOM_COMMANDS[@]}"; do
    normalized="${name,,}"
    if [[ "$normalized" == "$query_alt" ]]; then
      echo "$name"
      return 0
    fi
  done

  for name in "${!CUSTOM_COMMANDS[@]}"; do
    normalized="${name,,}"
    if [[ "$normalized" == *"$query_alt"* || "$query_alt" == *"$normalized"* ]]; then
      echo "$name"
    fi
  done
}

invoke_custom_command() {
  local root="$1"
  local cmd_name="$2"
  shift 2
  local user_args=("$@")
  
  load_custom_commands "$root"
  
  if [[ ! -v "CUSTOM_COMMANDS[$cmd_name]" ]]; then
    echo "[ERROR] Неизвестная команда: $cmd_name" >&2
    local suggestions
    suggestions="$(_suggest_conf_commands "$cmd_name" | head -n 5)"
    if [[ -n "$suggestions" ]]; then
      local formatted=""
      while IFS= read -r suggestion; do
        [[ -z "$suggestion" ]] && continue
        if [[ -n "$formatted" ]]; then
          formatted+=", "
        fi
        formatted+="ergoms ${suggestion}"
      done <<< "$suggestions"
      echo "Возможно, вы имели в виду: $formatted" >&2
    fi
    echo "Справка: ergoms help" >&2
    exit 1
  fi
  
  local command_def="${CUSTOM_COMMANDS[$cmd_name]}"
  
  # Check if it's a composite command (contains &&)
  if [[ "$command_def" == *"&&"* ]]; then
    IFS='|' read -ra sub_cmds <<< "${command_def// && /|}"
    
    for sub_cmd in "${sub_cmds[@]}"; do
      sub_cmd=$(echo "$sub_cmd" | xargs)  # Trim whitespace
      if ! _should_run_on_this_platform "$sub_cmd"; then
        continue
      fi
      
      # Execute in subshell to avoid exec
      (execute_command_string "$root" "$sub_cmd" "${user_args[@]}")
      local exit_code=$?
      
      if [[ $exit_code -ne 0 ]]; then
        echo "[ERROR] Команда завершилась с ошибкой: $cmd_name" >&2
        exit $exit_code
      fi
    done
  else
    execute_command_string "$root" "$command_def" "${user_args[@]}"
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      echo "[ERROR] Команда завершилась с ошибкой: $cmd_name" >&2
      exit $exit_code
    fi
  fi
}

invoke_poetry_command() {
  local root="${1:-}"
  shift
  export ERGOMS_INTERNAL=1

  # Intercept poetry install/update → api (core + modules)
  if [[ "${1:-}" == "install" ]]; then
    shift
    invoke_api_command "$root" install "$@"
    return
  fi

  if [[ "${1:-}" == "update" ]]; then
    shift
    invoke_api_command "$root" update "$@"
    return
  fi

  # Intercept "poetry list" → api module-list (show core deps + all modules)
  if [[ "${1:-}" == "list" ]]; then
    invoke_api_command "$root" module-list
    return
  fi

  local venv_python="$root/virtual_env/python/bin/python"
  cd "$root" || exit 1
  if [[ -f "$venv_python" ]]; then
    exec "$venv_python" -m poetry "$@"
  fi
  exec poetry "$@"
}

invoke_module_poetry_command() {
  local root="$1"
  local module_name="$2"
  shift 2
  local sub_cmd="${1:-}"

  if [[ -z "$sub_cmd" ]]; then
    echo "Использование:"
    echo "  ergoms ${module_name}:poetry add PACKAGE              -- добавить зависимость (версия подбирается автоматически)"
    echo "  ergoms ${module_name}:poetry add PACKAGE '>=1.0.0'    -- добавить с явным ограничением версии"
    echo "  ergoms ${module_name}:poetry remove PACKAGE           -- удалить зависимость"
    echo "  ergoms ${module_name}:poetry list                     -- список зависимостей модуля"
    return
  fi

  shift
  case "$sub_cmd" in
    add)
      if [[ $# -eq 0 ]]; then
        echo "[ERROR] Укажите имя пакета: ergoms ${module_name}:poetry add PACKAGE" >&2
        exit 1
      fi
      invoke_api_command "$root" module-add "$module_name" "$@"
      ;;
    remove)
      if [[ $# -eq 0 ]]; then
        echo "[ERROR] Укажите имя пакета: ergoms ${module_name}:poetry remove PACKAGE" >&2
        exit 1
      fi
      invoke_api_command "$root" module-remove "$module_name" "$@"
      ;;
    list|show)
      invoke_api_command "$root" module-list "$module_name"
      ;;
    *)
      echo "[ERROR] Неизвестная подкоманда: $sub_cmd" >&2
      echo "Доступные: add, remove, list" >&2
      exit 1
      ;;
  esac
}

invoke_api_command() {
  local root="${1:-}"
  shift
  local venv_python="$root/virtual_env/python/bin/python"
  
  if [[ ! -f "$venv_python" ]]; then
    echo "[ERROR] Виртуальное окружение не найдено: $venv_python" >&2
    echo "  Сначала выполните ergoms python-install" >&2
    exit 1
  fi
  
  export ERGOMS_INTERNAL=1
  export PYTHONPATH="$root"
  export PYTHONIOENCODING="utf-8"
  export PYTHONUNBUFFERED="1"
  _ergoms_export_tool_caches "$root"
  cd "$root/core/api" || exit 1
  exec "$venv_python" -m commands "$@"
}

invoke_media_api_command() {
  local root="${1:-}"
  shift
  local venv_python="$root/virtual_env/python/bin/python"
  
  if [[ ! -f "$venv_python" ]]; then
    echo "[ERROR] Виртуальное окружение не найдено: $venv_python" >&2
    echo "  Сначала выполните ergoms python-install" >&2
    exit 1
  fi
  
  export ERGOMS_INTERNAL=1
  cd "$root" || exit 1
  export PYTHONPATH="$root/core/media_api/src:$root"
  _ergoms_export_tool_caches "$root"
  exec "$venv_python" -m media_server.manage "$@"
}

invoke_npm_command() {
  local root="${1:-}"
  shift
  export ERGOMS_INTERNAL=1
  cd "$root/virtual_env/npm" || exit 1
  _ergoms_export_tool_caches "$root"
  _ergoms_prepend_nodejs_path "$root"
  local npm_bin
  npm_bin="$(_ergoms_npm_bin "$root")"

  if [[ "${1:-}" == "update" ]]; then
    shift
    "$npm_bin" update "$@"
    local npm_rc=$?
    if [[ $npm_rc -ne 0 ]]; then
      return "$npm_rc"
    fi
    local pkg_args=()
    local arg
    for arg in "$@"; do
      [[ "$arg" == -* ]] && continue
      [[ -n "$arg" ]] && pkg_args+=("$arg")
    done
    echo "[INFO] Обновление npm-зависимостей модулей..."
    node "$root/core/deployment/scripts/sync-module-npm-deps.js" --update --install-missing "${pkg_args[@]}"
    return $?
  fi

  exec "$npm_bin" "$@"
}

export -f _ergoms_export_tool_caches
export -f load_custom_commands
export -f execute_command_string
export -f invoke_custom_command
export -f invoke_poetry_command
export -f invoke_module_poetry_command
export -f invoke_api_command
export -f invoke_media_api_command
export -f invoke_npm_command
