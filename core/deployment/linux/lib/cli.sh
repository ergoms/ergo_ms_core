#!/usr/bin/env bash
# CLI wrapper management
# Управление CLI wrapper

create_cli_wrapper() {
  local target_script="$1"
  local name
  name="$(cli_name)"
  local path
  path="$(cli_path)"
  local tmp_file
  tmp_file="$(mktemp)"
  cat >"$tmp_file" <<'EOF'
#!/usr/bin/env bash
exec bash "__TARGET_SCRIPT__" "$@"
EOF
  # Inject actual target script path into the wrapper
  if command -v sed >/dev/null 2>&1; then
    sed -i "s|__TARGET_SCRIPT__|${target_script}|g" "$tmp_file"
  else
    # Fallback without in-place sed
    local tmp2
    tmp2="$(mktemp)"
    awk -v p="${target_script}" '{gsub("__TARGET_SCRIPT__", p); print}' "$tmp_file" > "$tmp2"
    mv "$tmp2" "$tmp_file"
  fi
  if [[ $(id -u) -eq 0 ]]; then
    install -m 0755 "$tmp_file" "$path"
  else
    sudo install -m 0755 "$tmp_file" "$path"
  fi
  rm -f "$tmp_file"
  echo "Installed CLI wrapper: $path"
}

remove_cli_wrapper() {
  local path
  path="$(cli_path)"
  if [[ -f "$path" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      rm -f "$path"
    else
      sudo rm -f "$path"
    fi
    echo "Removed CLI wrapper: $path"
  fi
}

export -f create_cli_wrapper
export -f remove_cli_wrapper

