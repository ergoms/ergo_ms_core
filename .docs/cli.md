# Управление сервисами через CLI

Командная оболочка `ergoms` осуществляет агрегацию команд из центрального дескриптора `core/deployment/commands.conf` и модульных конфигураций `modules/*/ergoms.conf`. Все операции в проекте выполняются **только через ergoms** — прямые вызовы `python manage.py`, `pip`, `poetry`, `npm` запрещены (см. `no-direct-manage-py.mdc`).

## Базовые операции

Управление системными службами (требуют прав администратора/root):

```cmd
ergoms start      # Запуск всех системных служб (API, Client, Celery Worker, Celery Beat, Media API)
ergoms stop       # Остановка всех сервисов
ergoms restart    # Перезапуск всех сервисов
ergoms status     # Статус всех сервисов
```

Для режима разработки (без системных служб) используйте отдельные команды: `ergoms dev`, `ergoms start-client`, `ergoms start-worker`, `ergoms start-beat`, `ergoms start-media` или `ergoms start-all` (API + Worker + Beat в одном терминале).

## Компонентный запуск

Избирательная инициализация отдельных компонентов:

```cmd
ergoms dev              # API в режиме разработки (с прогревом кэшей)
ergoms start-client     # Клиентское приложение Vue.js (npm:run dev)
ergoms start-worker     # Celery Worker (из celery_workers.yaml)
ergoms start-worker --worker=<name>   # Конкретный воркер
ergoms start-beat       # Celery Beat — планировщик задач
ergoms start-media      # Media API (CDN, файловый сервер, порт 8003)
ergoms start-all        # API + Worker + Beat в одном терминале (разработка)
```

## Наблюдение за системой

Инспекция журналов системных служб (при использовании `ergoms start`):

```cmd
ergoms logs ergo-api-dev [N]          # Последние N записей (по умолчанию 500)
ergoms logs ergo-client-dev
ergoms logs ergo-celery-worker-all    # Worker (при конфиге celery_workers.yaml по умолчанию)
ergoms logs ergo-celery-beat
ergoms logs ergo-media-api
```

## Миграции и статика

Операции со схемой БД и статикой:

```cmd
ergoms db-makemigrations    # Создание миграций
ergoms db-migrate           # Применение миграций
ergoms migrate-all          # Создание и применение миграций
ergoms sq-del-migrations <app> [start] [end] [--check-only] [--force]   # Объединение миграций
ergoms safe-drop-app <app> [--check-only] [--cascade] [--force] [--auto-fix]   # Удаление приложения
ergoms restore-menu [--core-only] [--module=name] [--dry-run]   # Восстановление меню
ergoms collectstatic        # Сбор статических файлов Django
```

## Управление зависимостями

```cmd
ergoms setup                # Полная настройка (setup-full): venv, Poetry, зависимости, CLI
ergoms install-deps         # Быстрая установка: api:install && npm:install && migrate + warmup
ergoms python-install       # Python-зависимости (api:install)
ergoms python-update        # Обновление Python-зависимостей (poetry:update)
ergoms reinstall            # Переустановка: poetry:install --sync && npm:ci
ergoms update-all           # Обновление всех зависимостей
ergoms warmup-caches        # Прогрев кэшей (discovered_apps, celery, modules_env)
ergoms warmup-caches-if-needed   # Прогрев только при пустом/устаревшем кэше
```

## Сборка проекта

Подготовка артефактов для производственного развёртывания:

```cmd
ergoms build-all            # Полная сборка: npm:run build && api:collectstatic --noinput
ergoms client-build         # Сборка клиентского приложения (npm:run build)
ergoms collectstatic        # Сборка статических ресурсов (api:collectstatic --noinput)
```

## Дополнительные команды CLI

### Media API и Ollama

```cmd
ergoms start-media      # Запуск Media API (CDN, порт 8003)
ergoms ollama           # Управление Ollama
ergoms install-ollama   # Установка Ollama
ergoms uninstall-ollama # Удаление Ollama
```

### Установка и управление службами

Регистрация системных служб (требуется администратор/root):

```cmd
ergoms install-all-services  # Регистрация служб (Windows: NSSM, Linux: systemd)
ergoms start-api-service     # Запуск службы API
ergoms start-client-service  # Запуск службы Client
ergoms start-worker-service  # Запуск службы Celery Worker
ergoms start-beat-service    # Запуск службы Celery Beat
ergoms start-media-service   # Запуск службы Media API
ergoms start-ollama-service  # Запуск службы Ollama
ergoms stop-all-services     # Остановка всех служб
ergoms uninstall-services    # Удаление служб (опция --purge)
```

**Платформенные скрипты прямого вызова:**

- `core/deployment/windows/ergo_ms.ps1` — скрипт PowerShell для Windows
- `core/deployment/linux/ergo_ms.sh` — скрипт Bash для Linux

Скрипты реализуют операции: `setup-full`, `clean`, `update-submodules`, управление жизненным циклом служб.

### Управление CLI-обёрткой

```cmd
ergoms install-cli    # Установка CLI-обёртки (требуется повышение привилегий)
ergoms uninstall-cli  # Удаление CLI-обёртки (требуется повышение привилегий)
ergoms help           # Вывод справочной информации по доступным командам
```

**Полная инициализация (setup-full):** при первой установке команда `ergoms` ещё недоступна. Запускайте настройку **напрямую скриптом** (см. раздел «Практические сценарии»). После установки CLI можно использовать `ergoms setup` (запускает setup-full).

### Комплексные сценарии развёртывания

Автоматизированное развёртывание с обновлением субмодулей, установкой зависимостей и сборкой:

