# Локальная серия и сохранённый остаток — 21.10.2026

Срез Git-состояния: 21.10.2026 20:13:30 (Москва).

Работа выполнена локально. SSH, production и push не использовались. Исходная
ревизия обёртки — `3aec711`. Отменённый `201330bc` не является предком текущего HEAD.
Локальное изменение правила коммитов сохранено с исходным SHA256 и не включено в серию.

Кодовая часть ближайшей поставки и адаптеры A оформлены коммитами. Полная приёмка A
остаётся открытой: чистая установка и повторный setup Windows/Linux не подтверждены.
Большой diff BI и остальные перечисленные ниже файлы остаются самостоятельным
локальным остатком. Рабочие BI-тесты не заменяют проверку его будущего точного коммита.

## Состав серии

Ниже 14 предшествующих коммитов. Этот реестр и текущий статус runtime
составляют завершающий отдельный docs-коммит.

| Репозиторий | Коммит | Изменение |
|---|---|---|
| `modules/crm` | `6b3f325` | refactor: LibreOffice устанавливается общим реестром с сохранением прежней команды. |
| `modules/education_materials_parser` | `f024a99` | refactor: Tesseract устанавливается общим реестром; прежний адаптер и модельные объявления совместимы. |
| `modules/vacancies_parser` | `1c1360d` | refactor: Chrome и chromedriver используют общий установщик с сохранением CLI. |
| `modules/ollama_framework` | `d1bb1f5` | refactor: Установка Ollama использует общий реестр, а модели читаются из runtime_requirements и прежних hook-файлов. |
| `ergo_ms` | `a4e4bb6` | fix: Изолированный профиль проверяется до операций развёртывания, подключения к БД и резервного копирования. |
| `core/api` | `82a5c8b` | fix: Декларативная изоляция ресурсов проверяется до загрузки Django settings и приложений. |
| `modules/organizations` | `f556045` | fix: Bridge возвращает сериализуемый public_id организации для потребителей. |
| `ergo_ms` | `7536d49` | fix: Отсутствующий gitlink organizations закреплён на проверенной ревизии. |
| `modules/crm_remastered` | `6f25bd1` | fix: Восстановление меню до миграций announcements больше не запускает засев её таблиц. |
| `modules/lms` | `59782f5` | fix: Зачисления и учебные результаты читают свою версию курса, сохраняют историю и не дублируются при повторном запросе. |
| `ergo_ms` | `c3593a9` | fix: globals объявлен для ESLint, полный npm lock согласован с зависимостями ядра. |
| `modules/lms` | `122d456` | feat: Преподаватель управляет черновиками и политикой завершения, а обучающийся видит результат своего зачисления. |
| `modules/lms` | `688a4ff` | feat: Отдельный пилот LMS готовится командой lms:pilot; SQL и media проверяются и восстанавливаются только в пустую изолированную среду. |
| `ergo_ms` | `1b4fe24` | docs: Аудит BI сохранён как исторический план с отдельной отметкой текущего состояния. |

В ядре оставлена нейтральная проверка декларативного профиля до Django, Compose,
нагрузочных и SQL-команд. Доменные ограничения, упаковка, HTTP-нагрузка, media,
закреплённые образы, npm-набор и SQL/media-восстановление принадлежат LMS.
Каноническая команда — `ergoms lms:pilot`; неопубликованной команды `lms-pilot` в ядре нет.

Общие `db-backup/db-restore` сохраняют SQL-контракт. Снимки пилота находятся в
`virtual_env/backups/lms/`, поэтому обычная SQL-ротация их не затрагивает.
Восстановление принимает только полностью проверенный снимок и пустую изолированную БД/media.
При сбое писатели остаются остановленными. SQL commit и публикация media не имеют
общей транзакции: ошибка после SQL commit записывается как failed и требует нового
пустого назначения. Частичное восстановление не считается успешным.

Core npm lock восстановлен отдельно от lock пилота. `globals` объявлен явно;
версии остальных записей сохранены из исходного графа, за исключением datepicker:
корневая декларация `^12` закреплена как 12.1.0; общий lock пилота сохраняет модульную
версию 14. Диапазоны остальных зависимостей не менялись. Чистый npm ci этого графа
не подтверждён из-за кэша/сети; сборки выполнялись с существующими установленными пакетами.

