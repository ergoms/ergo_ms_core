<!-- Сгенерировано .codex/scripts/sync_codex_rules.py. Не редактировать. -->

# Правила проекта для Codex

Перед работой сверься с [оглавлением правил](rules/rules-index.md). Хуки Codex подключают правила с `globs` по явным путям в запросах и вызовах инструментов. Если путь обнаружен впервые в `apply_patch`, хук откладывает правку до подгрузки правил. Открой правило из оглавления, если оно подходит по описанию или путь не распознан. Если оглавления ещё нет, создай копии и оглавление командой `python3 -B .codex/scripts/sync_codex_rules.py --runtime-only` из корня проекта.

При работе в модуле также прочитай его `AGENTS.md`, если он есть. Перед подготовкой сообщения коммита прочитай [`.cursorrules`](../.cursorrules).

При запуске из Git-подмодуля добавь параметр `-c 'project_root_markers=[".codex-project-instructions"]'` к команде `codex`, чтобы Codex прочитал общие правила вместе с `AGENTS.md` модуля.

Меняй правила в исходных `.mdc` и пересобирай их командой `python3 -B .codex/scripts/sync_codex_rules.py`. При старте сессии Codex обновляет копии и оглавление через хук `SessionStart`.

[Копия правила](rules/chat-style.md)

# Тон ответов в чате

Пиши по-русски обычными предложениями, как коллеге. Смысл важнее краткости. Не заменяй глаголы цепочками «A — B: C» и ярлыками «Итог», «Суть», «Сделано».

Английский оставляй в именах кода, командах и устоявшихся названиях (Django, Vue, PostgreSQL, Celery, JWT, `ergoms`, `public_id`). В речи бери русский эквивалент: настройка, запасной вариант, обходной путь, развёртывание, значение по умолчанию. Части приложения — **сервер** и **клиент**.

Когда рассказываешь, что сделано, называй поведение, флаги и адреса, а не «улучшено» или «добавлены настройки». Не пиши фон, который не спросили. Статус процесса — только факты, см. [`status-reports.mdc`](../.cursor/rules/status-reports.mdc).

Документацию пиши по [`writing-docs-and-rules.mdc`](../.cursor/rules/writing-docs-and-rules.mdc). Текст коммита — [`.cursorrules`](../.cursorrules), куда класть — [`git-commits.mdc`](../.cursor/rules/git-commits.mdc).

```text
Плохо: Сделано: лимит загрузок — отдельно user/admin; nginx — по admin.
Хорошо: Теперь у обычного пользователя и у администратора разные лимиты частоты загрузок. Для /upload/ nginx берёт более широкий лимит администратора.
```

[Копия правила](rules/clarifying-questions.md)

# Уточняющие вопросы

Если цель, объём или критерий готовности неясны, сначала уточни, потом действуй. То же при равноценных вариантах с разными компромиссами, при противоречии правилам и перед необратимым шагом: удаление, force push, смена схемы БД, commit или push без просьбы.

Не спрашивай, если ответ есть в коде, правилах, `BEHAVIOR.md` или в этом чате, либо есть обычный для ERGO MS способ (ergoms, ModuleBridge, `tokenStorage`). Мелочь реализации выбери сам и коротко назови её. Сначала посмотри репозиторий, потом задай конкретный вопрос.

Спрашивай 1–3 вопроса. При двух чётких вариантах используй `AskQuestion`. Если можно идти с допущением, напиши его и спроси, подходит ли оно.

Исключение по безопасности молча не делай — см. [`security.mdc`](../.cursor/rules/security.mdc).

[Копия правила](rules/code.md)

# Общие правила кода

- Тесты и точечные правки — только по просьбе. Правки развёртывания, `commands.conf`, служб, docker/nginx и security стека сопровождай `ergoms system-test` — [`system-test.mdc`](../.cursor/rules/system-test.mdc).
- Файл не длиннее 700 строк. Режь по ответственности, не по номеру строки. Общие константы — в один модуль. Импорты именованные и вверху файла. Не обрывай `def` или `class` посередине.
- Повторяющийся сценарий выноси в общий класс. Тяжёлую работу отдавай Celery. Часовой расчёт не запускай в shell Cursor — [`long-running-jobs.mdc`](../.cursor/rules/long-running-jobs.mdc).
- Данные приложения пиши внутри корня репозитория, не в `/tmp` и `/etc` — [`project-root-artifacts.mdc`](../.cursor/rules/project-root-artifacts.mdc).
- В командах и логах без эмодзи. После задачи убери мёртвый код и неиспользуемые импорты.
- `request.user` в сериализаторе бери через `SwaggerSafeSerializerMixin.get_safe_user()`. Новый ViewSet — `BaseModelViewSet`, фильтр выборки в `get_queryset` или `owner_field`.
- Комментарий объясняет «почему». Подробности API — [`api_code.mdc`](../.cursor/rules/api_code.mdc).

