#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

step() {
  echo
  echo "=== $* ==="
}

log "================================================="
echo "=      Начало проверки установки системы.       ="
echo "================================================="

step "1. Установка системы через Setup Full System"

cd "$ROOT_DIR"
echo
log "=== Запуск Setup Full System ==="

sudo_warmup() {
  # Запросить пароль один раз заранее (как при обычном sudo-вызове).
  # Если sudo не нужен/уже закеширован — вернётся мгновенно.
  if command -v sudo >/dev/null 2>&1; then
    sudo -v
  fi
}

run_task() {
  local label="$1"
  local task_file=".vscode/tasks.json"

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq не установлен. Невозможно прочитать $task_file" >&2
    return 1
  fi
  if [[ ! -r "$task_file" ]]; then
    echo "Нет прав на чтение $task_file (проверь права/владельца файла)." >&2
    return 1
  fi

  local cmd
  cmd="$(jq -er --arg label "$label" '
    .tasks[]
    | select(.label == $label)
    | (.linux.command // .command)
  ' "$task_file" 2>/dev/null || true)"


  [[ -n "$cmd" && "$cmd" != "null" ]] || {
    echo "Задача не найдена или не имеет комманды (поле command): $label" >&2
    return 1
  }

  cmd="${cmd//\$\{workspaceFolder\}/$ROOT_DIR}"
  echo "Выполнение команды: $cmd"

  # Запрос пароля для команды, требующей sudo.
  if [[ "$cmd" == *"sudo "* || "$cmd" == *" systemctl "* || "$cmd" == systemctl* ]]; then
    sudo_warmup
  fi

  bash -lc "$cmd"
}

run_task "Setup Full System"

echo
log "=== Проверка Setup Full System завершена. ==="

step "2. Проверка комманды setup через утилиту ergoms"

log "Удаление кэша и зависимостей"
ergoms clean

# if systemctl is-enabled ergo-media-api.service >/dev/null 2>&1; then
#   if [[ "$(systemctl is-enabled ergo-media-api.service 2>/dev/null || true)" == "enabled" ]]; then
#     sudo systemctl disable ergo-media-api.service
#     sudo systemctl stop ergo-media-api.service
#   fi
# fi
# npm install

ergoms setup # для linux вызовет bash core/deployment/linux/ergo_ms.sh setup-full
log "=== Проверка ergoms setup завершена. ==="

# bash core/deployment/linux/ergo_ms.sh start-services
# bash core/deployment/linux/ergo_ms.sh status-services
# bash core/deployment/linux/ergo_ms.sh logs-services
# bash core/deployment/linux/ergo_ms.sh stop-services
# bash core/deployment/linux/ergo_ms.sh uninstall-services
# bash core/deployment/linux/ergo_ms.sh uninstall-services --purge
# bash core/deployment/linux/ergo_ms.sh uninstall-services --purge

step "3. Установка служб через Install Services"
# bash core/deployment/linux/ergo_ms.sh install-services
step "3.1. Выполнение через команду утилиты ergoms: ergoms install-services"
ergoms install-all-services # для linux вызовет ergoms install-services
log "=== Проверка ergoms install-services завершена. ==="

step "3.2. Выполнение через команду Run Task: Install Services"
run_task "Install Services"
log "=== Проверка Run Task: Install Services завершена. ==="


step "4. Установка служб по отдельности"
step "4.1. Установка служб через Run Task"

log "Установка службы API Service"
run_task "Install API Service"
log "=== Проверка Run Task: Install API Service завершена. ==="

log "Установка службы Client Service"
run_task "Install Client Service"
log "=== Проверка Run Task: Install Client Service завершена. ==="

log "Установка службы Worker Service"
run_task "Install Worker Service"
log "=== Проверка Run Task: Install Worker Service завершена. ==="

log "Установка службы Beat Service"
run_task "Install Beat Service"
log "=== Проверка Run Task: Install Beat Service завершена. ==="

log "Установка службы Media Service"
run_task "Install Media Service"
log "=== Проверка Run Task: Install Media Service завершена. ==="

log "Установка службы Ollama Service"
run_task "Install Ollama Service"
log "=== Проверка Run Task: Install Ollama Service завершена. ==="

log "=== Проверка установки служб через Run Task по отдельности завершена. ==="

step "4.2. Установка служб через утилиту ergoms"
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

log "================================================="
echo "=     Проверка установки системы завершена.     ="
echo "================================================="