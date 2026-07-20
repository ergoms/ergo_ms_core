#!/bin/sh
set -eu

WAIT_SCRIPT="/usr/local/lib/ergo-ms/wait_for_services.py"
SETUP_SCRIPT="/usr/local/lib/ergo-ms/wait_for_docker_setup.py"
ERGOMS_SRC_MOUNTED="/app/core/deployment/docker/entrypoint/ergoms.sh"
ERGOMS_SRC_IMAGE="/usr/local/lib/ergo-ms/ergoms.sh"
ERGOMS_BIN="/usr/local/bin/ergoms"

# Обёртка ergoms для shell в контейнере (bind-mount в dev предпочтительнее образа).
_install_ergoms_cli() {
  src=""
  if [ -f "$ERGOMS_SRC_MOUNTED" ]; then
    src="$ERGOMS_SRC_MOUNTED"
  elif [ -f "$ERGOMS_SRC_IMAGE" ]; then
    src="$ERGOMS_SRC_IMAGE"
  fi
  if [ -n "$src" ]; then
    # sed: убрать CRLF с Windows-хоста при bind-mount
    sed 's/\r$//' "$src" >"$ERGOMS_BIN"
    chmod +x "$ERGOMS_BIN"
  fi
}

_install_ergoms_cli

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

if [ -n "${ERGO_DOCKER_SERVICE_NAME:-}" ] && [ "${ERGO_DOCKER_CONSOLE_OUTPUT:-}" != "1" ]; then
  LOG_DIR="${ERGO_DOCKER_LOG_DIR:-/app/logs/docker}"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/${ERGO_DOCKER_SERVICE_NAME}.log"
  echo "[INFO] Журнал Docker: ${LOG_FILE}" >&2
  exec >>"$LOG_FILE" 2>&1
fi

if [ -n "${ERGO_DOCKER_SERVICE_NAME:-}" ] && [ "${ERGO_DOCKER_CONSOLE_OUTPUT:-}" = "1" ]; then
  LOG_DIR="${ERGO_DOCKER_LOG_DIR:-/app/logs/docker}"
  mkdir -p "$LOG_DIR"
  echo "[INFO] Вывод также пишется в ${LOG_DIR}/ (см. tee в команде установки)" >&2
fi

exec "$@"
