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
    echo "[ERROR] Не найден локальный файл: $local_bin" >&2
    echo "  Восстановите core/deployment/bin из репозитория." >&2
    return 1
  fi

  chmod +x "$local_bin" 2>/dev/null || true

  echo "[OK] CLI ergoms — $bin_dir"
  echo "  Запуск: ergoms … (Project-Shell / PATH с core/deployment/bin)"
  echo "  Работает только из каталога проекта и подпапок (cwd)."
}

remove_cli_wrapper() {
  echo "[INFO] Файлы в core/deployment/bin не удаляются (они в репозитории)"
}

export -f create_cli_wrapper
export -f remove_cli_wrapper