### Файлы по коммитам

<details><summary>modules/crm · 6b3f325</summary>

```text
modules/crm/README.md
modules/crm/deployment/install_libreoffice.py
modules/crm/packages.yaml
modules/crm/runtime_requirements.yaml
```

</details>

<details><summary>modules/education_materials_parser · f024a99</summary>

```text
modules/education_materials_parser/README.md
modules/education_materials_parser/deployment/install_tesseract.py
modules/education_materials_parser/packages.yaml
modules/education_materials_parser/runtime_requirements.yaml
modules/education_materials_parser/api/kag/tests/test_install_tesseract.py
```

</details>

<details><summary>modules/vacancies_parser · 1c1360d</summary>

```text
modules/vacancies_parser/README.md
modules/vacancies_parser/deployment/install_chrome.py
modules/vacancies_parser/packages.yaml
modules/vacancies_parser/runtime_requirements.yaml
```

</details>

<details><summary>modules/ollama_framework · d1bb1f5</summary>

```text
modules/ollama_framework/README.md
modules/ollama_framework/AGENTS.md
modules/ollama_framework/.cursor/rules/ollama-framework.mdc
modules/ollama_framework/deployment/install_ollama.py
modules/ollama_framework/deployment/ollama_models_loader.py
modules/ollama_framework/packages.yaml
modules/ollama_framework/runtime_requirements.yaml
modules/ollama_framework/tests/test_runtime_requirements.py
```

</details>

<details><summary>ergo_ms · a4e4bb6</summary>

```text
core/deployment/project_isolation.py
core/deployment/tests/test_project_isolation.py
core/deployment/docker/Dockerfile.python
core/deployment/docker/docker_cli.py
core/deployment/lifecycle/docker/ops.py
core/deployment/lifecycle/runner.py
core/deployment/scripts/backup_database.py
core/deployment/scripts/db_backup_common.py
core/deployment/scripts/loadtest.py
core/deployment/locales/ru/cli_messages.yaml
core/deployment/locales/en/cli_messages.yaml
core/deployment/locales/fr/cli_messages.yaml
```

</details>

<details><summary>core/api · 82a5c8b</summary>

```text
core/api/src/config/__init__.py
```

</details>

<details><summary>modules/organizations · f556045</summary>

```text
modules/organizations/api/integrations.py
modules/organizations/api/test_bridge_organization.py
```

</details>

<details><summary>ergo_ms · 7536d49</summary>

```text
modules/organizations
```

</details>

<details><summary>modules/crm_remastered · 6f25bd1</summary>

```text
modules/crm_remastered/api/migrations/0017_engineering_case.py
modules/crm_remastered/api/test_engineering_case_migration.py
modules/crm_remastered/integrations.yaml
```

</details>

<details><summary>modules/lms · 59782f5</summary>

