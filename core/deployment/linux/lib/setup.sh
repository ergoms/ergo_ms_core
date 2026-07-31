#!/usr/bin/env bash
# Full system setup
# Полная настройка системы

update_submodules() {
  local root="$1"
  
  cd "$root" || exit 1
  if ! git submodule update --init --remote core/api core/client core/media_api; then
    write_ergoms_message setup_error_submodules_plain red --stderr
    exit 1
  fi
  
  write_ergoms_message setup_switch_dev_branch yellow
  
  cd "$root/core/api" || exit 1
  if ! git checkout dev; then
    write_ergoms_message setup_warn_dev_branch yellow --stderr "path=core/api"
  fi
  
  cd "$root/core/client" || exit 1
  if ! git checkout dev; then
    write_ergoms_message setup_warn_dev_branch yellow --stderr "path=core/client"
  fi
  
  cd "$root/core/media_api" || exit 1
  if ! git checkout dev; then
    write_ergoms_message setup_warn_dev_branch yellow --stderr "path=core/media_api"
  fi
  
  cd "$root" || exit 1
  write_ergoms_message setup_ok_submodules green
}

update_module_submodules() {
  local root="$1"
  local gitmodules="$root/.gitmodules"
  local -a module_paths=()
  local key path name branch

  if [[ ! -f "$gitmodules" ]]; then
    write_ergoms_message setup_error_gitmodules_missing red --stderr "path=$gitmodules"
    exit 1
  fi

  echo ""
  write_ergoms_message setup_heading_modules cyan
  echo ""

  cd "$root" || exit 1

  while IFS=' ' read -r key path; do
    if [[ "$path" == modules/* ]]; then
      module_paths+=("$path")
    fi
  done < <(git config -f "$gitmodules" --get-regexp '^submodule\..*\.path$' | awk '{print $1, $2}')

  if [[ ${#module_paths[@]} -eq 0 ]]; then
    write_ergoms_message setup_warn_no_module_submodules_alt yellow --stderr
    exit 0
  fi

  local succeeded=0
  local failed=0
  local skipped=0
  local -a failed_paths=()

  write_ergoms_message setup_updating_modules_alt yellow "" "count=${#module_paths[@]}"
  while IFS=' ' read -r key path; do
    [[ "$path" == modules/* ]] || continue
    name="${key#submodule.}"
    name="${name%.path}"
    branch="$(git config -f "$gitmodules" "submodule.$name.branch")"
    branch="${branch:-dev}"

    if [[ -z "$(git ls-files -s -- "$path")" ]]; then
      write_ergoms_message setup_skip_not_in_index gray "" "path=$path"
      skipped=$((skipped + 1))
      continue
    fi

    echo "  $path..."
    if ! git submodule update --init --remote -- "$path"; then
      write_ergoms_message setup_warn_update_failed yellow --stderr "path=$path"
      failed=$((failed + 1))
      failed_paths+=("$path")
      continue
    fi

    if ! (cd "$root/$path" && git checkout "$branch"); then
      write_ergoms_message setup_warn_switch_branch_named yellow --stderr "branch=$branch" "path=$path"
    fi

    succeeded=$((succeeded + 1))
  done < <(git config -f "$gitmodules" --get-regexp '^submodule\..*\.path$' | awk '{print $1, $2}')

  cd "$root" || exit 1

  if [[ "$succeeded" -gt 0 ]]; then
    if [[ "$skipped" -gt 0 || "$failed" -gt 0 ]]; then
      write_ergoms_message setup_ok_modules_summary_full green "" "succeeded=$succeeded" "skipped=$skipped" "failed=$failed"
    else
      write_ergoms_message setup_ok_modules_summary green "" "succeeded=$succeeded"
    fi
    local fp
    for fp in "${failed_paths[@]}"; do
      echo "  - $fp" >&2
    done
    return 0
  fi

  if [[ "$failed" -gt 0 ]]; then
    write_ergoms_message setup_error_no_modules red --stderr "failed=$failed"
    local fp
    for fp in "${failed_paths[@]}"; do
      echo "  - $fp" >&2
    done
    exit 1
  fi

  write_ergoms_message setup_warn_no_modules yellow --stderr
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
    write_ergoms_message setup_warn_python_missing_config_short yellow --stderr
    return 1
  fi

  if [[ ! -f "$script" ]]; then
    write_ergoms_message setup_warn_config_script_missing yellow --stderr "path=$script"
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
