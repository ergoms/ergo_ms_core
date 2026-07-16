#!/usr/bin/env bash
# Lifecycle runner invocation for Linux ergo_ms

invoke_lifecycle_runner() {
  local root="$1"
  local recipe="$2"
  shift 2
  local runner="$root/core/deployment/lifecycle/runner.py"
  local venv_py="$root/virtual_env/python/bin/python"

  if [[ ! -f "$runner" ]]; then
    echo "[ERROR] lifecycle runner не найден: $runner" >&2
    exit 1
  fi

  if [[ "$recipe" == "setup-full" && ! -x "$venv_py" ]]; then
    if command -v python3.12 >/dev/null 2>&1; then
      python3.12 "$runner" "$recipe" "$@"
    else
      python3 "$runner" "$recipe" "$@"
    fi
  elif [[ -x "$venv_py" ]]; then
    "$venv_py" "$runner" "$recipe" "$@"
  elif command -v python3.12 >/dev/null 2>&1; then
    python3.12 "$runner" "$recipe" "$@"
  else
    python3 "$runner" "$recipe" "$@"
  fi
}

export -f invoke_lifecycle_runner