```text
modules/lms/api/admin_lms.py
modules/lms/api/analytics.py
modules/lms/api/apps.py
modules/lms/api/audit.py
modules/lms/api/base_views.py
modules/lms/api/calendar_context.py
modules/lms/api/certificate_service.py
modules/lms/api/course_catalog.py
modules/lms/api/course_offering_service.py
modules/lms/api/course_structure.py
modules/lms/api/course_version_models.py
modules/lms/api/course_version_service.py
modules/lms/api/hr_reports.py
modules/lms/api/learning.py
modules/lms/api/learning_content.py
modules/lms/api/learning_items.py
modules/lms/api/learning_path_models.py
modules/lms/api/learning_paths.py
modules/lms/api/learning_resources.py
modules/lms/api/learning_workspace.py
modules/lms/api/legacy_access.py
modules/lms/api/models.py
modules/lms/api/progress.py
modules/lms/api/progress_service.py
modules/lms/api/reports.py
modules/lms/api/resources.py
modules/lms/api/scenario_tests.py
modules/lms/api/services.py
modules/lms/api/student_achievements.py
modules/lms/api/student_competencies.py
modules/lms/api/student_course_detail.py
modules/lms/api/student_dashboard.py
modules/lms/api/student_results.py
modules/lms/api/teacher.py
modules/lms/api/teacher_workspace.py
modules/lms/api/test_analytics.py
modules/lms/api/tests.py
modules/lms/api/urls.py
modules/lms/api/viewsets_assessment.py
modules/lms/api/viewsets_catalog.py
modules/lms/api/viewsets_structure.py
modules/lms/api/completion_policy.py
modules/lms/api/course_content_resolver.py
modules/lms/api/course_version_clone.py
modules/lms/api/course_versions.py
modules/lms/api/csv_safe.py
modules/lms/api/enrollment_guard.py
modules/lms/api/gradebook.py
modules/lms/api/result_calculator.py
modules/lms/api/result_scope.py
modules/lms/api/retention.py
modules/lms/api/test_course_version_isolation.py
modules/lms/api/test_enrollment_access.py
modules/lms/api/test_pilot_safety.py
modules/lms/api/test_result_enrollments.py
modules/lms/api/test_sprint2.py
modules/lms/api/test_sprint3.py
modules/lms/api/management/commands/generate_lms_data.py
modules/lms/api/management/commands/backfill_lms_result_enrollments.py
modules/lms/api/management/commands/check_lms_draft_graphs.py
modules/lms/api/migrations/0014_theme_course_version.py
modules/lms/api/migrations/0015_enrollment_result_links.py
modules/lms/api/migrations/0016_fill_enrollment_public_ids.py
modules/lms/api/migrations/0017_sprint2_versions_and_results.py
modules/lms/api/migrations/0018_resource_file_path_length.py
```

</details>

<details><summary>ergo_ms · c3593a9</summary>

```text
virtual_env/npm/package.json
virtual_env/npm/package-lock.json
```

</details>

<details><summary>modules/lms · 122d456</summary>

```text
modules/lms/client/Courses/CourseRouterView.vue
modules/lms/client/Courses/LmsCourseEnrollmentPanel.vue
modules/lms/client/Courses/LmsCourseOfferingsPanel.vue
modules/lms/client/Courses/StudentCourseView.vue
modules/lms/client/Courses/StudentCoursesView.vue
modules/lms/client/Courses/StudentLearningItemModal.vue
modules/lms/client/Courses/TeacherCourseView.vue
modules/lms/client/Courses/MyLearningView.vue
modules/lms/client/Courses/TeacherVersionsPanel.vue
modules/lms/client/LessonsManagement/LearningResourceEditor.vue
modules/lms/client/LessonsManagement/CourseCompletionPolicy.vue
modules/lms/client/Dashboard/HRDashboardView.vue
modules/lms/client/Competencies/CompetencyMapView.vue
modules/lms/client/composables/useCompetencyMap.js
modules/lms/client/composables/useCourseEnriched.js
modules/lms/client/js/endpoints.js
modules/lms/client/js/locales.js
modules/lms/client/js/routes.js
modules/lms/client/js/sprint2Locales.js
modules/lms/client/js/sprint3Locales.js
```

</details>

<details><summary>modules/lms · 688a4ff</summary>

```text
modules/lms/ergoms.conf
modules/lms/ergoms.help.yaml
modules/lms/loadtest.yaml
modules/lms/api/pilot_dataset.py
modules/lms/api/test_pilot_dataset.py
modules/lms/api/management/commands/export_lms_pilot_dataset.py
modules/lms/api/management/commands/verify_lms_restore.py
modules/lms/client/tests/pilot.spec.js
modules/lms/client/tests/playwright.config.js
modules/lms/docs/PILOT.md
modules/lms/docs/RUNBOOK.md
modules/lms/docs/RELEASE.md
modules/lms/docs/QA_STATUS.md
modules/lms/deployment/__init__.py
modules/lms/deployment/pilot/backup.py
modules/lms/deployment/pilot/cli.py
modules/lms/deployment/pilot/http.py
modules/lms/deployment/pilot/images.json
modules/lms/deployment/pilot/load.py
modules/lms/deployment/pilot/media.py
modules/lms/deployment/pilot/media_archive.py
modules/lms/deployment/pilot/npm_install.mjs
modules/lms/deployment/pilot/npm_lock.mjs
modules/lms/deployment/pilot/npm_runtime.py
modules/lms/deployment/pilot/safety.py
modules/lms/deployment/pilot/server_tests.py
modules/lms/deployment/pilot/__init__.py
modules/lms/deployment/tests/pilot_test_bootstrap.py
modules/lms/deployment/tests/test_media_backup.py
modules/lms/deployment/tests/test_pilot_backup.py
modules/lms/deployment/tests/test_pilot_dependencies.py
modules/lms/deployment/tests/test_pilot_freeze.py
modules/lms/deployment/tests/test_pilot_http.py
modules/lms/deployment/tests/test_pilot_load.py
modules/lms/deployment/tests/test_pilot_npm_lock.py
modules/lms/deployment/tests/test_pilot_npm_platforms.py
modules/lms/deployment/tests/test_pilot_npm_runtime.py
modules/lms/deployment/tests/test_pilot_policy.py
modules/lms/deployment/pilot/npm/package-lock.json
modules/lms/deployment/pilot/npm/package.json
```