[Копия правила](rules/core-module-isolation.md)

# Изоляция ядра от модулей

Ядро (`core/api`, `core/client`, `core/media_api`, `core/deployment`) не знает домен модулей. Связь — ModuleBridge и hook discovery. Проверка: `ergoms core-rules-check`. Каталог hook’ов — [`modules.mdc`](../.cursor/rules/modules.mdc), контракты — [`module-contracts.mdc`](../.cursor/rules/module-contracts.mdc).

- Нет `from modules.<имя>...` и static import из `modules/` в бизнес-коде ядра.
- Нет имён установленных модулей в runtime, комментариях и docstring ядра и `.cursor/rules/` — только `<name>`.
- Нет зашитых JWT claim, моделей и маршрутов модуля. Ядро кладёт произвольный dict claims.
- Данные модуля в сценарии ядра идут через platform-контракт и `bridge.call` или hook.
- Связь только модуль↔модуль не клади в каталог ядра. Имена контрактов ядра — `session.*`, `audit.*`, `core.*`.

```python
# GOOD
restore_claims = bridge.call(SESSION_RESTORE_CLAIMS, user=user) or {}
# BAD
from modules.<name>.api.models import SomeEntity
```

Новая связь ядро↔модуль начинается с константы в каталоге. Доменный loader модуля живёт в `modules/<name>/`.

[Копия правила](rules/docs.md)

# Документирование в репозитории

Новые README, INSTALL, CHANGELOG, схемы и docstring к понятному коду пиши только по просьбе.

Без отдельной просьбы можно править уже существующий документ, короткий README в `core/api/`, `core/client/`, `core/media_api/`, документацию модуля при правке `modules/<name>/` (`AGENTS.md`, `.mdc`, `README.md`, `ergoms.help.yaml` — [`module-docs.mdc`](../.cursor/rules/module-docs.mdc)) и норму в `BEHAVIOR.md` ([`module-behavior.mdc`](../.cursor/rules/module-behavior.mdc)).

Людям — [`.docs/`](../.docs/). Агенту — `.cursor/rules/`. Коммит — [`.cursorrules`](../.cursorrules) и [`git-commits.mdc`](../.cursor/rules/git-commits.mdc). Стиль — [`writing-docs-and-rules.mdc`](../.cursor/rules/writing-docs-and-rules.mdc) и [`docs-prose.mdc`](../.cursor/rules/docs-prose.mdc). При правке онбординга или безопасности сверь [`core/.github`](../core/.github/).

[Копия правила](rules/git-commits.md)

# Куда коммитить

«Закоммить» не значит коммит в корне workspace. Сначала `git -C <каталог_файла> rev-parse --show-toplevel`. Коммит и push — только в репозитории файла. Текст сообщения — [`.cursorrules`](../.cursorrules).

Обёртка `ergo_ms`: `.cursor/rules/`, `.docs/`, `core/deployment/`, `.gitmodules`, корневые `.gitignore`, `.cursorrules`, примеры env. Свой репозиторий: `core/api`, `core/client`, `core/media_api`, `core/.github`, `modules/<name>`. В `.gitmodules` стоит `ignore = all`: обёртка не фиксирует каждый новый SHA.

Два репозитория — два коммита. Указатель submodule (`git add core/client`, `git add modules/<name>`) обновляй только если пользователь просит закрепить SHA. Не смешивай в одном коммите обёртки её файлы и смену SHA. Не обновляй указатель следом за коммитом в submodule.

[Копия правила](rules/no-direct-manage-py.md)

# Команды — только через ergoms

Миграции, запуск, зависимости, сборка, Celery и статика — только `ergoms`. Не предлагай `python manage.py`, `pip`, `poetry` и `npm` как основной способ. Справочник — [`.docs/cli.md`](../.docs/cli.md), формат — [`ergoms-commands.mdc`](../.cursor/rules/ergoms-commands.mdc).

