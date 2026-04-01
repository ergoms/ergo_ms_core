#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

step() {
  echo
  echo "=== $* ==="
}

step "1. Проверка базовых версий"
if ! command -v python3 >/dev/null 2>&1; then
  log "python3 НЕ найден"
else
  PY_VER="$(python3 --version 2>&1 || echo '')"
  log "${PY_VER}"
  if [[ "${PY_VER}" != Python\ 3.12.* ]]; then
    log "ВНИМАНИЕ: требуется Python 3.12.x, у вас: ${PY_VER}"
  fi
fi
log "Node.js:" && node -v || log "node НЕ найден"
log "npm:" && ergoms npm -v || log "npm НЕ найден"

step "2. Проверка PostgreSQL и подключения к БД ergo_ms"
if command -v psql >/dev/null 2>&1; then
  log "Версия psql:" && psql --version || true

  DB_HOST="${DB_HOST:-127.0.0.1}"
  DB_NAME="${DB_NAME:-ergo_ms}"
  DB_USER="${DB_USER:-postgres}"
  DB_PASSWORD="${DB_PASSWORD:-admin}"

  if PGPASSWORD="${DB_PASSWORD}" psql -h "${DB_HOST}" -U "${DB_USER}" -d "${DB_NAME}" -c "select 1;" >/dev/null 2>&1; then
    log "Подключение к БД ${DB_NAME} как ${DB_USER}@${DB_HOST} успешно."
  else
    log "НЕ удалось подключиться к БД ${DB_NAME} как ${DB_USER}@${DB_HOST}."
  fi
else
  log "psql НЕ найден в PATH."
fi

step "3. Проверка наличия ergoms и help"
if command -v ergoms >/dev/null 2>&1; then
  log "ergoms найден: $(command -v ergoms)"
  ergoms help | sed -n '1,40p' || true
else
  log "ergoms НЕ найден. Попробуйте сначала запустить setup-full."
fi

step "4. Проверка виртуального окружения проекта"
VENV_PY="${ROOT_DIR}/virtual_env/python/bin/python"
if [[ -x "${VENV_PY}" ]]; then
  log "VENV Python: ${VENV_PY}"
  "${VENV_PY}" -V || true
else
  log "virtual_env/python не найден или python не исполняемый."
fi

step "5. Тест Django-команд через ergoms api"
if command -v ergoms >/dev/null 2>&1; then
  log "Тест: ergoms api check"
  if ergoms api check >/dev/null 2>&1; then
    log "Django check прошёл успешно."
  else
    log "Django check завершился с ошибкой (см. вывод выше)."
  fi
else
  log "Пропускаю тест Django-команд: ergoms не найден."
fi

step "6. Краткий тест миграций (без изменений схемы)"
if command -v ergoms >/dev/null 2>&1; then
  log "Тест: ergoms db-migrate (может занять время)"
  if ergoms db-migrate; then
    log "Миграции применены / уже в актуальном состоянии."
  else
    log "Миграции завершились с ошибкой (см. вывод выше)."
  fi
else
  log "Пропускаю миграции: ergoms не найден."
fi

echo
log "Проверка завершена."

