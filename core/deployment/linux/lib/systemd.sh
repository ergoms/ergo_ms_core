#!/usr/bin/env bash
# Systemd management for Linux services
# Управление systemd для служб Linux

write_env_file() {
  local root="$1"
  local env_file="$root/core/deployment/wrappers/ergo_ms.env"
  local legacy="/etc/default/ergo_ms"

  mkdir -p "$(dirname "$env_file")"
  cat >"$env_file" <<EOF
# Environment for ergo_ms services (внутри корня проекта)
ERGO_ROOT="$root"
PYTHONUNBUFFERED=1
NODE_ENV=development
ERGO_LOG_CONSOLE=false
EOF
  chmod 0644 "$env_file" 2>/dev/null || true
  echo "Записан $env_file с ERGO_ROOT=$root"

  if [[ -f "$legacy" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      rm -f "$legacy"
    else
      sudo rm -f "$legacy" 2>/dev/null || true
    fi
    echo "[OK] Удалён устаревший $legacy"
  fi
}

install_unit() {
  local name="$1"
  local content="$2"
  local root="$3"
  local units_dir="$root/core/deployment/wrappers/systemd"
  local unit_path="$units_dir/${name}.service"
  local legacy_path="/etc/systemd/system/${name}.service"
  local env_file="$root/core/deployment/wrappers/ergo_ms.env"

  # Шаблоны используют __ERGO_MS_ENV__; старый /etc/default — на случай ручных unit.
  content="${content//EnvironmentFile=-__ERGO_MS_ENV__/EnvironmentFile=-$env_file}"
  content="${content//EnvironmentFile=__ERGO_MS_ENV__/EnvironmentFile=$env_file}"
  content="${content//EnvironmentFile=-\/etc\/default\/ergo_ms/EnvironmentFile=-$env_file}"
  content="${content//EnvironmentFile=\/etc\/default\/ergo_ms/EnvironmentFile=$env_file}"

  mkdir -p "$units_dir"
  printf "%s" "$content" > "$unit_path"
  chmod 0644 "$unit_path" 2>/dev/null || true

  if [[ -f "$legacy_path" && ! -L "$legacy_path" ]]; then
    if [[ $(id -u) -eq 0 ]]; then
      rm -f "$legacy_path"
    else
      sudo rm -f "$legacy_path"
    fi
  fi

  if [[ $(id -u) -eq 0 ]]; then
    systemctl link "$unit_path" >/dev/null
    systemctl daemon-reload
  else
    sudo systemctl link "$unit_path" >/dev/null
    sudo systemctl daemon-reload
  fi
  echo "Установлен $unit_path (systemctl link)"
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
  local root="${1:-}"
  local client_log client_stdout client_stderr
  local _log_env_py="$root/virtual_env/python/bin/python"
  local _log_env_script="$root/core/deployment/scripts/log_env.py"

  if [[ -x "$_log_env_py" && -f "$_log_env_script" && -n "$root" ]]; then
    client_log="$("$_log_env_py" "$_log_env_script" path CLIENT_DEV "$root" 2>/dev/null || true)"
  fi
  [[ -z "$client_log" ]] && client_log='${ERGO_ROOT}/logs/client-dev.log'
  if [[ -x "$_log_env_py" && -f "$_log_env_script" && -n "$root" ]] \
    && [[ "$("$_log_env_py" "$_log_env_script" client-dev-enabled "$root" 2>/dev/null || true)" == "false" ]]; then
    client_stdout=null
    client_stderr=null
  else
    client_stdout="append:${client_log}"
    client_stderr="append:${client_log}"
  fi

  API_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo API (mode from API_DEPLOY_TYPE)
After=network.target ergo_ms_redis.service
Wants=ergo_ms_redis.service

[Service]
Type=simple
EnvironmentFile=__ERGO_MS_ENV__
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python core/api/scripts/start_api.py'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=ERGO_LOG_CONSOLE=false
StandardOutput=null
StandardError=append:${ERGO_ROOT}/logs/ergo_ms_api_dev.stderr.log

[Install]
WantedBy=multi-user.target
UNIT
)

  CLIENT_UNIT=$(cat <<UNIT
[Unit]
Description=Ergo Client (Vite dev or nginx skip)
After=network.target

[Service]
Type=simple
EnvironmentFile=__ERGO_MS_ENV__
ExecStart=/bin/bash -lc 'cd "\$ERGO_ROOT" && . "\$ERGO_ROOT/virtual_env/python/bin/activate" && python core/deployment/scripts/start_client_if_dev.py'
Restart=always
RestartSec=5
Environment=NODE_ENV=development
StandardOutput=${client_stdout}
StandardError=${client_stderr}

[Install]
WantedBy=multi-user.target
UNIT
)

  CELERY_BEAT_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Celery Beat
After=network.target
Requires=ergo_ms_api_dev.service

[Service]
Type=simple
EnvironmentFile=__ERGO_MS_ENV__
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python api/scripts/start_celery_beat.py'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=ERGO_LOG_CONSOLE=false
StandardOutput=null
StandardError=append:${ERGO_ROOT}/logs/ergo_ms_celery_beat.stderr.log

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
EnvironmentFile=__ERGO_MS_ENV__
Environment=PYTHONUNBUFFERED=1
Environment=ERGO_LOG_CONSOLE=false
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python core/api/scripts/start_media_api.py'
Restart=always
RestartSec=5
StandardOutput=null
StandardError=append:${ERGO_ROOT}/logs/ergo_ms_media_api.stderr.log

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
Requires=ergo_ms_api_dev.service

[Service]
Type=simple
EnvironmentFile=__ERGO_MS_ENV__
ExecStart=/bin/bash -lc 'cd "\$ERGO_ROOT/core" && . "\$ERGO_ROOT/virtual_env/python/bin/activate" && python api/scripts/start_celery_worker.py --worker=$worker_name'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=ERGO_LOG_CONSOLE=false
StandardOutput=null
StandardError=append:\${ERGO_ROOT}/logs/ergo_ms_celery_worker_${worker_name}.stderr.log

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
Requires=ergo_ms_api_dev.service

[Service]
Type=simple
EnvironmentFile=__ERGO_MS_ENV__
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && python api/scripts/start_celery_worker.py'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1
Environment=ERGO_LOG_CONSOLE=false
StandardOutput=null
StandardError=append:${ERGO_ROOT}/logs/ergo_ms_celery_worker.stderr.log

[Install]
WantedBy=multi-user.target
UNIT
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
      install_unit "ergo_ms_celery_worker_${worker}" "$unit_content" "$root"
    done
  else
    echo "Конфиг celery_workers.yaml не найден, устанавливаем один общий воркер"
    local unit_content
    unit_content="$(generate_default_worker_unit)"
    install_unit "ergo_ms_celery_worker" "$unit_content" "$root"
  fi
}

# Включение и запуск всех воркеров
enable_and_start_workers() {
  local root="$1"
  local workers
  workers="$(get_celery_workers "$root")"
  
  if [[ -n "$workers" ]]; then
    for worker in $workers; do
      enable_and_start "ergo_ms_celery_worker_${worker}.service"
    done
  else
    enable_and_start "ergo_ms_celery_worker.service"
  fi
}

export -f write_env_file
export -f install_unit
export -f enable_and_start
export -f get_base_unit_definitions
export -f generate_worker_unit
export -f generate_default_worker_unit
export -f install_worker_units
export -f enable_and_start_workers
