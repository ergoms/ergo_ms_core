#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
enable_test_traps

INSTALL_TEST="${SCRIPT_DIR}/install_test.sh"
EXTENSIONS_TEST="${SCRIPT_DIR}/extensions_test.sh"
DB_TEST="${SCRIPT_DIR}/db_test.sh"
RUN_TEST="${SCRIPT_DIR}/run_test.sh"
COMMAND_TEST="${SCRIPT_DIR}/command_test.sh"

for f in "${INSTALL_TEST}" "${EXTENSIONS_TEST}" "${DB_TEST}" "${RUN_TEST}" "${COMMAND_TEST}"; do
  if [[ ! -f "${f}" ]]; then
    echo "Ошибка: не найден скрипт ${f}" >&2
    exit 1
  fi
done

status_install="pending"
status_extensions="pending"
status_db="pending"
status_run="pending"
status_commands="pending"
final_error=""
exit_code=0

print_checklist() {
  echo | tee -a "$TEST_LOG_FILE" >/dev/null
  step "Чек-лист проверок (test_system): итог"
  local item
  for item in \
    "install_test.sh (окружение/установка)|$status_install" \
    "extensions_test.sh (VS Code расширения)|$status_extensions" \
    "db_test.sh (базы данных)|$status_db" \
    "run_test.sh (запуск/сервисы)|$status_run" \
    "command_test.sh (команды)|$status_commands"
  do
    IFS='|' read -r name st <<<"$item"
    log "[RESULT] ${name} - ${st}"
    echo "- ${name}: ${st}" | tee -a "$TEST_LOG_FILE" >/dev/null
  done
  if [[ -n "$final_error" ]]; then
    log "[ERROR] test_system: ${final_error}"
    echo "Ошибка, из-за которой остановился скрипт: ${final_error}" | tee -a "$TEST_LOG_FILE" >/dev/null
  fi
  log "[RESULT] test_system: код выхода = ${exit_code}"
}

trap 'print_checklist' EXIT

log "test.sh: этап 1/3 - install_test.sh (окружение, установка)"
status_install="fail"
if bash "${INSTALL_TEST}" "$@"; then
  status_install="ok"
  log "[OK] test_system: install_test.sh пройден; переход к extensions_test"
else
  final_error="install_test.sh завершился с ошибкой"
  exit_code=1
  exit 1
fi

echo
log "test.sh: этап 2/5 - extensions_test.sh (VS Code расширения)"
status_extensions="fail"
if bash "${EXTENSIONS_TEST}" "$@"; then
  status_extensions="ok"
  log "[OK] test_system: extensions_test.sh пройден; переход к db_test"
else
  # Extensions on Linux can be unavailable in headless/remote environments.
  # This should not stop the remaining checks; we only warn and continue.
  status_extensions="fail"
  log "[WARNING] extensions_test.sh завершился с ошибкой. Продолжаем тест."
fi

echo
log "test.sh: этап 3/5 - db_test.sh (базы данных)"
status_db="fail"
if bash "${DB_TEST}" "$@"; then
  status_db="ok"
  log "[OK] test_system: db_test.sh пройден; переход к run_test"
else
  final_error="db_test.sh завершился с ошибкой"
  exit_code=1
  exit 1
fi

echo
log "test.sh: этап 4/5 - run_test.sh (запуск, сервисы)"
status_run="fail"
if bash "${RUN_TEST}" "$@"; then
  status_run="ok"
  log "[OK] test_system: run_test.sh пройден; переход к command_test"
else
  final_error="run_test.sh завершился с ошибкой"
  exit_code=1
  exit 1
fi

echo
log "test.sh: этап 5/5 - command_test.sh (команды)"
status_commands="fail"
if bash "${COMMAND_TEST}" "$@"; then
  status_commands="ok"
  log "[OK] test_system: все этапы завершены. Тесты прошли."
else
  final_error="command_test.sh завершился с ошибкой"
  exit_code=1
  exit 1
fi

echo
echo "=== test.sh: все этапы завершены ==="
