#!/usr/bin/env bash
# Full system setup
# Полная настройка системы

update_submodules() {
  local root="$1"
  
  echo ""
  echo "=== Updating Git Submodules ==="
  echo ""
  
  cd "$root" || exit 1
  echo "-> Updating git submodules..."
  if ! git submodule update --init --remote core/api core/client core/django core/django_rest_framework core/media_api; then
    echo "[ERROR] Failed to update git submodules" >&2
    exit 1
  fi
  
  echo "-> Switching submodules to dev branch..."
  
  cd "$root/core/api" || exit 1
  if ! git checkout dev; then
    echo "[WARNING] Failed to checkout dev branch in core/api" >&2
  fi
  
  cd "$root/core/client" || exit 1
  if ! git checkout dev; then
    echo "[WARNING] Failed to checkout dev branch in core/client" >&2
  fi
  
  cd "$root/core/django" || exit 1
  if ! git checkout dev; then
    echo "[WARNING] Failed to checkout dev branch in core/django" >&2
  fi

  cd "$root/core/django_rest_framework" || exit 1
  if ! git checkout dev; then
    echo "[WARNING] Failed to checkout dev branch in core/django_rest_framework" >&2
  fi
  
  cd "$root/core/media_api" || exit 1
  if ! git checkout dev; then
    echo "[WARNING] Failed to checkout dev branch in core/media_api" >&2
  fi
  
  cd "$root" || exit 1
  echo "[OK] Git submodules updated"
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
    echo "    [WARNING] Python not found, cannot scaffold configuration files" >&2
    return 1
  fi

  if [[ ! -f "$script" ]]; then
    echo "    [WARNING] Config scaffold script not found: $script" >&2
    return 1
  fi

  "$python_cmd" "$script" --root "$root"
}

setup_full_system() {
  local root="$1"
  
  echo ""
  echo "=== Full System Setup ==="
  echo ""
  
  # Step 1: Git submodules
  echo "-> Step 1/7: Updating git submodules..."
  update_submodules "$root"
  
  # Create configuration files from examples if they don't exist
  echo "  Creating configuration files from examples..."
  scaffold_config_files "$root" || true
  
  # Step 2: Create virtual environment
  echo "-> Step 2/7: Creating Python virtual environment..."
  local venv_path="$root/virtual_env/python"
  if [[ -f "$venv_path/bin/activate" && -f "$venv_path/bin/python" ]]; then
    echo "  Virtual environment already exists"
  else
    if ! python3.12 -m venv "$venv_path"; then
      echo "[ERROR] Failed to create virtual environment" >&2
      exit 1
    fi
    echo "[OK] Virtual environment created"
  fi
  
  # Step 3: Install Poetry
  echo "-> Step 3/7: Installing Poetry..."
  local venv_activate="$venv_path/bin/activate"
  # shellcheck disable=SC1090
  source "$venv_activate"
  # Use python -m pip to avoid shell function wrappers ("pip()") from init_terminal.sh.
  # Force reinstall to restore a broken/missing console script.
  if ! python -m pip install --upgrade --force-reinstall poetry; then
    echo "[ERROR] Failed to install Poetry" >&2
    exit 1
  fi
  echo "[OK] Poetry installed"
  
  # Step 4: Install CLI wrapper
  echo "-> Step 4/7: Installing ErgoMS CLI..."
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
  echo "-> Step 5/7: Installing dependencies (python + npm)..."
  cd "$root" || exit 1
  export POETRY_VIRTUALENVS_CREATE=false
  echo "  Running: python -m commands install (core + module deps)..."
  if ! (cd "$root/core/api" && export PYTHONPATH="$root" && python -m commands install); then
    echo "[ERROR] commands install failed" >&2
    exit 1
  fi
  if ! npm run install:all; then
    echo "[ERROR] npm run install:all failed" >&2
    exit 1
  fi
  if ! npm run build; then
    echo "[ERROR] npm run build failed" >&2
    exit 1
  fi
  if ! (cd "$root/core/api" && export PYTHONPATH="$root" && python -m commands migrate); then
    echo "[ERROR] Database migration failed" >&2
    exit 1
  fi
  (cd "$root/core/api" && export PYTHONPATH="$root" && python -m commands warmup_caches) || true
  echo "[OK] Setup completed"
  
  # Step 6: Collect static
  echo "-> Step 6/7: Collecting static files..."
  if ! (cd "$root/core/api" && export PYTHONPATH="$root" && python -m commands collectstatic --noinput); then
    echo "[ERROR] Failed to collect static files" >&2
    exit 1
  fi
  echo "[OK] Static files collected"
  
  # Step 7: Setup complete (services not installed)
  echo "-> Step 7/7: Setup complete"
  
  echo ""
  echo "=== Full System Setup Complete ==="
  echo ""
  echo "System is ready! To install and start services, run:"
  echo "  ergoms install-services"
  echo ""
  echo "You can now use 'ergoms' commands to manage your system."
}

# shellcheck source=lib/clean.sh
source "$LIB_DIR/clean.sh"

export -f setup_full_system
export -f update_submodules
export -f scaffold_config_files
