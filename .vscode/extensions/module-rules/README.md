# ERGO MS Module Cursor Rules

Подхватывает правила агента из модулей (`modules/<имя>/.cursor/rules/*.mdc`) и регистрирует их в Cursor через `vscode.cursor.plugins.addPlugin`.

MCP — отдельное расширение `module-mcp` (каталог `.vscode/extensions/module-mcp/`).

## Установка

```bash
ergoms install-extensions
```

Затем **Developer: Reload Window**.

## Как работает

1. Сканирует `modules/*/.cursor/rules/*.mdc`.
2. Копирует правила в staging: `virtual_env/cache/cursor-module-plugins/<module>/`.
3. Для каждого модуля вызывает `vscode.cursor.plugins.addPlugin({ path })` на корень плагина (каталог с `.cursor-plugin/plugin.json`).
4. Следит за изменениями в `modules/*/.cursor/rules/**`.

Команда: **ERGO MS: Sync Module Cursor Rules**. Лог — Output → **ERGO MS Module Rules**.

## Конвенция в модуле

```text
modules/<имя>/
  .cursor/rules/
    <topic>.mdc
  AGENTS.md
```

```yaml
---
description: <имя> — тема
globs:
  - "modules/<имя>/**"
alwaysApply: false
---
```

Не ставьте `alwaysApply: true` на модульных правилах.

## Ограничения

- Нужен **Cursor** с Extension API `vscode.cursor.plugins` (`addPlugin` / `removePlugin`).
- Staging в `virtual_env/cache/` не коммитится.
