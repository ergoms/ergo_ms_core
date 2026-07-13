#!/usr/bin/env bash
# Генерация и установка конфигурации nginx для ERGO MS (Linux).
#
# Использование:
#   export ERGO_ROOT=/var/www/ergo_ms
#   export ERGO_SERVER_NAME=app.example.com
#   sudo bash core/deployment/nginx/install.sh
#
# Опционально:
#   ERGO_SSL_CERT, ERGO_SSL_KEY — пути к сертификатам
#   ERGO_NGINX_SITES_AVAILABLE — каталог sites-available (по умолчанию /etc/nginx/sites-available)
#   ERGO_NGINX_DRY_RUN=1 — только показать результат, не писать файлы

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ERGO_ROOT="${ERGO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
ERGO_SERVER_NAME="${ERGO_SERVER_NAME:-localhost}"
ERGO_SSL_CERT="${ERGO_SSL_CERT:-/etc/ssl/certs/ssl-cert-snakeoil.pem}"
ERGO_SSL_KEY="${ERGO_SSL_KEY:-/etc/ssl/private/ssl-cert-snakeoil.key}"
ERGO_NGINX_SNIPPETS="${ERGO_NGINX_SNIPPETS:-$SCRIPT_DIR/snippets}"
ERGO_NGINX_SITES_AVAILABLE="${ERGO_NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}"
ERGO_NGINX_SITES_ENABLED="${ERGO_NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"
SITE_NAME="${ERGO_NGINX_SITE_NAME:-ergo_ms}"
OUTPUT_CONF="${ERGO_NGINX_SITES_AVAILABLE}/${SITE_NAME}.conf"

warn_insecure_certs() {
  if [[ "$ERGO_SSL_CERT" == *snakeoil* || "$ERGO_SSL_KEY" == *snakeoil* ]]; then
    echo "Предупреждение: самоподписанный сертификат. Для production используйте Let's Encrypt." >&2
  fi
  if [[ ! -f "$ERGO_SSL_CERT" ]]; then
    echo "Предупреждение: SSL-сертификат не найден: $ERGO_SSL_CERT" >&2
  fi
  if [[ ! -f "$ERGO_SSL_KEY" ]]; then
    echo "Предупреждение: приватный ключ SSL не найден: $ERGO_SSL_KEY" >&2
  fi
}

export ERGO_ROOT ERGO_SERVER_NAME ERGO_SSL_CERT ERGO_SSL_KEY ERGO_NGINX_SNIPPETS

warn_insecure_certs

render_template() {
  local template="$1"
  local content
  content="$(cat "$template")"
  content="${content//\$\{ERGO_ROOT\}/$ERGO_ROOT}"
  content="${content//\$\{ERGO_SERVER_NAME\}/$ERGO_SERVER_NAME}"
  content="${content//\$\{ERGO_SSL_CERT\}/$ERGO_SSL_CERT}"
  content="${content//\$\{ERGO_SSL_KEY\}/$ERGO_SSL_KEY}"
  content="${content//\$\{ERGO_NGINX_SNIPPETS\}/$ERGO_NGINX_SNIPPETS}"
  printf '%s' "$content"
}

if [[ ! -f "$SCRIPT_DIR/ergo_ms.conf.template" ]]; then
  echo "Шаблон не найден: $SCRIPT_DIR/ergo_ms.conf.template" >&2
  exit 1
fi

if [[ ! -d "$ERGO_ROOT/core/client/dist" ]]; then
  echo "Предупреждение: $ERGO_ROOT/core/client/dist не найден. Выполните: ergoms build-all" >&2
fi

rendered="$(render_template "$SCRIPT_DIR/ergo_ms.conf.template")"

if [[ "${ERGO_NGINX_DRY_RUN:-}" == "1" ]]; then
  printf '%s\n' "$rendered"
  exit 0
fi

if [[ $(id -u) -ne 0 ]]; then
  echo "Нужны права root. Запустите с sudo." >&2
  exit 1
fi

mkdir -p "$ERGO_NGINX_SITES_AVAILABLE" "$ERGO_NGINX_SITES_ENABLED"
printf '%s\n' "$rendered" > "$OUTPUT_CONF"
ln -sf "$OUTPUT_CONF" "$ERGO_NGINX_SITES_ENABLED/${SITE_NAME}.conf"

if nginx -t; then
  systemctl reload nginx
  echo "Установлено: $OUTPUT_CONF"
  echo "Включено:   $ERGO_NGINX_SITES_ENABLED/${SITE_NAME}.conf"
else
  echo "nginx -t завершился с ошибкой. Конфиг записан, но не перезагружен." >&2
  exit 1
fi
