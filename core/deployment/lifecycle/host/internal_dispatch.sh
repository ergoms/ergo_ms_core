#!/usr/bin/env bash
# Внутренний dispatch для lifecycle (services, nginx, redis, postgres, tls, cli).
set -euo pipefail

category="${1:?category}"
operation="${2:?operation}"
root="${3:?root}"
shift 3 || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../linux/lib" && pwd)"

# shellcheck source=../../linux/lib/core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=../../linux/lib/systemd.sh
source "$LIB_DIR/systemd.sh"
# shellcheck source=../../linux/lib/services.sh
source "$LIB_DIR/services.sh"
# shellcheck source=../../linux/lib/cli.sh
source "$LIB_DIR/cli.sh"
# shellcheck source=../../linux/lib/nginx.sh
source "$LIB_DIR/nginx.sh"
# shellcheck source=../../linux/lib/redis.sh
source "$LIB_DIR/redis.sh"
# shellcheck source=../../linux/lib/postgres.sh
source "$LIB_DIR/postgres.sh"
# shellcheck source=../../linux/lib/tls.sh
source "$LIB_DIR/tls.sh"
# shellcheck source=../../linux/lib/portable_python.sh
source "$LIB_DIR/portable_python.sh"
# shellcheck source=../../linux/lib/portable_nodejs.sh
source "$LIB_DIR/portable_nodejs.sh"

set_service_project_root "$root"

case "$category" in
  service)
    case "$operation" in
      install-all) install_services "$root"; start_all ;;
      install-api) install_single_service "api" "$root"; systemctl_do start ergo-api-dev.service ;;
      install-client) install_single_service "client" "$root"; systemctl_do start ergo-client-dev.service 2>/dev/null || true ;;
      install-media) install_single_service "media" "$root"; systemctl_do start ergo-media-api.service ;;
      install-beat) install_single_service "beat" "$root"; systemctl_do start ergo-celery-beat.service ;;
      install-workers) install_single_service "worker" "$root" ;;
      start-all) start_all ;;
      start-api) systemctl_do start ergo-api-dev.service ;;
      start-client) systemctl_do start ergo-client-dev.service ;;
      start-media) systemctl_do start ergo-media-api.service ;;
      start-beat) systemctl_do start ergo-celery-beat.service ;;
      start-workers)
        for u in $(units_list "$root"); do
          [[ "$u" == ergo-celery-worker* ]] && systemctl_do start "$u"
        done
        ;;
      stop-all) stop_all ;;
      stop-api) systemctl_do stop ergo-api-dev.service ;;
      stop-client) systemctl_do stop ergo-client-dev.service ;;
      stop-media) systemctl_do stop ergo-media-api.service ;;
      stop-beat) systemctl_do stop ergo-celery-beat.service ;;
      stop-workers)
        for u in $(units_list "$root"); do
          [[ "$u" == ergo-celery-worker* ]] && systemctl_do stop "$u"
        done
        ;;
      restart-all) restart_all ;;
      restart-api) systemctl_do restart ergo-api-dev.service ;;
      restart-client) systemctl_do restart ergo-client-dev.service ;;
      restart-media) systemctl_do restart ergo-media-api.service ;;
      restart-beat) systemctl_do restart ergo-celery-beat.service ;;
      restart-workers)
        for u in $(units_list "$root"); do
          [[ "$u" == ergo-celery-worker* ]] && systemctl_do restart "$u"
        done
        ;;
      status-all) status_all ;;
      status-api) systemctl_do status ergo-api-dev.service ;;
      status-client) systemctl_do status ergo-client-dev.service ;;
      status-media) systemctl_do status ergo-media-api.service ;;
      status-beat) systemctl_do status ergo-celery-beat.service ;;
      status-workers)
        for u in $(units_list "$root"); do
          [[ "$u" == ergo-celery-worker* ]] && systemctl_do status "$u"
        done
        ;;
      uninstall-all)
        purge=false
        [[ "${1:-}" == "--purge" ]] && purge=true
        uninstall_all "$purge"
        ;;
      *) echo "[ERROR] Неизвестная операция service: $operation" >&2; exit 1 ;;
    esac
    ;;
  nginx)
    case "$operation" in
      install) nginx_install "$root" "${1:-}" "${2:-}" "false" ;;
      uninstall)
        purge=false
        [[ "${1:-}" == "--purge" ]] && purge=true
        nginx_uninstall "$root" "$purge"
        ;;
      start) nginx_start_service "$root" ;;
      stop) nginx_stop_service "$root" ;;
      restart) nginx_stop_service "$root"; nginx_start_service "$root" ;;
      reload) nginx_reload_service "$root" ;;
      status) nginx_status_service "$root" ;;
      test) nginx_test_config "$root" ;;
      *) echo "[ERROR] Неизвестная операция nginx: $operation" >&2; exit 1 ;;
    esac
    ;;
  redis)
    port=""
    for arg in "$@"; do
      case "$arg" in
        --purge) purge_flag=true ;;
        [0-9]*) port="$arg" ;;
      esac
    done
    case "$operation" in
      install) redis_install "$root" "$port" "false" ;;
      uninstall)
        purge=false
        [[ "${1:-}" == "--purge" ]] && purge=true
        redis_uninstall "$root" "$purge"
        ;;
      start) redis_start "$root" ;;
      stop) redis_stop "$root" ;;
      restart) redis_restart "$root" ;;
      status) redis_status "$root" ;;
      test) redis_test "$root" ;;
      *) echo "[ERROR] Неизвестная операция redis: $operation" >&2; exit 1 ;;
    esac
    ;;

  postgres)
    port=""
    no_skip=false
    purge=false
    for arg in "$@"; do
      case "$arg" in
        --purge) purge=true ;;
        --no-skip-system) no_skip=true ;;
        [0-9]*) port="$arg" ;;
      esac
    done
    case "$operation" in
      install)
        if [[ "$no_skip" == true ]]; then
          postgres_install "$root" "$port" "true"
        else
          postgres_install "$root" "$port" "false"
        fi
        ;;
      uninstall) postgres_uninstall "$root" "$purge" ;;
      start) postgres_start "$root" ;;
      stop) postgres_stop "$root" ;;
      restart) postgres_restart "$root" ;;
      status) postgres_status "$root" ;;
      test) postgres_test "$root" ;;
      *) echo "[ERROR] Неизвестная операция postgres: $operation" >&2; exit 1 ;;
    esac
    ;;
  tls)
    case "$operation" in
      install) tls_install "$root" "${1:-}" "${2:-}" "${3:-false}" ;;
      renew)
        dry=false
        [[ "${1:-}" == "--dry-run" ]] && dry=true
        tls_renew "$root" "$dry"
        ;;
      status) tls_status "$root" ;;
      *) echo "[ERROR] Неизвестная операция tls: $operation" >&2; exit 1 ;;
    esac
    ;;
  cli)
    case "$operation" in
      install) create_cli_wrapper "$root" ;;
      uninstall) remove_cli_wrapper "$root" ;;
      *) echo "[ERROR] Неизвестная операция cli: $operation" >&2; exit 1 ;;
    esac
    ;;
  runtime)
    force=false
    [[ "${1:-}" == "--force" ]] && force=true
    case "$operation" in
      install-python) install_portable_python "$root" "$force" ;;
      install-nodejs) install_portable_nodejs "$root" "$force" ;;
      *) echo "[ERROR] Неизвестная операция runtime: $operation" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "[ERROR] Неизвестная категория: $category" >&2
    exit 1
    ;;
esac