</details>

<details><summary>ergo_ms · 1b4fe24</summary>

```text
.docs/bi-analysis-audit.md
```

</details>

## Проверки

| Проверка | Фактический результат |
|---|---|
| Развёртывание, полная рабочая копия | 603 теста: OK, 1 SKIP |
| Развёртывание, точный Git-индекс в отдельной копии | 603 теста: OK, 1 SKIP |
| Серверный кандидат LMS/CRM/organizations на PostgreSQL | 112 тестов: OK |
| Пилот LMS, рабочая копия и точный кандидат | 33 теста в каждом прогоне: OK |
| BI и связанные регрессии ядра с новым временным кэшем | 159 тестов: OK, 1 SKIP |
| BI со штатным кэшем после предусмотренного прогрева | 134 теста: OK, 1 SKIP |
| Ollama | 16 тестов: OK |
| OCR-адаптер | 3 теста: OK |
| Bridge public_id организации | 2 теста: OK; также включены в интеграционный кандидат |
| Реальные runtime-декларации | runtime-check: OK, четыре обязательных инструмента |
| Корневые Poetry/npm lock | lock-check: OK, утечек модулей нет |
| ESLint LMS и BI, без исправлений | 0 ошибок, 522 предупреждения; правила не ослаблялись |
| Клиент, рабочая копия и точный кандидат | Обе сборки прошли; предупреждения о крупных chunks |
| Playwright точного кандидата | Обнаружены 4 исходных сценария; живой браузерный прогон не выполнен |
| Архитектура полной копии | 5 прежних ошибок размера документов CRM; новых не обнаружено |
| system-test install/security/commands с Docker | SKIP: локальный Docker недоступен |
| system-test scenarios, docker_direct | SKIP: нет доступного Docker/окружения сценария |
| system-test install с native host | Не запускался: Windows setup меняет CurrentUser execution policy и установку CLI; для приёмки нужна одноразовая среда |
| Чистый npm ci в отдельном каталоге | Offline: ENOTCACHED для yargs; сетевой повтор: ECONNRESET |

Тестовые PostgreSQL-БД получали уникальные имена; существующие тестовые БД не пересоздавались.
В финальном серверном кандидате проверено, что backend PostgreSQL; SQLite fallback запрещён.
Реальное восстановление SQL/media и длительная нагрузка нового состава не выполнялись.
MSSQL и ClickHouse остаются непроверенными по согласованному ограничению.

### Что выявила независимая проверка

- Чистый кандидат выявил ошибку callback меню CRM до создания announcements. Выделены
  исправление, зависимость и регрессии отдельным предшествующим коммитом; повтор прошёл.
- В первой копии кандидата Windows help не запускался без venv. Подготовлено чтение
  существующего Python через junction; повтор всех 603 тестов прошёл. Это не чистая установка.
- Старый файловый кэш маршрутизировал sandbox BI в CPU-очередь. Первоначальный прогон
  134 тестов дал один отказ. Старые кэши сохранены, выполнен штатный `ergoms api warmup_celery`
  без Django; повтор 134 тестов прошёл. Исходники кэша не изменялись. После обновления
  состава исходников нужен предусмотренный lifecycle прогрев.
