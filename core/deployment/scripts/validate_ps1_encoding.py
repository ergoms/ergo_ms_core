#!/usr/bin/env python3
"""
Проверка кодировки PowerShell-скриптов deployment.

Windows PowerShell 5.1 читает .ps1 без BOM в системной кодировке (CP1251):
кириллица в строках ломает разбор файла (ложные ParserError про `}` или кавычки).

Использование:
  ergoms ps1-encoding-check
  ergoms ps1-encoding-check --fix
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

_SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = _SCRIPTS_DIR.parent
PROJECT_ROOT = _DEPLOYMENT_DIR.parent.parent

if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402
from ps1_io import UTF8_BOM, read_ps1, write_ps1  # noqa: E402

_NON_ASCII_RE = re.compile(r'[^\x00-\x7f]')


def _scan_roots() -> list[Path]:
    return [_DEPLOYMENT_DIR]


def find_ps1_encoding_violations(*, roots: list[Path] | None = None) -> list[Path]:
    """Файлы .ps1 с не-ASCII текстом без UTF-8 BOM."""
    violations: list[Path] = []
    for root in roots or _scan_roots():
        for path in sorted(root.rglob('*.ps1')):
            raw = path.read_bytes()
            if not _NON_ASCII_RE.search(raw.decode('utf-8', errors='replace')):
                continue
            if not raw.startswith(UTF8_BOM):
                violations.append(path)
    return violations


def fix_ps1_encoding(paths: list[Path]) -> int:
    fixed = 0
    for path in paths:
        write_ps1(path, read_ps1(path))
        fixed += 1
        rel = path.relative_to(PROJECT_ROOT)
        print(format_console('ok', t('ps1_bom_added', rel=rel)))
    return fixed


def main() -> int:
    parser = argparse.ArgumentParser(description=t('ps1_encoding_check_description'))
    parser.add_argument(
        '--fix',
        action='store_true',
        help=t('help_fix_ps1'),
    )
    args = parser.parse_args()

    violations = find_ps1_encoding_violations()
    if not violations:
        print(format_console('ok', t('ps1_encoding_ok')))
        return 0

    for path in violations:
        rel = path.relative_to(PROJECT_ROOT)
        print(format_console('error', t('ps1_no_bom', rel=rel)))

    if args.fix:
        fix_ps1_encoding(violations)
        remaining = find_ps1_encoding_violations()
        if remaining:
            print(format_console('error', t('ps1_fix_remaining', count=len(remaining))))
            return 1
        print(format_console('ok', t('ps1_encoding_fixed')))
        return 0

    print(
        format_console(
            'info',
            t('ps1_fix_hint'),
        ),
    )
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
