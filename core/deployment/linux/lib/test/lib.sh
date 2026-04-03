ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

step() {
  echo
  echo "=== $* ==="
}

chown_project_paths_to_invoking_user() {
  # После запуска setup-full через sudo часть файлов может стать root:root.
  # Это ломает последующий `ergoms clean` (Permission denied), поэтому перед clean
  # возвращаем владение вызывающему пользователю.
  local target_user="${SUDO_USER:-$(id -un)}"
  local target_group
  target_group="$(id -gn "$target_user")"
  sudo chown -R "${target_user}:${target_group}" virtual_env logs .git/modules core/api core/client node_modules 2>/dev/null || true
}

sudo_warmup() {
  # Запросить пароль один раз заранее (как при обычном sudo-вызове).
  # Если sudo не нужен/уже закеширован — вернётся мгновенно.
  if command -v sudo >/dev/null 2>&1; then
    sudo -v
  fi
}

# ergoms stop: systemctl + снятие всех процессов с путём репозитория в cmdline (services.sh).
stop_all_ergoms() {
  local root="$ROOT_DIR"
  cd "$root"
  sudo_warmup
  ergoms stop || true
  ergoms stop-ollama || true
}

_test_source_core_sh() {
  local core_lib="$ROOT_DIR/core/deployment/linux/lib/core.sh"
  if [[ ! -f "$core_lib" ]]; then
    echo "Не найден $core_lib" >&2
    return 1
  fi
  # shellcheck source=../core.sh
  source "$core_lib"
  reset_units_cache
}

# start|stop|status unit'а через sudo (кэш после sudo_warmup в начале run_test), без polkit от ergoms *-service.
test_svc_systemctl() {
  local action="${1:?}"
  local unit="${2:?}"
  sudo_warmup
  _test_source_core_sh || return 1
  systemctl_do "$action" "$unit"
}

# Старт всех unit'ов worker по ключам workers: в celery_workers.yaml (не хардкод ergo-celery-worker-all).
start_worker_services_from_config() {
  local w
  sudo_warmup
  _test_source_core_sh || return 1
  for w in $(get_worker_service_names "$ROOT_DIR"); do
    log "systemctl start ${w}.service (воркер из celery_workers.yaml)"
    systemctl_do start "${w}.service" || return 1
  done
}

stop_worker_services_from_config() {
  local w
  sudo_warmup
  _test_source_core_sh || return 1
  for w in $(get_worker_service_names "$ROOT_DIR"); do
    systemctl_do stop "${w}.service" || true
  done
}

# Проверка worker: отклик consumer'ов через broker (нужен запущенный worker).
run_celery_worker_inspect_ping() {
  local root="$ROOT_DIR"
  (
    cd "$root/core/api" || exit 1
    # shellcheck disable=SC1091
    . "$root/virtual_env/python/bin/activate"
    export PYTHONPATH="$root"
    celery -A src.config.celery.celery_app inspect ping --timeout 8
  )
}

# Проверка beat: ближайшие слоты расписания из кода модулей (не ожидание реального срабатывания в БД).
run_celery_beat_show_next_tasks() {
  ( cd "$ROOT_DIR" && ergoms api show_next_tasks --count 5 )
}

_run_task_exec_shell() {
  local cmd="$1"
  local in_parallel="${2:-false}"
  cmd="${cmd//\$\{workspaceFolder\}/$ROOT_DIR}"
  echo "Выполнение команды: $cmd"
  if [[ "$cmd" == *"sudo "* || "$cmd" == *" systemctl "* || "$cmd" == systemctl* ]]; then
    sudo_warmup
  fi
  # По умолчанию при parallel — foreground: родитель уже параллелит через ( run_task … ) &; лишний & здесь
  # давал мгновенный return и обрывал сервисы следующим stop_all_ergoms в run_test.sh.
  # ERGO_RUN_TASK_DETACHED=1 — фон внутри подоболочки (автотест: поднять всё, подождать, остановить).
  if [[ "$in_parallel" == "true" && "${ERGO_RUN_TASK_DETACHED:-}" == "1" ]]; then
    ( cd "$ROOT_DIR" && bash -lc "$cmd" ) &
  else
    ( cd "$ROOT_DIR" && bash -lc "$cmd" )
  fi
}

_run_task_multi_terminal() {
  local label="$1"
  local task_file="$2"
  local core_sh="$ROOT_DIR/core/deployment/linux/lib/core.sh"
  if [[ ! -f "$core_sh" ]]; then
    echo "multi-terminal «$label»: не найден $core_sh" >&2
    return 1
  fi
  # shellcheck source=../core.sh
  source "$core_sh"
  reset_units_cache 2>/dev/null || true

  local rel template yaml workers key cmd
  rel="$(jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .source.file // empty' "$task_file")"
  template="$(jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .commandTemplate // empty' "$task_file")"
  if [[ -z "$rel" || -z "$template" ]]; then
    echo "multi-terminal «$label»: нужны source.file и commandTemplate" >&2
    return 1
  fi
  yaml="$ROOT_DIR/$rel"
  if [[ ! -f "$yaml" ]]; then
    echo "multi-terminal «$label»: нет файла $yaml" >&2
    return 1
  fi
  workers="$(get_celery_workers "$ROOT_DIR")"
  if [[ -z "$workers" ]]; then
    log "[WARNING] multi-terminal «$label»: пустой список воркеров в $rel"
    return 0
  fi
  for key in $workers; do
    cmd="${template//\$\{key\}/$key}"
    cmd="${cmd//\$\{workspaceFolder\}/$ROOT_DIR}"
    echo "Выполнение (multi-terminal «$label» [$key]): $cmd"
    ( cd "$ROOT_DIR" && bash -lc "$cmd" ) &
  done
}

