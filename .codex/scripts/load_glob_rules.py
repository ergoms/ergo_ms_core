#!/usr/bin/env python3
"""Добавляет в контекст Codex правила Cursor для путей из запроса или инструмента."""

import hashlib
import json
import re
import sqlite3
import sys
import time
from pathlib import Path

from sync_codex_rules import GLOBS, ROOT, RULES, plan

PATH_TOKEN = re.compile(r"""[`"']([^`"'\r\n]+)[`"']|([\w./~@+-]+)""")
PATCH_PATH = re.compile(r"^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$", re.M)
GLOB_TOKEN = re.compile(r"\*\*/|\*\*|\*|\?|.")
GLOB_REGEX = {"**/": "(?:.*/)?", "**": ".*", "*": "[^/]*", "?": "[^/]"}
CONTEXT_BYTES = 36000
DELIVERED = RULES / "delivered.sqlite3"
DELIVERY_TTL = 24 * 60 * 60


def match_glob(path, glob):
    pattern = "".join(GLOB_REGEX.get(token, re.escape(token)) for token in GLOB_TOKEN.findall(glob))
    return re.fullmatch(pattern, path) is not None


def referenced_paths(event):
    cwd = Path(event["cwd"])
    tool = event.get("tool_input") or {}
    if event["hook_event_name"] == "UserPromptSubmit":
        text = event.get("prompt", "")
    else:
        text = tool.get("command", "")
        cwd = cwd / (tool.get("workdir") or "")
    is_patch = event.get("tool_name") == "apply_patch"
    if is_patch:
        tokens = PATCH_PATH.findall(text)
    else:
        tokens = [quoted or bare for quoted, bare in PATH_TOKEN.findall(text)]

    for token in tokens:
        candidate = Path(token if is_patch else token.rstrip("."))
        if not candidate.name or not (is_patch or "/" in token or candidate.suffix or candidate.name.startswith(".")):
            continue
        for base in (cwd, ROOT):
            absolute = (base / candidate).resolve()
            if not absolute.is_relative_to(ROOT):
                continue
            if absolute.is_file() or ((is_patch or candidate.suffix) and absolute.parent.is_dir()):
                yield absolute.relative_to(ROOT).as_posix()
                break


def matching_sections(event):
    paths = set(referenced_paths(event))
    if not paths:
        return
    if GLOBS.is_file():
        rules = json.loads(GLOBS.read_text(encoding="utf-8"))
        fresh = None
    else:
        _, fresh = plan()
        rules = json.loads(fresh[GLOBS])
    for rule in rules:
        module = rule["module"]
        if not any(
            (not module or path.startswith(f"modules/{module}/"))
            and any(match_glob(path, glob) for glob in rule["globs"])
            for path in paths
        ):
            continue
        copy = RULES / rule["file"]
        if fresh is None:
            body = copy.read_text(encoding="utf-8")
        else:
            body = fresh[copy]
        if body.startswith("---\n"):
            body = body.split("\n---\n", 1)[1]
        label = copy.relative_to(ROOT).as_posix()
        yield f"### {label}\n\n{body.strip()}"


def select_batch(sections):
    batch = []
    size = 0
    for section in sections:
        section_size = len(section.encode("utf-8"))
        if batch and size + section_size > CONTEXT_BYTES:
            break
        batch.append(section)
        size += section_size
    return batch


def claim_batch(event, sections):
    session = event.get("session_id")
    turn = event.get("turn_id")
    if not session or not turn:
        return select_batch(sections), False

    entries = {hashlib.sha256(section.encode()).hexdigest(): section for section in sections}
    now = int(time.time())
    RULES.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DELIVERED, timeout=3) as db:
        db.execute("""CREATE TABLE IF NOT EXISTS delivered (
            session TEXT, turn TEXT, digest TEXT, timestamp INTEGER,
            PRIMARY KEY (session, turn, digest)
        )""")
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM delivered WHERE timestamp < ?", (now - DELIVERY_TTL,))
        seen = {
            row[0] for row in db.execute(
                "SELECT digest FROM delivered WHERE session = ? AND turn = ?", (session, turn),
            )
        }
        pending = {digest: section for digest, section in entries.items() if digest not in seen}
        batch = select_batch(pending.values())
        db.executemany(
            "INSERT INTO delivered VALUES (?, ?, ?, ?)",
            ((session, turn, digest, now) for digest in list(pending)[:len(batch)]),
        )
    return batch, True


def main():
    event = json.load(sys.stdin)
    sections = list(matching_sections(event))
    if not sections:
        return
    batch, tracked = claim_batch(event, sections)
    if not batch:
        return

    context = "Применимые правила проекта по путям файлов:\n\n" + "\n\n".join(batch)
    output = {
        "hookEventName": event["hook_event_name"],
        "additionalContext": context,
    }
    if event.get("tool_name") == "apply_patch" and tracked:
        output["permissionDecision"] = "deny"
        output["permissionDecisionReason"] = (
            "Первая правка отложена. Учти правила, добавленные в контекст, "
            "и заново сформируй патч."
        )
    print(json.dumps({"hookSpecificOutput": output}, ensure_ascii=False))


if __name__ == "__main__":
    main()
