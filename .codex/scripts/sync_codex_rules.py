#!/usr/bin/env python3
"""Собирает .codex/CODEX.md и .codex/rules/ из правил Cursor."""

import argparse
import json
import os
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile

ROOT = Path(__file__).resolve().parents[2]
PROJECT_DOC = ROOT / ".codex" / "CODEX.md"
RULES = ROOT / ".codex" / "rules"
INDEX = RULES / "rules-index.md"
GLOBS = RULES / "globs.json"
MEMORY = ROOT / ".codex" / "working-memory.md"
MARK = "<!-- Сгенерировано .codex/scripts/sync_codex_rules.py. Не редактировать. -->"

sys.path.insert(0, str(ROOT / ".claude" / "scripts"))
from sync_claude_rules import MARK as CLAUDE_MARK
from sync_claude_rules import relink, render, sources, split_frontmatter


def relative_link(target, document):
    return Path(os.path.relpath(target, document.parent)).as_posix()


def plan():
    project = [
        MARK,
        "# Правила проекта для Codex",
        "Перед работой сверься с [оглавлением правил](rules/rules-index.md). "
        "Хуки Codex подключают правила с `globs` по явным путям в запросах и вызовах инструментов. "
        "Если путь обнаружен впервые в `apply_patch`, хук откладывает правку до подгрузки правил. "
        "Открой правило из оглавления, если оно подходит по описанию или путь не распознан. "
        "Если оглавления ещё нет, создай копии и оглавление командой "
        "`python3 -B .codex/scripts/sync_codex_rules.py --runtime-only` из корня проекта.",
        "При работе в модуле также прочитай его `AGENTS.md`, если он есть. "
        "Перед подготовкой сообщения коммита прочитай [`.cursorrules`](../.cursorrules).",
        "При запуске из Git-подмодуля добавь параметр "
        "`-c 'project_root_markers=[\".codex-project-instructions\"]'` к команде `codex`, "
        "чтобы Codex прочитал общие правила вместе с `AGENTS.md` модуля.",
        "Меняй правила в исходных `.mdc` и пересобирай их командой "
        "`python3 -B .codex/scripts/sync_codex_rules.py`. "
        "При старте сессии Codex обновляет копии и оглавление через хук `SessionStart`.",
    ]
    groups = {
        "Общие правила": [],
        "Правила модулей": [],
        "Локальные правила": [],
    }
    copies = {}
    scoped = []
    for src, _, module in sources():
        meta, body = split_frontmatter(src.read_text(encoding="utf-8-sig"))
        local = src.name.endswith(".local.mdc")
        if module and meta["alwaysApply"]:
            meta["alwaysApply"] = False
            meta["globs"] = meta.get("globs") or [f"modules/{module}/**"]

        target = src
        if not local:
            folder = RULES / "modules" / module if module else RULES
            target = folder / f"{src.stem}.md"
            copies[target] = render(meta, body, src, target).replace(CLAUDE_MARK, MARK, 1)
            if meta.get("globs") and not meta["alwaysApply"]:
                scoped.append({
                    "file": target.relative_to(RULES).as_posix(),
                    "module": module,
                    "globs": meta["globs"],
                })
            if meta["alwaysApply"] and body.strip():
                project.extend((
                    f"[Копия правила]({relative_link(target, PROJECT_DOC)})",
                    relink(body.strip(), src, PROJECT_DOC),
                ))

        title = "Локальные правила" if local else "Правила модулей" if module else "Общие правила"
        path = target.relative_to(ROOT).as_posix()
        description = str(meta.get("description") or "").strip().strip('"').strip("'")
        globs = ", ".join(meta.get("globs") or ())
        entry = f"- [`{path}`]({relative_link(target, INDEX)})"
        if description:
            entry += f" — {description}"
        if globs:
            entry += f" (пути: `{globs}`)"
        if meta["alwaysApply"] and not local:
            entry += " (текст уже включён в CODEX.md)"
        groups[title].append(entry)

    index = [MARK, "", "# Оглавление правил Codex"]
    for title, entries in groups.items():
        if entries:
            index.extend(("", f"## {title}", "", *entries))
    copies[INDEX] = "\n".join(index) + "\n"
    copies[GLOBS] = json.dumps(scoped, ensure_ascii=False, indent=2) + "\n"
    return "\n\n".join(project) + "\n", copies


def matches(path, text):
    return path.is_file() and path.read_text(encoding="utf-8") == text


def write_if_changed(path, text):
    if matches(path, text):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(
        mode="w", encoding="utf-8", newline="\n", dir=path.parent, delete=False,
    ) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(text)
            temporary.close()
            temporary_path.chmod(0o644)
            temporary_path.replace(path)
        finally:
            temporary_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="проверить отслеживаемый .codex/CODEX.md")
    mode.add_argument("--runtime-only", action="store_true", help="обновить копии правил и оглавление")
    mode.add_argument("--session-start", action="store_true", help="обновить копии и передать локальную память")
    args = parser.parse_args()
    project, copies = plan()
    if args.check:
        if matches(PROJECT_DOC, project):
            return 0
        print("Обнови .codex/CODEX.md: python3 -B .codex/scripts/sync_codex_rules.py", file=sys.stderr)
        return 1
    if not (args.runtime_only or args.session_start):
        write_if_changed(PROJECT_DOC, project)
    for path, text in copies.items():
        write_if_changed(path, text)
    for path in RULES.rglob("*.md"):
        if path not in copies and MARK in path.read_text(encoding="utf-8"):
            path.unlink(missing_ok=True)
    if args.session_start and MEMORY.is_file():
        memory = MEMORY.read_text(encoding="utf-8").strip()
        if memory:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": memory,
            }}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
