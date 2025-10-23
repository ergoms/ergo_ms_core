#!/usr/bin/env bash
# Help system
# Система помощи

print_usage() {
  local detected_root="${1:-}"
  
  declare -A custom_cmds
  if [[ -n "$detected_root" ]]; then
    load_custom_commands "$detected_root" 2>/dev/null || true
    for key in "${!CUSTOM_COMMANDS[@]}"; do
      custom_cmds["$key"]="${CUSTOM_COMMANDS[$key]}"
    done
  fi
  
  cat <<USAGE

Ergo MS Service Manager for Linux
==================================

Usage:
  bash ergo_ms.sh [command] [options]
  ergoms [command] [options]  (after installing CLI)

Service Management Commands:
  install    Install units, save ERGO_ROOT, enable and start
  install-services Install and start services only
  install-api-service     Install and start API service only
  install-client-service  Install and start Client service only
  install-worker-service  Install and start Worker service only
  install-beat-service    Install and start Beat service only
  start      Start all services
  stop       Stop all services
  restart    Restart all services
  status     Show status for all services
  uninstall  Stop, disable, remove units; with --purge also removes /etc/default/ergo_ms
  install-cli    Install CLI wrapper /usr/local/bin/ergoms
  uninstall-cli  Remove CLI wrapper
  logs       Show logs for a service (usage: logs <service-name> [lines])
  setup-full     Full system setup (git, venv, poetry, npm) - no services

Deployment Commands (no root required):
  deploy-api     Deploy API only (install deps, migrate, collect static)
  deploy-client  Deploy Client only (install deps, build)
  deploy-api-dev Deploy and start API in development mode
  deploy-client-dev Deploy and start Client in development mode
  deploy-all     Deploy all components (API + Client)

Proxy Commands (automatically forward to respective tools):
  poetry <args>  Forward to poetry command
  api <args>     Forward to api command
  npm <args>     Forward to npm command

USAGE

  if [[ ${#custom_cmds[@]} -gt 0 ]]; then
    echo "Custom Commands:"
    echo ""
    
    # Separate core and module commands
    declare -A core_cmds
    declare -A module_cmds
    
    for cmd in "${!custom_cmds[@]}"; do
      if [[ "$cmd" == *:* ]]; then
        module_cmds["$cmd"]="${custom_cmds[$cmd]}"
      else
        core_cmds["$cmd"]="${custom_cmds[$cmd]}"
      fi
    done
    
    if [[ ${#core_cmds[@]} -gt 0 ]]; then
      echo "  Core Commands (defined in commands.conf):"
      for cmd in $(echo "${!core_cmds[@]}" | tr ' ' '\n' | sort); do
        local def="${core_cmds[$cmd]}"
        # Truncate long definitions
        if [[ ${#def} -gt 60 ]]; then
          def="${def:0:57}..."
        fi
        printf "    %-20s -> %s\n" "$cmd" "$def"
      done
      echo ""
    fi
    
    if [[ ${#module_cmds[@]} -gt 0 ]]; then
      echo "  Module Commands (defined in modules/*/ergoms.conf):"
      for cmd in $(echo "${!module_cmds[@]}" | tr ' ' '\n' | sort); do
        local def="${module_cmds[$cmd]}"
        # Truncate long definitions
        if [[ ${#def} -gt 60 ]]; then
          def="${def:0:57}..."
        fi
        printf "    %-30s -> %s\n" "$cmd" "$def"
      done
      echo ""
    fi
  fi

  cat <<USAGE
Options:
  --root <path>  Specify project root path (auto-detected if not provided)
  --purge        Remove all data when uninstalling
  --no-cli       Skip CLI wrapper installation

Examples:
  Full System Setup:
    sudo bash ergo_ms.sh setup-full
    sudo bash ergo_ms.sh setup-full --root /projects/ergo_ms
    sudo ergoms setup-full

  Service Management:
    sudo bash ergo_ms.sh install
    sudo bash ergo_ms.sh install --root /projects/ergo_ms
    sudo bash ergo_ms.sh status
    sudo bash ergo_ms.sh uninstall --purge
    ergoms start
    ergoms stop
    ergoms restart
    ergoms status
    ergoms logs ergo-api-dev
    ergoms logs ergo-client-dev 1000

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

  Deployment Commands:
    ergoms deploy-api           (deploy API only)
    ergoms deploy-client        (deploy Client only)
    ergoms deploy-api-dev       (deploy and start API in dev mode)
    ergoms deploy-client-dev    (deploy and start Client in dev mode)
    ergoms deploy-all           (deploy all components)
    
Configuration:
  Core commands: core/deployment/commands.conf
  Module commands: modules/*/ergoms.conf
  Edit these files to add your own command aliases and composite commands.

Notes:
  - Service management requires root or sudo
  - Proxy and custom commands do not require root privileges
  - For install you may pass --root

USAGE
}

export -f print_usage

