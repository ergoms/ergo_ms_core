# Устройство развёртывания (ergoms)

Этот документ описывает, как устроены скрипты в `core/deployment/` и утилита **ergoms** — единая точка входа для установки, запуска и служебных команд ERGO MS. Его читают разработчики, которые добавляют команды или правят скрипты под Windows и Linux.

Справочник команд для людей — в [`.docs/cli.md`](../../.docs/cli.md). Технический формат `commands.conf` — в [`.cursor/rules/ergoms-commands.mdc`](../../.cursor/rules/ergoms-commands.mdc).

## Предварительные условия

- Репозиторий клонирован; путь к проекту содержит только латиницу, цифры, дефис и подчёркивание.
- На компьютере **установлены** Python 3.12, Node.js 18+, PostgreSQL 14+ и Git — см. [README.md](../../README.md#быстрый-старт).
- Python-окружение проекта живёт в **`virtual_env/python/`** — каталог уже есть в дереве репозитория, его **не пересоздают** при установке.
- В пользовательской документации все команды выполняют через **`ergoms`**, а не через `python manage.py` напрямую.

## Кроссплатформенность

Любая команда ergoms должна работать на **Windows** (PowerShell) и **Linux** (bash). Если поведение зависит от ОС, в `core/deployment/commands.conf` используют префиксы **`win:`** и **`linux:`**; общая логика — в `core/deployment/windows/` и `core/deployment/linux/`.

Абстракции в коде приложения:

| Область | Где |
|---------|-----|
| Python (пути, процессы) | `core/api/src/core/utils/os_abstraction/` |
| Node (процессы) | `core/client/scripts/lib/process-ops.js` |

Подробнее — [`oc.mdc`](../../.cursor/rules/oc.mdc).

## Файл commands.conf

`core/deployment/commands.conf` — реестр команд ядра: строки вида `имя-команды=тип:действие`. Модули добавляют свои команды в `modules/<имя>/ergoms.conf`.

Команды **разнесены по отдельным файлам** — не один монолитный скрипт на всё, а шаги, которые можно переиспользовать и тестировать.

## Каталог wrappers

`core/deployment/wrappers/` — временные и генерируемые скрипты, которые создаются в процессе работы команд. Не храните здесь исходники «навсегда»; содержимое можно пересоздать.

## GeoIP (DB-IP City Lite)

Локальная геолокация IP для сессий пользователя и журнала аудита. Поиск только по файлу на диске — IP **не** отправляется во внешние API.

| Что | Где |
|-----|-----|
| База MMDB | `virtual_env/resources/geoip/dbip-city-lite.mmdb` (не в git) |
| Настройки | `.env`: `GEOIP_ENABLED`, `GEOIP_DOWNLOAD_URL` (см. `.env.example`) |
| Код | `core/api/src/core/utils/geoip.py`, `core/api/src/config/settings/geoip.py` |

### Команды

- `ergoms geoip-download` — скачать или обновить MMDB с db-ip.com (URL из `.env` или авто по месяцу)
- `ergoms geoip-backfill` — заполнить city/country у существующих `UserDevice` (`--dry-run` для проверки без записи)

### Первичная настройка GeoIP

1. Установите Python-зависимости: `ergoms python-install`
2. Скачайте базу: `ergoms geoip-download`
3. При необходимости заполните старые записи: `ergoms geoip-backfill`

### Обновление базы

Раз в месяц выполните `ergoms geoip-download`, затем перезапустите API — reader кэшируется в процессе.

## Redis (optional, portable packages)

Опциональный локальный Redis для общего кэша Django и channel layer (не входит в `setup-full`).

| Что | Где |
|-----|-----|
| Бинарники | `virtual_env/packages/redis/` (Windows: zip redis-windows 7.4.x msys2; Linux: сборка из tarball 7.4.x) |
| Конфиг | `virtual_env/packages/redis/conf/redis.conf` |
| Скрипты | `core/deployment/scripts/install_redis.py`, `resolve_env.py` |
| Windows | `core/deployment/windows/lib/redis.ps1`, служба `ergo_ms_redis` (NSSM) |
| Linux | `core/deployment/linux/lib/redis.sh`, unit `ergo-redis.service` |

### Команды

- `ergoms install-redis [port]` — установка и запуск (как `install-nginx`: бинарники, конфиг, старт процесса)
- `ergoms install-redis-service` — автозапуск (Windows service / systemd)
- `ergoms start-redis` / `stop-redis` / `restart-redis` / `status-redis` / `test-redis`
- `ergoms uninstall-redis` / `uninstall-redis --purge` (Linux) / `-Purge` (Windows)

### Первичная настройка Redis

1. `ergoms install-redis`, затем `REDIS_ENABLED=true` в `.env`
2. Перезапустить API
3. Проверка: `ergoms test-redis` → `PONG`

Переменные: `REDIS_ENABLED`, `REDIS_HOST`, `REDIS_PORT`, `API_CACHE_REDIS_URL`, `CHANNEL_LAYER_REDIS_URL` — см. `.env.example`.

## Типичные ошибки

| Симптом | Что проверить |
|---------|----------------|
| `ergoms` не найден | Первичная настройка: `setup-full` из [README.md](../../README.md) или `install-cli` |
| Команда есть только на одной ОС | Префикс `win:` / `linux:` в `commands.conf` |
| Окружение повреждено после ручного venv | Не создавай `.venv` — только `virtual_env/python/` ([`virtual-env.mdc`](../../.cursor/rules/virtual-env.mdc)) |

## См. также

| Тема | Файл |
|------|------|
| Справочник команд ergoms | [`.docs/cli.md`](../../.docs/cli.md) |
| Только ergoms, не manage.py | [`.cursor/rules/no-direct-manage-py.mdc`](../../.cursor/rules/no-direct-manage-py.mdc) |
| Службы Linux | [`.docs/deployment.md`](../../.docs/deployment.md) |
