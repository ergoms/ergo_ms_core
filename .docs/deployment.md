# Развёртывание системных служб (Linux)

На Linux ERGO MS можно зарегистрировать как набор служб **systemd**, чтобы API, клиент, Celery и media_api поднимались при старте сервера и перезапускались после сбоев. Для этого используется скрипт **`core/deployment/linux/ergo_ms.sh`**.

Путь к корню проекта задаётся переменной **`ERGO_ROOT`** в файле `/etc/default/ergo_ms` или передаётся флагом **`--root`** при установке.

## Установка и управление службами

Из корня репозитория (или с указанием `--root`):

```bash
sudo bash core/deployment/linux/ergo_ms.sh install [--root /var/www/ergo_ms]
sudo bash core/deployment/linux/ergo_ms.sh start
sudo bash core/deployment/linux/ergo_ms.sh stop
sudo bash core/deployment/linux/ergo_ms.sh restart
sudo bash core/deployment/linux/ergo_ms.sh status
sudo bash core/deployment/linux/ergo_ms.sh uninstall-services [--purge]
```

Команда **`install`** создаёт unit-файлы systemd и подготавливает окружение. **`uninstall-services`** снимает службы; с **`--purge`** удаляются и связанные данные конфигурации — используйте осторожно.

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
| `ergo-client-dev` | Vue-клиент (dev-сборка) |
| `ergo-celery-worker-all` | Celery worker |
| `ergo-celery-beat` | Celery beat |
| `ergo-media-api` | Media API |

Точные имена могут отличаться, если вы меняли конфигурацию worker'ов в `celery_workers.yaml`; список актуальных служб покажет `ergoms status`.

## Просмотр логов

Через systemd:

```bash
journalctl -u ergo-api-dev -n 500 -f
```

Через ergoms (если CLI установлен):

```bash
ergoms logs ergo-api-dev
```

Дополнительно файловые логи пишутся в каталог **`logs/`** в корне проекта — см. [development.md](development.md).

## Windows

Аналогичные сценарии для Windows описаны в **`core/deployment/windows/`** — там свои PowerShell-скрипты и службы. Принцип тот же: сначала `setup-full` или `install`, затем управление через ergoms.
