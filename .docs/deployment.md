# Разворачивание системных служб (Linux)

Скрипт `core/deployment/linux/ergo_ms.sh` осуществляет регистрацию и управление службами systemd. Путь к корню проекта задаётся в `/etc/default/ergo_ms` (переменная `ERGO_ROOT`) или через параметр `--root`.

## Поддерживаемые операции

```bash
# Выполнять из корня проекта или указать --root
sudo bash core/deployment/linux/ergo_ms.sh install [--root /var/www/ergo_ms]
sudo bash core/deployment/linux/ergo_ms.sh start
sudo bash core/deployment/linux/ergo_ms.sh stop
sudo bash core/deployment/linux/ergo_ms.sh restart
sudo bash core/deployment/linux/ergo_ms.sh status
sudo bash core/deployment/linux/ergo_ms.sh uninstall-services [--purge]
```

## CLI-обёртка `ergoms`

```bash
# Установка CLI-обёртки (путь — относительно корня проекта)
sudo bash core/deployment/linux/ergo_ms.sh install-cli

# Использование CLI
sudo ergoms install --root /var/www/ergo_ms
sudo ergoms start | stop | restart | status
sudo ergoms uninstall-services [--purge]

# Удаление CLI-обёртки
sudo ergoms uninstall-cli
```

## Идентификаторы служб systemd

- `ergo-api-dev.service` — Django API
- `ergo-client-dev.service` — Vue.js клиент
- `ergo-celery-worker-all.service` — Celery Worker (по умолчанию один воркер «all»)
- `ergo-celery-beat.service` — Celery Beat
- `ergo-media-api.service` — Media API (CDN)

## Инспекция журналов systemd

```bash
journalctl -u ergo-api-dev -n 500 -f
journalctl -u ergo-client-dev -n 500 -f
journalctl -u ergo-celery-worker-all -n 500 -f
journalctl -u ergo-celery-beat -n 500 -f
journalctl -u ergo-media-api -n 500 -f
```

Для просмотра логов через ergoms: `ergoms logs <service-name>`.