```cmd
ergoms deploy-api         # API-развёртывание: обновление субмодулей, установка зависимостей, применение миграций
ergoms deploy-client      # Client-развёртывание: обновление субмодуля, установка зависимостей, сборка проекта
ergoms deploy-all         # Полное развёртывание: обновление всех субмодулей ядра, установка зависимостей, сборка
ergoms deploy-api-dev     # Развёртывание API с запуском в режиме разработки
ergoms deploy-client-dev  # Развёртывание Client с запуском в режиме разработки
```

**Семантика префиксов команд:**

Префиксы `shell:`, `poetry:`, `npm:`, `win:`, `linux:` определяют контекст исполнения. Система автоматически выбирает интерпретатор команд (PowerShell или Bash) на основе детектирования операционной системы.

## Прокси-команды

Прямая переадресация к инструментальным утилитам (не требуется повышение привилегий):

```cmd
ergoms poetry <args>     # Переадресация к Poetry (контекст: корень проекта)
ergoms api <args>        # Переадресация к Django manage.py (core/api)
ergoms media_api <args>  # Переадресация к Media API manage.py
ergoms npm <args>        # Переадресация к npm
```

**Примеры использования:**

```cmd
# Операции Poetry
ergoms poetry install
ergoms poetry update
ergoms poetry add <package>

# Команды Django API
ergoms api migrate
ergoms api createsuperuser
ergoms api shell

# Операции npm
ergoms npm run dev
ergoms npm install
```

## Модульные команды

Каждый модуль расширяет CLI посредством собственного конфигурационного дескриптора `ergoms.conf`. Иллюстрация на примере модуля `video_analysis`:

- `ergoms video_analysis:install` — установка всех зависимостей модуля (`install_ffmpeg`, `install_opus_mt`, `install_vosk_model`, `install_silero_repo`, `install_tts_model`)
- `ergoms video_analysis:install-ffmpeg`, `install-opus`, `install-vosk`, `install-silero`, `install-tts-fr` — избирательная установка компонентов

При отсутствии коллизий имён команды доступны без префикса модуля. Актуальный реестр команд: `ergoms help`.

**Синтаксис вызова:**
```cmd
ergoms <module>:<command>       # Квалифицированный вызов с префиксом модуля
ergoms <command>                # Неквалифицированный вызов (при отсутствии коллизий)
```

## Практические сценарии

**Полная инициализация системы (первичная установка):**

Команда `ergoms` устанавливается в ходе setup-full (шаг 4), поэтому при первом развёртывании запускайте скрипт **напрямую**, без предварительной установки CLI:

```cmd
# Windows (PowerShell; при необходимости — повышение привилегий)
.\core\deployment\windows\ergo_ms.ps1 setup-full

# Linux (Bash с привилегиями суперпользователя)
sudo bash core/deployment/linux/ergo_ms.sh setup-full
```

После выполнения скрипта CLI (`ergoms`) доступен в PATH. Для повторной полной настройки: `ergoms setup`.

**Цикл ежедневной разработки:**

```cmd
ergoms start-all            # API + Worker + Beat
ergoms start-client         # Клиент (в отдельном терминале)
# или Ctrl+Shift+B в VS Code/Cursor для запуска всех сервисов
ergoms stop                 # Остановка (при использовании системных служб)
```

**Операции с базой данных:**

```cmd
ergoms migrate-all          # Генерация и применение миграций
ergoms api createsuperuser  # Создание учётной записи суперпользователя
ergoms api shell            # Интерактивная оболочка Django
```

**Управление зависимостями:**

```cmd
ergoms install-deps         # Быстрая установка (api:install + npm + migrate + warmup)
ergoms setup                # Полная настройка (при первой установке)
ergoms poetry add <package> # Добавление Python-пакета
ergoms npm install <package># Добавление npm-пакета
```

**Подготовка к производственному развёртыванию:**

```cmd
ergoms build-all            # Сборка клиента и агрегация статических ресурсов
```

## Конфигурация CLI

**Структура конфигурационных дескрипторов:**

- Команды ядра системы: `core/deployment/commands.conf`
- Команды модулей: `modules/*/ergoms.conf`

**Синтаксис определения команд:**

```conf
# Комментарий
command-name=type:command

# Типология префиксов:
# poetry:  - команда Poetry (контекст: корень проекта)
# api:     - команда Django manage.py (core/api)
# npm:    - команда npm
# shell:  - команда оболочки (кроссплатформенная)
# win:    - команда Windows (игнорируется на Linux)
# linux:  - команда Linux (игнорируется на Windows)
```

**Пример конфигурации ядра (core/deployment/commands.conf):**

```conf
# Команды API
dev=api:dev
db-migrate=api:migrate
migrate-all=api:makemigrations && api:migrate

# Команды Client
start-client=npm:run dev
client-build=npm:run build

# Управление зависимостями
setup=win:...setup-full && linux:...setup-full
install-deps=api:install && npm:install && api:migrate && api:warmup_caches
python-install=api:install
warmup-caches=api:warmup_caches

# Сборка артефактов
build-all=npm:run build && api:collectstatic --noinput
```

**Пример конфигурации модуля (modules/video_analysis/ergoms.conf):**

```conf
# Установка всех зависимостей модуля
install=api:install_ffmpeg && api:install_opus_mt && api:install_vosk_model
install-ffmpeg=api:install_ffmpeg
install-opus=api:install_opus_mt
```

**Требования к привилегиям:**

- Повышение привилегий требуется для: `install`, `start`, `stop`, `restart`, `status`, `uninstall`, `install-cli`, `setup-full`
- Прокси-команды и пользовательские команды не требуют повышения привилегий

**Завершение работы системы:**

- При использовании системных служб: `ergoms stop`
- При запуске через `ergoms start-all` или отдельные команды: `Ctrl+C` в каждом терминале

