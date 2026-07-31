# ERGO MS Module Cursor MCP

Ставит в `.cursor/mcp.json` все MCP ядра и модулей. **Установлены сразу, по умолчанию выключены** (`"disabled": true`).

## Установка

```bash
ergoms install-extensions
```

Reload Window → sync запишет серверы в mcp.json с `disabled: true`.

## Поведение

| Состояние | Что происходит |
|-----------|----------------|
| Новый сервер в каталоге | Попадает в mcp.json с `disabled: true` |
| Уже был `disabled: false` | При sync флаг сохраняется |
| `registerServer` | Только для серверов с `disabled: false` |

Включение:

- Settings → Tools & MCP (если Cursor уважает `disabled`), или
- **ERGO MS: Enable MCP Servers** (ставит `disabled: false` в mcp.json и регистрирует)

## Команды

| Команда | Назначение |
|---------|------------|
| **Sync Module Cursor MCP** | Обновить каталог в mcp.json |
| **Enable MCP Servers** | Выбрать, какие включить |
| **Disable MCP Servers** | Выбрать, какие выключить |

Лог: Output → **ERGO MS Module MCP**.
