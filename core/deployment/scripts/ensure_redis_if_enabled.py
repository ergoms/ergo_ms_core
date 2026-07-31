"""
Запуск Redis для разработки без tail логов.

Используется перед прогревом кэшей и API, когда REDIS_ENABLED=true.
Терминал с логами — ergoms start-redis-dev (VS Code Redis Dev / Start All Services).
"""

from __future__ import annotations

import socket
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
_DEPLOYMENT_DIR = SCRIPTS_DIR.parent
if str(_DEPLOYMENT_DIR) not in sys.path:
    sys.path.insert(0, str(_DEPLOYMENT_DIR))
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from cli_locale import t  # noqa: E402
from console_tags import format_console  # noqa: E402
from deployment_env import PROJECT_ROOT, effective_redis_host, effective_redis_port, is_redis_enabled  # noqa: E402
from install_redis import is_installed, ping_redis  # noqa: E402
from log_env import log_file_path  # noqa: E402
from nginx_foreground import _configure_stdio_utf8  # noqa: E402
from redis_dev import (  # noqa: E402
    is_redis_managed_service,
    read_dev_session_marker,
    read_redis_pid,
    write_dev_session_marker,
)


def _redis_tcp_ready(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=1.0):
            return True
    except OSError:
        return False


def ensure_redis_for_dev(*, quiet: bool = False) -> int:
    """
    Запускает Redis, если REDIS_ENABLED=true и процесс ещё не отвечает на ping.

    При REDIS_ENABLED=false возвращает 0 без действий.
    После detached-старта записывает dev-session marker для handoff в терминал.
    """
    if not is_redis_enabled():
        return 0

    if not is_installed(PROJECT_ROOT):
        print(format_console('error', t('redis_not_installed_hint')))
        return 1

    if is_redis_managed_service(PROJECT_ROOT):
        if not quiet:
            print(format_console('info', t('redis_os_service_running')))
        return 0

    def _claim_dev_session(*, source: str) -> None:
        # Marker нужен start-redis-dev: без него portable Redis считается «внешним»
        # и закрытие терминала VS Code его не остановит.
        if read_dev_session_marker(PROJECT_ROOT) is None:
            write_dev_session_marker(
                PROJECT_ROOT,
                pid=read_redis_pid(PROJECT_ROOT),
                source=source,
            )

    if ping_redis(PROJECT_ROOT):
        _claim_dev_session(source='warmup-adopt')
        if not quiet:
            print(format_console('info', t('redis_already_started')))
        return 0

    result = subprocess.run(
        'ergoms start-redis',
        shell=True,
        cwd=str(PROJECT_ROOT),
        check=False,
    )
    if result.returncode != 0:
        return result.returncode

    deadline = time.monotonic() + 15.0
    connect_host = effective_redis_host()
    connect_port = effective_redis_port()
    while time.monotonic() < deadline:
        if ping_redis(PROJECT_ROOT) and _redis_tcp_ready(connect_host, connect_port):
            _claim_dev_session(source='warmup')
            if not quiet:
                print(format_console('ok', t('redis_started_ok')))
            return 0
        time.sleep(0.5)

    log_hint = log_file_path('REDIS', PROJECT_ROOT)
    print(format_console('error', t('redis_ping_failed_log', path=log_hint)))
    return 1


def main() -> int:
    if not is_redis_enabled():
        return 0

    _configure_stdio_utf8()
    return ensure_redis_for_dev()


if __name__ == '__main__':
    raise SystemExit(main())
