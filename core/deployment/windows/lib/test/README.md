# Тестирование развёртывания (Linux и Windows)

Набор скриптов проверяет установку, запуск и базовые команды ERGO MS на обеих ОС. Структура на Linux (`.sh`) и Windows (`.ps1`) **одинакова по смыслу** — отличаются только оболочка и вызовы служб.

Документ для разработчиков deployment; конечному пользователю достаточно [`.docs/troubleshooting.md`](../../../../.docs/troubleshooting.md).

## Быстрый запуск

Рекомендуемый способ — одна команда ergoms:

```cmd
ergoms test_system
```

Альтернатива — запуск оркестратора напрямую:

- **Linux:** `bash core/deployment/linux/lib/test/test.sh`
- **Windows** (из корня репозитория): `.\core\deployment\windows\lib\test\test.ps1` — нужен префикс `.\`, иначе PowerShell не выполнит скрипт по относительному пути.

Весь вывод дублируется в **`logs/test.log`** в корне проекта.

## Из чего состоят тесты

### lib (`lib.sh` / `lib.ps1`)

Общая библиотека: логирование (`log`, `step`), запуск задач из `.vscode/tasks.json` (`run_task` / `Run-Task`), проверка Celery (`celery inspect ping`, `show_next_tasks`), остановка процессов перед прогоном (`stop_all_ergoms`).

### install_test

Проверяет установку: полную настройку через задачу VS Code «Setup Full System» (внутри — `setup-full`), `ergoms setup`, `ergoms install-all-services` и поочерёдную установку служб API, клиента, worker, beat, media и ollama (если модуль подключён).

### run_test

Проверяет запуск: задачу «Start All Services» (аналог `Ctrl+Shift+B`), `ergoms start`, отдельный запуск служб API, media и клиента, а также Celery — API, beat и workers с последующей проверкой `celery inspect ping` и `ergoms api show_next_tasks`.

### commands_test

Проверяет отдельные команды: миграции (`ergoms db-makemigrations`, `ergoms db-migrate`), `ergoms clean`, просмотр журналов (`ergoms logs ergo-api-dev 10`).

### test (`test.sh` / `test.ps1`)

Оркестратор: по очереди вызывает install, run, commands и остальные этапы.

## Задачи VS Code / Cursor

В `.vscode/tasks.json` заданы compound-задачи для IDE:

| Имя в tasks.json | Назначение |
|------------------|------------|
| Setup Full System | Первичная установка (`setup-full`) |
| Start All Services | Полный набор сервисов для разработки |

Их можно запустить из палитры команд (**Tasks: Run Task**) или через **`Ctrl+Shift+B`**, если задача назначена сборкой по умолчанию.

## Кодировка (Windows PowerShell 5.1)

Скрипты `.ps1` сохраняются в **UTF-8 с BOM**. Без BOM встроенный Windows PowerShell 5.1 часто читает файл в системной кодировке (например CP1251): кириллица в строках ломает разбор, в конце файла появляется ложная ошибка «Непредвиденная лексема `}`». В PowerShell 7+ BOM не обязателен.

## Типичные ошибки

| Симптом | Причина | Действие |
|---------|---------|----------|
| Скрипт не запускается на Windows | Нет `.\` перед путём | `.\core\deployment\windows\lib\test\test.ps1` |
| Ошибка парсинга `}` в `.ps1` | Файл без BOM, CP1251 | Сохранить UTF-8 with BOM |
| Тест завершается с ошибкой на Celery | Worker и beat с разными брокерами | Проверить `databases.yaml`, см. [`.docs/configuration.md`](../../../../.docs/configuration.md) |

## См. также

- [`.docs/troubleshooting.md`](../../../../.docs/troubleshooting.md)
- [`core/deployment/logic.md`](../../logic.md)
- [`.docs/cli.md`](../../../../.docs/cli.md)
