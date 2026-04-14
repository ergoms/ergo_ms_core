# Тестирование развертывания (Linux и Windows)

Набор скриптов для проверки установки, запуска и базовых команд системы. Реализации разделены по платформам (Linux — `.sh`, Windows — `.ps1`), при этом структура и смысл этапов максимально совпадают.

## Структура (Linux)

Папка: `core/deployment/linux/lib/test/`

- **`lib.sh`** — библиотека общих функций для тестов.
  - Логирование `log` и `step` с записью в общий журнал `logs/test.log` в корне репозитория.
  - `run_task`: запуск задач из `.vscode/tasks.json` (эмуляция запуска через VS Code).
  - Хелперы для остановки системы (`stop_all_ergoms`), работы со службами через `systemctl` (через `core/deployment/linux/lib/core.sh`), запуска всех worker-unit'ов из `celery_workers.yaml`.
  - Предпроверка окружения перед тестами запуска (`require_install_ready_for_launch`).

- **`install_test.sh`** — тесты установки.
  - Прогон установки через задачу `Setup Full System`.
  - Прогон установки через `ergoms setup`.
  - Установка всех служб (`ergoms install-all-services`) и по отдельности (`ergoms install-api-service`, `ergoms install-client-service`, `ergoms install-worker-service`, `ergoms install-beat-service`, `ergoms install-media-service`, `ergoms install-ollama-service`).

- **`run_test.sh`** — тесты запуска.
  - Запуск через задачу `Start All Services` (с фоновой стратегией для долгоживущих команд).
  - Запуск через `ergoms start`.
  - Отдельная проверка сервисов (api/media/client) через `systemctl`.
  - Проверка Celery-связки: API + beat + workers → `celery inspect ping` → `ergoms api show_next_tasks`.

- **`test.sh`** — главный скрипт-оркестратор: последовательно запускает этапы `install_test.sh` → `run_test.sh`.

## Структура (Windows)

Папка: `core/deployment/windows/lib/test/`

- **`lib.ps1`** — библиотека общих функций (логирование, запуск задач из `.vscode/tasks.json`, работа со службами Windows и процессами).
- **`install_test.ps1`** — тесты установки (аналогично Linux-этапу).
- **`run_test.ps1`** — тесты запуска (аналогично Linux-этапу).
- **`commands_test.ps1`** — тесты отдельных команд (например, `ergoms db-makemigrations`, `ergoms db-migrate`, `ergoms clean`, `ergoms logs ...`).
- **`test.ps1`** — главный скрипт-оркестратор, вызывает этапы установки/запуска/команд.
- **`README.md`** — описание Windows-ветки тестов (может содержать Windows-специфику, например про кодировку PowerShell 5.1).

## Запуск

- **Рекомендуемый способ (через `ergoms`, кроссплатформенно):** `ergoms test_system`
- **Linux:** `bash core/deployment/linux/lib/test/test.sh`
- **Windows:** из корня репозитория: `.\core\deployment\windows\lib\test\test.ps1`

Логи тестов пишутся в `logs/test.log` в корне проекта.
