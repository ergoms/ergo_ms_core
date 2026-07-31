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

  if declare -F write_ergoms_message >/dev/null 2>&1; then
    write_ergoms_message help_unavailable red --stderr
    write_ergoms_message help_setup_hint yellow --stderr
    write_ergoms_message help_doc_hint cyan --stderr
  else
    cat <<'FALLBACK'
Help unavailable: virtual environment not found.
Run initial setup (ergoms setup or setup-full).
See: .docs/cli.md
FALLBACK
  fi
}

export -f print_usage
