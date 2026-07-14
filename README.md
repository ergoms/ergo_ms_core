# ERGO MS

ERGO MS — модульный фреймворк для корпоративных веб-приложений. Ядро даёт общую инфраструктуру (аутентификация и профиль, роли и права, меню и оболочка клиента, управление контентом, уведомления, журнал действий, файлы, мост между модулями, фоновые задачи, ergoms), а расширять логику работы системы можно с помощью модулей в папке `modules/`.

Стек: Django 5 и DRF на сервере, Vue 3 и Vite на клиенте, PostgreSQL (или SQLite/MySQL) как основная БД, Celery (worker и beat) для фоновых, отложенных и периодических вычислительных операций, Poetry и npm. Опционально — portable **Redis** (кэш, channel layer, брокер Celery) и **nginx** (запуск как на сервере).

## Документация

- [Архитектура](.docs/architecture.md) — ядро, модули, интеграции
- [Структура проекта](.docs/structure.md) — каталоги и конфигурация
- [Настройка .env и БД](.docs/configuration.md) — первичная конфигурация
- [Разработка](.docs/development.md) — запуск для разработки и логи
- [Команды ergoms](.docs/cli.md) — справочник команд
- [Проблемы при установке](.docs/troubleshooting.md) — типичные ошибки
- [Системные службы](.docs/deployment.md) — systemd / Windows services, запуск как на сервере
- [Docker Compose](.docs/docker.md) — запуск стека в контейнерах (`ergoms docker-*`)
- [Развёртывание ergoms](core/deployment/logic.md) — commands.conf, GeoIP, Redis, nginx, TLS, Docker, realtime за reverse proxy
- [Ядро API](core/api/README.md) · [Клиент](core/client/README.md) · [Media API](core/media_api/README.md)

## Быстрый старт

Путь к проекту на диске должен содержать только латиницу, цифры, дефис и подчёркивание — без кириллицы и пробелов. Например: `C:\projects\ergo_ms\`.

Заранее на компьютере должны быть **установлены** Python 3.12, Node.js 18+, PostgreSQL 14+ и Git — без них полная настройка не начнётся.

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

Задача выполнит полную настройку (`setup-full`): виртуальное окружение, зависимости Python и npm, утилиту `ergoms`, расширения редактора. На Windows политика выполнения скриптов обходится автоматически; на Linux потребуются права администратора (`sudo`).

После установки появятся файлы `.env`, `databases.yaml` и `celery_workers.yaml` (из примеров, если их ещё не было). Проверьте их и при необходимости отредактируйте под свою среду — см. [configuration.md](.docs/configuration.md). Если параметры БД отличались от примера и миграции не применились, поправьте `databases.yaml` и снова выполните задачу **`Setup Full System`** или в терминале: `ergoms migrate-all`.

Подробнее о командах установки — [cli.md](.docs/cli.md#зависимости-и-первичная-настройка).

**Альтернатива без редактора** — из корня проекта в терминале:

Windows (PowerShell):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
.\core\deployment\windows\ergo_ms.ps1 setup-full
```

Linux:

```bash
sudo bash core/deployment/linux/ergo_ms.sh setup-full
```

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
