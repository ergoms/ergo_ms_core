ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
TEST_LOG_FILE="${ROOT_DIR}/logs/test.log"

_test_ensure_log_dir() {
  mkdir -p "$(dirname "$TEST_LOG_FILE")"
}

log() {
  _test_ensure_log_dir
  local line="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "$line" | tee -a "$TEST_LOG_FILE"
}

step() {
  _test_ensure_log_dir
  {
    echo
    echo "=== $* ==="
  } | tee -a "$TEST_LOG_FILE"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

_tasks_json_py() {
  # Чтение tasks.json через Python (fallback если нет jq).
  local tasks_json="${1:?}"
  local label="${2:?}"
  local action="${3:?}"

  local py_bin=""
  if command -v python3 >/dev/null 2>&1; then py_bin="python3"
  elif command -v python >/dev/null 2>&1; then py_bin="python"
  else
    echo ""
    return 2
  fi

  "$py_bin" - "$tasks_json" "$label" "$action" <<'PY'
import json, sys
path, label, action = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
tasks = data.get("tasks", [])
t = next((x for x in tasks if x.get("label") == label), None)

def out(s=""):
    sys.stdout.write(str(s) if s is not None else "")

if action == "exists":
    out("true" if t else "false")
elif action == "type":
    out((t or {}).get("type", ""))
elif action == "command":
    if not t:
        out("")
    else:
        # prefer linux.command, then command
        linux = t.get("linux") or {}
        cmd = linux.get("command") or t.get("command") or ""
        out(cmd)
elif action == "has_depends":
    out("true" if (t and "dependsOn" in t) else "false")
elif action == "depends_order":
    out((t or {}).get("dependsOrder") or "parallel")
elif action == "depends_list":
    if not t:
        out("")
    else:
        deps = t.get("dependsOn") or []
        if isinstance(deps, list):
            out("\n".join(str(d) for d in deps))
        else:
            out("")
else:
    out("")
PY
}

_tasks_json_get() {
  local task_file="${1:?}"
  local label="${2:?}"
  local field="${3:?}"

  if command -v jq >/dev/null 2>&1; then
    case "$field" in
      exists)
        jq -e --arg l "$label" 'any(.tasks[]; .label == $l)' "$task_file" >/dev/null 2>&1 && echo "true" || echo "false"
        ;;
      command)
        jq -r --arg l "$label" '
          .tasks[]
          | select(.label == $l)
          | (.linux.command // .command) // empty
        ' "$task_file"
        ;;
      type)
        jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .type // empty' "$task_file"
        ;;
      has_depends)
        jq -r --arg l "$label" '.tasks[] | select(.label == $l) | has("dependsOn")' "$task_file"
        ;;
      depends_order)
        jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .dependsOrder // "parallel"' "$task_file"
        ;;
      depends_list)
        jq -r --arg l "$label" '.tasks[] | select(.label == $l) | .dependsOn[]?' "$task_file"
        ;;
      *)
        echo ""
        ;;
    esac
  else
    _tasks_json_py "$task_file" "$label" "$field" || true
  fi
}

test_test_log_significant_line() {
  local line="${1:-}"
  [[ -n "${line//[[:space:]]/}" ]] || return 1

  # Тег вида [INFO]/[OK]/[WARNING]/[ERROR]/[SKIP] и т.п.
  if [[ "$line" =~ \[[[:alpha:]][^][]*\] ]]; then return 0; fi
  if [[ "$line" =~ \[(OK|ERR|ON|NO)\] ]]; then return 0; fi

  # Типовые фатальные/ошибочные маркеры.
  if [[ "$line" =~ ^fatal: ]]; then return 0; fi
  if [[ "$line" =~ (Traceback|ERROR|Error|Exception|Failed|Command\ failed|Permission\ denied|No\ such\ file|cannot\ import|circular\ import) ]]; then return 0; fi
  if [[ "$line" =~ (NativeCommandError|ServiceCommandException|Start-Service|OpenError:) ]]; then return 0; fi

  return 1
}

log_filtered_file() {
  local path="${1:?}"
  [[ -f "$path" ]] || return 0
  local ln any=1
  while IFS= read -r ln || [[ -n "$ln" ]]; do
    if test_test_log_significant_line "$ln"; then
      any=0
      log "$ln"
    fi
  done <"$path"
  return "$any"
}

log_tail_file() {
  local path="${1:?}"
  local lines="${2:-40}"
  [[ -f "$path" ]] || return 0
  log "[INFO] Последние ${lines} строк вывода (tail) для диагностики:"
  if has_cmd tail; then
    while IFS= read -r ln || [[ -n "$ln" ]]; do
      log "$ln"
    done < <(tail -n "$lines" "$path")
  fi
}

run_cmd() {
  # Запускает команду и пишет в test.log только "значимый" вывод stderr.
  local title="${1:?}"; shift
  _test_ensure_log_dir
  log "[CMD] $title"

  local tmp_dir err
  tmp_dir="$(mktemp -d)"
  err="${tmp_dir}/err.txt"
  set +e
  "$@" 2>"$err"
  local rc=$?
  set -e

  # Пишем только значимые строки из stderr. Если команда упала и "значимых" строк нет — пишем tail stderr.
  if ! log_filtered_file "$err"; then
    if [[ "$rc" -ne 0 ]]; then
      log_tail_file "$err" 60
    fi
  fi

  rm -rf "$tmp_dir" 2>/dev/null || true

  if [[ "$rc" -ne 0 ]]; then
    log "[ERROR] Команда завершилась с кодом $rc: $title"
  else
    log "[OK] $title"
  fi
  return "$rc"
}

