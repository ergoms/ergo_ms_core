# ERGO MS

ERGO MS — модульный фреймворк для корпоративных веб-приложений. Ядро даёт общую инфраструктуру (авторизация, CMS, меню, файлы, фоновые задачи), а доменная логика подключается отдельными модулями в каталоге `modules/`.

Стек: Django 5 и DRF на сервере, Vue 3 и Vite на клиенте, PostgreSQL (или SQLite/MySQL) как основная БД, Celery для асинхронной работы, Poetry и npm для зависимостей.

## Документация

- [Архитектура](.docs/architecture.md) — как устроены ядро, модули и интеграции
- [Структура проекта](.docs/structure.md) — каталоги и конфигурационные файлы
- [Настройка .env и БД](.docs/configuration.md) — первичная конфигурация
- [Разработка](.docs/development.md) — запуск стенда и логи
- [Команды ergoms](.docs/cli.md) — справочник CLI
- [Проблемы при установке](.docs/troubleshooting.md) — типичные ошибки
- [Службы Linux](.docs/deployment.md) — systemd и production-подобный запуск

## Быстрый старт

Путь к проекту на диске должен содержать только латиницу, цифры, дефис и подчёркивание — без кириллицы и пробелов. Например: `C:\projects\ergo_ms\`.

Понадобятся Python 3.12, Node.js 18+, PostgreSQL 14+ и Git.

```cmd
git clone <repository-url> ergo_ms
cd ergo_ms
copy .env.example .env
copy databases.yaml.example databases.yaml
```

Отредактируйте `.env` и `databases.yaml` под свою среду — см. [configuration.md](.docs/configuration.md).

**Первая установка.** Пока утилита `ergoms` не установлена, выполните полную настройку скриптом:

Windows (один раз разрешите выполнение скриптов в PowerShell):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
.\core\deployment\windows\ergo_ms.ps1 setup-full
```

Linux:

```bash
sudo bash core/deployment/linux/ergo_ms.sh setup-full
```

Дальнейшие операции — только через **`ergoms`**. Быстрая установка зависимостей после настройки: `ergoms install-deps`.

**Запуск для разработки.** В Cursor или VS Code удобнее всего нажать **`Ctrl+Shift+B`** — поднимутся API, клиент, Celery и media_api. Альтернатива в терминале: `ergoms start-all` и в втором окне `ergoms start-client`.

После запуска:

- интерфейс: http://localhost:8001  
- API: http://localhost:8000  
- media_api: http://localhost:8003  

Подробнее о повседневной работе — в [development.md](.docs/development.md).