- Готовность npm пилота учитывает optional-пакеты другой OS/CPU/libc. Регрессия проверяет,
  что Linux/glibc-набор готов без Windows/musl-пакетов, а неверная версия или fingerprint не принимаются.
- Проверены отказ при повреждённом снимке, непустое назначение, ошибки SQL и публикации
  media, повторный backup с той же меткой и независимость от общей SQL-ротации.

## Gitlinks

В коммитах обёртки добавлен только `modules/organizations` → `f556045`.
Остальные gitlinks намеренно не обновлялись. В таблице — их сохранённые указатели
и фактические локальные HEAD, если они различаются. Это не незакоммиченные исходники:
для согласованной поставки ревизии задаются явно. Упаковщик пилота фиксирует HEAD
обязательных репозиториев и отказывается работать с незакоммиченными исходниками.

| Путь | Gitlink обёртки | Локальный HEAD |
|---|---|---|
| `core/api` | `7efe191` | `82a5c8b` |
| `core/client` | `76d7509` | `517d5bf` |
| `core/media_api` | `12d2247` | `6e05fae` |
| `modules/competence_core` | `90d1759` | `d794626` |
| `modules/crm` | `58c2147` | `6b3f325` |
| `modules/crm_remastered` | `eef8b34` | `6f25bd1` |
| `modules/dissertation_sandbox` | `b031053` | `46cc35f` |
| `modules/education_materials_parser` | `64eab1a` | `f024a99` |
| `modules/educational_trajectories` | `428b55d` | `6e80186` |
| `modules/lms` | `ff5d9ff` | `688a4ff` |
| `modules/ollama_framework` | `a6de5ed` | `d1bb1f5` |
| `modules/projects` | `53fde7b` | `9e144f2` |
| `modules/students` | `df6a0d9` | `72d6af4` |
| `modules/vacancies_parser` | `6ccddfb` | `1c1360d` |
| `modules/workers` | `8dd9aaa` | `af7c46a` |

## Сохранённые локальные файлы

Ни один из этих файлов не скрывался новыми правилами `.gitignore`. Ниже точный
список наблюдаемого остатка; он не добавляется в коммиты этой серии. Статусы Git
сохранены как есть (`M` — изменён, `??` — новый). Параллельные изменения могут
продолжать появляться после времени этого среза.

### ergo_ms

Отменённая локальная правка правила коммитов сохранена. Документы этого завершающего коммита перечислены в составе серии.

```text
 M .cursor/rules/git-commits.mdc
```

### modules/lms

Отдельный остаток интерфейса, правил и плановых документов. Новые поля оценивания и пятый браузерный сценарий появились во время работы; в перенос включены только четыре исходных сценария из начального снимка. Рабочий файл с новым сценарием сохранён.

```text
 M AGENTS.md
 M api/INTEGRATIONS.md
 M api/completion_policy.py
 M api/result_calculator.py
 M api/test_sprint2.py
 M client/Admin/LmsCatalogSettingsCard.vue
 M client/Certificates/CertificatesView.vue
 M client/Grades/TeacherReviewsView.vue
 M client/LessonsManagement/LearningContentEditor.vue
 M client/Workspace/AssignmentsView.vue
 M client/Workspace/MaterialsView.vue
 M client/Workspace/TestsView.vue
 M client/assessments/TestConstructorWorkspace.vue
 M client/assessments/players/ChoiceOption.vue
 M client/assessments/questionTypes.js
 M client/js/assessmentsLocales.js
 M client/tests/pilot.spec.js
 M docs/QA_RELEASE.md
 M docs/README.md
 M docs/ROADMAP.md
 M logic.md
?? BEHAVIOR.md
?? client/LessonsManagement/LearningItemGradingFields.vue
?? docs/APROBATION.md
?? docs/IAS_PLAN.md
?? docs/INSTRUCTIONS.md
```

### modules/organizations

Три клиентские правки членства/ролей сохранены отдельно; bridge public_id закоммичен независимо.

```text
 M client/MemberDetailSettings/components/MemberDetailAdditionalFields.vue
 M client/MemberDetailSettings/components/MemberDetailMainSettings.vue
 M client/RolePolicySettings/components/CreateRoleGroupInfoStep.vue
```

