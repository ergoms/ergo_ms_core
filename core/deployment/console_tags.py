"""
Единые метки консольного вывода ergoms и deployment-скриптов.

Текст сообщения — на русском; метки — только на английском ([OK], [ERROR], …).
Не путать с уровнями logging в api.log ([INFO], [WARNING] из logging_config).
"""

from __future__ import annotations

import sys


TAG_OK = '[OK]'
TAG_ERROR = '[ERROR]'
TAG_WARNING = '[WARNING]'
TAG_SKIP = '[SKIP]'
TAG_INFO = '[INFO]'

TAGS_BY_LEVEL: dict[str, str] = {
    'ok': TAG_OK,
    'error': TAG_ERROR,
    'warning': TAG_WARNING,
    'skip': TAG_SKIP,
    'info': TAG_INFO,
}


def configure_stdio_utf8() -> None:
    """UTF-8 для stdout/stderr (Windows cp1252 иначе падает на кириллице)."""
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')


def tag_for_level(level: str) -> str:
    try:
        return TAGS_BY_LEVEL[level.lower()]
    except KeyError as exc:
        known = ', '.join(sorted(TAGS_BY_LEVEL))
        raise ValueError(f'Unknown console level {level!r}; expected one of: {known}') from exc


def format_console(level: str, message: str) -> str:
    tag = tag_for_level(level)
    text = (message or '').strip()
    if not text:
        return tag
    return f'{tag} {text}'
