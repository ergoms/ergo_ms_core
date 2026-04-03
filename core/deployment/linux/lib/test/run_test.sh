#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$ROOT_DIR"
# Один запрос пароля sudo на сессию; дальше systemctl_do не дергает polkit на каждый unit (в отличие от ergoms *-service).
sudo_warmup

echo "================================================="
echo "=      Начало проверки запуска системы.         ="
echo "================================================="
step "Предусловие: проверка установки и артефактов перед проверкой запуска системы"
require_install_ready_for_launch
echo
log "Предусловия выполнены. Система готова к запуску."

step "1. Запуск системы через Run Task: Start All Services"
echo "Предварительная остановка системы"
stop_all_ergoms
log "Запуск системы через Start All Services"
# Без detached parallel wait завершится сразу, а stop_all_ergoms убьёт только что поднятые процессы.
ERGO_RUN_TASK_DETACHED=1 run_task "Start All Services"
log "Ожидание стабилизации сервисов перед проверкой статуса (5 с)…"
sleep 5
echo
ergoms status || true
stop_all_ergoms
log "=== Запуск системы через Start All Services завершен. ==="

step "2. Запуск системы через ergoms start"
log "Предварительная остановка системы"
stop_all_ergoms
log "Запуск системы через ergoms start"
ergoms start
log "Ожидание стабилизации сервисов перед проверкой статуса (5 с)…"
sleep 5
echo
ergoms status || true
stop_all_ergoms
log "=== Запуск при помощи служб завершён. ==="

step "3. Отдельный запуск сервисов (api, media, client, celery-beat, worker)"
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

step "3.4. Celery: API + beat + все worker unit'ы из конфига → ping → show_next_tasks → стоп"
test_svc_systemctl start ergo-api-dev
sleep 4
test_svc_systemctl start ergo-celery-beat
sleep 3
start_worker_services_from_config
sleep 6
if run_celery_worker_inspect_ping; then
  log "celery inspect ping: OK"
else
  log "[WARNING] celery inspect ping не прошёл (брокер, worker или таймаут)"
fi
if run_celery_beat_show_next_tasks; then
  log "show_next_tasks: выполнено"
else
  log "[WARNING] show_next_tasks завершился с ошибкой"
fi
stop_worker_services_from_config
test_svc_systemctl stop ergo-celery-beat || true
test_svc_systemctl stop ergo-api-dev || true

stop_all_ergoms
log "=== Шаг 3 (отдельные сервисы и Celery) завершён. ==="