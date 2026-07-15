#!/bin/sh
set -eu

WAIT_SCRIPT="/usr/local/lib/ergo-ms/wait_for_services.py"
SETUP_SCRIPT="/usr/local/lib/ergo-ms/wait_for_docker_setup.py"

if [ -f "$WAIT_SCRIPT" ]; then
  python "$WAIT_SCRIPT" || exit 1
fi

if [ -f "$SETUP_SCRIPT" ]; then
  python "$SETUP_SCRIPT" || exit 1
fi

if command -v poetry >/dev/null 2>&1 && [ -f /app/pyproject.toml ]; then
  VENV_BIN="$(poetry env info -p 2>/dev/null)/bin" || VENV_BIN=""
  if [ -n "$VENV_BIN" ] && [ -d "$VENV_BIN" ]; then
    export PATH="$VENV_BIN:$PATH"
  fi
fi

if [ -n "${ERGO_DOCKER_SERVICE_NAME:-}" ]; then
  LOG_DIR="${ERGO_DOCKER_LOG_DIR:-/app/logs/docker}"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/${ERGO_DOCKER_SERVICE_NAME}.log"
  echo "[INFO] Журнал Docker: ${LOG_FILE}" >&2
  exec >>"$LOG_FILE" 2>&1
fi

exec "$@"
