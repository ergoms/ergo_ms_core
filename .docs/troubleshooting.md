# Решение проблем при установке

## Проблема 1: Permission denied при установке Poetry пакетов

**Диагностическая сигнатура:**

```
[Errno 13] Permission denied: Poetry Cache
```

**Процедура устранения:**

```cmd
# Windows: очистка кеша Poetry
rmdir /S /Q "%LOCALAPPDATA%\pypoetry\Cache"

# Linux/macOS: очистка кеша Poetry
rm -rf ~/.cache/pypoetry

# Переустановка зависимостей (из корня проекта)
ergoms python-install
# Либо с отключением кеша: ergoms poetry install --no-cache
```

## Проблема 2: Команда ergoms не найдена

**Процедура устранения:**

```cmd
# Windows (PowerShell с правами администратора)
.\core\deployment\windows\ergo_ms.ps1 install-cli

# Linux (Bash с правами root)
sudo bash core/deployment/linux/ergo_ms.sh install-cli
```

## Проблема 3: База данных не настроена

**Процедура устранения:**

1. Создайте `databases.yaml` на основе `databases.yaml.example`
2. Укажите параметры подключения к СУБД
3. Примените миграции: `ergoms db-migrate`

## Проблема 4: Медленный первый запуск API

**Причина:** Кэши обнаружения приложений, Celery и модулей пусты.

**Процедура устранения:**

```cmd
ergoms warmup-caches
```

Команда `ergoms dev` автоматически вызывает прогрев кэшей при необходимости.

