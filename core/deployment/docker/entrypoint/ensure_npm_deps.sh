#!/bin/sh
# Установка npm-зависимостей в контейнере client (smart / always).
set -eu

MARKER="${ERGO_NPM_DEPS_MARKER:-/app/node_modules/.ergo-docker-deps-ok}"
MODE="${DOCKER_NPM_INSTALL:-smart}"

needs_install() {
  if [ "$MODE" = "always" ]; then
    return 0
  fi

  if [ ! -f "$MARKER" ]; then
    return 0
  fi

  for candidate in \
    /app/package.json \
    /app/package-lock.json \
    /app/core/client/package.json
  do
    if [ -f "$candidate" ] && [ "$candidate" -nt "$MARKER" ]; then
      return 0
    fi
  done

  if [ -d /app/modules ]; then
    for pkg in /app/modules/*/client/package.json; do
      if [ -f "$pkg" ] && [ "$pkg" -nt "$MARKER" ]; then
        return 0
      fi
    done
  fi

  return 1
}

if needs_install; then
  echo "[INFO] npm: установка зависимостей…"
  npm run install:all
  mkdir -p "$(dirname "$MARKER")"
  touch "$MARKER"
else
  echo "[INFO] npm: зависимости актуальны"
fi
