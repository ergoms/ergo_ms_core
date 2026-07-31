"""
Генерация криптостойкого секрета для .env (API_SECRET_KEY, API_JWT_SIGNING_KEY и т.п.).

Только печатает значение — в .env не пишет.

  ergoms generate-secret
  ergoms generate-secret --count 2
"""

from __future__ import annotations

import argparse
import secrets
import sys
from pathlib import Path

_DEPLOYMENT_DIR = Path(__file__).resolve().parents[1]
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))

from cli_locale import t
from console_tags import configure_stdio_utf8, format_console

DEFAULT_BYTES = 32


def main() -> int:
    configure_stdio_utf8()

    parser = argparse.ArgumentParser(
        description=t('generate_secret_description'),
    )
    parser.add_argument(
        '-n',
        '--bytes',
        type=int,
        default=DEFAULT_BYTES,
        metavar='N',
        help=t('help_secret_bytes', default=DEFAULT_BYTES),
    )
    parser.add_argument(
        '-c',
        '--count',
        type=int,
        default=1,
        metavar='N',
        help=t('help_secret_count'),
    )
    args = parser.parse_args()

    if args.bytes < 16:
        print(
            format_console('error', t('secret_bytes_min')),
            file=sys.stderr,
        )
        return 1
    if args.count < 1:
        print(
            format_console('error', t('secret_count_min')),
            file=sys.stderr,
        )
        return 1

    print(
        format_console(
            'info',
            t('secret_copy_hint'),
        ),
        file=sys.stderr,
    )
    for _ in range(args.count):
        print(secrets.token_hex(args.bytes), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
