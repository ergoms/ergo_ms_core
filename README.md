# ERGO MS

ERGO MS — модульный фреймворк для корпоративных веб-приложений. Ядро даёт общую инфраструктуру (аутентификация и профиль, роли и права, меню и оболочка клиента, управление контентом, уведомления, журнал действий, файлы, мост между модулями, фоновые задачи, ergoms), а расширять логику работы системы можно с помощью модулей в папке `modules/`.

Стек: Django 5 и DRF на сервере, Vue 3 и Vite на клиенте, PostgreSQL (или SQLite/MySQL) как основная БД, Celery (worker и beat) для фоновых, отложенных и периодических вычислительных операций, Poetry и npm. Опционально — portable **Redis** (кэш, channel layer, брокер Celery) и **nginx** (запуск как на сервере).

## Документация

- [Сценарии установки Python, Node.js и PostgreSQL](#сценарии-установки-python-nodejs-и-postgresql) — системные интерпретаторы и СУБД vs portable в `virtual_env`
- [Архитектура](.docs/architecture.md) — ядро, модули, интеграции
- [Структура проекта](.docs/structure.md) — каталоги и конфигурация
- [Настройка .env и БД](.docs/configuration.md) — первичная конфигурация
- [Разработка](.docs/development.md) — запуск для разработки и логи
- [Команды ergoms](.docs/cli.md) — справочник команд
- [Lifecycle-pipeline](.docs/lifecycle-pipeline.md) — единая цепочка setup, deploy, служб, Docker и dev
- [Проблемы при установке](.docs/troubleshooting.md) — типичные ошибки
- [Системные службы](.docs/deployment.md) — systemd / Windows services, запуск как на сервере
- [Docker Compose](.docs/docker.md) — запуск стека в контейнерах (`ergoms docker-*`)
- [Развёртывание ergoms](core/deployment/logic.md) — commands.conf, GeoIP, Redis, nginx, TLS, Docker, realtime за reverse proxy
- [Ядро API](core/api/README.md) · [Клиент](core/client/README.md) · [Media API](core/media_api/README.md)

## Сценарии установки Python, Node.js и PostgreSQL

Перед клонированием репозитория на компьютере должен быть установлен **Git**. Python, Node.js и PostgreSQL можно взять из системы **или** поставить как portable-копии внутрь проекта (`virtual_env/packages/`) — оба варианта поддерживаются. Выбор влияет на то, что нужно подготовить **до** `setup-full`, и на значения в `.env` / `databases.yaml`.

### Python и Node.js

Интерпретаторы нужны для виртуального окружения Python (`virtual_env/python/`) и npm-workspace клиента (`virtual_env/npm/`). Режим задаётся в `.env` флагами `PORTABLE_PYTHON_ENABLED` и `PORTABLE_NODEJS_ENABLED` (в шаблоне [`.env.example`](.env.example) по умолчанию оба `false`).

| Сценарий | Что сделать | Когда уместен |
|----------|-------------|---------------|
| **Системные** интерпретаторы | Заранее установить Python **3.12** и Node.js **18+**. В `.env` оставить `PORTABLE_PYTHON_ENABLED=false` и `PORTABLE_NODEJS_ENABLED=false`. `setup-full` создаст venv из системного Python и будет использовать системный Node/npm. | На машине уже есть нужные версии; корпоративная политика запрещает скачивать runtime в каталог проекта. |
| **Portable** в проекте | В `.env` выставить `PORTABLE_PYTHON_ENABLED=true` и/или `PORTABLE_NODEJS_ENABLED=true` **до** полной настройки (или поправить `.env` и повторить `setup-full`). Скрипты скачают CPython 3.12 в `virtual_env/packages/python/` и Node.js LTS в `virtual_env/packages/nodejs/`, затем создадут venv и npm-workspace из них. | Чистая машина без Python/Node; нужна изолированная копия runtime только для этого репозитория. |

Явные команды работают **независимо** от флагов: `ergoms install-python` и `ergoms install-nodejs` всегда ставят (или обновляют) portable-копии. После них для зависимостей проекта: `ergoms python-install` и `ergoms npm run install:all` (или снова `ergoms setup` / `install-deps`).

Не создавайте вручную `.venv` / `venv` и не вызывайте `pip` / `npm` мимо `ergoms` — окружение проекта живёт только в `virtual_env/`.

### PostgreSQL

Основная БД задаётся в [`databases.yaml`](databases.yaml.example) (`default.host` / `default.port`). Portable PostgreSQL кладётся в `virtual_env/packages/postgres/` и по умолчанию слушает порт **5433**; типичный системный Postgres — **5432**. Скрипты **не** пишут host/port в `.env` — правит человек в yaml.

Детект «уже есть Postgres» идёт по **системной службе** с именем `postgresql*` (не по TCP и не по содержимому yaml). Службы проекта `ergo_ms_postgres` (Windows) и `ergo-postgres` (Linux) системными **не** считаются.

| Сценарий | Поведение | Что проверить в `databases.yaml` |
|----------|-----------|----------------------------------|
| **Системный** PostgreSQL 14+ | Если служба `postgresql*` уже есть, `setup-full` **пропускает** portable (`[SKIP]`), пока не включён force. Используйте уже установленный сервер. | `host` / `port` вашей установки (часто `127.0.0.1` и `5432`), имя БД, пользователь и пароль. База `ergo_ms` должна существовать или быть создана вами. |
| **Portable** (авто) | Нет системной службы `postgresql*` → `setup-full` ставит portable, инициализирует кластер, создаёт БД `ergo_ms`, регистрирует службу на **5433**. | В примере уже `port: 5433`. После установки при необходимости поправьте пароль и снова выполните `ergoms migrate-all`. |
| **Force portable** | В `.env`: `POSTGRES_FORCE_INSTALL=true`, либо один прогон `ergoms setup-full --with-postgres`. Portable ставится на **5433** даже при наличии системного Postgres. | Обязательно укажите `port: 5433` (или другой свободный порт portable), иначе API останется на системном `5432`. |

Отдельно, без полной настройки:

```cmd
ergoms install-postgres
ergoms start-postgres
ergoms status-postgres
ergoms test-postgres
ergoms uninstall-postgres
```

Флаг `--purge` / `-Purge` у `uninstall-postgres` удаляет и каталог `virtual_env/packages/postgres`.

В Docker PostgreSQL может идти контейнером (`DOCKER_PROFILE_POSTGRES`) — см. [docker.md](.docs/docker.md). Не держите одновременно portable на хосте и контейнерный Postgres на одном и том же порту без смены порта у одной из сторон.

## Быстрый старт

Путь к проекту на диске должен содержать только латиницу, цифры, дефис и подчёркивание — без кириллицы и пробелов. Например: `C:\projects\ergo_ms\`.

Заранее нужен **Git**. Python 3.12, Node.js 18+ и PostgreSQL 14+ — либо уже установлены в системе, либо будут поставлены как portable при `setup-full` (см. [сценарии выше](#сценарии-установки-python-nodejs-и-postgresql)). Шаблон `.env.example` рассчитан на **системные** Python/Node (`PORTABLE_*=false`) и авто-portable Postgres при отсутствии системной службы.

```cmd
git clone https://github.com/SKB-AI/ergo_ms_core ergo_ms
cd ergo_ms
git submodule update --init --recursive
```

Ядро (`core/api`, `core/client`, `core/media_api`) и модули в `modules/` — отдельные git-репозитории (submodule). Без `submodule update` каталоги могут оказаться пустыми.

Откройте каталог **`ergo_ms`** в **Cursor** или **VS Code** — в проекте уже настроены задачи (`.vscode/tasks.json`), через них проще всего установить окружение и запустить сервисы.

### 1. Первая установка (задача)

1. Меню **Terminal → Run Task…** (или **Терминал → Выполнить задачу…**).
2. Выберите **`Setup Full System`**.

Задача выполнит полную настройку (`setup-full`): виртуальное окружение, зависимости Python и npm, проверку локальной утилиты `ergoms` в корне проекта, расширения редактора. На Windows политика выполнения скриптов обходится автоматически. На Linux для части infra-команд (nginx, службы) runner при необходимости запросит `sudo`.

После установки появятся файлы `.env`, `databases.yaml` и `celery_workers.yaml` (из примеров, если их ещё не было). Проверьте их и при необходимости отредактируйте под свою среду — см. [configuration.md](.docs/configuration.md). Если параметры БД отличались от примера и миграции не применились, поправьте `databases.yaml` и снова выполните задачу **`Setup Full System`** или в терминале: `ergoms migrate-all`.

Подробнее о командах установки — [cli.md](.docs/cli.md#зависимости-и-первичная-настройка).

**Альтернатива без редактора** — из корня проекта в терминале:

```cmd
ergoms setup
```

Команда `ergoms` — файлы в **`core/deployment/bin/`** (`ergoms.cmd` на Windows, `ergoms` на Linux). Она работает **только** если текущий каталог — корень проекта или его подпапка. В Cursor/VS Code профиль **Project-Shell** уже добавляет этот каталог в PATH. Если терминал ещё не видит `ergoms`, один раз выполните полную настройку через скрипт оболочки:

Windows (PowerShell):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
.\core\deployment\windows\ergo_ms.ps1 setup-full
```

Linux:

```bash
bash core/deployment/linux/ergo_ms.sh setup-full
```

На Linux для infra-команд (nginx, службы) runner при необходимости запросит `sudo` сам — отдельно оборачивать в `sudo bash …` не нужно.

### 2. Запуск для разработки

После установки нажмите **`Ctrl+Shift+B`** — задача **`Start All Services`** запустит API, клиент, Celery worker и beat, media_api (с предварительным прогревом кэшей). Отдельные сервисы можно запустить через **Run Task…** — **`Client`**, **`API`**, **`Media API`** и т.д.

В терминале то же самое: **`ergoms start-all`** — прогрев кэшей и запуск всех пяти сервисов (на Windows каждый в отдельном окне). Дальнейшие операции обслуживания — через **`ergoms`**; обновить зависимости без полной переустановки: `ergoms install-deps`.

После запуска откройте в браузере **клиент** — это основная точка входа в систему:

**http://localhost:8001** — Vue-приложение: форма входа, боковое меню, страницы ядра и подключённых модулей. Клиент сам обращается к серверу по адресу из `.env` (`API_HOST`, `API_PORT`); отдельно открывать API для обычной работы не нужно. При первом запуске, если учётной записи ещё нет, создайте администратора в терминале: `ergoms api createsuperuser`, затем войдите на этой странице.

Порт можно изменить в `.env`, если он уже занят на вашем компьютере. Подробнее о сервисах и портах — в [development.md](.docs/development.md#адреса-в-браузере).

### 3. Опционально: Redis и nginx

Для локальной разработки с одним процессом API Redis не обязателен. Если нужен общий кэш, channel layer между несколькими worker API или брокер Celery на Redis:

```cmd
ergoms install-redis
```

Затем вручную в `.env`: `REDIS_ENABLED=true`, перезапустите API. Проверка: `ergoms test-redis` → `PONG`. Подробнее — [configuration.md](.docs/configuration.md#redis-и-несколько-процессов) и [`core/deployment/logic.md`](core/deployment/logic.md#redis-optional-portable-packages).

Запуск как на сервере (обратный прокси, один origin для клиента и API): эталон переменных — [`core/deployment/nginx/env.example`](core/deployment/nginx/env.example), команды — `ergoms install-nginx`, см. [cli.md](.docs/cli.md#nginx-опционально).
