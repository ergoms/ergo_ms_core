# ergo_ms — инструкции для Claude Code

Правила из `.cursor/rules` с `alwaysApply: true`. Подключены импортом, поэтому остаются единым источником для Cursor и Claude Code.

Правила с `globs` копируются в `.claude/rules/` командой `python3 .claude/scripts/sync_claude_rules.py`. Менять их нужно в `.cursor/rules`, копии не редактировать.

@../.cursor/rules/chat-style.mdc
@../.cursor/rules/clarifying-questions.mdc
@../.cursor/rules/code.mdc
@../.cursor/rules/core-module-isolation.mdc
@../.cursor/rules/docs.mdc
@../.cursor/rules/git-commits.mdc
@../.cursor/rules/no-direct-manage-py.mdc
@../.cursor/rules/no-host-fingerprint.mdc
@../.cursor/rules/security.mdc
@../.cursor/rules/struct.mdc
