# Решение проблем при установке

## Проблема 1: Permission denied при установке Poetry пакетов

**Диагностическая сигнатура:**

```
[Errno 13] Permission denied: Poetry Cache
```

**Процедура устранения:**

```cmd
# Очистка кеша Poetry
rmdir /S /Q "%LOCALAPPDATA%\pypoetry\Cache"

# Переустановка зависимостей без использования кеша
cd core
poetry install --no-cache
```

## Проблема 2: Команда ergoms не найдена

**Процедура устранения:**

```cmd
# PowerShell с повышением привилегий
.\core\deployment\windows\ergo_ms.ps1 install-cli
```

## Проблема 3: База данных не настроена

**Процедура устранения:**

1. Создайте конфигурационный дескриптор `databases.yaml` на основе шаблона `databases.yaml.example`
2. Определите параметры подключения к СУБД в соответствии с инфраструктурой
3. Примените миграции: `ergoms db-migrate`

