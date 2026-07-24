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
# shellcheck source=lib/nginx.sh
source "$LIB_DIR/nginx.sh"
# shellcheck source=lib/redis.sh
source "$LIB_DIR/redis.sh"
# shellcheck source=lib/tls.sh
source "$LIB_DIR/tls.sh"
# shellcheck source=lib/lifecycle.sh
source "$LIB_DIR/lifecycle.sh"
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
    local normalized_cmd="${command//_/-}"
    if [[ ! -v "available_custom_cmds[$command]" ]] && [[ -v "available_custom_cmds[$normalized_cmd]" ]]; then
      command="$normalized_cmd"
    fi
    case "$command" in
      install|install-services|install-api-service|install-client-service|install-worker-service|install-beat-service|install-media-service|start|stop|restart|status|uninstall-services|install-cli|uninstall-cli|logs|setup-full|update-submodules|update-module-submodules|clean|help|poetry|api|media_api|npm|install-nginx|uninstall-nginx|start-nginx|stop-nginx|restart-nginx|reload-nginx|status-nginx|test-nginx|install-tls|renew-tls|status-tls|install-redis|install-redis-service|uninstall-redis|start-redis|stop-redis|restart-redis|status-redis|test-redis)
        shift ;;
      *:poetry)
        shift ;;  # module:poetry command, handled below
      -h|--help)
        print_usage "$detected_root"; exit 0 ;;
      *)
        # Check if it's a custom command
        if [[ -v "available_custom_cmds[$command]" ]]; then
          shift
        else
          echo "Неизвестная команда: $command" >&2
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

  # Справка без root
  if [[ "$command" == "help" ]]; then
    print_usage "$detected_root" "$@"
    exit 0
  fi

  # Check if it's a <module>:poetry command (doesn't require root)
  local is_module_poetry_command=false
  local module_poetry_name=""
  if [[ "$command" =~ ^([a-zA-Z0-9_-]+):poetry$ ]]; then
    is_module_poetry_command=true
    module_poetry_name="${BASH_REMATCH[1]}"
  fi

  # Check if it's a proxy command (doesn't require root)
  local is_proxy_command=false
  case "$command" in
    poetry|api|media_api|npm)
      is_proxy_command=true ;;
  esac
  
  # Check if it's a logs command (doesn't require root for viewing)
  local is_logs_command=false
  if [[ "$command" == "logs" ]]; then
    is_logs_command=true
  fi
  
  # Check if it's a custom command (doesn't require root)
  # Exclude built-in commands to avoid recursion (e.g. install-cli would re-invoke self via commands.conf)
  local builtin_override="install-cli|uninstall-cli|install|install-services|install-api-service|install-client-service|install-worker-service|install-beat-service|install-media-service|start|stop|restart|status|uninstall-services|setup-full|install-nginx|uninstall-nginx|start-nginx|stop-nginx|restart-nginx|reload-nginx|status-nginx|test-nginx|install-tls|renew-tls|status-tls|install-redis|install-redis-service|uninstall-redis|start-redis|stop-redis|restart-redis|status-redis|test-redis"
  local is_custom_command=false
  if [[ -v "available_custom_cmds[$command]" ]] && [[ ! "$command" =~ ^($builtin_override)$ ]]; then
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

  # Check if it's an update-submodules command (doesn't require root)
  local is_update_submodules_command=false
  if [[ "$command" == "update-submodules" ]]; then
    is_update_submodules_command=true
  fi

  local is_update_module_submodules_command=false
  if [[ "$command" == "update-module-submodules" ]]; then
    is_update_module_submodules_command=true
  fi

  # Check if it's a nginx command (requires root for install/uninstall, not for others)
  local is_nginx_command=false
  case "$command" in
    install-nginx|uninstall-nginx|start-nginx|stop-nginx|restart-nginx|reload-nginx|status-nginx|test-nginx|install-tls|renew-tls|status-tls)
      is_nginx_command=true ;;
  esac

  # Check if it's a redis command
  local is_redis_command=false
  case "$command" in
    install-redis|install-redis-service|uninstall-redis|start-redis|stop-redis|restart-redis|status-redis|test-redis)
      is_redis_command=true ;;
  esac

  # Parse flags/positional root for proxy, custom, logs, deploy, clean, update-submodules, nginx, and redis commands
  if [[ "$is_proxy_command" == true ]] || [[ "$is_module_poetry_command" == true ]] || [[ "$is_custom_command" == true ]] || [[ "$is_logs_command" == true ]] || [[ "$is_deploy_command" == true ]] || [[ "$is_clean_command" == true ]] || [[ "$is_update_submodules_command" == true ]] || [[ "$is_update_module_submodules_command" == true ]] || [[ "$is_nginx_command" == true ]] || [[ "$is_redis_command" == true ]]; then
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
        echo "Указанный путь --root не существует или не является каталогом: $arg_root" >&2
        exit 1
      fi
    else
      ERGO_ROOT="$(detect_project_root)"
    fi
    
    # Execute clean and update-submodules as built-in first (avoid recursion via commands.conf)
    if [[ "$is_clean_command" == true ]]; then
      clear_project_dependencies "$ERGO_ROOT"
      exit 0
    fi
    if [[ "$is_update_submodules_command" == true ]]; then
      invoke_lifecycle_runner "$ERGO_ROOT" update-submodules
      exit 0
    fi
    if [[ "$is_update_module_submodules_command" == true ]]; then
      invoke_lifecycle_runner "$ERGO_ROOT" update-module-submodules
      exit 0
    fi

    # Execute nginx/tls via lifecycle runner
    if [[ "$is_nginx_command" == true ]]; then
      local nginx_purge=false
      local extra=()
      while (( "$#" )); do
        case "$1" in
          --purge) nginx_purge=true; shift ;;
          --dry-run) extra+=(--dry-run); shift ;;
          *) break ;;
        esac
      done
      [[ "$nginx_purge" == true ]] && extra+=(--purge)
      case "$command" in
        install-nginx|install-tls)
          extra+=(--server-name "${1:-}" --listen-port "${2:-}" --domain "${1:-}" --email "${2:-}")
          ;;
      esac
      invoke_lifecycle_runner "$ERGO_ROOT" "$command" "${extra[@]}"
      exit 0
    fi

    # Execute redis via lifecycle runner
    if [[ "$is_redis_command" == true ]]; then
      local redis_port="" redis_purge=false
      local extra=()
      while (( "$#" )); do
        case "$1" in
          --purge) redis_purge=true; shift ;;
          --configure)
            echo "[WARNING] --configure устарел; задайте REDIS_ENABLED=true в .env" >&2
            shift
            ;;
          *)
            if [[ -z "$redis_port" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
              redis_port="$1"
              shift
            else
              break
            fi
            ;;
        esac
      done
      [[ "$redis_purge" == true ]] && extra+=(--purge)
      [[ -n "$redis_port" ]] && extra+=(--listen-port "$redis_port")
      case "$command" in
        install-redis|install-redis-service)
          invoke_lifecycle_runner "$ERGO_ROOT" install-redis "${extra[@]}"
          ;;
        *)
          invoke_lifecycle_runner "$ERGO_ROOT" "$command" "${extra[@]}"
          ;;
      esac
      exit 0
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
    
    # Execute logs command
    if [[ "$is_logs_command" == true ]]; then
      if [[ $# -eq 0 ]]; then
        echo "[ERROR] Укажите имя службы" >&2
        echo "Доступные службы: $(units_list "$ERGO_ROOT" | tr ' ' ',')" >&2
        echo "Использование: ergoms logs <имя-службы> [строки]" >&2
        exit 1
      fi
      
      local service_name="$1"
      local lines="${2:-500}"
      local module_filter=""

      if [[ "$service_name" == "celery-tasks" ]]; then
        if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
          lines="$2"
        elif [[ -n "${2:-}" ]]; then
          module_filter="$2"
          lines="${3:-500}"
        fi
        set_service_project_root "$ERGO_ROOT"
        show_celery_tasks_logs "$module_filter" "$lines"
        exit 0
      fi

      if [[ "$service_name" == "celery-beat" ]]; then
        if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
          lines="$2"
        elif [[ -n "${2:-}" ]]; then
          module_filter="$2"
          lines="${3:-500}"
        fi
        set_service_project_root "$ERGO_ROOT"
        show_celery_beat_logs "$module_filter" "$lines"
        exit 0
      fi
      
      [[ "$service_name" == "media_api" ]] && service_name="ergo-media-api"

      set_service_project_root "$ERGO_ROOT"

      # При NGINX_ENABLED Vite-служба не ставится — не открываем её логи с ошибкой
      if [[ "$service_name" == "ergo-client-dev" || "$service_name" == "ergo-client-dev.service" ]]; then
        if is_nginx_enabled "$ERGO_ROOT"; then
          echo "$(format_ergo_console skip 'ergo-client-dev не используется (NGINX_ENABLED=true, клиент через nginx)')"
          exit 0
        fi
      fi

      local valid=false
      case "$service_name" in
        ergo_ms_nginx|ergo_ms_nginx.service|ergo-redis|ergo-redis.service|ergo_ms_redis)
          valid=true
          ;;
      esac

      if [[ "$valid" == false ]]; then
        for u in $(units_list "$ERGO_ROOT"); do
          if [[ "$u" == "$service_name" || "$u" == "${service_name}.service" ]]; then
            valid=true
            service_name="$u"
            break
          fi
        done
      fi

      if [[ "$valid" == false ]]; then
        write_ergoms_message 'unknown_service' red stderr "name=$service_name"
        echo "Доступные службы: $(units_list "$ERGO_ROOT" | tr '\n' ' ') ergo_ms_nginx ergo-redis celery-tasks celery-beat" >&2
        exit 1
      fi

      show_service_logs "$service_name" "$lines"
      exit 0
    fi
    
    # Execute <module>:poetry command
    if [[ "$is_module_poetry_command" == true ]]; then
      invoke_module_poetry_command "$ERGO_ROOT" "$module_poetry_name" "$@"
      exit 0
    fi

    # Execute proxy command
    case "$command" in
      poetry)    invoke_poetry_command "$ERGO_ROOT" "$@" ;;
      api)       invoke_api_command "$ERGO_ROOT" "$@" ;;
      media_api) invoke_media_api_command "$ERGO_ROOT" "$@" ;;
      npm)       invoke_npm_command "$ERGO_ROOT" "$@" ;;
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
          echo "Неизвестный аргумент: $1" >&2; print_usage "$detected_root"; exit 1
        fi
        ;;
    esac
  done

  # Detect project root for service commands
  if [[ -n "$arg_root" ]]; then
    if [[ -d "$arg_root" ]]; then
      if command -v readlink >/dev/null 2>&1; then ERGO_ROOT="$(readlink -f "$arg_root")"; else ERGO_ROOT="$(cd "$arg_root" && pwd)"; fi
    else
      echo "Указанный путь --root не существует или не является каталогом: $arg_root" >&2
      exit 1
    fi
  else
    ERGO_ROOT="$(detect_project_root)"
  fi

  # Устанавливаем корень проекта для функций служб
  set_service_project_root "$ERGO_ROOT"

  # Fast-path commands that don't need install
  case "$command" in
    start)    invoke_lifecycle_runner "$ERGO_ROOT" start; exit 0 ;;
    stop)     invoke_lifecycle_runner "$ERGO_ROOT" stop; exit 0 ;;
    restart)  invoke_lifecycle_runner "$ERGO_ROOT" restart; exit 0 ;;
    status)   invoke_lifecycle_runner "$ERGO_ROOT" status; exit 0 ;;
    uninstall-services)
      extra=()
      [[ "$purge" == true ]] && extra+=(--purge)
      invoke_lifecycle_runner "$ERGO_ROOT" uninstall-services "${extra[@]}"
      exit 0
      ;;
    install-cli) create_cli_wrapper "$SELF_SCRIPT"; exit 0 ;;
    uninstall-cli) remove_cli_wrapper; exit 0 ;;
    setup-full)
      extra=()
      [[ "${recreate_venv:-false}" == true ]] && extra+=(--recreate-venv)
      invoke_lifecycle_runner "$ERGO_ROOT" setup-full "${extra[@]}"
      exit 0
      ;;
    install-services)
      invoke_lifecycle_runner "$ERGO_ROOT" install-services
      exit 0
      ;;
    install-api-service)
      invoke_lifecycle_runner "$ERGO_ROOT" install-api-service
      exit 0
      ;;
    install-client-service)
      invoke_lifecycle_runner "$ERGO_ROOT" install-client-service
      exit 0
      ;;
    install-worker-service)
      invoke_lifecycle_runner "$ERGO_ROOT" install-worker-service
      exit 0
      ;;
    install-beat-service)
      invoke_lifecycle_runner "$ERGO_ROOT" install-beat-service
      exit 0
      ;;
    install-media-service)
      invoke_lifecycle_runner "$ERGO_ROOT" install-media-service
      exit 0
      ;;
    install)  ;; # Continue to install flow
    *)        echo "Неизвестная команда: $command" >&2; print_usage "$detected_root"; exit 1 ;;
  esac

  # INSTALL flow
  # Basic sanity checks for expected structure
  if [[ ! -d "$ERGO_ROOT/core/api" ]] || [[ ! -d "$ERGO_ROOT/core/client" ]]; then
    echo "Каталог $ERGO_ROOT не похож на проект ergo_ms (нет core/api/ или core/client/)." >&2
    echo "Выполните ergoms setup для инициализации всех submodule." >&2
    exit 1
  fi

  # Handle install command (legacy systemd flow)
  case "$command" in
    install)
      write_env_file "$ERGO_ROOT"
      
      # Получаем базовые unit definitions
      get_base_unit_definitions "$ERGO_ROOT"
      
      local skip_client=0
      is_nginx_enabled "$ERGO_ROOT" && skip_client=1

      # Устанавливаем базовые службы
      install_unit "ergo-api-dev"        "$API_UNIT"
      if (( skip_client == 0 )); then
        install_unit "ergo-client-dev"     "$CLIENT_UNIT"
      else
        disable_client_service_if_nginx "$ERGO_ROOT"
      fi
      install_unit "ergo-media-api"      "$MEDIA_API_UNIT"
      install_unit "ergo-celery-beat"    "$CELERY_BEAT_UNIT"
      
      # Устанавливаем воркеры из конфигурации
      install_worker_units "$ERGO_ROOT"

      daemon_reload

      # Включаем и запускаем базовые службы
      enable_and_start ergo-api-dev.service
      if (( skip_client == 0 )); then
        enable_and_start ergo-client-dev.service
      fi
      enable_and_start ergo-media-api.service
      enable_and_start ergo-celery-beat.service
      
      # Включаем и запускаем воркеры
      enable_and_start_workers "$ERGO_ROOT"

      echo "Все службы установлены и запущены."
      echo "Просмотр логов: journalctl -u ergo-api-dev -n 500 -f"

      if [[ "$no_cli" == false ]]; then
        create_cli_wrapper "$SELF_SCRIPT"
        echo "Доступны команды: $(cli_name) start|stop|restart|status|uninstall-services [--purge]"
      else
        echo "Установка CLI-обёртки пропущена (--no-cli)."
      fi
      ;;
  esac
}

main "$@"
