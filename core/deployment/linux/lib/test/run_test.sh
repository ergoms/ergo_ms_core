#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
enable_test_traps

cd "$ROOT_DIR"
sudo_warmup

echo "================================================="
echo "=      Начало проверки запуска системы.         ="
echo "================================================="
step "Предусловие: проверка установки и артефактов перед проверкой запуска системы"
ERGO_TEST_CURRENT_STEP="run: prerequisites"
require_install_ready_for_launch
echo
log "Предусловия выполнены. Система готова к запуску."

step "1. Запуск системы через Run Task: Start All Services"
ERGO_TEST_CURRENT_STEP="run: task Start All Services"
echo "Предварительная остановка системы"
stop_all_ergoms
log "Запуск системы через Start All Services"
ERGO_RUN_TASK_DETACHED=1 run_cmd "run_task Start All Services" run_task "Start All Services"
log "Ожидание стабилизации сервисов перед проверкой статуса (5 с)…"
sleep 5
echo
run_cmd "ergoms status" ergoms status || true
stop_all_ergoms
log "=== Запуск системы через Start All Services завершен. ==="

step "2. Запуск системы через ergoms start"
ERGO_TEST_CURRENT_STEP="run: ergoms start"
log "Предварительная остановка системы"
stop_all_ergoms
log "Запуск системы через ergoms start"
run_cmd "ergoms start" ergoms start
log "Ожидание стабилизации сервисов перед проверкой статуса (5 с)…"
sleep 5
echo
run_cmd "ergoms status" ergoms status || true
stop_all_ergoms
log "=== Запуск при помощи служб завершён. ==="

step "3. Отдельный запуск сервисов (api, media, client, celery-beat, worker)"
ERGO_TEST_CURRENT_STEP="run: per-service systemctl"
echo "Условия для воркеров:"
echo "  — Число systemd unit'ов = числу ключей в workers: в celery_workers.yaml (либо один ergo-celery-worker.service без yaml)."
echo "  — Сценарии «много / мало» воркеров: разный celery_workers.yaml и повторная установка: ergoms install-worker-service."
echo "  — Проверка worker: celery inspect ping (задачи доходят до исполнителя)."
echo "  — Проверка beat: ergoms api show_next_tasks (расписание; полный цикл периодики — отдельный ручной/долгий тест)."
stop_all_ergoms

step "3.1. API: старт → статус → стоп"
test_svc_systemctl start ergo-api-dev
sleep 3
( test_svc_systemctl status ergo-api-dev | head -25 ) || true
test_svc_systemctl stop ergo-api-dev || true

step "3.2. Media API: старт → статус → стоп"
test_svc_systemctl start ergo-media-api
sleep 3
( test_svc_systemctl status ergo-media-api | head -25 ) || true
test_svc_systemctl stop ergo-media-api || true

step "3.3. Client: старт → статус → стоп"
test_svc_systemctl start ergo-client-dev
sleep 3
( test_svc_systemctl status ergo-client-dev | head -25 ) || true
test_svc_systemctl stop ergo-client-dev || true

step "3.4. Celery: расширенный тест (yaml сценарии, worker task, beat)"
ERGO_TEST_CURRENT_STEP="run: celery_test"
CELERY_TEST="${SCRIPT_DIR}/celery_test.sh"
if [[ ! -f "$CELERY_TEST" ]]; then
  log "[WARNING] Не найден $CELERY_TEST — пропускаю расширенный тест Celery"
else
  run_cmd "celery_test.sh" bash "$CELERY_TEST"
fi

stop_all_ergoms
log "=== Шаг 3 (отдельные сервисы и Celery) завершён. ==="

echo "================================================="
echo "=     Проверка запуска системы завершена.       ="
echo "================================================="