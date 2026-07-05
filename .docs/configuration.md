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

VITE_DEFAULT_THEME=auto
VITE_LOG_LEVEL=debug
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

## Realtime (WebSocket и polling)

Переменная **`REALTIME_TRANSPORT`** в `.env`:

- `websocket` — Django Channels (по умолчанию); API запускается через ASGI.
- `http_polling` — обход прокси без WebSocket; клиент опрашивает REST по интервалам.

Интервалы polling на сервере (секунды): `REALTIME_POLL_PRESENCE_INTERVAL`, `REALTIME_POLL_NOTIFICATIONS_INTERVAL`, `REALTIME_POLL_ADMIN_PRESENCE_INTERVAL`, `REALTIME_POLL_MESSENGER_INTERVAL`. Для сборки клиента те же значения можно задать в миллисекундах через `VITE_REALTIME_*` — см. `.env.example`.

За nginx без WebSocket — пример в `core/deployment/nginx/env.example`. Правила разработки — [`.cursor/rules/realtime.mdc`](../.cursor/rules/realtime.mdc).

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
