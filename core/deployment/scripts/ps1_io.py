"""Чтение и запись PowerShell-скриптов с UTF-8 BOM (Windows PowerShell 5.1).

При правке .ps1 из Python — только write_ps1(), не Path.write_text().
Проверка репозитория: ergoms ps1-encoding-check (входит в core-rules-check).
"""

from __future__ import annotations

from pathlib import Path

UTF8_BOM = b'\xef\xbb\xbf'


def read_ps1(path: Path) -> str:
    """Читает .ps1; BOM (если есть) отбрасывается."""
    raw = path.read_bytes()
    if raw.startswith(UTF8_BOM):
        raw = raw[len(UTF8_BOM) :]
    return raw.decode('utf-8')


def write_ps1(path: Path, content: str) -> None:
    """Записывает .ps1 в UTF-8 с BOM — как ergoms-скрипты в репозитории."""
    path.write_bytes(UTF8_BOM + content.encode('utf-8'))
