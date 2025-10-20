#!/usr/bin/env bash
set -euo pipefail

# This script installs and starts systemd services for ergo_ms on Linux.
# It auto-detects the project root and avoids hardcoded directories by using
# an EnvironmentFile and systemd's %E{VAR} specifier.

require_root_or_sudo() {
  if [[ $(id -u) -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "This script requires root or sudo. Install sudo or run as root." >&2
      exit 1
    fi
  fi
}

detect_project_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Prefer git root if available
  if command -v git >/dev/null 2>&1; then
    if git -C "$script_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
      git -C "$script_dir" rev-parse --show-toplevel
      return 0
    fi
  fi

  # Fallback: assume systemd directory is inside project root
  echo "$(cd "$script_dir/.." && pwd)"
}

write_env_file() {
  local root="$1"
  local env_file="/etc/default/ergo_ms"
  local tmp_file
  tmp_file="$(mktemp)"

  cat >"$tmp_file" <<EOF
# Environment for ergo_ms services
ERGO_ROOT="$root"
PYTHONUNBUFFERED=1
NODE_ENV=development
EOF

  if [[ $(id -u) -eq 0 ]]; then
    install -m 0644 "$tmp_file" "$env_file"
  else
    sudo install -m 0644 "$tmp_file" "$env_file"
  fi
  rm -f "$tmp_file"
  echo "Written $env_file with ERGO_ROOT=$root"
}

install_unit() {
  local name="$1"
  local content="$2"
  local unit_path="/etc/systemd/system/${name}.service"
  local tmp_file
  tmp_file="$(mktemp)"
  printf "%s" "$content" > "$tmp_file"
  if [[ $(id -u) -eq 0 ]]; then
    install -m 0644 "$tmp_file" "$unit_path"
  else
    sudo install -m 0644 "$tmp_file" "$unit_path"
  fi
  rm -f "$tmp_file"
  echo "Installed $unit_path"
}

units_list() {
  echo "ergo-api-dev.service ergo-client-dev.service ergo-celery-worker.service ergo-celery-beat.service"
}

cli_name() {
  echo "ergoms"
}

cli_path() {
  echo "/usr/local/bin/$(cli_name)"
}

create_cli_wrapper() {
  local target_script="$1"
  local name
  name="$(cli_name)"
  local path
  path="$(cli_path)"
  local tmp_file
  tmp_file="$(mktemp)"
  cat >"$tmp_file" <<'EOF'
#!/usr/bin/env bash
exec bash "__TARGET_SCRIPT__" "$@"
EOF
  # Inject actual target script path into the wrapper
  if command -v sed >/dev/null 2>&1; then
    sed -i "s|__TARGET_SCRIPT__|${target_script}|g" "$tmp_file"
  else
    # Fallback without in-place sed
    local tmp2
    tmp2="$(mktemp)"
    awk -v p="${target_script}" '{gsub("__TARGET_SCRIPT__", p); print}' "$tmp_file" > "$tmp2"
    mv "$tmp2" "$tmp_file"
  fi
  if [[ $(id -u) -eq 0 ]]; then
    install -m 0755 "$tmp_file" "$path"
  else
    sudo install -m 0755 "$tmp_file" "$path"
  fi
  rm -f "$tmp_file"
  echo "Installed CLI wrapper: $path"
}

remove_cli_wrapper() {
  local path
  path="$(cli_path)"
  if [[ -f "$path" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      rm -f "$path"
    else
      sudo rm -f "$path"
    fi
    echo "Removed CLI wrapper: $path"
  fi
}

daemon_reload() {
  if [[ $(id -u) -eq 0 ]]; then
    systemctl daemon-reload
  else
    sudo systemctl daemon-reload
  fi
}

systemctl_do() {
  if [[ $(id -u) -eq 0 ]]; then
    systemctl "$@"
  else
    sudo systemctl "$@"
  fi
}

enable_and_start() {
  local unit="$1"
  if [[ $(id -u) -eq 0 ]]; then
    systemctl enable --now "$unit"
  else
    sudo systemctl enable --now "$unit"
  fi
}

start_all() {
  local u
  for u in $(units_list); do systemctl_do start "$u"; done
}

stop_all() {
  local u
  for u in $(units_list); do systemctl_do stop "$u" || true; done
}

restart_all() {
  local u
  for u in $(units_list); do systemctl_do restart "$u"; done
}

status_all() {
  local u
  for u in $(units_list); do systemctl_do status "$u" | cat; done
}

uninstall_all() {
  local purge="$1"
  stop_all || true
  local u
  for u in $(units_list); do systemctl_do disable "$u" || true; done
  for u in $(units_list); do
    if [[ -f "/etc/systemd/system/$u" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/systemd/system/$u"
      else
        sudo rm -f "/etc/systemd/system/$u"
      fi
      echo "Removed /etc/systemd/system/$u"
    fi
  done
  daemon_reload
  if [[ "$purge" == "true" ]]; then
    if [[ -f "/etc/default/ergo_ms" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        rm -f "/etc/default/ergo_ms"
      else
        sudo rm -f "/etc/default/ergo_ms"
      fi
      echo "Removed /etc/default/ergo_ms"
    fi
  fi
}

load_custom_commands() {
  local root="$1"
  local config_file="$root/core/deployment/commands.conf"
  
  declare -g -A CUSTOM_COMMANDS=()
  
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
}

execute_command_string() {
  local root="$1"
  local cmd_string="$2"
  shift 2
  local user_args=("$@")
  
  # Parse command type (poetry:, api:, npm:)
  if [[ "$cmd_string" =~ ^(poetry|api|npm):(.+)$ ]]; then
    local cmd_type="${BASH_REMATCH[1]}"
    local cmd_args="${BASH_REMATCH[2]}"
    
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
    esac
  else
    # Execute as shell command
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

print_usage() {
  local detected_root=""
  detected_root="$(detect_project_root 2>/dev/null || echo '')"
  
  declare -A custom_cmds
  if [[ -n "$detected_root" ]]; then
    load_custom_commands "$detected_root" 2>/dev/null || true
    for key in "${!CUSTOM_COMMANDS[@]}"; do
      custom_cmds["$key"]="${CUSTOM_COMMANDS[$key]}"
    done
  fi
  
  cat <<USAGE
Usage:
  bash $0 [command] [options]
  ergoms [command] [options]  (after installing CLI)

Service Management Commands:
  install    Install units, save ERGO_ROOT, enable and start
  start      Start all services
  stop       Stop all services
  restart    Restart all services
  status     Show status for all services
  uninstall  Stop, disable, remove units; with --purge also removes /etc/default/ergo_ms
  install-cli    Install CLI wrapper /usr/local/bin/ergoms
  uninstall-cli  Remove CLI wrapper

Proxy Commands (automatically forward to respective tools):
  poetry <args>  Forward to poetry command
  api <args>     Forward to api command
  npm <args>     Forward to npm command

USAGE

  if [[ ${#custom_cmds[@]} -gt 0 ]]; then
    echo "Custom Commands (defined in commands.conf):"
    echo ""
    for cmd in $(echo "${!custom_cmds[@]}" | tr ' ' '\n' | sort); do
      local def="${custom_cmds[$cmd]}"
      # Truncate long definitions
      if [[ ${#def} -gt 60 ]]; then
        def="${def:0:57}..."
      fi
      printf "  %-20s -> %s\n" "$cmd" "$def"
    done
    echo ""
  fi

  cat <<USAGE
Options:
  --root <path>  Specify project root path (auto-detected if not provided)
  --purge        Remove all data when uninstalling
  --no-cli       Skip CLI wrapper installation

Examples:
  Service Management:
    sudo bash $0 install
    sudo bash $0 install --root /projects/ergo_ms
    sudo bash $0 status
    sudo bash $0 uninstall --purge
    ergoms start
    ergoms stop
    ergoms restart
    ergoms status

  Proxy Commands:
    ergoms poetry install
    ergoms poetry update
    ergoms api migrate
    ergoms api createsuperuser
    ergoms npm run dev
    ergoms npm install

  Custom Commands:
    ergoms python-install       (alias for: poetry install)
    ergoms setup                (runs: poetry install && npm install && api migrate)
    ergoms db-migrate           (alias for: api migrate)

Configuration:
  Custom commands are defined in: core/deployment/commands.conf
  Edit this file to add your own command aliases and composite commands.

Notes:
  - Service management requires root or sudo
  - Proxy and custom commands do not require root privileges
  - For install you may pass --root

USAGE
}

main() {
  local command=""
  local ERGO_ROOT
  local arg_root=""
  local purge=false
  local no_cli=false
  local SELF_SCRIPT
  if command -v readlink >/dev/null 2>&1; then
    SELF_SCRIPT="$(readlink -f "$0")"
  else
    SELF_SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  fi

  # Try to detect root early to load custom commands
  local detected_root=""
  detected_root="$(detect_project_root 2>/dev/null || echo '')"
  
  declare -A available_custom_cmds
  if [[ -n "$detected_root" ]]; then
    load_custom_commands "$detected_root" 2>/dev/null || true
    for key in "${!CUSTOM_COMMANDS[@]}"; do
      available_custom_cmds["$key"]="${CUSTOM_COMMANDS[$key]}"
    done
  fi

  # First positional can be a command
  if (( $# > 0 )); then
    command="$1"
    case "$command" in
      install|start|stop|restart|status|uninstall|install-cli|uninstall-cli|poetry|api|npm)
        shift ;;
      -h|--help)
        print_usage; exit 0 ;;
      *)
        # Check if it's a custom command
        if [[ -v "available_custom_cmds[$command]" ]]; then
          shift
        else
          echo "Unknown command: $command" >&2
          print_usage
          exit 1
        fi
        ;;
    esac
  fi

  # If no command provided, show help
  if [[ -z "$command" ]]; then
    print_usage
    exit 0
  fi

  # Check if it's a proxy command (doesn't require root)
  local is_proxy_command=false
  case "$command" in
    poetry|api|npm)
      is_proxy_command=true ;;
  esac
  
  # Check if it's a custom command (doesn't require root)
  local is_custom_command=false
  if [[ -v "available_custom_cmds[$command]" ]]; then
    is_custom_command=true
  fi

  # Parse flags/positional root for proxy and custom commands
  if [[ "$is_proxy_command" == true ]] || [[ "$is_custom_command" == true ]]; then
    while (( "$#" )); do
      case "$1" in
        --root)
          shift; arg_root="${1:-}"; shift || true ;;
        --root=*)
          arg_root="${1#*=}"; shift ;;
        -h|--help)
          print_usage; exit 0 ;;
        *)
          break ;;  # Rest are arguments for the command
      esac
    done
    
    # Detect project root
    if [[ -n "$arg_root" ]]; then
      if [[ -d "$arg_root" ]]; then
        if command -v readlink >/dev/null 2>&1; then ERGO_ROOT="$(readlink -f "$arg_root")"; else ERGO_ROOT="$(cd "$arg_root" && pwd)"; fi
      else
        echo "Provided --root path does not exist or is not a directory: $arg_root" >&2
        exit 1
      fi
    else
      ERGO_ROOT="$(detect_project_root)"
    fi
    
    # Execute custom command
    if [[ "$is_custom_command" == true ]]; then
      invoke_custom_command "$ERGO_ROOT" "$command" "$@"
      exit 0
    fi
    
    # Execute proxy command
    case "$command" in
      poetry) invoke_poetry_command "$ERGO_ROOT" "$@" ;;
      api)    invoke_api_command "$ERGO_ROOT" "$@" ;;
      npm)    invoke_npm_command "$ERGO_ROOT" "$@" ;;
    esac
    exit 0
  fi

  # For non-proxy commands, require root/sudo
  require_root_or_sudo

  # Parse flags/positional root for service commands
  while (( "$#" )); do
    case "$1" in
      --root)
        shift; arg_root="${1:-}"; shift || true ;;
      --root=*)
        arg_root="${1#*=}"; shift ;;
      --purge)
        purge=true; shift ;;
      --no-cli)
        no_cli=true; shift ;;
      -h|--help)
        print_usage; exit 0 ;;
      *)
        if [[ -z "$arg_root" ]]; then
          arg_root="$1"; shift
        else
          echo "Unknown argument: $1" >&2; print_usage; exit 1
        fi
        ;;
    esac
  done

  # Fast-path commands that don't need install
  case "$command" in
    start)    start_all; exit 0 ;;
    stop)     stop_all; exit 0 ;;
    restart)  restart_all; exit 0 ;;
    status)   status_all; exit 0 ;;
    uninstall) uninstall_all "$purge"; exit 0 ;;
    install-cli) create_cli_wrapper "$SELF_SCRIPT"; exit 0 ;;
    uninstall-cli) remove_cli_wrapper; exit 0 ;;
    install)  ;; # Continue to install flow
    *)        echo "Unknown command: $command" >&2; print_usage; exit 1 ;;
  esac

  # INSTALL flow
  if [[ -n "$arg_root" ]]; then
    if [[ -d "$arg_root" ]]; then
      if command -v readlink >/dev/null 2>&1; then ERGO_ROOT="$(readlink -f "$arg_root")"; else ERGO_ROOT="$(cd "$arg_root" && pwd)"; fi
    else
      echo "Provided --root path does not exist or is not a directory: $arg_root" >&2; exit 1
    fi
  else
    ERGO_ROOT="$(detect_project_root)"
  fi

  # Basic sanity checks for expected structure
  if [[ ! -d "$ERGO_ROOT/core/api" ]] || [[ ! -d "$ERGO_ROOT/core/client" ]]; then
    echo "Detected root $ERGO_ROOT doesn't look like an ergo_ms project (missing core/api/ or core/client/)." >&2
    exit 1
  fi

  write_env_file "$ERGO_ROOT"

  # Define units using %E{ERGO_ROOT}
  API_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo API (dev)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && api dev'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
)

  CLIENT_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Client (npm run dev)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && npm run dev'
