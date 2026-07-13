#!/usr/bin/env bash
# Help system
# Справка ergoms (ядро и модули через ergoms_help.py)

print_usage() {
  local detected_root="${1:-}"
  shift || true

  if [[ -n "$detected_root" ]]; then
    local python_exe="$detected_root/virtual_env/python/bin/python"
    local script_path="$detected_root/core/deployment/scripts/ergoms_help.py"
    if [[ -x "$python_exe" && -f "$script_path" ]]; then
      exec "$python_exe" "$script_path" --platform linux --root "$detected_root" "$@"
    fi
  fi

  cat <<'FALLBACK'
Справка недоступна: не найдено виртуальное окружение.
Выполните первичную настройку (ergoms setup или setup-full).
Подробнее: .docs/cli.md
FALLBACK
}

export -f print_usage
