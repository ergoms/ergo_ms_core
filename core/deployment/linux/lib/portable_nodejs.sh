#!/usr/bin/env bash
# Portable Node.js LTS -> virtual_env/packages/nodejs
# Версия зафиксирована: при обновлении править PORTABLE_NODE_LTS_VERSION.

PORTABLE_NODE_LTS_VERSION='24.18.0'

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

_download_file_node() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 --max-time 600 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  else
    echo "[ERROR] Нужны curl или wget для загрузки Node.js" >&2
    return 1
  fi
}

install_portable_nodejs() {
  local root="$1"
  local force="${2:-false}"
  local dest exe legacy
  dest="$(portable_nodejs_dir "$root")"
  exe="$(portable_node_exe "$root")"
  legacy="$root/virtual_env/nodejs"

  # Перенос со старого пути virtual_env/nodejs
  if [[ ! -x "$exe" && -x "$legacy/bin/node" ]]; then
    mkdir -p "$(dirname "$dest")"
    rm -rf "$dest"
    mv "$legacy" "$dest"
    echo "$(format_ergo_console ok 'Portable Node.js перенесён в virtual_env/packages/nodejs')"
  elif [[ -d "$legacy" ]]; then
    rm -rf "$legacy"
  fi

  if [[ "$force" != "true" ]] && portable_nodejs_installed "$root"; then
    echo "$(format_ergo_console skip "Portable Node.js уже установлен: $($exe --version 2>&1)")"
    return 0
  fi

  local cache_tmp version arch
  cache_tmp="$root/virtual_env/cache/tmp"
  mkdir -p "$cache_tmp"
  version="$PORTABLE_NODE_LTS_VERSION"
  arch="$(portable_node_arch_suffix)" || return 1

  local tar_name="node-v${version}-${arch}.tar.xz"
  local url="https://nodejs.org/dist/v${version}/${tar_name}"

  echo "$(format_ergo_console info "Загрузка Node.js LTS v${version} (${arch})…")"

  local archive extract
  archive="$cache_tmp/$tar_name"
  extract="$cache_tmp/nodejs_extract"
  rm -rf "$extract"
  mkdir -p "$extract"

  _download_file_node "$url" "$archive" || return 1
  tar -xJf "$archive" -C "$extract" || {
    echo "[ERROR] Не удалось распаковать архив Node.js" >&2
    rm -f "$archive"
    rm -rf "$extract"
    return 1
  }

  local inner
  inner="$(find "$extract" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  if [[ -z "$inner" || ! -x "$inner/bin/node" ]]; then
    echo "[ERROR] В архиве Node.js не найден bin/node" >&2
    rm -f "$archive"
    rm -rf "$extract"
    return 1
  fi

  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$inner" "$dest"
  rm -f "$archive"
  rm -rf "$extract"

  if [[ ! -x "$exe" ]]; then
    echo "[ERROR] После установки не найден: $exe" >&2
    return 1
  fi

  echo "$(format_ergo_console ok "Portable Node.js установлен: $($exe --version 2>&1)")"
}

export -f portable_nodejs_dir portable_node_exe portable_npm_exe
export -f portable_nodejs_installed portable_node_arch_suffix
export -f install_portable_nodejs
