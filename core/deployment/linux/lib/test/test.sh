#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
cd "$ROOT_DIR"
INSTALL_TEST="${SCRIPT_DIR}/install_test.sh"
RUN_TEST="${SCRIPT_DIR}/run_test.sh"

for f in "${INSTALL_TEST}" "${RUN_TEST}"; do
  if [[ ! -f "${f}" ]]; then
    echo "Ошибка: не найден скрипт ${f}" >&2
    exit 1
  fi
done

echo "=== test.sh: этап установки (install_test.sh) ==="
bash "${INSTALL_TEST}" "$@"

echo
echo "=== test.sh: этап запуска (run_test.sh) ==="
bash "${RUN_TEST}" "$@"

echo
echo "=== test.sh: оба этапа завершены ==="
