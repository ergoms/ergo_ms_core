"""Повышение привилегий на Linux (sudo re-exec)."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


def is_root() -> bool:
    if os.name == 'nt':
        return False
    return os.geteuid() == 0


def needs_sudo_reexec(recipe_needs_sudo: bool) -> bool:
    if not recipe_needs_sudo:
        return False
    if sys.platform == 'win32':
        return False
    if is_root():
        return False
    return shutil.which('sudo') is not None


def reexec_with_sudo(argv: list[str], *, cwd: Path | None = None) -> int:
    cmd = ['sudo', *argv]
    return subprocess.call(cmd, cwd=str(cwd) if cwd else None)
