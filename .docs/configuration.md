# Настройка конфигурации

Перед первым запуском в корне проекта нужны **`.env`** и **`databases.yaml`**. При полной первичной настройке (`setup-full`) они создаются из примеров автоматически; после этого их нужно проверить и при необходимости настроить под свою среду.

## Файл `.env`

Если файла ещё нет, скопируйте `.env.example` в `.env`. В примере перечислены все переменные с комментариями; для локальной разработки обычно хватает минимального набора (остальное можно оставить как в `.env.example`):

```env
API_HOST=localhost
API_PORT=8000
API_ALLOWED_HOSTS=localhost,127.0.0.1
API_DEPLOY_TYPE=development
API_SECRET_KEY=замени-на-длинную-случайную-строку

API_JWT_LIFETIME_ENABLED=true
API_ACCESS_TOKEN_LIFETIME=30
API_REFRESH_TOKEN_LIFETIME=60

CLIENT_HOST=localhost
CLIENT_PORT=8001

EMAIL_ENABLED=false

CLIENT_DEFAULT_THEME=auto
CLIENT_LOG_LEVEL=debug
```

Почту для разработки можно не настраивать: при `EMAIL_ENABLED=false` письма не отправляются. Для staging или сервера включите `EMAIL_ENABLED=true` и задайте `EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`, `EMAIL_HOST_PASSWORD`, `EMAIL_USE_SSL` / `EMAIL_USE_TLS` — см. `.env.example`.

Полный перечень переменных и их смысл — в `.env.example`.

При развёртывании на сервере обязательно смените `API_SECRET_KEY` на криптостойкий ключ, выставьте `API_DEPLOY_TYPE=production` и укажите реальные домены в `API_ALLOWED_HOSTS`.

## Файл `databases.yaml`

Если файла ещё нет, скопируйте `databases.yaml.example` в `databases.yaml`. Для начала работы нужна хотя бы секция **`default`** — основная база приложения:

```yaml
databases:
  default:
    engine: "postgresql"
    name: "ergo_ms"
    user: "postgres"
    password: "admin"
    host: "localhost"
    port: 5432
```

Убедитесь, что база `ergo_ms` создана в PostgreSQL и пользователь имеет к ней доступ. После правок конфигурации примените миграции: `ergoms db-migrate`.

### Базы для Celery

Фоновые задачи могут использовать ту же PostgreSQL или отдельные секции в том же файле:

- **`celery`** — общая очередь; удобный вариант для разработки, когда worker и beat делят одну базу.
- **`celery_worker`** и **`celery_beat`** — раздельные настройки, если на сервере нужна изоляция очередей.

Важно: **worker и beat должны подключаться к одному брокеру**. Иначе планировщик будет ставить задачи в одну очередь, а исполнитель слушать другую. Если секции Celery не заданы, система создаст локальный SQLite в `virtual_env/celery/` — этого достаточно для экспериментов, но не для нагрузки.

При локальной разработке можно указать одного пользователя `postgres` во всех секциях — так проще, чем заводить отдельных пользователей БД.

### Замечание про YAML

Если в пароле или других строках встречаются символы `!`, `#`, `{`, `}` — заключите значение в двойные кавычки, например: `password: "!admin123"`. Иначе парсер YAML может прочитать строку неверно.

## Меню приложения

Пункты бокового меню хранятся в БД. Модуль с клиентом регистрирует их в **миграции данных API** (`MenuMigrationHelper`, `module_source='modules/<имя>'`), затем выполняет `ergoms migrate-all`. Маршруты страниц — в `client/js/routes.js`; каждый пункт меню ссылается на `routeName` из этого файла.

