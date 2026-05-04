#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
enable_test_traps

cd "$ROOT_DIR"
sudo_warmup

backup_and_prepare_workers_yaml() {
  local yaml="$ROOT_DIR/celery_workers.yaml"
  local bak="$ROOT_DIR/celery_workers.yaml.test.bak"
  cp -f "$yaml" "$bak"

  restore_workers_yaml() {
    if [[ -f "$bak" ]]; then
      cp -f "$bak" "$yaml"
      rm -f "$bak"
    fi
  }
  trap restore_workers_yaml EXIT
}

write_workers_yaml() {
  local keys="${1:?}"
  local yaml="$ROOT_DIR/celery_workers.yaml"

  {
    echo "workers:"
    local k
    for k in $keys; do
      cat <<YAML
  ${k}:
    description: "autotest worker ${k}"
    hostname: "${k}_worker"
    queues: all
    concurrency: 1

YAML
    done
    cat <<'YAML'
defaults:
  pool: threads
  loglevel: info
  events: true
YAML
  } >"$yaml"
}

reinstall_worker_services_from_yaml() {
  log "Переустановка worker-служб: ergoms install-worker-service (перечитать celery_workers.yaml)"
  ergoms install-worker-service
  _test_source_core_sh || return 1
  daemon_reload
  reset_units_cache
}

assert_workers_services_match_config() {
  _test_source_core_sh || return 1

  local workers expected actual missing=0
  workers="$(get_celery_workers "$ROOT_DIR" || true)"
  if [[ -z "${workers// }" ]]; then
    log "[WARNING] celery_workers.yaml не найден или пустой; проверка соответствия воркеров пропущена"
    return 1
  fi

  expected=""
  local w
  for w in $workers; do expected="${expected} ergo-celery-worker-${w}"; done
  actual="$(systemctl list-units --all --type=service --no-legend 'ergo-celery-worker-*.service' 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' || true)"

  log "Workers в celery_workers.yaml: $workers"
  log "Ожидаемые службы: $(echo "$expected" | xargs)"
  log "Найденные службы: $(echo "$actual" | tr '\n' ' ' | xargs)"

  for w in $workers; do
    if ! echo "$actual" | grep -qx "ergo-celery-worker-${w}"; then
      log "[WARNING] Нет службы для воркера из celery_workers.yaml: ergo-celery-worker-${w}"
      missing=1
    fi
  done
  return "$missing"
}

start_and_check_worker_services() {
  _test_source_core_sh || return 1
  local ok=0 w
  for w in $(get_worker_service_names "$ROOT_DIR"); do
    log "Запуск воркера-службы: ${w}.service"
    systemctl_do start "${w}.service" || ok=1
  done
  sleep 6
  for w in $(get_worker_service_names "$ROOT_DIR"); do
    if systemctl is-active --quiet "${w}.service"; then
      log "${w}: Running"
    else
      ok=1
      log "[WARNING] ${w}: NOT Running"
    fi
  done
  stop_worker_services_from_config || true
  return "$ok"
}

run_celery_worker_task_test() {
  require_python_venv
  local root="$ROOT_DIR"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local task_mod="${tmp_dir}/_ergo_celery_test_task.py"
  local send_script="${tmp_dir}/_ergo_celery_send_task.py"
  local worker_pid=""
  local worker_log="${tmp_dir}/_ergo_celery_worker.log"

  cleanup() {
    set +e
    if [[ -n "$worker_pid" ]]; then
      log "Остановка test worker PID=${worker_pid}"
      kill -9 "$worker_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir" 2>/dev/null || true
  }
  trap cleanup EXIT

  cat >"$task_mod" <<'PY'
from src.config.celery import celery_app

@celery_app.task(name="ergo_test_ping")
def ergo_test_ping():
    return "pong"
PY

  cat >"$send_script" <<'PY'
import sys
import django
django.setup()
from src.config.celery import celery_app
r = celery_app.send_task("ergo_test_ping")
val = r.get(timeout=15)
print(val)
sys.exit(0 if val == "pong" else 1)
PY

  (
    cd "$root/core/api"
    # shellcheck disable=SC1091
    . "$root/virtual_env/python/bin/activate"
    export PYTHONPATH="$tmp_dir:$root:$root/core/api"
    export DJANGO_SETTINGS_MODULE="src.config.patterns.test"

    log "Запуск test worker с задачей ergo_test_ping..."
    celery -A src.config.celery.celery_app worker --loglevel=info -Q default --concurrency=1 -n test_worker@%h --include=_ergo_celery_test_task >"$worker_log" 2>&1 &
    worker_pid="$!"
    export worker_pid
    sleep 6

    if ! kill -0 "$worker_pid" 2>/dev/null; then
      log "[WARNING] worker завершился преждевременно"
      log_tail_file "$worker_log" 80
      exit 1
    fi

    log "Проверка, что задача зарегистрирована на воркере (celery inspect registered)..."
    local ok_registered=1
    local i
    for i in 1 2 3 4 5; do
      if celery -A src.config.celery.celery_app inspect registered --timeout 5 2>/dev/null | grep -q "ergo_test_ping"; then
        ok_registered=0
        break
      fi
      sleep 2
    done
    if [[ "$ok_registered" -ne 0 ]]; then
      log "[WARNING] Тестовая задача ergo_test_ping не зарегистрирована на воркере. Скорее всего, include-модуль не импортировался."
      log_tail_file "$worker_log" 120
      exit 1
    fi

    log "Отправка задачи ergo_test_ping и ожидание результата..."
    if ! python "$send_script"; then
      log_tail_file "$worker_log" 120
      exit 1
    fi
  )
}

