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

if command -v systemctl >/dev/null 2>&1; then
  systemctl reload nginx
  exit 0
fi

if command -v nginx >/dev/null 2>&1; then
  nginx -s reload
fi
