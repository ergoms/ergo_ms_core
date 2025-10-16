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

print_usage() {
  cat <<USAGE
Usage:
  sudo bash $0 [install|start|stop|restart|status|uninstall|install-cli|uninstall-cli] [--root /abs/path|--root=/abs/path|/abs/path] [--purge] [--no-cli]

Commands:
  install    Install units, save ERGO_ROOT, enable and start
  start      Start all services
  stop       Stop all services
  restart    Restart all services
  status     Show status for all services
  uninstall  Stop, disable, remove units; with --purge also removes /etc/default/ergo_ms
  install-cli    Install CLI wrapper /usr/local/bin/ergoms
  uninstall-cli  Remove CLI wrapper

If no command is provided, this help is shown. For install you may pass --root.
USAGE
}

main() {
  require_root_or_sudo

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

  # First positional can be a command
  if (( $# > 0 )); then
    case "$1" in
      install|start|stop|restart|status|uninstall|install-cli|uninstall-cli)
        command="$1"; shift ;;
      -h|--help)
        print_usage; exit 0 ;;
    esac
  fi

  # If no command provided, show help
  if [[ -z "$command" ]]; then
    print_usage
    exit 0
  fi

  # Parse flags/positional root
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


