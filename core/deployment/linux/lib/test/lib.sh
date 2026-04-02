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

run_task() {
  local label="$1"
  local task_file="$ROOT_DIR/.vscode/tasks.json"

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