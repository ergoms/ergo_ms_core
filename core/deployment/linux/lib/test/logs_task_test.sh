#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
enable_test_traps

cd "$ROOT_DIR"

step "VS Code task: Logs: All Services (эмуляция multi-terminal)"
ERGO_TEST_CURRENT_STEP="logs_task: all services"

TASKS_JSON="$ROOT_DIR/.vscode/tasks.json"
TASK_LABEL="Logs: All Services"

validate_vscode_logs_task_definition() {
  if ! command -v jq >/dev/null 2>&1; then
    log "[WARNING] jq не установлен — не могу проверить определение VS Code task '${TASK_LABEL}' в tasks.json"
    return 1
  fi
  if [[ ! -r "$TASKS_JSON" ]]; then
    log "[WARNING] Нет прав на чтение $TASKS_JSON — не могу проверить VS Code task '${TASK_LABEL}'"
    return 1
  fi

  if ! jq -e --arg l "$TASK_LABEL" 'any(.tasks[]; .label == $l)' "$TASKS_JSON" >/dev/null 2>&1; then
    log "[WARNING] VS Code task не найдена в tasks.json: '${TASK_LABEL}'"
    return 1
  fi

  local type
  type="$(jq -r --arg l "$TASK_LABEL" '.tasks[] | select(.label == $l) | .type // empty' "$TASKS_JSON")"
  if [[ "$type" != "multi-terminal" ]]; then
    log "[WARNING] VS Code task '${TASK_LABEL}': ожидается type=multi-terminal, фактически: '${type}'"
    return 1
  fi

  local s1f s1p s1ct s2f s2p s2ct
  s1f="$(jq -r --arg l "$TASK_LABEL" '.tasks[] | select(.label == $l) | .sources[0].file // empty' "$TASKS_JSON")"
  s1p="$(jq -r --arg l "$TASK_LABEL" '.tasks[] | select(.label == $l) | .sources[0].path // empty' "$TASKS_JSON")"
  s1ct="$(jq -r --arg l "$TASK_LABEL" '.tasks[] | select(.label == $l) | .sources[0].commandTemplate // empty' "$TASKS_JSON")"
  s2f="$(jq -r --arg l "$TASK_LABEL" '.tasks[] | select(.label == $l) | .sources[1].file // empty' "$TASKS_JSON")"
  s2p="$(jq -r --arg l "$TASK_LABEL" '.tasks[] | select(.label == $l) | .sources[1].path // empty' "$TASKS_JSON")"
  s2ct="$(jq -r --arg l "$TASK_LABEL" '.tasks[] | select(.label == $l) | .sources[1].commandTemplate // empty' "$TASKS_JSON")"

  local ok=0
  if [[ "$s1f" != ".vscode/logs-services.yaml" || "$s1p" != "services" ]]; then
    ok=1
    log "[WARNING] VS Code task '${TASK_LABEL}': sources[0] ожидается (.vscode/logs-services.yaml / services), фактически: ($s1f / $s1p)"
  fi
  if [[ "$s2f" != "celery_workers.yaml" || "$s2p" != "workers" ]]; then
    ok=1
    log "[WARNING] VS Code task '${TASK_LABEL}': sources[1] ожидается (celery_workers.yaml / workers), фактически: ($s2f / $s2p)"
  fi

  if [[ "$s1ct" != ergoms\ logs* || "$s2ct" != ergoms\ logs* ]]; then
    ok=1
    log "[WARNING] VS Code task '${TASK_LABEL}': commandTemplate не похож на 'ergoms logs ...' (s1='$s1ct', s2='$s2ct')"
  fi

  if [[ "$ok" -eq 0 ]]; then
    log "[OK] VS Code task '${TASK_LABEL}': определение в tasks.json выглядит корректно"
    return 0
  fi
  return 1
}

if ! validate_vscode_logs_task_definition; then
  log "[WARNING] Определение VS Code task '${TASK_LABEL}' не прошло валидацию. Проверку логов всё равно выполняю командами ergoms logs."
fi

services="$(get_services_from_logs_yaml || true)"
workers="$(get_workers_from_workers_yaml || true)"

if [[ -z "${services// }" ]]; then
  log "[WARNING] В .vscode/logs-services.yaml не найдено services: ключей"
else
  log "Services из .vscode/logs-services.yaml: $(echo "$services" | tr '\n' ' ' | xargs)"
fi

if [[ -z "${workers// }" ]]; then
  log "[WARNING] В celery_workers.yaml не найдено workers: ключей"
else
  log "Workers из celery_workers.yaml: $(echo "$workers" | tr '\n' ' ' | xargs)"
fi

all_ok=0

while IFS= read -r svc; do
  [[ -n "$svc" ]] || continue
  log "VSCode Logs: команда: ergoms logs ${svc} 50"
  if ! run_with_timeout 10 ergoms logs "$svc" 50; then
    all_ok=1
    log "[WARNING] logs для ${svc} не отработал"
  fi
done <<< "$services"

while IFS= read -r w; do
  [[ -n "$w" ]] || continue
  name="ergo-celery-worker-${w}"
  log "VSCode Logs: команда: ergoms logs ${name} 50"
  if ! run_with_timeout 10 ergoms logs "$name" 50; then
    all_ok=1
    log "[WARNING] logs для ${name} не отработал"
  fi
done <<< "$workers"

exit "$all_ok"

