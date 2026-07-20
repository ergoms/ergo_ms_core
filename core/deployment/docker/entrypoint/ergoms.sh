#!/usr/bin/env bash
# Тонкая обёртка ergoms внутри Docker (api / media-api / celery).
# Полный CLI хоста (setup, docker-*, службы) здесь недоступен.
set -euo pipefail

ERGO_TAG_ERROR='[ERROR]'
ERGO_TAG_INFO='[INFO]'

# В контейнере корень всегда /app. ERGO_PROJECT_ROOT в .compose.env — путь хоста для bind-mount.
ROOT="/app"
API_DIR="$ROOT/core/api"

usage() {
  cat <<'EOF'
ergoms (Docker) — команды Django API и media_api внутри контейнера.

Использование:
  ergoms api <команда> [аргументы...]
  ergoms media_api <команда> [аргументы...]
  ergoms help

Примеры:
  ergoms api createsuperuser
  ergoms api migrate
  ergoms api shell

Без интерактива (удобно из Windows-терминала):
  export DJANGO_SUPERUSER_USERNAME=admin
  export DJANGO_SUPERUSER_PASSWORD='your-password'
  export DJANGO_SUPERUSER_EMAIL=admin@example.com
  ergoms api createsuperuser --noinput

Остальные команды (setup, docker-*, start-client, …) — только на хосте:
  ergoms docker-shell-api
EOF
}

resolve_python() {
  if command -v poetry >/dev/null 2>&1 && [ -f "$ROOT/pyproject.toml" ]; then
    local venv_bin
    venv_bin="$(poetry env info -p 2>/dev/null)/bin" || venv_bin=""
    if [ -n "$venv_bin" ] && [ -x "$venv_bin/python" ]; then
      echo "$venv_bin/python"
      return 0
    fi
  fi
  if [ -x "$ROOT/virtual_env/python/bin/python" ]; then
    echo "$ROOT/virtual_env/python/bin/python"
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    command -v python
    return 0
  fi
  return 1
}

run_api() {
  local py
  if ! py="$(resolve_python)"; then
    echo "${ERGO_TAG_ERROR} Python не найден в контейнере" >&2
    exit 1
  fi
  if [ ! -d "$API_DIR" ]; then
    echo "${ERGO_TAG_ERROR} Каталог API не найден: $API_DIR" >&2
    exit 1
  fi
  export PYTHONPATH="$ROOT"
  export PYTHONIOENCODING=utf-8:replace
  export PYTHONUTF8=1
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export PYTHONUNBUFFERED=1
  export ERGOMS_INTERNAL=1
  cd "$API_DIR" || exit 1
  exec "$py" -m commands "$@"
}

run_media_api() {
  local py
  if ! py="$(resolve_python)"; then
    echo "${ERGO_TAG_ERROR} Python не найден в контейнере" >&2
    exit 1
  fi
  export PYTHONPATH="$ROOT/core/media_api/src:$ROOT"
  export PYTHONIOENCODING=utf-8:replace
  export PYTHONUTF8=1
  export LANG="${LANG:-C.UTF-8}"
  export LC_ALL="${LC_ALL:-C.UTF-8}"
  export PYTHONUNBUFFERED=1
  export ERGOMS_INTERNAL=1
  cd "$ROOT" || exit 1
  exec "$py" -m media_server.manage "$@"
}

main() {
  if [ "$#" -eq 0 ]; then
    usage
    exit 0
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    help|-h|--help)
      usage
      exit 0
      ;;
    api)
      if [ "$#" -eq 0 ]; then
        echo "${ERGO_TAG_ERROR} Укажите команду Django. Пример: ergoms api createsuperuser" >&2
        exit 1
      fi
      run_api "$@"
      ;;
    media_api)
      if [ "$#" -eq 0 ]; then
        echo "${ERGO_TAG_ERROR} Укажите команду media_api. Пример: ergoms media_api check" >&2
        exit 1
      fi
      run_media_api "$@"
      ;;
    *)
      echo "${ERGO_TAG_ERROR} Команда «${cmd}» в контейнере недоступна." >&2
      echo "${ERGO_TAG_INFO} Здесь поддерживаются: api, media_api, help." >&2
      echo "${ERGO_TAG_INFO} Полный ergoms (setup, docker-*, службы) — на хосте проекта." >&2
      exit 1
      ;;
  esac
}

main "$@"
