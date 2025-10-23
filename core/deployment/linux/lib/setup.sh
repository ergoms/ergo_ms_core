#!/usr/bin/env bash
# Full system setup
# Полная настройка системы

setup_full_system() {
  local root="$1"
  
  echo ""
  echo "=== Full System Setup ==="
  echo ""
  
  # Step 1: Git submodules
  echo "-> Step 1/7: Updating git submodules..."
  cd "$root" || exit 1
  if ! git submodule update --init --remote core/api core/client; then
    echo "[ERROR] Failed to update git submodules" >&2
    exit 1
  fi
  
  cd "$root/core/api" || exit 1
  if ! git checkout dev; then
    echo "[ERROR] Failed to checkout dev branch in core/api" >&2
    exit 1
  fi
  
  cd "$root/core/client" || exit 1
  if ! git checkout dev; then
    echo "[ERROR] Failed to checkout dev branch in core/client" >&2
    exit 1
  fi
  
  cd "$root" || exit 1
  echo "[OK] Git submodules updated"
  
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
  if ! pip install poetry; then
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
  
  # Step 5: Run setup (poetry install && npm install && api migrate)
  echo "-> Step 5/7: Running ergoms setup..."
  cd "$root/core" || exit 1
  if ! poetry install; then
    echo "[ERROR] Poetry install failed" >&2
    exit 1
  fi
  if ! npm install; then
    echo "[ERROR] npm install failed" >&2
    exit 1
  fi
  if ! api migrate; then
    echo "[ERROR] Database migration failed" >&2
    exit 1
  fi
  echo "[OK] Setup completed"
  
  # Step 6: Collect static
  echo "-> Step 6/7: Collecting static files..."
  if ! api collectstatic --noinput; then
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

export -f setup_full_system

