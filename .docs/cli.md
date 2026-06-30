# Управление через ergoms

В ERGO MS нет отдельного «зоопарка» из `python manage.py`, `npm run` и `poetry install` в документации для пользователя. Единая точка входа — утилита **`ergoms`**. Она читает команды из `core/deployment/commands.conf` и из `modules/*/ergoms.conf`, сама выбирает нужный каталог и виртуальное окружение.

Технические детали формата команд (префиксы `api:`, `npm:`, `win:` и т.д.) описаны в `.cursor/rules/ergoms-commands.mdc`. Здесь — то, что нужно в ежедневной работе.

## Разработка на локальной машине

Чтобы поднять API с прогревом кэшей:

```cmd
ergoms dev
```

Клиент Vue:

```cmd
ergoms start-client
```

Файловый сервис, Celery worker и планировщик:

```cmd
ergoms start-media
ergoms start-worker
ergoms start-beat
```

Если удобнее держать API и Celery в одном окне терминала:

```cmd
ergoms start-all
```

В Cursor и VS Code для полного набора сервисов можно нажать **`Ctrl+Shift+B`** — это эквивалент ручного запуска нескольких процессов.

## База данных и статика

```cmd
ergoms db-makemigrations
ergoms db-migrate
ergoms migrate-all
ergoms collectstatic
ergoms client-build
ergoms build-all
```

Первые три — работа со схемой БД, последние — подготовка артефактов для production (сборка клиента и статики Django).

## Зависимости и первичная настройка

При первом клонировании репозитория ergoms ещё не установлен — тогда запускают `setup-full` скриптом из README. После этого доступны:

```cmd
ergoms setup
ergoms install-deps
ergoms python-install
ergoms npm run install:all
ergoms warmup-caches
```

`install-deps` — быстрый путь «Python + npm + миграции + прогрев», когда окружение уже есть, но нужно освежить зависимости.

## Любая команда Django

Management-команды вызываются через прокси:

```cmd
ergoms api createsuperuser
ergoms api shell
ergoms api <имя_команды> [аргументы]
```

Так же вызываются модульные команды вроде `ergoms api init_technologies` или `ergoms api seed_lms_demo`.

## Команды модулей

Модуль может добавить свои алиасы в `modules/<имя>/ergoms.conf`. Тогда они вызываются так:

```cmd
ergoms project_ed:install-sidebar-menu
ergoms video_analysis:install
```

## Системные службы (Linux / Windows)

Установка API, клиента, Celery и media_api как служб ОС требует прав администратора:

```cmd
ergoms start
ergoms stop
ergoms restart
ergoms status
ergoms logs ergo-api-dev
```

На Linux подробнее — в [deployment.md](deployment.md). Для обычной разработки службы не нужны: достаточно `ergoms dev` и `ergoms start-client`.

## Как устроен конфиг команд

В `core/deployment/commands.conf` строки вида `имя-команды=тип:действие`. Несколько шагов объединяют через `&&`. Например:

```conf
migrate-all=api:makemigrations && api:migrate
install-deps=api:install && npm:run install:all && api:migrate && api:warmup_caches
dev=api:dev
start-client=npm:run dev
```

Новую команду ядра добавляют в этот файл; модульную — в `ergoms.conf` соответствующего модуля.

## Остановка

Процессы, запущенные вручную в терминале, останавливают **`Ctrl+C`**. Службы ОС — через `ergoms stop`.