run_celery_beat_execution_test() {
  require_python_venv
  local root="$ROOT_DIR"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local task_name="ergo_test_ping"
  local periodic_name="ergo_test_periodic_ping"

  cleanup() { rm -rf "$tmp_dir" 2>/dev/null || true; }
  trap cleanup RETURN

  cat >"${tmp_dir}/_ergo_celery_test_task.py" <<PY
from src.config.celery import celery_app

@celery_app.task(name="${task_name}")
def ergo_test_ping():
    return "pong"
PY

  cat >"${tmp_dir}/_create_periodic.py" <<PY
import django
django.setup()
from django_celery_beat.models import IntervalSchedule, PeriodicTask
PeriodicTask.objects.filter(name="${periodic_name}").delete()
schedule, _ = IntervalSchedule.objects.get_or_create(every=5, period=IntervalSchedule.SECONDS)
pt = PeriodicTask.objects.create(name="${periodic_name}", task="${task_name}", interval=schedule, enabled=True, one_off=False)
print(pt.id)
PY

  cat >"${tmp_dir}/_check_periodic.py" <<PY
import django
django.setup()
from django_celery_beat.models import PeriodicTask
pt = PeriodicTask.objects.filter(name="${periodic_name}").first()
if not pt:
  raise SystemExit(2)
cnt = pt.total_run_count or 0
print(cnt)
raise SystemExit(0 if cnt >= 1 else 1)
PY

  cat >"${tmp_dir}/_cleanup_periodic.py" <<PY
import django
django.setup()
from django_celery_beat.models import PeriodicTask
PeriodicTask.objects.filter(name="${periodic_name}").delete()
PY

  (
    cd "$root/core/api"
    # shellcheck disable=SC1091
    . "$root/virtual_env/python/bin/activate"
    export PYTHONPATH="$tmp_dir:$root:$root/core/api"
    export DJANGO_SETTINGS_MODULE="src.config.patterns.test"

    log "Создание временной periodic task в django_celery_beat..."
    python "${tmp_dir}/_create_periodic.py" >/dev/null

    log "Ожидание срабатывания periodic task (до 25с)..."
    local deadline=$(( $(date +%s) + 25 ))
    while [[ "$(date +%s)" -lt "$deadline" ]]; do
      if python "${tmp_dir}/_check_periodic.py" >/dev/null 2>&1; then
        log "beat execution test: OK (PeriodicTask.total_run_count >= 1)"
        python "${tmp_dir}/_cleanup_periodic.py" >/dev/null 2>&1 || true
        exit 0
      fi
      sleep 3
    done

    log "[WARNING] beat execution test: FAILED (PeriodicTask не сработала за таймаут)"
    python "${tmp_dir}/_cleanup_periodic.py" >/dev/null 2>&1 || true
    exit 1
  )
}

step "Celery: подготовка (стоп) и запуск API + beat"
ERGO_TEST_CURRENT_STEP="celery: start api + beat"
stop_all_ergoms || true
test_svc_systemctl start ergo-api-dev
sleep 4
test_svc_systemctl start ergo-celery-beat
sleep 3
( test_svc_systemctl status ergo-celery-beat | head -25 ) || true

step "Celery Beat: show_next_tasks (расписание)"
ERGO_TEST_CURRENT_STEP="celery: show_next_tasks"
if run_celery_beat_show_next_tasks; then
  log "show_next_tasks: OK"
else
  log "[WARNING] show_next_tasks: FAILED"
fi

step "Celery Beat: проверка фактического исполнения (временная periodic task)"
ERGO_TEST_CURRENT_STEP="celery: beat execution"
if run_celery_beat_execution_test; then
  log "beat execution: OK"
else
  log "[WARNING] beat execution: FAILED"
fi

step "Celery Workers: соответствие celery_workers.yaml и служб (много/мало)"
ERGO_TEST_CURRENT_STEP="celery: workers many/few"
backup_and_prepare_workers_yaml

step "Celery Workers: сценарий 'мало' (1 worker) → install-worker-service → сверка unit'ов"
write_workers_yaml "one"
reinstall_worker_services_from_yaml || true
assert_workers_services_match_config || true

step "Celery Workers: сценарий 'много' (8 workers) → install-worker-service → сверка unit'ов"
write_workers_yaml "w1 w2 w3 w4 w5 w6 w7 w8"
reinstall_worker_services_from_yaml || true
assert_workers_services_match_config || true

step "Celery Workers: возврат к исходному celery_workers.yaml → install-worker-service → сверка unit'ов"
cp -f "$ROOT_DIR/celery_workers.yaml.test.bak" "$ROOT_DIR/celery_workers.yaml"
reinstall_worker_services_from_yaml || true
assert_workers_services_match_config || true

step "Celery Workers: запуск служб (все unit'ы из celery_workers.yaml)"
ERGO_TEST_CURRENT_STEP="celery: start worker services"
if start_and_check_worker_services; then
  log "worker services: OK"
else
  log "[WARNING] worker services: FAILED"
fi

step "Celery Worker: проверка через задачу (send_task -> result.get)"
ERGO_TEST_CURRENT_STEP="celery: worker task execution"
if run_celery_worker_task_test; then
  log "worker task execution: OK (pong)"
else
  log "[WARNING] worker task execution: FAILED"
fi

step "Celery: стоп"
ERGO_TEST_CURRENT_STEP="celery: stop"
test_svc_systemctl stop ergo-celery-beat || true
test_svc_systemctl stop ergo-api-dev || true
stop_worker_services_from_config || true
stop_all_ergoms || true

