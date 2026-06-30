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

Утилита ergoms ставится на шаге **setup-full** при первичной настройке. Если терминал её не видит, установите CLI отдельно:

Windows (PowerShell):

```cmd
.\core\deployment\windows\ergo_ms.ps1 install-cli
```

Linux:

```bash
sudo bash core/deployment/linux/ergo_ms.sh install-cli
```

Либо повторите полную настройку из README — `setup-full` создаст окружение, зависимости и обёртку ergoms.

## База данных

Если API падает с ошибкой подключения к PostgreSQL:

1. Убедитесь, что файл **`databases.yaml`** создан из примера и параметры `host`, `port`, `user`, `password`, `name` соответствуют вашей СУБД.
2. Создайте пустую базу с указанным именем, если её ещё нет.
3. Выполните **`ergoms db-migrate`**.

## Медленный первый запуск API

При первом запуске система строит кэши списка приложений, модулей и конфигурации Celery. Это нормально. Ускорить можно явным прогревом:

```cmd
ergoms warmup-caches
```

Команда **`ergoms dev`** сама вызывает прогрев, если кэш пустой или устарел — отдельно вызывать не обязательно.
