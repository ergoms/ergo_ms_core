#!/usr/bin/env bash
# Full system setup
# Полная настройка системы

update_submodules() {
  local root="$1"
  
  cd "$root" || exit 1
  if ! git submodule update --init --remote core/api core/client core/media_api; then
    echo "[ERROR] Не удалось обновить git submodule" >&2
    exit 1
  fi
  
  echo "-> Переключение submodule на ветку dev..."
  
  cd "$root/core/api" || exit 1
  if ! git checkout dev; then
    echo "[WARNING] Не удалось переключить ветку dev в core/api" >&2
  fi
  
  cd "$root/core/client" || exit 1
  if ! git checkout dev; then
    echo "[WARNING] Не удалось переключить ветку dev в core/client" >&2
  fi
  
  cd "$root/core/media_api" || exit 1
  if ! git checkout dev; then
    echo "[WARNING] Не удалось переключить ветку dev в core/media_api" >&2
  fi
  
  cd "$root" || exit 1
  echo "[OK] Git submodule обновлены"
}

update_module_submodules() {
  local root="$1"
  local gitmodules="$root/.gitmodules"
  local -a module_paths=()
  local key path name branch

  if [[ ! -f "$gitmodules" ]]; then
    echo "[ERROR] .gitmodules не найден: $gitmodules" >&2
    exit 1
  fi

  echo ""
  echo "=== Обновление git submodule модулей ==="
  echo ""

  cd "$root" || exit 1

  while IFS=' ' read -r key path; do
    if [[ "$path" == modules/* ]]; then
      module_paths+=("$path")
    fi
  done < <(git config -f "$gitmodules" --get-regexp '^submodule\..*\.path$' | awk '{print $1, $2}')

  if [[ ${#module_paths[@]} -eq 0 ]]; then
    echo "[WARNING] В .gitmodules не найдены submodule модулей" >&2
    exit 0
  fi

  local succeeded=0
  local failed=0
  local skipped=0
  local -a failed_paths=()

  echo "-> Обновление ${#module_paths[@]} submodule модулей..."
  while IFS=' ' read -r key path; do
    [[ "$path" == modules/* ]] || continue
    name="${key#submodule.}"
    name="${name%.path}"
    branch="$(git config -f "$gitmodules" "submodule.$name.branch")"
    branch="${branch:-dev}"

    if [[ -z "$(git ls-files -s -- "$path")" ]]; then
      echo "[SKIP] $path не зарегистрирован в git (нет в индексе)"
      skipped=$((skipped + 1))
      continue
    fi

    echo "  $path..."
    if ! git submodule update --init --remote -- "$path"; then
      echo "[WARNING] Не удалось обновить $path" >&2
      failed=$((failed + 1))
      failed_paths+=("$path")
      continue
    fi

    if ! (cd "$root/$path" && git checkout "$branch"); then
      echo "[WARNING] Не удалось переключить ветку $branch в $path" >&2
    fi

    succeeded=$((succeeded + 1))
  done < <(git config -f "$gitmodules" --get-regexp '^submodule\..*\.path$' | awk '{print $1, $2}')

  cd "$root" || exit 1

  if [[ "$succeeded" -gt 0 ]]; then
    local summary="[OK] Обновлено модулей: $succeeded"
    if [[ "$skipped" -gt 0 || "$failed" -gt 0 ]]; then
      summary="$summary. Пропущено: $skipped. С ошибкой: $failed"
    fi
    echo "$summary"
    local fp
    for fp in "${failed_paths[@]}"; do
      echo "  - $fp" >&2
    done
    return 0
  fi

  if [[ "$failed" -gt 0 ]]; then
    echo "[ERROR] Не удалось обновить ни одного модуля ($failed)" >&2
    local fp
    for fp in "${failed_paths[@]}"; do
      echo "  - $fp" >&2
    done
    exit 1
  fi

  echo "[WARNING] Нет модулей для обновления" >&2
}

scaffold_config_files() {
  local root="$1"
  local script="$root/core/deployment/scripts/scaffold_config_files.py"
  local python_cmd=""

  for cmd in python3.12 python3 python; do
    if command -v "$cmd" >/dev/null 2>&1; then
      python_cmd="$cmd"
      break
    fi
  done

  if [[ -z "$python_cmd" ]]; then
    echo "    [WARNING] Python не найден, невозможно создать файлы конфигурации" >&2
    return 1
  fi

  if [[ ! -f "$script" ]]; then
    echo "    [WARNING] Скрипт создания конфигурации не найден: $script" >&2
    return 1
  fi

  "$python_cmd" "$script" --root "$root"
}

setup_full_system() {
  local root="$1"
  invoke_lifecycle_runner "$root" setup-full
}

# shellcheck source=lib/clean.sh
source "$LIB_DIR/clean.sh"

export -f setup_full_system
export -f update_submodules
export -f update_module_submodules
export -f scaffold_config_files
