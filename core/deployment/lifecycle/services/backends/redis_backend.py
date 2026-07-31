"""
Shared redis status / test (ping) for host lifecycle.

Install и NSSM/systemd остаются в shell-адаптерах.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

from lifecycle.services.backends import _bootstrap  # noqa: F401

from console_tags import format_console  # noqa: E402
from install_redis import (  # noqa: E402
    is_installed,
    ping_redis,
    redis_conf_path,
    redis_packages_dir,
)

REDIS_WINDOWS_SERVICE = 'ergo_ms_redis'
REDIS_LINUX_SERVICE = 'ergo_ms_redis.service'


def _configure_stdio_utf8() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')


def _is_redis_service_active() -> bool:
    if os.name == 'nt':
        result = subprocess.run(
            ['sc', 'query', REDIS_WINDOWS_SERVICE],
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace',
            check=False,
        )
        if result.returncode != 0:
            return False
        return 'RUNNING' in (result.stdout or '').upper()

    active = subprocess.run(
        ['systemctl', 'is-active', '--quiet', REDIS_LINUX_SERVICE],
        check=False,
    )
    return active.returncode == 0


def cmd_test(root: Path) -> int:
    if not is_installed(root):
        print(format_console('error', 'Redis не установлен'), file=sys.stderr)
        return 1
    if ping_redis(root):
        print(format_console('ok', 'PONG'))
        return 0
    print(format_console('error', 'Redis не отвечает на ping'), file=sys.stderr)
    return 1


def cmd_status(root: Path) -> int:
    _configure_stdio_utf8()
    redis_dir = redis_packages_dir(root)

    if not is_installed(root):
        print('Redis: не установлен')
        print(f'  Ожидаемый путь: {redis_dir}')
        return 0

    print('')
    print('=== Статус Redis ===')

    if _is_redis_service_active():
        label = REDIS_WINDOWS_SERVICE if os.name == 'nt' else REDIS_LINUX_SERVICE
        print(f'  Служба ({label}): Running')
    elif ping_redis(root):
        print('  Process: Запущен (PONG)')
    else:
        print('  Process: Not running')

    conf = redis_conf_path(root)
    if conf.is_file():
        print(f'  Config: {conf}')
    return 0


def main(argv: list[str] | None = None) -> int:
    _configure_stdio_utf8()
    parser = argparse.ArgumentParser(description='Redis backend (status/test)')
    parser.add_argument('operation', choices=('status', 'test'))
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[5])
    args = parser.parse_args(argv)

    root = args.root.resolve()
    if args.operation == 'status':
        return cmd_status(root)
    return cmd_test(root)


if __name__ == '__main__':
    raise SystemExit(main())
