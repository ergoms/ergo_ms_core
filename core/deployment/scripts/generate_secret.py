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

from console_tags import configure_stdio_utf8, format_console

DEFAULT_BYTES = 32


def main() -> int:
    configure_stdio_utf8()

    parser = argparse.ArgumentParser(
        description='Сгенерировать секрет для .env (hex, как openssl rand -hex N)',
    )
    parser.add_argument(
        '-n',
        '--bytes',
        type=int,
        default=DEFAULT_BYTES,
        metavar='N',
        help=f'Длина в байтах до hex (по умолчанию {DEFAULT_BYTES}, длина строки 2N)',
    )
    parser.add_argument(
        '-c',
        '--count',
        type=int,
        default=1,
        metavar='N',
        help='Сколько секретов напечатать (по умолчанию 1)',
    )
    args = parser.parse_args()

    if args.bytes < 16:
        print(
            format_console('error', 'Минимум 16 байт (--bytes)'),
            file=sys.stderr,
        )
        return 1
    if args.count < 1:
        print(
            format_console('error', 'Число секретов (--count) должно быть >= 1'),
            file=sys.stderr,
        )
        return 1

    print(
        format_console(
            'info',
            'Скопируйте значение в .env (API_SECRET_KEY / API_JWT_SIGNING_KEY). '
            'Файл окружения команда не изменяет.',
        ),
        file=sys.stderr,
    )
    for _ in range(args.count):
        print(secrets.token_hex(args.bytes), flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