### modules/crm_remastered

Переводы сохранены отдельно от исправления миграции.

```text
 M client/js/locales/en.js
 M client/js/locales/fr.js
 M client/js/locales/ru.js
```

### modules/competence_core

Локальная правка миграции требует отдельного разбора; не относится к адаптерам инструментов.

```text
 M api/migrations/0033_profession_catalog.py
```

### modules/tasks

Клиентские правки задач сохранены отдельно.

```text
 M client/components/CreateTaskModal.vue
 M client/js/useTaskModalView.js
```

### modules/ollama_framework

Windows-служба не включена в перенос установщика. Её переустановка и изменение режима остановки требуют отдельной проверки служб.

```text
 M deployment/windows/install-ollama-service.ps1
```

### modules/bi_analysis

Большой существующий diff BI не включён в серию пилота/инструментов. 134 теста проверяют рабочую копию; будущие смысловые коммиты BI ещё требуют независимой проверки точного состава.

```text
 M .env.example
 M BEHAVIOR.md
 M README.md
 M api/bi_charts/file_rows.py
 M api/bi_charts/methods.py
 M api/bi_charts/serializers.py
 M api/bi_charts/views.py
 M api/bi_connections/files/media_io.py
 M api/bi_connections/files/serializers.py
 M api/bi_connections/files/upload_views.py
 M api/bi_connections/files/views.py
 M api/bi_connections/methods.py
 M api/bi_connections/table_preview.py
 M api/bi_connections/views.py
 M api/bi_dashboards/models.py
 M api/bi_dashboards/serializers.py
 M api/bi_dashboards/views.py
 M api/bi_datasets/serializers.py
 M api/bi_datasets/services/draft_preview/snapshot.py
 M api/bi_datasets/services/formula_to_sql.py
 M api/bi_datasets/services/saved_query/builder.py
 M api/bi_datasets/services/saved_query/common.py
 M api/bi_datasets/services/sql_values.py
 M api/bi_datasets/services/sync.py
 M api/bi_datasets/views/_sync_gate.py
 M api/bi_datasets/views/dataset_preview_views.py
 M api/bi_datasets/views/dataset_views.py
 M api/bi_datasets/views/draft_preview_views.py
 M api/bi_datasets/views/sync_status_views.py
 M api/bi_datasets/views/table_field_param_views.py
 M api/celery_config.py
 M api/config.py
 M api/eda/data_loader.py
 M api/eda/serializers.py
 M api/eda/views.py
 M api/modeling/serializers.py
 M api/modeling/views.py
 M api/models.py
 M api/recommender/profile.py
 M api/sandbox/views.py
 M api/sharing/services.py
 M api/tasks.py
 M api/tests/test_excel_io.py
 M api/tests/test_module_connection_files.py
 M client/Charts/components/BiChartEmbed.vue
 M client/Charts/components/ChartSettingsFieldModal.vue
 M client/Charts/components/InMemoryChartEmbed.vue
 M client/Charts/components/js/chartDataTransform.js
 M client/Charts/components/js/chartTheme.js
 M client/Charts/components/js/echartsOptionBuilder.js
 M client/Connections/Files/FilePreview/js/useCsvPreview.js
 M client/Connections/Files/SheetEditor/SheetEditor.vue
 M client/Connections/Files/SheetEditor/SpreadsheetGrid.vue
 M client/Connections/Files/SheetEditor/composables/sheetTranspose.js
 M client/Connections/Files/SheetEditor/composables/useFormulas.js
 M client/Connections/Files/SheetEditor/composables/useMerge.js
 M client/Connections/Files/js/useFileList.js
 M client/Connections/components/db-settings/ConnectionDetail.vue
 M client/Dashboards/Chart/ChartWidget.vue
 M client/Dashboards/Chart/chartUrlUtils.js
 M client/Dashboards/DashboardHeader.vue
 M client/Dashboards/DashboardPage.vue
 M client/Dashboards/Selector/SelectorSettings.vue
 M client/Dashboards/Selector/SelectorWidget.vue
 M client/Dashboards/Selector/components/SelectorDataSection.vue
 M client/Dashboards/Selector/components/SelectorListItem.vue
 M client/Dashboards/Selector/components/SelectorListPanel.vue
 M client/Dashboards/components/DefaultValueSelector.vue
 M client/Dashboards/components/PageWindow.vue
 M client/Dashboards/components/connections/ConnectionsModal.vue
 M client/Dashboards/js/useDashboardDrag.js
 M client/Datasets/Analysis/AnalysisPage.vue
 M client/Datasets/DatasetFooter.vue
 M client/Datasets/DatasetListPage.vue
 M client/Datasets/DatasetPage.vue
 M client/Datasets/Fields/Source/SourceSettings.vue
 M client/Datasets/Fields/Source/js/formulaLanguage.js
 M client/Datasets/Fields/Source/js/formulaValidation.js
 M client/Datasets/Sources/DatasetCreating.vue
 M client/Datasets/Sources/TableLinkModal.vue
 M client/MainPage/Sidebar/components/SimpleTableDataSet.vue
 M client/MainPage/js/useMainSidebarStore.js
 M client/components/common/Placeholders.vue
 M client/components/sharing/UserSearch.vue
 M client/package.json
 M task_footprint.yaml
?? api/bi_connections/source_access.py
?? api/bi_dashboards/graph_write.py
?? api/bi_dashboards/migrations/0007_page_item_public_ids.py
?? api/bi_datasets/services/column_renames.py
?? api/bi_datasets/services/field_expressions.py
?? api/bi_datasets/services/field_values.py
?? api/bi_datasets/services/query_executor.py
?? api/bi_datasets/services/source_binding.py
?? api/crud_audit.py
?? api/migrations/0008_public_ids_task_runs.py
?? api/task_access.py
?? api/tests/test_bi_crud_audit.py
?? api/tests/test_dashboard_browser.py
?? api/tests/test_draft_task_access.py
?? api/tests/test_postgres_source.py
?? api/tests/test_preview_boundaries.py
?? api/tests/test_public_id_migration.py
?? api/tests/test_saved_dataset_execution.py
?? api/tests/test_source_binding.py
?? api/tests/test_stabilization.py
?? api/tests/test_task_concurrency.py
?? client/Dashboards/js/dashboardSerialization.js
?? client/tests/browserHarness.js
?? client/tests/chartUrlUtils.test.mjs
?? client/tests/dashboard.browser.mjs
?? client/tests/dashboardSerialization.test.mjs
?? runtime_requirements.yaml
```

