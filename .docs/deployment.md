# Разворачивание системных служб (Linux)

Скрипт `core/deployment/linux/ergo_ms.sh` осуществляет регистрацию и управление службами systemd без использования жёстко заданных путей. Конфигурация пути к корневому каталогу системы определяется посредством файла окружения `/etc/default/ergo_ms` (переменная `ERGO_ROOT`).

## Поддерживаемые операции

```bash
sudo bash /var/www/ergo_ms/linux/ergo_ms.sh install --root /var/www/ergo_ms   # Регистрация служб и инициализация
sudo bash /var/www/ergo_ms/linux/ergo_ms.sh start                             # Запуск всех служб
sudo bash /var/www/ergo_ms/linux/ergo_ms.sh stop                              # Остановка всех служб
sudo bash /var/www/ergo_ms/linux/ergo_ms.sh restart                           # Перезапуск всех служб
sudo bash /var/www/ergo_ms/linux/ergo_ms.sh status                            # Получение статуса всех служб
sudo bash /var/www/ergo_ms/linux/ergo_ms.sh uninstall [--purge]               # Удаление служб (опция --purge удаляет /etc/default/ergo_ms)
```

## CLI-обёртка `ergoms`

```bash
# Установка CLI-обёртки
sudo bash /var/www/ergo_ms/linux/ergo_ms.sh install-cli

# Использование CLI
sudo ergoms install --root /var/www/ergo_ms
sudo ergoms start | stop | restart | status
sudo ergoms uninstall [--purge]

# Удаление CLI-обёртки
sudo ergoms uninstall-cli
```

## Идентификаторы служб systemd

- `ergo-api-dev.service` — серверное приложение Django в режиме разработки
- `ergo-client-dev.service` — клиентское приложение Vue.js в режиме разработки
- `ergo-celery-worker.service` — обработчик асинхронных задач Celery
- `ergo-celery-beat.service` — планировщик периодических задач Celery

## Инспекция журналов systemd

```bash
journalctl -u ergo-api-dev -n 500 -f
journalctl -u ergo-client-dev -n 500 -f
journalctl -u ergo-celery-worker -n 500 -f
journalctl -u ergo-celery-beat -n 500 -f
```

