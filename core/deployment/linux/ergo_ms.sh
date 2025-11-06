#!/usr/bin/env bash
set -euo pipefail

# This script installs and starts systemd services for ergo_ms on Linux.
# It auto-detects the project root and avoids hardcoded directories by using
# an EnvironmentFile and systemd's %E{VAR} specifier.

# Load modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=lib/systemd.sh
source "$LIB_DIR/systemd.sh"
# shellcheck source=lib/services.sh
source "$LIB_DIR/services.sh"
# shellcheck source=lib/setup.sh
source "$LIB_DIR/setup.sh"
# shellcheck source=lib/cli.sh
source "$LIB_DIR/cli.sh"
# shellcheck source=lib/commands.sh
source "$LIB_DIR/commands.sh"
# shellcheck source=lib/help.sh
source "$LIB_DIR/help.sh"

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
      install|install-services|install-api-service|install-client-service|install-worker-service|install-beat-service|start|stop|restart|status|uninstall-services|install-cli|uninstall-cli|logs|setup-full|clean|poetry|api|npm)
        shift ;;
      -h|--help)
        print_usage "$detected_root"; exit 0 ;;
      *)
        # Check if it's a custom command
        if [[ -v "available_custom_cmds[$command]" ]]; then
          shift
        else
          echo "Unknown command: $command" >&2
          print_usage "$detected_root"
          exit 1
        fi
        ;;
    esac
  fi

  # If no command provided, show help
  if [[ -z "$command" ]]; then
    print_usage "$detected_root"
    exit 0
  fi

  # Check if it's a proxy command (doesn't require root)
  local is_proxy_command=false
  case "$command" in
    poetry|api|npm)
      is_proxy_command=true ;;
  esac
  
  # Check if it's a logs command (doesn't require root for viewing)
  local is_logs_command=false
  if [[ "$command" == "logs" ]]; then
    is_logs_command=true
  fi
  
  # Check if it's a custom command (doesn't require root)
  local is_custom_command=false
  if [[ -v "available_custom_cmds[$command]" ]]; then
    is_custom_command=true
  fi
  
  # Check if it's a deployment command (doesn't require root)
  local is_deploy_command=false
  case "$command" in
    deploy-api|deploy-client|deploy-api-dev|deploy-client-dev|deploy-all)
      is_deploy_command=true ;;
  esac
  
  # Check if it's a clean command (doesn't require root)
  local is_clean_command=false
  if [[ "$command" == "clean" ]]; then
    is_clean_command=true
  fi

  # Parse flags/positional root for proxy, custom, logs, deploy, and clean commands
  if [[ "$is_proxy_command" == true ]] || [[ "$is_custom_command" == true ]] || [[ "$is_logs_command" == true ]] || [[ "$is_deploy_command" == true ]] || [[ "$is_clean_command" == true ]]; then
    while (( "$#" )); do
      case "$1" in
        --root)
          shift; arg_root="${1:-}"; shift || true ;;
        --root=*)
          arg_root="${1#*=}"; shift ;;
        -h|--help)
          print_usage "$detected_root"; exit 0 ;;
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
    
    # Execute deploy command
    if [[ "$is_deploy_command" == true ]]; then
      invoke_custom_command "$ERGO_ROOT" "$command" "$@"
      exit 0
    fi
    
    # Execute clean command
    if [[ "$is_clean_command" == true ]]; then
      clear_project_dependencies "$ERGO_ROOT"
      exit 0
    fi
    
    # Execute logs command
    if [[ "$is_logs_command" == true ]]; then
      if [[ $# -eq 0 ]]; then
        echo "[ERROR] Please specify a service name" >&2
        echo "Available services: $(units_list | tr ' ' ',')" >&2
        echo "Usage: ergoms logs <service-name> [lines]" >&2
        exit 1
      fi
      
      local service_name="$1"
      local lines="${2:-500}"
      
      # Check if service exists
      local valid=false
      for u in $(units_list); do
        if [[ "$u" == "$service_name" || "$u" == "${service_name}.service" ]]; then
          valid=true
          service_name="$u"
          break
        fi
      done
      
      if [[ "$valid" == false ]]; then
        echo "[ERROR] Unknown service: $service_name" >&2
        echo "Available services: $(units_list | tr '\n' ' ')" >&2
        exit 1
      fi
      
      show_service_logs "$service_name" "$lines"
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
        print_usage "$detected_root"; exit 0 ;;
      *)
        if [[ -z "$arg_root" ]]; then
          arg_root="$1"; shift
        else
          echo "Unknown argument: $1" >&2; print_usage "$detected_root"; exit 1
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
    uninstall-services) uninstall_all "$purge"; exit 0 ;;
    install-cli) create_cli_wrapper "$SELF_SCRIPT"; exit 0 ;;
    uninstall-cli) remove_cli_wrapper; exit 0 ;;
    setup-full)
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
      setup_full_system "$ERGO_ROOT"
      exit 0
      ;;
    install)  ;; # Continue to install flow
    install-services)  ;; # Continue to install flow
    install-api-service)  ;; # Continue to install flow
    install-client-service)  ;; # Continue to install flow
    install-worker-service)  ;; # Continue to install flow
    install-beat-service)  ;; # Continue to install flow
    *)        echo "Unknown command: $command" >&2; print_usage "$detected_root"; exit 1 ;;
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
    echo "Run 'ergoms setup' to initialize all submodules." >&2
    exit 1
  fi

  # Handle individual service installation
  case "$command" in
    install-services)
      install_services "$ERGO_ROOT"
      ;;
    install-api-service)
      install_single_service "api" "$ERGO_ROOT"
      ;;
    install-client-service)
      install_single_service "client" "$ERGO_ROOT"
      ;;
    install-worker-service)
      install_single_service "worker" "$ERGO_ROOT"
      ;;
    install-beat-service)
      install_single_service "beat" "$ERGO_ROOT"
      ;;
    install)
      write_env_file "$ERGO_ROOT"
      
      # Get unit definitions
      get_unit_definitions
      
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
        echo "You can now run: $(cli_name) start|stop|restart|status|uninstall-services [--purge]"
      else
        echo "CLI wrapper install skipped (--no-cli)."
      fi
      ;;
  esac
}

main "$@"

