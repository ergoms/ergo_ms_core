#!/bin/sh
set -eu

WAIT_SCRIPT="/usr/local/lib/ergo-ms/wait_for_services.py"

if [ -f "$WAIT_SCRIPT" ]; then
  python "$WAIT_SCRIPT" || exit 1
fi

if command -v poetry >/dev/null 2>&1 && [ -f /app/pyproject.toml ]; then
  VENV_BIN="$(poetry env info -p 2>/dev/null)/bin" || VENV_BIN=""
  if [ -n "$VENV_BIN" ] && [ -d "$VENV_BIN" ]; then
    export PATH="$VENV_BIN:$PATH"
  fi
fi

exec "$@"
