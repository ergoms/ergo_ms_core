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

docker_npm_env() {
  export npm_config_audit=false
  export npm_config_fund=false
  export npm_config_update_notifier=false
  export npm_config_maxsockets="${npm_config_maxsockets:-8}"
  export npm_config_fetch_retries=5
}

docker_npm_install_flags="--ignore-scripts --no-package-lock --no-audit --no-fund"

# Копирует node_modules из staging (native FS) в именованный том.
# Bind-mount /app на Docker Desktop (Windows) сильно замедляет npm reify.
copy_node_modules_tree() {
  src="$1"
  dst="$2"
  mkdir -p "$dst"
  if [ -d "$src" ]; then
    rm -rf "$dst"/*
    rm -rf "$dst"/.[!.]* "$dst"/..?* 2>/dev/null || true
    # tar надёжнее cp для скрытых каталогов (.bin) на томах Docker Desktop.
    ( cd "$src" && tar cf - . ) | ( cd "$dst" && tar xf - )
  fi
}

prepare_docker_root_manifest() {
  staging="$1"
  node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync('/app/package.json', 'utf8'));
    delete pkg.workspaces;
    fs.writeFileSync('${staging}/package.json', JSON.stringify(pkg, null, 2));
  "
}

docker_install_root_deps() {
  staging="$(mktemp -d /tmp/ergo-npm-root.XXXXXX)"
  trap 'rm -rf "$staging"' EXIT INT TERM

  prepare_docker_root_manifest "$staging"
  if [ -f /app/.npmrc ]; then
    cp /app/.npmrc "$staging/.npmrc"
  fi

  echo "[INFO] npm: корневые пакеты (staging, без bind-mount)…"
  (
    cd "$staging"
    npm install $docker_npm_install_flags --loglevel=warn
  )

  echo "[INFO] npm: копирование корневых пакетов в том node_modules…"
  copy_node_modules_tree "$staging/node_modules" /app/node_modules
  rm -rf "$staging"
  trap - EXIT INT TERM
}

link_client_workspace_bins() {
  # Отдельный том core/client/node_modules без пакетов ломает npm run --prefix:
  # бинарники (vite и др.) лежат в /app/node_modules/.bin после docker-install.
  mkdir -p /app/core/client/node_modules/.bin
  if [ ! -d /app/node_modules/.bin ]; then
    return 0
  fi
  for bin in /app/node_modules/.bin/*; do
    [ -e "$bin" ] || continue
    name="$(basename "$bin")"
    ln -sf "../../../node_modules/.bin/$name" "/app/core/client/node_modules/.bin/$name"
  done
}

docker_install_npm_deps() {
  docker_npm_env
  echo "[INFO] npm: установка зависимостей (режим Docker)…"
  docker_install_root_deps
  echo "[INFO] npm: модульные пакеты…"
  node core/deployment/scripts/sync-module-npm-deps.js --install-missing
  echo "[INFO] npm: зависимости client workspace…"
  npm install $docker_npm_install_flags --prefix core/client --loglevel=warn
}

if needs_install; then
  if [ -n "${ERGO_DOCKER_SERVICE_NAME:-}" ]; then
    docker_install_npm_deps
  else
    echo "[INFO] npm: установка зависимостей…"
    npm run install:all
  fi
  mkdir -p "$(dirname "$MARKER")"
  touch "$MARKER"
else
  echo "[INFO] npm: зависимости актуальны"
fi

if [ -n "${ERGO_DOCKER_SERVICE_NAME:-}" ]; then
  link_client_workspace_bins
fi
