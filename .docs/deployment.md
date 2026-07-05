# Развёртывание системных служб (Linux)

На Linux ERGO MS можно зарегистрировать как набор служб **systemd**, чтобы API, клиент, Celery и media_api запускались при старте сервера и перезапускались после сбоев. Для этого используется скрипт **`core/deployment/linux/ergo_ms.sh`**.

Путь к корню проекта задаётся переменной **`ERGO_ROOT`** в файле `/etc/default/ergo_ms` или передаётся флагом **`--root`** при установке.

## Установка и управление службами

Из корня репозитория (или с указанием `--root`) выполните нужную команду:

```bash
sudo bash core/deployment/linux/ergo_ms.sh install [--root /var/www/ergo_ms]
sudo bash core/deployment/linux/ergo_ms.sh start
sudo bash core/deployment/linux/ergo_ms.sh stop
sudo bash core/deployment/linux/ergo_ms.sh restart
sudo bash core/deployment/linux/ergo_ms.sh status
sudo bash core/deployment/linux/ergo_ms.sh uninstall-services [--purge]
```

Команда **`install`** создаёт unit-файлы systemd и подготавливает окружение. **`uninstall-services`** снимает службы; с **`--purge`** удаляются и связанные данные конфигурации — используйте её только если уверены, что конфигурацию можно удалить.

Чтобы вызывать **`ergoms`** из любого каталога под sudo:

```bash
sudo bash core/deployment/linux/ergo_ms.sh install-cli
sudo ergoms start
sudo ergoms status
```

## Имена служб

| Служба systemd | Компонент |
|----------------|-----------|
| `ergo-api-dev` | Django API |
| `ergo-client-dev` | Vue-клиент (режим разработки) |
| `ergo-celery-worker-all` | Celery worker |
| `ergo-celery-beat` | Celery beat |
| `ergo-media-api` | Media API |

Точные имена могут отличаться, если вы меняли конфигурацию исполнителей в `celery_workers.yaml`; список актуальных служб покажет `ergoms status`.

## Просмотр логов

Через systemd:

```bash
journalctl -u ergo-api-dev -n 500 -f
```

Через ergoms, если утилита установлена:

```bash
ergoms logs ergo-api-dev
```

Дополнительно файловые журналы пишутся в каталог **`logs/`** в корне проекта — см. [development.md](development.md).

## Windows

Аналогичные сценарии для Windows описаны в **`core/deployment/windows/`** — там свои PowerShell-скрипты и службы. Сначала выполните полную первичную настройку (`setup-full`) или установку служб (`install`), затем управляйте ими через ergoms.

## См. также

| Вопрос | Документ |
|--------|----------|
| Запуск для разработки (без служб) | [development.md](development.md) |
| Справочник команд ergoms | [cli.md](cli.md) |
| Если служба не запускается | [troubleshooting.md](troubleshooting.md) |