### modules/dissertation_sandbox

Локальные изменения преобразования документов и тестов сохранены отдельно от общего реестра.

```text
 M README.md
 M tools/index_corpus/doc_convert.py
 M tools/office.py
?? tools/tests/test_office.py
```

## Продолжение

1. Разобрать оставшийся BI diff отдельно от чужих UI/предметных изменений и проверить
   точные будущие коммиты. Рабочий git status с ignore=all не отражает движения HEAD подмодулей;
   для контроля использовать явный `--ignore-submodules=none`.
2. Завершить A на согласованных ревизиях в одноразовых Windows/Linux-средах: установка
   с нуля, повторный setup без повторных скачиваний, отказ зеркала и целостность.
3. Проверить реальный пилот: npm ci, изолированный подъём, backup/restore с PostgreSQL
   и media, браузерные сценарии, повторные запуски и нагрузка. До этого выпуск не принят.
4. Затем B/C → D → F/G → E → H. B — общий индекс моделей; C — независимая
   core.analytics; D — дескрипторы и bridge-исполнение с переносом отчётов без пересчёта;
   F/G — дашборды, экспорт, кэш и клиент; E — выключенная по умолчанию идемпотентная
   автосборка с сохранением ручных правок; H — установка, миграции и итоговая приёмка.

## Локальные доказательства

Начальный снимок, бинарные patch, копии новых файлов и журнал коммитов: `virtual_env/cache/residual-review-20261021-160205/`.
Точные кандидаты собраны через checkout-index, не из всей рабочей копии.
Временные junction используют существующий Python/Node/npm только для тестов и сборки;
их нельзя считать доказательством установки с нуля. При уборке сначала снять junction,
не удаляя рекурсивно их целевые каталоги.
Логи прогонов — `virtual_env/cache/residual-*.log`; в Git они не включены.
