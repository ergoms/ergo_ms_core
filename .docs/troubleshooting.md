# Решение проблем при установке

Ниже — типичные сбои при первой настройке ERGO MS и что с ними делать. Если ошибка не из этого списка, начните с проверки `.env`, `databases.yaml` и каталога `logs/`.

## Poetry: Permission denied

Сообщение вроде `[Errno 13] Permission denied` при установке Python-зависимостей часто связано с повреждённым кэшем Poetry.

На Windows удалите кэш и переустановите зависимости:

```cmd
rmdir /S /Q "%LOCALAPPDATA%\pypoetry\Cache"
ergoms python-install
```

На Linux или macOS:

```bash
rm -rf ~/.cache/pypoetry
ergoms python-install
```

## Команда ergoms не найдена

Утилита ergoms устанавливается на шаге **полной первичной настройки** (`setup-full`) — см. [README.md](../README.md). Если терминал её не находит, установите ergoms отдельно.

**Windows** — из корня проекта в PowerShell:

```cmd
.\core\deployment\windows\ergo_ms.ps1 install-cli
```

**Linux** — из корня проекта с правами администратора:

```bash
sudo bash core/deployment/linux/ergo_ms.sh install-cli
```

Либо повторите полную настройку из README: команда `setup-full` создаст окружение, зависимости и обёртку ergoms.

## База данных

Если API не удаётся подключить к PostgreSQL:

1. Убедитесь, что файл **`databases.yaml`** создан из примера и параметры `host`, `port`, `user`, `password`, `name` соответствуют вашей СУБД.
2. Создайте пустую базу с указанным именем, если её ещё нет.
3. Примените миграции командой **`ergoms db-migrate`**.

## Медленный первый запуск API

При первом запуске система строит кэши списка приложений, модулей и конфигурации Celery — это нормально. Ускорить повторные старты можно явным прогревом:

```cmd
ergoms warmup-caches
```

Команда **`ergoms dev`** сама вызывает прогрев, если кэш пустой или устарел — отдельно вызывать её не обязательно.

## Пустые каталоги core/ или modules/ после clone

Если `core/api`, `core/client` или `modules/<имя>/` пусты — не подтянуты submodule:

```cmd
git submodule update --init --recursive
```

Затем повторите `setup-full` или `ergoms install-deps`.

## WebSocket / realtime не работает между процессами

Симптом: уведомления или presence не приходят при нескольких worker API.

**Причина:** channel layer `memory` работает только в одном процессе.

**Что сделать:** в `.env` задайте `CHANNEL_LAYER_BACKEND=postgres` или установите Redis (`ergoms install-redis`, `REDIS_ENABLED=true`, `CHANNEL_LAYER_BACKEND=redis`). Перезапустите API. См. [configuration.md](configuration.md#redis-и-несколько-процессов).

## Redis не отвечает

Симптом: `ergoms test-redis` не возвращает `PONG`.

1. Установите и запустите: `ergoms install-redis` или `ergoms start-redis`.
2. Проверьте `REDIS_HOST`, `REDIS_PORT` в `.env`.
3. Журнал: `logs/redis.log` или `ergoms logs ergo-redis`.

## SSE обрывается за nginx

Симптом: поток `/api/realtime/stream/` закрывается через короткое время.

1. Проверьте конфиг: `ergoms test-nginx`.
2. Перезагрузите: `ergoms reload-nginx`.
3. Убедитесь, что в шаблоне `ergo_ms.conf.template` для SSE отключён `proxy_buffering` — см. [realtime.mdc](../.cursor/rules/realtime.mdc).

## См. также

| Вопрос | Документ |
|--------|----------|
| Настройка `.env` и баз данных | [configuration.md](configuration.md) |
| Справочник команд ergoms | [cli.md](cli.md) |
| Запуск для разработки | [development.md](development.md) |
