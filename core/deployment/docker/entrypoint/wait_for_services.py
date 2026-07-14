"""
Ожидание postgres и redis перед стартом сервиса в Docker.

Переменные: ERGO_DOCKER_DB_HOST, ERGO_DOCKER_DB_PORT, REDIS_HOST, REDIS_PORT,
DOCKER_DATABASE, DOCKER_ENABLED.
"""

from __future__ import annotations

import os
import socket
import sys
import time


def _env(name: str, default: str = '') -> str:
    return os.environ.get(name, default).strip() or default


def _truthy(name: str, default: bool = False) -> bool:
    value = _env(name, 'true' if default else 'false').lower()
    return value in ('1', 'true', 'yes', 'on')


def wait_tcp(host: str, port: int, timeout: float, label: str) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=2):
                print(f'[OK] {label} доступен: {host}:{port}')
                return True
        except OSError:
            time.sleep(1)
    print(f'[ERROR] Таймаут ожидания {label}: {host}:{port}', file=sys.stderr)
    return False


def main() -> int:
    if not _truthy('DOCKER_ENABLED'):
        return 0

    timeout = float(_env('ERGO_DOCKER_WAIT_TIMEOUT', '120'))

    redis_host = _env('REDIS_HOST', 'redis')
    redis_port = int(_env('REDIS_PORT', '6379') or '6379')
    if not wait_tcp(redis_host, redis_port, timeout, 'Redis'):
        return 1

    db_mode = _env('DOCKER_DATABASE', 'container').lower()
    if db_mode == 'container' and _truthy('DOCKER_PROFILE_POSTGRES', default=True):
        db_host = _env('ERGO_DOCKER_DB_HOST', 'postgres')
        db_port = int(_env('ERGO_DOCKER_DB_PORT', '5432') or '5432')
        if not wait_tcp(db_host, db_port, timeout, 'PostgreSQL'):
            return 1

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
