# ergo_ms — инструкции для Claude Code

Правила из `.cursor/rules` лежат в `.claude/rules/` и собираются автоматически. Для alwaysApply-правил копии без `paths` грузятся в каждой сессии, остальные — при работе с подходящими файлами.

Менять правила нужно в `.cursor/rules`, копии не редактировать. После правок запустить `python3 .claude/scripts/sync_claude_rules.py`.
