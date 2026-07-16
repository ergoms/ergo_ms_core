#!/usr/bin/env python3
"""
Проверка shell-скриптов deployment для Linux.

CRLF и UTF-8 BOM ломают shebang и source на Linux (ошибка «#!/usr/bin/env: No such file or directory»).

Использование:
  ergoms sh-encoding-check
  ergoms sh-encoding-check --fix
"""

from __future__ import annotations

import argparse
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

from console_tags import format_console  # noqa: E402
from sh_io import read_sh, sh_encoding_issues, write_sh  # noqa: E402


def _scan_roots() -> list[Path]:
    return [_DEPLOYMENT_DIR]


def find_sh_encoding_violations(*, roots: list[Path] | None = None) -> list[tuple[Path, list[str]]]:
    """Файлы .sh с CRLF/CR или UTF-8 BOM."""
    violations: list[tuple[Path, list[str]]] = []
    for root in roots or _scan_roots():
        for path in sorted(root.rglob('*.sh')):
            issues = sh_encoding_issues(path.read_bytes())
            if issues:
                violations.append((path, issues))
    return violations


def fix_sh_encoding(paths: list[Path]) -> int:
    fixed = 0
    for path in paths:
        write_sh(path, read_sh(path))
        fixed += 1
        rel = path.relative_to(PROJECT_ROOT)
        print(format_console('ok', f'LF без BOM: {rel}'))
    return fixed


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Проверка LF и отсутствия BOM в .sh deployment (Linux shebang)',
    )
    parser.add_argument(
        '--fix',
        action='store_true',
        help='нормализовать нарушающие файлы через sh_io.write_sh (UTF-8, LF, без BOM)',
    )
    args = parser.parse_args()

    violations = find_sh_encoding_violations()
    if not violations:
        print(format_console('ok', 'Все .sh deployment в UTF-8 LF без BOM'))
        return 0

    for path, issues in violations:
        rel = path.relative_to(PROJECT_ROOT)
        print(format_console('error', f'{rel}: {", ".join(issues)}'))

    if args.fix:
        fix_sh_encoding([path for path, _ in violations])
        remaining = find_sh_encoding_violations()
        if remaining:
            print(format_console('error', f'После --fix осталось нарушений: {len(remaining)}'))
            return 1
        print(format_console('ok', 'Кодировка .sh исправлена'))
        return 0

    print(
        format_console(
            'info',
            'Исправление: ergoms sh-encoding-check --fix (или write_sh при правке .sh из Python)',
        ),
    )
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
