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
  
  echo ""
  echo "=== Полная настройка системы ==="
  echo ""
  
  # Step 1: Git submodules
  echo "-> Шаг 1/7: обновление git submodule..."
  update_submodules "$root"
  
  # Create configuration files from examples if they don't exist
  echo "  Создание файлов конфигурации из примеров..."
  scaffold_config_files "$root" || true
  
  # Step 2: Create virtual environment
  echo "-> Шаг 2/7: создание виртуального окружения Python..."
  local venv_path="$root/virtual_env/python"
  if [[ -f "$venv_path/bin/activate" && -f "$venv_path/bin/python" ]]; then
    echo "  Виртуальное окружение уже существует"
  else
    if ! python3.12 -m venv "$venv_path"; then
      echo "[ERROR] Не удалось создать виртуальное окружение" >&2
      exit 1
    fi
    echo "[OK] Виртуальное окружение создано"
  fi
  
  # Step 3: Install Poetry
  echo "-> Шаг 3/7: установка Poetry..."
  local venv_activate="$venv_path/bin/activate"
  # shellcheck disable=SC1090
  source "$venv_activate"
  # Use python -m pip to avoid shell function wrappers ("pip()") from init_terminal.sh.
  # Force reinstall to restore a broken/missing console script.
  if ! python -m pip install --upgrade --force-reinstall poetry; then
    echo "[ERROR] Не удалось установить Poetry" >&2
    exit 1
  fi
  echo "[OK] Poetry установлен"
  
  # Step 4: Install CLI wrapper
  echo "-> Шаг 4/7: установка CLI ErgoMS..."
  local target_script
  if command -v readlink >/dev/null 2>&1; then
    # Get the main script (go up from lib to linux directory)
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local linux_dir
    linux_dir="$(cd "$lib_dir/.." && pwd)"
    target_script="$linux_dir/ergo_ms.sh"
  else
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local linux_dir
    linux_dir="$(cd "$lib_dir/.." && pwd)"
    target_script="$linux_dir/ergo_ms.sh"
  fi
  create_cli_wrapper "$target_script"
  
  # Step 5: Python (ядро + модули через commands install) + npm
  echo "-> Шаг 5/7: установка зависимостей (python + npm)..."
  cd "$root" || exit 1
  export POETRY_VIRTUALENVS_CREATE=false
  echo "  Выполняется: python -m commands install (ядро + зависимости модулей)..."
  if ! (cd "$root/core/api" && export PYTHONPATH="$root" && python -m commands install); then
    echo "[ERROR] команда install завершилась с ошибкой" >&2
    exit 1
  fi
  if ! npm run install:all; then
    echo "[ERROR] npm run install:all завершился с ошибкой" >&2
    exit 1
  fi
  if ! npm run build; then
    echo "[ERROR] npm run build завершился с ошибкой" >&2
    exit 1
  fi
  if ! (cd "$root/core/api" && export PYTHONPATH="$root" && python -m commands migrate); then
    echo "[ERROR] Миграции базы данных не применились" >&2
    exit 1
  fi
  (cd "$root/core/api" && export PYTHONPATH="$root" && python -m commands warmup_caches) || true
  echo "[OK] Настройка завершена"
  
  # Step 6: Collect static
  echo "-> Шаг 6/7: сбор статических файлов..."
  if ! (cd "$root/core/api" && export PYTHONPATH="$root" && python -m commands collectstatic --noinput); then
    echo "[ERROR] Не удалось собрать статические файлы" >&2
    exit 1
  fi
  echo "[OK] Статические файлы собраны"
  
  # Step 7: Setup complete (services not installed)
  echo "-> Шаг 7/7: настройка завершена"
  
  echo ""
  echo "=== Полная настройка системы завершена ==="
  echo ""
  echo "Система готова! Чтобы установить и запустить службы, выполните:"
  echo "  ergoms install-services"
  echo ""
  echo "Теперь можно управлять системой через команды ergoms."
}

# shellcheck source=lib/clean.sh
source "$LIB_DIR/clean.sh"

export -f setup_full_system
export -f update_submodules
export -f update_module_submodules
export -f scaffold_config_files
