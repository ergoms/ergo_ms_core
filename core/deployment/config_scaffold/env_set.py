"""Запись KEY=VALUE в .env с учётом закомментированных директив # KEY=value."""

from __future__ import annotations

import re
from pathlib import Path

from .env_compare import _env_key_from_line

_ACTIVE_LINE_RE_TEMPLATE = r'^{key}=.*$'
_COMMENTED_DIRECTIVE_RE_TEMPLATE = r'^#\s*{key}=.*$'


def _line_pattern(template: str, key: str) -> re.Pattern[str]:
    return re.compile(template.format(key=re.escape(key)))


def _example_canonical_active_keys(example_text: str) -> set[str]:
    """Ключи, у которых в шаблоне есть раскомментированная строка KEY=VALUE."""
    keys: set[str] = set()
    for line in example_text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        parsed_key = _env_key_from_line(stripped)
        if parsed_key:
            keys.add(parsed_key)
    return keys


def _example_key_placement(example_text: str, key: str) -> str:
    """
    Где в .env.example описан ключ:
    - active — есть раскомментированная строка;
    - commented — только # KEY=...;
    - missing — нет в шаблоне.
    """
    has_active = False
    has_commented = False
    for line in example_text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parsed_key = _env_key_from_line(stripped)
        if parsed_key != key:
            continue
        if stripped.startswith('#'):
            has_commented = True
        else:
            has_active = True
    if has_active:
        return 'active'
    if has_commented:
        return 'commented'
    return 'missing'


def _find_line_indices(lines: list[str], key: str) -> tuple[list[int], list[int]]:
    active_re = _line_pattern(_ACTIVE_LINE_RE_TEMPLATE, key)
    directive_re = _line_pattern(_COMMENTED_DIRECTIVE_RE_TEMPLATE, key)
    active_indices: list[int] = []
    directive_indices: list[int] = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if directive_re.match(stripped):
            directive_indices.append(index)
        elif active_re.match(stripped):
            active_indices.append(index)
    return active_indices, directive_indices


def set_env_var_in_content(
    content: str,
    key: str,
    value: str,
    *,
    example_path: Path | None = None,
) -> str:
    """
    Записывает KEY=value в текст .env.

    С example_path: для ключей только в # KEY=... раскомментирует директиву на её месте;
    для ключей с активной строкой в шаблоне — обновляет первую активную строку.
    Без example_path: активная строка → директива → дописывание в конец.
    """
    new_line = f'{key}={value}'
    lines = content.splitlines() if content else []

    placement = 'missing'
    if example_path and example_path.is_file():
        example_text = example_path.read_text(encoding='utf-8')
        placement = _example_key_placement(example_text, key)

    active_indices, directive_indices = _find_line_indices(lines, key)

    target_index: int | None = None
    remove_indices: list[int] = []

    if placement == 'commented' and directive_indices:
        target_index = directive_indices[-1]
        remove_indices = active_indices
    elif placement == 'active' and active_indices:
        target_index = active_indices[0]
        remove_indices = active_indices[1:]
    elif placement == 'missing':
        if active_indices:
            target_index = active_indices[0]
            remove_indices = active_indices[1:]
        elif directive_indices:
            target_index = directive_indices[-1]
        else:
            if lines and lines[-1].strip():
                lines.append('')
            lines.append(new_line)
            return _join_lines(lines, content)
    else:
        if active_indices:
            target_index = active_indices[0]
            remove_indices = active_indices[1:]
        elif directive_indices:
            target_index = directive_indices[-1]
        else:
            if lines and lines[-1].strip():
                lines.append('')
            lines.append(new_line)
            return _join_lines(lines, content)

    if target_index is None:
        if lines and lines[-1].strip():
            lines.append('')
        lines.append(new_line)
        return _join_lines(lines, content)

    lines[target_index] = new_line
    for index in reversed(remove_indices):
        lines.pop(index)
    return _join_lines(lines, content)


def _join_lines(lines: list[str], original_content: str) -> str:
    result = '\n'.join(lines)
    if original_content.endswith('\n') or original_content.endswith('\r\n'):
        result += '\n'
    return result
