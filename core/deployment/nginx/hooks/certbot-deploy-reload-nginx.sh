#!/usr/bin/env bash
# Certbot deploy-hook: reload nginx after certificate renewal.
set -euo pipefail

ERGO_ROOT="${ERGO_ROOT:-__ERGO_ROOT__}"

if [[ -x /usr/local/bin/ergoms ]]; then
  if ergoms reload-nginx --root "$ERGO_ROOT" >/dev/null 2>&1; then
    exit 0
  fi
fi

if [[ -f "$ERGO_ROOT/core/deployment/linux/ergo_ms.sh" ]]; then
  if bash "$ERGO_ROOT/core/deployment/linux/ergo_ms.sh" reload-nginx --root "$ERGO_ROOT" >/dev/null 2>&1; then
    exit 0
  fi
fi

# Last resort: local packages nginx (without ergoms in PATH)
local_nginx="$ERGO_ROOT/virtual_env/packages/nginx/sbin/nginx"
local_conf="$ERGO_ROOT/virtual_env/packages/nginx/conf/nginx.conf"
if [[ -x "$local_nginx" && -f "$local_conf" ]]; then
  (cd "$ERGO_ROOT/virtual_env/packages/nginx" && "$local_nginx" -s reload -c "$local_conf")
  exit 0
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl reload ergo_ms_nginx 2>/dev/null && exit 0
fi
