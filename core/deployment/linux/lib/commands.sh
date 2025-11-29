#!/usr/bin/env bash
# Custom commands management
# Управление пользовательскими командами

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
  
  # Parse command type (poetry:, api:, npm:, shell:, win:, linux:)
  if [[ "$cmd_string" =~ ^(poetry|api|npm|shell|win|linux):(.+)$ ]]; then
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
        exec poetry $cmd_args "${user_args[@]}"
        ;;
      api)
        local venv_activate="$root/virtual_env/python/bin/activate"
        if [[ ! -f "$venv_activate" ]]; then
          echo "[ERROR] Virtual environment not found" >&2
          exit 1
        fi
        cd "$root/core" || exit 1
        # shellcheck disable=SC1090
        source "$venv_activate"
        # shellcheck disable=SC2086
        exec api $cmd_args "${user_args[@]}"
        ;;
      npm)
        cd "$root/core" || exit 1
        # shellcheck disable=SC2086
        exec npm $cmd_args "${user_args[@]}"
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

invoke_custom_command() {
  local root="$1"
  local cmd_name="$2"
  shift 2
  local user_args=("$@")
  
  load_custom_commands "$root"
  
  if [[ ! -v "CUSTOM_COMMANDS[$cmd_name]" ]]; then
    echo "[ERROR] Unknown command: $cmd_name" >&2
    echo "Available custom commands: ${!CUSTOM_COMMANDS[*]}" >&2
    echo "Run 'ergoms help' for all available commands" >&2
    exit 1
  fi
  
  local command_def="${CUSTOM_COMMANDS[$cmd_name]}"
  
  # Check if it's a composite command (contains &&)
  if [[ "$command_def" == *"&&"* ]]; then
    echo "-> Executing composite command: $cmd_name"
    IFS='&&' read -ra sub_cmds <<< "$command_def"
    
    for sub_cmd in "${sub_cmds[@]}"; do
      sub_cmd=$(echo "$sub_cmd" | xargs)  # Trim whitespace
      echo "   -> $sub_cmd"
      
      # Execute in subshell to avoid exec
      (execute_command_string "$root" "$sub_cmd" "${user_args[@]}")
      local exit_code=$?
      
      if [[ $exit_code -ne 0 ]]; then
        echo "[ERROR] Command failed: $sub_cmd" >&2
        exit $exit_code
      fi
    done
  else
    execute_command_string "$root" "$command_def" "${user_args[@]}"
  fi
}

invoke_poetry_command() {
  local root="${1:-}"
  shift
  cd "$root" || exit 1
  exec poetry "$@"
}

invoke_api_command() {
  local root="${1:-}"
  shift
  local venv_activate="$root/virtual_env/python/bin/activate"
  
  if [[ ! -f "$venv_activate" ]]; then
    echo "[ERROR] Virtual environment not found at: $venv_activate" >&2
    echo "  Please run 'ergoms poetry install' first" >&2
    exit 1
  fi
  
  cd "$root/core" || exit 1
  # shellcheck disable=SC1090
  source "$venv_activate"
  exec api "$@"
}

invoke_npm_command() {
  local root="${1:-}"
  shift
  cd "$root/core" || exit 1
  exec npm "$@"
}

export -f load_custom_commands
export -f execute_command_string
export -f invoke_custom_command
export -f invoke_poetry_command
export -f invoke_api_command
export -f invoke_npm_command

