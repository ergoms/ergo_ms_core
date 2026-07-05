# Управление через ergoms

Команды Django, npm и Poetry в пользовательской документации не вызывают напрямую. Единая точка входа — утилита **`ergoms`**: она читает команды из `core/deployment/commands.conf` и из `modules/*/ergoms.conf`, сама выбирает нужный каталог и виртуальное окружение.

Технический формат команд (префиксы `api:`, `npm:`, `win:` и т.д.) описан в `.cursor/rules/ergoms-commands.mdc`. Ниже — то, что нужно при локальной разработке и обслуживании проекта.

## Локальная разработка

Для запуска API с прогревом кэшей выполните:

```cmd
ergoms dev
```

Клиент Vue запускается отдельной командой:

```cmd
ergoms start-client
```

Файловый сервис, исполнитель Celery и планировщик beat:

```cmd
ergoms start-media
ergoms start-worker
ergoms start-beat
```

Если удобнее держать API и Celery в одном окне терминала, используйте:

```cmd
ergoms start-all
```

В Cursor и VS Code для полного набора сервисов можно нажать **`Ctrl+Shift+B`** — это эквивалент ручного запуска нескольких процессов из терминала.

## База данных и статика

Работа со схемой БД и подготовка артефактов для развёртывания:

```cmd
ergoms db-makemigrations
ergoms db-migrate
ergoms migrate-all
ergoms collectstatic
ergoms client-build
ergoms build-all
```

Первые три команды создают и применяют миграции; последние собирают клиент и статику Django.

## Зависимости и первичная настройка {#зависимости-и-первичная-настройка}

При первом клонировании репозитория утилита **ergoms** ещё не установлена — тогда выполняют **полную первичную настройку** (`setup-full`) по инструкции в [README.md](../README.md). После неё доступны, в частности:

```cmd
ergoms setup
ergoms install-deps
ergoms python-install
ergoms npm run install:all
ergoms warmup-caches
```

Команда `install-deps` обновляет зависимости Python и npm, применяет миграции и прогревает кэши — когда окружение уже есть, но его нужно освежить после pull или смены ветки.

## Любая команда Django

Команды Django вызываются через прокси `ergoms api`:

```cmd
ergoms api createsuperuser
ergoms api shell
ergoms api <имя_команды> [аргументы]
```

Так же вызываются модульные команды, например `ergoms api init_technologies` или `ergoms api seed_lms_demo`.

## Команды модулей

Модуль может добавить собственные имена команд в `modules/<имя>/ergoms.conf`. Тогда они вызываются с префиксом модуля:

```cmd
ergoms video_analysis:install
```

## Зависимости модулей (Python)

Пакеты для модуля прописывают не в корневом `pyproject.toml`, а в `modules/<имя>/pyproject.toml`. Управляют этим через прокси `ergoms api`:

```cmd
ergoms api module-add <модуль> <пакет>
ergoms api module-add <модуль> <пакет> ">=1.0.0"
ergoms api module-add <модуль> <пакет> --install
ergoms api module-remove <модуль> <пакет>
ergoms api module-list
```

`module-add` без явной версии сам подбирает последнюю совместимую; флаг `--install` сразу устанавливает пакет. После добавления или удаления без `--install` нужно выполнить `ergoms python-install`, чтобы применить изменения.

## GeoIP (геолокация IP)

Локальная база DB-IP City Lite для city/country в сессиях и журнале аудита:

```cmd
ergoms geoip-download
ergoms geoip-backfill
ergoms geoip-backfill --dry-run
```

Перед первым использованием включите **`GEOIP_ENABLED=true`** в `.env` и скачайте MMDB. Подробнее — [`core/deployment/logic.md`](../core/deployment/logic.md#geoip-db-ip-city-lite) и [configuration.md](configuration.md#geoip-геолокация-ip).

## Системные службы (Linux / Windows)

Чтобы зарегистрировать API, клиент, Celery и media_api как службы операционной системы, нужны права администратора:

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

Новую команду ядра добавляют в этот файл; команду модуля — в `ergoms.conf` соответствующего модуля.

## Остановка

Процессы, запущенные вручную в терминале, останавливают сочетанием **`Ctrl+C`**. Системные службы — командой `ergoms stop`.

## См. также

| Вопрос | Документ |
|--------|----------|
| Как устроена система в целом | [architecture.md](architecture.md) |
| Запуск для разработки, логи | [development.md](development.md) |
| Настройка `.env` и баз данных | [configuration.md](configuration.md) |
| Если команда завершилась с ошибкой | [troubleshooting.md](troubleshooting.md) |
