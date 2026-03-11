#!/usr/bin/env bash
# Кроссплатформенный launcher для MCP Python серверов (Linux / macOS / WSL / Windows+Git Bash)
# Пробует python3, затем py -3, затем python
if command -v python3 >/dev/null 2>&1; then
    exec python3 "$@"
elif command -v py >/dev/null 2>&1; then
    exec py -3 "$@"
else
    exec python "$@"
fi