enable_test_traps() {
  # Логирует причину остановки скрипта (строка/команда/rc).
  set -E
  trap '{
    rc=$?;
    cmd=${BASH_COMMAND:-unknown};
    line=${BASH_LINENO[0]:-unknown};
    src=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}};
    step_name=${ERGO_TEST_CURRENT_STEP:-""};
    if [[ -n "$step_name" ]]; then
      log "[ERROR] Скрипт остановлен на шаге: $step_name"
    fi
    log "[ERROR] Ошибка (rc=$rc) в $src:$line; команда: $cmd"
    exit "$rc"
  }' ERR
}

run_with_timeout() {
  local seconds="${1:?}"; shift
  if has_cmd timeout; then
    timeout "${seconds}" "$@"
  else
    "$@"
  fi
}

parse_yaml_map_keys() {
  # Простой YAML-парсер: возвращает ключи map в секции root_key.
  local yaml_file="${1:?}"
  local root_key="${2:?}"
  local indent="${3:-2}"

  [[ -f "$yaml_file" ]] || return 0

  local in_root=false
  local re_key="^[[:space:]]{${indent}}([A-Za-z0-9_-]+):[[:space:]]*$"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    if [[ "$line" =~ ^${root_key}:[[:space:]]*$ ]]; then
      in_root=true
      continue
    fi

    if [[ "$in_root" == true ]]; then
      # Новый корневой ключ (0 пробелов + word + :)
      if [[ "$line" =~ ^[A-Za-z0-9_-]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
        break
      fi
      if [[ "$line" =~ $re_key ]]; then
        echo "${BASH_REMATCH[1]}"
      fi
    fi
  done < "$yaml_file"
}

get_services_from_logs_yaml() {
  parse_yaml_map_keys "$ROOT_DIR/.vscode/logs-services.yaml" "services" 2 || true
}

get_workers_from_workers_yaml() {
  parse_yaml_map_keys "$ROOT_DIR/celery_workers.yaml" "workers" 2 || true
}

chown_project_paths_to_invoking_user() {
  # Возврат владения, если setup запускали через sudo.
  local target_user="${SUDO_USER:-$(id -un)}"
  local target_group
  target_group="$(id -gn "$target_user")"
  sudo_warmup
  sudo chown -R "${target_user}:${target_group}" virtual_env logs .git/modules core/api core/client node_modules 2>/dev/null || true
}

sudo_warmup() {
  # Прогрев sudo timestamp, чтобы не прерывать тест посреди шага.
  if command -v sudo >/dev/null 2>&1; then
    sudo -v
  fi
}

stop_all_ergoms() {
  local root="$ROOT_DIR"
  cd "$root"
  sudo_warmup
  run_cmd "ergoms stop" ergoms stop || true
  run_cmd "ergoms ollama_framework:stop-ollama" ergoms ollama_framework:stop-ollama || true
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

test_svc_systemctl() {
  local action="${1:?}"
  local unit="${2:?}"
  sudo_warmup
  _test_source_core_sh || return 1
  systemctl_do "$action" "$unit"
}

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

run_celery_beat_show_next_tasks() {
  ( cd "$ROOT_DIR" && ergoms api show_next_tasks --count 5 )
}

require_python_venv() {
  local root="$ROOT_DIR"
  if [[ ! -f "$root/virtual_env/python/bin/activate" ]]; then
    echo "Не найден venv: $root/virtual_env/python/bin/activate" >&2
    return 1
  fi
}

_run_task_exec_shell() {
  local cmd="$1"
  local in_parallel="${2:-false}"
  cmd="${cmd//\$\{workspaceFolder\}/$ROOT_DIR}"
  echo "Выполнение команды: $cmd"
  if [[ "$cmd" == *"sudo "* || "$cmd" == *" systemctl "* || "$cmd" == systemctl* ]]; then
    sudo_warmup
  fi
  # ERGO_RUN_TASK_DETACHED=1 — запуск в фоне (для долгоживущих dev-сервисов).
  if [[ "$in_parallel" == "true" && "${ERGO_RUN_TASK_DETACHED:-}" == "1" ]]; then
    ( cd "$ROOT_DIR" && bash -lc "$cmd" ) >/dev/null 2>&1 &
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
    ( cd "$ROOT_DIR" && bash -lc "$cmd" ) >/dev/null 2>&1 &
  done
}

run_task() {
  local label="${1:?}"
  local in_parallel="${2:-false}"
  local task_file="$ROOT_DIR/.vscode/tasks.json"

  if [[ ! -r "$task_file" ]]; then
    echo "Нет прав на чтение $task_file (проверь права/владельца файла)." >&2
    return 1
  fi

  if [[ "$(_tasks_json_get "$task_file" "$label" exists)" != "true" ]]; then
    echo "Задача не найдена в tasks.json: $label" >&2
    return 1
  fi

  local cmd
  cmd="$(_tasks_json_get "$task_file" "$label" command)"

  if [[ -n "$cmd" && "$cmd" != "null" ]]; then
    _run_task_exec_shell "$cmd" "$in_parallel"
    return 0
  fi

  local ttype
  ttype="$(_tasks_json_get "$task_file" "$label" type)"
  if [[ "$ttype" == "multi-terminal" ]]; then
    _run_task_multi_terminal "$label" "$task_file" || return 1
    return 0
  fi

  if [[ "$(_tasks_json_get "$task_file" "$label" has_depends)" == "true" ]]; then
    local order dep
    local -a pids=()
    order="$(_tasks_json_get "$task_file" "$label" depends_order)"
    log "Задача «$label»: dependsOn (порядок: $order)"
    if [[ "$order" == "sequence" ]]; then
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        run_task "$dep" false || return 1
      done < <(_tasks_json_get "$task_file" "$label" depends_list)
    else
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        ( run_task "$dep" true ) &
        pids+=($!)
      done < <(_tasks_json_get "$task_file" "$label" depends_list)
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