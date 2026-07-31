#!/usr/bin/env bash
# Portable CPython 3.12.x (python-build-standalone) -> virtual_env/packages/python
# Версия зафиксирована: при обновлении править PORTABLE_PYTHON_PBS_TAG / PORTABLE_PYTHON_VERSION.
# Архив кэшируется в virtual_env/cache/downloads; extract — в virtual_env/cache/tmp.

PORTABLE_PYTHON_PBS_TAG='20260718'
PORTABLE_PYTHON_VERSION='3.12.13'

# shellcheck source=portable_archive.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable_archive.sh"

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
  local machine root="${1:-}"
  machine="$(uname -m)"
  case "$machine" in
    aarch64|arm64) echo 'aarch64-unknown-linux-gnu' ;;
    x86_64|amd64) echo 'x86_64-unknown-linux-gnu' ;;
    *)
      if [[ -n "$root" ]]; then
        ergoms_console_from_root "$root" portable_unsupported_arch_python red --stderr "arch=$machine"
      fi
      return 1
      ;;
  esac
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
    ergoms_console_from_root "$root" portable_python_skip_installed gray "" "version=$($exe --version 2>&1)"
    return 0
  fi

  local arch_triple downloads cache_tmp
  arch_triple="$(portable_python_arch_triple "$root")" || return 1
  downloads="$root/virtual_env/cache/downloads"
  cache_tmp="$root/virtual_env/cache/tmp"
  mkdir -p "$downloads" "$cache_tmp"

  local name url
  {
    read -r name
    read -r url
  } < <(pinned_portable_python_asset "$arch_triple")

  local archive extract partial
  archive="$downloads/$name"
  extract="$cache_tmp/python_pbs_extract"
  partial="${archive}.partial"

  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    if ! cached_runtime_archive_ok "$archive"; then
      ergoms_console_from_root "$root" portable_python_info_download cyan "" "name=$name"
      download_runtime_archive "$url" "$archive" "$root" || return 1
    else
      ergoms_console_from_root "$root" portable_python_info_cache cyan "" "name=$name"
    fi

    rm -rf "$extract"
    mkdir -p "$extract"
    if ! tar -xzf "$archive" -C "$extract"; then
      if [[ "$attempt" -ge 2 ]]; then
        ergoms_console_from_root "$root" portable_python_error_unpack red --stderr
        rm -f "$partial"
        rm -rf "$extract"
        return 1
      fi
      ergoms_console_from_root "$root" portable_python_warn_corrupt yellow
      rm -f "$archive"
      continue
    fi

    local python_src="$extract/python"
    if [[ ! -x "$python_src/bin/python3" ]]; then
      local found
      found="$(find "$extract" -maxdepth 3 -type f -name python3 2>/dev/null | head -n1)"
      if [[ -n "$found" ]]; then
        python_src="$(cd "$(dirname "$found")/.." && pwd)"
      fi
    fi
    if [[ ! -x "$python_src/bin/python3" ]]; then
      if [[ "$attempt" -ge 2 ]]; then
        ergoms_console_from_root "$root" portable_python_error_bin_missing red --stderr "binary=bin/python3"
        rm -f "$partial"
        rm -rf "$extract"
        return 1
      fi
      ergoms_console_from_root "$root" portable_python_warn_invalid yellow
      rm -f "$archive"
      continue
    fi

    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    mv "$python_src" "$dest"
    rm -f "$partial"
    rm -rf "$extract"

    if [[ ! -x "$exe" ]]; then
      ergoms_console_from_root "$root" portable_not_found_after_install red --stderr "path=$exe"
      return 1
    fi

    ergoms_console_from_root "$root" portable_python_ok_installed green "" "version=$($exe --version 2>&1)"
    return 0
  done
}

export -f portable_python_dir portable_python_exe portable_python_installed
export -f portable_python_arch_triple pinned_portable_python_asset install_portable_python
