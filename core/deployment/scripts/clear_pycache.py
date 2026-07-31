"""
Удаление каталогов __pycache__ в дереве проекта (без запуска Django).

  ergoms clear-pycache
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402


def _configure_stdio_utf8() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            try:
                stream.reconfigure(encoding='utf-8', errors='replace')
            except (AttributeError, OSError, ValueError):
                pass


def clear_pycache(root: Path) -> tuple[int, int]:
    removed = 0
    failed = 0

    for cache_dir in sorted(root.rglob('__pycache__')):
        if not cache_dir.is_dir():
            continue
        try:
            shutil.rmtree(cache_dir)
            removed += 1
        except OSError as exc:
            failed += 1
            print(
                format_console('warning', t('pycache_remove_failed', path=cache_dir, exc=exc)),
                file=sys.stderr,
            )

    return removed, failed


def main() -> int:
    _configure_stdio_utf8()

    parser = argparse.ArgumentParser(description=t('pycache_description'))
    parser.add_argument(
        '--root',
        default='.',
        help=t('help_root_path'),
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(format_console('error', t('project_dir_not_found', root=root)), file=sys.stderr)
        return 1

    removed, failed = clear_pycache(root)

    if failed:
        print(
            format_console(
                'error',
                t('pycache_partial_fail', removed=removed, failed=failed),
            ),
            file=sys.stderr,
        )
        return 1

    if removed:
        print(format_console('ok', t('pycache_removed', count=removed)))
    else:
        print(format_console('ok', t('pycache_none_found')))

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
