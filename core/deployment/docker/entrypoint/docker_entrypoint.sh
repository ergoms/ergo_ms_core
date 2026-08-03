#!/bin/sh
set -eu

WAIT_SCRIPT_IMAGE="/usr/local/lib/ergo-ms/wait_for_services.py"
SETUP_SCRIPT_IMAGE="/usr/local/lib/ergo-ms/wait_for_docker_setup.py"
WAIT_SCRIPT_MOUNTED="/app/core/deployment/docker/entrypoint/wait_for_services.py"
SETUP_SCRIPT_MOUNTED="/app/core/deployment/docker/entrypoint/wait_for_docker_setup.py"
ERGOMS_SRC_MOUNTED="/app/core/deployment/docker/entrypoint/ergoms.sh"
ERGOMS_SRC_IMAGE="/usr/local/lib/ergo-ms/ergoms.sh"
# Предпочтение: CLI из дерева проекта; запасной — только слой образа (вне bind-mount /app)
ERGOMS_PROJECT_BIN="/app/core/deployment/bin"
ERGOMS_FALLBACK_BIN="/usr/local/bin/ergoms"

# Обёртка ergoms для shell в контейнере.
# Бинарь entrypoint лежит вне /app (CRLF bind-mount на Windows).
# Wait-скрипты предпочитаем из /app (актуальный код), иначе — слой образа.
_install_ergoms_cli() {
  export PATH="${ERGOMS_PROJECT_BIN}:/app/virtual_env/python/bin:${PATH:-}"
  if [ -d /app/core/deployment ]; then
    export PYTHONPATH="/app/core/deployment${PYTHONPATH:+:$PYTHONPATH}"
  fi

  if [ -x "${ERGOMS_PROJECT_BIN}/ergoms" ]; then
    return 0
  fi

  src=""
  if [ -f "$ERGOMS_SRC_MOUNTED" ]; then
    src="$ERGOMS_SRC_MOUNTED"
  elif [ -f "$ERGOMS_SRC_IMAGE" ]; then
    src="$ERGOMS_SRC_IMAGE"
  fi
  if [ -n "$src" ]; then
    # sed: убрать CRLF с Windows-хоста при bind-mount
    sed 's/\r$//' "$src" >"$ERGOMS_FALLBACK_BIN"
    chmod +x "$ERGOMS_FALLBACK_BIN"
  fi
}

_run_python_script() {
  # $1 image path, $2 mounted path
  script="$1"
  if [ -f "$2" ]; then
    script="$2"
  fi
  if [ -f "$script" ]; then
    # CRLF с Windows-хоста ломает shebang/import при прямом запуске mounted .py
    if [ "$script" = "$2" ]; then
      tmp="$(mktemp)"
      sed 's/\r$//' "$script" >"$tmp"
      python "$tmp" || { rm -f "$tmp"; exit 1; }
      rm -f "$tmp"
    else
      python "$script" || exit 1
    fi
  fi
}

_install_ergoms_cli

_run_python_script "$WAIT_SCRIPT_IMAGE" "$WAIT_SCRIPT_MOUNTED"
_run_python_script "$SETUP_SCRIPT_IMAGE" "$SETUP_SCRIPT_MOUNTED"

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
