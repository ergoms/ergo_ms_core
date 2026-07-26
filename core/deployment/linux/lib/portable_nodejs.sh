#!/usr/bin/env bash
# Portable Node.js LTS -> virtual_env/packages/nodejs
# Версия зафиксирована: при обновлении править PORTABLE_NODE_LTS_VERSION.
# Архив кэшируется в virtual_env/cache/downloads; extract — в virtual_env/cache/tmp.

PORTABLE_NODE_LTS_VERSION='24.18.0'

# shellcheck source=portable_archive.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable_archive.sh"

portable_nodejs_dir() {
  local root="$1"
  echo "$root/virtual_env/packages/nodejs"
}

portable_node_exe() {
  local root="$1"
  echo "$(portable_nodejs_dir "$root")/bin/node"
}

portable_npm_exe() {
  local root="$1"
  echo "$(portable_nodejs_dir "$root")/bin/npm"
}

portable_nodejs_installed() {
  local root="$1"
  local exe
  exe="$(portable_node_exe "$root")"
  [[ -x "$exe" ]] && "$exe" --version >/dev/null 2>&1
}

portable_node_arch_suffix() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    aarch64|arm64) echo 'linux-arm64' ;;
    x86_64|amd64) echo 'linux-x64' ;;
    *)
      echo "[ERROR] Неподдерживаемая архитектура для portable Node.js: $machine" >&2
      return 1
      ;;
  esac
}

install_portable_nodejs() {
  local root="$1"
  local force="${2:-false}"
  local dest exe
  dest="$(portable_nodejs_dir "$root")"
  exe="$(portable_node_exe "$root")"

  if [[ "$force" != "true" ]] && portable_nodejs_installed "$root"; then
    echo "$(format_ergo_console skip "Portable Node.js уже установлен: $($exe --version 2>&1)")"
    return 0
  fi

  local downloads cache_tmp version arch
  downloads="$root/virtual_env/cache/downloads"
  cache_tmp="$root/virtual_env/cache/tmp"
  mkdir -p "$downloads" "$cache_tmp"
  version="$PORTABLE_NODE_LTS_VERSION"
  arch="$(portable_node_arch_suffix)" || return 1

  local tar_name="node-v${version}-${arch}.tar.xz"
  local url="https://nodejs.org/dist/v${version}/${tar_name}"
  local archive extract partial
  archive="$downloads/$tar_name"
  extract="$cache_tmp/nodejs_extract"
  partial="${archive}.partial"

  local attempt=0
  while true; do
    attempt=$((attempt + 1))
    if ! cached_runtime_archive_ok "$archive"; then
      echo "$(format_ergo_console info "Загрузка Node.js LTS v${version} (${arch})…")"
      download_runtime_archive "$url" "$archive" || return 1
    else
      echo "$(format_ergo_console info "Кэш архива Node.js: ${tar_name}")"
    fi

    rm -rf "$extract"
    mkdir -p "$extract"
    if ! tar -xJf "$archive" -C "$extract"; then
      if [[ "$attempt" -ge 2 ]]; then
        echo "[ERROR] Не удалось распаковать архив Node.js" >&2
        rm -f "$partial"
        rm -rf "$extract"
        return 1
      fi
      echo "$(format_ergo_console warning 'Архив Node.js повреждён — повторная загрузка')"
      rm -f "$archive"
      continue
    fi

    local inner
    inner="$(find "$extract" -maxdepth 1 -mindepth 1 -type d | head -n1)"
    if [[ -z "$inner" || ! -x "$inner/bin/node" ]]; then
      if [[ "$attempt" -ge 2 ]]; then
        echo "[ERROR] В архиве Node.js не найден bin/node" >&2
        rm -f "$partial"
        rm -rf "$extract"
        return 1
      fi
      echo "$(format_ergo_console warning 'Архив Node.js некорректен — повторная загрузка')"
      rm -f "$archive"
      continue
    fi

    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    mv "$inner" "$dest"
    rm -f "$partial"
    rm -rf "$extract"

    if [[ ! -x "$exe" ]]; then
      echo "[ERROR] После установки не найден: $exe" >&2
      return 1
    fi

    echo "$(format_ergo_console ok "Portable Node.js установлен: $($exe --version 2>&1)")"
    return 0
  done
}

export -f portable_nodejs_dir portable_node_exe portable_npm_exe
export -f portable_nodejs_installed portable_node_arch_suffix
export -f install_portable_nodejs
