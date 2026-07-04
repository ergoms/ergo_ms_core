#!/usr/bin/env bash
# Systemd management for Linux services
# Управление systemd для служб Linux

write_env_file() {
  local root="$1"
  local env_file="/etc/default/ergo_ms"
  local tmp_file
  tmp_file="$(mktemp)"

  cat >"$tmp_file" <<EOF
# Environment for ergo_ms services
ERGO_ROOT="$root"
PYTHONUNBUFFERED=1
NODE_ENV=development
EOF

  if [[ $(id -u) -eq 0 ]]; then
    install -m 0644 "$tmp_file" "$env_file"
  else
    sudo install -m 0644 "$tmp_file" "$env_file"
  fi
  rm -f "$tmp_file"
  echo "Written $env_file with ERGO_ROOT=$root"
}

install_unit() {
  local name="$1"
  local content="$2"
  local unit_path="/etc/systemd/system/${name}.service"
  local tmp_file
  tmp_file="$(mktemp)"
  printf "%s" "$content" > "$tmp_file"
  if [[ $(id -u) -eq 0 ]]; then
    install -m 0644 "$tmp_file" "$unit_path"
  else
    sudo install -m 0644 "$tmp_file" "$unit_path"
  fi
  rm -f "$tmp_file"
  echo "Installed $unit_path"
}

enable_and_start() {
  local unit="$1"
  if [[ $(id -u) -eq 0 ]]; then
    systemctl reset-failed "$unit" 2>/dev/null || true
    systemctl enable --now "$unit"
  else
    sudo systemctl reset-failed "$unit" 2>/dev/null || true
    sudo systemctl enable --now "$unit"
  fi
}

# Получение базовых unit definitions (API, Client, Beat)
get_base_unit_definitions() {
  API_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo API (mode from API_DEPLOY_TYPE)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python core/api/scripts/start_api.py'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
)

  CLIENT_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Client (Vite dev or nginx skip)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python core/deployment/scripts/start_client_if_dev.py'
Restart=always
RestartSec=5
Environment=NODE_ENV=development

[Install]
WantedBy=multi-user.target
UNIT
)

  CELERY_BEAT_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Celery Beat
After=network.target
Requires=ergo-api-dev.service

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python api/scripts/start_celery_beat.py'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
)

  MEDIA_API_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Media API (CDN / file server)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
Environment=PYTHONUNBUFFERED=1
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python core/api/scripts/start_media_api.py'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
)

  export API_UNIT
  export CLIENT_UNIT
  export CELERY_BEAT_UNIT
  export MEDIA_API_UNIT
}

# Генерация unit для конкретного Celery worker'а
generate_worker_unit() {
  local worker_name="$1"
  
  cat <<UNIT
[Unit]
Description=Ergo Celery Worker ($worker_name)
After=network.target
Requires=ergo-api-dev.service

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "\$ERGO_ROOT/core" && . "\$ERGO_ROOT/virtual_env/python/bin/activate" && python api/scripts/start_celery_worker.py --worker=$worker_name'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
}

# Генерация unit для единственного worker'а (без конфига)
generate_default_worker_unit() {
  cat <<'UNIT'
[Unit]
Description=Ergo Celery Worker
After=network.target
Requires=ergo-api-dev.service

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python api/scripts/start_celery_worker.py'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
}

# Устаревшая функция для обратной совместимости
# Используется только если вызывается напрямую
get_unit_definitions() {
  get_base_unit_definitions
  
  # Для обратной совместимости генерируем default worker unit
  CELERY_WORKER_UNIT="$(generate_default_worker_unit)"
  export CELERY_WORKER_UNIT
}

# Установка всех воркеров из конфигурации
install_worker_units() {
  local root="$1"
  local workers
  workers="$(get_celery_workers "$root")"
  
  if [[ -n "$workers" ]]; then
    echo "Найдены воркеры в celery_workers.yaml: $workers"
    for worker in $workers; do
      local unit_content
      unit_content="$(generate_worker_unit "$worker")"
      install_unit "ergo-celery-worker-${worker}" "$unit_content"
    done
  else
    echo "Конфиг celery_workers.yaml не найден, устанавливаем один общий воркер"
    local unit_content
    unit_content="$(generate_default_worker_unit)"
    install_unit "ergo-celery-worker" "$unit_content"
  fi
}

# Включение и запуск всех воркеров
enable_and_start_workers() {
  local root="$1"
  local workers
  workers="$(get_celery_workers "$root")"
  
  if [[ -n "$workers" ]]; then
    for worker in $workers; do
      enable_and_start "ergo-celery-worker-${worker}.service"
    done
  else
    enable_and_start "ergo-celery-worker.service"
  fi
}

export -f write_env_file
export -f install_unit
export -f enable_and_start
export -f get_base_unit_definitions
export -f generate_worker_unit
export -f generate_default_worker_unit
export -f get_unit_definitions
export -f install_worker_units
export -f enable_and_start_workers
