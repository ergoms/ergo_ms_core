#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
enable_test_traps

cd "$ROOT_DIR"
sudo_warmup

echo "================================================="
echo "=      Начало проверки команд системы.          ="
echo "================================================="

step "1. Проверка команд базы данных"
ERGO_TEST_CURRENT_STEP="commands: db"
log "Выполнение ergoms db-makemigrations"
if ! run_cmd "ergoms db-makemigrations" ergoms db-makemigrations; then
  log "[WARNING] db-makemigrations завершился с ошибкой"
fi

log "Выполнение ergoms db-migrate"
if ! run_cmd "ergoms db-migrate" ergoms db-migrate; then
  log "[WARNING] db-migrate завершился с ошибкой"
fi

step "2. Проверка команды очистки (clean)"
ERGO_TEST_CURRENT_STEP="commands: clean"
log "Выполнение ergoms clean"
stop_all_ergoms || true
chown_project_paths_to_invoking_user
if ! run_cmd "ergoms clean (auto-confirm)" bash -lc "echo y | ergoms clean"; then
  log "[WARNING] clean завершился с ошибкой"
fi

step "3. Проверка команды логов (logs)"
ERGO_TEST_CURRENT_STEP="commands: logs"
log "Выполнение ergoms logs ergo-api-dev 10"
if ! run_cmd "ergoms logs ergo-api-dev 10" run_with_timeout 8 ergoms logs ergo-api-dev 10; then
  log "[WARNING] logs ergo-api-dev завершился с ошибкой или таймаутом"
else
  log "logs ergo-api-dev: OK"
fi

step "3.1. Run Task: Logs: All Services (эмуляция multi-terminal)"
ERGO_TEST_CURRENT_STEP="commands: logs all services"
LOGS_TASK_TEST="${SCRIPT_DIR}/logs_task_test.sh"
if [[ ! -f "$LOGS_TASK_TEST" ]]; then
  log "[WARNING] Не найден $LOGS_TASK_TEST — пропускаю тест Logs: All Services"
else
  if run_cmd "logs_task_test.sh" bash "$LOGS_TASK_TEST"; then
    log "Logs: All Services: OK"
  else
    log "[WARNING] Logs: All Services: есть ошибки"
  fi
fi

step "4. Подготовка системы к работе (финальный ergoms setup)"
ERGO_TEST_CURRENT_STEP="commands: final setup"
log "Выполнение ergoms setup"
if ! run_cmd "ergoms setup" ergoms setup; then
  log "[WARNING] ergoms setup завершился с ошибкой"
fi

echo "================================================="
echo "=     Проверка команд системы завершена.        ="
echo "================================================="