| Задача | Команда |
|---|---|
| Настройка | `ergoms setup` |
| Миграции | `ergoms migrate-all` / `db-migrate` / `db-makemigrations` |
| API / клиент | `ergoms dev` / `start-client` |
| Сборка клиента | `ergoms client-build` |
| Celery | `ergoms start-worker` / `start-beat` |
| Зависимости | `ergoms python-install`, `ergoms npm install` |
| Django | `ergoms api <команда>` |

Модуль: `ergoms <имя>:<команда>`. Не правь `manage.py`, чтобы обойти ergoms. Метки CLI — `[OK]` / `[ERROR]`, текст — `t('key')` ([`console-output.mdc`](../.cursor/rules/console-output.mdc)).

Одно окружение: portable CPython в `virtual_env/packages/python/`, venv в `virtual_env/python/` (`bin/python` на Linux, `Scripts/python.exe` на Windows). Node — `virtual_env/packages/nodejs/`, npm workspace — `virtual_env/npm/` ([`npm-workspace.mdc`](../.cursor/rules/npm-workspace.mdc)). Не создавай `.venv`, не ставь пакеты мимо ergoms и не удаляй `virtual_env/` целиком. Если Python не найден: `ergoms install-python`, затем `ergoms python-install`. Подробности путей — [`virtual-env.mdc`](../.cursor/rules/virtual-env.mdc).

[Копия правила](rules/no-host-fingerprint.md)

# Без отпечатка хоста в репозитории

В коде, комментариях, `.env.example`, README, правилах Cursor и help не описывай конкретное железо и «текущий» сервер. Это только локальный `.env` или runbook вне git.

Допустимы нейтральные ориентиры: «при нехватке RAM», «на CPU медленнее», «подстройте под свою машину». Не пиши объём RAM, число ядер, модель GPU, тип диска и hostname как факт среды.

```dotenv
# BAD: на этом сервере только CPU, large на 32 ГБ нецелесообразен
# GOOD: устройство inference — cpu | cuda | auto; large тяжелее base
```

[Копия правила](rules/security.md)

# Безопасность ERGO MS

Перед правками auth, API, прав, файлов, env, CORS, cookies или логов сверься с этим правилом. Примеры — [`security-details.mdc`](../.cursor/rules/security-details.mdc).

- Секреты только в `.env`, не в коде, git и чате. Серверные ключи не попадают в бандл клиента.
- Токены и контекст сессии — через `tokenStorage.js`, не в localStorage. JWT не в query WebSocket.
- Снаружи `public_id` (UUID), не числовой id из БД: ни в URL, ни в query, ни в browser storage.
- API проверяет права сам. Эндпоинт по умолчанию требует JWT (`BaseAPIView` / `BaseModelViewSet`). Публичный — только `BaseAPIViewPublicMixin` и строка в allowlist.
- Файлы — через media_api, не `/media/` на основном API.
- Ошибки клиента — `logError`, не `console.error` объекта axios. В логах API нет credentials.
- Prod: `DEBUG=False`, cookies HttpOnly, Secure и SameSite, без sourcemap.
- Железо хоста в git не пиши — [`no-host-fingerprint.mdc`](../.cursor/rules/no-host-fingerprint.mdc). Исключение по безопасности молча не делай.

[Копия правила](rules/struct.md)

# Архитектура ERGO MS

Сервер — Django (`core/api/`), клиент — Vue (`core/client/`). Ядро: `api/`, `client/`, `media_api/` и `deployment/`. Модули — `modules/<имя>/` (submodule). Community-тексты — `core/.github`. После clone: `git submodule update --init --recursive`.

Связь модуль↔модуль и ядро↔домен модуля — только ModuleBridge и hook-файлы с фиксированным именем. Каталог — [`modules.mdc`](../.cursor/rules/modules.mdc). Вынос процесса — [`modularization.mdc`](../.cursor/rules/modularization.mdc). Режимы — корневой `.env`, детали — [`env-examples.mdc`](../.cursor/rules/env-examples.mdc).

В ядре запрещены `from modules.<имя>.api...`, имена установленных модулей даже в комментариях, static import страниц модуля и обход моста. Проверка — `ergoms core-rules-check`. Изоляция подробнее — [`core-module-isolation.mdc`](../.cursor/rules/core-module-isolation.mdc).
