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
    systemctl enable --now "$unit"
  else
    sudo systemctl enable --now "$unit"
  fi
}

get_unit_definitions() {
  API_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo API (dev)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && api dev'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
)

  CLIENT_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Client (npm run dev)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && npm run dev'
Restart=always
RestartSec=5
Environment=NODE_ENV=development

[Install]
WantedBy=multi-user.target
UNIT
)

  CELERY_WORKER_UNIT=$(cat <<'UNIT'
[Unit]
Description=Ergo Celery Worker
After=network.target
Requires=ergo-api-dev.service

[Service]
Type=simple
EnvironmentFile=/etc/default/ergo_ms
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && api start_celery_worker'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

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
ExecStart=/bin/bash -lc 'cd "$ERGO_ROOT/core" && . "$ERGO_ROOT/virtual_env/python/bin/activate" && api start_celery_beat'
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
UNIT
)

  export API_UNIT
  export CLIENT_UNIT
  export CELERY_WORKER_UNIT
  export CELERY_BEAT_UNIT
}

export -f write_env_file
export -f install_unit
export -f enable_and_start
export -f get_unit_definitions

