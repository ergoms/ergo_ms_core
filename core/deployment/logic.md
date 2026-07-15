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

Часть команд **не** в `commands.conf`, а встроена в `ergo_ms.ps1` / `ergo_ms.sh`: **nginx**, **redis**, **TLS**, установка служб (`install`, `start`, `stop`). Описания — в `help.manifest.yaml`; правила — [`.cursor/rules/deployment-infra.mdc`](../../.cursor/rules/deployment-infra.mdc).

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

Переменные: `REDIS_ENABLED`, `REDIS_HOST`, `REDIS_PORT`, `API_CACHE_REDIS_URL`, `CHANNEL_LAYER_REDIS_URL` — см. `.env.example`. Effective-логика — [`redis_runtime.py`](../../core/api/src/config/redis_runtime.py).

## Nginx (optional, portable packages)

Обратный прокси для запуска как на сервере: один origin для клиента, API, WebSocket и media_api. **Не входит** в `setup-full`.

| Что | Где |
|-----|-----|
| Бинарники | `virtual_env/packages/nginx/` |
| Шаблон конфига | `core/deployment/nginx/ergo_ms.conf.template` |
| Рендер конфига | `core/deployment/scripts/render_nginx_config.py`, `resolve_env.py` |
| Effective-переменные | `nginx_runtime.py`, `env_resolvers.py` |
| Windows | `core/deployment/windows/lib/nginx.ps1`, служба `ergo_ms_nginx` (NSSM) |
| Linux | `core/deployment/linux/lib/nginx.sh`, unit `ergo_ms_nginx.service` |
| Эталон `.env` | `core/deployment/nginx/env.example` |

### Команды

- `ergoms install-nginx` — установка бинарников, рендер конфига, запуск
- `ergoms install-nginx-service` — автозапуск (Windows / systemd)
- `ergoms reload-nginx` — проверка конфига и перезагрузка
- `ergoms start-nginx` / `stop-nginx` / `restart-nginx` / `status-nginx` / `test-nginx`
- `ergoms uninstall-nginx` / `uninstall-nginx --purge` (Linux) / `-Purge` (Windows)

Команды реализованы в `ergo_ms.ps1` / `ergo_ms.sh`, не в `commands.conf`.

### Первичная настройка nginx

1. Скопируйте нужные переменные из `core/deployment/nginx/env.example` в корневой `.env` (`NGINX_ENABLED=true`, `CLIENT_USE_RELATIVE_API=true`, …).
2. `ergoms install-nginx` (на Linux — с `sudo`, если нужны права на unit).
3. Проверка: `ergoms test-nginx`, `ergoms status-nginx`.
4. После смены клиента: `ergoms client-build && ergoms reload-nginx`.

Переменные: `NGINX_*`, `CLIENT_USE_RELATIVE_API` — см. `.env.example` и `env.example` nginx.

## TLS (Let's Encrypt, Linux)

Выпуск и обновление сертификатов для nginx. **Только Linux** (certbot, root/sudo).

| Что | Где |
|-----|-----|
| Скрипты | `core/deployment/linux/lib/tls.sh`, `core/deployment/scripts/tls_cli.py` |
| Конфиг доменов | `core/deployment/nginx/tls_config.py`, `tls_runtime.py` |
| Hook после renew | `core/deployment/nginx/hooks/certbot-deploy-reload-nginx.sh` |

### Команды

- `sudo ergoms install-tls` — certbot, выпуск сертификата, HTTPS в nginx
- `sudo ergoms renew-tls` — обновление (`certbot renew`)
- `ergoms status-tls` — срок действия и пути (без root)

### Первичная настройка TLS

1. nginx установлен и `NGINX_ENABLED=true`.
2. В `.env`: `ERGO_TLS_EMAIL`, домены (`NGINX_SERVER_NAME` или `ERGO_TLS_DOMAINS`).
3. `sudo ergoms install-tls`.
4. Сверьте `ergoms status-tls` с путями `ERGO_SSL_CERT` / `ERGO_SSL_KEY` в `.env`.

Переменные: `ERGO_TLS_*`, `ERGO_SSL_CERT`, `ERGO_SSL_KEY`, `CORS_ALLOWED_ORIGINS` — см. `core/deployment/nginx/env.example`.

## Docker Compose

Запуск стека в контейнерах — альтернатива portable Redis/nginx на хосте и отдельным процессам `ergoms dev`. Команды — префикс **`ergoms docker-*`** в `commands.conf`; CLI — [`docker_cli.py`](docker/docker_cli.py).

| Что | Где |
|-----|-----|
| Compose-файлы | `core/deployment/docker/docker-compose*.yml` |
| Образы | `Dockerfile.python`, `Dockerfile.client` |
| Effective env (read-only) | [`docker_runtime.py`](docker/docker_runtime.py) |
| Entrypoint | `entrypoint/docker_entrypoint.sh`, `wait_for_services.py` |
| Worker-сервисы | `generate_workers_compose.py` → `docker-compose.workers.generated.yml` |
| nginx в Docker | `nginx/ergo_ms.docker.conf.template` → `ergo_ms.conf.rendered` |

### Команды

- `ergoms docker-init` — build, gen-workers, up, install, migrate
- `ergoms docker-clean --yes` — down с томами, локальные образы, артефакты compose
- `ergoms docker-up` / `docker-down` / `docker-restart`
- `ergoms docker-dev` / `docker-prod` — режим из `--mode` или `DOCKER_MODE` в `.env`
- `ergoms docker-build`, `docker-ps`, `docker-logs`, `docker-migrate`, `docker-shell-api`, `docker-gen-workers`

Описания для `ergoms help` — раздел `docker` в [`help.manifest.yaml`](help.manifest.yaml).

### Первичная настройка Docker

1. Docker Desktop / Docker Engine + Compose V2
2. В `.env`: `DOCKER_ENABLED=true`, `DOCKER_MODE`, profiles (`DOCKER_PROFILE_*`)
3. `databases.yaml` — при `DOCKER_DATABASE=container` хост `localhost` подменяется на сервис `postgres`
4. `ergoms docker-init`

Переменные: секция **Docker** в `.env.example`. Порты — `API_PORT`, `CLIENT_PORT` и др. (не отдельные `DOCKER_*_PORT`).

### Генерируемые артефакты (не в git)

- `.compose.env`, `.compose.databases.yaml`
- `docker-compose.workers.generated.yml`
- `init/postgres/02-celery-databases.sql`
- `nginx/ergo_ms.conf.rendered`

Скрипты **не пишут** в корневой `.env` / `databases.yaml` — только артефакты в `core/deployment/docker/`. Подробнее — [`.docs/docker.md`](../../.docs/docker.md), [`.cursor/rules/docker.mdc`](../../.cursor/rules/docker.mdc).

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
| Службы Linux / Windows | [`.docs/deployment.md`](../../.docs/deployment.md) |
| Redis, nginx, TLS (правила агента) | [`.cursor/rules/deployment-infra.mdc`](../../.cursor/rules/deployment-infra.mdc) |
| Docker Compose (правила агента) | [`.cursor/rules/docker.mdc`](../../.cursor/rules/docker.mdc) |
| Docker (документация) | [`.docs/docker.md`](../../.docs/docker.md) |
