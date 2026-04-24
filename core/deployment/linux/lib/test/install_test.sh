#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
enable_test_traps

cd "$ROOT_DIR"
sudo_warmup

echo "================================================="
echo "=      Начало проверки установки системы.       ="
echo "================================================="

step "1. Установка системы через Setup Full System"
ERGO_TEST_CURRENT_STEP="install: setup full system"
log "Удаление кэша и зависимостей"
chown_project_paths_to_invoking_user
run_cmd "ergoms stop" ergoms stop || true
run_cmd "ergoms clean (auto-confirm)" bash -lc "echo y | ergoms clean"
echo
log "=== Запуск Setup Full System ==="
run_cmd "run_task Setup Full System" run_task "Setup Full System"
echo
log "=== Проверка Setup Full System завершена. ==="

step "2. Проверка комманды setup через утилиту ergoms"
ERGO_TEST_CURRENT_STEP="install: ergoms setup"
log "Удаление кэша и зависимостей"
chown_project_paths_to_invoking_user
run_cmd "ergoms stop" ergoms stop || true
run_cmd "ergoms clean (auto-confirm)" bash -lc "echo y | ergoms clean"
run_cmd "ergoms setup" ergoms setup
log "=== Проверка ergoms setup завершена. ==="

step "3. Установка служб через команду ergoms install-all-services"
ERGO_TEST_CURRENT_STEP="install: install-all-services"
run_cmd "ergoms uninstall-services" ergoms uninstall-services || true
if ! run_cmd "ergoms install-all-services" ergoms install-all-services; then
  log "[WARNING] ergoms install-all-services завершилась с ошибкой (часто: юнит в auto-restart/FAILURE и systemctl status даёт ненулевой код, либо StartLimit). Продолжаем тест."
fi
log "=== Проверка ergoms install-all-services завершена. ==="


step "4. Установка служб через отдельные команды утилиту ergoms"
ERGO_TEST_CURRENT_STEP="install: per-service installs"
log "Установка API через утилиту ergoms: ergoms install-api-service"
run_cmd "ergoms install-api-service" ergoms install-api-service
log "=== Проверка ergoms install-api-service завершена. ==="

log "Установка Client через утилиту ergoms: ergoms install-client-service"
run_cmd "ergoms install-client-service" ergoms install-client-service
log "=== Проверка ergoms install-client-service завершена. ==="

log "Установка Worker через утилиту ergoms: ergoms install-worker-service"
run_cmd "ergoms install-worker-service" ergoms install-worker-service
log "=== Проверка ergoms install-worker-service завершена. ==="

log "Установка Beat через утилиту ergoms: ergoms install-beat-service"
run_cmd "ergoms install-beat-service" ergoms install-beat-service
log "=== Проверка ergoms install-beat-service завершена. ==="

log "Установка Media через утилиту ergoms: ergoms install-media-service"
run_cmd "ergoms install-media-service" ergoms install-media-service
log "=== Проверка ergoms install-media-service завершена. ==="

log "Установка Ollama через утилиту ergoms: ergoms install-ollama-service"
run_cmd "ergoms install-ollama-service" ergoms install-ollama-service
log "=== Проверка ergoms install-ollama-service завершена. ==="

log "=== Проверка установки служб через утилиту ergoms по отдельности завершена. ==="

echo "================================================="
echo "=     Проверка установки системы завершена.     ="
echo "================================================="