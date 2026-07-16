"""Чтение и запись shell-скриптов deployment: UTF-8 без BOM, только LF.

Проверка репозитория: ergoms sh-encoding-check (входит в core-rules-check).
"""

from __future__ import annotations

from pathlib import Path

UTF8_BOM = b'\xef\xbb\xbf'


def read_sh(path: Path) -> str:
    """Читает .sh; BOM (если есть) отбрасывается, переводы строк нормализуются в LF."""
    raw = path.read_bytes()
    if raw.startswith(UTF8_BOM):
        raw = raw[len(UTF8_BOM) :]
    text = raw.decode('utf-8')
    return text.replace('\r\n', '\n').replace('\r', '\n')


def write_sh(path: Path, content: str) -> None:
    """Записывает .sh в UTF-8 без BOM, с LF."""
    normalized = content.replace('\r\n', '\n').replace('\r', '\n')
    path.write_bytes(normalized.encode('utf-8'))


def sh_encoding_issues(raw: bytes) -> list[str]:
    """Возвращает список нарушений для сырого содержимого .sh."""
    issues: list[str] = []
    if raw.startswith(UTF8_BOM):
        issues.append('UTF-8 BOM')
    if b'\r\n' in raw or (b'\r' in raw and b'\r\n' not in raw):
        issues.append('CRLF или CR')
    return issues
