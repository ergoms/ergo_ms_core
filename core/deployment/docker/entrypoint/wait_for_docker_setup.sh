#!/bin/sh
# Ожидание маркера установки (Node-образ client без Python).
set -eu

MARKER="${ERGO_DOCKER_SETUP_MARKER:-/app/logs/.ergo-docker-setup-ok}"
POLL_SEC="${ERGO_DOCKER_SETUP_POLL_SEC:-5}"

case "${ERGO_DOCKER_REQUIRES_SETUP:-}" in
  1|true|yes|on|TRUE|YES|ON) ;;
  *) exit 0 ;;
esac

if [ -f "$MARKER" ]; then
  exit 0
fi

echo "[INFO] Ожидание завершения установки Docker (ergoms docker-init)…"
while [ ! -f "$MARKER" ]; do
  sleep "$POLL_SEC"
done
echo "[OK] Установка Docker завершена, запуск сервиса…"