# Задача из .vscode/tasks.json: command → иначе multi-terminal → иначе dependsOn (рекурсия).
# Второй аргумент: true — долгоживущая shell-команда в фоне (ветка parallel у родителя).
run_task() {
  local label="${1:?}"
  local in_parallel="${2:-false}"
  local task_file="$ROOT_DIR/.vscode/tasks.json"

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq не установлен. Невозможно прочитать $task_file" >&2
    return 1
  fi
  if [[ ! -r "$task_file" ]]; then
    echo "Нет прав на чтение $task_file (проверь права/владельца файла)." >&2
    return 1
  fi

  if ! jq -e --arg l "$label" 'any(.tasks[]; .label == $l)' "$task_file" >/dev/null 2>&1; then
    echo "Задача не найдена в tasks.json: $label" >&2
    return 1
  fi

  local cmd
  cmd="$(jq -r --arg l "$label" '
    .tasks[]
    | select(.label == $l)
    | (.linux.command // .command) // empty
  ' "$task_file")"

  if [[ -n "$cmd" && "$cmd" != "null" ]]; then
    _run_task_exec_shell "$cmd" "$in_parallel"
    return 0
  fi

  local ttype
  ttype="$(jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .type // empty' "$task_file")"
  if [[ "$ttype" == "multi-terminal" ]]; then
    _run_task_multi_terminal "$label" "$task_file" || return 1
    return 0
  fi

  if [[ "$(jq -r --arg l "$label" '.tasks[] | select(.label == $l) | has("dependsOn")' "$task_file")" == "true" ]]; then
    local order dep
    local -a pids=()
    order="$(jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .dependsOrder // "parallel"' "$task_file")"
    log "Задача «$label»: dependsOn (порядок: $order)"
    if [[ "$order" == "sequence" ]]; then
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        run_task "$dep" false || return 1
      done < <(jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .dependsOn[]?' "$task_file")
    else
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        ( run_task "$dep" true ) &
        pids+=($!)
      done < <(jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .dependsOn[]?' "$task_file")
      local pid
      for pid in "${pids[@]}"; do
        wait "$pid" || return 1
      done
    fi
    return 0
  fi

  echo "Задача «$label» без command, без dependsOn и не multi-terminal" >&2
  return 1
}

# Проверка, что проект установлен (setup + install-services) и unit-файлы есть в systemd.
# Вызывать перед сценариями проверки запуска служб.
require_install_ready_for_launch() {
  local root="$ROOT_DIR"
  log "Проверка готовности к запуску: структура проекта, venv, ergoms, systemd."

  if ! command -v ergoms >/dev/null 2>&1; then
    echo "ergoms не найден в PATH. Выполните установку CLI (ergo_ms.sh install-cli / setup)." >&2
    return 1
  fi

  if [[ ! -d "$root/core/api" || ! -d "$root/core/client" ]]; then
    echo "Нет каталогов core/api или core/client. Выполните ergoms setup." >&2
    return 1
  fi

  if [[ ! -f "$root/virtual_env/python/bin/activate" ]]; then
    echo "Нет virtual_env/python. Выполните ergoms setup или ergoms install-deps." >&2
    return 1
  fi

  if [[ ! -d "$root/node_modules" && ! -d "$root/core/client/node_modules" ]]; then
    echo "Нет node_modules (корень или core/client). Выполните ergoms setup / ergoms npm install." >&2
    return 1
  fi

  if [[ ! -f /etc/default/ergo_ms ]]; then
    echo "Нет /etc/default/ergo_ms. Выполните ergoms install-all-services (или install-services)." >&2
    return 1
  fi

  local core_lib="$root/core/deployment/linux/lib/core.sh"
  if [[ ! -f "$core_lib" ]]; then
    echo "Не найден $core_lib" >&2
    return 1
  fi
  # shellcheck source=../core.sh
  source "$core_lib"
  reset_units_cache 2>/dev/null || true

  local units u short frag missing=0
  units="$(generate_units_list "$root")"
  sudo_warmup
  for u in $units; do
    short="${u%.service}"
    frag="$(systemctl_do show "$short" -p FragmentPath --value 2>/dev/null || true)"
    if [[ -z "$frag" || ! -f "$frag" ]]; then
      echo "Unit не установлен в systemd: $u (ожидается после ergoms install-all-services)." >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    return 1
  fi

  log "► Готовность к запуску служб: OK."
}