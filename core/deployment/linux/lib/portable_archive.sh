#!/usr/bin/env bash
# Общие хелперы кэша архивов portable runtime (Python / Node.js).
# Кэш: virtual_env/cache/downloads; partial — рядом с целевым файлом.

cached_runtime_archive_ok() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]]
}

download_runtime_archive() {
  local url="$1"
  local dest="$2"
  local partial="${dest}.partial"
  mkdir -p "$(dirname "$dest")"
  rm -f "$partial"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 --max-time 600 -o "$partial" "$url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$partial" "$url" || return 1
  else
    echo "[ERROR] Нужны curl или wget для загрузки runtime-архива" >&2
    return 1
  fi

  if ! cached_runtime_archive_ok "$partial"; then
    echo "[ERROR] Скачанный архив пуст или отсутствует" >&2
    rm -f "$partial"
    return 1
  fi
  mv -f "$partial" "$dest"
}

export -f cached_runtime_archive_ok download_runtime_archive
