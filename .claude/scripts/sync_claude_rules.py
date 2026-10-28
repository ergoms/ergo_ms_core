#!/usr/bin/env python3
"""Собирает .claude/rules/*.md из .cursor/rules/*.mdc.

Источник правды — .cursor/rules. Каждое правило превращается в .claude/rules/*.md,
текст не меняется:
- с globs — копия с полем paths, грузится при работе с подходящими файлами;
- с alwaysApply: true — копия без paths, грузится в каждой сессии.
Пропускаются правила без globs и без alwaysApply (в Cursor их подключают вручную
или по описанию) и *.local.mdc (личные файлы, они не коммитятся).
Импорты @...mdc из CLAUDE.md не используются: Claude Code не раскрывает .mdc.

Использование:
    python3 .claude/scripts/sync_claude_rules.py          # записать копии
    python3 .claude/scripts/sync_claude_rules.py --check  # код 1, если копии устарели
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / ".cursor" / "rules"
DST = ROOT / ".claude" / "rules"
MARK = "<!-- Сгенерировано .claude/scripts/sync_claude_rules.py из .cursor/rules. Не редактировать. -->"
LINK = re.compile(r"\]\(([^)/]+\.mdc)\)")


def split_frontmatter(text):
    """Разбирает frontmatter построчно: Cursor терпит незакавыченные двоеточия, YAML — нет."""
    if not text.startswith("---\n"):
        raise ValueError("нет frontmatter")
    end = text.index("\n---\n", 4)
    meta = {}
    key = None
    for line in text[4:end].split("\n"):
        if line.startswith("  - ") and key:
            meta.setdefault(key, []).append(line[4:].strip().strip('"').strip("'"))
        elif ":" in line and not line.startswith(" "):
            key, _, value = line.partition(":")
            key = key.strip()
            meta[key] = value.strip() or []
    if isinstance(meta.get("globs"), str):
        meta["globs"] = [g.strip() for g in meta["globs"].split(",") if g.strip()]
    meta["alwaysApply"] = meta.get("alwaysApply") == "true"
    return meta, text[end + 5:]


def render(meta, body):
    globs = meta.get("globs") or []
    lines = []
    if globs:
        lines = ["---", "paths:"] + [f"  - {json.dumps(g, ensure_ascii=False)}" for g in globs] + ["---"]
    lines += [MARK, ""]
    # Ссылки на соседние .mdc ведут в .cursor/rules, рядом их в .claude/rules нет.
    body = LINK.sub(r"](../../.cursor/rules/\1)", body.lstrip("\n"))
    return "\n".join(lines) + "\n" + body


def plan():
    wanted = {}
    for src in sorted(SRC.glob("*.mdc")):
        if src.name.endswith(".local.mdc"):
            continue
        meta, body = split_frontmatter(src.read_text(encoding="utf-8").replace("\r\n", "\n"))
        if not meta["alwaysApply"] and not meta.get("globs"):
            continue
        wanted[DST / f"{src.stem}.md"] = render(meta, body)
    return wanted


def generated_files():
    if not DST.exists():
        return []
    return [p for p in DST.glob("*.md") if MARK in p.read_text(encoding="utf-8")]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="не писать, только проверить")
    args = parser.parse_args()

    wanted = plan()
    stale = [p for p, text in wanted.items() if not p.exists() or p.read_text(encoding="utf-8") != text]
    orphans = [p for p in generated_files() if p not in wanted]

    if args.check:
        if stale or orphans:
            for p in stale:
                print(f"устарел: {p.relative_to(ROOT)}")
            for p in orphans:
                print(f"лишний: {p.relative_to(ROOT)}")
            print("Запустите: python3 .claude/scripts/sync_claude_rules.py", file=sys.stderr)
            return 1
        print(f"Копии актуальны: {len(wanted)} файлов")
        return 0

    DST.mkdir(parents=True, exist_ok=True)
    for p, text in wanted.items():
        if p in stale:
            p.write_text(text, encoding="utf-8")
    for p in orphans:
        p.unlink()
    print(f"Записано: {len(stale)}, удалено лишних: {len(orphans)}, всего правил: {len(wanted)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
