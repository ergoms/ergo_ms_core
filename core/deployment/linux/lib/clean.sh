# Clean project dependencies helpers
# Вспомогательные функции для очистки зависимостей проекта

stop_blocking_processes_for_clean() {
  local root="$1"
  local venv_python="$root/virtual_env/python"

  echo "  Останавливаю процессы, которые могут блокировать файлы проекта..."

  if command -v systemctl >/dev/null 2>&1; then
    while IFS= read -r unit; do
      [[ -z "$unit" ]] && continue
      if systemctl is-active --quiet "$unit" 2>/dev/null; then
        if systemctl stop "$unit" 2>/dev/null; then
          echo "  Остановлена служба: $unit"
        else
          echo "  [WARNING] Не удалось остановить службу $unit (может потребоваться root)" >&2
        fi
      fi
    done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '/ergo-/ {print $1}')
  fi

  if command -v fuser >/dev/null 2>&1 && [[ -d "$venv_python" ]]; then
    fuser -k "$venv_python" 2>/dev/null || true
  fi

  if command -v pkill >/dev/null 2>&1; then
    pkill -f "${venv_python}" 2>/dev/null || true
    pkill -f "${root}/node_modules" 2>/dev/null || true
  fi

  sleep 2
}

clear_project_shell_environment() {
  local venv_path="$1"
  local venv_norm
  venv_norm="$(cd "$venv_path" 2>/dev/null && pwd -P)" || return 0

  if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    local active_norm
    active_norm="$(cd "$VIRTUAL_ENV" 2>/dev/null && pwd -P)" || active_norm="$VIRTUAL_ENV"
    if [[ "$active_norm" == "$venv_norm" ]]; then
      unset VIRTUAL_ENV
      echo "  Сброшена переменная VIRTUAL_ENV для виртуального окружения проекта"
    fi
  fi

  if [[ -n "${PATH:-}" ]]; then
    local scripts_path="${venv_norm}/bin"
    local new_path=""
    local part norm
    IFS=':' read -r -a path_parts <<< "$PATH"
    for part in "${path_parts[@]}"; do
      [[ -z "$part" ]] && continue
      norm="$(cd "$part" 2>/dev/null && pwd -P)" || norm="$part"
      if [[ "$norm" == "$scripts_path" ]]; then
        continue
      fi
      if [[ -z "$new_path" ]]; then
        new_path="$part"
      else
        new_path="${new_path}:$part"
      fi
    done
    PATH="$new_path"
    export PATH
  fi
}

remove_path_robust() {
  local path="$1"
  local max_retries="${2:-3}"
  local attempt

  [[ -e "$path" ]] || return 0

  for ((attempt = 1; attempt <= max_retries; attempt++)); do
    if rm -rf "$path" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  [[ ! -e "$path" ]]
}

clean_directory_contents() {
  local dir_path="$1"
  local label="$2"
  local root="$3"

  if [[ ! -d "$dir_path" ]]; then
    echo "[SKIP] $label не найден"
    return
  fi

  local removed_count=0
  local has_items=false
  local failed_items=()
  local item base

  for item in "$dir_path"/*; do
    [[ -e "$item" ]] || continue
    base="$(basename "$item")"
    [[ "$base" == ".gitkeep" ]] && continue
    has_items=true
    if remove_path_robust "$item"; then
      removed_count=$((removed_count + 1))
    else
      failed_items+=("$base")
    fi
  done

  if [[ ${#failed_items[@]} -gt 0 ]]; then
    stop_blocking_processes_for_clean "$root"
    local retry_failed=()
    for base in "${failed_items[@]}"; do
      local full_item="$dir_path/$base"
      [[ -e "$full_item" ]] || continue
      if remove_path_robust "$full_item" 5; then
        removed_count=$((removed_count + 1))
      else
        retry_failed+=("$base")
      fi
    done
    failed_items=("${retry_failed[@]}")
  fi

  if [[ ${#failed_items[@]} -gt 0 ]]; then
    echo "[ERROR] Не удалось очистить $label: не удалось удалить: ${failed_items[*]}" >&2
    echo "  Закройте терминалы с активированным venv, остановите серверы разработки и снова выполните ergoms clean" >&2
    return
  fi

  if [[ "$has_items" == true ]]; then
    echo "[OK] Удалено $removed_count элементов из $label"
  else
    echo "[SKIP] $label уже пуст"
  fi
}

clear_project_dependencies() {
  local root="$1"

  local -a clean_paths=(
    "node_modules"
    "virtual_env/python"
    "virtual_env/static_api"
    "virtual_env/celery"
    "virtual_env/nodejs"
    "virtual_env/packages"
    "virtual_env/resources"
    "virtual_env/trained_models"
    "virtual_env/cache"
    "virtual_env/docker-cache"
  )

  echo ""
  echo "=== Очистка зависимостей проекта ==="
  echo ""
  echo "Будут удалены:"
  for p in "${clean_paths[@]}"; do
    echo "  - $p"
  done
  echo ""
  echo "Папка media не будет удалена."
  echo ""

  read -rp "Продолжить? (y/N) " confirmation
  if [[ ! "$confirmation" =~ ^[yY]$ ]]; then
    echo "Операция отменена пользователем."
    return
  fi

  stop_blocking_processes_for_clean "$root"
  clear_project_shell_environment "$root/virtual_env/python"

  local total=${#clean_paths[@]}
  local step=0
  for rel_path in "${clean_paths[@]}"; do
    step=$((step + 1))
    local full_path="$root/$rel_path"
    echo ""
    echo "-> Шаг ${step}/${total}: очистка ${rel_path}..."

    if [[ "$rel_path" == "node_modules" ]]; then
      if [[ -d "$full_path" ]]; then
        if remove_path_robust "$full_path"; then
          echo "[OK] $rel_path удалён"
        else
          stop_blocking_processes_for_clean "$root"
          if remove_path_robust "$full_path" 5; then
            echo "[OK] $rel_path удалён"
          else
            echo "[ERROR] Не удалось удалить $rel_path" >&2
            echo "  Закройте другие терминалы и серверы разработки, затем снова выполните ergoms clean" >&2
          fi
        fi
      else
        echo "[SKIP] $rel_path не найден"
      fi
    else
      clean_directory_contents "$full_path" "$rel_path" "$root"
    fi
  done

  echo ""
  echo "=== Очистка завершена ==="
  echo ""
  echo "Чтобы установить зависимости заново, выполните:"
  echo "  ergoms setup"
  echo ""
}

export -f stop_blocking_processes_for_clean
export -f clear_project_shell_environment
export -f remove_path_robust
export -f clean_directory_contents
export -f clear_project_dependencies
