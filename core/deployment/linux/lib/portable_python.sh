#!/usr/bin/env bash
# Portable CPython 3.12.x (python-build-standalone) -> virtual_env/packages/python
# Версия зафиксирована: при обновлении править PORTABLE_PYTHON_PBS_TAG / PORTABLE_PYTHON_VERSION.

PORTABLE_PYTHON_PBS_TAG='20260718'
PORTABLE_PYTHON_VERSION='3.12.13'

portable_python_dir() {
  local root="$1"
  echo "$root/virtual_env/packages/python"
}

portable_python_exe() {
  local root="$1"
  echo "$(portable_python_dir "$root")/bin/python3"
}

portable_python_installed() {
  local root="$1"
  local exe
  exe="$(portable_python_exe "$root")"
  [[ -x "$exe" ]] && "$exe" --version >/dev/null 2>&1
}

portable_python_arch_triple() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    aarch64|arm64) echo 'aarch64-unknown-linux-gnu' ;;
    x86_64|amd64) echo 'x86_64-unknown-linux-gnu' ;;
    *)
      echo "[ERROR] Неподдерживаемая архитектура для portable Python: $machine" >&2
      return 1
      ;;
  esac
}

_download_file_pbs() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 --max-time 600 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  else
    echo "[ERROR] Нужны curl или wget для загрузки Python" >&2
    return 1
  fi
}

pinned_portable_python_asset() {
  local arch_triple="$1"
  local name="cpython-${PORTABLE_PYTHON_VERSION}+${PORTABLE_PYTHON_PBS_TAG}-${arch_triple}-install_only.tar.gz"
  local url="https://github.com/astral-sh/python-build-standalone/releases/download/${PORTABLE_PYTHON_PBS_TAG}/${name}"
  printf '%s\n' "$name"
  printf '%s\n' "$url"
}

install_portable_python() {
  local root="$1"
  local force="${2:-false}"
  local dest exe
  dest="$(portable_python_dir "$root")"
  exe="$(portable_python_exe "$root")"

  if [[ "$force" != "true" ]] && portable_python_installed "$root"; then
    echo "$(format_ergo_console skip "Portable Python уже установлен: $($exe --version 2>&1)")"
    return 0
  fi

  local arch_triple cache_tmp
  arch_triple="$(portable_python_arch_triple)" || return 1
  cache_tmp="$root/virtual_env/cache/tmp"
  mkdir -p "$cache_tmp"

  local name url
  {
    read -r name
    read -r url
  } < <(pinned_portable_python_asset "$arch_triple")

  echo "$(format_ergo_console info "Загрузка $name…")"

  local archive extract
  archive="$cache_tmp/$name"
  extract="$cache_tmp/python_pbs_extract"
  rm -rf "$extract"
  mkdir -p "$extract"

  _download_file_pbs "$url" "$archive" || return 1
  tar -xzf "$archive" -C "$extract" || {
    echo "[ERROR] Не удалось распаковать архив Python" >&2
    rm -f "$archive"
    rm -rf "$extract"
    return 1
  }

  local python_src="$extract/python"
  if [[ ! -x "$python_src/bin/python3" ]]; then
    local found
    found="$(find "$extract" -maxdepth 3 -type f -name python3 2>/dev/null | head -n1)"
    if [[ -n "$found" ]]; then
      python_src="$(cd "$(dirname "$found")/.." && pwd)"
    fi
  fi
  if [[ ! -x "$python_src/bin/python3" ]]; then
    echo "[ERROR] В архиве не найден bin/python3" >&2
    rm -f "$archive"
    rm -rf "$extract"
    return 1
  fi

  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$python_src" "$dest"
  rm -f "$archive"
  rm -rf "$extract"

  if [[ ! -x "$exe" ]]; then
    echo "[ERROR] После установки не найден: $exe" >&2
    return 1
  fi

  echo "$(format_ergo_console ok "Portable Python установлен: $($exe --version 2>&1)")"
}

export -f portable_python_dir portable_python_exe portable_python_installed
export -f portable_python_arch_triple pinned_portable_python_asset install_portable_python
