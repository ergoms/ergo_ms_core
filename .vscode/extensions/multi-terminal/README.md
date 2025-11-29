# Multi-Terminal Tasks

Расширение VS Code/Cursor для запуска нескольких терминалов из одной задачи.

## Установка

```bash
# Linux/macOS
bash .vscode/extensions/multi-terminal/install.sh

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File .vscode/extensions/multi-terminal/install.ps1

# Или через ergoms
ergoms install-multi-terminal
```

После установки **перезапустите VS Code/Cursor**.

## Использование в tasks.json

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

- **Multi-Terminal: Остановить все терминалы** (`Ctrl+Shift+P`)

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

