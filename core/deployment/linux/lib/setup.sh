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
  if ! git submodule update --init --remote core/api core/client core/django core/media_api; then
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
  
  cd "$root/core/django" || exit 1
  if ! git checkout dev; then
    echo "[ERROR] Failed to checkout dev branch in core/django" >&2
    exit 1
  fi
  
  cd "$root/core/media_api" || exit 1
  if ! git checkout dev; then
    echo "[ERROR] Failed to checkout dev branch in core/media_api" >&2
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
  
  # Step 5: Run setup (poetry install && npm install && npm run build && api migrate)
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
  if ! npm run build; then
    echo "[ERROR] npm run build failed" >&2
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

# Clean project dependencies
# Очистка зависимостей проекта
clear_project_dependencies() {
  local root="$1"
  
  echo ""
  echo "=== Cleaning Project Dependencies ==="
  echo ""
  echo "This will remove:"
  echo "  - node_modules"
  echo "  - virtual_env/python/*"
  echo "  - virtual_env/static_api/*"
  echo "  - virtual_env/celery/*"
  echo "  - virtual_env/nodejs/*"
  echo "  - virtual_env/packages/*"
  echo "  - virtual_env/resources/*"
  echo "  - virtual_env/trained_models/*"
  echo ""
  echo "Media folder will NOT be deleted."
  echo ""
  
  read -rp "Are you sure you want to continue? (y/N) " confirmation
  if [[ ! "$confirmation" =~ ^[yY]$ ]]; then
    echo "Operation cancelled by user."
    return
  fi
  
  # Step 1: Remove node_modules
  echo ""
  echo "-> Step 1/8: Removing node_modules..."
  local node_modules_path="$root/node_modules"
  if [[ -d "$node_modules_path" ]]; then
    if rm -rf "$node_modules_path"; then
      echo "[OK] node_modules removed"
    else
      echo "[ERROR] Failed to remove node_modules" >&2
    fi
  else
    echo "[SKIP] node_modules not found"
  fi
  
  # Step 2: Remove virtual_env/python/*
  echo ""
  echo "-> Step 2/8: Cleaning virtual_env/python..."
  local python_venv_path="$root/virtual_env/python"
  if [[ -d "$python_venv_path" ]]; then
    local removed_count=0
    local item_count=0
    for item in "$python_venv_path"/*; do
      if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
        item_count=$((item_count + 1))
      fi
    done
    
    if [[ $item_count -gt 0 ]]; then
      for item in "$python_venv_path"/*; do
        if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
          if rm -rf "$item"; then
            removed_count=$((removed_count + 1))
          fi
        fi
      done
      echo "[OK] Removed $removed_count items from virtual_env/python"
    else
      echo "[SKIP] virtual_env/python is already empty"
    fi
  else
    echo "[SKIP] virtual_env/python not found"
  fi
  
  # Step 3: Remove virtual_env/static_api/*
  echo ""
  echo "-> Step 3/8: Cleaning virtual_env/static_api..."
  local static_path="$root/virtual_env/static_api"
  if [[ -d "$static_path" ]]; then
    local removed_count=0
    local item_count=0
    for item in "$static_path"/*; do
      if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
        item_count=$((item_count + 1))
      fi
    done
    
    if [[ $item_count -gt 0 ]]; then
      for item in "$static_path"/*; do
        if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
          if rm -rf "$item"; then
            removed_count=$((removed_count + 1))
          fi
        fi
      done
      echo "[OK] Removed $removed_count items from virtual_env/static_api"
    else
      echo "[SKIP] virtual_env/static_api is already empty"
    fi
  else
    echo "[SKIP] virtual_env/static_api not found"
  fi
  
  # Step 4: Remove virtual_env/celery/*
  echo ""
  echo "-> Step 4/8: Cleaning virtual_env/celery..."
  local celery_path="$root/virtual_env/celery"
  if [[ -d "$celery_path" ]]; then
    local removed_count=0
    local item_count=0
    for item in "$celery_path"/*; do
      if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
        item_count=$((item_count + 1))
      fi
    done
    
    if [[ $item_count -gt 0 ]]; then
      for item in "$celery_path"/*; do
        if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
          if rm -rf "$item"; then
            removed_count=$((removed_count + 1))
          fi
        fi
      done
      echo "[OK] Removed $removed_count items from virtual_env/celery"
    else
      echo "[SKIP] virtual_env/celery is already empty"
    fi
  else
    echo "[SKIP] virtual_env/celery not found"
  fi
  
  # Step 5: Remove virtual_env/nodejs/*
  echo ""
  echo "-> Step 5/8: Cleaning virtual_env/nodejs..."
  local nodejs_path="$root/virtual_env/nodejs"
  if [[ -d "$nodejs_path" ]]; then
    local removed_count=0
    local item_count=0
    for item in "$nodejs_path"/*; do
      if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
        item_count=$((item_count + 1))
      fi
    done
    
    if [[ $item_count -gt 0 ]]; then
      for item in "$nodejs_path"/*; do
        if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
          if rm -rf "$item"; then
            removed_count=$((removed_count + 1))
          fi
        fi
      done
      echo "[OK] Removed $removed_count items from virtual_env/nodejs"
    else
      echo "[SKIP] virtual_env/nodejs is already empty"
    fi
  else
    echo "[SKIP] virtual_env/nodejs not found"
  fi
  
  # Step 6: Remove virtual_env/packages/*
  echo ""
  echo "-> Step 6/8: Cleaning virtual_env/packages..."
  local packages_path="$root/virtual_env/packages"
  if [[ -d "$packages_path" ]]; then
    local removed_count=0
    local item_count=0
    for item in "$packages_path"/*; do
      if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
        item_count=$((item_count + 1))
      fi
    done
    
    if [[ $item_count -gt 0 ]]; then
      for item in "$packages_path"/*; do
        if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
          if rm -rf "$item"; then
            removed_count=$((removed_count + 1))
          fi
        fi
      done
      echo "[OK] Removed $removed_count items from virtual_env/packages"
    else
      echo "[SKIP] virtual_env/packages is already empty"
    fi
  else
    echo "[SKIP] virtual_env/packages not found"
  fi
  
  # Step 7: Remove virtual_env/resources/*
  echo ""
  echo "-> Step 7/8: Cleaning virtual_env/resources..."
  local resources_path="$root/virtual_env/resources"
  if [[ -d "$resources_path" ]]; then
    local removed_count=0
    local item_count=0
    for item in "$resources_path"/*; do
      if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
        item_count=$((item_count + 1))
      fi
    done
    
    if [[ $item_count -gt 0 ]]; then
      for item in "$resources_path"/*; do
        if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
          if rm -rf "$item"; then
            removed_count=$((removed_count + 1))
          fi
        fi
      done
      echo "[OK] Removed $removed_count items from virtual_env/resources"
    else
      echo "[SKIP] virtual_env/resources is already empty"
    fi
  else
    echo "[SKIP] virtual_env/resources not found"
  fi
  
  # Step 8: Remove virtual_env/trained_models/*
  echo ""
  echo "-> Step 8/8: Cleaning virtual_env/trained_models..."
  local models_path="$root/virtual_env/trained_models"
  if [[ -d "$models_path" ]]; then
    local removed_count=0
    local item_count=0
    for item in "$models_path"/*; do
      if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
        item_count=$((item_count + 1))
      fi
    done
    
    if [[ $item_count -gt 0 ]]; then
      for item in "$models_path"/*; do
        if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
          if rm -rf "$item"; then
            removed_count=$((removed_count + 1))
          fi
        fi
      done
      echo "[OK] Removed $removed_count items from virtual_env/trained_models"
    else
      echo "[SKIP] virtual_env/trained_models is already empty"
    fi
  else
    echo "[SKIP] virtual_env/trained_models not found"
  fi
  
  echo ""
  echo "=== Cleaning Complete ==="
  echo ""
  echo "To reinstall dependencies, run:"
  echo "  ergoms setup"
  echo ""
}

export -f setup_full_system
export -f clear_project_dependencies

