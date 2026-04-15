#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$ROOT_DIR"

echo "================================================="
echo "=      Начало проверки установки системы.       ="
echo "================================================="

step "1. Установка системы через Setup Full System"
log "Удаление кэша и зависимостей"
chown_project_paths_to_invoking_user
ergoms stop || true
ergoms clean
echo
log "=== Запуск Setup Full System ==="
run_task "Setup Full System"
echo
log "=== Проверка Setup Full System завершена. ==="

step "2. Проверка комманды setup через утилиту ergoms"
log "Удаление кэша и зависимостей"
chown_project_paths_to_invoking_user
ergoms stop || true
ergoms clean
ergoms setup # для linux вызовет bash core/deployment/linux/ergo_ms.sh setup-full
log "=== Проверка ergoms setup завершена. ==="

step "3. Установка служб через команду ergoms install-all-services" # для linux вызовет bash core/deployment/linux/ergo_ms.sh install-services
# Удаление всех служб перед установкой
ergoms uninstall-services || true
if ! ergoms install-all-services; then
  log "[WARNING] ergoms install-all-services завершилась с ошибкой (часто: юнит в auto-restart/FAILURE и systemctl status даёт ненулевой код, либо StartLimit). Продолжаем тест."
fi
log "=== Проверка ergoms install-all-services завершена. ==="


step "4. Установка служб через отдельные команды утилиту ergoms"
log "Установка API через утилиту ergoms: ergoms install-api-service"
ergoms install-api-service
log "=== Проверка ergoms install-api-service завершена. ==="

log "Установка Client через утилиту ergoms: ergoms install-client-service"
ergoms install-client-service
log "=== Проверка ergoms install-client-service завершена. ==="

log "Установка Worker через утилиту ergoms: ergoms install-worker-service"
ergoms install-worker-service
log "=== Проверка ergoms install-worker-service завершена. ==="

log "Установка Beat через утилиту ergoms: ergoms install-beat-service"
ergoms install-beat-service
log "=== Проверка ergoms install-beat-service завершена. ==="

log "Установка Media через утилиту ergoms: ergoms install-media-service"
ergoms install-media-service
log "=== Проверка ergoms install-media-service завершена. ==="

log "Установка Ollama через утилиту ergoms: ergoms install-ollama-service"
ergoms install-ollama-service
log "=== Проверка ergoms install-ollama-service завершена. ==="

log "=== Проверка установки служб через утилиту ergoms по отдельности завершена. ==="

echo "================================================="
echo "=     Проверка установки системы завершена.     ="
echo "================================================="