Restart=always
RestartSec=5
Environment=NODE_ENV=development

[Install]
WantedBy=multi-user.target
UNIT
)

  CELERY_WORKER_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Celery Worker
After=network.target
Requires=ergo-api-dev.service

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && api start_celery_worker'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
)

  CELERY_BEAT_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Celery Beat
After=network.target
Requires=ergo-api-dev.service

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && api start_celery_beat'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
)

  install_unit "ergo-api-dev"        "$API_UNIT"
  install_unit "ergo-client-dev"     "$CLIENT_UNIT"
  install_unit "ergo-celery-worker"  "$CELERY_WORKER_UNIT"
  install_unit "ergo-celery-beat"    "$CELERY_BEAT_UNIT"

  daemon_reload

  enable_and_start ergo-api-dev.service
  enable_and_start ergo-client-dev.service
  enable_and_start ergo-celery-worker.service
  enable_and_start ergo-celery-beat.service

  echo "All services installed and started."
  echo "View logs: journalctl -u ergo-api-dev -n 500 -f"

  if [[ "$no_cli" == false ]]; then
    create_cli_wrapper "$SELF_SCRIPT"
    echo "You can now run: $(cli_name) start|stop|restart|status|uninstall [--purge]"
  else
    echo "CLI wrapper install skipped (--no-cli)."
  fi
}

main "$@"