Порядок пунктов и видимость для пользователей настраиваются в админ-панели CMS (`MenuPanel.vue`) и тоже сохраняются в БД. Подробнее — [architecture.md](architecture.md#боковое-меню) и [`.cursor/rules/menu.mdc`](../.cursor/rules/menu.mdc).

## Регистрация пользователей

Режим задаётся переменной **`API_REGISTRATION_MODE`** в `.env`:

| Значение | Поведение |
|----------|-----------|
| `open` | свободная регистрация (по умолчанию) |
| `invitation` | только по приглашению глобального администратора |
| `closed` | регистрация отключена |

Для режима `invitation` также задайте **`API_REGISTRATION_INVITATION_TTL_DAYS`** (срок действия ссылки). Управление приглашениями — в CMS, раздел «Приглашения». Проверка уникальности email — **`API_REGISTRATION_CHECK_EMAIL_EXISTS`**.

Самостоятельное изменение email, ФИО и телефона в профиле — **`API_USER_PROFILE_SELF_EDIT_ENABLED`**. Если выключено, пользователи отправляют заявки администратору.

## Настройки клиента

Все параметры клиента — в `.env` с префиксом **`CLIENT_*`** или через общие переменные **`API_*`**, **`DISABLED_MODULES`**, **`REALTIME_*`**. Сборка (`core/client/vite.config.js`) подставляет их в бандл; в коде используйте **`@/js/clientEnv.js`**, не `import.meta.env` напрямую.

| Переменная в `.env` | Назначение |
|---------------------|------------|
| `CLIENT_DEFAULT_THEME` | Тема по умолчанию: `auto`, `light`, `dark` |
| `CLIENT_LOG_LEVEL` | Уровень логов клиента |
| `CLIENT_USE_RELATIVE_API` | API и WebSocket с того же origin, что SPA (nginx) |
| `API_HOST`, `API_PORT` | Адрес API в dev без nginx |
| `API_PASSWORD_*` | Политика паролей (сервер и подсказки в формах) |
| `DISABLED_MODULES` | Отключённые модули (сервер и клиент) |

Новая настройка модуля для клиента: `CLIENT_<МОДУЛЬ>_*` в `modules/<имя>/.env` (или в корневом `.env`) + поле в `clientEnv.js` и `buildClientEnvDefines()` в `vite.config.js`.

## Настройки модулей

У части модулей есть собственные `.env.example` в каталоге `modules/<имя>/`. При `setup-full` из них создаётся `modules/<имя>/.env`. Переменные из модульных `.env` **переопределяют** одноимённые из корневого `.env` — и на сервере (Django), и при сборке клиента (Vite).

Проверка соответствия example и рабочего файла: `ergoms env`.

| Модуль | Файл | Примеры переменных |
|--------|------|-------------------|
| `tasks` | `modules/tasks/.env.example` | `TASKS_MAX_ATTACHMENT_SIZE_MB`, `CLIENT_TASKS_MAX_ATTACHMENT_SIZE_MB` |
| `bi_analysis` | `modules/bi_analysis/.env.example` | `BI_PREVIEW_ASYNC_THRESHOLD`, `FERNET_KEY`, `CLIENT_BI_PREVIEW_ITEMS_PER_PAGE` |
| `organizations` | `modules/organizations/.env.example` | `ORGANIZATIONS_USE_MEMBER_INVITATIONS` |
| `video_analysis` | `modules/video_analysis/.env.example` | `VIDEO_ANALYSIS_USE_GPU` |

Если модуль указан в `DISABLED_MODULES`, его `.env` не учитывается при сборке клиента.

## Realtime (WebSocket, SSE и polling)

Переменные **`REALTIME_*`** в `.env` — **единые для сервера и клиента**. После входа клиент синхронизируется с `GET /api/realtime/config/`.

- `websocket` — Django Channels (по умолчанию); API через ASGI.
- `sse` — push через **Server-Sent Events** (`GET /api/realtime/stream/`).
- `http_polling` — клиент опрашивает REST по интервалам (`GET /api/realtime/sync/`).

**Channel layer** (для push между worker’ами): `CHANNEL_LAYER_BACKEND=memory` (dev, один процесс), `postgres` (без Redis, через основную БД) или `redis`. См. `.env.example`.

Интервалы polling (секунды): `REALTIME_POLL_*`. SSE keepalive: `REALTIME_SSE_KEEPALIVE_INTERVAL`.

Nginx: отдельный location для `/api/realtime/stream/` — `core/deployment/nginx/ergo_ms.conf.template`. Правила разработки — [`.cursor/rules/realtime.mdc`](../.cursor/rules/realtime.mdc).

## Кэш Django

Переменная **`API_CACHE_BACKEND`** в `.env`:

| Значение | Когда |
|----------|-------|
| `locmem` | разработка, один процесс API (по умолчанию) |
| `file` | без Redis на Linux (не рекомендуется на Windows) |
| `redis` | несколько процессов, общий кэш |

При `REDIS_ENABLED=true` без явного `API_CACHE_BACKEND` effective-backend — `redis` (см. [`redis_runtime.py`](../core/api/src/config/redis_runtime.py)).

## Celery broker

Помимо секций в `databases.yaml` (SQLite/PostgreSQL) в `.env` задаётся **`CELERY_BROKER_BACKEND`**:

| Значение | Поведение |
|----------|-----------|
| `auto` | из `databases.yaml` или локальный SQLite |
| `redis` | брокер на Redis (`CELERY_BROKER_URL` или `REDIS_DB_CELERY_BROKER`) |
| `database` | явно через БД |
| `local` | локальный SQLite в `virtual_env/celery/` |

Расписание Beat (django-celery-beat) хранится в PostgreSQL, не в Redis.

## Redis и несколько процессов {#redis-и-несколько-процессов}

Portable Redis **не входит** в `setup-full`. Установка:

```cmd
ergoms install-redis
ergoms test-redis
```

В `.env` вручную: **`REDIS_ENABLED=true`**, перезапустите API.

При `REDIS_ENABLED=true` модуль [`redis_runtime.py`](../core/api/src/config/redis_runtime.py) по умолчанию включает `redis` для channel layer, кэша и Celery broker — если не заданы явно `CHANNEL_LAYER_BACKEND`, `API_CACHE_BACKEND`, `CELERY_BROKER_BACKEND`.

Типичный набор для production (см. блок «Несколько процессов» в `.env.example`):

```env
REDIS_ENABLED=true
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
API_CACHE_BACKEND=redis
CHANNEL_LAYER_BACKEND=redis
CELERY_BROKER_BACKEND=redis
```

Разделение баз Redis по умолчанию: DB 0 — channel layer, 1 — кэш, 2 — Celery broker, 3 — result backend (`REDIS_DB_*`).

Альтернатива Redis для channel layer — **`CHANNEL_LAYER_BACKEND=postgres`** (через основную БД).

Подробнее — [`core/deployment/logic.md`](../core/deployment/logic.md#redis-optional-portable-packages), [cli.md](cli.md#redis-опционально).

## Production за nginx

Эталон переменных для запуска за обратным прокси — [`core/deployment/nginx/env.example`](../core/deployment/nginx/env.example). Скопируйте нужные значения в корневой `.env`.

Ключевые переменные:

| Переменная | Назначение |
|------------|------------|
| `NGINX_ENABLED` | включить сценарий nginx |
| `NGINX_SERVER_NAME`, `NGINX_PUBLIC_HOST` | домен |
| `CLIENT_USE_RELATIVE_API` | API и WebSocket с того же origin, что SPA |
| `API_DEPLOY_TYPE`, `CLIENT_DEPLOY_TYPE` | `production` |
| `ERGO_TLS_*`, `ERGO_SSL_CERT`, `ERGO_SSL_KEY` | TLS (Linux, `ergoms install-tls`) |

Команды: `ergoms install-nginx`, `ergoms reload-nginx`, `ergoms test-nginx` — см. [cli.md](cli.md#nginx-опционально).

## Docker Compose

Переменные **`DOCKER_*`** — секция в `.env.example`. Порты публикуются из `API_PORT`, `CLIENT_PORT`, `MEDIA_API_BIND_PORT` и др.; параметры БД — из `databases.yaml` (при `DOCKER_DATABASE=container` хост `localhost` подменяется на сервис `postgres` внутри compose).

В `.env` задайте `DOCKER_ENABLED=true`, режим `DOCKER_MODE` (`dev` / `prod`) и profiles (`DOCKER_PROFILE_POSTGRES`, `DOCKER_PROFILE_NGINX`, `DOCKER_PROFILE_JUPYTER`). Первый запуск: `ergoms docker-init`.

Скрипты не изменяют корневой `.env` — генерируют только артефакты в `core/deployment/docker/`. Подробнее — [docker.md](docker.md).

## GeoIP (геолокация IP)

Локальная база DB-IP City Lite для city/country в сессиях и аудите. В `.env`:

- **`GEOIP_ENABLED=true`** — включить lookup при входе и в аудите
- **`GEOIP_DOWNLOAD_URL`** — URL архива MMDB (см. `.env.example`)

Скачать базу: `ergoms geoip-download`. Заполнить старые записи: `ergoms geoip-backfill`. Подробнее — [`core/deployment/logic.md`](../core/deployment/logic.md#geoip-db-ip-city-lite).

## Совместная работа через Live Share

Если нужно показать проект коллеге в реальном времени, подойдёт расширение [Live Share](https://marketplace.visualstudio.com/items?itemName=MS-vsliveshare.vsliveshare) для VS Code или Cursor. У участников сеанса должны быть доступны порты API и клиента из вашего `.env` — обычно это 8000 и 8001.

## См. также

| Вопрос | Документ |
|--------|----------|
| Справочник команд ergoms | [cli.md](cli.md) |
| Если конфигурация не применяется | [troubleshooting.md](troubleshooting.md) |
| Запуск для разработки | [development.md](development.md) |
| Docker Compose | [docker.md](docker.md) |
