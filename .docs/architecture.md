# Архитектура ERGO MS

ERGO MS — это модульный фреймворк для веб-приложений. В его основе лежит простое разделение: **ядро** отвечает за общую инфраструктуру, а **модули** добавляют предметную логику — LMS, CRM, аналитику и всё остальное, что подключается отдельными репозиториями.

Серверная часть построена на Django и Django REST Framework, клиент — на Vue 3 и Vite. Фоновые задачи выполняет Celery, файлы раздаёт отдельный сервис media_api. Все эти части живут в одном дереве проекта, но связаны чёткими границами: ядро не знает о конкретных модулях, модули не обращаются друг к другу напрямую.

## Ядро и модули

Ядро расположено в каталоге `core/`. Сейчас это четыре части:

| Каталог | Назначение |
|---------|------------|
| `core/api/` | Django API: CMS, права, уведомления, аудит действий, интеграции |
| `core/client/` | Vue-клиент |
| `core/media_api/` | раздача и загрузка файлов |
| `core/deployment/` | ergoms, скрипты установки и запуска |

Модули лежат в `modules/<имя>/`. Каждый модуль — это отдельный git-submodule со своим репозиторием. У модуля может быть серверная часть (`api/`), клиентская (`client/`), или обе сразу. Типичный модуль с клиентом описывает маршруты в `client/js/routes.js`, пункты sidebar — в миграции API; Django-приложение регистрирует в `api/apps.py`.

Связь «модуль — модуль» идёт только через **мост** (ModuleBridge): на сервере это `core/api/src/core/integrations/`, на клиенте — `@/integrations/ModuleBridge.js`. Прямые импорты из одного модуля в другой запрещены архитектурой и проверяются изоляцией.

## Как система находит модули

Регистрировать модули вручную не нужно. При старте API `ModuleDiscoverer` обходит `modules/` и подхватывает все `api/**/apps.py`. Клиент при сборке сканирует `modules/*/client/js/` — оттуда берутся маршруты, адреса API и правила доступа к страницам. Пункты **бокового меню** регистрируются на сервере (миграции данных в `MenuItem`), а не из JSON клиента. Вложенные разделы (например, подсистема MCT в LMS) могут иметь свои `routes.js` глубже в дереве; `endpoints.js` и `permission-rules.js` при этом обычно остаются в корневом `client/js/`.

Celery подключает конфиги из `modules/<имя>/api/celery_config.py`, задачи — из `api/tasks.py`. Если файлы размещены по соглашению проекта, система подхватит их при старте без ручной регистрации.

## Команды и окружение

Любая операция в проекте — миграции, запуск, установка зависимостей, сборка — выполняется через утилиту **ergoms**. Её команды описаны в `core/deployment/commands.conf`, модульные расширения — в `modules/*/ergoms.conf`. Подробнее о командах ergoms см. [cli.md](cli.md).

Внутри `core/api/` за это отвечают два каталога: `commands/` — команды управления зависимостями модулей (`install`, `module-add`, `module-remove`, `module-list`), `scripts/` — точки входа процессов (запуск API, Celery, Jupyter, прогрев кэшей), которые `commands.conf` вызывает напрямую.

Python-окружение одно на весь проект: `virtual_env/python/`. Зависимости сервера (Django, DRF и др.) — из корневого `pyproject.toml`, команда `ergoms python-install`. Переменные окружения задаются в корневом `.env`, модули при необходимости переопределяют их своими `.env` в корне модуля.

## Файлы, база данных, фоновые задачи

Пользовательские и служебные файлы не раздаются через основной API по `/media/`. Для этого есть **media_api** (порт 8003 по умолчанию) и подписанные URL. Подробности — в правилах `media_api.mdc`.

Подключения к базам описываются в `databases.yaml`. Основная секция — `default`; для Celery могут быть отдельные секции `celery`, `celery_worker`, `celery_beat`. Worker и планировщик Beat должны смотреть на один и тот же брокер, иначе задачи из расписания не дойдут до исполнителя.

Краткие README по частям ядра: [`core/api/`](../core/api/README.md), [`core/client/`](../core/client/README.md), [`core/media_api/`](../core/media_api/README.md).

Запуск фоновой обработки: `ergoms start-worker` и `ergoms start-beat`. Если отдельные секции Celery в YAML не заданы, система использует локальный SQLite в `virtual_env/celery/` как запасной вариант.

## Боковое меню

Пункты sidebar хранятся в PostgreSQL (`MenuItem`, `MenuSeparator`). Модули регистрируют их в **миграциях API** через `MenuMigrationHelper` (`core/api/src/core/cms/adp/menu/migration_utils.py`); эталон — `modules/module_template/api/migrations/0004_add_menu.py`. После `ergoms migrate-all` дерево меню доступно API.

При работе приложения `UserMenuView` отдаёт персональное меню с учётом прав; клиент загружает его через `menuService.js` и отображает в `MenuList`. Администратор может менять порядок, видимость и разделители в CMS (`MenuPanel.vue`) — правки сохраняются в БД. Правила для разработчиков — [`.cursor/rules/menu.mdc`](../.cursor/rules/menu.mdc).

## Realtime (WebSocket и polling)

Уведомления in_app, presence, мессенджер и часть админ-лент обновляются в реальном времени. Режим задаётся переменной `REALTIME_TRANSPORT` в `.env`:

- **`websocket`** (по умолчанию) — Django Channels; JWT передаётся в первом JSON-сообщении после подключения, не в URL.
- **`http_polling`** — периодические REST-запросы, если корпоративный прокси не пропускает WebSocket.

Интервалы polling и переменные `VITE_REALTIME_*` — в [configuration.md](configuration.md). Технические правила — [`.cursor/rules/realtime.mdc`](../.cursor/rules/realtime.mdc).

## Геолокация IP (GeoIP)

Для city/country в сессиях и аудите используется локальная база DB-IP City Lite (MMDB на диске, без отправки IP во внешние API). Команды: `ergoms geoip-download`, `ergoms geoip-backfill`. Подробности — [`core/deployment/logic.md`](../core/deployment/logic.md#geoip-db-ip-city-lite).

## Кроссплатформенность и инструменты

Проект рассчитан на Windows и Linux. Скрипты развёртывания лежат в `core/deployment/windows/` и `core/deployment/linux/`, в `commands.conf` команды могут помечаться префиксами `win:` и `linux:`. Работа с путями и процессами в коде вынесена в слои абстракции (`os_abstraction` на Python, `process-ops.js` на клиенте).

Для Cursor в корне лежат правила в `.cursor/rules/` — это инструкции ассистенту по стилю и ограничениям проекта. Для интеграции с внешними инструментами может использоваться `.cursor/mcp.json`.

Обновление submodules: `git submodule update --init --recursive`.

## См. также

| Вопрос | Документ |
|--------|----------|
| Структура каталогов и конфигурации | [structure.md](structure.md) |
| Справочник команд ergoms | [cli.md](cli.md) |
| Настройка `.env` и баз данных | [configuration.md](configuration.md) |
