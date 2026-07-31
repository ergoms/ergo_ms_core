# ERGO MS Tasks

Расширение VS Code/Cursor для задач проекта:

- **multi-terminal** — несколько терминалов из одной задачи (как раньше);
- **ergo-module** — модульные задачи из `modules/<name>/vscode.tasks.yaml` в Run Task.

## Установка

```bash
# Linux/macOS
bash .vscode/extensions/tasks/install.sh

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File .vscode/extensions/tasks/install.ps1

# Или вместе с остальными расширениями
ergoms install-extensions
```

После установки **перезапустите VS Code/Cursor** (или Reload Window).

Прежнее расширение `ergo-ms-multi-terminal` при установке удаляется автоматически.

## Модульные задачи (Run Task)

Модуль объявляет задачи в `modules/<name>/vscode.tasks.yaml`. Расширение подхватывает файл для включённых модулей (есть `api/` или `client/`, нет в `DISABLED_MODULES`) и показывает их в **Terminal → Run Task** в группе **ERGO MS Modules** (тип `ergo-module`).

```yaml
module: module_template
tasks:
  - label: "Template: Migrate"
    detail: "Создать и применить миграции модуля-шаблона"
    command: "ergoms module_template:migrate"
```

| Поле | Описание |
|------|----------|
| `module` | Имя каталога; должно совпадать с папкой модуля |
| `label` | Имя в Run Task (уникально в workspace) |
| `detail` | Описание на русском |
| `command` | Только `ergoms …` |
| `panel` | `shared` (по умолчанию) или `new` |
| `hide` | `true` — не показывать в Run Task |

Предупреждения — канал **ERGO MS Module Tasks**. Корневой `.vscode/tasks.json` для модульных команд не расширяйте.

## Использование в tasks.json

Тип задачи в JSON по-прежнему `multi-terminal` (совместимость с существующими задачами ядра).

### Вариант 1: Динамический список из файла

```json
{
    "label": "Start All Workers",
    "type": "multi-terminal",
    "source": {
        "file": "celery_workers.yaml",
        "path": "workers"
    },
    "commandTemplate": "ergoms start-worker --worker=${key}",
    "nameTemplate": "Worker: ${key}",
    "group": "my-workers",
    "delay": 500
}
```

### Вариант 2: Статический список терминалов

```json
{
    "label": "Start Services",
    "type": "multi-terminal",
    "terminals": [
        {
            "name": "API Server",
            "command": "ergoms dev"
        },
        {
            "name": "Client",
            "command": "ergoms start-client"
        },
        {
            "name": "Worker",
            "command": "ergoms start-worker"
        }
    ],
    "group": "services",
    "delay": 300
}
```

## Параметры задачи

| Параметр | Тип | Описание |
|----------|-----|----------|
| `type` | string | Всегда `"multi-terminal"` |
| `source` | object | Источник данных из файла |
| `source.file` | string | Путь к YAML/JSON файлу |
| `source.path` | string | Путь к списку в файле (например: `workers` или `config.items`) |
| `commandTemplate` | string | Шаблон команды. `${key}` заменяется на ключ из source |
| `nameTemplate` | string | Шаблон имени терминала |
| `terminals` | array | Статический список терминалов (альтернатива source) |
| `terminals[].name` | string | Имя терминала |
| `terminals[].command` | string | Команда для выполнения |
| `terminals[].cwd` | string | Рабочая директория (опционально) |
| `group` | string | Группа терминалов для управления |
| `delay` | number | Задержка между запусками в мс (по умолчанию 300) |
| `hideControlTerminal` | boolean | Скрыть управляющий терминал (по умолчанию false) |

## Команды

- **ERGO MS: Stop All Terminals** (`Ctrl+Shift+P`)

## Поддерживаемые форматы файлов

- YAML (`.yaml`, `.yml`)
- JSON (`.json`)

## Пример файла celery_workers.yaml

```yaml
workers:
  gpu:
    description: "GPU worker"
    queues:
      - video_analysis
  cpu:
    description: "CPU worker"  
    queues:
      - data_processing
  parser:
    description: "Parser worker"
    queues:
      - parsing
```

При использовании `"path": "workers"` расширение создаст терминалы для: `gpu`, `cpu`, `parser`.

## Скрытие управляющего терминала

По умолчанию при запуске multi-terminal задачи создается управляющий терминал, который отображает статус запуска. Если вы хотите скрыть этот терминал и видеть только запущенные дочерние терминалы, используйте опцию `hideControlTerminal`:

```json
{
    "label": "Start All Workers",
    "type": "multi-terminal",
    "source": {
        "file": "celery_workers.yaml",
        "path": "workers"
    },
    "commandTemplate": "ergoms start-worker --worker=${key}",
    "nameTemplate": "Worker: ${key}",
    "group": "my-workers",
    "delay": 500,
    "hideControlTerminal": true
}
```
