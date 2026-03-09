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
  
  # Special handling for databases.yaml - only first 8 lines
  local databases_source_path="$root/databases.yaml.example"
  local databases_target_path="$root/databases.yaml"
  if [[ -f "$databases_source_path" ]]; then
    if [[ ! -f "$databases_target_path" ]]; then
      if head -n 8 "$databases_source_path" > "$databases_target_path"; then
        echo "    Created databases.yaml (first 8 lines)"
      else
        echo "    [WARNING] Failed to create databases.yaml" >&2
      fi
    else
      echo "    databases.yaml already exists, skipping"
    fi
  else
    echo "    [WARNING] Example file databases.yaml.example not found" >&2
  fi
  
  # Other configuration files - full copy
  local config_files=(
    "celery_workers.yaml.example:celery_workers.yaml"
    ".env.example:.env"
  )
  
  for config_pair in "${config_files[@]}"; do
    IFS=':' read -r source_file target_file <<< "$config_pair"
    local source_path="$root/$source_file"
    local target_path="$root/$target_file"
    
    if [[ -f "$source_path" ]]; then
      if [[ ! -f "$target_path" ]]; then
        if cp "$source_path" "$target_path"; then
          echo "    Created $target_file"
        else
          echo "    [WARNING] Failed to create $target_file" >&2
        fi
      else
        echo "    $target_file already exists, skipping"
      fi
    else
      echo "    [WARNING] Example file $source_file not found" >&2
    fi
  done
  
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
  if ! python -m commands migrate; then
    echo "[ERROR] Database migration failed" >&2
    exit 1
  fi
  python -m commands warmup_caches || true
  echo "[OK] Setup completed"
  
  # Step 6: Collect static
  echo "-> Step 6/7: Collecting static files..."
  if ! python -m commands collectstatic --noinput; then
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

clean_directory_contents() {
  local dir_path="$1"
  local label="$2"
  
  if [[ ! -d "$dir_path" ]]; then
    echo "[SKIP] $label not found"
    return
  fi
  
  local removed_count=0
  local has_items=false
  for item in "$dir_path"/*; do
    if [[ -e "$item" ]] && [[ "$(basename "$item")" != ".gitkeep" ]]; then
      has_items=true
      if rm -rf "$item"; then
        removed_count=$((removed_count + 1))
      fi
    fi
  done
  
  if [[ "$has_items" == true ]]; then
    echo "[OK] Removed $removed_count items from $label"
  else
    echo "[SKIP] $label is already empty"
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
  )
  
  echo ""
  echo "=== Cleaning Project Dependencies ==="
  echo ""
  echo "This will remove:"
  for p in "${clean_paths[@]}"; do
    echo "  - $p"
  done
  echo ""
  echo "Media folder will NOT be deleted."
  echo ""
  
  read -rp "Are you sure you want to continue? (y/N) " confirmation
  if [[ ! "$confirmation" =~ ^[yY]$ ]]; then
    echo "Operation cancelled by user."
    return
  fi
  
  local total=${#clean_paths[@]}
  local step=0
  for rel_path in "${clean_paths[@]}"; do
    step=$((step + 1))
    local full_path="$root/$rel_path"
    echo ""
    echo "-> Step ${step}/${total}: Cleaning ${rel_path}..."
    
    if [[ "$rel_path" == "node_modules" ]]; then
      if [[ -d "$full_path" ]]; then
        if rm -rf "$full_path"; then
          echo "[OK] $rel_path removed"
        else
          echo "[ERROR] Failed to remove $rel_path" >&2
        fi
      else
        echo "[SKIP] $rel_path not found"
      fi
    else
      clean_directory_contents "$full_path" "$rel_path"
    fi
  done
  
  echo ""
  echo "=== Cleaning Complete ==="
  echo ""
  echo "To reinstall dependencies, run:"
  echo "  ergoms setup"
  echo ""
}

export -f setup_full_system
export -f update_submodules
export -f clean_directory_contents
export -f clear_project_dependencies

