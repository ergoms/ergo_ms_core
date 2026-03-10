# Управление сервисами через CLI

Командная оболочка `ergoms` осуществляет агрегацию команд из центрального дескриптора `core/deployment/commands.conf` и модульных конфигураций `modules/*/ergoms.conf`. Классификация команд представлена ниже.

## Базовые операции

Управление жизненным циклом всех сервисов системы (API, Client, Celery Worker, Celery Beat):

```cmd
ergoms start      # Инициализация всех сервисов
ergoms stop       # Завершение работы всех сервисов
ergoms restart    # Перезапуск всех сервисов
ergoms status     # Получение статуса всех сервисов
```

## Компонентный запуск

Избирательная инициализация отдельных компонентов системы:

```cmd
ergoms dev              # API в режиме разработки (api:dev)
ergoms start-client     # Клиентское приложение (npm:run dev)
ergoms start-worker     # Обработчик фоновых задач (scripts/start_celery_worker.py)
ergoms start-beat       # Планировщик периодических задач (scripts/start_celery_beat.py)
```

## Наблюдение за системой

Инспекция журналов сервисов с параметрами глубины вывода:

```cmd
ergoms logs ergo-api-dev           # Последние 500 записей журнала API
ergoms logs ergo-client-dev 1000   # Последние 1000 записей журнала Client
ergoms logs ergo-celery-worker     # Журнал обработчика фоновых задач
ergoms logs ergo-celery-beat       # Журнал планировщика задач
```

## Миграции и статика

Операции обслуживания схемы базы данных и статических ресурсов:

```cmd
ergoms db-migrate           # Применение миграций к базе данных
ergoms db-makemigrations    # Генерация новых миграций
ergoms migrate-all          # Генерация и применение миграций (единая транзакция)
ergoms collectstatic        # Агрегация статических файлов
```

## Управление зависимостями

Операции с пакетными зависимостями Python и Node.js:

```cmd
ergoms setup                # Полная инициализация: poetry:install && npm:install && api:migrate
ergoms python-install       # Установка Python-зависимостей (poetry:install)
ergoms python-update        # Обновление Python-зависимостей (poetry:update)
ergoms reinstall            # Переустановка с синхронизацией: poetry:install --sync && npm:ci
ergoms update-all           # Обновление всех зависимостей: poetry:update && npm:update
```

## Сборка проекта

Подготовка артефактов для производственного развёртывания:

```cmd
ergoms build-all            # Полная сборка: npm:run build && api:collectstatic --noinput
ergoms client-build         # Сборка клиентского приложения (npm:run build)
ergoms collectstatic        # Сборка статических ресурсов (api:collectstatic --noinput)
```

## Дополнительные команды CLI

### Установка и управление службами

Регистрация системных служб в операционной системе (требуется повышение привилегий):

```cmd
ergoms install              # Регистрация и запуск служб Windows
ergoms uninstall            # Удаление служб (опция -Purge удаляет пользовательские данные)
ergoms install-all-services # Регистрация всех служб Windows
ergoms install-all-services-linux # Регистрация всех служб Linux (systemd)
```

**Платформенные скрипты прямого вызова:**

- `core/deployment/windows/ergo_ms.ps1` — скрипт PowerShell для Windows
- `core/deployment/linux/ergo_ms.sh` — скрипт Bash для Linux

Скрипты реализуют операции: `setup-full`, `clean`, управление жизненным циклом служб.

### Управление CLI-обёрткой

```cmd
ergoms install-cli    # Установка CLI-обёртки (требуется повышение привилегий)
ergoms uninstall-cli  # Удаление CLI-обёртки (требуется повышение привилегий)
ergoms help           # Вывод справочной информации по доступным командам
```

**Полная инициализация (setup-full):** при первой установке команда `ergoms` ещё не установлена. Запускайте полную настройку **скриптом напрямую** (см. раздел «Практические сценарии»). После установки CLI доступна и команда `ergoms setup-full` для повторных запусков.

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
ergoms poetry <args>     # Переадресация к Poetry
ergoms api <args>        # Переадресация к Django manage.py
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

После выполнения скрипта CLI (`ergoms`) доступен в PATH. Для повторной полной настройки можно использовать: `ergoms setup-full`.

**Цикл ежедневной разработки:**

```cmd
ergoms start                # Инициализация всех сервисов
ergoms logs ergo-api-dev    # Инспекция журналов
ergoms stop                 # Завершение работы сервисов
```

**Операции с базой данных:**

```cmd
ergoms migrate-all          # Генерация и применение миграций
ergoms api createsuperuser  # Создание учётной записи суперпользователя
ergoms api shell            # Интерактивная оболочка Django
```

**Управление зависимостями:**

```cmd
ergoms setup                # Полная установка зависимостей (poetry + npm + migrate)
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
# poetry: - команда Poetry (контекст выполнения: core/)
# api:    - команда Django manage.py
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

# Команды Celery
start-worker=win:...python.exe core\api\scripts\start_celery_worker.py && linux:...python core/api/scripts/start_celery_worker.py
start-beat=win:...python.exe core\api\scripts\start_celery_beat.py && linux:...python core/api/scripts/start_celery_beat.py

# Управление зависимостями
setup=poetry:install && npm:install && api:migrate
python-install=poetry:install
update-all=poetry:update && npm:update

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

```cmd
ergoms stop
```

Альтернативный способ: завершение процессов терминалов посредством `Ctrl+C` в каждом активном сеансе.

