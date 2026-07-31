#!/usr/bin/env bash
# CLI wrapper management — core/deployment/bin (без системных каталогов)

_ERGOMS_CLI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ergoms_project_root_from_cli_lib() {
  cd "$_ERGOMS_CLI_LIB_DIR/../../../.." && pwd
}

_ergoms_bin_dir() {
  echo "$1/core/deployment/bin"
}

create_cli_wrapper() {
  local project_root="${1:-}"
  if [[ -z "$project_root" ]]; then
    project_root="$(_ergoms_project_root_from_cli_lib)"
  fi
  local bin_dir local_bin
  bin_dir="$(_ergoms_bin_dir "$project_root")"
  local_bin="$bin_dir/ergoms"

  if [[ ! -f "$local_bin" ]]; then
    ERGO_ROOT="$project_root" write_ergoms_message cli_local_missing red --stderr "path=$local_bin"
    ERGO_ROOT="$project_root" write_ergoms_message cli_restore_bin yellow --stderr
    return 1
  fi

  chmod +x "$local_bin" 2>/dev/null || true

  ERGO_ROOT="$project_root" write_ergoms_message cli_ok_path green "" "path=$bin_dir"
  ERGO_ROOT="$project_root" write_ergoms_message cli_run_hint cyan
  ERGO_ROOT="$project_root" write_ergoms_message cli_cwd_hint cyan
}

remove_cli_wrapper() {
  local project_root="${1:-}"
  if [[ -z "$project_root" ]]; then
    project_root="$(_ergoms_project_root_from_cli_lib)"
  fi
  ERGO_ROOT="$project_root" write_ergoms_message cli_bin_not_removed cyan
}

export -f create_cli_wrapper
export -f remove_cli_wrapper
