# Тестирование развертывания (Linux и Windows)

Набор тестов для проверки установки, запуска и базовых команд системы. Тесты разделены на платформы (Linux — скрипты `.sh`, Windows — скрипты `.ps1`), но имеют полностью аналогичную структуру и логику.

Всё разбито на логические модули:

1. **`lib`** (`lib.sh` / `lib.ps1`) — библиотека общих функций.
   - Содержит функции логирования `log` и `step` (с автоматической записью в общий журнал `logs/test.log`).
   - Функция `run_task` / `Run-Task` парсит `.vscode/tasks.json` и запускает команды (эмулируя запуск через VS Code).
   - Функции для работы со службами (`systemctl` в Linux / `Get-Service` в Windows) и Celery (`celery inspect ping`, `show_next_tasks`).
   - Функции для очистки процессов перед тестами (`stop_all_ergoms`).

2. **`install_test`** (`install_test.sh` / `install_test.ps1`) — тесты установки:
   - Установка через `Setup Full System` (`setup-full`).
   - Установка через команду `ergoms setup`.
   - Установка всех служб сразу (`ergoms install-all-services`).
   - Поочередная установка каждой службы (`install-api-service`, `install-client-service`, `install-worker-service`, `install-beat-service`, `install-media-service`, `ollama_framework:install-ollama-service`).

3. **`run_test`** (`run_test.sh` / `run_test.ps1`) — тесты запуска:
   - Запуск через задачу `Start All Services` (аналог ctrl+shift+b).
   - Запуск через команду `ergoms start`.
   - Отдельный запуск каждого сервиса (api, media, client) через системные службы.
   - Тестирование Celery: запуск API, Beat и всех установленных воркеров, после чего выполняется `celery inspect ping` (проверка связи брокера и воркера) и `ergoms api show_next_tasks` (проверка расписания).

4. **`commands_test`** (`commands_test.ps1` и аналоги) — тесты отдельных команд:
   - Создание и применение миграций (`ergoms db-makemigrations`, `ergoms db-migrate`).
   - Очистка кэша (`ergoms clean`).
   - Проверка логов (например, `ergoms logs ergo-api-dev 10`).

5. **`test`** (`test.sh` / `test.ps1`) — главный скрипт-оркестратор, который поочерёдно вызывает все этапы тестирования (`install_test`, `run_test` и т.д.).

## Запуск

Для полного тестирования достаточно запустить главный скрипт-оркестратор:

- **Рекомендуемый способ (через `ergoms`, кроссплатформенно):** `ergoms test_system`
- **Linux:** `bash core/deployment/linux/lib/test/test.sh`
- **Windows:** из корня репозитория: `.\core\deployment\windows\lib\test\test.ps1` (нужен префикс `.\`, иначе PowerShell не выполнит скрипт по относительному пути).

Весь процесс (установка, запуск, команды) пройдёт автоматически с дублированием вывода в файл `logs/test.log` в корне проекта.

### Кодировка (Windows PowerShell 5.1)

Скрипты `.ps1` сохраняются в **UTF-8 с BOM**. Без BOM встроенный Windows PowerShell 5.1 часто читает файл в системной кодировке (например CP1251), из‑за чего кириллица в строках ломает разбор и в конце файла появляется ложная ошибка «Непредвиденная лексема `}`». В PowerShell 7+ BOM не обязателен.
