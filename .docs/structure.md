# Структура проекта

Корень репозитория — это не только исходники, но и точка сборки всей системы. Здесь лежат конфигурация, виртуальное окружение, логи и ссылки на подключённые модули.

## Основные каталоги

**`core/api/`** — Django-приложение: модели, API, CMS, права, уведомления, аудит действий, интеграции.

**`core/client/`** — Vue-приложение: маршруты, меню, общие компоненты, стили.

**`core/media_api/`** — отдельный сервис для хранения и раздачи файлов.

**`core/deployment/`** — скрипты установки и запуска, файл `commands.conf` с командами ergoms.

**`modules/<имя>/`** — доменные модули. Каждый модуль — submodule со своим git-репозиторием; внутри типично пары `api/` и `client/`.

**`virtual_env/`** — Python-окружение (`python/`) и служебные данные: кэш Celery, ресурсы и т.п. Второй venv в проекте создавать не нужно.

**`logs/`** — журналы API, Celery, media_api и отдельных модулей. При отладке сюда стоит заглянуть в первую очередь.

## Конфигурационные файлы

В корне проекта:

- **`.env`** — переменные окружения (создаётся из `.env.example`, в том числе при `setup-full`).
- **`databases.yaml`** — подключения к PostgreSQL и, при необходимости, к базам Celery (из `databases.yaml.example`).
- **`celery_workers.yaml`** — какие очереди обслуживает каждый исполнитель Celery.

У модулей могут быть свои **`.env`** и **`ergoms.conf`** — локальные переопределения и команды, которые ergoms регистрирует с префиксом имени модуля.

Пункты бокового меню модуль регистрирует в **миграции API** (`MenuMigrationHelper` → таблицы `MenuItem` / `MenuSeparator`). Порядок и видимость настраиваются в админ-панели CMS (`MenuPanel.vue`). Маршруты страниц — `client/js/routes.js`. Подробнее — [architecture.md](architecture.md#боковое-меню).

## Документация и правила

Каталог **`.docs/`** — описание архитектуры, настройки и команд для людей. Оглавление — в [README.md](../README.md#документация) в корне репозитория.

**`.cursor/rules/`** — инструкции для AI-ассистента в Cursor; по смыслу пересекаются с `.docs/`, но короче и с примерами «плохо / хорошо». Стиль правил и документов — [`writing-docs-and-rules.mdc`](../.cursor/rules/writing-docs-and-rules.mdc).

Технические заметки в дереве **`core/`**:

| Файл | О чём |
|------|--------|
| [`core/api/README.md`](../core/api/README.md) | Django API, структура, запуск |
| [`core/client/README.md`](../core/client/README.md) | Vue-клиент, компоненты |
| [`core/media_api/README.md`](../core/media_api/README.md) | файловый сервис |
| [`core/deployment/logic.md`](../core/deployment/logic.md) | ergoms, commands.conf, GeoIP, realtime за nginx |
| `modules/<имя>/logic.md` | контракты конкретного модуля (если есть) |

## Куда смотреть дальше

| Вопрос | Документ |
|--------|----------|
| Как устроена система в целом | [architecture.md](architecture.md) |
| Как настроить `.env` и базы данных | [configuration.md](configuration.md) |
| Как запускать проект при разработке | [development.md](development.md) |
| Справочник команд ergoms | [cli.md](cli.md) |
| Если установка завершилась с ошибкой | [troubleshooting.md](troubleshooting.md) |
| Системные службы на Linux | [deployment.md](deployment.md) |
